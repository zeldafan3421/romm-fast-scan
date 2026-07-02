# Pre-Deployment Checklist & Known Risks

Use this checklist **before deploying the plugin to your production RomM instance.**

---

## Prerequisites

- [ ] **Backup your RomM data** — database, config, library metadata
  ```sh
  # Backup database
  cp /path/to/romm/data/database.db /backups/database.db.$(date +%Y%m%d)
  
  # Backup pod YAML
  cp /path/to/romm.yml /backups/romm.yml.backup
  
  # Backup plugin dir (if it exists)
  cp -r /opt/romm/fast-scan-plugin /backups/fast-scan-plugin.backup
  ```

- [ ] **RomM is stable and working** — run a successful scan before installing the plugin to establish a baseline

- [ ] **Disk space is sufficient**
  ```sh
  # Check free space in plugin directory and library
  df -h /opt/romm /path/to/library
  
  # Native plugins need ~5 MB; logs during first compile may use more
  ```

- [ ] **Read the essential documentation:**
  - [x] README.md — understand what the plugin does
  - [x] TESTING.md § "What to Document" — know what to record
  - [x] EDGE_CASES.md — understand limitations

---

## Installation Phase

- [ ] **Create plugin directory with correct permissions**
  ```sh
  mkdir -p /opt/romm/fast-scan-plugin
  chmod 755 /opt/romm/fast-scan-plugin
  ```

- [ ] **Run install.sh**
  ```sh
  sh install.sh
  
  # Verify files are present
  ls -la /opt/romm/fast-scan-plugin/plugins/fasthash/fasthash.c
  ls -la /opt/romm/fast-scan-plugin/plugins/archive-list/archive_list.c
  ls -la /opt/romm/fast-scan-plugin/overrides/prepatched/
  ```

