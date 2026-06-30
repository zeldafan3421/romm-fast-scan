# Edge Cases & Limitations

## Overview

The fast-scan plugin optimizes the common path (single-file ROM scanning with GIL-released hashing and optional skip-on-unchanged cache), but various edge cases fall back to safe defaults. Understanding these helps predict behavior in your library and avoid surprises.

---

## Hashing Path (C Extension vs Pure Python)

### Archive Files (`.zip`, `.7z`, `.rar`, etc.)

**Behavior:** Always use pure Python decompression, never the C extension.

**Why:** Archive decompression is format-specific and memory-bound. The C extension only handles raw file I/O + hash updates; decompression libraries (libzip, p7zip) are already in Python. Forcing them through the C extension would be slower, not faster.

**Scope:** Any ROM with an extension in `ARCHIVE_READERS` (checked in `roms_handler.py`).

**Impact:** Negligible — most modern ROM collections use raw disc files, not archives.

**Test:** Trigger a scan of a platform with `.zip` files. Check logs for decompression errors; none should appear (uses Python fallback gracefully).

---

### Multi-File ROMs (Multi-Disc, multi-part files)

**Behavior:** The C extension only applies to the *single* file being hashed. For multi-disc ROMs (folder with multiple `.bin`/`.iso` files), each file is hashed individually via the C extension, but the *aggregate* CRC across all files is accumulated in pure Python.

**Why:** Multi-file accumulation is stateful (`MultiFileHasher` type in the C code), and building that on the fly is unneeded complexity — most single-file ROMs benefit from the speedup. The per-file reads are still parallelized by `SCAN_WORKERS`.

**Limitation:** A multi-file ROM with 10 member files will hash via the C extension 10 times (parallelized), but no single pass reads all 10 together.

**Impact:** Minimal — the bottleneck is I/O, not hashing. 10 parallel reads of individual files is faster than 1 serial read of all 10.

**Test:** Scan a platform with multi-file ROMs (e.g., PSX `.bin`/`.cue`). Hashing should complete without errors.

---

### CHD Files (Compressed Harmonic Drive)

**Behavior:** Raw CHD files are hashed by the C extension. CHD-specific metadata (SHA1 embedded in the file) is extracted separately via `extract_chd_hash()` and returned in `chd_sha1_hash`.

**Why:** The embedded SHA1 is a property of the CHD format, not a hash of the file's contents.

**Limitation:** The cache (Tier-0) does not apply to CHD files — they always re-hash. This is because the cache relies on file size + mtime; CHD files often have complex versioning, and a recompressed CHD with identical content may have different size/mtime.

**Impact:** CHD rescans are slower than raw file rescans. If you have a large CHD collection, you may want to run `Rescan hashes` less frequently or disable the C extension and stick with pure Python (negligible difference in speed for CHD).

**Test:** Run a scan on a platform with CHD files (e.g., Arcade). Hashes should appear, and the embedded `chd_sha1_hash` should be populated.

---

### Firmware Files

**Behavior:** Firmware files are handled like ROMs — hashed by the C extension if they're single files, fallback to Python if needed.

**Limitation:** Firmware files rarely change, so the hash cache (Tier-0) is less valuable for them. But if enabled, unchanged firmware will benefit just like ROMs.

**Test:** Run a scan on a platform with firmware (e.g., BIOS files). Hashes should appear normally.

---

## Hash Cache (Tier-0: FAST_SCAN_HASH_CACHE)

### Size & Mtime Collision (False Negative)

**Scenario:** A file is edited in-place to preserve both file size and modification time.

**Example:**
```
Original: rom.rom (100 MB, mtime=2026-06-30T10:00:00)
Edit:     Modify bytes in the middle, write back without changing size or mtime
Result:   rom.rom (100 MB, mtime=2026-06-30T10:00:00)  ← size+mtime match DB
```

**Behavior:** Cache returns the *stored* hashes (unchanged), so the file's true hash difference is not detected.

**Likelihood:** Very low. File editors typically update mtime on save. Preserving mtime requires deliberate action (e.g., `touch -r` after editing, or tools like rsync with `--times`). Preserving size is even rarer (in-place overwrites of exact byte count).

