# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`romm-fast-scan` is a drop-in performance plugin for [RomM](https://github.com/rommapp/romm) (a ROM library manager). RomM hashes every ROM file (CRC32/MD5/SHA1) during a scan; the stock implementation does this in pure Python, which holds the GIL and serializes all scan workers. This plugin ships a C extension that releases the GIL during hashing/I/O, plus a runtime patcher that injects it into RomM's `roms_handler.py` at container boot — no changes to RomM's own source tree are needed at build/release time by users.

There is no application server here — this repo produces a **container image layer / volume-mounted plugin** for someone else's running service (RomM). "Running the project" means building or booting a RomM container with this plugin wired in, not running a local dev server.

## Repository layout

```
src/_fasthash.c          C extension: CRC32+MD5+SHA1 in one pass, GIL released (the perf core)
src/fast_scan_cache.py   Opt-in hash-skip cache (FAST_SCAN_HASH_CACHE=1), pure Python
start.sh                 Container entrypoint: compiles the extension, patches roms_handler.py, execs RomM
roms_handler.patch       Unified diff applied to RomM's roms_handler.py at boot (tier-2)
known_sha256.txt         Maps each known upstream roms_handler.py SHA -> a pre-patched file (tier-1)
overrides/prepatched/    One fully pre-patched roms_handler.py per known RomM version
Containerfile/Dockerfile Build a RomM image with the plugin pre-compiled and baked in (identical content)
scripts/                 Install/uninstall, YAML patchers, image builder, refresh/prune tooling
examples/                Ready-to-deploy pod YAML / compose files
docs/                    Deep-dive docs (architecture, testing, edge cases, troubleshooting, container build)
```

Read `README.md` first for the user-facing install/uninstall/config flows — it is the source of truth for behavior. `docs/ARCHITECTURE.md`, `docs/TESTING.md`, `docs/EDGE_CASES.md`, and `docs/TROUBLESHOOTING.md` go deeper on specific areas than this file does.

## The three-tier patch strategy (core invariant)

Every change to `roms_handler.py`'s hashing path must be expressible as **all three** of these, kept in sync:

1. **Tier-1, exact SHA match** (fastest, safest): `known_sha256.txt` maps an upstream file's SHA256 to a file in `overrides/prepatched/`, which is copied in verbatim.
2. **Tier-2, unified diff**: `roms_handler.patch` is applied with `patch` when no exact SHA match exists. It's meant to survive minor upstream changes to files it doesn't touch.
3. **Tier-3, fallback**: if neither applies, `start.sh` logs a warning and starts RomM unmodified (pure Python hashing) — never blocks boot.

`start.sh` runs this logic (dry-run patch check first, so it never leaves a half-patched file) at every container boot. Never hand-edit `overrides/prepatched/*.py` or `roms_handler.patch` independently — they must stay derivable from each other for the same RomM version. Use `scripts/refresh.sh` (run **inside a live RomM container**) to regenerate both together against a new upstream `roms_handler.py`; it writes the new `.py` into `overrides/prepatched/`, appends to `known_sha256.txt`, and rewrites `roms_handler.patch` as a diff between stock and patched. See the Python heredoc in `scripts/refresh.sh` for the exact anchor-based insertions used (import injection, `_DEFAULT_*_HEX` constants, the `elif hashable_platform:` branch rewrite, and the tier-0 cache injection) — reuse those same anchors if you need to touch this logic by hand.

`known_sha256.txt` only grows over time (every refresh appends). Use `scripts/prune_versions.py` (`list` / `remove <version>` / `keep-latest N`, with `--dry-run` and `--purge`) to trim old entries — this only affects which RomM versions get the tier-1 fast path; tier-2/3 still work for any pruned version.

## Independent tiers of optimization

Don't conflate the patch-application tiers above with the performance tiers described in `docs/ARCHITECTURE.md`:
- **Tier-0 (opt-in):** `fast_scan_cache.py` — skip re-hashing a file entirely if its stored size+mtime match disk (`FAST_SCAN_HASH_CACHE=1`, default off — fail-safe, single-file ROMs only).
- **Tier-1:** `_fasthash.c` — GIL-released single-pass C hashing, used for any non-archive file when tier-0 doesn't short-circuit it.
- **Tier-3:** stock pure-Python hashing — used for archives (`.zip`/`.7z`/`.rar`/...) always, and as the fallback when the C extension is unavailable or raises.

Every one of these fails open to the next: a broken cache lookup, a missing `.so`, or an exception from `_fasthash` all fall through to plain Python hashing rather than erroring the scan.

## `_fasthash.c` conventions

- Module-level `hash_file()`/`hash_buffer()` are stateless and thread-safe with no locking — this is the hot path used by scan workers.
- `MultiFileHasher` holds mutable per-instance accumulator state (`accum`) and *must* serialize access to it via its `PyThread_type_lock` (`self->lock`), acquired only after `Py_BEGIN_ALLOW_THREADS`. If you add a new method that touches `self->accum`, follow the existing lock-around-the-no-GIL-section pattern in `MFH_hash_file`/`MFH_update_buffer`/`MFH_finalize` — this was verified against ThreadSanitizer once already; don't regress it.
- `hs_hexdigest()` finalizes via `EVP_MD_CTX_copy` onto temp contexts specifically so the live context can keep accumulating after a non-final digest read — don't call `EVP_DigestFinal_ex` directly on the live context.
- Buffer size is `256 * 1024` (256 KB) — a deliberate sweet spot noted in `docs/ARCHITECTURE.md`; don't change it without re-benchmarking.

