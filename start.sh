#!/bin/sh
# fast_scan_plugin/start.sh
# ─────────────────────────────────────────────────────────────────────────────
# Runs before RomM's normal entrypoint.
#   1. Compiles each native plugin under plugins/*/ if not already cached.
#   2. Patches roms_handler.py to call into the plugin system.
#   3. Hands off to the real entrypoint.
#
# Patching strategy (most-to-least resilient):
#   a. Exact SHA match  → copy pre-patched file (guaranteed correct)
#   b. Patch applies    → apply unified diff (survives minor upstream changes)
#   c. Neither          → warn, skip, RomM runs normally with pure Python
#
# Plugins are plain C-ABI shared libraries (see include/romm_plugin_abi.h,
# plugins/README.md) loaded at runtime by src/plugin_manager.py via ctypes.
# Unlike the old single CPython extension this replaced, they need no Python
# headers and have no CPython-ABI coupling at all -- a compiled .so here
# works unmodified across every RomM/Python version, so (unlike the old
# _fasthash.so) it never needs to be rebuilt just because RomM bumped its
# Python minor version.
# ─────────────────────────────────────────────────────────────────────────────

PLUGIN_DIR="/romm-plugin"
SRC_DIR="$PLUGIN_DIR/src"
PLUGINS_ROOT="$PLUGIN_DIR/plugins"

TARGET_PY="/backend/handler/filesystem/roms_handler.py"
PATCH_FILE="$PLUGIN_DIR/roms_handler.patch"
PREPATCHED_DIR="$PLUGIN_DIR/overrides/prepatched"
KNOWN_SHA_FILE="$PLUGIN_DIR/known_sha256.txt"

PYTHON=$(command -v python3.13 2>/dev/null || command -v python3 2>/dev/null || echo "python3")

log() { echo "[fast-scan] $*"; }

# ── 1. Compile native plugins ─────────────────────────────────────────────────
# Self-contained (doesn't shell out to scripts/build-plugins.sh) so start.sh
# keeps working even on a minimal deployment that only copied the plugin
# directory itself -- same reasoning as the old compile_extension() being
# self-contained rather than depending on another script being present.
compile_plugins() {
    [ -d "$PLUGINS_ROOT" ] || { log "No $PLUGINS_ROOT -- skipping plugin compilation"; return; }

    NEED_BUILD=0
    for src_c in "$PLUGINS_ROOT"/*/*.c; do
        [ -f "$src_c" ] || continue
        plugin_dir=$(dirname "$src_c")
        so_file=$("$PYTHON" -c "import json,sys; print(json.load(open(sys.argv[1]))['so_file'])" "$plugin_dir/plugin.json.tmpl" 2>/dev/null) || continue
        [ -f "$plugin_dir/$so_file" ] || NEED_BUILD=1
    done

    if [ "$NEED_BUILD" = "0" ]; then
        log "All plugins cached, nothing to compile"
        return
    fi

    INSTALLED_TOOLS=0
    if ! command -v gcc > /dev/null 2>&1 || ! command -v cc > /dev/null 2>&1; then
        log "Installing build tools for plugin compilation..."
        apk add --no-cache gcc musl-dev openssl-dev zlib-dev > /dev/null 2>&1 \
            && INSTALLED_TOOLS=1 \
            || { log "Cannot install build tools -- plugins unavailable, using pure Python fallback"; return; }
    fi

    for tmpl in "$PLUGINS_ROOT"/*/plugin.json.tmpl; do
        [ -f "$tmpl" ] || continue
        plugin_dir=$(dirname "$tmpl")
        plugin_name=$(basename "$plugin_dir")
        so_file=$("$PYTHON" -c "import json,sys; print(json.load(open(sys.argv[1]))['so_file'])" "$tmpl" 2>/dev/null)
        src_c=$(find "$plugin_dir" -maxdepth 1 -name '*.c' | head -1)

        [ -n "$so_file" ] && [ -n "$src_c" ] || { log "Skipping $plugin_name: malformed plugin (no so_file/source)"; continue; }
        [ -f "$plugin_dir/$so_file" ] && { log "Cached: $plugin_dir/$so_file"; continue; }

        case "$plugin_name" in
            fasthash) LDFLAGS="-lssl -lcrypto -lz -lpthread" ;;
            *)        LDFLAGS="" ;;
        esac

        log "Compiling $plugin_name -> $so_file ..."
        if cc -O2 -std=c99 -fPIC -shared \
              -I "$PLUGIN_DIR/include" \
              -o "$plugin_dir/$so_file" \
              "$src_c" \
              $LDFLAGS \
              > /dev/null 2>&1
        then
            SHA256=$(sha256sum "$plugin_dir/$so_file" | awk '{print $1}')
            "$PYTHON" - "$tmpl" "$plugin_dir/plugin.json" "$SHA256" << 'PYEOF'