**Mitigation:** 
- Disable cache for that rescan: `FAST_SCAN_HASH_CACHE=0`
- Or, always do a `Complete` scan (not just `Rescan hashes`) after you suspect changes — `Complete` clears resources, forcing a full hash re-read

**Detection:** If you suspect this happened:
```sh
# Force re-hash of a specific ROM:
# 1. Delete the ROM's record in RomM (web UI or DB)
# 2. Re-scan the platform
# 3. New hashes will be computed from scratch
```

**Test:** Create a file, note its mtime and size, edit it (changing one byte), restore mtime and size using `touch -r` and `truncate`, then run a rescan. The cache will incorrectly reuse hashes (expected behavior; this is the known edge case).

---

### Database Inconsistencies

**Scenario:** A `RomFile` record exists in the DB, but the file on disk is missing.

**Behavior:** Cache query returns `None` (file stat fails on `ENOENT`), caller hashes normally. If the file truly is missing, hashing will raise an exception, and RomM logs a warning (normal RomM behavior — no regression).

**Impact:** Safe — no risk of stale hashes.

---

### Stored Hashes Are Empty

**Scenario:** A `RomFile` record exists with `file_size_bytes` and `last_modified`, but all hash columns (`crc_hash`, `md5_hash`, `sha1_hash`, `chd_sha1_hash`) are `NULL` or empty strings.

**Cause:** The file was recorded but never successfully hashed (e.g., scan was interrupted, or platform is non-hashable).

**Behavior:** Cache returns `None` (detects empty row and falls through), file is re-hashed normally.

**Impact:** Safe — the file is hashed, and the DB is updated with real hashes.

---

### Concurrent Scans

**Scenario:** Two scans are running simultaneously on the same ROM file (unlikely in practice due to RomM's UI, but theoretically possible).

**Behavior:** 
- Scan A reads the file, computes hashes, updates the DB
- Scan B queries the DB at the same time; it may get either old or new hashes depending on transaction isolation
- Both scans' results are correct (no corruption), but the final DB state depends on which scan commits last

**Impact:** Minimal — scans serialize via the `SCAN_WORKERS` semaphore, so true concurrency on the *same ROM* is prevented by RomM's locking. Multiple ROMs are scanned in parallel, but each one is processed by at most one worker at a time.

**Mitigation:** None needed — RomM's semaphore handles this.

---

### mtime Floating-Point Rounding

**Scenario:** mtime is stored as a float in the DB and round-trips through floating-point arithmetic.

**Behavior:** The cache uses a 1e-6 epsilon when comparing mtimes to absorb float noise. This is much tighter than typical filesystem mtime granularity (1 second on ext4, 2 seconds on HFS+), so false positives are impossible.

**Example:**
```
Stored mtime:  1719746400.123456 (float in DB)
Disk mtime:    1719746400.123456 (float from os.stat)
Difference:    < 1e-6  ✓ cache hit

Stored mtime:  1719746400.123456
Disk mtime:    1719746401.123456 (1 second later)
Difference:    > 1e-6  ✓ cache miss (correct)
```

**Impact:** None — the epsilon is conservative and catches all real changes.

---

### Network Storage (NFS, SMB)

**Scenario:** ROM files are on NFS or SMB, where mtime granularity and synchronization may differ between client and server.

**Behavior:** 
- Cache hit logic: `stat()` on the client may see a different mtime than the server recorded in the DB, causing spurious cache misses
- Result: Files are re-hashed even though they're unchanged (safe but slower)

**Mitigation:** 
- The cache still works; it's just conservative (cache misses when there's clock skew are safe)
- If you see systematic re-hashing of network files even though they haven't changed, disable the cache: `FAST_SCAN_HASH_CACHE=0`

**Test:** Mount ROMs via NFS, enable cache, run two rescans back-to-back. Measure timing — if the second rescan is not significantly faster, clock skew may be causing cache misses.

---

### Symbolic Links

**Scenario:** A ROM file is a symlink to another file, or is inside a symlinked directory.

