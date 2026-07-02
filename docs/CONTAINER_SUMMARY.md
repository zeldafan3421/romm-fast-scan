# Container Build Summary

**Retired.** This was a "what was created" implementation summary written when the container build automation was first added — it described a single-CPython-extension design (`src/_fasthash.c`, one hardcoded RomM version, one hardcoded CI tag) that this project no longer has. Rather than maintain a second, narrative copy of build mechanics that's guaranteed to drift out of sync with the actual `Containerfile`/`Dockerfile`/CI workflow again, this content now lives only in the places that are actually kept current:

- **`CLAUDE.md`**'s "Building / compiling plugins" section — the builder stage, the `plugins-export` stage, the three build sites that must stay equivalent, per-plugin link flags
- **`CLAUDE.md`**'s "Versioning model" section — how the CI build matrix derives every published version automatically from `known_sha256.txt`
- **`plugins/README.md`**'s "Signing and `FAST_SCAN_ALLOW_UNSIGNED_PLUGINS`" section — how official plugins get signed at build time, and what that means for a locally-built image
- **`README.md`**'s "Option B: build it yourself" and "Staying up to date with RomM" sections — the user-facing version of the same information
- **`docs/BUILD_QUICK_START.md`** / **`docs/CONTAINER_BUILD.md`** — the still-maintained build guides

If you're looking for "what does the container build actually do," start with `CLAUDE.md`.
