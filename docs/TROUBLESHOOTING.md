# Troubleshooting Guide

## Common Issues & Solutions

---

## Installation Issues

### `cp: cannot create directory '/opt/romm/fast-scan-plugin/lib': Permission denied`

**Cause:** The plugin directory is owned by a different user or has restrictive permissions.

**Solution:**
```sh
# Ensure you have write access to the plugin directory
sudo chown -R $(whoami) /opt/romm/fast-scan-plugin
chmod -R u+w /opt/romm/fast-scan-plugin

# Then re-run install.sh
sh install.sh
```

---

### `patch_romm_yaml.py: romm.yml not found`

**Cause:** Running the script from the wrong directory.

**Solution:**
```sh
# Run from the directory containing your romm.yml
cd /home/manager/deployments/romm
python3 /path/to/patch_romm_yaml.py
```

Or specify the path explicitly:
```sh
python3 /path/to/patch_romm_yaml.py /home/manager/deployments/romm/romm.yml
```

---

### `Patch failed — anchor text not found`

**Cause:** The `romm.yml` structure is unexpected (maybe already patched, or a custom variant).

**Solution:**
1. Check if already patched:
   ```sh
   grep -q "/romm-plugin/start.sh" romm.yml && echo "Already patched"
   ```

2. If already patched, no action needed — the pod YAML is ready.

3. If not patched but has unexpected structure, manually add the plugin configuration. Compare your `romm.yml` against [examples/romm.patched.example.yml](examples/romm.patched.example.yml) and apply the changes shown in the example.

---

## Startup Issues

### `[fast-scan] Compiling _fasthash extension ... Compile failed`

**Cause:** `gcc` or required headers (`openssl-dev`, `zlib-dev`, `musl-dev`) are not available.

