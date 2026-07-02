# tests/ — synthetic correctness + performance suite

This exists so this repo's claims about the plugin — *"it's correct"* and
*"it's this much faster"* — can be **reproduced on demand** instead of taken
on faith. Any performance figure that appears in `README.md`/docs should be
regenerable here; if a number can't be reproduced by this suite, it doesn't
belong in the docs.

```sh
sh tests/run.sh              # correctness + benchmark
sh tests/run.sh correctness  # just correctness (fast)
sh tests/run.sh benchmark    # just the benchmark
```

`run.sh` builds the plugins from source and runs with
`FAST_SCAN_ALLOW_UNSIGNED_PLUGINS=1` (a locally-built plugin is unsigned —
only CI holds the signing key; see `plugins/README.md`). Needs a C compiler
and the `fasthash` build deps (openssl/zlib headers). Fixtures go in a temp
dir and are cleaned up on exit (~1 GiB peak).

## What each piece does

- **`fixtures.py`** — deterministic (seeded) synthetic files whose *sizes*
  mimic real library shapes: `small` (many 256 KiB files, NES/GB-era),
  `medium` (4 MiB, SNES/Genesis-era), `large` (48 MiB, N64/PSX/disc),
  `mixed` (a blend), plus `edge` sizes (0, 1, around the 256 KiB read
  boundary) for correctness.
- **`correctness.py`** — the foundation. Verifies the native plugins agree
  with Python's stdlib (`hashlib`/`zlib`/`zipfile`) on every input:
  `hash_file`, the `hash_file_accum` accumulator (per-file *and* combined
  digests), and `archive_list`. A fast plugin that hashes *wrong* is worse
  than no plugin, so a benchmark number means nothing until this passes.
- **`benchmark.py`** — compares `pm.hash_file` against a faithful
  reproduction of RomM's own single-pass Python hashing, under RomM's
  concurrency model (`asyncio.to_thread` + a `SCAN_WORKERS`-sized
  semaphore), at matched worker counts. Prints a markdown table.
- **`call_overhead.py`** — the fixed *per-call* cost of the `ctypes` path,
  decomposed (bare FFI floor / native call+I/O / full Python wrapper). The
  plugin used to be a CPython extension called through the native C-API;
  it's now a `.so` called via `ctypes`, which costs a little more per call
  (measured **~2 µs new-vs-old differential** on the dev VM — the Python
  wrapper the old extension avoided, plus the libffi floor). This exists so
  that trade is a committed number, not a hand-wave, and so it isn't
  mistaken for a regression: it's <1% of hash time on anything but very
  small ROMs, and the deliberate price of zero CPython-ABI coupling. See
  CLAUDE.md's "Why `ctypes`, and what it costs" note.

## How to read the benchmark honestly (this is the point)

- It reports **native-vs-Python at the *same* worker count**, which isolates
  the plugin's own contribution (same concurrency on both sides). That's the
  honest thing to quote — not "native at 8 workers vs Python at 1".
- It measures the **warm page cache, CPU/overhead-bound** case — the *upper
  bound* on the plugin's benefit. A real first-time scan of a large library
  on a spinning disk is **I/O-bound**: both implementations read the
  identical bytes off the same disk, so the field speedup is **lower** than
  the table. Never quote these as "typical HDD scan" numbers.
- The Python baseline here is deliberately *lean* (a tight single-pass
  loop). RomM's actual `_calculate_rom_hashes` does more per-file Python
  work (dual per-file + accumulator hashing, mime detection), so the real
  in-RomM CPU-bound advantage is plausibly a little higher than this floor —
  but we quote the conservative, reproducible number.

## Representative result

Measured on the development VM (9 vCPUs, warm cache) with this suite — run
it yourself for numbers on your own hardware:

| Workload | 1 worker | 4 workers | 8 workers |
|---|---|---|---|
| many small files (`small`) | ~1.0× | ~1.6× | ~1.6× |
| few large files (`large`) | ~1.0× | ~1.1× | ~1.05× |

Takeaways: **no single-file speedup** (both paths bottom out in OpenSSL), a
**modest concurrency win concentrated in many-small-file libraries**, and
**near-parity on large files**. This is why the README quotes a modest,
scoped figure rather than a big headline multiplier.
