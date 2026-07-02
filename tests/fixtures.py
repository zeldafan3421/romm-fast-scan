#!/usr/bin/env python3
"""
fixtures.py — deterministic synthetic ROM-shaped test data.
──────────────────────────────────────────────────────────────────────────
Generates directories of synthetic files whose *sizes* mimic real ROM
library shapes, so correctness.py and benchmark.py run against the same,
reproducible inputs on any machine. Content is pseudo-random but seeded, so
two runs on the same machine produce byte-identical files (and therefore
identical hashes) -- important for correctness.py's expected-value caching
and for comparing benchmark runs over time.

stdlib only. Not a plugin; just makes files.

Workload profiles (name -> list of (count, size_bytes)):
  small   -- many tiny files: NES/GB/GBA-era libraries
  medium  -- moderate files:  SNES/Genesis-era
  large   -- few big files:   N64/PSX/disc images
  mixed   -- a realistic blend of all three

Sizes are deliberately modest so the suite runs in seconds; the *ratio* of
native-vs-Python is what matters, not absolute wall-clock, and that ratio is
stable across scaled-up totals (verified: doubling counts leaves the
speedup ratios within noise).
"""

import argparse
import os
import pathlib
import random
import sys

# name -> [(count, size_bytes), ...]
PROFILES = {
    "small":  [(512, 256 * 1024)],                       # 512 x 256 KiB  = 128 MiB
    "medium": [(96, 4 * 1024 * 1024)],                   # 96  x 4 MiB    = 384 MiB
    "large":  [(12, 48 * 1024 * 1024)],                  # 12  x 48 MiB   = 576 MiB
    "mixed":  [(300, 256 * 1024), (48, 4 * 1024 * 1024), (6, 48 * 1024 * 1024)],
}

# Edge-case sizes correctness.py cares about (bytes). Kept tiny.
EDGE_SIZES = [0, 1, 255, 256, 257, 65535, 65536, 65537, 256 * 1024, 256 * 1024 + 1]

_SEED = 1234567


def _write_random(path: pathlib.Path, size: int, rng: random.Random) -> None:
    remaining = size
    with open(path, "wb") as f:
        while remaining > 0:
            n = min(remaining, 1024 * 1024)
            f.write(rng.randbytes(n))
            remaining -= n


def generate_profile(dest: pathlib.Path, profile: str) -> list:
    if profile not in PROFILES:
        raise ValueError(f"unknown profile '{profile}' (known: {', '.join(PROFILES)})")
    dest.mkdir(parents=True, exist_ok=True)
    rng = random.Random(f"{_SEED}:{profile}")
    paths = []
    idx = 0
    for count, size in PROFILES[profile]:
        for _ in range(count):
            p = dest / f"{profile}_{idx:05d}_{size}.bin"
            if not (p.is_file() and p.stat().st_size == size):
                _write_random(p, size, rng)
            else:
                # Already present at the right size from a prior run; still
                # advance the rng by the same amount so later files match.
                rng.randbytes(size)
            paths.append(p)
            idx += 1
    return paths


def generate_edge_cases(dest: pathlib.Path) -> list:
    dest.mkdir(parents=True, exist_ok=True)
    rng = random.Random(f"{_SEED}:edge")
    paths = []
    for size in EDGE_SIZES:
        p = dest / f"edge_{size}.bin"
        if not (p.is_file() and p.stat().st_size == size):
            _write_random(p, size, rng)
        else:
            rng.randbytes(size)
        paths.append(p)
    return paths


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dest", help="directory to generate fixtures into")
    ap.add_argument("--profile", choices=list(PROFILES) + ["edge", "all"], default="all")
    args = ap.parse_args()
    dest = pathlib.Path(args.dest)
    if args.profile in ("all",):
        for name in PROFILES:
            n = len(generate_profile(dest / name, name))
            print(f"{name}: {n} files")
        n = len(generate_edge_cases(dest / "edge"))
        print(f"edge: {n} files")
    elif args.profile == "edge":
        print(f"edge: {len(generate_edge_cases(dest / 'edge'))} files")
    else:
        print(f"{args.profile}: {len(generate_profile(dest / args.profile, args.profile))} files")


if __name__ == "__main__":
    sys.exit(main())
