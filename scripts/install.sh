#!/bin/sh
# fast_scan_plugin/install.sh
# Run this ONCE on the host to deploy the plugin.
# Usage:  sh install.sh [--plugin-dest /path/to/dest]
# ─────────────────────────────────────────────────────────────────────────────

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="${1:-/opt/romm/fast-scan-plugin}"

echo "=== romm-fast-scan plugin installer ==="
echo ""

# ── 1. Copy plugin files to the service data directory ───────────────────────
echo "→ Installing plugin files to: $DEST"
mkdir -p "$DEST/lib"
cp -r "$SCRIPT_DIR/src"       "$DEST/"
cp -r "$SCRIPT_DIR/overrides" "$DEST/"
cp    "$SCRIPT_DIR/start.sh"  "$DEST/"
chmod +x "$DEST/start.sh"
touch "$DEST/lib/.gitkeep"

echo "  Done."
echo ""

# ── 2. Check for the patched romm.yml ────────────────────────────────────────
PATCHED="$(dirname "$SCRIPT_DIR")/romm.patched.yml"

if [ -f "$PATCHED" ]; then
    echo "→ A ready-to-use pod YAML is at:"
    echo "    $PATCHED"
    echo ""
    echo "  To apply it:"
    echo "    podman pod stop  romm-pod  2>/dev/null || true"
    echo "    podman pod rm    romm-pod  2>/dev/null || true"
    echo "    podman play kube $PATCHED"
    echo ""
    echo "  Or if you prefer to keep your existing romm.yml, the three changes"
    echo "  you need are shown in the diff below:"
    echo ""
    diff "$(dirname "$SCRIPT_DIR")/romm.yml" "$PATCHED" || true
else
    echo "  (romm.patched.yml not found — diff skipped)"
fi

# ── 3. Sanity check ──────────────────────────────────────────────────────────
echo ""
echo "→ Installed files:"
find "$DEST" -not -path "$DEST/lib" | sort | sed "s|$DEST|  plugin:|"

echo ""
echo "=== Install complete ==="
echo ""
echo "On next pod start, start.sh will:"
echo "  1. Compile _fasthash.so inside the container (takes ~5 s, one time only)"
echo "  2. Patch roms_handler.py"
echo "  3. Start RomM normally"
echo ""
echo "If anything fails, RomM falls back to pure Python — no data is at risk."
