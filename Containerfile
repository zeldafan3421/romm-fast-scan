# Containerfile for romm-fast-scan
# ───────────────────────────────────────────────────────────────────────────────
#
# Build a RomM image with the fast-scan plugin pre-installed and compiled.
#
# This image:
#   • Pins to a specific RomM version (e.g., 4.9.2)
#   • Pre-compiles every native plugin under plugins/*/ at build time
#     (no runtime compilation)
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
#   • Plugins are plain C-ABI shared libraries (include/romm_plugin_abi.h,
#     loaded via ctypes at runtime -- see src/plugin_manager.py), so unlike
#     the old single CPython extension this replaced, they have no Python
#     ABI coupling at all. The builder stage below can be a generic
#     alpine:latest again (it doesn't need to match BASE_IMAGE's Python --
#     there's no Python involved in a plugin .so in the first place), and
#     a plugin built once here loads unmodified on any RomM/Python version.
#   • If the patch no longer applies to BASE_IMAGE's roms_handler.py, the
#     image still builds; start.sh falls back to pure Python at runtime.
#     Run refresh.sh inside a running container to regenerate the patch,
#     then rebuild
#   • The plugin files are always applied; no fallback to a stock,
#     un-patched RomM image -- if you want that, use the volume-mount
#     install instead of a prebuilt image (see README)

ARG BASE_IMAGE=docker.io/rommapp/romm:4.9.2

# Build stage: compile every native plugin under plugins/*/. A generic
# Alpine image is fine here -- see the Python-ABI-coupling note above.
FROM alpine:latest AS builder

RUN apk add --no-cache gcc musl-dev openssl-dev zlib-dev

WORKDIR /build
COPY include/ /build/include/
COPY plugins/ /build/plugins/

# Plain shell, no heredoc: `RUN <<EOF` blocks need a BuildKit-compatible
# frontend and podman/buildah's default parser doesn't support them --
# this project leads with Podman throughout, so avoid the dependency.
# Mirrors start.sh's compile_plugins() at runtime; the sha256 -> plugin.json
# step uses sed instead of python3 so the builder doesn't need Python at all.
#
# Skips a plugin whose .so already exists in the build context: the
# official ghcr.io image pipeline (.github/workflows/build-container.yml's
# sign-plugins job) pre-builds and *signs* plugins before this Containerfile
# ever runs, then hands the already-built plugins/ directory in as part of
# the build context -- without this check, this stage would happily
# recompile over them with a fresh, unsigned .so, silently discarding the
# signature. A local/dev build (scripts/build-image.sh, no signing key
# involved) never has pre-built .so files in its checkout, so this is a
# no-op for that path -- it builds fresh, unsigned, exactly as before.
RUN for tmpl in /build/plugins/*/plugin.json.tmpl; do \
        plugin_dir=$(dirname "$tmpl"); \
        plugin_name=$(basename "$plugin_dir"); \
        so_file=$(sed -n 's/.*"so_file": *"\([^"]*\)".*/\1/p' "$tmpl"); \
        if [ -f "$plugin_dir/$so_file" ]; then \
            echo "Cached (pre-built): $plugin_dir/$so_file"; \
            continue; \
        fi; \
        src_c=$(find "$plugin_dir" -maxdepth 1 -name '*.c' | head -1); \
        case "$plugin_name" in \
            fasthash) LDFLAGS="-lssl -lcrypto -lz -lpthread" ;; \
            *) LDFLAGS="" ;; \
        esac; \
        echo "Building $plugin_name -> $so_file"; \
        gcc -O2 -std=c99 -fPIC -shared -I /build/include \
            -o "$plugin_dir/$so_file" "$src_c" $LDFLAGS; \
        sha256=$(sha256sum "$plugin_dir/$so_file" | awk '{print $1}'); \
        sed "s/\"sha256\": null/\"sha256\": \"$sha256\"/" "$tmpl" > "$plugin_dir/plugin.json"; \
        echo "Built: $plugin_dir/$so_file (sha256=$sha256)"; \
    done

# Export-only stage: just the built plugins/, nothing else from the Alpine
# builder's filesystem. Not part of the normal 2-stage build (a plain
# `docker build .`/`podman build .` never builds this, since it isn't an
# ancestor of the default final stage below) -- exists only so CI's
# sign-plugins job can `--target plugins-export -o type=local` a minimal
# artifact to sign, instead of exporting the builder stage's entire
# filesystem (gcc, musl-dev, and everything else Alpine) just to reach a
# few hundred KB of .so files.
FROM scratch AS plugins-export
COPY --from=builder /build/plugins/ /

# Stage 2: Final RomM image with plugin
FROM ${BASE_IMAGE}

# Runtime dependencies: openssl-dev/zlib-dev for the fasthash plugin's
# libssl/libcrypto/libz (archive-list needs nothing beyond libc, already
# present); openssh-keygen so plugin_manager.py can always verify official
# plugins' signatures on this image without depending on anything the
# volume-mount/first-boot path might or might not have installed -- see
# plugins/README.md's "Signing and FAST_SCAN_ALLOW_UNSIGNED_PLUGINS".
RUN apk add --no-cache openssl-dev zlib-dev openssh-keygen

RUN mkdir -p /romm-plugin/src /romm-plugin/overrides/prepatched

# include/ is kept at runtime too (not just in the builder) so start.sh's
# compile_plugins() can still recompile on demand -- e.g. if a .so is ever
# deleted from a running container -- on an image-based deployment, not
# just the volume-mount one.
COPY include/ /romm-plugin/include/
COPY --from=builder /build/plugins/ /romm-plugin/plugins/

COPY src/ /romm-plugin/src/
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
# Since plugins have no Python-ABI coupling, the *builder* stage doesn't
# need to change at all when BASE_IMAGE does -- only stage 2 (the actual
# RomM image being extended) does. A plugin compiled for one RomM version
# is exactly as valid for any other.
#
# This always applies the plugin at build time -- there's no fallback to an
# unpatched image. If that's not what you want (e.g. you want to keep
# tracking docker.io/rommapp/romm:latest and get the plugin patched in
# dynamically at each boot instead of pinning to a build), use the
# volume-mount install path instead -- see README.md.
