# Architecture & Internals

## Overview

romm-fast-scan optimizes RomM's ROM scanning through a small **native plugin system** layered on top of a resilient source patch, plus one independent opt-in cache:

1. **Tier-0: Hash Cache** — reuse stored file hashes when size+mtime unchanged (opt-in, `FAST_SCAN_HASH_CACHE`)
2. **Tier-1: Native Plugin** — compute CRC32/MD5/SHA1 in a single file pass via a signed, GIL-free C-ABI plugin
3. **Tier-3: Pure Python** — stock RomM fallback (no optimization)

(Tier-2 is the unified diff patch, a resilience mechanism for keeping the source integration working across RomM releases — see "The Source Patch" below.)

Each tier is independent and fail-safe — any failure falls through to the next tier. This document covers the mechanics; see `plugins/README.md` for how to write or modify a plugin, and `CLAUDE.md` for contributor-facing conventions and the project's longer-term roadmap.

**A note on history:** earlier versions of this project shipped a single CPython C-extension (`src/_fasthash.c`) that was `import`ed directly into RomM's Python process, tied to RomM's exact Python minor version and rebuilt whenever that changed. That extension has been fully removed and replaced by the plugin system described below — if you find a reference to `_fasthash`, `_fh`, or a `/romm-plugin/lib/` directory anywhere, it's stale; the current design has no CPython extension at all.

---

## Tier-0: Hash Cache (`src/fast_scan_cache.py`)

### When It Applies

- Single-file ROMs (multi-file ROMs fall through to tier-1)
- Enabled via `FAST_SCAN_HASH_CACHE=1` environment variable (default off)
- Only on `COMPLETE` or `RESCAN_HASHES` scan types (incremental scans skip unchanged ROMs anyway)

### How It Works

```
On each file being hashed:
  1. stat(file) → size, mtime
  2. Query RomFile(rom_id, file_name) from DB
  3. Compare:
     - If size matches AND mtime within epsilon → return stored (crc, md5, sha1, chd_sha1)
     - Otherwise → return None (fall through to tier-1)
```

### Key Design Decisions

**Why opt-in?**
- False negative edge case: file edited in-place preserving size+mtime won't be re-hashed
- This is rare (requires deliberate tools like rsync --times), but possible
- Safer to default off; users can opt-in when they understand the trade-off

**Why compare size+mtime, not hash?**
- Computing a "compare hash" requires reading the file, defeating the purpose
- Size+mtime are much faster to check (stat call)
- They're good proxies for "file unchanged" (false positives are extremely rare)

**Why epsilon on mtime?**
- mtime is stored as a float in the DB; floating-point round-trip introduces tiny errors
- 1e-6 second epsilon absorbs these errors without catching real changes
- Typical filesystem granularity is 1 second, so the epsilon is ultra-conservative

**Sync session vs ORM relationship:**
- The handler's `rom` object is lazy-loaded with `lazy="raise"` on `.files`
- We can't access `rom.files` without triggering an out-of-session error
- Instead, we use `sync_session` to directly query the `RomFile` table by `rom_id` + `file_name`
- This is safe and isolated — a query failure returns `None` and falls through

### Fail-Safety

Every check is wrapped in try/except:
- `os.stat()` fails on missing file → `None` → fall through
- DB import fails (module moved) → `None` → fall through
- Database error (query, schema) → `None` → fall through
- Stored hashes empty or missing → `None` → fall through

**Result:** Cache can never produce a wrong hash. At worst, it's a no-op. This tier is entirely independent of the plugin system below it — it works (or doesn't) regardless of whether any plugin is loaded.

---

## The Plugin System

### ABI Contract (`include/romm_plugin_abi.h`)

A plugin is a shared library (`.so`) exposing a small, versioned C ABI — `extern "C"` functions, only primitives/fixed-size buffers/structs-of-primitives crossing the boundary, no exceptions escaping, every hook returning a status code (`0` = success, nonzero = failure). Nothing about the ABI requires C or C++: any language that can produce a proper `extern "C"`-equivalent shared library qualifies (Rust as a `cdylib`, Go with `-buildmode=c-shared`, Zig, and others, in addition to C/C++) — proven live by loading a plugin built with a bare `cc` invocation entirely outside this repo's own build tooling.

