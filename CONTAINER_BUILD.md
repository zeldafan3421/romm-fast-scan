# Building a Container Image with the Plugin

This guide covers building a Podman/Docker image with the fast-scan plugin pre-installed and pre-compiled.

---

## Overview

The build files (`Containerfile` for Podman, `Dockerfile` for Docker) build a RomM image with:
- ✅ C extension pre-compiled (no runtime compilation needed)
- ✅ Plugin files pre-installed
- ✅ Fast boot (compilation happens once, at build time)
- ⚠️ Pinned to a specific RomM version (e.g., 4.9.2)
- ⚠️ Not automatically updated when RomM releases a new version

This is different from the volume-mount approach (in README.md), which:
- ✅ Works with any RomM version (via three-tier patching)
- ✅ Easy to update (just update the base image)
- ❌ Compiles the C extension at runtime on first boot

**Choose container build if:** You want the fastest boot and don't mind rebuilding the image for RomM updates.

**Choose volume mount if:** You want maximum flexibility and don't mind 5–10 seconds of compilation on first boot.

---

## Build Files

- **`Containerfile`** — Podman-native format (recommended for Podman)
- **`Dockerfile`** — Docker-native format (required for Docker/Docker Buildx)

Both files are identical. Use whichever matches your container runtime:
- `podman build` → uses `Containerfile` automatically
- `docker build` → uses `Dockerfile` automatically
- `docker buildx build` → uses `Dockerfile` (must be present)

If you're using Docker and get `no such file or directory`, the `Dockerfile` should fix it.

---

## Prerequisites

- `podman` or `docker` installed
- The romm-fast-scan repository cloned
- ~2 GB disk space for the build

---

## Building the Image

### Quick Build (4.9.2)

**With Podman:**
```sh
cd /path/to/romm-fast-scan
podman build -t romm:4.9.2-fast-scan .
```

**With Docker:**
```sh
cd /path/to/romm-fast-scan
docker build -t romm:4.9.2-fast-scan .
```

**With Docker Buildx (multi-arch, faster cache):**
```sh
docker buildx build -t romm:4.9.2-fast-scan --load .
```

Expected output:
```
[1/2] STEP 1/8: FROM alpine:latest AS builder
...
[2/2] STEP 1/4: FROM docker.io/rommapp/romm:4.9.2
...
[2/2] STEP 4/4: ENTRYPOINT ["/romm-plugin/start.sh"]
--> 9f3a8c7d2e1c
Successfully tagged localhost/romm:4.9.2-fast-scan
```

Build time: ~2–3 minutes (mostly downloading the base image).

### Build for a Different RomM Version

```sh
# For RomM 5.0.0-alpha.2
podman build -t romm:5.0.0-alpha.2-fast-scan \
  --build-arg BASE_IMAGE=docker.io/rommapp/romm:5.0.0-alpha.2 .
```

