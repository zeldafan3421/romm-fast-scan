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
    ROMM_VER=$("$PYTHON" -c "import importlib.metadata; print(importlib.metadata.version('romm'))" 2>/dev/null || echo "unknown")
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
export PYTHONPATH="$SRC_DIR:${PYTHONPATH:-/backend}"
log "PYTHONPATH=$PYTHONPATH"

# ── 4. Hand off to RomM's real entrypoint ───────────────────────────────────
log "Starting RomM..."
exec /docker-entrypoint.sh /init
