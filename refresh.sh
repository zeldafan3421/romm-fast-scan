#!/bin/sh
# fast_scan_plugin/refresh.sh
# ─────────────────────────────────────────────────────────────────────────────
# Run this INSIDE a running RomM container after a RomM update breaks the patch.
# It pulls the current roms_handler.py, re-applies the fast-scan changes,
# and updates the plugin files so the next container restart works.
#
# Usage (from the host):
#   podman exec <romm-app-container-id> sh /romm-plugin/refresh.sh
# ─────────────────────────────────────────────────────────────────────────────

set -e

PLUGIN_DIR="/romm-plugin"
STOCK_PY="/backend/handler/filesystem/roms_handler.py"
PATCH_FILE="$PLUGIN_DIR/roms_handler.patch"
OVERRIDE_PY="$PLUGIN_DIR/overrides/handler/filesystem/roms_handler.py"
KNOWN_SHA_FILE="$PLUGIN_DIR/known_sha256.txt"
PYTHON=$(command -v python3.13 2>/dev/null || command -v python3 2>/dev/null || echo "python3")

log() { echo "[refresh] $*"; }

[ -f "$STOCK_PY" ] || { echo "ERROR: $STOCK_PY not found"; exit 1; }

# Install tools we need
for pkg in patch diffutils; do
    command -v patch > /dev/null 2>&1 && break
    apk add --no-cache "$pkg" > /dev/null 2>&1 || true
done
command -v patch > /dev/null 2>&1 || { echo "ERROR: cannot install patch utility"; exit 1; }

# Record new SHA
NEW_SHA=$(sha256sum "$STOCK_PY" | awk '{print $1}')
ROMM_VER=$(python3 -c "import importlib.metadata; print(importlib.metadata.version('romm'))" 2>/dev/null || echo "unknown")
log "Stock roms_handler.py SHA: $NEW_SHA (RomM $ROMM_VER)"

# Apply existing patch to a temp copy to produce the new patched file
TMP_STOCK=$(mktemp)
TMP_PATCHED=$(mktemp)
cp "$STOCK_PY" "$TMP_STOCK"

log "Checking if existing patch still applies..."
if patch --dry-run -N -s "$TMP_STOCK" "$PATCH_FILE" 2>/dev/null; then
    cp "$TMP_STOCK" "$TMP_PATCHED"
    patch -N -s "$TMP_PATCHED" "$PATCH_FILE" 2>/dev/null
    log "Existing patch applied cleanly — no regeneration needed."
    log "Updating known_sha256.txt for new version..."
    printf '%s  roms_handler.py (RomM %s)\n' "$NEW_SHA" "$ROMM_VER" > "$KNOWN_SHA_FILE"
    cp "$TMP_PATCHED" "$OVERRIDE_PY"
    rm -f "$TMP_STOCK" "$TMP_PATCHED"
    log "Done. Restart the pod to activate."
    exit 0
fi

log "Existing patch does not apply. Regenerating..."

# Re-apply our known changes programmatically using Python
"$PYTHON" - "$TMP_STOCK" "$TMP_PATCHED" << 'PYEOF'
import sys, re

src = open(sys.argv[1]).read()
out = src

# ── Insert _fh import after `import zlib` ────────────────────────────────────
IMPORT_ANCHOR = "import zlib\nfrom dataclasses"
IMPORT_INSERT = (
    "import zlib\n"
    "\ntry:\n"
    "    import _fasthash as _fh\n"
    "except ImportError:\n"
    "    _fh = None\n"
    "from dataclasses"
)
if "_fasthash" not in out:
    count = out.count(IMPORT_ANCHOR)
    if count == 1:
        out = out.replace(IMPORT_ANCHOR, IMPORT_INSERT, 1)
    else:
        print(f"WARNING: import anchor not found (count={count}), skipping import injection", file=sys.stderr)

# ── Add _DEFAULT_*_HEX constants ─────────────────────────────────────────────
SHA1_ANCHOR = "DEFAULT_SHA1_H_DIGEST = hashlib.sha1(usedforsecurity=False).digest()"
SHA1_REPLACE = (
    SHA1_ANCHOR + "\n"
    "_DEFAULT_MD5_HEX = hashlib.md5(usedforsecurity=False).hexdigest()\n"
    "_DEFAULT_SHA1_HEX = hashlib.sha1(usedforsecurity=False).hexdigest()"
)
if "_DEFAULT_MD5_HEX" not in out:
    count = out.count(SHA1_ANCHOR)
    if count == 1:
        out = out.replace(SHA1_ANCHOR, SHA1_REPLACE, 1)
    else:
        print(f"WARNING: SHA1_ANCHOR not found (count={count})", file=sys.stderr)