Every plugin `.so` must export `romm_plugin_abi_version(void)`. The loader cross-checks this against what the plugin's `plugin.json` manifest claims *and* against what the loader itself supports — a mismatch in either direction gets the whole plugin skipped and logged, never partially loaded.

Three hooks exist today:
- **`hash_file`** — one file in, three hex digests out (`romm_hash_file`). The only hook currently wired into RomM's actual scan path.
- **`hash_file_accum`** — an opaque-handle accumulator for combining several files into one digest (multi-disc ROMs), mirroring the shape of the old CPython extension's `MultiFileHasher` Python type but implemented as four plain C functions (`romm_hash_accum_new`/`_file`/`_finalize`/`_free`) called through `ctypes` instead of a Python class. Implemented, loads correctly, **not currently called anywhere in `roms_handler.py`** — multi-disc ROMs still hash via the stock per-file Python path today.
- **`archive_list`** — lists a ZIP's members (name, sizes, stored CRC32) without decompressing anything. Implemented, loads correctly, **not currently wired into RomM's scan path** — exists to prove the plugin system generalizes beyond hashing, doesn't yet replace the actual decompress-and-hash work the archive branch does today.

See `CLAUDE.md`'s "Roadmap: incremental backend replacement" section for where the unwired hooks (and future ones — cover/thumbnail resizing, fuzzy metadata matching are named candidates with no code yet) fit into the longer-term plan.

### The Loader (`src/plugin_manager.py`)

Discovers every `plugins/*/plugin.json` (finalized manifests only — a directory with just source and no finalized manifest is invisible to it), and for each one, in order:

1. Verifies the `.so`'s sha256 matches what the manifest claims (tamper/corruption check)
2. **Verifies the `.so`'s cryptographic signature** (see "Signing" below) — this is the one check in this codebase that does *not* fail open by default
3. Verifies ABI version agreement (manifest vs binary vs what this loader supports)
4. Loads the `.so` via `ctypes.CDLL` and binds each declared hook to a Python-callable wrapper

Any failure at any step is logged and that plugin (or just that hook, if only one hook's binding fails) is skipped — never a hard error, never blocks RomM from starting. `plugin_manager.hash_file(path)` (and the other public hook-dispatch functions) return `None` on any failure or absence; callers fall back to pure Python. Because `ctypes` automatically releases Python's GIL for the duration of any foreign-function call, a plugin's C code doesn't need to do anything special to enable real parallelism across `SCAN_WORKERS` — unlike the old CPython extension, which had to manually bracket its hashing loop in `Py_BEGIN_ALLOW_THREADS`/`Py_END_ALLOW_THREADS` since it ran *inside* the interpreter.

**Per-call cost of the `ctypes` path.** Dispatching through `ctypes` (libffi + the per-call Python wrapper that allocates the output buffers and encodes/decodes the strings) costs slightly more per call than the old CPython extension did — the old one called through the native C-API and built its result in C. Measured by `tests/call_overhead.py`: ~2 µs new-vs-old differential per `hash_file` call, which is <1% of hash time above ~130 KiB and only a few percent on very small carts. It's the deliberate, understood cost of dropping CPython-ABI coupling (see CLAUDE.md's "Why `ctypes`, and what it costs"), not a regression; the wrapper is the optimizable part if it ever matters.

### The `fasthash` Plugin (`plugins/fasthash/fasthash.c`)

**Single-pass hashing:**
```c
BUF_SIZE = 256 KB  // Read buffer, a deliberate sweet spot -- don't change without re-benchmarking

for each 256 KB chunk:
  crc32_update(chunk)
  md5_update(chunk)
  sha1_update(chunk)

return (crc_hex, md5_hex, sha1_hex)
```
Stock Python hashes a file by calling `hashlib.md5()` then re-reading for `hashlib.sha1()`, etc. — for a large file on slow storage, reading three times is three times slower than reading once.