**Behavior:** `os.stat()` follows symlinks by default, so the cache sees the target file's size/mtime. If the symlink is re-created or the target changes, the cache detects the change normally.

**Limitation:** If a symlink points to different targets (e.g., you swap it between two versions of a game), the cache may miss the change if both targets have identical size+mtime. This is the same as the size+mtime collision edge case.

**Impact:** Very rare.

**Mitigation:** Same as size+mtime collision: disable cache or do a `Complete` scan.

---

## Patching & Version Resilience

### Patch Doesn't Apply (Tier-2 failure)

**Scenario:** RomM is updated, and `roms_handler.py` changes in a way that breaks the unified diff patch.

**Behavior:**
1. `start.sh` tries the diff (tier-2): fails
2. Falls back to tier-3: pure Python hashing (no C extension used)
3. Logs a warning: `"WARNING: Could not patch roms_handler.py."`

**Impact:** RomM still starts and scans normally, but at pure-Python speeds (3–5× slower than with the C extension).

**Mitigation:** Run `refresh.sh` inside the container to regenerate the patch and SHAs for the new version:
```sh
podman exec <romm-app-container-id> sh /romm-plugin/refresh.sh
podman pod stop romm-pod && podman pod rm romm-pod && podman play kube romm.yml
```

**Test:** See [TESTING.md](TESTING.md) § "refresh.sh resilience".

---

### Exact SHA Match Fails (Tier-1 fallback)

**Scenario:** RomM version is new (not in `known_sha256.txt`), or the container's file SHA doesn't match any known entry.

**Behavior:** Tier-1 fails, falls back to tier-2 (apply the diff patch). The patch *usually* applies cleanly if only minor changes were made.

**Impact:** None — if the patch applies, you get the full fast path. If it doesn't, you fall back to pure Python (safe but slow).

**Test:** Manually corrupt the first known SHA in `known_sha256.txt`, restart the pod. Logs should show a tier-2 patch attempt instead of a tier-1 copy.

---

### Pre-patched Files Diverge from Patch

**Scenario:** The committed `prepatched/*.py` files and the `roms_handler.patch` diff were built from different upstream versions and no longer match.

**Behavior:** Tier-1 can match and copy a pre-patched file (fast path), or tier-2 can apply the patch (slower, but still uses the fast path). The two strategies are independent and should both work.

**Impact:** None — both tiers produce the same fast path. If they diverge, tier-1 just doesn't match, and tier-2 applies the patch.

**Likelihood:** Very low — the patch is regenerated from the latest pre-patched file, so they're always in sync.

---

## Build & Runtime Issues

### C Extension Fails to Compile

**Scenario:** `gcc` is unavailable, or OpenSSL/zlib headers are missing.

**Behavior:**
1. `start.sh` tries to compile: `apk add gcc musl-dev openssl-dev zlib-dev`
2. If install fails, logs: `"Compile failed — using pure Python fallback"`
3. RomM starts without the C extension

**Impact:** RomM scans at pure Python speeds (no actual hash errors, just slower).

**Mitigation:** Ensure the container has internet access on first boot, or pre-install build tools in a custom image.

**Test:** Block outbound traffic to APK repos before boot; `start.sh` should fail to install `gcc` and fall back to pure Python.

---

### .so File Corruption

**Scenario:** The compiled `.so` file is corrupted or incompatible with the running Python version.

**Behavior:** `import _fasthash` fails with a runtime error (e.g., `ELF header mismatch`). The import is wrapped in a try/except, so the handler falls back to Python hashing.

**Impact:** Safe — RomM continues with pure Python.

**Mitigation:** Delete the cached `.so` and let `start.sh` recompile:
```sh
rm /romm-plugin/lib/_fasthash*.so
podman pod stop romm-pod && podman pod rm romm-pod && podman play kube romm.yml
```

---

### fast_scan_cache Module Not Found

**Scenario:** `src/fast_scan_cache.py` is missing or not on `PYTHONPATH`.

**Behavior:** The handler's `import fast_scan_cache as _fsc` is wrapped in a try/except, so `_fsc` is `None`. The cache tier-0 check skips (returns `None`), and tier-2 (C extension) or tier-3 (Python) proceeds normally.