import json, sys
meta = json.load(open(sys.argv[1]))
meta["sha256"] = sys.argv[3]
json.dump(meta, open(sys.argv[2], "w"), indent=2)
PYEOF
            log "Built: $plugin_dir/$so_file"
        else
            log "Compile failed for $plugin_name -- that hook falls back to pure Python"
            rm -f "$plugin_dir/$so_file"
        fi
    done

    if [ "$INSTALLED_TOOLS" = "1" ]; then
        apk del gcc musl-dev openssl-dev zlib-dev > /dev/null 2>&1 || true
        log "Removed build tools"
    fi
}

compile_plugins || true

# ── 2. Patch roms_handler.py ─────────────────────────────────────────────────

patch_handler() {
    [ -f "$TARGET_PY" ] || { log "Target $TARGET_PY not found — skipping patch"; return; }

    # Already-patched check: roms_handler.py lives in the container's own
    # filesystem, not a host bind mount, so it persists across restarts of
    # the *same* container instance -- a previous boot's successful tier-a/b
    # patch is still there on the next boot. Without this check, tier-a's
    # SHA lookup (which only maps *unpatched* upstream SHAs) and tier-b's
    # `patch --dry-run` (which correctly refuses to re-apply an
    # already-applied patch) both "fail" here even though nothing is wrong
    # -- every restart after the first successful patch would otherwise log
    # a false "Could not patch" warning claiming hashing fell back to pure
    # Python when it never did. Checked first, before computing CURRENT_SHA
    # below, since there's nothing left to diagnose if this is already true.
    if grep -q "import plugin_manager as _pm" "$TARGET_PY" 2>/dev/null; then
        log "roms_handler.py already patched (plugin_manager integration present)"
        return
    fi

    # Computed once up front (not nested in the tier-1 branch below) so it's
    # always available for the diagnostic message at the bottom if every tier
    # fails -- the single most useful piece of information for figuring out
    # why, since it's exactly what a new/unrecognized version's SHA looks like.
    CURRENT_SHA=$(sha256sum "$TARGET_PY" 2>/dev/null | awk '{print $1}')

    # a. Exact SHA match: safe to copy the matching pre-patched file directly.
    #    known_sha256.txt maps each known UNPATCHED upstream SHA to its own
    #    pre-patched file, so multiple RomM versions are supported at once.
    if [ -f "$KNOWN_SHA_FILE" ] && [ -d "$PREPATCHED_DIR" ] && [ -n "$CURRENT_SHA" ]; then
        # Read "<sha> <filename>" lines, skipping comments and blanks.
        MATCH_FILE=$(awk -v cur="$CURRENT_SHA" \
            '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} $1==cur {print $2; exit}' \
            "$KNOWN_SHA_FILE")
        if [ -n "$MATCH_FILE" ] && [ -f "$PREPATCHED_DIR/$MATCH_FILE" ]; then
            cp "$PREPATCHED_DIR/$MATCH_FILE" "$TARGET_PY" \
                && log "Installed roms_handler.py (exact match: $MATCH_FILE)" \
                && return
        fi
    fi

    # b. Try to apply the unified diff patch (survives minor upstream changes)
    PATCH_DRY_RUN_OUTPUT=""
    if [ -f "$PATCH_FILE" ]; then
        # Install patch utility if missing
        if ! command -v patch > /dev/null 2>&1; then
            apk add --no-cache patch > /dev/null 2>&1 || true
        fi

        if command -v patch > /dev/null 2>&1; then
            # Dry-run first so we never leave a half-patched file. Capture its
            # output (normally discarded) so a failure here can say *why*.
            PATCH_DRY_RUN_OUTPUT=$(patch --dry-run -N -s "$TARGET_PY" "$PATCH_FILE" 2>&1)
            if [ $? -eq 0 ]; then
                patch -N -s "$TARGET_PY" "$PATCH_FILE" 2>/dev/null \
                    && log "Applied roms_handler.py patch" \
                    && return
            fi
        fi
    fi

    # c. Neither worked — warn loudly but let RomM start normally
    # RomM isn't pip-installed under a "romm" distribution name, so
    # importlib.metadata.version('romm') always raises -- read the same
    # __version__.py that /init's own print_banner() reads (relative to
    # /backend, which is why that's hardcoded here rather than relying on
    # start.sh's own cwd).
    ROMM_VER=$("$PYTHON" -c "exec(open('/backend/__version__.py').read()); print(__version__)" 2>/dev/null || echo "unknown")
    log "WARNING: Could not patch roms_handler.py."
    log "         RomM has likely updated. Any compiled plugins are still there,"
    log "         but hashing falls back to pure Python until you update the plugin."
    log "         RomM version:  $ROMM_VER"
    log "         Current SHA256: ${CURRENT_SHA:-<sha256sum failed>}"
    if [ -n "$PATCH_DRY_RUN_OUTPUT" ]; then
        log "         Patch dry-run said:"
        printf '%s\n' "$PATCH_DRY_RUN_OUTPUT" | while IFS= read -r line; do log "           $line"; done
    fi
    log "         Run:  sh $PLUGIN_DIR/refresh.sh  to regenerate the patch."
}