**Hash algorithms:** CRC32 via zlib; MD5 and SHA1 via OpenSSL's EVP API (`EVP_MD_CTX_copy` allows non-destructive finalization — read a digest without ending the ability to keep accumulating, needed for the multi-file accumulator hook).

**Concurrency:** `romm_hash_file`'s module-level function is stateless — each call touches only its own stack/heap, no locking needed. The multi-file accumulator's per-handle state (`AccumHandle`) *does* need locking if two threads might ever call methods on the *same* handle concurrently — protected by a `pthread_mutex_t`, a direct port of a pattern that was a real, ThreadSanitizer-confirmed data race in the old CPython-extension version before that lock existed.

**Exceptions & fallback:** a C function returns nonzero on any failure (missing file, read error, hashing error) rather than raising. The Python side wraps every call in `try/except` as a second line of defense on top of that:
```python
try:
    result = await asyncio.to_thread(_pm.hash_file, path)
    if result is not None:
        f_crc_hex, f_md5_hex, f_sha1_hex = result
        _used_fast_path = True
except Exception:
    pass  # fall through to the Python path below
```
No ROM is ever left without a hash — a plugin failure means slower, not wrong or missing.

### Signing

Official plugins (`fasthash`, `archive-list`) are cryptographically signed at build time using `ssh-keygen -Y sign`/`-Y verify` — the same primitive `git`'s `gpg.format=ssh` commit signing uses, chosen to avoid a new Python dependency (no `cryptography`/`pynacl`; this repo's Python is stdlib-only, and `ssh-keygen` is just another external CLI tool the way `patch`/`gcc` already are).

By default, `plugin_manager.py` **refuses to load any plugin that isn't signed by the official key** — this includes a plugin you build yourself from this repo's own source, since only this repo's CI holds the private key (`PLUGIN_SIGNING_KEY`, a GitHub Actions secret, never committed, never entering a Docker build context or image layer). Setting `FAST_SCAN_ALLOW_UNSIGNED_PLUGINS=1` opts back into the older, weaker sha256-only behavior — required for the volume-mount install path and any locally-built image, since neither can produce signed plugins. See `plugins/README.md`'s "Signing and `FAST_SCAN_ALLOW_UNSIGNED_PLUGINS`" section for the full mechanism, including how the private key stays out of the build (a `FROM scratch` `plugins-export` Containerfile stage lets CI extract just the built `.so`s for signing before any real image build runs).

This is the one check in the whole codebase that deliberately does *not* fail open toward "keep working, just slower" — an unverifiable signature fails toward "don't run this native code." It still composes with everything else here: a rejected plugin is just another reason a hook stays unavailable, and callers fall back to Python exactly as they would for any other rejection reason.

---

## The Source Patch (`roms_handler.patch`)

### Resilience Strategy

