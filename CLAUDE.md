# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`romm-fast-scan` is a drop-in performance plugin for [RomM](https://github.com/rommapp/romm) (a ROM library manager), built on a small native-plugin system. RomM's `roms_handler.py` is patched **once** to call `plugin_manager.hash_file(...)` instead of hashing in pure Python; `plugin_manager.py` loads plain C-ABI `.so` plugins at runtime via `ctypes`. The stock hashing implementation holds the GIL and serializes all scan workers; the bundled `fasthash` plugin has no GIL to release in the first place (it's not a CPython extension), so scan workers run genuinely concurrently. There's also an `archive-list` plugin (ZIP central-directory listing) that exists to prove the plugin system generalizes beyond hashing — it isn't wired into RomM's scan path yet, only proven at the loader/plugin level.

This design replaced an earlier one where `roms_handler.py` called directly into a CPython C extension (`_fasthash.c`, now removed). That extension's `.so` filename was tied to the exact Python ABI of whatever RomM image it ran in, so a prebuilt image's *builder* stage had to be `FROM` the exact target RomM image just to get a matching Python. Plain C-ABI plugins have no Python involved at all, so a plugin built once works unmodified across every RomM/Python version — see `plugins/README.md` for the full contract and rationale.

There is no application server here — this repo produces a **container image layer / volume-mounted plugin** for someone else's running service (RomM). "Running the project" means building or booting a RomM container with this plugin wired in, not running a local dev server.

## Repository layout

```
include/romm_plugin_abi.h  The C-ABI contract every plugin implements (versioned)
plugins/README.md          Plugin authoring guide -- read this before touching a plugin
plugins/fasthash/          hash_file + hash_file_accum hooks (CRC32/MD5/SHA1), fasthash.c + plugin.json.tmpl
plugins/archive-list/      archive_list hook (ZIP central-directory listing), archive_list.c + plugin.json.tmpl
src/plugin_manager.py      ctypes loader: verifies sha256+abi_version, dispatches into loaded plugins
src/fast_scan_cache.py     Opt-in hash-skip cache (FAST_SCAN_HASH_CACHE=1), pure Python, unrelated to plugins
start.sh                   Container entrypoint: compiles uncached plugins, patches roms_handler.py, execs RomM
roms_handler.patch         Unified diff applied to RomM's roms_handler.py at boot (tier-2)
known_sha256.txt           Maps each known upstream roms_handler.py SHA -> a pre-patched file (tier-1)
overrides/prepatched/      One fully pre-patched roms_handler.py per known RomM version
Containerfile/Dockerfile   Build a RomM image with every plugin pre-compiled and baked in (identical content)
scripts/                   Install/uninstall, YAML patchers, image + plugin builders, refresh/prune tooling
examples/                  Ready-to-deploy pod YAML / compose files
docs/                      Deep-dive docs -- predates the plugin migration, may describe the old _fasthash.c
                            design in places; treat README.md/plugins/README.md as authoritative if they conflict
```

Read `README.md` first for the user-facing install/uninstall/config flows — it is the source of truth for behavior. `plugins/README.md` is the source of truth for writing or modifying a plugin.

## The three-tier patch strategy (core invariant)

Every change to `roms_handler.py`'s hashing path must be expressible as **all three** of these, kept in sync:

1. **Tier-1, exact SHA match** (fastest, safest): `known_sha256.txt` maps an upstream file's SHA256 to a file in `overrides/prepatched/`, which is copied in verbatim.
2. **Tier-2, unified diff**: `roms_handler.patch` is applied with `patch` when no exact SHA match exists. It's meant to survive minor upstream changes to files it doesn't touch.
3. **Tier-3, fallback**: if neither applies, `start.sh` logs a warning and starts RomM unmodified (pure Python hashing) — never blocks boot.

`start.sh` runs this logic (dry-run patch check first, so it never leaves a half-patched file) at every container boot. Never hand-edit `overrides/prepatched/*.py` or `roms_handler.patch` independently — they must stay derivable from each other for the same RomM version. Use `scripts/refresh.sh` (run **inside a live RomM container**) to regenerate both together against a new upstream `roms_handler.py`; it writes the new `.py` into `overrides/prepatched/`, appends to `known_sha256.txt`, and rewrites `roms_handler.patch` as a diff between stock and patched. See the Python heredoc in `scripts/refresh.sh` for the exact anchor-based insertions used (`plugin_manager` import + `load_plugins()` call injection, `_DEFAULT_*_HEX` constants, the `elif hashable_platform:` branch rewrite calling `_pm.hash_file(...)`, and the tier-0 cache injection) — reuse those same anchors if you need to touch this logic by hand. If you add a genuinely new hook to `roms_handler.py` (not just a new plugin behind an existing hook), `scripts/refresh.sh`'s anchors need a matching update or a future refresh will silently regenerate the old call shape.

