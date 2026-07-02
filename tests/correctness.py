#!/usr/bin/env python3
"""
correctness.py — verify the native plugins produce correct output.
──────────────────────────────────────────────────────────────────────────
A fast plugin that computes the *wrong* hash is worse than no plugin, so
this is the foundation the benchmark stands on: before trusting any timing
number, prove the native path agrees with Python's stdlib reference
(hashlib / zlib / zipfile) across normal and edge-case inputs.

Checks:
  * hash_file        vs zlib.crc32 + hashlib.md5 + hashlib.sha1, over a
                     range of sizes incl. 0 bytes, 1 byte, and around the
                     256 KiB read-buffer boundary
  * hash_file_accum  combined digest vs the reference hash of the
                     concatenation of several files, plus each per-file
                     digest
  * archive_list     vs Python's zipfile (member names, sizes, stored CRC32)

Exit 0 if everything matches, nonzero (with a diff) on the first mismatch.
stdlib only. Loads the real src/plugin_manager.py.
"""

import hashlib
import os
import pathlib
import sys
import zipfile
import zlib

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(REPO / "src"))
import plugin_manager as pm  # noqa: E402

import fixtures  # noqa: E402

_failures = []


def _fail(msg):
    _failures.append(msg)
    print(f"  FAIL: {msg}")


def ref_hash_file(path):
    """Reference single-file hash, matching the plugin's conventions:
    empty file -> all three empty strings; else lowercase hex, crc zero-
    padded to 8 chars (matching fasthash.c's %08x)."""
    with open(path, "rb") as f:
        data = f.read()
    if not data:
        return ("", "", "")
    crc = zlib.crc32(data) & 0xFFFFFFFF
    return (f"{crc:08x}", hashlib.md5(data).hexdigest(), hashlib.sha1(data).hexdigest())


def ref_hash_concat(paths):
    crc = 0
    md5 = hashlib.md5()
    sha1 = hashlib.sha1()
    saw_bytes = False
    for p in paths:
        with open(p, "rb") as f:
            data = f.read()
        if data:
            saw_bytes = True
        crc = zlib.crc32(data, crc)
        md5.update(data)
        sha1.update(data)
    if not saw_bytes:
        return ("", "", "")
    return (f"{crc & 0xFFFFFFFF:08x}", md5.hexdigest(), sha1.hexdigest())


def check_hash_file(paths):
    print(f"hash_file: {len(paths)} files")
    for p in paths:
        got = pm.hash_file(str(p))
        exp = ref_hash_file(p)
        if got is None:
            _fail(f"hash_file returned None for {p.name} (plugin not loaded?)")
            return
        if got != exp:
            _fail(f"hash_file mismatch on {p.name} ({p.stat().st_size} B): got {got}, expected {exp}")


def check_accumulator(paths):
    print(f"hash_file_accum: combining {len(paths)} files")
    acc = pm.new_multi_file_accumulator()
    if acc is None:
        _fail("new_multi_file_accumulator() returned None (hash_file_accum hook not loaded?)")
        return
    for p in paths:
        per = acc.hash_file(str(p))
        exp_per = ref_hash_file(p)
        if per != exp_per:
            _fail(f"accum per-file mismatch on {p.name}: got {per}, expected {exp_per}")
    combined = acc.finalize()
    exp_combined = ref_hash_concat(paths)
    if combined != exp_combined:
        _fail(f"accum combined mismatch: got {combined}, expected {exp_combined}")
    acc.free()


def check_archive_list(tmp: pathlib.Path):
    print("archive_list: vs Python zipfile")
    zpath = tmp / "sample.zip"
    members = {
        "readme.txt": b"hello world\n",
        "nested/data.bin": bytes(range(256)) * 40,
        "empty.dat": b"",
    }
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
        for name, content in members.items():
            z.writestr(name, content)

    got = pm.archive_list(str(zpath))
    if got is None:
        _fail("archive_list returned None for a valid zip (hook not loaded, or parse failed)")
        return

    with zipfile.ZipFile(zpath) as z:
        expected = {
            i.filename: (i.compress_size, i.file_size, i.CRC & 0xFFFFFFFF)
            for i in z.infolist()
        }
    got_map = {name: (csize, usize, crc) for (name, csize, usize, crc) in got}

    if set(got_map) != set(expected):
        _fail(f"archive_list member set differs: got {sorted(got_map)}, expected {sorted(expected)}")
        return
    for name, exp in expected.items():
        if got_map[name] != exp:
            _fail(f"archive_list entry '{name}' differs: got {got_map[name]}, "
                  f"expected (compressed, uncompressed, crc32)={exp}")


def main():
    if len(sys.argv) < 2:
        print("usage: correctness.py <fixtures_dir>", file=sys.stderr)
        return 2
    root = pathlib.Path(sys.argv[1])

    pm.load_plugins(str(REPO / "plugins"))
    hooks = pm.loaded_hooks()
    print(f"loaded hooks: {hooks}")
    if "hash_file" not in hooks:
        print(
            "\nERROR: no plugin providing 'hash_file' loaded. Build the plugins first\n"
            "  (sh scripts/build-plugins.sh) and run with FAST_SCAN_ALLOW_UNSIGNED_PLUGINS=1\n"
            "  -- locally-built plugins are unsigned. tests/run.sh does both for you.",
            file=sys.stderr,
        )
        return 2

    edge = fixtures.generate_edge_cases(root / "edge")
    check_hash_file(edge)
    # a handful from each real profile too, so the buffer-loop path (files
    # bigger than one 256 KiB read) is exercised on realistic sizes
    sample = []
    for name in ("small", "medium", "large"):
        sample += fixtures.generate_profile(root / name, name)[:3]
    check_hash_file(sample)
    check_accumulator(edge[:5] + sample[:3])
    check_archive_list(root)

    print()
    if _failures:
        print(f"CORRECTNESS FAILED: {len(_failures)} mismatch(es)")
        return 1
    print("CORRECTNESS OK: native output matches stdlib reference on every input")
    return 0


if __name__ == "__main__":
    sys.exit(main())
