# Containerfile for romm-fast-scan
# ───────────────────────────────────────────────────────────────────────────────
#
# Build a RomM image with the fast-scan plugin pre-installed and compiled.
#
# This image:
#   • Pins to a specific RomM version (e.g., 4.9.2)
#   • Pre-compiles the C extension at build time (no runtime compilation)
#   • Patches roms_handler.py at build time
#   • Still respects the normal start.sh logic (three-tier patching)
#
# Usage:
#   podman build -t romm:4.9.2-fast-scan .
#   podman run -it ... romm:4.9.2-fast-scan
#
# Alternatively, use as a base for your own image:
#   FROM ghcr.io/rommapp/romm:4.9.2
#   COPY --from=romm-fast-scan-builder /romm-plugin /romm-plugin
#   # ... rest of your custom config ...
#
# Notes:
#   • Defaults to RomM 4.9.2; override with --build-arg BASE_IMAGE=... to
#     build against a different RomM tag (see BASE_IMAGE below)
#   • The builder stage is BASE_IMAGE itself (not a generic alpine:latest),
#     so the compiled .so is always built for BASE_IMAGE's actual Python --
#     no EXT_SUFFIX mismatch, no runtime recompile needed
#   • If the patch no longer applies to BASE_IMAGE's roms_handler.py, the
#     image still builds; start.sh falls back to pure Python at runtime.
#     Run refresh.sh inside a running container to regenerate the patch,
#     then rebuild
#   • The plugin files are always applied; no fallback to a stock,
#     un-patched RomM image -- if you want that, use the volume-mount
#     install instead of a prebuilt image (see README)

ARG BASE_IMAGE=docker.io/rommapp/romm:4.9.2

# Build stage: compile the C extension against the *exact same image* that
# will run it (not a generic alpine:latest). The compiled .so's filename is
# tied to the builder's Python ABI (e.g. cpython-313-x86_64-linux-musl.so),
# and RomM's image doesn't necessarily track Alpine's default python3
# package version/build -- pinning the builder to alpine:latest silently
# produced a .so for the wrong Python, which start.sh then had to discard
# and recompile at runtime every boot anyway, defeating the point of
# pre-compiling at build time. Building FROM the target image guarantees a
# match by construction, regardless of how that image gets its Python.
FROM ${BASE_IMAGE} AS builder

RUN apk add --no-cache \
    python3-dev \
    gcc musl-dev \
    openssl-dev zlib-dev

WORKDIR /build
COPY src/ /build/src/

# Plain shell rather than a Python heredoc: `RUN <<EOF` blocks need a
# BuildKit-compatible frontend (a `# syntax=` directive, or Docker Buildx),
# and podman/buildah's default parser doesn't support them out of the box.
# This mirrors start.sh's compile_extension() at runtime.
RUN EXT_SUFFIX=$(python3 -c "import sysconfig; print(sysconfig.get_config_var('EXT_SUFFIX'))") && \
    INC=$(python3 -c "import sysconfig; print(sysconfig.get_path('include'))") && \
    echo "EXT_SUFFIX: $EXT_SUFFIX" && \
    echo "Include path: $INC" && \
    gcc -O2 -std=c99 -Wall -fPIC -shared \
        -o "_fasthash${EXT_SUFFIX}" \
        src/_fasthash.c \
        -I"$INC" \
        -lssl -lcrypto -lz && \
    echo "Built: _fasthash${EXT_SUFFIX}"

# Stage 2: Final RomM image with plugin
FROM ${BASE_IMAGE}

# Install runtime dependencies for the C extension
RUN apk add --no-cache openssl-dev zlib-dev

# Create plugin directory structure
RUN mkdir -p /romm-plugin/lib /romm-plugin/overrides/prepatched

# Copy pre-compiled C extension from builder
COPY --from=builder /build/_fasthash* /romm-plugin/lib/

# Copy plugin source and utilities
COPY src/fast_scan_cache.py /romm-plugin/src/fast_scan_cache.py
COPY overrides/prepatched/ /romm-plugin/overrides/prepatched/
COPY roms_handler.patch /romm-plugin/
COPY known_sha256.txt /romm-plugin/
COPY start.sh /romm-plugin/start.sh
COPY scripts/refresh.sh /romm-plugin/refresh.sh

# Make scripts executable
RUN chmod +x /romm-plugin/start.sh /romm-plugin/refresh.sh

# Override the entrypoint to use our start.sh
# (This is the key: we inject our plugin startup before RomM's normal boot)
ENTRYPOINT ["/romm-plugin/start.sh"]

# ───────────────────────────────────────────────────────────────────────────────
# Building for a different RomM version
# ───────────────────────────────────────────────────────────────────────────────
#
#   podman build --build-arg BASE_IMAGE=docker.io/rommapp/romm:5.0.0 \
#     -t romm:5.0.0-fast-scan .
#
# (scripts/build-image.sh wraps this: `sh scripts/build-image.sh 5.0.0`)
#
# This always applies the plugin at build time -- there's no fallback to an
# unpatched image. If that's not what you want (e.g. you want to keep
# tracking docker.io/rommapp/romm:latest and get the plugin patched in
# dynamically at each boot instead of pinning to a build), use the
# volume-mount install path instead -- see README.md.
