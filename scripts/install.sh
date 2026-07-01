#!/bin/sh
# scripts/install.sh
# Run this ONCE on the host to deploy the plugin (volume-mount method).
# Usage:  sh scripts/install.sh [/path/to/dest]
#
# DEPRECATED for RomM versions that already have a published fast-scan
# image (currently 4.9.2) -- see README.md for the one-line `image:` swap,
# which needs none of this. This script stays the right tool for RomM
# versions without a published image yet; patch_romm_yaml.py (the next
# step) checks the target version and blocks with a pointer to the image
# swap if one already exists for it, so you'll be told either way.
# ─────────────────────────────────────────────────────────────────────────────

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
DEST="${1:-/opt/romm/fast-scan-plugin}"

echo "=== romm-fast-scan plugin installer (volume-mount method) ==="
echo ""
echo "NOTE: if your RomM version already has a published fast-scan image,"
echo "the one-line 'image:' swap in README.md is simpler and recommended"
echo "instead of this. patch_romm_yaml.py (step 2 below) will check and"
echo "tell you if that's the case for your version."
echo ""

# ── 1. Copy plugin files to the service data directory ───────────────────────
echo "→ Installing plugin files to: $DEST"
mkdir -p "$DEST/lib"
cp -r "$REPO_ROOT/src"               "$DEST/"
cp -r "$REPO_ROOT/overrides"         "$DEST/"
cp    "$REPO_ROOT/start.sh"          "$DEST/"
cp    "$REPO_ROOT/roms_handler.patch" "$DEST/"
cp    "$REPO_ROOT/known_sha256.txt"  "$DEST/"
cp    "$SCRIPT_DIR/refresh.sh"       "$DEST/"
chmod +x "$DEST/start.sh" "$DEST/refresh.sh"
touch "$DEST/lib/.gitkeep"

echo "  Done."
echo ""
echo "  To remove the plugin later, run: sh $SCRIPT_DIR/uninstall.sh $DEST"
echo ""

# ── 2. Patch your pod YAML ────────────────────────────────────────────────────
echo "→ Next, wire the plugin into your pod YAML:"
echo "    python3 $SCRIPT_DIR/patch_romm_yaml.py /path/to/romm.yml $DEST"
echo ""
echo "  This backs up romm.yml and adds the entrypoint override, PYTHONPATH,"
echo "  and volume mount needed to load the plugin. See"
echo "  $REPO_ROOT/examples/romm.patched.example.yml for the expected result."

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