`known_sha256.txt` only grows over time (every refresh appends). Use `scripts/prune_versions.py` (`list` / `remove <version>` / `keep-latest N`, with `--dry-run` and `--purge`) to trim old entries — this only affects which RomM versions get the tier-1 fast path; tier-2/3 still work for any pruned version.

## Independent tiers of optimization

Don't conflate the patch-application tiers above with the performance tiers used at hashing time:
- **Tier-0 (opt-in):** `fast_scan_cache.py` — skip re-hashing a file entirely if its stored size+mtime match disk (`FAST_SCAN_HASH_CACHE=1`, default off — fail-safe, single-file ROMs only). Pure Python, entirely unrelated to the plugin system; sits in front of it.
- **Tier-1:** `plugin_manager.hash_file(...)` — dispatches into whichever plugin provides the `hash_file` hook (the bundled `fasthash` plugin, GIL-released single-pass native hashing), used for any non-archive file when tier-0 doesn't short-circuit it.
- **Tier-3:** stock pure-Python hashing — used for archives (`.zip`/`.7z`/`.rar`/...) always, and as the fallback when no plugin provides `hash_file`, a plugin's `.so` fails to load/verify, or a call into it fails.

Every one of these fails open to the next: a broken cache lookup, a missing/corrupt/ABI-mismatched plugin `.so`, or a plugin call itself failing all fall through to plain Python hashing rather than erroring the scan. `plugin_manager.hash_file()` specifically returns `None` on any failure (it never raises for an expected failure mode) — the call site in the patched `roms_handler.py` checks for `None` in addition to keeping a `try/except` as a second line of defense.

## Plugin system conventions

See `plugins/README.md` for the full plugin-authoring guide; this section is the subset worth knowing before touching `plugin_manager.py` or an existing plugin's C source.

- `include/romm_plugin_abi.h` is the versioned contract. Every plugin `.so` exports `romm_plugin_abi_version(void)`; `plugin_manager.py`'s loader checks it against what `plugin.json` claims *and* against what the loader itself supports — both checks are meaningful (not one redundant with the other): manifest-vs-binary catches a stale `plugin.json` next to a rebuilt `.so` or vice versa, independent of what the loader supports; binary-vs-loader-constant catches a plugin genuinely built for a different ABI generation. If you ever restructure this, keep both reachable — an earlier version of this check had the second one provably unreachable (both prior checks already forced agreement with the same constant), caught by testing the actual failure path, not by reading the code.
- `plugins/fasthash/fasthash.c`'s module-level `romm_hash_file` is stateless with no locking — the hot path used by scan workers, each call touches only its own stack/heap. `romm_hash_accum_*` (multi-file accumulator, mirrors the old `MultiFileHasher`) holds mutable per-handle state and *must* serialize access to it via its `pthread_mutex_t`, held only for the duration of the accum-touching work. This is a direct port of a pattern that was a real, ThreadSanitizer-confirmed data race in the CPython-extension version before the lock existed — don't regress it if you touch this code.
- `hs_hexdigest()` (inside `fasthash.c`) finalizes via `EVP_MD_CTX_copy` onto temp contexts specifically so the live context can keep accumulating after a non-final digest read — don't call `EVP_DigestFinal_ex` directly on the live context. Every EVP call here is return-checked before use; an earlier version of this that didn't check `EVP_MD_CTX_copy`/`EVP_DigestFinal_ex` was a real segfault risk (undefined internal digest state → dereference), found and fixed before the plugin migration and ported forward.
- Buffer size is `256 * 1024` (256 KB) — a deliberate sweet spot; don't change it without re-benchmarking.
- Plugin source `#include`s the ABI header as `"romm_plugin_abi.h"` (no relative path) and relies on an explicit `-I` compiler flag pointing at `include/` — every compile site (`start.sh`, `scripts/build-plugins.sh`, the `Containerfile`) passes this flag. A relative `#include "../../include/romm_plugin_abi.h"` was tried first and only resolves inside a git checkout, not once deployed to `/romm-plugin/` — caught by actually running the compile step against a simulated deployment, not by reading the code.
- sha256/ABI verification (above) isn't the only gate a plugin has to pass: `plugin_manager.py` also checks a signature by default, refusing anything not signed by the official key unless `FAST_SCAN_ALLOW_UNSIGNED_PLUGINS=1` is set — see `plugins/README.md`'s "Signing and `FAST_SCAN_ALLOW_UNSIGNED_PLUGINS`" section and the last bullet under "Fallback-safety is the design contract" below for why this one check is deliberately not fail-open like everything else here.

