# Testing Guide for romm-fast-scan

## Overview

This plugin modifies two critical paths in RomM:
1. **File hashing** — `roms_handler.py` calls `plugin_manager.hash_file(...)`, which dispatches into the native `fasthash` plugin (a plain C-ABI `.so` loaded via `ctypes`, not a CPython extension) to compute CRC32/MD5/SHA1. `ctypes` automatically releases the GIL for the duration of the call, so `SCAN_WORKERS` threads run genuinely concurrently.
2. **Hash storage** — the cache helper reuses stored hashes for unchanged files

Both are designed to fail safely (fall back to pure Python), but comprehensive testing before production use is strongly recommended.

---

## Manual Testing

### 1. Installation & Startup

**Test: plugin boots and compiles the native plugins**

```sh
# On the host:
sh install.sh
# Copy romm.yml and patch it
python3 ../scripts/patch_romm_yaml.py

# Volume-mount / self-built plugins aren't signed -- add this or they
# won't load (see plugins/README.md's "Signing and
# FAST_SCAN_ALLOW_UNSIGNED_PLUGINS"):
#   - name: FAST_SCAN_ALLOW_UNSIGNED_PLUGINS
#     value: "1"

# Restart the pod
podman pod stop romm-pod && podman pod rm romm-pod
podman play kube romm.yml
```

**Expected output in logs:**
```
[fast-scan] Compiling fasthash -> libfasthash.so ...
[fast-scan] Built: /romm-plugin/plugins/fasthash/libfasthash.so
[fast-scan] Compiling archive-list -> libarchive_list.so ...
[fast-scan] Built: /romm-plugin/plugins/archive-list/libarchive_list.so
[fast-scan] Applied roms_handler.py patch
[fast-scan] PYTHONPATH=/romm-plugin/src:/backend
[fast-scan] Starting RomM...
```

**On second boot (cached .so, or any boot of a prebuilt `ghcr.io` image):**
```
[fast-scan] All plugins cached, nothing to compile
[fast-scan] Installed roms_handler.py (exact match: 4.9.2.py)
```

**Common startup failures:**
- `Cannot install build tools -- plugins unavailable, using pure Python fallback` → `apk`/compiler unavailable; RomM falls back to pure Python (acceptable, slower)
- `Compile failed for <plugin> -- that hook falls back to pure Python` → that plugin's hook is unavailable this boot
- `Could not patch roms_handler.py` → version mismatch; RomM falls back to pure Python
- A plugin compiles fine but never gets used → check whether it was rejected for being unsigned (see TROUBLESHOOTING.md)

---

### 2. Hashing (native `fasthash` plugin fast path)

**Test: the native plugin is actually used for single files**

```sh
podman exec <romm-app-container-id> sh -c '
  python3 -c "
    import sys
    sys.path.insert(0, \"/romm-plugin/src\")
    import plugin_manager as pm
    pm.load_plugins(\"/romm-plugin/plugins\")
    # Hash a real ROM file in the library
    result = pm.hash_file(\"/path/to/a/rom.rom\")
    if result is None:
      print(\"hash_file() returned None -- plugin unavailable\")
    else:
      crc, md5, sha1 = result
      print(f\"CRC: {crc}\")
      print(f\"MD5: {md5}\")
      print(f\"SHA1: {sha1}\")
  " 2>&1
'
```

**Expected:** hex strings, one per hash type, no errors, and not `None`.

**Verify against Python hashlib to confirm correctness:**
```python
import hashlib
with open("/path/to/a/rom.rom", "rb") as f:
    data = f.read()
    print(hashlib.md5(data).hexdigest())
    print(hashlib.sha1(data).hexdigest())
```

Should match the native plugin's output exactly.

---

### 3. Hashing (Fallback: archive files)

**Test: archive files (`.zip`, `.7z`) always use Python decompression**

In the RomM web UI, trigger a scan of a platform that has multi-file ROMs or archives. Check the logs — you should not see decompression errors. Archives should hash successfully via the Python fallback, not the native plugin.

**Verify:** extract an archive manually and compute hashes on its members; RomM should report the same hashes for the archive.

---

### 4. Hash Cache (Tier-0: opt-in)

**Test: cache is disabled by default**

```sh
podman exec <romm-app-container-id> python3 -c "
  import fast_scan_cache as c
  print('Cache enabled:', c.is_enabled())
" 2>&1
```

**Expected:** `Cache enabled: False`

**Test: cache can be enabled**

Add to your pod YAML:
```yaml
- name: FAST_SCAN_HASH_CACHE
  value: "1"
```

Restart the pod:
```sh
podman exec <romm-app-container-id> python3 -c "
  import fast_scan_cache as c
  print('Cache enabled:', c.is_enabled())
" 2>&1
```

**Expected:** `Cache enabled: True`

---

### 5. Hash Cache (behavioral test)

