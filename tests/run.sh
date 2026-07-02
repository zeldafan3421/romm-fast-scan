#!/bin/sh
# tests/run.sh — build the plugins, then run the synthetic suite.
# ─────────────────────────────────────────────────────────────────────────────
# One command to reproduce this repo's correctness + performance claims:
#
#   sh tests/run.sh                 # correctness + benchmark
#   sh tests/run.sh correctness     # just correctness
#   sh tests/run.sh benchmark       # just the benchmark
#
# It builds the plugins from source (scripts/build-plugins.sh) and runs with
# FAST_SCAN_ALLOW_UNSIGNED_PLUGINS=1, because a locally-built plugin is
# unsigned -- only this repo's CI holds the signing key (see plugins/
# README.md "Signing and FAST_SCAN_ALLOW_UNSIGNED_PLUGINS"). Needs a C
# compiler + the fasthash plugin's build deps (openssl/zlib headers); the
# same toolchain scripts/build-plugins.sh already documents.
#
# Fixtures are generated under a temp dir and removed on exit. Total on-disk
# footprint is a bit over 1 GiB while running.
# ─────────────────────────────────────────────────────────────────────────────
set -e

WHAT="${1:-all}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Locally-built plugins are unsigned; the suite is explicitly opting in.
export FAST_SCAN_ALLOW_UNSIGNED_PLUGINS=1

FIXTURES="$(mktemp -d)"
cleanup() { rm -rf "$FIXTURES"; }
trap cleanup EXIT INT TERM

echo "== building plugins from source =="
sh "$REPO_ROOT/scripts/build-plugins.sh"
echo ""

rc=0
if [ "$WHAT" = "all" ] || [ "$WHAT" = "correctness" ]; then
    echo "== correctness =="
    python3 "$SCRIPT_DIR/correctness.py" "$FIXTURES" || rc=$?
    echo ""
fi

if [ "$WHAT" = "all" ] || [ "$WHAT" = "benchmark" ]; then
    echo "== benchmark =="
    python3 "$SCRIPT_DIR/benchmark.py" "$FIXTURES" || rc=$?
fi

exit "$rc"
