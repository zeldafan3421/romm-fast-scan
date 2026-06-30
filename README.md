# romm-fast-scan

A drop-in scanning performance plugin for [RomM](https://github.com/rommapp/romm) that replaces the pure-Python file hashing path with a C extension that releases the GIL, enabling genuine parallel hashing across scan workers.

Tested on **RomM 4.9.2**. Includes tooling to stay compatible across updates.

---

## How it works

RomM computes CRC32, MD5, and SHA1 hashes for every ROM file during a scan. The original implementation does this in pure Python, which means the GIL serializes all workers even when `SCAN_WORKERS > 1` — extra workers don't actually run in parallel.

This plugin compiles a small C extension (`_fasthash.c`) inside the container at first boot. The extension:

- Computes all three hashes in a **single file pass** using a 256 KB read buffer
- Calls `Py_BEGIN_ALLOW_THREADS` / `Py_END_ALLOW_THREADS` to **release the GIL** during I/O and hashing
- Falls back transparently to the original Python path for archive files (`.zip`, `.7z`, `.rar`, etc.) that require decompression

The result is that `SCAN_WORKERS` threads actually run in parallel on CPU and I/O simultaneously.

**Observed speedup on a 28,000-game library:** ~3–5× faster full rescan with 4 workers on HDD; higher on SSD.

---

## Requirements

- RomM deployed via Podman pod YAML (Kubernetes-style)
- The container must have internet access on first boot (to `apk add gcc`)
- Python 3.13 (the version RomM 4.9.2 ships)

---

## Installation

### 1. Deploy plugin files to your server

```sh
# On the machine running RomM:
mkdir -p /opt/romm/fast-scan-plugin/lib
cp -r src overrides start.sh refresh.sh roms_handler.patch known_sha256.txt \
      /opt/romm/fast-scan-plugin/
chmod +x /opt/romm/fast-scan-plugin/start.sh \
         /opt/romm/fast-scan-plugin/refresh.sh
```

Or run the helper:

```sh
sh install.sh
```

### 2. Patch your pod YAML

Copy `patch_romm_yaml.py` next to your `romm.yml` and run it once:

```sh
python3 patch_romm_yaml.py
```

This backs up your existing `romm.yml` and adds three things:
- `command: ["/romm-plugin/start.sh"]` — runs the plugin before RomM starts
- `PYTHONPATH=/romm-plugin/lib:/backend` — makes the compiled `.so` importable
- A `hostPath` volume mount for the plugin directory

See `romm.patched.example.yml` for the full expected result.

### 3. Restart the pod

```sh
podman pod stop romm-pod && podman pod rm romm-pod && podman play kube romm.yml
```

On **first boot** you'll see log lines like:

```
[fast-scan] Compiling _fasthash extension for cpython-313-x86_64-linux-musl.so ...
[fast-scan] Built: /romm-plugin/lib/_fasthash.cpython-313-x86_64-linux-musl.so
[fast-scan] Applied roms_handler.py patch
[fast-scan] PYTHONPATH=/romm-plugin/lib:/backend
[fast-scan] Starting RomM...
```

Subsequent boots skip compilation (the `.so` is cached on the host volume).

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

---

## Staying up to date with RomM

On each boot `start.sh` patches `roms_handler.py` using a three-tier strategy:

1. **SHA match** — if the container's file matches `known_sha256.txt`, use the pre-patched copy (fastest, safest)
2. **Patch applies** — if the SHA doesn't match, try applying `roms_handler.patch` (survives minor upstream changes)
3. **Graceful fallback** — if neither works, log a warning and start RomM normally with pure-Python hashing

When you see this warning after a `docker pull`:

```
[fast-scan] WARNING: Could not patch roms_handler.py.
```

Run the refresh tool **inside the running container**:

```sh
podman exec <container-id> sh /romm-plugin/refresh.sh
podman pod stop romm-pod && podman pod rm romm-pod && podman play kube romm.yml
```

This re-generates the patch against the new RomM version and updates `known_sha256.txt`.

---

## Fallback behaviour

If anything goes wrong, RomM still starts normally:

- If `gcc` is unavailable and `_fasthash.so` isn't cached → pure Python hashing
- If the patch fails to apply → stock `roms_handler.py`, no fast path
- If `_fasthash` raises an exception at import or call time → falls back to Python per-file

No ROM data is ever at risk.

---

## File layout

```
romm-fast-scan/
├── src/
│   └── _fasthash.c              C extension: CRC32 + MD5 + SHA1 with GIL release
├── overrides/
│   └── handler/filesystem/
│       └── roms_handler.py      Patched handler (RomM 4.9.2 base)
├── lib/                         Compiled .so lands here at runtime (gitignored)
├── start.sh                     Container entrypoint wrapper
├── refresh.sh                   Re-generates patch after a RomM update
├── install.sh                   Host-side setup helper
├── patch_romm_yaml.py           Patches your romm.yml in-place (with backup)
├── roms_handler.patch           Minimal unified diff applied at boot
├── known_sha256.txt             SHA256 of the roms_handler.py this was built against
└── romm.patched.example.yml     Example of a fully patched pod YAML
```

---

## License

AGPL-3.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

`overrides/handler/filesystem/roms_handler.py` is a derivative work of
[rommapp/romm](https://github.com/rommapp/romm), which is also AGPL-3.0.

---

## Disclaimer

Not affiliated with or endorsed by the RomM project. Use at your own risk.