**Prerequisites:**
- A library with at least 100 games (to make timing differences visible)
- Cache enabled (`FAST_SCAN_HASH_CACHE=1`)
- HDD or slower storage (SSD may not show the benefit)

**Test: first rescan reads all files, second rescan uses cache**

In RomM web UI, run a `Complete` scan or `Rescan hashes`:

```
First run (all files unchanged):
  - Duration: X minutes (full read + hash)
  - Cache misses on every file (not in DB yet after scan)

// Files on disk haven't changed
// Run the same scan again

Second run (all files unchanged):
  - Duration: Y minutes where Y << X (mostly stats, cache hits)
  - Hashes reused from DB
```

**Expected ratio:** ~3–10x faster on HDD if your library is unchanged (mostly stat() overhead instead of disk reads).

---

### 6. Hash Cache (cache miss detection)

**Test: edited files are re-hashed, not cached**

1. Identify a small ROM file in your library
2. Get its mtime: `stat /path/to/rom`
3. Note its hashes in RomM
4. Append a single byte to the file: `echo >> /path/to/rom`
5. Run `Rescan hashes`

**Expected:**
- File size changed → cache lookup returns `None` → file is re-hashed
- Hashes change in RomM (they should differ from step 3)
- No false cache hit

---

### 7. GIL Release (concurrency verification)

This requires instrumentation or external profiling. For a basic check:

**Test: multiple workers actually run in parallel**

The native `fasthash` plugin isn't a CPython extension at all — it's a plain
C-ABI `.so` called through `ctypes`, which releases the GIL automatically for
the duration of any foreign-function call. There's no manual
`Py_BEGIN_ALLOW_THREADS` in the plugin's C source (unlike the old `_fasthash.c`
CPython extension this replaced) — it's simply not part of the interpreter's
execution model in the first place.

```sh
# Set 8 workers in your pod YAML
# Run a scan on a platform with 1000+ games on HDD

# Monitor CPU usage while scanning:
# - With the native plugin (GIL released by ctypes): multiple cores should be busy (>200% in top)
# - Stock RomM (GIL held by pure-Python hashing): mostly one core busy (100% in top)
```

**Measure with time:**
```sh
time podman exec <romm-app-container-id> python3 << 'EOF'
import asyncio, time
from handler.scan_handler import scan_handler

# Time a full rescan
t0 = time.time()
# ... run scan ...
print(f"Elapsed: {time.time() - t0:.1f}s")
EOF
```

Compare 4 workers vs 1 worker on your library:
- 4 workers should be 2.5–3× faster on HDD (not 4× due to I/O serialization on spin)
- 4 workers should be closer to 3.5–4× faster on SSD

---

## Automated / Scripted Testing

### Test: native plugins build on fresh container

```sh
# Build a fresh RomM container and mount the plugin
podman run --rm -v /opt/romm/fast-scan-plugin:/romm-plugin \
  docker.io/rommapp/romm:latest \
  /romm-plugin/start.sh 2>&1 | grep -E "Built:|Cached:|All plugins cached|Compile failed"
```

**Expected:** `Built: /romm-plugin/plugins/fasthash/libfasthash.so` (and the same for `archive-list`).

---

### Test: Patch applies to known versions

```sh
# Simulate patching against 4.9.2 and 5.0.0-alpha.2
for ref in 4.9.2 5.0.0-alpha.2; do
  gh api repos/rommapp/romm/contents/backend/handler/filesystem/roms_handler.py?ref=$ref \
    -q '.content' | base64 -d > /tmp/stock_$ref.py
  
  cp /tmp/stock_$ref.py /tmp/test_$ref.py
  patch -N -s /tmp/test_$ref.py roms_handler.patch || {
    echo "FAIL: patch doesn't apply to $ref"
    exit 1
  }
  python3 -c "import ast; ast.parse(open('/tmp/test_$ref.py').read())" || {
    echo "FAIL: patched $ref has syntax errors"
    exit 1
  }
done
echo "PASS: patch applies to all known versions and produces valid syntax"
```

---

### Test: Cache helper fail-safety

```python
import os, sys
sys.path.insert(0, '/romm-plugin/src')
import fast_scan_cache as c

# Test 1: disabled returns None
os.environ['FAST_SCAN_HASH_CACHE'] = '0'
assert c.cached_file_hash(1, '/tmp', 'x') is None, "disabled cache should return None"

# Test 2: enabled but file missing returns None
os.environ['FAST_SCAN_HASH_CACHE'] = '1'
assert c.cached_file_hash(1, '/tmp', 'nonexistent.rom') is None, "missing file should return None"

# Test 3: enabled but DB unavailable returns None
# (Can't mock DB easily outside RomM, but the try/except should catch it)
result = c.cached_file_hash(99999, '/tmp', 'fake.rom')
assert result is None, "invalid rom_id should return None"

print("PASS: cache helper is fail-safe")
```

---

### Test: refresh.sh resilience

Simulates a RomM upstream change that breaks the diff patch:

