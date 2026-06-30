# Container Build Summary

This document summarizes the automated container image building approach for the romm-fast-scan plugin.

---

## What Was Created

### **Containerfile & Dockerfile**
Both files are identical; they exist for tool compatibility:
- **Containerfile** — Used by `podman build` (Podman-native format)
- **Dockerfile** — Used by `docker build` and `docker buildx` (Docker-native format)

Multi-stage build:
  - **Stage 1 (builder):** Compile the C extension using Alpine + gcc
  - **Stage 2 (final):** RomM base image + pre-compiled .so + plugin files
- Pins to RomM 4.9.2 (default, can override with `--build-arg`)
- Sets `ENTRYPOINT` to `/romm-plugin/start.sh` (plugin startup before RomM)
- No code changes — uses the same patch/start.sh/refresh.sh as the volume-mount approach

### **../scripts/build-image.sh** (Local build helper)
Simple shell script to build the image locally:
```sh
sh ../scripts/build-image.sh                    # Build for 4.9.2
sh ../scripts/build-image.sh 5.0.0              # Build for 5.0.0
sh ../scripts/build-image.sh 4.9.2 ghcr.io/myorg  # Build and push
```

### **.github/workflows/build-container.yml** (GitHub Actions)
Automated build + push on:
- Push to `main` (if Containerfile or plugin files change)
- Manual trigger (workflow_dispatch)

Pushes to `ghcr.io/<repo>` using GitHub's GITHUB_TOKEN (no secrets needed).

### **CONTAINER_BUILD.md** (Documentation)
Comprehensive guide:
- Building locally and via GitHub Actions
- Using the built image (direct run, pod YAML, registry push)
- Updating for new RomM versions
- Comparison with volume-mount approach
- Debugging and troubleshooting

---

## Key Design Decision: "Decoupled from Code"

The Containerfile is **not** an embedded, frozen state of the plugin. Instead, it:

1. **Copies plugin files at build time** (src/, overrides/prepatched/, patches, scripts)
2. **Compiles the C extension** using those files
3. **Sets ENTRYPOINT to start.sh** (the normal plugin entry point)

This means:
- ✅ If you fix a bug in the plugin code, rebuild the image (changes are picked up)
- ✅ The patch is applied at runtime by start.sh (tier-1/2/3 fallback still works)
- ✅ You can run `refresh.sh` inside a container to regenerate the patch for a new RomM version
- ✅ The image gracefully falls back to pure Python if anything fails

The container is **reproducible** — building from the same Containerfile + repo state always produces an identical image.

---

## Workflow

### Local Development
```sh
# Make changes to plugin code
# Build locally
sh ../scripts/build-image.sh 4.9.2

# Test
podman run -it ... romm:4.9.2-fast-scan

# When satisfied, push to GitHub
git push
# GitHub Actions will build and push to ghcr.io
```

### Updating for a New RomM Version
```sh
# Option 1: Edit Containerfile
sed -i 's/FROM docker.io\/rommapp\/romm:4.9.2/FROM docker.io\/rommapp\/romm:4.9.3/' Containerfile
sh ../scripts/build-image.sh 4.9.3

# Option 2: Use build-arg (no file changes)
sh ../scripts/build-image.sh 4.9.3

# If patch doesn't apply:
# - Image still builds (patch is copied)
# - At runtime, start.sh tries to apply it
# - If it fails, falls back to pure Python
# - Run refresh.sh inside to regenerate and update the repo
```

### Automated Builds (GitHub Actions)
```
On push to main:
  1. GitHub Actions builds the Containerfile
  2. Pushes to ghcr.io/zeldafan3421/romm-fast-scan:4.9.2-fast-scan
  3. You can `podman pull` and use the pre-built image
```

---

## Comparison with Alternatives

| Approach | Pros | Cons | When to Use |
|---|---|---|---|
| **Volume Mount** (README) | Works with any RomM; flexible | Runtime compilation (5–10s first boot) | Development, frequent RomM updates |
| **Container Build** (this) | Fast boot; pre-compiled; reproducible | Must rebuild for new RomM versions | Production, stable deployments, air-gapped |
| **Custom Base Image** | Full control | High maintenance burden | Not recommended for this use case |

---

## What's Unchanged

The container approach **does not change**:
- Plugin code (src/_fasthash.c, src/fast_scan_cache.py)
- Patch application logic (start.sh three-tier system)
- Refresh workflow (refresh.sh still regenerates patches)
- Database schema or RomM integration
- Any configuration or testing procedures