# ── Add rom_md5_hex / rom_sha1_hex variables ─────────────────────────────────
RA_ANCHOR = '        rom_ra_h = ""\n'
RA_REPLACE = (
    '        rom_ra_h = ""\n'
    '        rom_md5_hex: str | None = None   # set by _fh fast path; overrides rom_md5_h at return\n'
    '        rom_sha1_hex: str | None = None\n'
)
if "rom_md5_hex" not in out:
    count = out.count(RA_ANCHOR)
    if count == 1:
        out = out.replace(RA_ANCHOR, RA_REPLACE, 1)
    else:
        print(f"WARNING: rom_ra_h anchor not found (count={count})", file=sys.stderr)

# ── Replace single-file hashable_platform branch ─────────────────────────────
# Find the elif hashable_platform: block that follows archive handling.
# We identify it by looking for the _calculate_rom_hashes call pattern
# that updates rom_crc_c/rom_md5_h/rom_sha1_h.

OLD_BRANCH_PATTERN = re.compile(
    r'(        elif hashable_platform:\n)'
    r'(            try:\n'
    r'                crc_c, rom_crc_c, md5_h, rom_md5_h, sha1_h, rom_sha1_h = \(\n'
    r'                    await asyncio\.to_thread\(\n'
    r'                        self\._calculate_rom_hashes,\n'
    r'                        Path\(abs_fs_path, rom\.fs_name\),\n'
    r'                        rom_crc_c,\n'
    r'                        rom_md5_h,\n'
    r'                        rom_sha1_h,\n'
    r'                    \)\n'
    r'                \)\n'
    r'            \)?\s*except zlib\.error:\n'
    r'                crc_c = 0\n'
    r'                md5_h = hashlib\.md5\(usedforsecurity=False\)\n'
    r'                sha1_h = hashlib\.sha1\(usedforsecurity=False\)\n)',
    re.MULTILINE,
)

NEW_BRANCH_HEADER = (
    "        elif hashable_platform:\n"
    "            _used_fast_path = False\n"
    "            if _fh is not None and rom_ext not in ARCHIVE_READERS:\n"
    "                # Fast C path: GIL-released CRC32+MD5+SHA1 in one pass\n"
    "                try:\n"
    "                    f_crc_hex, f_md5_hex, f_sha1_hex = await asyncio.to_thread(\n"
    "                        _fh.hash_file, str(Path(abs_fs_path, rom.fs_name))\n"
    "                    )\n"
    "                    _used_fast_path = True\n"
    "                except Exception:\n"
    "                    pass  # fall through to Python path below\n"
    "\n"
    "            if _used_fast_path:\n"
    "                rom_crc_c = int(f_crc_hex, 16)\n"
    '                rom_md5_hex = f_md5_hex if f_md5_hex != _DEFAULT_MD5_HEX else ""\n'
    '                rom_sha1_hex = f_sha1_hex if f_sha1_hex != _DEFAULT_SHA1_HEX else ""\n'
    "                file_hash = FileHash(\n"
    '                    crc_hash=f_crc_hex if rom_crc_c != DEFAULT_CRC_C else "",\n'
    "                    md5_hash=rom_md5_hex,\n"
    "                    sha1_hash=rom_sha1_hex,\n"
    "                    chd_sha1_hash=(\n"
    "                        extract_chd_hash(rom_dir) if is_chd_file(rom_dir) else \"\"\n"
    "                    ),\n"
    "                )\n"
    "            else:\n"
    "                # Python path: archive files, or _fh unavailable/failed\n"
    "                try:\n"
    "                    crc_c, rom_crc_c, md5_h, rom_md5_h, sha1_h, rom_sha1_h = (\n"
    "                        await asyncio.to_thread(\n"
    "                            self._calculate_rom_hashes,\n"
    "                            Path(abs_fs_path, rom.fs_name),\n"
    "                            rom_crc_c,\n"
    "                            rom_md5_h,\n"
    "                            rom_sha1_h,\n"
    "                        )\n"
    "                    )\n"
    "                except zlib.error:\n"
    "                    crc_c = 0\n"
    "                    md5_h = hashlib.md5(usedforsecurity=False)\n"
    "                    sha1_h = hashlib.sha1(usedforsecurity=False)\n"
)