```sh
podman exec <romm-app-container-id> sh -c '
  # Verify refresh.sh exists and is executable
  test -x /romm-plugin/refresh.sh || exit 1
  
  # Dry-run: check the re-patcher logic
  /romm-plugin/refresh.sh 2>&1 | grep -E "Recording new version|Done"
'
```

**Expected:** refresh completes, updates `known_sha256.txt`, and regenerates `roms_handler.patch`.

---

## Performance Benchmarking

### Benchmark 1: native plugin vs pure Python

**Setup:**
- Disable cache: `FAST_SCAN_HASH_CACHE=0`
- Pick a ROM file (100 MB–1 GB ideal)

**Measure the native plugin:**
```sh
podman exec <romm-app-container-id> python3 << 'EOF'
import sys, time
sys.path.insert(0, "/romm-plugin/src")
import plugin_manager as pm
pm.load_plugins("/romm-plugin/plugins")
path = "/path/to/test.rom"
t0 = time.time()
for _ in range(10):
    crc, md5, sha1 = pm.hash_file(path)
elapsed = time.time() - t0
print(f"Native plugin (10 runs): {elapsed:.2f}s ({elapsed/10:.3f}s per run)")
EOF
```

**Measure pure Python:**
```sh
podman exec <romm-app-container-id> python3 << 'EOF'
import time, hashlib, binascii
path = "/path/to/test.rom"
def hash_file_py(p):
    crc = 0
    md5_h = hashlib.md5(usedforsecurity=False)
    sha1_h = hashlib.sha1(usedforsecurity=False)
    with open(p, 'rb') as f:
        for chunk in iter(lambda: f.read(256*1024), b''):
            crc = binascii.crc32(chunk, crc)
            md5_h.update(chunk)
            sha1_h.update(chunk)
    return f'{crc:08x}', md5_h.hexdigest(), sha1_h.hexdigest()

t0 = time.time()
for _ in range(10):
    hash_file_py(path)
elapsed = time.time() - t0
print(f"Python (10 runs): {elapsed:.2f}s ({elapsed/10:.3f}s per run)")
EOF
```

**Expected:** Native plugin 2–5× faster depending on file size and disk speed.

---

### Benchmark 2: cache hit ratio

**Setup:**
- Enable cache: `FAST_SCAN_HASH_CACHE=1`
- Library with 28k games, unchanged between scans

**Measure:**
```sh
time podman exec <romm-app-container-id> RomM rescan --type=complete
```

Compare:
- **First rescan:** full read, no cache hits (10–60 minutes depending on HDD)
- **Second rescan:** mostly stats, high cache hits (2–10 minutes)

**Log the ratio:**
```
First rescan:  45 minutes (reading all 28k games)
Second rescan: 8 minutes  (5.6× faster, mostly mtime/size stats)
```

---

## Integration Testing

### Test: concurrent scans don't break

Start two scans simultaneously in RomM (if the UI allows):
- They should serialize via `SCAN_WORKERS` semaphore, not corrupt hashes
- No race conditions on file I/O or DB writes

### Test: plugin survives RomM restarts

```sh
podman pod stop romm-pod && podman pod rm romm-pod && podman play kube romm.yml
# Wait for startup
sleep 10
# Verify the .so files are cached and reused
podman logs <romm-app-container-id> | grep -E "All plugins cached|Cached:"
```

**Expected:** second startup logs `All plugins cached, nothing to compile` (instant, not recompiled).

---

## What to Document / Report

If you encounter unexpected behavior or want to confirm normal operation, record:

1. **Plugin startup logs** — check for warnings or failures
2. **RomM version** — `docker inspect docker.io/rommapp/romm:latest` or `podman run ... romm --version`
3. **Library size** — count of games and total size on disk
4. **Storage type** — HDD, SSD, NFS, etc.
5. **SCAN_WORKERS setting** — how many workers you configured
6. **Timings** — before/after the plugin for a full rescan
7. **Any hash mismatches** — if a file's hash differs between runs (sign of a real issue)

---

## Known Limitations & Testing Caveats

- **Hash cache edge case:** a file edited in place to preserve both size and mtime will not be re-hashed (rare; documented in EDGE_CASES.md)
- **Multi-file ROMs:** the cache only applies to single-file ROMs, not multi-disc or archive ROMs
- **Network storage:** the native plugin should work fine on NFS, but mtime rounding may differ between client and server, causing cache misses
- **Signing:** a plugin you compile yourself (volume-mount install, or `scripts/build-plugins.sh`) is unsigned and won't load unless `FAST_SCAN_ALLOW_UNSIGNED_PLUGINS=1` is set — see `plugins/README.md`'s "Signing and `FAST_SCAN_ALLOW_UNSIGNED_PLUGINS`" section
- **Symbolic links:** the plugin follows symlinks (standard behavior), but cache hits depend on stable inode/mtime, which may change if symlinks are re-created

See [EDGE_CASES.md](EDGE_CASES.md) for full details.