**Note:** The patch must apply to that RomM version. If it doesn't:
- The image will still build (the patch is copied, but won't apply at build time)
- At runtime, `start.sh` will try to apply it (may fail over to tier-3 pure Python)
- To fix: Run `refresh.sh` inside the container and commit the new patch to the repo

---

## Using the Image

### Option 1: Direct Run

```sh
podman run -it \
  -p 8080:8080 \
  -v /path/to/your/library:/romm/library:ro \
  -v /path/to/your/data:/romm/data \
  -v /path/to/mariadb/data:/var/lib/mysql \
  romm:4.9.2-fast-scan
```

This is a minimal example. For a full pod setup, see Option 2.

### Option 2: Kubernetes-Style Pod YAML

Use the same `romm.yml` from the normal setup, but change the image:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: romm-pod
spec:
  containers:
    - name: romm-app
      image: localhost/romm:4.9.2-fast-scan  # ← Use the built image
      # (rest of the pod YAML stays the same)
```

The only difference from the normal setup is:
- The image already has the plugin built in
- No need to mount `/opt/romm/fast-scan-plugin` (it's in the image)
- `start.sh` will still run at boot (it's the `ENTRYPOINT`)

**Note:** If you were using `command: ["/romm-plugin/start.sh"]` in your pod YAML, that's now redundant but harmless (the `ENTRYPOINT` in the Containerfile is the same). You can remove it or leave it.

---

## Image Limitations

### Pinned to RomM Version

The Containerfile hardcodes:
```dockerfile
FROM docker.io/rommapp/romm:4.9.2
```

To use a different RomM version, you must rebuild the image:

```sh
# Edit the Containerfile
sed -i 's/FROM docker.io\/rommapp\/romm:.*/FROM docker.io\/rommapp\/romm:5.0.0/' Containerfile

# Rebuild
podman build -t romm:5.0.0-fast-scan .
```

Or use the `--build-arg` approach (see "Build for a Different Version" above).

### Pre-Compiled .so May Not Match

The C extension is compiled during `podman build`, using the builder container's Python version. If the final image uses a different Python version, the `.so` may not load:

```
ImportError: ELF header: e_machine is EM_X86_64, expected EM_386
```

This is rare (RomM 4.x all use Python 3.13), but if it happens, `start.sh` will detect it and recompile at runtime.

---

## Updating for a New RomM Release

### Scenario 1: Patch Still Applies (Common)

RomM releases 4.9.3 with only minor changes (unrelated to `roms_handler.py`):

```sh
# Update the Containerfile
sed -i 's/FROM docker.io\/rommapp\/romm:4.9.2/FROM docker.io\/rommapp\/romm:4.9.3/' Containerfile

# Rebuild
podman build -t romm:4.9.3-fast-scan .

# Test the image
podman run -it ... romm:4.9.3-fast-scan
# start.sh will:
# 1. Try exact SHA match (probably fails, new version)
# 2. Try applying the patch (succeeds, because changes are unrelated)
# 3. Set PYTHONPATH and start RomM
```

**Result:** Works perfectly. The patch applies cleanly.

---

### Scenario 2: Patch Doesn't Apply (Rare)

RomM releases 5.0.0 and significantly rewrites `roms_handler.py`:

```sh
# Update and rebuild
sed -i 's/FROM docker.io\/rommapp\/romm:4.9.2/FROM docker.io\/rommapp\/romm:5.0.0/' Containerfile
podman build -t romm:5.0.0-fast-scan .

# Test
podman run -it ... romm:5.0.0-fast-scan
# start.sh will:
# 1. Try exact SHA match (fails)
# 2. Try applying the old patch (fails, structure changed)
# 3. Fall back to pure Python (tier-3)
```

**Result:** Image boots, but scans are slow (pure Python). Fix:

```sh
# Option 1: Regenerate the patch inside the container
podman exec <container-id> sh /romm-plugin/refresh.sh

# Then copy the updated patch back to the repo
podman cp <container-id>:/romm-plugin/roms_handler.patch \
  /path/to/romm-fast-scan/roms_handler.patch

# Update the repo and rebuild
cd /path/to/romm-fast-scan
git add roms_handler.patch known_sha256.txt
git commit -m "Update patch for RomM 5.0.0"
git push

# Rebuild the image
podman build -t romm:5.0.0-fast-scan .
```

Or, if you don't want to maintain the image:

```sh
# Option 2: Use the volume-mount approach instead
# (Stick with the stock RomM image and mount the plugin as a volume)
# See README.md for the normal pod YAML setup
```

---

## Multi-Stage Build Details

The Containerfile uses a two-stage build:

```dockerfile
# Stage 1: Compile the C extension (alpine base, minimal)
FROM alpine:latest AS builder
  # Copy src/
  # Compile with gcc
  # Result: _fasthash*.so

# Stage 2: Create the final RomM image
FROM docker.io/rommapp/romm:4.9.2
  # Copy the .so from stage 1
  # Copy plugin files
  # Set ENTRYPOINT
```

**Why two stages?**
- **Smaller image:** The final image doesn't include `gcc` (just the compiled .so)
- **Faster rebuilds:** If the base image changes, the builder stage can be skipped
- **Isolation:** The build environment (gcc, Python dev headers) is not in the final image

**Image size:**
- Stock RomM 4.9.2: ~500 MB
- With plugin: +15–20 MB (mostly the Python source + .so)

---

## Tagging and Pushing to a Registry

### Tag the Built Image

```sh
podman tag romm:4.9.2-fast-scan ghcr.io/your-org/romm:4.9.2-fast-scan
```

### Push to GitHub Container Registry

```sh
podman login ghcr.io
podman push ghcr.io/your-org/romm:4.9.2-fast-scan
```

### Use the Pushed Image in Your Pod YAML

```yaml
containers:
  - name: romm-app
    image: ghcr.io/your-org/romm:4.9.2-fast-scan
```

---

## Debugging the Build

### Build Fails During Compilation

```
gcc: error: ... _fasthash.c: No such file or directory
```

**Cause:** The `src/` directory is not in the build context.

**Solution:** Make sure you're in the repo root:
```sh
ls src/_fasthash.c  # Should exist
podman build -t romm:4.9.2-fast-scan .
```

### Build Fails When Pulling Base Image

```
Error: 404 Not Found: manifest not found
```

**Cause:** The RomM version doesn't exist (e.g., typo in version number).

**Solution:** Check the available versions:
```sh
podman pull docker.io/rommapp/romm:latest  # Verify registry access
podman search rommapp/romm  # List available tags
```

### Running the Image Fails

```
[fast-scan] Cached: /romm-plugin/lib/_fasthash...
[fast-scan] WARNING: Could not patch roms_handler.py.
```

**Cause:** The pre-compiled .so doesn't match the Python version, or the patch doesn't apply.

**Solution:**
1. Check if the .so matches:
   ```sh
   podman run -it romm:4.9.2-fast-scan python3 -c "import _fasthash; print('OK')"
   ```

2. If import fails, rebuild with the correct base image version.

3. If the patch warning appears, run refresh.sh inside the container (see "Updating for a New RomM Release" above).

---

## Building a Custom Image (Advanced)

If you want to add your own customizations (e.g., additional packages, environment variables):

```dockerfile
FROM localhost/romm:4.9.2-fast-scan

# Your customizations here
RUN apk add --no-cache my-package
ENV MY_VAR=value

# The plugin is already set up; just extend it
```

Then build:
```sh
docker build -f MyDockerfile -t my-custom-romm:4.9.2 .
```

---

## Comparison: Container Build vs. Volume Mount

| Aspect | Container Build | Volume Mount |
|---|---|---|
| **Build time** | 2–3 min (first build) | ~0 (reuse existing images) |
| **Compilation** | At build time | At first runtime (5–10s) |
| **RomM updates** | Rebuild image needed | Just update base image, no rebuild |
| **Patch flexibility** | Image-locked to patch version | Auto-applies newest patch |
| **Image size** | Slightly larger (~20 MB more) | Smaller (no .so) |
| **Deployment** | Push to registry | Mount plugin directory |
| **Maintenance** | Update Containerfile for new RomM | Zero maintenance |
| **Best for** | Fixed, air-gapped deployments | Active development, frequent updates |

---

## Next Steps

1. **Build the image:** `podman build -t romm:4.9.2-fast-scan .`
2. **Test it:** Run with your library, verify scans are fast and hashes are correct
3. **Push to registry:** `podman push ghcr.io/your-org/romm:4.9.2-fast-scan` (optional)
4. **Deploy:** Update your pod YAML to use the image
5. **Monitor:** Check logs with `podman logs -f <container>`

---

## Troubleshooting

→ See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for common issues (many apply to both deployment methods)

→ See [PRE_DEPLOYMENT_CHECKLIST.md](PRE_DEPLOYMENT_CHECKLIST.md) for validation steps