- [ ] **If volume-mounting (self-built plugins), plan to allow unsigned plugins**
  Plugins compiled on-host or by `scripts/build-plugins.sh` are never signed (only this
  repo's CI holds the private signing key), and `plugin_manager.py` refuses to load an
  unsigned plugin by default. Add this to your pod YAML now, or the plugin will silently
  fall back to pure Python on first boot:
  ```yaml
  - name: FAST_SCAN_ALLOW_UNSIGNED_PLUGINS
    value: "1"
  ```
  See `plugins/README.md`'s "Signing and `FAST_SCAN_ALLOW_UNSIGNED_PLUGINS`" section.
  Not needed if you're deploying the prebuilt `ghcr.io/zeldafan3421/romm-fast-scan` image —
  those plugins are already signed.

- [ ] **Patch romm.yml**
  ```sh
  python3 ../scripts/patch_romm_yaml.py
  
  # Verify the patch was applied
  grep -c "/romm-plugin/start.sh" romm.yml
  # Should output: 1
  ```

- [ ] **Verify pod YAML is valid**
  ```sh
  # Try to parse it as YAML
  python3 -c "import yaml; yaml.safe_load(open('romm.yml'))" && echo "Valid YAML"
  ```

---

## First Boot Phase

- [ ] **Restart the pod**
  ```sh
  podman pod stop romm-pod
  podman pod rm romm-pod
  podman play kube romm.yml
  ```

- [ ] **Monitor startup logs for the next 2 minutes**
  ```sh
  podman logs -f <romm-app-container-id> 2>&1 | grep -i "fast-scan"
  
  # Expected output (volume-mount / first-ever compile):
  # [fast-scan] Compiling fasthash -> libfasthash.so ...
  # [fast-scan] Built: /romm-plugin/plugins/fasthash/libfasthash.so
  # [fast-scan] Compiling archive-list -> libarchive_list.so ...
  # [fast-scan] Built: /romm-plugin/plugins/archive-list/libarchive_list.so
  # [fast-scan] Applied roms_handler.py patch
  # [fast-scan] PYTHONPATH=/romm-plugin/src:/backend
  # [fast-scan] Starting RomM...
  
  # Expected output (prebuilt ghcr.io image, or any later boot):
  # [fast-scan] All plugins cached, nothing to compile
  # [fast-scan] Installed roms_handler.py (exact match: 4.9.2.py)
  # [fast-scan] PYTHONPATH=/romm-plugin/src:/backend
  # [fast-scan] Starting RomM...
  
  # If you see [fast-scan] WARNING instead, the patch failed (see TROUBLESHOOTING.md)
  # If a plugin silently never gets used, it may have failed signature verification
  # rather than compilation — see TROUBLESHOOTING.md and plugins/README.md's
  # "Signing and FAST_SCAN_ALLOW_UNSIGNED_PLUGINS" section.
  ```

- [ ] **Verify RomM web UI is responsive**
  ```sh
  curl -s http://localhost:8080 | head -20
  
  # Should return HTML (not timeout, not 500 error)
  ```

- [ ] **Check database is intact**
  ```sh
  podman exec <romm-app-container-id> python3 -c "
    from handler.database import db_platform_handler
    platforms = db_platform_handler.get_platforms()
    print(f'Database OK: {len(platforms)} platforms found')
  " 2>&1
  ```

---

## First Scan Phase (Without Cache)

- [ ] **Run a quick scan on a small platform**
  ```sh
  # In the web UI, select a platform with 10–50 games
  # Run "New Roms" or "Quick" scan
  # Monitor logs:
  podman logs -f <romm-app-container-id> 2>&1 | tail -20
  ```

- [ ] **Verify hashes are computed and reasonable**
  ```sh
  # Pick a ROM file and manually check its hash
  ROMPATH="/path/to/library/NES/Super Mario Bros.nes"
  
  md5_from_romm="<copy from RomM web UI>"
  md5_from_disk=$(md5sum "$ROMPATH" | awk '{print $1}')
  
  if [ "$md5_from_romm" = "$md5_from_disk" ]; then
    echo "✓ Hash matches"
  else
    echo "✗ Hash mismatch: expected $md5_from_disk, got $md5_from_romm"
  fi
  ```

- [ ] **Record timing of the first scan**
  ```sh
  # Time a full "Complete" scan of a small platform
  # Record: platform name, game count, duration, SCAN_WORKERS value
  
  # Example:
  # Platform: NES (523 games)
  # Duration: 3 minutes 45 seconds
  # SCAN_WORKERS: 4
  ```

---

## Cache Setup Phase (If Enabled)

- [ ] **Enable cache in pod YAML** (optional; can skip if you want the native plugin only)
  ```yaml
  - name: FAST_SCAN_HASH_CACHE
    value: "1"
  ```

- [ ] **Restart the pod**
  ```sh
  podman pod stop romm-pod && podman pod rm romm-pod
  podman play kube romm.yml
  
  # Wait for startup
  sleep 10
  ```

- [ ] **Verify cache is enabled**
  ```sh
  podman exec <romm-app-container-id> python3 -c "
    import os
    print('Cache enabled:', os.environ.get('FAST_SCAN_HASH_CACHE', 'unset'))
  " 2>&1
  ```

- [ ] **Run the same scan again (should be faster)**
  ```sh
  # In the web UI, run the same "Complete" scan on the same platform
  # Record timing: should be 5–10× faster than the first run
  
  # If not faster, check TROUBLESHOOTING.md § "cache seems to not be working"
  ```

---

## Validation Phase

- [ ] **All hashes are consistent**
  ```sh
  # Do two back-to-back complete rescans
  # All hashes should be identical (same MD5, CRC, SHA1 as previous scan)
  
  # If any ROM has different hashes:
  # - First rescan: natural, new computation
  # - Second rescan: hashes identical to first rescan? (check for stability)
  # - If still changing: file is actually changing on disk (check permissions)
  ```

- [ ] **No errors in logs**
  ```sh
  podman logs <romm-app-container-id> 2>&1 | grep -i "error\|exception\|traceback"
  
  # Some errors are OK (e.g., "file not found" for deleted ROMs)
  # But exceptions in fast-scan code should not appear
  ```

- [ ] **Performance is better (or at least not worse)**
  ```sh
  # Compare timings:
  
  # Without plugin (stock RomM):
  #   First rescan: X minutes
  #   Workers: N
  
  # With plugin:
  #   First rescan: X/2 to X/5 minutes (native fasthash plugin speedup)
  #   With cache enabled:
  #   Second rescan: X/10 to X/50 minutes (cache + native fasthash plugin)
  
  # If slower than stock, something is wrong (see TROUBLESHOOTING.md)
  ```

- [ ] **Your library size and characteristics**
  ```sh
  # Document your setup for future reference/debugging
  
  # Run this inside the container:
  podman exec <romm-app-container-id> python3 -c "
    from handler.database import db_platform_handler, db_rom_handler
    platforms = db_platform_handler.get_platforms()
    total_roms = sum(p.rom_count for p in platforms)
    print(f'Total platforms: {len(platforms)}')
    print(f'Total ROMs: {total_roms}')
    print(f'Storage: HDD/SSD/NFS (yours)')
    print(f'SCAN_WORKERS: 4 (yours)')
  " 2>&1
  ```

---

## Known Risks & Mitigations

### Risk: Native Plugin Doesn't Compile (Impact: Medium — slower but still works)

**Preconditions:** Volume-mount install only — prebuilt `ghcr.io` images ship every plugin precompiled, so this never applies to them.

**Mitigation:**
- [ ] Ensure container has internet access on first boot
- [ ] If it fails, check logs: `podman logs <romm-app-container-id> 2>&1 | grep -i "compile\|fast-scan"`
- [ ] Restart the pod; the second boot may succeed if the first failed due to transient network issues
- [ ] If persistent, you can still use the plugin (pure Python fallback)

---

### Risk: Plugin Not Signed (Impact: Medium — plugin silently falls back to pure Python)

**Preconditions:** Volume-mount install, or a locally-built image (Option B) — either way you built the `.so` yourself, and only this repo's CI holds the private signing key, so `plugin_manager.py` refuses to load it by default.

**Mitigation:**
- [ ] Set `FAST_SCAN_ALLOW_UNSIGNED_PLUGINS: "1"` in your pod YAML before first boot
- [ ] If you'd rather not run unsigned native code, extract the already-signed `.so`+`.sig` out of the published `ghcr.io` image instead of rebuilding (`podman cp`/`docker cp`)
- [ ] See `plugins/README.md`'s "Signing and `FAST_SCAN_ALLOW_UNSIGNED_PLUGINS`" section

---

### Risk: Patch Doesn't Apply After RomM Update (Impact: Medium — slower but still works)

**Mitigation:**
- [ ] Always check startup logs for `[fast-scan] WARNING`
- [ ] If the warning appears, run `refresh.sh` inside the container immediately
- [ ] Know how to disable the plugin if needed: comment out `command:` in pod YAML and restart

---

### Risk: Hash Cache Reuses Stale Hashes (Impact: Low — rare edge case)

**Preconditions:** A file is edited in-place to preserve both size and mtime (very rare).

**Mitigation:**
- [ ] If you suspect this happened (hashes seem wrong), disable cache: `FAST_SCAN_HASH_CACHE=0`
- [ ] Do a `Complete` rescan (not just `Rescan hashes`)
- [ ] Hashes should now be correct
- [ ] Re-enable cache if you want it

---

### Risk: Database Corruption (Impact: High — but not caused by plugin)

**Preconditions:** MariaDB container crashes, network storage failure, etc. (pre-existing risk, not introduced by plugin).

**Mitigation:**
- [ ] Regular backups of `/path/to/romm/data/database.db`
- [ ] Test restore procedure before relying on it
- [ ] If corruption is suspected, restore from backup and inform RomM developers

---

### Risk: Concurrency Issues (Impact: Very Low — semaphore serializes ROM processing)

**Preconditions:** Two scans started simultaneously on the same ROM (unlikely via web UI).

**Mitigation:**
- [ ] The plugin's semaphore and RomM's concurrency controls prevent this
- [ ] If it somehow happens, no data corruption occurs (just race on DB writes)
- [ ] Restart the pod if you're concerned

---

### Risk: File Permission Errors (Impact: Medium — some ROMs won't scan)

**Preconditions:** Plugin directory or library files have restrictive ownership/permissions.

**Mitigation:**
- [ ] Before install: `ls -la /opt/romm/fast-scan-plugin` should be readable by the RomM process
- [ ] Before first scan: `ls -la /path/to/library` should be readable by the RomM process
- [ ] If errors appear in logs (`Permission denied`), fix permissions:
  ```sh
  chmod -R 755 /opt/romm/fast-scan-plugin
  chmod -R 755 /path/to/library
  ```

---

## Rollback Procedure (If Something Goes Wrong)

If the plugin causes problems, you can disable it quickly:

```sh
# 1. Restore the original pod YAML
cp /backups/romm.yml.backup romm.yml

# 2. Restart the pod (this removes the plugin from the startup path)
podman pod stop romm-pod && podman pod rm romm-pod
podman play kube romm.yml

# 3. RomM will start normally (without the plugin)
# All your data is safe; you just won't get the speedup

# 4. Troubleshoot:
# - Check logs: podman logs <romm-app-container-id>
# - Read TROUBLESHOOTING.md and EDGE_CASES.md
# - Try again with different settings (e.g., SCAN_WORKERS=2)
```

---

## Ongoing Maintenance

After deployment, periodically check:

- [ ] **Logs for warnings:** `podman logs <romm-app-container-id> 2>&1 | grep WARNING`
- [ ] **Database health:** Scans complete without errors
- [ ] **Disk space:** Cache and logs don't fill the disk
- [ ] **After RomM updates:** Check if patch still applies; run `refresh.sh` if needed

---

## Success Criteria

Your deployment is successful when:

✅ RomM starts without errors (check logs)  
✅ Scans complete without errors (check logs)  
✅ Hashes are correct (verified against manual `md5sum` on a few files)  
✅ Performance improved (native `fasthash` plugin: 2–5× faster; cache: 5–10× faster on second scan)  
✅ No new warnings or exceptions in logs  
✅ Database integrity is maintained (no duplicate entries, hashes don't jump around)  

---

## Deployment Completed

Once all checks pass:

- [ ] Save the current state (note the date, RomM version, library size)
- [ ] Archive logs for future reference
- [ ] Schedule regular backups
- [ ] If performance is good, you can enable cache for even faster rescans

---

## Still Having Issues?

→ Check [TROUBLESHOOTING.md](TROUBLESHOOTING.md)  
→ Review [EDGE_CASES.md](EDGE_CASES.md) for limitations  
→ See [TESTING.md](TESTING.md) for diagnostic procedures  

