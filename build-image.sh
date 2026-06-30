#!/bin/sh
# build-image.sh — Build a Podman/Docker image with the fast-scan plugin
# ─────────────────────────────────────────────────────────────────────────────
#
# Usage:
#   sh build-image.sh                        # Build for RomM 4.9.2 (default)
#   sh build-image.sh 5.0.0                  # Build for RomM 5.0.0
#   sh build-image.sh 4.9.2 ghcr.io/my-org  # Push to your registry

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="${1:-4.9.2}"
REGISTRY="${2:-}"
IMAGE_NAME="romm"
TAG="${IMAGE_NAME}:${VERSION}-fast-scan"

echo "=== Building $TAG ==="
echo ""
echo "RomM version: $VERSION"
echo "Tag: $TAG"
echo ""

# Build the image using the specified RomM version
if command -v podman >/dev/null 2>&1; then
    BUILDER="podman"
elif command -v docker >/dev/null 2>&1; then
    BUILDER="docker"
else
    echo "ERROR: neither podman nor docker found"
    exit 1
fi

echo "Builder: $BUILDER"

# Choose the build file based on which builder is available
if [ "$BUILDER" = "podman" ]; then
    BUILD_FILE="Containerfile"
else
    BUILD_FILE="Dockerfile"
fi

# Detect if we need to use --build-arg for a custom version
if [ "$VERSION" != "4.9.2" ]; then
    echo "Using custom base image: docker.io/rommapp/romm:$VERSION"
    $BUILDER build \
        -f "$BUILD_FILE" \
        --build-arg "BASE_IMAGE=docker.io/rommapp/romm:$VERSION" \
        -t "$TAG" \
        "$SCRIPT_DIR"
else
    echo "Using default base image: docker.io/rommapp/romm:4.9.2"
    $BUILDER build -f "$BUILD_FILE" -t "$TAG" "$SCRIPT_DIR"
fi

echo ""
echo "✓ Image built: $TAG"
echo ""
echo "Usage:"
echo "  $BUILDER run -it \\"
echo "    -p 8080:8080 \\"
echo "    -v /path/to/library:/romm/library:ro \\"
echo "    -v /path/to/data:/romm/data \\"
echo "    $TAG"
echo ""

if [ -n "$REGISTRY" ]; then
    FULL_TAG="$REGISTRY/$TAG"
    echo "Pushing to $REGISTRY..."
    $BUILDER tag "$TAG" "$FULL_TAG"
    $BUILDER push "$FULL_TAG"
    echo "✓ Pushed: $FULL_TAG"
    echo ""
    echo "Use in pod YAML:"
    echo "  image: $FULL_TAG"
else
    echo "To push to a registry:"
    echo "  sh build-image.sh $VERSION ghcr.io/your-org"
fi
