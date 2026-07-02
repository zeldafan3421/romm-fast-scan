#!/usr/bin/env python3
"""
call_overhead.py — measure the fixed per-call overhead of the ctypes path.
──────────────────────────────────────────────────────────────────────────
The plugin used to be a CPython extension (`import _fasthash`) called
through the native Python C-API. It's now a plain `.so` called through
`ctypes` (see plugin_manager.py) — a deliberate trade: zero CPython-ABI
coupling (one build works on every RomM/Python version, any-language
plugins) in exchange for a bit more *per-call* overhead than a direct
C-API extension had. This quantifies that "bit", so it's a committed
number instead of a hand-wave, and so nobody later mistakes it for a
regression.

It decomposes the cost of one `plugin_manager.hash_file()` call into:

  ffi     -- a bare `ctypes` call into the .so with no args and no I/O
             (`romm_plugin_abi_version()`): the irreducible libffi floor.
  raw     -- the native `romm_hash_file` on a 0-byte file, with the output
             buffers and encoded path allocated ONCE and reused: FFI + the
             file open/read(0)/close syscalls, but no per-call Python work.
  wrapper -- the full `pm.hash_file()` on the same 0-byte file: everything
             `raw` does PLUS the per-call Python the wrapper adds afresh
             each time (3x create_string_buffer, path.encode(), 3x decode).

`wrapper - raw` is the part the old C-API extension mostly avoided and the
part that's optimizable (pre-allocated per-thread buffers) if it ever
mattered. All of it is fixed per *file*, so it's negligible on large files
and only visible on very small ones (tiny NES/Atari-2600 ROMs) -- which is
exactly where the ctypes design reads as a hair slower than the old
extension did.

stdlib only. Loads the real src/plugin_manager.py + the fasthash .so.
"""

import ctypes
import json
import pathlib
import sys
import tempfile
import time

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(REPO / "src"))
import plugin_manager as pm  # noqa: E402


def per_call_seconds(fn, iters, repeats=7, warmup=2000):
    for _ in range(warmup):
        fn()
    best = float("inf")
    for _ in range(repeats):
        start = time.perf_counter()
        for _ in range(iters):
            fn()
        best = min(best, (time.perf_counter() - start) / iters)
    return best


def measured_throughput_mb_s(tmp: pathlib.Path):
    """Hash a few-MB file to get this machine's steady hashing rate, so the
    'overhead is <1% above N KB' crossover below is grounded, not assumed."""
    p = tmp / "throughput.bin"
    size = 8 * 1024 * 1024
    p.write_bytes(b"\xa5" * size)
    # warm cache
    with open(p, "rb") as f:
        f.read()
    best = float("inf")
    for _ in range(5):
        start = time.perf_counter()
        pm.hash_file(str(p))
        best = min(best, time.perf_counter() - start)
    return (size / (1024 * 1024)) / best


def main():
    pm.load_plugins(str(REPO / "plugins"))
    if "hash_file" not in pm.loaded_hooks():
        print(
            "ERROR: fasthash not loaded. Build it (sh scripts/build-plugins.sh) and set\n"
            "FAST_SCAN_ALLOW_UNSIGNED_PLUGINS=1 -- tests/run.sh does both.",
            file=sys.stderr,
        )
        return 2

    # Load the .so directly for the raw/ffi measurements (independent of pm's
    # internal bookkeeping), binding romm_hash_file exactly as _bind_hash_file does.
    fh_dir = REPO / "plugins" / "fasthash"
    meta = json.loads((fh_dir / "plugin.json").read_text())
    lib = ctypes.CDLL(str(fh_dir / meta["so_file"]))
    lib.romm_plugin_abi_version.restype = ctypes.c_int
    lib.romm_plugin_abi_version.argtypes = []
    raw_fn = lib.romm_hash_file
    raw_fn.restype = ctypes.c_int
    raw_fn.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p]

    tmp = pathlib.Path(tempfile.mkdtemp())
    try:
        zero = tmp / "zero.bin"
        zero.write_bytes(b"")
        zpath_b = str(zero).encode()
        crc = ctypes.create_string_buffer(pm.CRC_BUF_LEN)
        md5 = ctypes.create_string_buffer(pm.MD5_BUF_LEN)
        sha1 = ctypes.create_string_buffer(pm.SHA1_BUF_LEN)

        t_ffi = per_call_seconds(lambda: lib.romm_plugin_abi_version(), 200_000)
        t_raw = per_call_seconds(lambda: raw_fn(zpath_b, crc, md5, sha1), 50_000)
        t_wrap = per_call_seconds(lambda: pm.hash_file(str(zero)), 50_000)

        rate = measured_throughput_mb_s(tmp)
    finally:
        for p in tmp.iterdir():
            p.unlink()
        tmp.rmdir()

    us = 1e6
    ffi_us, raw_us, wrap_us = t_ffi * us, t_raw * us, t_wrap * us
    wrapper_overhead_us = wrap_us - raw_us
    # The new-vs-OLD differential -- the part that makes the ctypes design a
    # touch slower than the old CPython extension. The old extension also
    # opened/read/closed the file (that cost is in `raw` and is NOT new), so
    # the differential is the Python wrapper it avoided plus the libffi floor
    # it didn't pay (a direct C-API call was cheaper than a ctypes one).
    differential_us = wrapper_overhead_us + ffi_us

    def crossover_kib(cost_us):
        # size where cost is <1% of hash time: size > cost_s * rate_MBps * 1MB * 100
        return (cost_us / us) * rate * 1024 * 100

    print(f"Environment: Python {sys.version.split()[0]}, hashing rate ~{rate:.0f} MB/s (warm cache)\n")
    print("Per-call cost (best of several tight loops):")
    print(f"  ffi      bare ctypes call, no args / no I/O       : {ffi_us:6.2f} us")
    print(f"  raw      native hash_file, 0-byte, buffers reused : {raw_us:6.2f} us  (mostly file open/read/close syscalls -- the OLD extension paid these too)")
    print(f"  wrapper  full pm.hash_file(), 0-byte file         : {wrap_us:6.2f} us")
    print(f"  wrapper - raw  (per-call Python the wrapper adds) : {wrapper_overhead_us:6.2f} us  (3x create_string_buffer + encode + 3x decode)\n")
    print("Interpretation:")
    print(f"  Total fixed cost per file: ~{wrap_us:.1f} us -- but most of that is file I/O the old")
    print(f"    CPython extension paid too, so it is NOT what made the ctypes design slower.")
    print(f"  New-vs-old differential:  ~{differential_us:.1f} us (the ~{wrapper_overhead_us:.1f} us wrapper the old extension")
    print(f"    avoided by building its result in C, plus the ~{ffi_us:.2f} us libffi floor a direct")
    print(f"    C-API call didn't pay). THIS is why the ctypes design is a hair slower per call.")
    print(f"  That ~{differential_us:.1f} us is <1% of hashing time above ~{crossover_kib(differential_us):.0f} KiB, so it's invisible on")
    print(f"    anything but very small ROMs (sub-~10 KB Atari-2600/NES carts), where it's a")
    print(f"    few percent -- consistent with the ctypes build reading as marginally slower")
    print(f"    than the old extension on a small-ROM-heavy library, while both stay well")
    print(f"    ahead of stock RomM. Deliberate cost of dropping CPython-ABI coupling;")
    print(f"    the wrapper part is optimizable (pre-allocated per-thread buffers) if needed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
