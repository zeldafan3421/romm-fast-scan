#!/bin/sh
# fast_scan_plugin/start.sh
# ─────────────────────────────────────────────────────────────────────────────
# Runs before RomM's normal entrypoint.
#   1. Compiles _fasthash.so (C extension) inside the container if not cached.
#   2. Patches roms_handler.py to use the C fast path.
#   3. Hands off to the real entrypoint.
#
# Patching strategy (most-to-least resilient):
#   a. Exact SHA match  → copy pre-patched file (guaranteed correct)
#   b. Patch applies    → apply unified diff (survives minor upstream changes)
#   c. Neither          → warn, skip, RomM runs normally with pure Python
# ─────────────────────────────────────────────────────────────────────────────

PLUGIN_DIR="/romm-plugin"
LIB_DIR="$PLUGIN_DIR/lib"
SRC_DIR="$PLUGIN_DIR/src"

TARGET_PY="/backend/handler/filesystem/roms_handler.py"
PATCH_FILE="$PLUGIN_DIR/roms_handler.patch"
PREPATCHED_DIR="$PLUGIN_DIR/overrides/prepatched"
KNOWN_SHA_FILE="$PLUGIN_DIR/known_sha256.txt"

PYTHON=$(command -v python3.13 2>/dev/null || command -v python3 2>/dev/null || echo "python3")

log() { echo "[fast-scan] $*"; }

# ── 1. Compile _fasthash extension ───────────────────────────────────────────
compile_extension() {
    EXT_SUFFIX=$("$PYTHON" -c "import sysconfig; print(sysconfig.get_config_var('EXT_SUFFIX'))" 2>/dev/null)
    [ -z "$EXT_SUFFIX" ] && { log "Cannot determine EXT_SUFFIX — skipping compile"; return 1; }

    TARGET_SO="$LIB_DIR/_fasthash${EXT_SUFFIX}"

    if [ -f "$TARGET_SO" ]; then
        log "Cached: $TARGET_SO"
        return 0
    fi

    log "Compiling _fasthash extension for $EXT_SUFFIX ..."

    INSTALLED_TOOLS=0
    if ! command -v gcc > /dev/null 2>&1; then
        log "Installing build tools..."
        apk add --no-cache gcc musl-dev openssl-dev zlib-dev > /dev/null 2>&1 \
            && INSTALLED_TOOLS=1 \
            || { log "Cannot install build tools — using pure Python fallback"; return 1; }
    fi

    INC=$("$PYTHON" -c "import sysconfig; print(sysconfig.get_path('include'))" 2>/dev/null)
    mkdir -p "$LIB_DIR"

    gcc -O2 -std=c99 -Wall -fPIC -shared \
        -o "$TARGET_SO" \
        "$SRC_DIR/_fasthash.c" \
        -I"$INC" \
        -lssl -lcrypto -lz \
        > /dev/null 2>&1 \
        && log "Built: $TARGET_SO" \
        || { log "Compile failed — using pure Python fallback"; rm -f "$TARGET_SO"; }

    if [ "$INSTALLED_TOOLS" = "1" ]; then
        apk del gcc musl-dev openssl-dev zlib-dev > /dev/null 2>&1 || true
        log "Removed build tools"
    fi
}

compile_extension || true

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
    log "         RomM has likely updated. The C extension is compiled but"
    log "         hashing falls back to pure Python until you update the plugin."
    log "         RomM version:  $ROMM_VER"
    log "         Current SHA256: ${CURRENT_SHA:-<sha256sum failed>}"
    if [ -n "$PATCH_DRY_RUN_OUTPUT" ]; then
        log "         Patch dry-run said:"
        printf '%s\n' "$PATCH_DRY_RUN_OUTPUT" | while IFS= read -r line; do log "           $line"; done
    fi
    log "         Run:  sh $PLUGIN_DIR/refresh.sh  to regenerate the patch."
}

patch_handler

# ── 3. Add lib + src dirs to PYTHONPATH ──────────────────────────────────────
# lib holds the compiled _fasthash.so; src holds the pure-Python
# fast_scan_cache helper (used by the opt-in FAST_SCAN_HASH_CACHE path).
export PYTHONPATH="$LIB_DIR:$SRC_DIR:${PYTHONPATH:-/backend}"
log "PYTHONPATH=$PYTHONPATH"

# ── 4. Hand off to RomM's real entrypoint ───────────────────────────────────
log "Starting RomM..."
exec /docker-entrypoint.sh /init