if "_used_fast_path" not in out:
    m = OLD_BRANCH_PATTERN.search(out)
    if m:
        out = out[:m.start()] + NEW_BRANCH_HEADER + out[m.end():]
    else:
        print("WARNING: single-file elif branch not found — fast path not injected", file=sys.stderr)

# ── Fix _make_file_hash call that follows the branch ─────────────────────────
# In older versions it appeared after the elif block; in newer it's inside the else.
# If it's still outside (Python fallback didn't capture it), move it in.
ORPHAN_HASH = (
    "\n            file_hash = _make_file_hash(\n"
    "                crc_c,\n"
    "                md5_h,\n"
    "                sha1_h,\n"
    "                chd_sha1_hash=(\n"
    "                    extract_chd_hash(rom_dir) if is_chd_file(rom_dir) else \"\"\n"
    "                ),\n"
    "            )\n"
)
ELSE_HASH = (
    "                file_hash = _make_file_hash(\n"
    "                    crc_c,\n"
    "                    md5_h,\n"
    "                    sha1_h,\n"
    "                    chd_sha1_hash=(\n"
    "                        extract_chd_hash(rom_dir) if is_chd_file(rom_dir) else \"\"\n"
    "                    ),\n"
    "                )\n"
)
# Remove orphan if it appears between elif and # Calculate the RA hash
if ORPHAN_HASH in out and ELSE_HASH not in out:
    out = out.replace(ORPHAN_HASH, "\n", 1)

# ── Update ParsedRomFiles return to use hex overrides ────────────────────────
OLD_RETURN = (
    "            md5_hash=(\n"
    "                rom_md5_h.hexdigest()\n"
    "                if rom_md5_h and rom_md5_h.digest() != DEFAULT_MD5_H_DIGEST\n"
    "                else \"\"\n"
    "            ),\n"
    "            sha1_hash=(\n"
    "                rom_sha1_h.hexdigest()\n"
    "                if rom_sha1_h and rom_sha1_h.digest() != DEFAULT_SHA1_H_DIGEST\n"
    "                else \"\"\n"
    "            ),\n"
)
NEW_RETURN = (
    "            md5_hash=(\n"
    "                rom_md5_hex\n"
    "                if rom_md5_hex is not None\n"
    "                else (\n"
    "                    rom_md5_h.hexdigest()\n"
    "                    if rom_md5_h and rom_md5_h.digest() != DEFAULT_MD5_H_DIGEST\n"
    "                    else \"\"\n"
    "                )\n"
    "            ),\n"
    "            sha1_hash=(\n"
    "                rom_sha1_hex\n"
    "                if rom_sha1_hex is not None\n"
    "                else (\n"
    "                    rom_sha1_h.hexdigest()\n"
    "                    if rom_sha1_h and rom_sha1_h.digest() != DEFAULT_SHA1_H_DIGEST\n"
    "                    else \"\"\n"
    "                )\n"
    "            ),\n"
)
if "rom_md5_hex\n                if rom_md5_hex is not None" not in out:
    count = out.count(OLD_RETURN)
    if count == 1:
        out = out.replace(OLD_RETURN, NEW_RETURN, 1)
    else:
        print(f"WARNING: ParsedRomFiles return not patched (count={count})", file=sys.stderr)

open(sys.argv[2], "w").write(out)
print("Python re-patch complete.")
PYEOF

if [ $? -ne 0 ]; then
    log "ERROR: Python re-patch script failed."
    rm -f "$TMP_STOCK" "$TMP_PATCHED"
    exit 1
fi

# Verify the result looks sane
if ! grep -q "_fasthash" "$TMP_PATCHED"; then
    log "ERROR: Re-patched file is missing _fasthash — aborting."
    rm -f "$TMP_STOCK" "$TMP_PATCHED"
    exit 1
fi

# Generate new patch from stock → patched
diff -u "$TMP_STOCK" "$TMP_PATCHED" > "$PATCH_FILE" || true

# Update stored override and SHA
cp "$TMP_PATCHED" "$OVERRIDE_PY"
printf '%s  roms_handler.py (RomM %s)\n' "$NEW_SHA" "$ROMM_VER" > "$KNOWN_SHA_FILE"

rm -f "$TMP_STOCK" "$TMP_PATCHED"

log "Regenerated roms_handler.patch and updated known_sha256.txt."
log "Done. Restart the pod to activate the fast path."