## Building / compiling plugins

There is no `setup.py`/build system in-repo. Plugins are compiled with a plain `cc`/`gcc` invocation, run in three places that must stay equivalent:
- `scripts/build-plugins.sh` (on a dev machine, against a repo checkout)
- `start.sh`'s `compile_plugins()` (runtime, inside the running container, self-contained — doesn't shell out to the script above)
- `Containerfile`'s builder stage (build time)

Unlike the old CPython extension, none of these need to match RomM's Python version — plain C-ABI `.so` files have no Python involved at all, so the `Containerfile`'s builder stage is a generic `alpine:latest`, not `FROM ${BASE_IMAGE}`. `fasthash` links `-lssl -lcrypto -lz -lpthread`; `archive-list` needs nothing beyond libc — per-plugin link flags are special-cased by name in all three build sites (a `case` statement), add a new arm there for a new plugin that needs one. `Dockerfile` and `Containerfile` are kept byte-identical (`diff` clean) — if you edit one, mirror the change in the other, or check whether one can just be a copy of the other.

The `Containerfile`/`Dockerfile` also define a fourth stage, `plugins-export` (`FROM scratch`, just `COPY --from=builder /build/plugins/ /`) — not part of the normal build (nothing depends on it as an ancestor of the final image, so a plain `docker build .` never builds it), it exists only so `.github/workflows/build-container.yml`'s `sign-plugins` job can `--target plugins-export -o type=local` a minimal artifact (just the built `.so`s, not gcc/musl-dev/the rest of Alpine) to sign with `PLUGIN_SIGNING_KEY` before any matrix leg's real image build runs. The builder stage's compile loop skips a plugin whose `.so` already exists in the build context specifically so that signed artifact survives into the final image unmodified instead of being silently recompiled-and-unsigned.

To build/test a full image locally:
```sh
sh scripts/build-image.sh                 # RomM 4.9.2 (default), local tag romm:4.9.2-fast-scan
sh scripts/build-image.sh 5.0.0            # a different RomM version
sh scripts/build-image.sh 4.9.2 ghcr.io/your-org   # also push
```
This picks `Containerfile` under `podman` and `Dockerfile` under `docker` automatically.

## No automated test suite