It only adds an **optional** build mechanism for those who want a pre-compiled image.

---

## Files & Their Roles

| File | Purpose | Maintains Code | Notes |
|---|---|---|---|
| Containerfile | Multi-stage build spec | No | Fixed format; only BASE_IMAGE changes |
| ../scripts/build-image.sh | Local build helper | No | Thin wrapper around podman/docker |
| .github/workflows/build-container.yml | Automated build trigger | No | Standard GHA syntax; minimal |
| CONTAINER_BUILD.md | Documentation | No | Usage guide + comparison table |

**Code files (not modified):**
- src/_fasthash.c — C extension
- src/fast_scan_cache.py — Cache helper
- start.sh, refresh.sh — Plugin startup/maintenance
- roms_handler.patch — Unified diff patch
- known_sha256.txt — Version map

All code files are **automatically included** in the image build. Any changes to them are reflected in the next rebuild (local or GitHub Actions).

---

## Future Maintenance

When RomM 5.0.0 is released:

```
Current state:
  Containerfile: FROM docker.io/rommapp/romm:4.9.2

Step 1: Try building with new version
  sh ../scripts/build-image.sh 5.0.0
  
  If it works (patch applies cleanly):
    → Done! The 5.0.0 image is ready

  If it fails (patch doesn't apply):
    → Run refresh.sh inside the image to regenerate
    → Update the repo with the new patch
    → Commit and rebuild

Step 2: Update Containerfile (optional, for easier builds)
  sed -i 's/FROM .*/FROM docker.io\/rommapp\/romm:5.0.0/' Containerfile
  git add Containerfile && git commit
  
  Now `sh ../scripts/build-image.sh` (no args) builds for 5.0.0

Step 3: Push to repo
  git push
  → GitHub Actions builds and pushes ghcr.io image automatically
```

---

## Security Notes

- The Containerfile uses the official `docker.io/rommapp/romm` base image
- No third-party images are pulled (only alpine for builder)
- The builder stage is discarded in the final image (no gcc/headers in prod)
- GitHub Actions uses `GITHUB_TOKEN` (ephemeral, no long-lived secrets)
- Images can be signed with Cosign (optional, not set up here)

---

## Known Limitations

1. **Image size:** ~20 MB larger than base RomM (C extension + Python source)
2. **Rebuild needed for RomM updates** — unlike volume mount, which is flexible
3. **Build time:** 2–3 minutes (mostly downloading base image)
4. **Single version per image** — can't run both 4.9.2 and 5.0.0 images from the same Containerfile without rebuilding

---

## Benefits Over Volume Mount

1. **Zero compilation at runtime** — boot is instant (no 5–10s gcc delay)
2. **Pre-tested** — build/test locally, push when confident
3. **Reproducible** — same Containerfile + git commit = identical image
4. **CI/CD friendly** — GitHub Actions handles builds automatically
5. **Immutable deployments** — image tag never changes (no surprise updates)

---

## When to Use Container Build vs. Volume Mount

**Use Container Build if:**
- You want the fastest boot (no runtime compilation)
- You have a stable, production setup
- You don't update RomM frequently
- You want a self-contained image to share or archive

**Use Volume Mount if:**
- You're still developing/experimenting
- You update RomM often
- You want maximum flexibility
- You don't mind the 5–10s first-boot compilation

**Both are fully supported and can coexist.**

---

## Testing the Container Build

```sh
# 1. Build locally
sh ../scripts/build-image.sh 4.9.2

# 2. Run and test
podman run -it \
  -p 8080:8080 \
  -v /test/library:/romm/library:ro \
  -v /test/data:/romm/data \
  romm:4.9.2-fast-scan

# 3. Verify logs
podman logs -f <container> 2>&1 | grep -i "fast-scan\|plugin"

# 4. Check hashes
# (same procedure as PRE_DEPLOYMENT_CHECKLIST.md)

# 5. If everything works, push to registry
sh ../scripts/build-image.sh 4.9.2 ghcr.io/your-org
```

---

## Summary

- ✅ **Containerfile:** Automated, multi-stage build for RomM + plugin
- ✅ **../scripts/build-image.sh:** Simple helper for local builds
- ✅ **GitHub Actions:** Automated builds on push
- ✅ **CONTAINER_BUILD.md:** Full documentation
- ✅ **No code modifications:** Everything is decoupled, backward-compatible
- ✅ **Patch still applies normally:** Three-tier fallback works as designed

The container build is an **optional convenience layer**. The core plugin (C extension, cache, patch, start.sh) remains independent and can be used with or without the container.