**Possible reasons:**
- Container has no internet access (can't `apk add`)
- Alpine packages are not available in your region
- Custom base image missing build tools

**Solution:**
```sh
# Option 1: Ensure internet access on first boot
# (The plugin will apk add gcc automatically)

# Option 2: Pre-install build tools in a custom Dockerfile
FROM docker.io/rommapp/romm:latest
RUN apk add --no-cache gcc musl-dev openssl-dev zlib-dev
# Then rebuild your image

# Option 3: Accept pure Python fallback
# RomM will work normally, just 3–5× slower
# Once working, you can update the image and remove gcc
```

**Impact:** RomM scans at pure Python speeds. Not an error — graceful fallback.

---

### `[fast-scan] Applied roms_handler.py patch` but plugin is slow

**Cause:** The patch was applied, but the C extension may not have compiled successfully (check logs).

**Solution:** Check the full startup logs:
```sh
podman logs <romm-app-container-id> 2>&1 | grep -i "fasthash\|compile\|fast-scan"
```

If you see `Compile failed`:
- Verify internet access and try restarting the pod
- Or, check if the `.so` is present: `ls /romm-plugin/lib/_fasthash*.so`

---

### `WARNING: Could not patch roms_handler.py`

**Cause:** RomM was updated to a version the plugin doesn't recognize, and the unified diff patch no longer applies.

**Solution:**
```sh
# Inside the container, run the refresh helper:
podman exec <romm-app-container-id> sh /romm-plugin/refresh.sh

# Restart the pod to use the updated patch:
podman pod stop romm-pod && podman pod rm romm-pod && podman play kube romm.yml
```

The `refresh.sh` script will:
1. Re-apply the fast-scan changes to the new RomM version
2. Update `roms_handler.patch` and `known_sha256.txt`
3. Store a new pre-patched version for future boots

**Impact:** RomM runs with pure Python hashing until you run `refresh.sh`. No data is at risk.

---

## Scanning Issues

### Scan hangs or never completes

**Possible causes:**

1. **SCAN_WORKERS too high:** Workers are waiting for I/O.
   ```sh
   # Check your setting in the pod YAML
   grep -A1 "SCAN_WORKERS" romm.yml
   
   # Reduce to 4–6 for HDD, 8–12 for SSD
   ```

2. **Library is on slow/unavailable storage.**
   ```sh
   # Check if the library mount is responding
   podman exec <romm-app-container-id> ls /path/to/library | head -5
   ```

3. **Semaphore deadlock (very rare).**
   ```sh
   # Restart the pod
   podman pod stop romm-pod && podman pod rm romm-pod && podman play kube romm.yml
   ```

**Solution:** Reduce `SCAN_WORKERS`, verify storage access, and check disk space (scans may fail if the drive is full).

---

### File hashes are different on each scan

**Possible causes:**

1. **File is actually changing:** Check the file's mtime:
   ```sh
   stat /path/to/rom.rom
   ```

2. **Cache is reusing stale hashes (rare):**
   - Disable cache: `FAST_SCAN_HASH_CACHE=0` in the pod YAML
   - Restart and rescan
   - If hashes stabilize, it was a cache issue (report this)

3. **Corrupted .so or import error:**
   ```sh
   podman exec <romm-app-container-id> python3 -c "
     import _fasthash
     print('C extension OK')
   " 2>&1 || echo "C extension failed — check logs"
   ```

**Solution:**
- Verify the file hasn't changed: `md5sum /path/to/rom.rom` before and after a scan
- If the file is stable but hashes differ, delete the `.so` and recompile:
  ```sh
  podman exec <romm-app-container-id> rm -f /romm-plugin/lib/_fasthash*.so
  podman pod stop romm-pod && podman pod rm romm-pod && podman play kube romm.yml
  ```

---

### Cache seems to not be working (every rescan is slow)

**Possible causes:**

1. **Cache is disabled:**
   ```sh
   podman exec <romm-app-container-id> python3 -c "
     import os
     print('FAST_SCAN_HASH_CACHE:', os.environ.get('FAST_SCAN_HASH_CACHE', 'unset'))
   "
   ```

2. **Cache module not found:**
   ```sh
   podman exec <romm-app-container-id> python3 -c "
     import fast_scan_cache
     print('Cache module OK')
   " 2>&1 || echo "Cache module not found"
   ```

3. **Storage is too fast:** Cache benefits are negligible on NVMe.

4. **Clock skew (network storage):** mtime is changing between boots.

**Solution:**
```yaml
# In your pod YAML, add/verify:
- name: FAST_SCAN_HASH_CACHE
  value: "1"
```

Then restart and run a rescan twice:
```sh
# First rescan (all files read)
# Second rescan (should be much faster if cache works)
time podman exec <romm-app-container-id> RomM rescan --type=complete
```

If the second rescan is still slow, clock skew or storage-type issues may be preventing cache hits. Check [EDGE_CASES.md](EDGE_CASES.md) for mitigation.

---

## Database Issues

### `database.db` is corrupted or has integrity errors

**Symptom:** RomM shows strange hash values or scans fail with database errors.

**Solution:**
```sh
# Backup the DB
cp /path/to/romm/data/database.db /path/to/romm/data/database.db.backup

# Restart the pod (RomM will attempt recovery)
podman pod stop romm-pod && podman pod rm romm-pod && podman play kube romm.yml

# Check logs for errors
podman logs <romm-db-container-id>

# If still broken, restore from backup
# (You may lose recent scans, but data is safe)
```

The plugin doesn't corrupt the DB (it only reads and writes standard RomM columns), so this is usually a pre-existing issue or a problem with the MariaDB container.

---

### Cache query fails with database error

**Symptom:** Logs show exceptions in `fast_scan_cache` lookups.

**Cause:** Database schema changed or is temporarily unavailable.

**Solution:** The cache is fail-safe — exceptions are caught and return `None`, so hashing falls back to the normal path. No action needed, but if this happens repeatedly:

1. Check database health:
   ```sh
   podman exec <romm-db-container-id> mariadb -u root -p$MARIADB_ROOT_PASSWORD -e "SELECT 1;"
   ```

2. Check RomFile table exists:
   ```sh
   podman exec <romm-db-container-id> mariadb -u root -p$MARIADB_ROOT_PASSWORD -e "DESCRIBE romm.rom_files;" 2>&1 | head
   ```

3. If schema is broken, you may need to restore from a backup or reinitialize the database.

---

## Performance Issues

### Scans are slower than before (regression)

**Possible causes:**

1. **C extension not being used:** Check tier (see [EDGE_CASES.md](EDGE_CASES.md) § "How to Check Which Tier Is Active").

2. **SCAN_WORKERS too low:** Check the setting in your pod YAML.
   ```yaml
   - name: SCAN_WORKERS
     value: "4"  # or higher for SSD
   ```

3. **Library moved to slower storage:** HDD vs SSD makes a huge difference.

4. **Unrelated RomM slowness:** Check if other parts of RomM are slow (metadata fetching, UI).

**Solution:**
- Verify the C extension is active: `podman logs <romm-app-container-id> 2>&1 | grep -E "Built:|Cached:"`
- Increase `SCAN_WORKERS` if appropriate for your storage
- Benchmark a single 1 GB file against pure Python (see [TESTING.md](TESTING.md))

---

### Cache hit ratio is low (still slow after second rescan)

**Possible causes:**

1. **Files are changing on disk:** The files aren't actually unchanged.
   ```sh
   # Compare mtimes across two scans
   find /path/to/library -type f -newer /tmp/marker 2>/dev/null | wc -l
   ```

2. **Clock skew (network storage):** mtime differs between client and server.

3. **Files are in multi-file ROMs:** Cache only applies to single-file ROMs.
   ```sh
   # Count single vs multi-file ROMs in your DB
   # (This requires SQL access — check your database)
   ```

**Solution:**
- Verify files aren't changing: Run scans hours apart, not back-to-back
- For network storage, disable cache: `FAST_SCAN_HASH_CACHE=0`
- Check what fraction of your library is single-file vs multi-file (cache only helps the single-file portion)

---

## Update / Upgrade Issues

### After updating RomM, plugin no longer works

**Symptom:** Pod starts but warns `"Could not patch roms_handler.py"` or starts very slowly.

**Cause:** RomM version changed, and the pre-patched file SHA doesn't match.

**Solution:**
```sh
# Run refresh.sh inside the new container
podman exec <romm-app-container-id> sh /romm-plugin/refresh.sh

# Restart the pod
podman pod stop romm-pod && podman pod rm romm-pod && podman play kube romm.yml
```

This will:
- Generate a new patch if the old one doesn't apply
- Update `known_sha256.txt` to recognize the new version
- Store a pre-patched version for the next boot

---

### `refresh.sh` reports cache injection failed

**Symptom:**
```
[refresh] WARNING: could not inject hash-skip cache — fast path still works,
          but FAST_SCAN_HASH_CACHE will be a no-op on this version.
```

**Cause:** The new RomM version's `roms_handler.py` structure doesn't match expected anchors.

**Solution:** The fast path (C extension) still works — only the cache is disabled. This is safe.

To fix, open an issue on the repo with:
- Your RomM version
- The output of `podman exec ... sh /romm-plugin/refresh.sh`

---

## Diagnostics & Reporting

### How to gather logs for debugging

```sh
# Full pod logs
podman logs <romm-app-container-id> > /tmp/romm-logs.txt 2>&1

# Database logs (if available)
podman logs <romm-db-container-id> > /tmp/db-logs.txt 2>&1

# Plugin-specific logs
podman logs <romm-app-container-id> 2>&1 | grep -i "fast-scan\|fasthash\|cache" > /tmp/plugin-logs.txt

# File the above along with:
# - Your RomM version (docker inspect image or podman run ... --version)
# - Library size and storage type (HDD/SSD/NFS)
# - SCAN_WORKERS setting
# - FAST_SCAN_HASH_CACHE enabled/disabled
```

---

### Minimal reproduction example

If you encounter a bug, help us reproduce it:

1. **Exact RomM version:**
   ```sh
   podman exec <romm-app-container-id> python3 -c "
     import importlib.metadata
     print(importlib.metadata.version('romm'))
   "
   ```

2. **Single test file:** Provide a small ROM that exhibits the problem (or describe its characteristics: size, format, multi-file, etc.).

3. **Steps to reproduce:**
   - Install plugin
   - Configure X (e.g., cache enabled, SCAN_WORKERS=4)
   - Run scan Y
   - Observe unexpected behavior Z

4. **Logs:** Include the startup logs and scan logs from the steps above.

---

## When All Else Fails

### Disable the plugin temporarily

If you need RomM to work immediately and the plugin is causing issues:

```sh
# Remove the plugin command from the pod YAML
# Change:  command: ["/romm-plugin/start.sh"]
# To:      (comment it out or delete the line)

# Then restart:
podman pod stop romm-pod && podman pod rm romm-pod && podman play kube romm.yml
```

RomM will start normally (without the plugin, at standard speed). You can re-enable it once you've diagnosed the issue.

### Reset to a known-good state

```sh
# Delete all plugin files
rm -rf /opt/romm/fast-scan-plugin

# Restore the original romm.yml
cp /home/manager/deployments/romm/romm.yml.bak.YYYYMMDD_HHMMSS /path/to/romm.yml

# Restart
podman pod stop romm-pod && podman pod rm romm-pod && podman play kube romm.yml
```

Then re-install from scratch if desired.

---

## Contact & Support

- **GitHub Issues:** https://github.com/zeldafan3421/romm-fast-scan/issues
- **RomM Project:** https://github.com/rommapp/romm (for RomM-specific issues)

When opening an issue, include:
- Plugin version (commit hash or date)
- RomM version
- Library size and storage type
- Reproduction steps
- Full logs (startup + scan)