There's no CI test job and no unit-test framework wired in (`.github/workflows/build-container.yml` only builds and pushes the image). Testing is manual/behavioral against a real RomM container. When changing hashing logic, the practical verification loop is:
1. Build an image, or use the volume-mount install against a real RomM instance, or (for isolated plugin work) just `sh scripts/build-plugins.sh` and load it directly.
2. From the repo root: `sys.path.insert(0, "src"); import plugin_manager as pm; pm.load_plugins("plugins")`, then call `pm.hash_file(path)` / `pm.new_multi_file_accumulator()` / `pm.archive_list(path)` directly, comparing against `hashlib`/`zipfile`.
3. Check `roms_handler.py` for the anchors in `scripts/refresh.sh` after patching — verify with `python3 -c "import ast; ast.parse(open(path).read())"` that the patched file is still syntactically valid.
4. For anything touching shared mutable state (the accumulator's handle), specifically try to race two threads against the *same* handle under load — a heavy concurrent-call loop checking for hangs/crashes/wrong output at minimum, ThreadSanitizer if available (this sandbox's TSan was independently flaky on unrelated trivial code during the plugin migration — one clean zero-warning run plus a heavy stress test with no hang was treated as sufficient evidence given that constraint; don't assume TSan will run cleanly in every environment).

## Shell/Python style already in use

- All shell scripts are POSIX `sh` (`#!/bin/sh`, no bashisms) — they run inside Alpine containers (`ash`) as well as on arbitrary host shells.
- `start.sh` / `refresh.sh` write log lines as `log() { echo "[prefix] $*"; }` with a consistent `[fast-scan]` / `[refresh]` prefix; keep new log lines in that voice.
- Every script/tool that mutates a file the user owns (`romm.yml`, `known_sha256.txt`) backs it up first (`*.bak.<timestamp>`) and validates before declaring success — `patch_romm_yaml.py` and `prune_versions.py` both roll back on any sanity-check failure. Follow this pattern for any new mutating script.
- `patch_romm_yaml.py`/`unpatch_romm_yaml.py` use exact-count string replacement (`patch(text, old, new, label)` — errors if the anchor occurs 0 or >1 times) rather than regex, to avoid silently patching the wrong spot. Reuse that helper's approach for new YAML edits.
- Python here is stdlib-only (no `requirements.txt`, no third-party deps) since these scripts run standalone on a host or inside the RomM container's own interpreter.

## Versioning model

This repo supports **multiple RomM versions simultaneously**, not just the latest, and `known_sha256.txt` is the single source of truth for which ones: every version anyone has ever run `refresh.sh` against, image-published or not, in append-only order.
- `scripts/list_known_versions.py` reads that ledger and is the one place version lists get derived from — nothing else should hardcode a second copy. `--json` feeds a CI matrix, `--only VERSION` validates one, no flags prints one per line.
- `.github/workflows/build-container.yml` builds and publishes a `ghcr.io/zeldafan3421/romm-fast-scan:<version>-fast-scan` image for **every** version `list_known_versions.py` reports, via a matrix job — not a single hardcoded tag. Adding support for a new RomM version is "run `refresh.sh` inside a live container of it, review the diff, commit `known_sha256.txt` + the new `overrides/prepatched/<version>.py`" — the next push to `main` publishes an image for it with no separate CI edit required. This is the mechanism behind the compatibility commitment below.
- `scripts/patch_romm_yaml.py`'s `SUPPORTED_IMAGE_VERSIONS` is computed the same way (`load_supported_image_versions()`, reading `known_sha256.txt` from the deployed plugin path, then a repo checkout, then CWD, failing open to an empty set if none is found) rather than a hardcoded set — but that file stays a standalone-copyable script (see its module docstring), so it keeps its *own* small inlined copy of the comment-parsing logic instead of importing `list_known_versions.py`. If you ever change `known_sha256.txt`'s line format, update both.
- The volume-mount install path (`patch_romm_yaml.py`, `install.sh`) is the deprecated-but-supported fallback for any RomM version *without* a published image yet; it refuses to proceed against a version that already has one unless `--allow-deprecated` is passed.
- `.github/workflows/compat-watch.yml` (`scripts/check_upstream_versions.py`) runs weekly, diffing upstream `rommapp/romm`'s published `5.*` releases against `known_sha256.txt` and opening/refreshing/closing a single tracking issue (label `compat-watch`) when a gap appears — see the Roadmap section below. It never runs `refresh.sh` or commits anything itself; closing a gap still needs a human in the loop.

## Roadmap: incremental backend replacement

The plugin system's first (and so far only) hook, `hash_file`, replaces one hot path in `roms_handler.py`. The longer-term plan is to extend the same mechanism — one hook at a time, same three-tier patch discipline, same fail-open contract, never a rewrite — to other CPU-bound spots in RomM's backend, as capacity and need line up. Concretely, in rough order:

1. **`hash_file` — done.** Wired into `roms_handler.py`, shipped in the `fasthash` plugin.
2. **`archive_list` / `hash_file_accum` — proven, not yet wired.** Both hooks exist in `include/romm_plugin_abi.h`, both are implemented and load correctly through `plugin_manager.py` (see `plugins/README.md`'s "Adding the hook to roms_handler.py" section for exactly what wiring either of these in would take), but neither is called anywhere in `roms_handler.py` yet.
3. **Named future candidates, no code yet:** cover/thumbnail resizing in `resources_handler.py` (Pillow-based today) and fuzzy metadata-name matching in `igdb_handler.py` are the next most CPU-bound spots in RomM's backend worth a native plugin, based on a survey of the source — nothing beyond this note exists for either yet.

**Any language, not just C/C++.** Nothing about `include/romm_plugin_abi.h` requires C or C++ specifically, only a proper `extern "C"`-equivalent shared library — Rust (`cdylib`), Go (`-buildmode=c-shared`), Zig, and others all qualify. This repo's own bundled plugins happen to be written in C, but `plugin_manager.py`'s loader has no opinion on how a `.so` was produced. It's proven, not just asserted: `plugins/README.md`'s "Precompiled and third-party plugins" section documents a plugin built with a bare `cc` invocation entirely outside this repo's build tooling, dropped in with nothing but a finalized `plugin.json` and its `.so`, loading and running correctly with zero special-casing anywhere in the loader.

**Compatibility commitment.** This repo commits to supporting every RomM **5.\*.\*** backend release, indefinitely, via the mechanism in "Versioning model" above (an automated build matrix plus a weekly upstream-gap check) rather than by promise alone. It commits to **indefinite RomM frontend compatibility** too, but that one is close to free: every hook this repo has or has ever proposed operates entirely on RomM's Python backend and native plugins loaded into it — nothing in this mechanism can read, patch, or depend on RomM's frontend, so no frontend change can ever break it. `build-container.yml` greps for accidental `frontend` references in the patch/override files as a cheap guard against that ever changing by mistake.

## Fallback-safety is the design contract

Every layer here must degrade to "stock RomM behavior" on any failure — this is the property users are trusting when they swap in this plugin, and it should guide any change:
- No compiler/build tools → skip compilation, that hook falls back to pure Python.
- Patch doesn't apply → skip patching, run pure Python.
- A plugin's `.so` fails sha256/ABI-version verification, fails to load, or a call into it raises → `plugin_manager` returns `None`, caller falls back to Python per-file (caught in the patched `roms_handler.py`, not this repo's own code, but the patch generation must preserve this `try/except` in addition to the `None` check — `plugin_manager` fails open by returning `None`, not by raising, so both checks matter).
- Hash cache disabled, unavailable, DB error, or mismatch → returns `None`, caller reads and hashes normally.
- **The one deliberate exception:** signature verification does not fail open toward "use it anyway." A plugin's `.so` failing to verify against `plugins/official-signers.txt` — missing `.sig`, missing signers file, missing `ssh-keygen`, or a genuinely invalid signature, all treated the same — is refused outright unless `FAST_SCAN_ALLOW_UNSIGNED_PLUGINS=1` is set, full stop, not "load it and warn." This still composes with everything else in this list: a refused plugin is just another reason `plugin_manager` returns `None`, so `roms_handler.py` needs no awareness of signing at all — but it's worth being explicit that *this specific check's* fail-open direction is "don't run unverified native code," not "keep hashing fast." See `plugins/README.md`'s "Signing and `FAST_SCAN_ALLOW_UNSIGNED_PLUGINS`" section.

Never introduce a code path where a failure in this plugin could produce a *wrong* hash or block RomM from starting — silent fallback, not a hard error, is the expected behavior throughout this codebase. Signature verification is the sole intentional exception to the "always fail toward working" half of that sentence; it still never blocks RomM from starting.

## `LIBRARY_SIZE` tuning profiles

The plugin's contract is "make scans faster, otherwise behave **exactly** like stock RomM." `LIBRARY_SIZE` (handled in `start.sh` step 4, before the `exec`) is how anything beyond raw acceleration is offered — as an explicit, opt-in profile, never as an always-on change. Two profiles today:

- **`DEFAULT`** (the value when `LIBRARY_SIZE` is unset or `DEFAULT`) — **hard invariant: this branch sets nothing.** No `export`, no plugin-pinned constants, not even a "4h". It inherits every RomM default exactly as *the RomM version you're running* ships them, so `DEFAULT` behaves identically to stock RomM on any version, forever, with nothing in this repo to drift out of date when RomM changes a default. When you touch this code, keep the `DEFAULT` branch a no-op (a `log` line is the only thing it may do) — the moment it sets a value, the passthrough guarantee is broken.
- **`LARGE`** — raises only knobs whose RomM stock default is too tight for a big library. Currently just `SCAN_TIMEOUT`: `export SCAN_TIMEOUT="${SCAN_TIMEOUT:-86400}"` (RomM's own default is the RQ `job_timeout` for both manual scans in `endpoints/sockets/scan.py` and the watcher's auto-rescans in `watcher.py` — currently 4h — which hard-kills a scan that legitimately runs longer; `LARGE` gives it 24h).

Invariants for any future profile work, hold all of them:
1. `DEFAULT` sets nothing — it *is* whatever RomM's own defaults are for that version.
2. Every knob a non-default profile sets uses `${VAR:-…}`, so an explicitly-set value always wins — a profile supplies a smarter *default*, never an override of the user's own choice.
3. Only environment/config-level knobs that are trivially overridable and cannot corrupt data or block startup belong here — never signing (`FAST_SCAN_ALLOW_UNSIGNED_PLUGINS`, a security decision) or the hash cache (`FAST_SCAN_HASH_CACHE`, a correctness tradeoff), which stay their own independent switches.
4. An unrecognized `LIBRARY_SIZE` value warns and falls back to `DEFAULT` — a typo must never break a deployment.
5. Document any new profile/knob in `start.sh`'s step-4 comment, `README.md`'s "Library size profiles", and here, and keep all three consistent.