**Impact:** Cache feature is disabled, but fast path (C extension) still works.

**Mitigation:** Ensure `install.sh` copied the `src/` directory:
```sh
ls /romm-plugin/src/fast_scan_cache.py
```

---

## Configuration Issues

### SCAN_WORKERS Too High

**Scenario:** `SCAN_WORKERS` is set to more than the number of CPU cores, or too high for the storage backend (e.g., 16 on an HDD).

**Behavior:** Workers idle waiting for I/O; effective parallelism is limited by disk throughput, not CPU cores.

**Impact:** Slower than optimal (unnecessary context-switching overhead). See [README.md](../README.md) for recommended values by storage type.

**Mitigation:** Set `SCAN_WORKERS` appropriately for your storage:
- HDD: 4–6
- SSD: 8–12
- NVMe: 12–16

---

### SCAN_WORKERS = 1

**Scenario:** Only one worker is configured.

**Behavior:** Files are scanned serially. The C extension's GIL release doesn't help (single thread = no parallelism anyway), but it doesn't hurt either.

**Impact:** Slowest possible scan (but correct). Pure Python would be similar speed.

**Mitigation:** Increase `SCAN_WORKERS` to your core count or higher.

---

### SKIP_HASH_CALCULATION Enabled

**Scenario:** RomM is configured with `SKIP_HASH_CALCULATION: true` in config.yml.

**Behavior:** The handler's `calculate_hashes` flag is False, so no hashes are computed (C extension is never called).

**Impact:** Scans are very fast (no I/O or hashing), but no hashes are stored. This is a deliberate RomM feature for testing or large libraries where hashes aren't needed.

**Compatibility:** The plugin works fine — it just has nothing to hash. The cache (Tier-0) is never invoked (requires `calculate_hashes=True`).

---

## Monitoring & Debugging

### How to Check Which Tier Is Active

**Tier-1 (exact SHA match):**
```
[fast-scan] Installed roms_handler.py (exact match: 4.9.2.py)
```

**Tier-2 (patch applied):**
```
[fast-scan] Applied roms_handler.py patch
```

**Tier-3 (fallback, pure Python):**
```
[fast-scan] WARNING: Could not patch roms_handler.py.
            RomM has likely updated. The C extension is compiled but
            hashing falls back to pure Python until you update the plugin.
```

---

### How to Check if the C Extension Is Being Used

Inside the container:
```sh
python3 -c "
  try:
    import _fasthash
    print('C extension imported successfully')
    # Try hashing a file
    crc, md5, sha1 = _fasthash.hash_file('/path/to/a/rom.rom')
    print(f'Hashing works: {len(md5)} char MD5')
  except Exception as e:
    print(f'C extension failed: {e}')
    print('Falling back to pure Python')
"
```

---

### How to Check if the Cache Is Active

Inside the container:
```sh
python3 -c "
  import os
  os.environ['FAST_SCAN_HASH_CACHE'] = '1'
  import fast_scan_cache as c
  print(f'Cache enabled: {c.is_enabled()}')
  result = c.cached_file_hash(1, '/tmp', 'test.rom')
  print(f'Lookup result (should be None for missing file): {result}')
"
```

---

## Summary Table

| Scenario | Behavior | Impact | Mitigation |
|---|---|---|---|
| Archive file | Always Python | None (rare) | None |
| Multi-file ROM | Per-file C, aggregate Python | Minimal | None |
| CHD file | C extension for raw file, metadata separate | None | None |
| Size+mtime collision | Cache miss, file re-hashed | Very low likelihood | Manual re-hash or disable cache |
| Network storage clock skew | Spurious cache misses | Safe but slower | Disable cache on NFS |
| Patch fails | Fall back to pure Python | Slower, no errors | Run `refresh.sh` |
| .so corrupted | Import fails, Python fallback | Slower | Delete .so, recompile |
| Cache module missing | Cache disabled | C extension still works | Verify `install.sh` |
| SCAN_WORKERS too high | I/O bottleneck | Slower than optimal | Tune for storage type |
| SKIP_HASH_CALCULATION enabled | No hashing (intentional) | None | None |

