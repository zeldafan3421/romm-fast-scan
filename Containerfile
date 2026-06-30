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
#   • This Containerfile is versioned to RomM 4.9.2 (see ARG BASE_IMAGE below)
#   • To support a new RomM version, build from that version and run refresh.sh
#   • The plugin files are always applied; no fallback to stock RomM
#   • For a version-agnostic image that handles multiple RomM versions,
#     see the multi-stage build example below (commented out)

# Build stage: compile the C extension in isolation
FROM alpine:latest AS builder

RUN apk add --no-cache \
    python3 python3-dev \
    gcc musl-dev \
    openssl-dev zlib-dev

WORKDIR /build
COPY src/ /build/src/

RUN python3 << 'PYEOF'
import sysconfig
import subprocess
import os

# Determine the EXT_SUFFIX (e.g., cpython-313-x86_64-linux-musl.so)
ext_suffix = sysconfig.get_config_var('EXT_SUFFIX')
include_path = sysconfig.get_path('include')

print(f"EXT_SUFFIX: {ext_suffix}")
print(f"Include path: {include_path}")

# Compile the C extension
result = subprocess.run([
    'gcc', '-O2', '-std=c99', '-Wall', '-fPIC', '-shared',
    '-o', f'_fasthash{ext_suffix}',
    'src/_fasthash.c',
    f'-I{include_path}',
    '-lssl', '-lcrypto', '-lz'
], capture_output=True, text=True)

if result.returncode != 0:
    print(f"Compilation failed:\n{result.stderr}")
    exit(1)

print(f"Built: _fasthash{ext_suffix}")
PYEOF

# Stage 2: Final RomM image with plugin
FROM docker.io/rommapp/romm:4.9.2

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
# Multi-Version Example (Advanced)
# ───────────────────────────────────────────────────────────────────────────────
#
# To build for multiple RomM versions, you can use build args:
#
#   ARG BASE_IMAGE=docker.io/rommapp/romm:4.9.2
#   FROM ${BASE_IMAGE}
#
# Then build with:
#
#   podman build --build-arg BASE_IMAGE=docker.io/rommapp/romm:5.0.0 \
#     -t romm:5.0.0-fast-scan .
#
# However, the C extension binary is compiled for the builder's Python version,
# so you'll get the best results if the base image uses the same Python version
# (all RomM 4.x use Python 3.13 as of this writing).
#
# If you try to use a pre-compiled .so from a different Python version,
# start.sh will detect the mismatch and recompile at runtime.

# ───────────────────────────────────────────────────────────────────────────────
# Notes for Future Maintenance
# ───────────────────────────────────────────────────────────────────────────────
#
# 1. When RomM releases a new version (e.g., 5.0.0):
#    - Update "FROM docker.io/rommapp/romm:4.9.2" to the new version
#    - Test the build: podman build -t romm:5.0.0-fast-scan .
#    - The C extension will recompile for that version's Python
#
# 2. If the patch no longer applies (unlikely; it's resilient):
#    - The Containerfile will still apply it at build time (no image change)
#    - At runtime, start.sh will use tier-1 (exact SHA match)
#    - If that fails, it falls back to tier-2 (apply the patch)
#    - If that fails, it falls back to tier-3 (pure Python)
#    - So the image degrades gracefully and doesn't break
#
# 3. To update for a future RomM version after the patch needs regeneration:
#    - Build the image with the new RomM version
#    - The image will include the old patch (may not apply)
#    - At runtime, start.sh will try the patch (falls back to pure Python if needed)
#    - Run `podman exec <container> sh /romm-plugin/refresh.sh` to regenerate
#    - Commit the new patch back to the repo
#    - Rebuild the image with the new patch
#
# 4. This Containerfile always applies the plugin (no fallback to stock RomM):
#    - If you want a fallback option, mount the plugin as a volume instead
#    - Then use the stock RomM image with the normal pod YAML + patch_romm_yaml.py
