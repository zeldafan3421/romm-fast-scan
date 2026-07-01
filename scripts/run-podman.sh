#!/bin/sh
# scripts/run-podman.sh
# Run RomM + the fast-scan plugin with plain `podman run` -- no compose file,
# no pod YAML. Sets up a network, a MariaDB container, and the RomM
# container using the prebuilt fast-scan image.
#
# Same deployment as examples/romm.release.yml and examples/docker-compose.yml,
# just imperative instead of declarative. If you're on a RomM version without
# a published fast-scan image yet, this isn't for you -- see "Advanced
# install: volume mount" in README.md instead (or examples/romm.release.yml /
# `podman play kube` if you'd rather use the declarative pod YAML this
# project otherwise leads with).
#
# Works rootless -- port 8080 and the volumes/network below need no special
# privileges.
#
# Usage:
#   Edit the variables below, then:  sh scripts/run-podman.sh
#   Or override any of them via environment instead of editing the script:
#   LIBRARY_PATH=/mnt/roms ROMM_AUTH_SECRET_KEY=$(openssl rand -hex 32) \
#     DB_PASSWORD=$(openssl rand -hex 32) DB_ROOT_PASSWORD=$(openssl rand -hex 32) \
#     sh scripts/run-podman.sh
# ─────────────────────────────────────────────────────────────────────────────

set -e

# ── Configuration -- edit these, or export the same names before running ────
LIBRARY_PATH="${LIBRARY_PATH:-/your/games/library}"                # <-- change this
RESOURCES_PATH="${RESOURCES_PATH:-/your/romm/data/resources}"      # <-- change this
REDIS_PATH="${REDIS_PATH:-/your/romm/data/redis-data}"             # <-- change this
ASSETS_PATH="${ASSETS_PATH:-/your/romm/data/assets}"               # <-- change this
CONFIG_PATH="${CONFIG_PATH:-/your/romm/config}"                    # <-- change this

# Three DIFFERENT secrets -- generate with: openssl rand -hex 32
ROMM_AUTH_SECRET_KEY="${ROMM_AUTH_SECRET_KEY:-changeme-auth-generate-with-openssl-rand-hex-32}"
DB_PASSWORD="${DB_PASSWORD:-changeme-db-generate-with-openssl-rand-hex-32}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-changeme-root-generate-with-openssl-rand-hex-32}"

SCAN_WORKERS="${SCAN_WORKERS:-4}"    # HDD: 4-6, SATA SSD: 8-12, NVMe: 12-16 -- see README "Configuration"
HOST_PORT="${HOST_PORT:-8080}"
IMAGE="${IMAGE:-ghcr.io/zeldafan3421/romm-fast-scan:4.9.2-fast-scan}"

NETWORK="romm-net"
DB_VOLUME="romm-mysql-data"

# ── Safety checks ─────────────────────────────────────────────────────────────
case "$ROMM_AUTH_SECRET_KEY" in changeme-*)
    echo "ERROR: ROMM_AUTH_SECRET_KEY is still a placeholder." >&2
    echo "  Generate one with: openssl rand -hex 32" >&2
    echo "  Then edit this script or export ROMM_AUTH_SECRET_KEY before running." >&2
    exit 1 ;;
esac
case "$DB_PASSWORD" in changeme-*)
    echo "ERROR: DB_PASSWORD is still a placeholder." >&2
    echo "  Generate one with: openssl rand -hex 32" >&2
    echo "  Then edit this script or export DB_PASSWORD before running." >&2
    exit 1 ;;
esac
case "$DB_ROOT_PASSWORD" in changeme-*)
    echo "ERROR: DB_ROOT_PASSWORD is still a placeholder." >&2
    echo "  Generate one with: openssl rand -hex 32" >&2
    echo "  Then edit this script or export DB_ROOT_PASSWORD before running." >&2
    exit 1 ;;
esac
if [ "$ROMM_AUTH_SECRET_KEY" = "$DB_PASSWORD" ] || [ "$ROMM_AUTH_SECRET_KEY" = "$DB_ROOT_PASSWORD" ] || [ "$DB_PASSWORD" = "$DB_ROOT_PASSWORD" ]; then
    echo "ERROR: ROMM_AUTH_SECRET_KEY, DB_PASSWORD, and DB_ROOT_PASSWORD must all" >&2
    echo "  be different values. Reusing one secret across roles means a leak of" >&2
    echo "  any one of them compromises all of them." >&2
    exit 1
fi
if [ ! -d "$LIBRARY_PATH" ]; then
    echo "ERROR: LIBRARY_PATH ('$LIBRARY_PATH') doesn't exist." >&2
    echo "  This should be your existing game library -- refusing to mount an" >&2
    echo "  empty auto-created directory in its place. Edit LIBRARY_PATH and retry." >&2
    exit 1
fi

# ── Setup ──────────────────────────────────────────────────────────────────
mkdir -p "$RESOURCES_PATH" "$REDIS_PATH" "$ASSETS_PATH" "$CONFIG_PATH"

podman network inspect "$NETWORK" >/dev/null 2>&1 || podman network create "$NETWORK"
podman volume inspect "$DB_VOLUME" >/dev/null 2>&1 || podman volume create "$DB_VOLUME"

echo "→ Starting romm-db..."
podman run -d \
    --name romm-db \
    --network "$NETWORK" \
    --restart unless-stopped \
    -e MARIADB_ROOT_PASSWORD="$DB_ROOT_PASSWORD" \
    -e MARIADB_DATABASE=romm \
    -e MARIADB_USER=romm-user \
    -e MARIADB_PASSWORD="$DB_PASSWORD" \
    -v "$DB_VOLUME":/var/lib/mysql \
    docker.io/mariadb:latest

echo "→ Waiting for romm-db to become healthy..."
i=0
until podman exec romm-db healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 60 ]; then
        echo "ERROR: romm-db did not become healthy after 120s. Check: podman logs romm-db" >&2
        exit 1
    fi
    sleep 2
done

echo "→ Starting romm-app..."
podman run -d \
    --name romm-app \
    --network "$NETWORK" \
    --restart unless-stopped \
    -p "${HOST_PORT}:8080" \
    -e USER_ID=1000 \
    -e GROUP_ID=1000 \
    -e TZ=UTC \
    -e DB_HOST=romm-db \
    -e DB_NAME=romm \
    -e DB_USER=romm-user \
    -e DB_PASSWD="$DB_PASSWORD" \
    -e ROMM_AUTH_SECRET_KEY="$ROMM_AUTH_SECRET_KEY" \
    -e SCAN_WORKERS="$SCAN_WORKERS" \
    -v "$LIBRARY_PATH":/romm/library:ro \
    -v "$RESOURCES_PATH":/romm/resources \
    -v "$REDIS_PATH":/redis-data \
    -v "$ASSETS_PATH":/romm/assets \
    -v "$CONFIG_PATH":/romm/config \
    "$IMAGE"

echo ""
echo "=== Done ==="
echo "RomM should be reachable at: http://localhost:${HOST_PORT}"
echo "Logs:      podman logs -f romm-app"
echo "Stop:      podman stop romm-app romm-db"
echo "Remove:    podman rm -f romm-app romm-db && podman network rm $NETWORK"
echo "  (the $DB_VOLUME volume is left in place -- add 'podman volume rm $DB_VOLUME' to also drop your database)"
