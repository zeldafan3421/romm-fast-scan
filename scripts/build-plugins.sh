#!/bin/sh
# scripts/build-plugins.sh
# Compiles every native plugin under plugins/*/ and writes a finalized
# plugin.json (with the real sha256 of the freshly-built .so) alongside it.
#
# Unlike the old CPython-extension build (compile_extension() in start.sh),
# these plugins need no Python headers and don't depend on the target
# RomM image's Python version at all -- they only need libssl-dev/zlib-dev
# (fasthash) or nothing beyond libc (archive-list). One build per (arch,
# libc) target is enough for every RomM version, forever, unlike the old
# per-Python-ABI .so that had to be rebuilt to match whatever Python each
# RomM image happened to ship.
#
# Usage:
#   sh scripts/build-plugins.sh              # builds every plugins/*/*.c
#   sh scripts/build-plugins.sh fasthash      # build just one plugin
# ─────────────────────────────────────────────────────────────────────────────

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PLUGINS_DIR="$REPO_ROOT/plugins"

CC="${CC:-cc}"

log() { echo "[build-plugins] $*"; }

sha256_of() {
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

build_one() {
    plugin_dir="$1"
    name="$(basename "$plugin_dir")"
    tmpl="$plugin_dir/plugin.json.tmpl"

    if [ ! -f "$tmpl" ]; then
        log "skip $name: no plugin.json.tmpl"
        return
    fi

    # so_file comes from the template; link flags can't live cleanly in
    # JSON, so they're special-cased per plugin name below. Add a case when
    # you add a plugin whose link flags differ from "none".
    so_file=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['so_file'])" "$tmpl")
    src_file=$(find "$plugin_dir" -maxdepth 1 -name '*.c' | head -1)

    if [ -z "$src_file" ]; then
        log "skip $name: no .c source file found"
        return
    fi

    case "$name" in
        fasthash)
            LDFLAGS="-lssl -lcrypto -lz -lpthread"
            ;;
        *)
            LDFLAGS=""
            ;;
    esac

    log "building $name ($src_file -> $so_file)"
    "$CC" -shared -fPIC -O2 -std=c99 \
        -o "$plugin_dir/$so_file" \
        "$src_file" \
        $LDFLAGS

    sha256=$(sha256_of "$plugin_dir/$so_file")

    python3 - "$tmpl" "$plugin_dir/plugin.json" "$sha256" << 'PYEOF'
import json, sys
tmpl_path, out_path, sha256 = sys.argv[1], sys.argv[2], sys.argv[3]
meta = json.load(open(tmpl_path))
meta["sha256"] = sha256
with open(out_path, "w") as f:
    json.dump(meta, f, indent=2)
    f.write("\n")
PYEOF

    sha256_short=$(echo "$sha256" | cut -c1-12)
    log "wrote $plugin_dir/plugin.json (sha256=${sha256_short}...)"
}

if [ -n "${1:-}" ]; then
    build_one "$PLUGINS_DIR/$1"
else
    for d in "$PLUGINS_DIR"/*/; do
        [ -f "${d}plugin.json.tmpl" ] && build_one "${d%/}"
    done
fi

log "done"
