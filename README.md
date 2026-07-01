# romm-fast-scan

A drop-in scanning performance plugin for [RomM](https://github.com/rommapp/romm) that replaces the pure-Python file hashing path with a C extension that releases the GIL, enabling genuine parallel hashing across scan workers.

Verified against **RomM 4.9.2** and **5.0.0-alpha.2**. Includes tooling to stay compatible across updates.

---

## How it works

RomM computes CRC32, MD5, and SHA1 hashes for every ROM file during a scan. The original implementation does this in pure Python, which means the GIL serializes all workers even when `SCAN_WORKERS > 1` — extra workers don't actually run in parallel.

This plugin compiles a small C extension (`_fasthash.c`) — either baked into a prebuilt image at build time, or inside the container on first boot if you volume-mount it onto the stock image instead. The extension:

- Computes all three hashes in a **single file pass** using a 256 KB read buffer
- Calls `Py_BEGIN_ALLOW_THREADS` / `Py_END_ALLOW_THREADS` to **release the GIL** during I/O and hashing
- Falls back transparently to the original Python path for archive files (`.zip`, `.7z`, `.rar`, etc.) that require decompression

The result is that `SCAN_WORKERS` threads actually run in parallel on CPU and I/O simultaneously.

**Observed speedup on a 28,000-game library:** ~3–5× faster full rescan with 4 workers on HDD; higher on SSD.

---

## Requirements

- RomM deployed via Podman (or Docker) pod YAML (Kubernetes-style)
- If building your own image: `podman` or `docker` on the machine you build from (not necessarily the RomM host — you can build elsewhere and push)
- If volume-mounting onto the stock image instead (see [Advanced install](#advanced-install-keep-the-stock-image) below): the container needs internet access on first boot, to install a compiler

---

## Installation

The plugin is a container image swap: change one line in your existing `romm.yml`, restart. `start.sh` — the same three-tier patching described below — still runs at every boot inside the image, so you keep the same graceful-fallback behavior either way; the image just ships the C extension precompiled instead of compiling it on first boot.

### Option A: use the published image

```diff
-      image: docker.io/rommapp/romm:4.9.2
+      image: ghcr.io/zeldafan3421/romm-fast-scan:4.9.2-fast-scan
```

That's the entire change. No `command:` override, no `PYTHONPATH` env var, no volume mount — all of that is already baked into the image. The image is built by [this repo's GitHub Actions workflow](.github/workflows/build-container.yml) directly from the same source in this repo, not hand-pushed — if you'd rather verify that yourself or not depend on it, use Option B.

Restart the pod:

```sh
podman pod stop romm-pod && podman pod rm romm-pod && podman play kube romm.yml
```

### Option B: build it yourself

If you'd rather not run an image you didn't build:

```sh
sh scripts/build-image.sh          # builds romm:4.9.2-fast-scan locally
```

Then point `image:` at the local tag (`localhost/romm:4.9.2-fast-scan`) instead of the ghcr.io one, and restart the same way. `scripts/build-image.sh <version> <registry>` also builds for other RomM versions and can push to your own registry — see the script's usage comment.

Either option: on first boot you'll see

```
[fast-scan] Cached: /romm-plugin/lib/_fasthash.cpython-313-x86_64-linux-musl.so
[fast-scan] Installed roms_handler.py (exact match: 4.9.2.py)
[fast-scan] PYTHONPATH=/romm-plugin/lib:/romm-plugin/src:/backend
[fast-scan] Starting RomM...
```

`Cached:` (not `Compiling:`) confirms the extension came precompiled with the image — there's no build step at container startup.

---

## Advanced install: keep the stock image

Use this instead of Option A/B if you want to keep running `docker.io/rommapp/romm:latest` directly — e.g. to auto-track upstream releases without picking a fast-scan-tagged image, or because policy requires the official image. This volume-mounts the plugin onto the stock image; the C extension compiles inside the container on first boot instead of at image-build time.

### 1. Deploy plugin files to your server

```sh
# On the machine running RomM:
mkdir -p /opt/romm/fast-scan-plugin/lib
cp -r src overrides start.sh roms_handler.patch known_sha256.txt \
      /opt/romm/fast-scan-plugin/
cp scripts/refresh.sh /opt/romm/fast-scan-plugin/
chmod +x /opt/romm/fast-scan-plugin/start.sh /opt/romm/fast-scan-plugin/refresh.sh
```

Or run the install helper:

```sh
sh scripts/install.sh
```

### 2. Patch your pod YAML

Copy `scripts/patch_romm_yaml.py` next to your `romm.yml` and run it once:

```sh
python3 scripts/patch_romm_yaml.py
```

This backs up your existing `romm.yml` and adds three things:
- `command: ["/romm-plugin/start.sh"]` — runs the plugin before RomM starts
- `PYTHONPATH=/romm-plugin/lib:/backend` — makes the compiled `.so` importable
- A `hostPath` volume mount for the plugin directory

See `examples/romm.patched.example.yml` for the full expected result.

### 3. Restart the pod

```sh
podman pod stop romm-pod && podman pod rm romm-pod && podman play kube romm.yml
```

On **first boot** you'll see log lines like:

```
[fast-scan] Compiling _fasthash extension for cpython-313-x86_64-linux-musl.so ...
[fast-scan] Built: /romm-plugin/lib/_fasthash.cpython-313-x86_64-linux-musl.so
[fast-scan] Applied roms_handler.py patch
[fast-scan] PYTHONPATH=/romm-plugin/lib:/backend
[fast-scan] Starting RomM...
```

Subsequent boots skip compilation (the `.so` is cached on the host volume).

---

## Configuration

Set `SCAN_WORKERS` in your pod YAML based on your storage:

| Storage type | Recommended workers |
|---|---|
| NVMe SSD | 12–16 |
| SATA SSD | 8–12 |
| HDD | 4–6 |
| Network (NFS/SMB) | 4–8 |

With the GIL released, workers actually run in parallel — unlike stock RomM where extra workers above ~2 give diminishing returns.

### Optional: skip re-reading unchanged files

`Complete` and `Rescan hashes` scans normally re-read every byte of every ROM, even when nothing on disk changed. RomM already stores each file's size, mtime, and hashes. Set this env var to reuse the stored hashes whenever a file's size **and** mtime are unchanged, skipping the read entirely:

```yaml
- name: FAST_SCAN_HASH_CACHE
  value: "1"
```

On an unchanged library this turns a full rescan from "read every byte" into a stat pass — minutes instead of hours on an HDD. It composes with the C extension, which still accelerates the files that actually changed.

**Default off** — it's opt-in because a file edited in place that preserves both its size and mtime (rare; some sync tools do this) would not be re-hashed. It is fail-safe: any problem (disabled, unavailable, file changed, no stored record) falls back to reading and hashing the file normally, so it can never produce a wrong hash. Scope: single-file ROMs; multi-disc and archive ROMs always hash normally.

---

## Staying up to date with RomM

On each boot `start.sh` patches `roms_handler.py` using a three-tier strategy:

1. **SHA match** — `known_sha256.txt` maps each known upstream file SHA to its own pre-patched copy. If the container's file matches any listed version, that copy is installed verbatim (fastest, safest). Multiple RomM versions are supported simultaneously, so the exact-match path keeps working after a `docker pull` to a version you've already refreshed against.
2. **Patch applies** — if the SHA doesn't match, try applying `roms_handler.patch` (survives minor upstream changes — e.g. it already applies cleanly to 5.0.0-alpha.2, whose changes don't touch the hashing path)
3. **Graceful fallback** — if neither works, log a warning and start RomM normally with pure-Python hashing

**If you're on the volume-mount (advanced) install**, this runs fresh against whatever image tag you're currently running, so pulling a new `rommapp/romm` tag just works — you'll see the warning below if that version is new enough to miss both tier-1 and tier-2.

**If you're on a prebuilt image** (Option A/B), the RomM version is fixed by whichever image tag you deployed. To move to a newer RomM release, pull/build the matching fast-scan-tagged image and swap `image:` again — same one-line change as installing. The published ghcr.io image is rebuilt automatically on every push to this repo's `main` branch (see `.github/workflows/build-container.yml`), so `4.9.2-fast-scan` always reflects the latest plugin fixes for that RomM version; it does not itself track new RomM *versions* until this repo's Containerfile is updated to build against them.

When you see this warning after a `docker pull` (or when the image build hits a RomM version this hasn't been refreshed against yet):

```
[fast-scan] WARNING: Could not patch roms_handler.py.
```

Run the refresh tool **inside the running container**:

```sh
podman exec <container-id> sh /romm-plugin/refresh.sh
podman pod stop romm-pod && podman pod rm romm-pod && podman play kube romm.yml
```

This re-generates the patch against the new RomM version and updates `known_sha256.txt`. If you're building your own image (Option B), copy the regenerated `roms_handler.patch`/`known_sha256.txt`/`overrides/prepatched/` back out of the container into this repo and rebuild — see `refresh.sh`'s output for the exact files it touched.

### Removing old versions

Every refresh appends an entry to `known_sha256.txt` and a file to `overrides/prepatched/`, so that list only grows as RomM is updated over time. Trim it with:

```sh
python3 scripts/prune_versions.py list
python3 scripts/prune_versions.py remove 4.9.0 4.9.1       # by version, filename, or SHA prefix
python3 scripts/prune_versions.py keep-latest 3            # keep only the N most recently recorded
```

Removing a version doesn't break anything — `start.sh` just falls back to tier-2 (the diff patch) for that version's SHA instead of the tier-1 exact match, same as for any version that was never recorded. Add `--dry-run` to preview, or `--purge` to delete the old pre-patched files outright instead of moving them to `overrides/prepatched/.removed/` (the default, reversible behavior). `known_sha256.txt` is backed up before every change. Pass `--dir /opt/romm/fast-scan-plugin` to prune a deployed plugin directory instead of the repo checkout.

---

## Fallback behaviour

If anything goes wrong, RomM still starts normally:

- Volume-mount install: if `gcc` is unavailable and `_fasthash.so` isn't cached → pure Python hashing. Prebuilt images (Option A/B) never hit this — the extension is already compiled into the image.
- If the patch fails to apply → stock `roms_handler.py`, no fast path
- If `_fasthash` raises an exception at import or call time → falls back to Python per-file

No ROM data is ever at risk.

---

## Uninstallation

**If you installed via Option A/B (image swap):** change `image:` back to the stock tag and restart — the exact inverse of installing, no scripts involved:

```diff
-      image: ghcr.io/zeldafan3421/romm-fast-scan:4.9.2-fast-scan
+      image: docker.io/rommapp/romm:4.9.2
```

```sh
podman pod stop romm-pod && podman pod rm romm-pod && podman play kube romm.yml
```

**If you installed via the volume-mount (advanced) path:**

```sh
sh scripts/uninstall.sh /opt/romm/fast-scan-plugin /path/to/romm.yml
podman pod stop romm-pod && podman pod rm romm-pod && podman play kube /path/to/romm.yml
```

This:
- Reverts `romm.yml` to stock RomM — removes the entrypoint override, `PYTHONPATH`, and volume mount that `patch_romm_yaml.py` added (backs up first, same as installing)
- Deletes the plugin directory from the host
- Leaves your ROM library, RomM's database, and any `romm.yml.bak.*` backups untouched

Omit the `romm.yml` argument to only remove the plugin directory and leave your pod YAML as-is (you'll see a reminder with the command to run later). To revert just the YAML without touching the plugin directory, run `python3 scripts/unpatch_romm_yaml.py /path/to/romm.yml` directly.

**Either way:** hashes already computed by the C extension are ordinary CRC32/MD5/SHA1 values — RomM doesn't know or care they came from the plugin, so nothing needs to be re-scanned after uninstalling.

---

## File layout

```
romm-fast-scan/
├── README.md                    Main documentation entry point
│
├── Plugin Code:
│   ├── src/
│   │   ├── _fasthash.c          C extension: CRC32 + MD5 + SHA1 with GIL release
│   │   └── fast_scan_cache.py   Opt-in hash-skip cache (FAST_SCAN_HASH_CACHE)
│   ├── overrides/
│   │   └── prepatched/          Pre-patched handlers, one per known RomM version
│   │       ├── 4.9.2.py
│   │       └── 5.0.0-alpha.2.py
│   ├── start.sh                 Container entrypoint wrapper (core plugin file)
│   ├── roms_handler.patch       Minimal unified diff applied at boot
│   └── known_sha256.txt         Maps each known roms_handler.py SHA → pre-patched file
│
├── Container Automation:
│   ├── Dockerfile               Docker build file
│   ├── Containerfile            Podman build file
│   └── .github/workflows/       GitHub Actions CI/CD
│
├── scripts/                     Utility scripts
│   ├── install.sh                Host-side plugin deployment
│   ├── uninstall.sh              Host-side plugin removal (reverts romm.yml + deletes files)
│   ├── patch_romm_yaml.py        Patches your romm.yml in-place (with backup)
│   ├── unpatch_romm_yaml.py      Reverts romm.yml to stock (with backup)
│   ├── build-image.sh            Container image builder helper
│   ├── refresh.sh                Re-generates patch after a RomM update
│   └── prune_versions.py         Removes old recorded RomM versions
│
├── examples/                    Example configurations
│   └── romm.patched.example.yml Example of a fully patched pod YAML
│
└── Other:
    ├── LICENSE                  AGPL-3.0
    ├── NOTICE                   Derivative work attribution
    └── lib/                     Compiled .so lands here at runtime (gitignored)
```

---

## Documentation

📖 **See the [Wiki](https://github.com/zeldafan3421/romm-fast-scan/wiki)** for comprehensive documentation:

- [Quick Start](https://github.com/zeldafan3421/romm-fast-scan/wiki/Home) — Build reference
- [Testing](https://github.com/zeldafan3421/romm-fast-scan/wiki/Testing) — Test procedures and benchmarks
- [Pre-Deployment Checklist](https://github.com/zeldafan3421/romm-fast-scan/wiki/Pre-Deployment-Checklist) — Readiness validation
- [Troubleshooting](https://github.com/zeldafan3421/romm-fast-scan/wiki/Troubleshooting) — Common issues
- [Edge Cases](https://github.com/zeldafan3421/romm-fast-scan/wiki/Edge-Cases) — Limitations and workarounds
- [Architecture](https://github.com/zeldafan3421/romm-fast-scan/wiki/Architecture) — Technical internals
- [Container Build](https://github.com/zeldafan3421/romm-fast-scan/wiki/Container-Build) — Building images
- [Container Design](https://github.com/zeldafan3421/romm-fast-scan/wiki/Container-Design) — Design & maintenance

---

## License

AGPL-3.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

The pre-patched handlers under `overrides/prepatched/` are derivative works of
[rommapp/romm](https://github.com/rommapp/romm), which is also AGPL-3.0.

---

## Disclaimer

Not affiliated with or endorsed by the RomM project. Use at your own risk.
