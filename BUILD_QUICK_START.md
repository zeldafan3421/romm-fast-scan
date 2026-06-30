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
sh build-image.sh 4.9.2                    # Local build
sh build-image.sh 4.9.2 ghcr.io/my-org     # Build + push
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
# Quick test (verify plugin loaded)
podman run --rm romm:4.9.2-fast-scan \
  python3 -c "import _fasthash; print('✓ C extension OK')"

# Full test with your library
podman run -it \
  -p 8080:8080 \
  -v /path/to/library:/romm/library:ro \
  -v /path/to/data:/romm/data \
  romm:4.9.2-fast-scan
```

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
| `ELF header mismatch` | .so compiled for wrong Python | Rebuild image with correct base version |
| `Could not patch roms_handler.py` | Patch doesn't apply to this version | Run `refresh.sh` inside container, update patch |

---

## Files

- **Containerfile** — For `podman build` (Podman-native)
- **Dockerfile** — For `docker build` / `docker buildx` (Docker-native)
- **build-image.sh** — Helper script (auto-detects podman vs docker)

Both Containerfile and Dockerfile are identical.

---

## Full Documentation

See [CONTAINER_BUILD.md](CONTAINER_BUILD.md) for detailed usage, updating for new RomM versions, and architecture details.