patch_handler

# ── 3. Add src dir to PYTHONPATH ─────────────────────────────────────────────
# src holds plugin_manager.py (loads plugins/*/*.so via ctypes -- the .so
# itself is never imported as a Python module, so it doesn't need to be on
# PYTHONPATH the way the old _fasthash.so did) and fast_scan_cache.py (the
# opt-in FAST_SCAN_HASH_CACHE tier-0 path, unrelated to and unaffected by
# the plugin system).
#
# Idempotent: skip prepending if $SRC_DIR is already present anywhere in
# PYTHONPATH. Without this check, a caller that pre-sets PYTHONPATH to
# include $SRC_DIR (as scripts/patch_romm_yaml.py's pod YAML used to, before
# this was made unconditional here and that injection was removed as
# redundant) would end up with it duplicated on every boot -- harmless to
# Python's import machinery, but confusing in logs and a sign something's
# not quite right.
case ":${PYTHONPATH:-}:" in
    *":$SRC_DIR:"*) : ;;  # already present, don't duplicate
    *) export PYTHONPATH="$SRC_DIR:${PYTHONPATH:-/backend}" ;;
esac
log "PYTHONPATH=$PYTHONPATH"

# ── 4. Apply the LIBRARY_SIZE tuning profile ─────────────────────────────────
# LIBRARY_SIZE selects a small set of size-appropriate defaults. The whole
# point is that the plugin stays a *pure passthrough* out of the box -- it
# only makes scans faster and changes nothing else about RomM's behavior --
# unless you deliberately opt into a heavier profile.
#
#   DEFAULT (or unset) -- INVARIANT: sets nothing at all. Inherits every RomM
#                         default exactly as *this version of RomM* ships them.
#                         There are deliberately no plugin-pinned constants in
#                         this branch -- not even a "4h" -- so DEFAULT tracks
#                         whatever RomM itself defaults to, on any version, for
#                         ever. Stock RomM behavior, just faster hashing.
#   LARGE              -- raises only the knobs whose RomM stock default is too
#                         tight for a big library. Currently: SCAN_TIMEOUT.
#
# RomM enqueues each scan as an RQ background job with job_timeout=SCAN_TIMEOUT
# (RomM's own config default -- 4h on today's supported versions), used for
# both manual scans (endpoints/sockets/scan.py) and the filesystem watcher's
# auto-rescans (watcher.py). RQ hard-kills the job at that limit -- so a
# library that legitimately takes longer gets cut off mid-scan even though
# nothing is wrong. LARGE raises that default to 24h.
#
# Every knob a profile sets uses the `${VAR:-...}` form, so an explicitly-set
# value always wins -- the profile only supplies a smarter *default*, it never
# overrides a choice you made yourself. Room to add more knobs to LARGE (and
# more profiles) later without changing this contract.
LIBRARY_SIZE="${LIBRARY_SIZE:-DEFAULT}"
case "$LIBRARY_SIZE" in
    DEFAULT|default)
        log "LIBRARY_SIZE=DEFAULT (passthrough -- stock RomM behavior, just faster hashing)"
        ;;
    LARGE|large)
        export SCAN_TIMEOUT="${SCAN_TIMEOUT:-86400}"
        log "LIBRARY_SIZE=LARGE (SCAN_TIMEOUT=$SCAN_TIMEOUT; set SCAN_TIMEOUT to override)"
        ;;
    *)
        log "WARNING: unknown LIBRARY_SIZE='$LIBRARY_SIZE' -- treating as DEFAULT (passthrough)."
        log "         Known profiles: DEFAULT, LARGE. See README's \"Library size profiles\"."
        ;;
esac

# ── 5. Hand off to RomM's real entrypoint ───────────────────────────────────
log "Starting RomM..."
exec /docker-entrypoint.sh /init
