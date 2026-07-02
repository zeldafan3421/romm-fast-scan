#!/usr/bin/env python3
"""
benchmark.py — reproducible native-vs-Python hashing benchmark.
──────────────────────────────────────────────────────────────────────────
Exists so any performance number in this repo's docs can be *regenerated*
rather than asserted from memory. It compares two implementations of the
exact work RomM's scan does per file -- single-pass CRC32 + MD5 + SHA1 --
under the same concurrency model RomM uses (asyncio.to_thread + a
SCAN_WORKERS-sized semaphore):

  * "python" -- a faithful reproduction of RomM's own _calculate_rom_hashes:
                one read loop, incremental zlib.crc32 / hashlib.md5 /
                hashlib.sha1, 256 KiB chunks (matching the native buffer).
  * "native" -- pm.hash_file(), the fasthash plugin via ctypes.

For each workload profile (see fixtures.py) it reports the native-vs-python
speedup at matched worker counts -- that isolates the plugin's contribution
(same concurrency on both sides), which is the honest thing to quote.

IMPORTANT SCOPE (read before quoting a number):
  Files are warmed into the page cache first, so this measures the
  STEADY-STATE, CPU/overhead-bound case -- the *upper bound* on the plugin's
  benefit. A real first-time scan of a large library on a spinning disk is
  I/O-bound: both implementations read the identical bytes off the same
  disk, so the wall-clock difference there is smaller than what you see
  here. Quote these as "warm-cache, CPU-bound" numbers, not "typical HDD
  scan" numbers. Correctness is verified separately by correctness.py.

stdlib only. Loads the real src/plugin_manager.py.
"""

import argparse
import asyncio
import hashlib
import os
import pathlib
import platform
import sys
import time
import zlib

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(REPO / "src"))
import plugin_manager as pm  # noqa: E402

import fixtures  # noqa: E402

CHUNK = 256 * 1024  # match fasthash.c's read buffer for a fair comparison


def python_hash_file(path):
    """Faithful reproduction of RomM's stock single-pass hashing."""
    crc = 0
    md5 = hashlib.md5(usedforsecurity=False)
    sha1 = hashlib.sha1(usedforsecurity=False)
    with open(path, "rb") as f:
        while True:
            chunk = f.read(CHUNK)
            if not chunk:
                break
            crc = zlib.crc32(chunk, crc)
            md5.update(chunk)
            sha1.update(chunk)
    return crc & 0xFFFFFFFF, md5.hexdigest(), sha1.hexdigest()


def warm(paths):
    for p in paths:
        with open(p, "rb") as f:
            while f.read(4 * 1024 * 1024):
                pass


async def _run(fn, paths, workers):
    sem = asyncio.Semaphore(workers)

    async def one(p):
        async with sem:
            await asyncio.to_thread(fn, str(p))

    await asyncio.gather(*(one(p) for p in paths))


def timed(fn, paths, workers, repeats=3):
    best = float("inf")
    for _ in range(repeats):
        start = time.perf_counter()
        asyncio.run(_run(fn, paths, workers))
        best = min(best, time.perf_counter() - start)
    return best


def human_bytes(n):
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024:
            return f"{n:.0f} {unit}"
        n /= 1024
    return f"{n:.1f} TiB"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("fixtures_dir")
    ap.add_argument("--profiles", default="small,medium,large,mixed")
    ap.add_argument("--workers", default="1,4,8")
    ap.add_argument("--repeats", type=int, default=3)
    args = ap.parse_args()

    root = pathlib.Path(args.fixtures_dir)
    worker_counts = [int(w) for w in args.workers.split(",") if w.strip()]
    profiles = [p for p in args.profiles.split(",") if p.strip()]

    pm.load_plugins(str(REPO / "plugins"))
    if "hash_file" not in pm.loaded_hooks():
        print(
            "ERROR: no 'hash_file' plugin loaded. Build plugins (sh scripts/build-plugins.sh)\n"
            "and set FAST_SCAN_ALLOW_UNSIGNED_PLUGINS=1 -- tests/run.sh does both.",
            file=sys.stderr,
        )
        return 2

    cpu = platform.processor() or platform.machine()
    print(f"Environment: {cpu}, {os.cpu_count()} CPUs, Python {platform.python_version()} ({platform.system()})")
    print("Measuring: warm page cache -> steady-state, CPU/overhead-bound (the UPPER BOUND on")
    print("the plugin's benefit; a cold-disk first scan is I/O-bound and shows less). Best of")
    print(f"{args.repeats} runs per cell.\n")

    print("| Profile | Files | Total | Workers | Python (s) | Native (s) | Native speedup |")
    print("|---------|-------|-------|---------|-----------|-----------|----------------|")

    for profile in profiles:
        paths = fixtures.generate_profile(root / profile, profile)
        total = sum(p.stat().st_size for p in paths)
        warm(paths)
        for w in worker_counts:
            t_py = timed(python_hash_file, paths, w, args.repeats)
            t_na = timed(pm.hash_file, paths, w, args.repeats)
            speedup = t_py / t_na if t_na > 0 else float("nan")
            print(f"| {profile} | {len(paths)} | {human_bytes(total)} | {w} "
                  f"| {t_py:.3f} | {t_na:.3f} | {speedup:.2f}x |")

    print("\nNotes:")
    print("- Native-vs-Python at the *same* worker count isolates the plugin's contribution.")
    print("- Warm-cache numbers are the best case. Real cold-disk scans are I/O-bound (both")
    print("  paths read identical bytes), so the field speedup is lower -- do not quote these")
    print("  as 'typical HDD' figures.")
    print("- Correctness (native output == stdlib reference) is checked by tests/correctness.py.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
