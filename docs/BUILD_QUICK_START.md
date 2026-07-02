# Build Quick Start

Quick reference for building the romm-fast-scan container image.

---

## Choose Your Tool

### Podman (recommended)
```sh
podman build -t romm:4.9.2-fast-scan .
podman run -it ... romm:4.9.2-fast-scan
```

### Docker
```sh
docker build -t romm:4.9.2-fast-scan .
docker run -it ... romm:4.9.2-fast-scan
```

### Docker Buildx (multi-platform, faster cache)
```sh
docker buildx build -t romm:4.9.2-fast-scan --load .
```

### Using the Helper Script
```sh
sh ../scripts/build-image.sh 4.9.2                    # Local build
sh ../scripts/build-image.sh 4.9.2 ghcr.io/my-org     # Build + push
```

---

## Different RomM Versions

```sh
# 4.9.3
podman build --build-arg BASE_IMAGE=docker.io/rommapp/romm:4.9.3 \
  -t romm:4.9.3-fast-scan .

# 5.0.0-alpha.2
podman build --build-arg BASE_IMAGE=docker.io/rommapp/romm:5.0.0-alpha.2 \
  -t romm:5.0.0-alpha.2-fast-scan .
```

---

## Test the Image

```sh
# Quick test (verify a plugin loaded and passes signature/ABI checks)
podman run --rm -e FAST_SCAN_ALLOW_UNSIGNED_PLUGINS=1 romm:4.9.2-fast-scan \
  python3 -c "
import sys; sys.path.insert(0, '/romm-plugin/src')
import plugin_manager as pm
pm.load_plugins('/romm-plugin/plugins')
print('✓ plugin OK:', pm.hash_file('/etc/hostname'))
"

# Full test with your library
podman run -it \
  -p 8080:8080 \
  -v /path/to/library:/romm/library:ro \
  -v /path/to/data:/romm/data \
  romm:4.9.2-fast-scan
```

Plugins built by a local `podman build`/`docker build` are **unsigned** (only this
repo's CI holds the private signing key), so `-e FAST_SCAN_ALLOW_UNSIGNED_PLUGINS=1`
is required for a locally-built image — see `plugins/README.md`'s "Signing and
`FAST_SCAN_ALLOW_UNSIGNED_PLUGINS`" section. The published `ghcr.io` image ships
signed plugins and doesn't need this flag.

---

## Push to Registry

```sh
# GitHub Container Registry (ghcr.io)
podman tag romm:4.9.2-fast-scan ghcr.io/your-org/romm:4.9.2-fast-scan
podman login ghcr.io
podman push ghcr.io/your-org/romm:4.9.2-fast-scan

# Use in pod YAML
image: ghcr.io/your-org/romm:4.9.2-fast-scan
```

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `no such file or directory: Dockerfile` | Using Docker without Dockerfile | `Dockerfile` now exists — retry |
| Plugin refuses to load / falls back to pure Python silently | Plugin isn't signed (local build) | Set `FAST_SCAN_ALLOW_UNSIGNED_PLUGINS=1` |
| `Could not patch roms_handler.py` | Patch doesn't apply to this version | Run `refresh.sh` inside container, update patch |

---

## Files

- **Containerfile** — For `podman build` (Podman-native)
- **Dockerfile** — For `docker build` / `docker buildx` (Docker-native)
- **../scripts/build-image.sh** — Helper script (auto-detects podman vs docker)

Both Containerfile and Dockerfile are identical.

---

## Full Documentation

See [CONTAINER_BUILD.md](CONTAINER_BUILD.md) for detailed usage, updating for new RomM versions, and architecture details.

