# romm-fast-scan

A drop-in scanning performance plugin for [RomM](https://github.com/rommapp/romm) built on a small native-plugin system: RomM's `roms_handler.py` is patched **once** to call into `plugin_manager.py`, which loads plain C-ABI `.so` plugins at runtime. The first plugin, `fasthash`, replaces RomM's pure-Python file hashing with GIL-released native CRC32/MD5/SHA1, enabling genuine parallel hashing across scan workers.

Committed to supporting every RomM **5.\*.\*** backend release, indefinitely — see [Compatibility commitment](#compatibility-commitment) below. Verified today against RomM **4.9.2** and **5.0.0-alpha.2**.

---

## How it works

RomM computes CRC32, MD5, and SHA1 hashes for every ROM file during a scan. The original implementation does this in pure Python, which means the GIL serializes all workers even when `SCAN_WORKERS > 1` — extra workers don't actually run in parallel.

`roms_handler.py` is patched to call `plugin_manager.hash_file(path)` instead of hashing in Python directly. `plugin_manager` loads whichever native plugins are present under `plugins/*/` (see [`plugins/README.md`](plugins/README.md) for the full contract) and dispatches into them via `ctypes` — no Python C-API, no CPython ABI coupling, so a compiled plugin works unmodified across every RomM/Python version. The bundled `fasthash` plugin:

- Computes all three hashes in a **single file pass** using a 256 KB read buffer
- Has no GIL to release in the first place — it's a plain shared library, not a CPython extension, so scan worker threads calling into it run genuinely concurrently by default
- Falls back transparently to the original Python path for archive files (`.zip`, `.7z`, `.rar`, etc.) that require decompression, or if no plugin provides the `hash_file` hook at all

The result is that `SCAN_WORKERS` threads actually run in parallel on CPU and I/O simultaneously. Every layer fails open: a missing plugin, a corrupt `.so`, an ABI mismatch, or a plugin call itself failing all fall back to plain Python hashing — never a wrong hash, never a blocked scan.

**Observed speedup on a 28,000-game library:** ~3–5× faster full rescan with 4 workers on HDD; higher on SSD.

---

## Requirements

- RomM deployed via Podman (or Docker) pod YAML (Kubernetes-style)
- If building your own image: `podman` or `docker` on the machine you build from (not necessarily the RomM host — you can build elsewhere and push)
- If volume-mounting onto the stock image instead (see [Advanced install](#advanced-install-volume-mount-deprecated-for-supported-versions) below — the go-to path only for RomM versions without a published image yet): the container needs internet access on first boot, to install a compiler

---

## Installation

The plugin is a container image swap: change one line in your existing config, restart. `start.sh` — the same three-tier patching described below — still runs at every boot inside the image, so you keep the same graceful-fallback behavior either way; the image just ships every plugin precompiled instead of compiling them on first boot.

**Starting from scratch?** Pick whichever deployment style you'd use for RomM anyway — every one of these already points at the published image, ready to fill in and run:

| Style | File |
|---|---|
| Podman/Kubernetes pod YAML | [`examples/romm.release.yml`](examples/romm.release.yml) — `podman play kube` |
| Docker/Podman Compose | [`examples/docker-compose.yml`](examples/docker-compose.yml) — `docker compose up -d` / `podman compose up -d` |
| Plain `docker run`, no config file | [`scripts/run-docker.sh`](scripts/run-docker.sh) |
| Plain `podman run`, no config file | [`scripts/run-podman.sh`](scripts/run-podman.sh) |

The rest of this section is for swapping an *existing* pod-YAML deployment over; Option A/B apply the same way if you're on Compose or a bare `run` command — just change the `image:` (or `--image`) reference the same way.

### Option A: use the published image

```diff
-      image: docker.io/rommapp/romm:4.9.2
+      image: ghcr.io/zeldafan3421/romm-fast-scan:4.9.2-fast-scan
```

That's the entire change. No `command:` override, no `PYTHONPATH` env var, no volume mount — all of that is already baked into the image. The image is built by [this repo's GitHub Actions workflow](.github/workflows/build-container.yml) directly from the same source in this repo, not hand-pushed — if you'd rather verify that yourself or not depend on it, use Option B.

Restart the pod:

```sh
podman pod stop romm-pod && podman pod rm romm-pod && podman play kube romm.yml
```

### Option B: build it yourself

If you'd rather not run an image you didn't build:

```sh
sh scripts/build-image.sh          # builds romm:4.9.2-fast-scan locally
```

Then point `image:` at the local tag (`localhost/romm:4.9.2-fast-scan`) instead of the ghcr.io one, and restart the same way. `scripts/build-image.sh <version> <registry>` also builds for other RomM versions and can push to your own registry — see the script's usage comment.

A locally-built image isn't signed the way the published `ghcr.io` image is (only this repo's CI holds the private signing key) — add `FAST_SCAN_ALLOW_UNSIGNED_PLUGINS: "1"` (see "Plugin signing" under Configuration below) or your plugins won't load.

Either option: on first boot you'll see

```
[fast-scan] All plugins cached, nothing to compile
[fast-scan] Installed roms_handler.py (exact match: 4.9.2.py)
[fast-scan] PYTHONPATH=/romm-plugin/src:/backend
[fast-scan] Starting RomM...
```

`All plugins cached` confirms every plugin came precompiled with the image — there's no build step at container startup.

---

## Advanced install: volume mount (deprecated for supported versions)

**Deprecated for any RomM version that already has a published fast-scan image** — currently just `4.9.2`. For those, use Option A/B above instead; `patch_romm_yaml.py` (step 2 below) checks the target version and refuses to proceed for a supported one, pointing you back at the image swap.

This path stays fully supported, with no warning, as **the go-to way to try the plugin on a RomM version this repo hasn't published an image for yet** — e.g. right after a new RomM release, before someone's built and pushed a matching `X.Y.Z-fast-scan` tag. It's also still available if you specifically want to keep running `docker.io/rommapp/romm:latest` directly (auto-tracking upstream without picking a version-pinned tag) — pass `--allow-deprecated` to `patch_romm_yaml.py` if you're doing that against a supported version; tracking `:latest` itself is never blocked, since the version can't be determined ahead of time.

Unlike Option A/B, this volume-mounts the plugin onto the stock image, so plugins compile inside the container on first boot instead of at image-build time — and if the version turns out to be new enough that the committed patch doesn't apply cleanly, it's the same `refresh.sh` workflow (see [Staying up to date with RomM](#staying-up-to-date-with-romm) below) that's used to generate the patch for the next official image in the first place.

Plugins compiled this way aren't signed (only this repo's CI holds the private signing key), so this path needs `FAST_SCAN_ALLOW_UNSIGNED_PLUGINS: "1"` in your pod YAML — see "Plugin signing" under [Configuration](#configuration).

### 1. Deploy plugin files to your server

```sh
# On the machine running RomM:
mkdir -p /opt/romm/fast-scan-plugin
cp -r src overrides include plugins start.sh roms_handler.patch known_sha256.txt \
      /opt/romm/fast-scan-plugin/
cp scripts/refresh.sh /opt/romm/fast-scan-plugin/
chmod +x /opt/romm/fast-scan-plugin/start.sh /opt/romm/fast-scan-plugin/refresh.sh
```

Or run the install helper:

```sh
sh scripts/install.sh
```

### 2. Patch your pod YAML

Copy `scripts/patch_romm_yaml.py` next to your `romm.yml` and run it once:

```sh
python3 scripts/patch_romm_yaml.py
```

It first checks the `image:` tag in your `romm.yml`. If that RomM version already has a published fast-scan image, it stops there and prints the `image:` swap to use instead (pass `--allow-deprecated` to proceed anyway). Otherwise — the expected case for this path — it backs up your existing `romm.yml` and adds three things:
- `command: ["/romm-plugin/start.sh"]` — runs the plugin before RomM starts
- `PYTHONPATH=/romm-plugin/src:/backend` — makes `plugin_manager` importable (plugin `.so` files themselves are loaded by absolute path via `ctypes`, not through `PYTHONPATH`)
- A `hostPath` volume mount for the plugin directory

See `examples/romm.patched.example.yml` for the full expected result.

### 3. Restart the pod

```sh
podman pod stop romm-pod && podman pod rm romm-pod && podman play kube romm.yml
```

On **first boot** you'll see log lines like:

```
[fast-scan] Compiling fasthash -> libfasthash.so ...
[fast-scan] Built: /romm-plugin/plugins/fasthash/libfasthash.so
[fast-scan] Compiling archive-list -> libarchive_list.so ...
[fast-scan] Built: /romm-plugin/plugins/archive-list/libarchive_list.so
[fast-scan] Applied roms_handler.py patch
[fast-scan] PYTHONPATH=/romm-plugin/src:/backend
[fast-scan] Starting RomM...
```

Subsequent boots skip compilation (each plugin's `.so` is cached on the host volume).

---

## Configuration

Set `SCAN_WORKERS` in your pod YAML based on your storage:

| Storage type | Recommended workers |
|---|---|
| NVMe SSD | 12–16 |
| SATA SSD | 8–12 |
| HDD | 4–6 |
| Network (NFS/SMB) | 4–8 |

With the GIL released, workers actually run in parallel — unlike stock RomM where extra workers above ~2 give diminishing returns.

### Library size profiles (`LIBRARY_SIZE`)

By default the plugin is a **pure passthrough** — it makes scans faster and changes nothing else about how RomM behaves. Some of RomM's stock defaults get in the way once a library is big enough, though, so `LIBRARY_SIZE` lets you opt into a set of size-appropriate defaults in one switch:

```yaml
- name: LIBRARY_SIZE
  value: "LARGE"
```

| Profile | What it does |
|---|---|
| `DEFAULT` (or unset) | **Nothing.** Inherits *every* RomM default exactly as your RomM version ships them — just with faster hashing. The plugin sets no values in this mode, so if a future RomM changes a default, `DEFAULT` tracks it automatically. This is the passthrough contract. |
| `LARGE` | Raises only the knobs whose RomM stock default is too tight for a big library. Currently: the scan timeout (RomM's stock value — 4h on today's supported versions — up to 24h). |

**The `DEFAULT` invariant:** `DEFAULT` is *not* "the plugin's idea of good defaults" — it's "whatever RomM itself defaults to on the version you're running." The plugin never sets `SCAN_TIMEOUT` (or anything else) in `DEFAULT` mode; it leaves RomM's own config untouched. So `DEFAULT` on RomM 4.9.2 behaves exactly like stock RomM 4.9.2, `DEFAULT` on a future RomM behaves exactly like that future RomM, with no plugin-pinned constants to drift out of date.

**Why `LARGE` exists:** RomM runs each scan as a background job with a hard timeout (`SCAN_TIMEOUT`, currently 4h on supported versions) and kills the job when it's exceeded — even mid-scan, even though nothing is wrong. A large library can legitimately take longer, so `LARGE` gives it 24h.

Every knob a profile sets is just a smarter *default* — a value you set yourself always wins. So you can pick `LARGE` but still pin the exact timeout:

```yaml
- name: LIBRARY_SIZE
  value: "LARGE"
- name: SCAN_TIMEOUT
  value: "-1"      # LARGE's 24h default, overridden to no timeout at all
```

(`SCAN_TIMEOUT=-1` means RQ never times the job out — a genuinely stuck scan would then never be auto-reaped, though RomM's manual "stop scan" still works. `14400` is stock 4h.) An unrecognized `LIBRARY_SIZE` value logs a warning and falls back to `DEFAULT`, so a typo can never break your deployment.

### Optional: skip re-reading unchanged files

`Complete` and `Rescan hashes` scans normally re-read every byte of every ROM, even when nothing on disk changed. RomM already stores each file's size, mtime, and hashes. Set this env var to reuse the stored hashes whenever a file's size **and** mtime are unchanged, skipping the read entirely:

```yaml
- name: FAST_SCAN_HASH_CACHE
  value: "1"
```

On an unchanged library this turns a full rescan from "read every byte" into a stat pass — minutes instead of hours on an HDD. It composes with the fasthash plugin, which still accelerates the files that actually changed.

**Default off** — it's opt-in because a file edited in place that preserves both its size and mtime (rare; some sync tools do this) would not be re-hashed. It is fail-safe: any problem (disabled, unavailable, file changed, no stored record) falls back to reading and hashing the file normally, so it can never produce a wrong hash. Scope: single-file ROMs; multi-disc and archive ROMs always hash normally.

### Plugin signing

Official plugins are signed at build time; `plugin_manager.py` refuses to load an unsigned plugin by default — including a plugin you build yourself from this repo's own source (see `plugins/README.md`'s "Signing and `FAST_SCAN_ALLOW_UNSIGNED_PLUGINS`" for why). If you're on the volume-mount install or you built a plugin locally with `scripts/build-plugins.sh`, set:

```yaml
- name: FAST_SCAN_ALLOW_UNSIGNED_PLUGINS
  value: "1"
```

If you're on a prebuilt `ghcr.io/zeldafan3421/romm-fast-scan` image, you don't need this — those plugins are already signed.

---

## Compatibility commitment

This repo commits to supporting every RomM **5.\*.\*** backend release, indefinitely, and to **indefinite RomM frontend compatibility**. Neither is just a promise — both are backed by mechanism:

- **Backend, 5.\*.\*:** `scripts/list_known_versions.py` reads `known_sha256.txt` (the ledger every `refresh.sh` run appends to) as the single source of truth for which versions are supported, and `.github/workflows/build-container.yml` builds and publishes a `ghcr.io/zeldafan3421/romm-fast-scan:<version>-fast-scan` image for **every** version that ledger covers — automatically, via a build matrix, on every push to `main`. Adding a new RomM version is "run `refresh.sh`, commit the result"; nothing else needs hand-editing. A weekly scheduled workflow (`.github/workflows/compat-watch.yml`) checks upstream `rommapp/romm` releases for any `5.x` version not yet covered and opens a tracking issue if it finds one — so a gap gets surfaced automatically rather than discovered by a user.
- **Frontend, indefinitely:** every part of this project — the `roms_handler.py` source patch and every native plugin — operates entirely on RomM's Python backend. Nothing here reads, patches, or depends on RomM's frontend in any way, so no frontend change can ever break it. CI greps for accidental `frontend` references in the patched files as a cheap guard against that ever changing by mistake.

See `CLAUDE.md`'s "Versioning model" and "Roadmap: incremental backend replacement" sections for the full mechanism and where this project is headed next (hashing is the first of several planned hooks, not the only one).

---

## Staying up to date with RomM

On each boot `start.sh` patches `roms_handler.py` using a three-tier strategy:

1. **SHA match** — `known_sha256.txt` maps each known upstream file SHA to its own pre-patched copy. If the container's file matches any listed version, that copy is installed verbatim (fastest, safest). Multiple RomM versions are supported simultaneously, so the exact-match path keeps working after a `docker pull` to a version you've already refreshed against.
2. **Patch applies** — if the SHA doesn't match, try applying `roms_handler.patch` (survives minor upstream changes — e.g. it already applies cleanly to 5.0.0-alpha.2, whose changes don't touch the hashing path)
3. **Graceful fallback** — if neither works, log a warning and start RomM normally with pure-Python hashing

**If you're on the volume-mount (advanced) install**, this runs fresh against whatever image tag you're currently running, so pulling a new `rommapp/romm` tag just works — you'll see the warning below if that version is new enough to miss both tier-1 and tier-2.

**If you're on a prebuilt image** (Option A/B), the RomM version is fixed by whichever image tag you deployed. To move to a newer RomM release, pull/build the matching fast-scan-tagged image and swap `image:` again — same one-line change as installing. Every known-version image is rebuilt automatically on every push to this repo's `main` branch (see `.github/workflows/build-container.yml`'s build matrix, derived from `known_sha256.txt` via `scripts/list_known_versions.py`), so e.g. `4.9.2-fast-scan` always reflects the latest plugin fixes for that RomM version. A published image for a *new* RomM version appears as soon as this repo has run `refresh.sh` against it and committed the result — see [Compatibility commitment](#compatibility-commitment) above.

When you see this warning after a `docker pull` (or when the image build hits a RomM version this hasn't been refreshed against yet):

```
[fast-scan] WARNING: Could not patch roms_handler.py.
```

Run the refresh tool **inside the running container**:

```sh
podman exec <container-id> sh /romm-plugin/refresh.sh
podman pod stop romm-pod && podman pod rm romm-pod && podman play kube romm.yml
```

This re-generates the patch against the new RomM version and updates `known_sha256.txt`. If you're building your own image (Option B), copy the regenerated `roms_handler.patch`/`known_sha256.txt`/`overrides/prepatched/` back out of the container into this repo and rebuild — see `refresh.sh`'s output for the exact files it touched.

### Removing old versions

Every refresh appends an entry to `known_sha256.txt` and a file to `overrides/prepatched/`, so that list only grows as RomM is updated over time. Trim it with:

```sh
python3 scripts/prune_versions.py list
python3 scripts/prune_versions.py remove 4.9.0 4.9.1       # by version, filename, or SHA prefix
python3 scripts/prune_versions.py keep-latest 3            # keep only the N most recently recorded
```

Removing a version doesn't break anything — `start.sh` just falls back to tier-2 (the diff patch) for that version's SHA instead of the tier-1 exact match, same as for any version that was never recorded. Add `--dry-run` to preview, or `--purge` to delete the old pre-patched files outright instead of moving them to `overrides/prepatched/.removed/` (the default, reversible behavior). `known_sha256.txt` is backed up before every change. Pass `--dir /opt/romm/fast-scan-plugin` to prune a deployed plugin directory instead of the repo checkout.

---

## Fallback behaviour

If anything goes wrong, RomM still starts normally:

- Volume-mount install: if a compiler is unavailable and a plugin's `.so` isn't cached → that hook falls back to pure Python. Prebuilt images (Option A/B) never hit this — every plugin is already compiled into the image.
- If the patch fails to apply → stock `roms_handler.py`, no fast path
- If a plugin's `.so` fails a sha256/ABI-version check, fails to load, or a call into it fails → `plugin_manager` returns `None` and the caller falls back to Python, same as if no plugin were installed at all

No ROM data is ever at risk.

---

## Uninstallation

**If you installed via Option A/B (image swap):** change `image:` back to the stock tag and restart — the exact inverse of installing, no scripts involved:

```diff
-      image: ghcr.io/zeldafan3421/romm-fast-scan:4.9.2-fast-scan
+      image: docker.io/rommapp/romm:4.9.2
```

```sh
podman pod stop romm-pod && podman pod rm romm-pod && podman play kube romm.yml
```

**If you installed via the volume-mount (advanced) path:**

```sh
sh scripts/uninstall.sh /opt/romm/fast-scan-plugin /path/to/romm.yml
podman pod stop romm-pod && podman pod rm romm-pod && podman play kube /path/to/romm.yml
```

This:
- Reverts `romm.yml` to stock RomM — removes the entrypoint override, `PYTHONPATH`, and volume mount that `patch_romm_yaml.py` added (backs up first, same as installing)
- Deletes the plugin directory from the host
- Leaves your ROM library, RomM's database, and any `romm.yml.bak.*` backups untouched

Omit the `romm.yml` argument to only remove the plugin directory and leave your pod YAML as-is (you'll see a reminder with the command to run later). To revert just the YAML without touching the plugin directory, run `python3 scripts/unpatch_romm_yaml.py /path/to/romm.yml` directly.

**Either way:** hashes already computed by the fasthash plugin are ordinary CRC32/MD5/SHA1 values — RomM doesn't know or care they came from the plugin, so nothing needs to be re-scanned after uninstalling.

---

## File layout

```
romm-fast-scan/
├── README.md                    Main documentation entry point
│
├── Plugin System:
│   ├── include/
│   │   └── romm_plugin_abi.h    The C-ABI contract every plugin implements
│   ├── plugins/
│   │   ├── README.md            Plugin authoring guide (start here to add a plugin)
│   │   ├── official-signers.txt Public key(s) plugin_manager.py verifies signatures against
│   │   ├── fasthash/            hash_file + hash_file_accum hooks (CRC32/MD5/SHA1)
│   │   │   ├── fasthash.c
│   │   │   └── plugin.json.tmpl
│   │   └── archive-list/        archive_list hook (ZIP central-directory listing)
│   │       ├── archive_list.c
│   │       └── plugin.json.tmpl
│   ├── src/
│   │   ├── plugin_manager.py    ctypes loader: discovers, verifies, and calls into plugins
│   │   └── fast_scan_cache.py   Opt-in hash-skip cache (FAST_SCAN_HASH_CACHE)
│   ├── overrides/
│   │   └── prepatched/          Pre-patched handlers, one per known RomM version
│   │       ├── 4.9.2.py
│   │       └── 5.0.0-alpha.2.py
│   ├── start.sh                 Container entrypoint wrapper (core plugin file)
│   ├── roms_handler.patch       Minimal unified diff applied at boot
│   └── known_sha256.txt         Maps each known roms_handler.py SHA → pre-patched file
│
├── Container Automation:
│   ├── Dockerfile               Docker build file
│   ├── Containerfile            Podman build file
│   └── .github/workflows/
│       ├── build-container.yml   Builds+publishes an image for every known-version (matrix)
│       └── compat-watch.yml      Weekly: flags upstream RomM 5.x versions not yet covered
│
├── scripts/                     Utility scripts
│   ├── install.sh                Host-side plugin deployment
│   ├── uninstall.sh              Host-side plugin removal (reverts romm.yml + deletes files)
│   ├── patch_romm_yaml.py        Patches your romm.yml in-place (with backup)
│   ├── unpatch_romm_yaml.py      Reverts romm.yml to stock (with backup)
│   ├── build-image.sh            Container image builder helper
│   ├── build-plugins.sh          Compiles plugins/*/*.c and finalizes plugin.json
│   ├── run-docker.sh             Run RomM + plugin with plain `docker run`, no config file
│   ├── run-podman.sh             Run RomM + plugin with plain `podman run`, no config file
│   ├── refresh.sh                Re-generates patch after a RomM update
│   ├── prune_versions.py         Removes old recorded RomM versions
│   ├── list_known_versions.py    Single source of truth for "which versions are supported"
│   └── check_upstream_versions.py  Compares known_sha256.txt against upstream RomM releases
│
├── examples/                    Example configurations
│   ├── romm.release.yml         Ready-to-deploy pod YAML (Option A/B image swap)
│   ├── docker-compose.yml       Ready-to-deploy Compose file (same, Compose form)
│   └── romm.patched.example.yml Illustrative volume-mount result (Advanced install)
│
└── Other:
    ├── LICENSE                  AGPL-3.0
    └── NOTICE                   Derivative work attribution
```

Compiled plugin `.so` files and their finalized `plugin.json` (with a real `sha256`, computed at build time) are build artifacts, not committed — same treatment `lib/*.so` had for the old single extension. `plugins/*/plugin.json.tmpl` is the committed template each build fills in.

---

## Documentation

📖 **See the [Wiki](https://github.com/zeldafan3421/romm-fast-scan/wiki)** for comprehensive documentation:

- [Quick Start](https://github.com/zeldafan3421/romm-fast-scan/wiki/Home) — Build reference
- [Testing](https://github.com/zeldafan3421/romm-fast-scan/wiki/Testing) — Test procedures and benchmarks
- [Pre-Deployment Checklist](https://github.com/zeldafan3421/romm-fast-scan/wiki/Pre-Deployment-Checklist) — Readiness validation
- [Troubleshooting](https://github.com/zeldafan3421/romm-fast-scan/wiki/Troubleshooting) — Common issues
- [Edge Cases](https://github.com/zeldafan3421/romm-fast-scan/wiki/Edge-Cases) — Limitations and workarounds
- [Architecture](https://github.com/zeldafan3421/romm-fast-scan/wiki/Architecture) — Technical internals
- [Container Build](https://github.com/zeldafan3421/romm-fast-scan/wiki/Container-Build) — Building images
- [Container Design](https://github.com/zeldafan3421/romm-fast-scan/wiki/Container-Design) — Design & maintenance

---

## License

AGPL-3.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

The pre-patched handlers under `overrides/prepatched/` are derivative works of
[rommapp/romm](https://github.com/rommapp/romm), which is also AGPL-3.0.

---

## Disclaimer

Not affiliated with or endorsed by the RomM project. Use at your own risk.