RomM's `roms_handler.py` is patched **once** — not per-plugin, not per-hook-addition to an existing hook — to call into `plugin_manager.hash_file(...)` instead of hashing in pure Python. Adding a new plugin behind an existing hook needs zero source changes; `plugin_manager.py` already dispatches into whatever's loaded. Only wiring in a genuinely *new* hook (like `archive_list` would need, if that's ever done) requires touching `roms_handler.py` again.

The patch itself uses the same three-tier strategy as always:

1. **On boot (`start.sh`):**
   - Container's `roms_handler.py` already contains `import plugin_manager as _pm`? → already patched (a previous boot's tier-1/tier-2 succeeded and persists across restarts of the same container, since `roms_handler.py` lives in the container's own filesystem, not a bind mount) → log success, done. Without this check, every restart after the first successful patch would otherwise re-attempt tier-1/tier-2 against an already-patched file, both of which correctly "fail" against it — this used to produce a real, misleading "Could not patch" warning claiming the fast path had been lost when it hadn't; fixed by checking for this marker first.
   - Exact SHA match against `known_sha256.txt`? → tier-1: copy the matching `overrides/prepatched/<version>.py` verbatim (fastest, safest)
   - `roms_handler.patch` applies via `patch --dry-run`? → tier-2: apply it (survives minor upstream changes)
   - Neither? → tier-3: log a warning, start RomM unmodified (pure Python hashing, never blocks boot)

2. **On RomM update (`scripts/refresh.sh`):** regenerates tier-1 (a fresh pre-patched file) and tier-2 (a fresh diff) together for a new RomM version, run manually inside a live container of that version, backing up before mutating anything.

### What the Patch Injects

```python
# After imports:
try:
    import plugin_manager as _pm
    _pm.load_plugins("/romm-plugin/plugins")
except Exception:
    _pm = None
try:
    import fast_scan_cache as _fsc
except Exception:
    _fsc = None

# After default hash constants:
_DEFAULT_MD5_HEX = hashlib.md5(usedforsecurity=False).hexdigest()
_DEFAULT_SHA1_HEX = hashlib.sha1(usedforsecurity=False).hexdigest()

# Variables for tier-0/tier-1 results:
rom_md5_hex: str | None = None   # set by plugin fast path; overrides rom_md5_h at return
rom_sha1_hex: str | None = None

# In the single-file branch, replace the old hashing call with:
#   _cache_hit = await asyncio.to_thread(_fsc.cached_file_hash, ...)     # tier-0
#   if _cache_hit is not None:
#       (use it)
#   else:
#       _plugin_result = await asyncio.to_thread(_pm.hash_file, path)   # tier-1
#       if _plugin_result is not None:
#           (use it)
#       else:
#           (tier-2/3 Python fallback, unchanged from stock)

# At return, prefer the hex overrides when set:
md5_hash=(
    rom_md5_hex
    if rom_md5_hex is not None
    else (python_fallback)
)
```

The patch is minimal because it preserves all surrounding logic — only inserting/replacing the hashing branch. It's regenerated by `scripts/refresh.sh` using anchor-based text insertion, not hand-maintained separately from `overrides/prepatched/*.py`; both are derived from the same source of truth for a given RomM version.

---

## Boot Sequence (`start.sh`)

```
1. Compile any plugin whose .so isn't already present
   - For each plugins/*/plugin.json.tmpl:
     - .so already there? → "Cached: ..." log line, skip (this is how CI's
       pre-built-and-signed artifacts survive into the final image without
       being silently recompiled and unsigned)
     - Otherwise → apk add gcc/musl-dev/... if needed, compile with cc,
       finalize plugin.json with the real sha256, apk del build tools after

2. Patch roms_handler.py (see "The Source Patch" above)
   a. Already patched? → done
   b. Exact SHA match? → copy pre-patched file (tier-1)
   c. Patch applies? → apply diff (tier-2)
   d. Neither? → warn and proceed without the fast path (tier-3)

3. Set PYTHONPATH=/romm-plugin/src:/backend
   - src/ holds plugin_manager.py and fast_scan_cache.py
   - plugin .so files are never imported as Python modules -- ctypes
     dlopen's them directly -- so they don't need to be on PYTHONPATH at all

4. Start RomM normally
   - exec /docker-entrypoint.sh /init
```

Each step logs to stdout (picked up by `podman logs`). On failure, the next step either works or falls back gracefully — nothing here can prevent RomM from starting.

---

## Refresh Sequence (`scripts/refresh.sh`)

Used when RomM is updated and the existing patch no longer applies cleanly:

```
1. Compute the new RomM version's roms_handler.py SHA256

2. Try the committed patch first (tier-2)
   - patch --dry-run to check if it still applies
   - If yes: apply it for real, record the new SHA -> overrides/prepatched/

3. If the patch doesn't apply, regenerate it
   - Anchor-based text insertion against the same set of anchors this
     patch always uses (plugin_manager import + load_plugins() call,
     _DEFAULT_*_HEX constants, the elif hashable_platform: branch calling
     _pm.hash_file(...), the tier-0 cache injection)
   - Builds the full patched file in Python, then re-derives
     roms_handler.patch as a diff between stock and patched

4. Verify the result
   - grep for "plugin_manager" in the regenerated file
   - python3 -c "import ast; ast.parse(...)" to confirm it's still valid Python

5. Store the result
   - Copy the patched file -> overrides/prepatched/<version>.py
   - Append the SHA to known_sha256.txt (append-only; existing entries
     for other versions are preserved)

6. On next boot: exact-SHA tier-1 copy works immediately, no
   regeneration needed for that version again
```

**Key insight:** `known_sha256.txt` is the single source of truth for which RomM versions this repo supports (`scripts/list_known_versions.py` reads it) — every version anyone has ever run `refresh.sh` against stays fast-path-capable indefinitely. See CLAUDE.md's "Versioning model" and "Roadmap: incremental backend replacement" sections for how this feeds the CI build matrix and the RomM 5.\*.\* compatibility commitment.

---

## Integration Points with RomM

### Patched File: `get_rom_files()`

The handler's main hashing method. The patch modifies the single-file hashing branch:

```python
async def get_rom_files(self, rom: Rom, calculate_hashes: bool = True):
    # ...
    elif hashable_platform:  # This is what the patch replaces
        # Tier-0: cache check (if _fsc enabled)
        # Tier-1: plugin_manager.hash_file() (if a plugin provides the hook)
        # Tier-2/3: Python fallback
```

All tiers return a `FileHash` namedtuple with `(crc_hash, md5_hash, sha1_hash, chd_sha1_hash)`, so downstream code is unchanged.

### Concurrency: SCAN_WORKERS

```python
scan_semaphore = asyncio.Semaphore(SCAN_WORKERS)

for rom in roms:
    scan_tasks.append(scan_rom_with_semaphore(rom))

await asyncio.gather(*scan_tasks)  # Run up to SCAN_WORKERS in parallel
```

Workers overlap during hashing because `ctypes` releases the GIL for the duration of the native call into the plugin. This is a *smaller* edge than it sounds: stock RomM's `hashlib`/`zlib` already release the GIL during the actual hash computation, so the plugin's win is the reduced per-file Python overhead, not a jump from "fully serialized" to "parallel." See the measured, reproducible numbers in `tests/` — the speedup is modest and workload-dependent, not a large multiplier.

---

## Database Schema (used by tier-0 cache)

`RomFile` table columns (from `models/rom.py`):
- `rom_id` — foreign key to Rom
- `file_name` — filename (e.g., "game.rom")
- `file_path` — relative directory path
- `file_size_bytes` — file size in bytes
- `last_modified` — mtime as float (seconds since epoch)
- `crc_hash` — CRC32 as hex string (nullable)
- `md5_hash` — MD5 as hex string (nullable)
- `sha1_hash` — SHA1 as hex string (nullable)
- `chd_sha1_hash` — CHD metadata hash (nullable)

The cache queries: `SELECT crc_hash, md5_hash, sha1_hash, chd_sha1_hash FROM rom_files WHERE rom_id = ? AND file_name = ? LIMIT 1`

---

## Performance Characteristics

### Tier-0 (Cache Hit)

- **Cost:** One `stat()` call (~1 ms on local disk, ~10 ms on NFS) + one DB query (~5 ms)
- **Speedup vs reading file:** 10–100× (no file I/O)
- **Applicable to:** ~100% of unchanged ROMs on second rescan

### Tier-1 (Native Plugin)

- **Cost:** Single file read (sequential I/O) + CRC32 + MD5 + SHA1 (CPU)
- **Speedup vs Python:** modest and workload-dependent — measured (warm cache, `tests/benchmark.py`) at ~parity for a single file, up to ~1.5–1.6× on many-small-file libraries at high `SCAN_WORKERS`, near-parity on few-large-file libraries, and less on cold spinning disk (I/O-bound). Not a large multiplier; run `sh tests/run.sh` for numbers on your hardware.
- **Applicable to:** 100% of changed ROMs, 100% of scans if the cache is disabled

### Tier-2/3 (Python Fallback)

- **Cost:** Multiple file reads (re-read for each hash) with the GIL held, serializing workers
- **Speedup:** None (this is the baseline)
- **Applicable to:** Archive files (always), or when no plugin is available/signed/loadable

The README's "How it works" section has the current headline number from real-world testing — check there rather than trusting a stale figure hardcoded into this file, since it can drift as the plugin evolves.

---

## Known Design Limitations

1. **Multi-disc ROMs:** the `hash_file_accum` hook exists and works (proven at the plugin-loader level) but isn't wired into `roms_handler.py`'s scan path yet — multi-file ROMs hash via the stock Python path today. Named in the roadmap, not started.

2. **Archive extraction:** always uses Python decompression — format-specific and not something a hashing plugin can help with directly. The `archive_list` hook (ZIP central-directory listing without decompression) exists and works but isn't wired in as a fast pre-check yet either.

3. **Network storage:** cache hits may be spurious if clock skew exists between client and server.

4. **Size+mtime collision:** a file edited in-place preserving both size and mtime will not be re-hashed by the tier-0 cache. Rare but possible with specialized tools.

5. **Self-built plugins are unsigned:** the volume-mount install path and any locally-built image (`scripts/build-image.sh`, `scripts/build-plugins.sh`) can never produce signed plugins — only this repo's CI holds the private key. `FAST_SCAN_ALLOW_UNSIGNED_PLUGINS=1` is required for those paths; this is intentional, not a bug, but worth knowing going in.

---

## Testing Recommendations

- **Unit test:** load a plugin through the real loader and call its hook directly — `sys.path.insert(0, "src"); import plugin_manager as pm; pm.load_plugins("plugins"); pm.hash_file(path)` — compare against `hashlib`.
- **Integration test:** run a full rescan and verify hashes are computed correctly.
- **Concurrency test:** run with multiple `SCAN_WORKERS` and verify no race conditions or data corruption, especially if touching the multi-file accumulator's shared handle state.
- **Resilience test:** upgrade RomM and run `refresh.sh`; verify the new patch applies and is used on next boot.
- **Signature test:** corrupt a plugin's `.sig` or remove it; confirm it's rejected by default and loads (with a warning) under `FAST_SCAN_ALLOW_UNSIGNED_PLUGINS=1`.
- **Performance test:** benchmark a full rescan before/after, and compare cache hit vs miss timing.

See [TESTING.md](TESTING.md) for detailed instructions.

---

## Code Locations

| Component | File | Purpose |
|---|---|---|
| ABI contract | `include/romm_plugin_abi.h` | The versioned C ABI every plugin implements |
| Plugin loader | `src/plugin_manager.py` | Discovers, sha256/signature/ABI-verifies, and loads plugins via ctypes |
| fasthash plugin | `plugins/fasthash/fasthash.c` | hash_file + hash_file_accum hooks (CRC32/MD5/SHA1) |
| archive-list plugin | `plugins/archive-list/archive_list.c` | archive_list hook (ZIP central-directory listing) |
| Official signers | `plugins/official-signers.txt` | Public key(s) plugin_manager.py verifies plugin signatures against |
| Cache helper | `src/fast_scan_cache.py` | Opt-in hash reuse for unchanged files (tier-0), independent of the plugin system |
| Patch | `roms_handler.patch` | Unified diff wiring plugin_manager.hash_file(...) into RomM's handler |
| Pre-patched files | `overrides/prepatched/*.py` | Pre-computed handlers for known RomM versions (tier-1 exact-match) |
| Known versions | `known_sha256.txt` | Single source of truth for which RomM versions are supported |
| Boot entrypoint | `start.sh` | Compile/verify plugins, patch the handler, set PYTHONPATH, start RomM |
| Refresh tool | `scripts/refresh.sh` | Regenerate the patch and pre-patched files after a RomM update |
| Version lister | `scripts/list_known_versions.py` | Reads known_sha256.txt for CI and other tooling |
| YAML patcher | `scripts/patch_romm_yaml.py` | Add plugin config (incl. FAST_SCAN_ALLOW_UNSIGNED_PLUGINS) to a pod YAML |
| Installer | `scripts/install.sh` | Deploy plugin files to host filesystem |
| Build workflow | `.github/workflows/build-container.yml` | Signs and publishes an image per known RomM version |
| Compatibility watch | `.github/workflows/compat-watch.yml` | Weekly check for upstream RomM 5.x releases not yet covered |
