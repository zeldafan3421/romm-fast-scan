# btrfs Multi-Drive Pools: Tuning Guide

## Overview

This guide is for a RomM library that lives on a btrfs filesystem spanning multiple physical devices in `single` data profile (a JBOD-style pool — capacity pooled across drives, not RAID0/RAID1). It covers how that storage layout interacts with `SCAN_WORKERS` and this plugin, and how to set one up from an existing single-drive volume.

**Scope check first:** this is a storage-layer tuning guide, not a plugin feature. Nothing in `romm-fast-scan` is btrfs-aware — the plugin only changes how a single file gets hashed once a worker thread has it open (see `README.md`'s "How it works"). What follows explains why a multi-drive pool tends to let `SCAN_WORKERS` do more useful concurrent work, and how that combines with the plugin's own (modest, measured) per-file overhead reduction — not a claim that the plugin does anything btrfs-specific.

---

## How btrfs spreads data across a single-profile multi-device pool

In `single` data profile, btrfs allocates ~1 GiB data chunks from whichever member device has the most free space, roughly round-robin as chunks fill up. A given file's extents are normally written into one chunk on one device — this is *not* the same as RAID0 striping, where every file is split across all devices. So:

- Two different ROMs scanned concurrently will often land on two different physical drives.
- One large ROM's bytes are typically read from a single drive, no faster than before, unless it happened to span a chunk boundary onto a second device (possible for very large files, but not the common case and not something to plan around).

The practical upshot: multi-drive concurrency benefits **many files scanned in parallel**, not any single file's read speed.

---

## Why this interacts with `SCAN_WORKERS` (and not specifically with this plugin)

Worth being precise here, since it's easy to overstate: CPython releases the GIL during a blocking `read()` syscall regardless of what hashing code runs afterward, so multiple scan-worker threads reading from different physical drives concurrently is something **stock RomM's threading model can already do** — it isn't unlocked by this plugin. (See `README.md`'s "How it works" — even pure-Python `hashlib`/`zlib` release the GIL during the actual hash math; the plugin's real contribution is cutting the *Python-level* per-file overhead around that, not GIL contention that didn't fully exist the way earlier framings of this repo used to claim.)

What a multi-drive pool and this plugin each contribute, and where they compound:

- **A multi-drive pool raises the ceiling on useful concurrency.** With one physical device, `SCAN_WORKERS` beyond a handful mostly queues behind that device's own I/O queue depth. With N independent devices, more workers can have a genuinely outstanding read in flight at once before you hit diminishing returns.
- **The plugin lowers each worker's per-file CPU/dispatch cost**, most measurably on many-small-file libraries at higher worker counts (this repo's own reproducible suite shows ~1.5–1.6× on a many-small-file workload at 4–8 workers, warm cache/CPU-bound — see `tests/README.md`, and don't quote a bigger number than that). A worker that spends less CPU time per file becomes available to pick up the next queued read sooner.
- **Neither of these is validated by `tests/benchmark.py`** — that suite runs from a warm page cache with no real disk I/O involved by design (see `tests/README.md`'s "How to read the benchmark honestly"), so it isolates the plugin's own overhead reduction but says nothing about storage topology. If you want a real number for *your* pool, measure it yourself — see below.

---

## Setting up single-profile data across multiple devices

Check your current layout:

```sh
btrfs filesystem usage /mnt/library
btrfs filesystem show /mnt/library
```

Add a new device to an existing pool:

```sh
btrfs device add -f /dev/sdX /mnt/library
```

Adding a device doesn't move any existing data by itself — new writes start favoring the emptier device(s), but files already on the original drive stay put until you balance:

```sh
btrfs balance start -dconvert=single -mconvert=raid1 /mnt/library
```

This keeps data in `single` profile (spread across devices, no duplication — you still only need N drives of capacity for N drives of data) while metadata goes to `raid1` for resilience, which is the common default `mkfs.btrfs` already applies once a filesystem has 2+ devices; the explicit `-mconvert` here just makes sure a fs that was created single-device stays that way after adding more.

Notes on running the balance itself:
- It's a heavy, disk-I/O-bound operation in its own right — it can take hours on a large pool, and RomM (or anything else reading the same drives) will run *slower*, not faster, while it's in progress. Schedule it for a low-usage window.
- `btrfs balance status /mnt/library` shows progress; `btrfs balance pause` / `btrfs balance cancel` are safe to use if you need to stop partway — no data loss, it just resumes (or you restart it) later.
- For a very large pool, `-dusage=N` filters let you balance incrementally (e.g. `-dusage=50` only touches chunks under 50% utilized) instead of one long run touching everything.

**Avoid RAID5/RAID6 for the data profile.** btrfs's parity-raid profiles have a long-documented history of write-hole and parity-reconstruction issues; check current upstream status before relying on them for a library you care about. `single`, `raid1`, and `raid10` remain the well-trodden, write-safe choices.

---

## Tuning `SCAN_WORKERS` for a multi-drive pool

README's `SCAN_WORKERS` table (NVMe 12–16, SATA SSD 8–12, HDD 4–6, network 4–8) is calibrated per single device — it has no multi-drive column, because drive count is a separate axis this repo hasn't benchmarked (per the caveat above, `tests/` doesn't model storage topology at all).

Directional starting point, not a validated number: more independent spindles can usefully absorb more concurrent workers than the single-device guidance implies, since reads are more likely to be spread across queues instead of piling onto one. Treat the README table as a per-device floor, then confirm on your own hardware rather than assuming a multiplier.

How to measure it honestly, on your own pool:

1. Disable `FAST_SCAN_HASH_CACHE` (or use a library where it won't kick in) so every file actually gets read — otherwise you're measuring the cache, not I/O concurrency.
2. Run a `Rescan hashes` (or `Complete` scan) at a baseline `SCAN_WORKERS`, and record wall time.
3. Raise `SCAN_WORKERS` in steps, re-running the same scan, while watching per-device I/O with `iostat -x 1` (or `iotop`). You're looking for multiple member devices showing simultaneous sustained read activity, not just one.
4. Stop raising workers once wall time plateaus or a single device saturates — that's your pool's ceiling, and it will differ from the README's single-device numbers.

Once you've found a good worker count for reads, turn `FAST_SCAN_HASH_CACHE` back on for routine rescans (see README's "Optional: skip re-reading unchanged files") — on an unchanged library that turns the whole question into a stat pass, independent of how many drives you have.

---

## Common pitfalls

- **Don't expect a single large ROM to read faster.** Balancing spreads *files* across drives, not the *bytes of one file* (that needs RAID0, with its own tradeoffs). The benefit is scoped to many files scanned concurrently.
- **A freshly-added drive doesn't rebalance existing data on its own.** New writes favor the emptier device; a full `btrfs balance` is what actually redistributes files already on the pool.
- **A btrfs pool reached over the network (NFS/SMB export to the RomM host) behaves like the README's "Network (NFS/SMB)" row, not like local multi-drive concurrency** — the network link, not spindle count, becomes the bottleneck at that point.
- **Don't benchmark while `btrfs scrub` or `balance` is running.** Both are disk-I/O heavy and will contend with a RomM scan for the same drives, skewing any timing comparison.

---

## See also

- `README.md` — "Configuration" (`SCAN_WORKERS` baseline table, `FAST_SCAN_HASH_CACHE`) and "How it works" (the honest, scoped performance claim this guide builds on)
- `tests/README.md` — what this repo's own benchmark suite measures and, importantly, what it doesn't (no real disk I/O, no storage topology)
- `docs/TROUBLESHOOTING.md` — "Performance Issues" section, if scans get slower after a storage change rather than faster