## Building / compiling the C extension

There is no `setup.py`/build system in-repo. The extension is compiled with a plain `gcc` invocation, run in two places that must stay equivalent:
- `start.sh`'s `compile_extension()` (runtime, inside the running container, Alpine/musl target)
- `Containerfile`'s builder stage (build time, `FROM ${BASE_IMAGE}` — built **against the exact RomM image it will run in**, not a generic `alpine:latest`, so the `.so`'s Python ABI suffix always matches; see the comment above `FROM ${BASE_IMAGE} AS builder`)

Both link `-lssl -lcrypto -lz` and require `python3-dev`/`musl-dev`/`openssl-dev`/`zlib-dev` (Alpine package names). `Dockerfile` and `Containerfile` are kept byte-identical (`diff` clean) — if you edit one, mirror the change in the other, or check whether one can just be a copy of the other.

To build/test a full image locally:
```sh
sh scripts/build-image.sh                 # RomM 4.9.2 (default), local tag romm:4.9.2-fast-scan
sh scripts/build-image.sh 5.0.0            # a different RomM version
sh scripts/build-image.sh 4.9.2 ghcr.io/your-org   # also push
```
This picks `Containerfile` under `podman` and `Dockerfile` under `docker` automatically.

## No automated test suite

There's no CI test job and no unit-test framework wired in (`.github/workflows/build-container.yml` only builds and pushes the image). Testing is manual/behavioral against a real RomM container — see `docs/TESTING.md` for the full procedures: verifying `_fasthash.hash_file()` output against `hashlib`, confirming archives still fall back to Python, cache enable/disable checks, and before/after scan-timing benchmarks. When changing hashing logic, the practical verification loop is:
1. Build an image or use the volume-mount install against a real RomM instance.
2. Exec into the running container and call `_fasthash.hash_file(path)` / `fast_scan_cache.cached_file_hash(...)` directly, comparing against `hashlib`.
3. Check `roms_handler.py` for the anchors in `scripts/refresh.sh` after patching — verify with `python3 -c "import ast; ast.parse(open(path).read())"` that the patched file is still syntactically valid, and run the "patch applies to known versions" check described in `docs/TESTING.md`.

## Shell/Python style already in use

- All shell scripts are POSIX `sh` (`#!/bin/sh`, no bashisms) — they run inside Alpine containers (`ash`) as well as on arbitrary host shells.
- `start.sh` / `refresh.sh` write log lines as `log() { echo "[prefix] $*"; }` with a consistent `[fast-scan]` / `[refresh]` prefix; keep new log lines in that voice.
- Every script/tool that mutates a file the user owns (`romm.yml`, `known_sha256.txt`) backs it up first (`*.bak.<timestamp>`) and validates before declaring success — `patch_romm_yaml.py` and `prune_versions.py` both roll back on any sanity-check failure. Follow this pattern for any new mutating script.
- `patch_romm_yaml.py`/`unpatch_romm_yaml.py` use exact-count string replacement (`patch(text, old, new, label)` — errors if the anchor occurs 0 or >1 times) rather than regex, to avoid silently patching the wrong spot. Reuse that helper's approach for new YAML edits.
- Python here is stdlib-only (no `requirements.txt`, no third-party deps) since these scripts run standalone on a host or inside the RomM container's own interpreter.

## Versioning model

This repo supports **multiple RomM versions simultaneously**, not just the latest:
- `SUPPORTED_IMAGE_VERSIONS` in `scripts/patch_romm_yaml.py` lists RomM versions with a published `ghcr.io/zeldafan3421/romm-fast-scan:<version>-fast-scan` image (currently just `4.9.2`) — keep this in sync with what `.github/workflows/build-container.yml` actually publishes.
- `known_sha256.txt` / `overrides/prepatched/` track a broader set — every version anyone has ever run `refresh.sh` against, image-published or not.
- The volume-mount install path (`patch_romm_yaml.py`, `install.sh`) is the deprecated-but-supported fallback for any RomM version *without* a published image yet; it refuses to proceed against a version that already has one unless `--allow-deprecated` is passed.
- CI (`.github/workflows/build-container.yml`) only builds the pinned `4.9.2-fast-scan` tag on every push to `main` — bumping to a new RomM release requires updating `ARG BASE_IMAGE` in `Containerfile`/the workflow's `type=raw,value=...` tag, not just editing source.

## Fallback-safety is the design contract

Every layer here must degrade to "stock RomM behavior" on any failure — this is the property users are trusting when they swap in this plugin, and it should guide any change:
- No `gcc`/build tools → skip compilation, run pure Python.
- Patch doesn't apply → skip patching, run pure Python.
- `_fasthash` raises at import or call time → fall back to Python per-file (caught in the patched `roms_handler.py`, not this repo's own code, but the patch generation must preserve this `try/except`).
- Hash cache disabled, unavailable, DB error, or mismatch → returns `None`, caller reads and hashes normally.

Never introduce a code path where a failure in this plugin could produce a *wrong* hash or block RomM from starting — silent fallback, not a hard error, is the expected behavior throughout this codebase.
