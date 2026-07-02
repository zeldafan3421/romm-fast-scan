# Writing a romm-fast-scan plugin

A plugin is a shared library (`.so`) exposing a small C ABI, plus a
`plugin.json` manifest. Nothing about the ABI requires C or C++
specifically — only that the result is a proper `extern "C"`-equivalent
shared library, which most native-compiled languages can produce (Rust as
a `cdylib`, Go with `-buildmode=c-shared`, Zig, and so on, in addition to
C/C++). It has no Python.h, no CPython ABI coupling, and no dependency on
which RomM version or Python minor version it will run alongside — build
it once per (arch, libc) target and it works everywhere, forever. This is
what lets `roms_handler.py` get patched **once** (see
`../roms_handler.patch`) to call into `plugin_manager.hash_file(...)`
instead of needing a new source patch every time the hashing
implementation changes.

See `../include/romm_plugin_abi.h` for the full, authoritative contract —
this file is a guide to using it, not a copy of it. Everything below
through "Building" describes the source-in-this-repo path (write C, get
it compiled by this repo's own tooling); see "Precompiled and third-party
plugins" further down if you'd rather build elsewhere, in another
language, or install a plugin someone else already built.

## The rules (non-negotiable)

1. Every exported function is `extern "C"`. Only primitives, fixed-size
   buffers, and structs of primitives cross the boundary — no STL, no
   exceptions escaping a plugin function (catch in the plugin, return a
   status code).
2. Every hook function returns a status code: `0` = success, nonzero =
   failure. `src/plugin_manager.py` treats *any* nonzero return (or the
   `.so` failing to load at all) as "this plugin isn't available" and
   falls back to the existing pure-Python path. A plugin can only make a
   scan slower by being absent or broken; it can never make RomM produce
   a wrong hash or fail to start.
3. Never crash the process on bad input — a missing file, a truncated
   archive, a corrupt image. Return nonzero (or `NULL` for a handle-based
   hook) instead. A real segfault in a plugin still takes down the whole
   RomM worker process, same as anywhere else in a shared library; this
   contract only holds if your code actually honors it.
4. Every `.so` exports `romm_plugin_abi_version(void)` returning
   `ROMM_PLUGIN_ABI_VERSION`. The loader checks this *and* cross-checks it
   against the `abi_version` claimed in `plugin.json` before calling
   anything else in your plugin — get either wrong and the whole plugin is
   skipped and logged, not partially loaded.

## Directory layout

```
plugins/
  <name>/
    <name>.c              Source. Whatever you want, as long as the
                           exported symbols match what plugin.json declares.
    plugin.json.tmpl       Manifest template, committed to git. "sha256": null.
    plugin.json             ) Build artifacts. Gitignored -- regenerated
    lib<name>.so            ) by every build (scripts/build-plugins.sh,
                             ) start.sh's compile_plugins(), or the
                             ) Containerfile's builder stage).
```

`plugin.json.tmpl` is the source of truth for everything except the
`sha256`, which necessarily depends on the exact compiled bytes (compiler
version, flags, target) and can't be known ahead of a build:

```json
{
  "name": "fasthash",
  "abi_version": 1,
  "so_file": "libfasthash.so",
  "sha256": null,
  "hooks": {
    "hash_file": {
      "entry_symbol": "romm_hash_file"
    }
  }
}
```

A build step (see below) reads the template, compiles the source, computes
the real `sha256` of the result, and writes the finalized `plugin.json`
next to the `.so`. **Never hand-edit a finalized `plugin.json`** — if the
`sha256` doesn't match the actual file on disk byte-for-byte, the loader
refuses to load it (this is the whole point: a cheap tamper/corruption
check before any of your code ever runs).

## The three hook shapes today

Pick whichever matches what you're building; add a new one to
`romm_plugin_abi.h` (bump `ROMM_PLUGIN_ABI_VERSION`) if none fit.

- **`hash_file`** — one file in, three hex digests out via caller-provided
  buffers. See `fasthash/fasthash.c`'s `romm_hash_file`.
- **`hash_file_accum`** — an opaque-handle accumulator for hashing several
  files into one combined digest (multi-disc ROMs). Four symbols per
  plugin.json (`new`/`file`/`finalize`/`free`), all declared under one
  `entry_symbols` object rather than a single `entry_symbol` string. See
  `fasthash/fasthash.c`'s `romm_hash_accum_*` family — note the
  per-handle `pthread_mutex_t`: if two threads might ever call methods on
  the *same* handle concurrently (they shouldn't, by design, but plugin
  code should be defensive), the handle's own state needs locking. A
  data race here was a real, ThreadSanitizer-confirmed bug in the
  CPython-extension version this was ported from before that lock
  existed — don't drop it if you touch this pattern. Like `archive_list`
  below, this hook is **not yet wired into `roms_handler.py`** — proven at
  the plugin-system level (loads, callable, matches the old
  `MultiFileHasher`'s output) but nothing in RomM's current scan path
  calls `plugin_manager.new_multi_file_accumulator()` yet. Multi-disc ROMs
  still hash through the stock per-file path today.
- **`archive_list`** — another opaque-handle hook, this one for listing a
  ZIP's members (name, sizes, stored CRC32) without decompressing
  anything. See `archive-list/archive_list.c`. Good reference for a
  hook whose result is a *variable-length* collection rather than a
  fixed set of output buffers: `open` returns a handle, `entry_count`
  and `entry_at(handle, index, &out)` let the caller pull results one
  struct at a time, `close` frees it.

## Building

```sh
sh ../scripts/build-plugins.sh              # every plugin
sh ../scripts/build-plugins.sh fasthash     # just one
```

This is exactly what `start.sh` does at container boot (self-contained,
not by shelling out to this script) and what the `Containerfile`'s builder
stage does at image-build time — all three read the same
`plugin.json.tmpl`, compile with the same `-I ../include` flag, and
finalize `plugin.json` with the real `sha256` afterward. If your plugin
needs extra link flags (a library beyond libc), add a `case` arm for its
name in all three places — `fasthash`'s `-lssl -lcrypto -lz -lpthread` is
the existing example to copy.

Manually, without the helper:

```sh
gcc -shared -fPIC -O2 -std=c99 -I ../include -o libyourname.so yourname.c [-lwhatever]
sha256sum libyourname.so   # paste into plugin.json's "sha256" field
```

No `python3-dev`, no `python-config`, no per-Python-minor-version rebuild
— that whole problem belonged to the old single CPython extension this
system replaced, and doesn't apply to a plain C-ABI `.so` at all.

## Precompiled and third-party plugins

Everything above describes the source-in-this-repo path. That's not the
only way to get a plugin loaded.

`src/plugin_manager.py`'s `load_plugins()` only ever looks for a
finalized `plugin.json` next to a `.so` (`sorted(root.glob("*/plugin.json"))`)
— it has no idea whether either file came from this repo's build tooling,
a bare `gcc` invocation on your own machine, `cargo build`, `go build
-buildmode=c-shared`, or anything else. Separately, `start.sh`'s
`compile_plugins()` only ever looks for a `.c` file or a `plugin.json.tmpl`
(`*/*.c`, `*/plugin.json.tmpl`) — a plugin directory with neither is
invisible to it, silently skipped, not logged as an error. Put together:
**a plugin directory containing only a finalized `plugin.json` and its
matching `.so` is never touched by the build phase and is loaded normally
by the load phase.** This isn't a special case bolted on for this
purpose — it's what falls out of keeping "build" and "load" as genuinely
separate concerns, verified live against a plugin built entirely outside
this repo's tooling (no `.c` in the deployed directory, no `.tmpl`, no
`build-plugins.sh`/`start.sh`/`Containerfile` involvement) — it loaded,
passed sha256/ABI verification, and its hook produced correct output with
zero special-casing anywhere in `plugin_manager.py`.

**To install one:** drop `<name>/plugin.json` (finalized — a real
`sha256`, not `null`) and `<name>/<so_file>` into the plugins root (the
deployed `/romm-plugin/plugins/` for a live install, or `plugins/` if
you're building a custom image). No `.c`, no `.tmpl`, no build step
required on this repo's side at all.

**Trust and provenance — read this before installing someone else's
plugin.** A plugin `.so` is native code that runs inside your RomM
container with the same privileges RomM itself has. The `sha256` in
`plugin.json` is a *corruption/tamper* check — it confirms the `.so` on
disk matches what the manifest claims, nothing more; anyone able to edit
both files together can make it pass. This is now backed by something
stronger by default: see "Signing and FAST_SCAN_ALLOW_UNSIGNED_PLUGINS"
below — a precompiled/third-party plugin isn't signed by the official key
(it can't be; only this repo's own CI holds that private key), so loading
one requires deliberately setting `FAST_SCAN_ALLOW_UNSIGNED_PLUGINS=1`.
That env var is the actual trust decision — only set it for a plugin from
a source you'd trust to the same degree as any other native binary you'd
run with your container's privileges. If in doubt, prefer a plugin you
can read the source of and build yourself, and understand that self-built
copy will *also* need the env var (see below for why).

**Hook collisions:** if two loaded plugins declare the same hook,
`plugin_manager.py` keeps whichever loads first (directories are visited
in sorted order) and logs a warning for the rest — it does not error or
refuse to boot.

**Getting a good third-party plugin adopted into this repo:** if a
precompiled plugin someone built independently proves widely useful and
its author is willing to share the source, it can be brought into
`plugins/<name>/` and wired into the standard build tooling (`scripts/
build-plugins.sh` / `start.sh` / the `Containerfile`'s builder stage —
see "Building" above) so this repo starts building and shipping it going
forward. That's a case-by-case maintainer decision today, not an
automated process.

## Signing and `FAST_SCAN_ALLOW_UNSIGNED_PLUGINS`

Official plugins (`fasthash`, `archive-list`) are cryptographically
signed at build time. By default, `plugin_manager.py`'s `load_plugins()`
**refuses to load any plugin that isn't signed by the official key** —
this includes precompiled/third-party plugins (above) *and* a plugin you
built yourself from this repo's own source. Set
`FAST_SCAN_ALLOW_UNSIGNED_PLUGINS=1` to opt back into the older,
weaker behavior (sha256 tamper-check only, no authenticity check) at your
own risk.

**Mechanism:** `ssh-keygen -Y sign` / `-Y verify` — the same primitive
`git`'s `gpg.format=ssh` commit signing uses, chosen so this stays
dependency-free (no `cryptography`/`pynacl`, consistent with "Python here
is stdlib-only," just an external CLI tool the same way `patch`/`gcc`
already are). `.github/workflows/build-container.yml`'s `sign-plugins`
job builds every plugin once (plugins have no RomM-version coupling, see
above), signs each `.so` with the private half of a keypair that exists
**only** as the `PLUGIN_SIGNING_KEY` GitHub Actions secret — never
committed, never written into a Docker build context or image layer — and
hands the signed artifact to every matrix build leg. `plugins/
official-signers.txt` (committed — public key material, safe to be
public) is what `plugin_manager.py` verifies against.

**Why self-built plugins need the env var too, even from this repo's own
source:** the check is "signed by the official key," not "built from
trusted source." `plugin_manager.py` has no way to distinguish "you
compiled the exact same `fasthash.c` yourself" from "a stranger compiled
something else entirely" — only CI holds the private key. If you build
locally (`scripts/build-plugins.sh`) or use the volume-mount install
path, either set `FAST_SCAN_ALLOW_UNSIGNED_PLUGINS=1`, or extract the
already-signed `.so`+`.sig` out of the published `ghcr.io` image instead
of rebuilding (`podman cp`/`docker cp` from a running container).

**What "unverifiable" means:** a missing `.sig` file, a missing
`official-signers.txt`, a missing `ssh-keygen` binary, or a genuinely
invalid signature are all treated identically — as "not signed" — and
gated by the same env var. This is one of the only checks in this repo
that does *not* fail open toward "just use pure Python" by default; it
fails toward "don't run this native code." The official image always has
`ssh-keygen` installed (`Containerfile`'s runtime stage), so this
fallback path is realistically only ever hit on a self-built or
volume-mount install, not the published image.

**Rotating the signing key** (not needed today, first key): generate a
new keypair, append its public half as a new line in
`official-signers.txt` (multiple valid keys can coexist), start signing
new builds with the new private key, and remove the old line only once no
artifacts signed with it are expected to still be circulating.

## Testing a new plugin

There's no test framework wired into this repo (see `CLAUDE.md`'s
"No automated test suite" note) — testing here means the same
manual/behavioral verification used throughout: compile it, load it
through the real `plugin_manager.py`, and compare its output against a
trusted reference (`hashlib`, `zipfile`, PIL, whatever's authoritative for
what you're implementing). The loop that was actually used to build and
verify `fasthash` and `archive-list`:

1. `sh scripts/build-plugins.sh yourplugin`
2. From the repo root:
   ```python
   import sys; sys.path.insert(0, "src")
   import plugin_manager as pm
   pm.load_plugins("plugins")
   print(pm.loaded_hooks())   # your hook should be in this list
   ```
3. Compare output against a trusted reference for several real inputs,
   including edge cases (empty file, missing file, malformed input) —
   every one of those should come back `None` through `plugin_manager`,
   never raise.
4. If your hook can be exercised concurrently (the way `SCAN_WORKERS`
   calls `hash_file` from multiple threads simultaneously), stress-test
   it under load; if it has any shared mutable state across calls (like
   `hash_file_accum`'s handle), specifically try to race two threads
   against the *same* handle and confirm it doesn't corrupt or crash
   (ThreadSanitizer if you have it available; a heavy concurrent-call
   loop checking for hangs/wrong output is the fallback used here when
   TSan wasn't reliably available in the sandbox this was built in).
5. Confirm the loader's safety nets actually work for your plugin
   specifically: corrupt its `sha256` in `plugin.json` (should skip,
   logged, not loaded), its `abi_version` (same), and remove/tamper its
   `.sig` (should skip unless `FAST_SCAN_ALLOW_UNSIGNED_PLUGINS=1`, see
   "Signing and `FAST_SCAN_ALLOW_UNSIGNED_PLUGINS`" below).

## Adding the hook to `roms_handler.py` (only for a genuinely new hook)

If you're adding a plugin behind an **existing** hook (a faster
`hash_file` implementation, say), you're done — `plugin_manager.py`
already calls into it, and `roms_handler.py` never needs to change again.

If you're wiring in a **new** hook that RomM's source doesn't call yet,
that's the one case that still needs a `roms_handler.py` (or
`resources_handler.py`, etc.) source patch — same three-tier process as
everything else in this repo (`known_sha256.txt` / `overrides/prepatched/`
/ `roms_handler.patch`, regenerated via `scripts/refresh.sh`). See
`../CLAUDE.md`'s "three-tier patch strategy" section for how that works.
`archive_list` in this repo is deliberately *not* wired into
`roms_handler.py` yet — it's proven at the plugin-system level (compiles,
loads, matches `zipfile` exactly) but doesn't yet replace anything RomM's
scan path currently does, since listing a ZIP's stored metadata isn't a
drop-in replacement for the actual decompress-and-hash work the archive
branch does today. Wiring it in as a fast pre-check would be exactly this
kind of new-hook integration, if it's ever wanted.

See `../CLAUDE.md`'s "Roadmap: incremental backend replacement" section for
where `archive_list`, `hash_file_accum`, and other not-yet-started hooks
fit into this project's longer-term plan.
