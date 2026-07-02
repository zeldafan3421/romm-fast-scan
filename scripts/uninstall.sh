#!/bin/sh
# scripts/uninstall.sh
# Removes the romm-fast-scan plugin from a host.
# Usage:  sh scripts/uninstall.sh [/path/to/plugin/dest] [/path/to/romm.yml]
#
# This script:
#   1. Reverts romm.yml to stock RomM (if a yml path is given)
#   2. Removes the plugin directory from the host
#   3. Does NOT touch your library, RomM database, or any RomM data —
#      it only removes plugin files and the romm.yml changes it made
# ─────────────────────────────────────────────────────────────────────────────

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="${1:-/opt/romm/fast-scan-plugin}"
YML="${2:-}"

echo "=== romm-fast-scan plugin uninstaller ==="
echo ""

# ── 1. Unpatch romm.yml (if given) ───────────────────────────────────────────
YML_CHANGED=0
if [ -n "$YML" ]; then
    if [ -f "$YML" ]; then
        if grep -q "/romm-plugin/start.sh" "$YML" 2>/dev/null; then
            echo "→ Reverting $YML to stock RomM..."
            python3 "$SCRIPT_DIR/unpatch_romm_yaml.py" "$YML"
            YML_CHANGED=1
            echo ""
        else
            echo "→ $YML doesn't contain the plugin patch — nothing to revert."
            echo ""
        fi
    else
        echo "→ Skipping romm.yml revert: '$YML' not found"
        echo ""
    fi
else
    echo "→ No romm.yml path given — skipping the pod YAML revert."
    echo "  Run this to also remove the plugin's changes from your pod YAML:"
    echo "    python3 $SCRIPT_DIR/unpatch_romm_yaml.py /path/to/romm.yml"
    echo "  (or restore one of your romm.yml.bak.* backups)"
    echo ""
fi

# ── 2. Remove the plugin directory ───────────────────────────────────────────
if [ -d "$DEST" ]; then
    echo "→ Removing plugin directory: $DEST"
    rm -rf "$DEST"
    echo "  Done."
else
    echo "→ Plugin directory '$DEST' not found — nothing to remove."
fi

echo ""
echo "=== Uninstall complete ==="
echo ""
echo "What was removed:"
echo "  - Plugin files at $DEST (compiled .so, patches, scripts)"
if [ "$YML_CHANGED" = "1" ]; then
    echo "  - Plugin-related entries in $YML (entrypoint, PYTHONPATH,"
    echo "    FAST_SCAN_ALLOW_UNSIGNED_PLUGINS if present, volume mount)"
fi
echo ""
echo "What was NOT touched:"
echo "  - Your ROM library"
echo "  - RomM's database (hashes computed by the C extension are valid RomM"
echo "    hashes and remain in place; nothing needs to be re-scanned)"
echo "  - Any romm.yml.bak.* backups created during install or by"
echo "    unpatch_romm_yaml.py"
echo ""
echo "Next step: restart the pod so it picks up stock RomM behavior:"
echo "  podman pod stop romm-pod 2>/dev/null || true"
echo "  podman pod rm   romm-pod 2>/dev/null || true"
echo "  podman play kube ${YML:-romm.yml}"
