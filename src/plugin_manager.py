"""
plugin_manager.py — loader for romm-fast-scan native (C-ABI) plugins.
──────────────────────────────────────────────────────────────────────────
Discovers, verifies, and loads plugin .so files described by a plugin.json
manifest (see plugins/README.md and include/romm_plugin_abi.h for the full
contract). Every public function here follows the same fail-open contract
as the rest of this project: any problem — missing plugin, sha256 mismatch,
ABI version mismatch, a plugin call itself failing — returns None (or, for
the class-based multi-file API, raises nothing and simply makes the object
inert), and the caller falls back to the existing pure-Python path. A
plugin can degrade a scan's speed; it must never be able to break one.

One check is deliberately NOT fail-open: signature verification. By
default a plugin whose .so isn't signed by the official key (see
plugins/README.md's "Signing and FAST_SCAN_ALLOW_UNSIGNED_PLUGINS"
section) is refused outright, not loaded-with-a-warning -- set
FAST_SCAN_ALLOW_UNSIGNED_PLUGINS=1 to opt back into the older
sha256-tamper-check-only behavior. This still composes with everything
above: a refused plugin is just another reason a hook stays unavailable
and callers fall back to Python, same as any other rejection.

stdlib only (ctypes), matching every other Python file in this repo — no
cffi, no requirements.txt. See CLAUDE.md's "Python here is stdlib-only" note.

Usage (mirrors the shape roms_handler.py's patch calls into):

    import plugin_manager as pm
    pm.load_plugins("/romm-plugin/plugins")   # once, at import/startup

    result = pm.hash_file(path)               # None on any failure/absence
    if result is None:
        result = _python_hash_file(path)      # existing fallback

    accum = pm.new_multi_file_accumulator()   # None if hash_file_accum unavailable
    if accum is not None:
        crc, md5, sha1 = accum.hash_file(member_path)
        ...
        combined = accum.finalize()
        accum.free()
"""

import ctypes
import hashlib
import json
import logging
import os
import pathlib
import subprocess

log = logging.getLogger("plugin_manager")

CRC_BUF_LEN = 9
MD5_BUF_LEN = 33
SHA1_BUF_LEN = 41
ARCHIVE_NAME_MAX = 260

ROMM_PLUGIN_ABI_VERSION = 1

# ── Signing ───────────────────────────────────────────────────────────────
# Official plugins (fasthash, archive-list) are signed at build time by
# .github/workflows/build-container.yml's sign-plugins job, using the
# private half of a keypair that exists only as the PLUGIN_SIGNING_KEY
# GitHub Actions secret -- it is never committed. Verification here checks
# a plugin's .so against plugins/official-signers.txt (public key material,
# safe to commit) via `ssh-keygen -Y verify`, the same primitive git's
# gpg.format=ssh commit signing uses. See plugins/README.md's "Signing and
# FAST_SCAN_ALLOW_UNSIGNED_PLUGINS" section for the full rationale.
#
# Unlike every other check in this file, an unverified signature does NOT
# fail open by default -- that's the point. A missing/corrupt/tampered
# signature, a missing ssh-keygen binary, or a missing official-signers.txt
# are all treated identically to "not signed by the official key" and the
# plugin is refused, unless FAST_SCAN_ALLOW_UNSIGNED_PLUGINS is set. This
# still composes with the rest of the fail-open contract below it: a
# refused plugin just means this hook returns None, exactly like any other
# rejection reason already does -- roms_handler.py needs no changes.
SIGNING_NAMESPACE = "romm-fast-scan-plugin"
OFFICIAL_SIGNER_IDENTITY = "romm-fast-scan-official"
ALLOW_UNSIGNED_ENV = "FAST_SCAN_ALLOW_UNSIGNED_PLUGINS"
ALLOWED_SIGNERS_FILENAME = "official-signers.txt"
_TRUTHY = {"1", "true", "yes", "on"}


def _allow_unsigned() -> bool:
    return os.environ.get(ALLOW_UNSIGNED_ENV, "").strip().lower() in _TRUTHY


def _signature_verified(so_path: pathlib.Path, allowed_signers_path: pathlib.Path) -> bool:
    """True only if so_path has a matching <so_path>.sig signed by a key
    listed in allowed_signers_path under OFFICIAL_SIGNER_IDENTITY. Any
    problem at all -- missing .sig, missing allowed_signers file, missing
    ssh-keygen binary, a tampered .so, wrong key -- returns False, never
    raises. False is not itself a rejection; the caller decides what to do
    with it (see ALLOW_UNSIGNED_ENV above)."""
    sig_path = so_path.with_name(so_path.name + ".sig")
    if not sig_path.is_file() or not allowed_signers_path.is_file():
        return False
    try:
        with open(so_path, "rb") as f:
            result = subprocess.run(
                [
                    "ssh-keygen", "-Y", "verify",
                    "-f", str(allowed_signers_path),
                    "-I", OFFICIAL_SIGNER_IDENTITY,
                    "-n", SIGNING_NAMESPACE,
                    "-s", str(sig_path),
                ],
                stdin=f,
                capture_output=True,
                timeout=10,
            )
    except Exception:
        return False
    return result.returncode == 0

# hook name -> loaded implementation, populated by load_plugins()
_HOOKS: dict = {}
# plugin name -> ctypes.CDLL, kept alive for the process lifetime (a CDLL
# unloaded while a hook is still registered would make every subsequent
# call through that hook segfault)
_LOADED_LIBS: dict = {}


class _ArchiveEntry(ctypes.Structure):
    _fields_ = [
        ("name", ctypes.c_char * ARCHIVE_NAME_MAX),
        ("compressed_size", ctypes.c_uint64),
        ("uncompressed_size", ctypes.c_uint64),
        ("crc32", ctypes.c_uint32),
    ]


def _sha256_of(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(256 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _bind_hash_file(lib, entry_symbol: str):
    fn = getattr(lib, entry_symbol)
    fn.restype = ctypes.c_int
    fn.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p]

    def hash_file(path: str):
        crc = ctypes.create_string_buffer(CRC_BUF_LEN)
        md5 = ctypes.create_string_buffer(MD5_BUF_LEN)
        sha1 = ctypes.create_string_buffer(SHA1_BUF_LEN)
        try:
            rc = fn(path.encode(), crc, md5, sha1)
        except Exception:
            return None
        if rc != 0:
            return None
        return crc.value.decode(), md5.value.decode(), sha1.value.decode()

    return hash_file


def _bind_hash_file_accum(lib, entry_symbols: dict):
    new_fn = getattr(lib, entry_symbols["new"])
    new_fn.restype = ctypes.c_void_p
    new_fn.argtypes = []

    file_fn = getattr(lib, entry_symbols["file"])
    file_fn.restype = ctypes.c_int
    file_fn.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p]

    finalize_fn = getattr(lib, entry_symbols["finalize"])
    finalize_fn.restype = ctypes.c_int
    finalize_fn.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p]

    free_fn = getattr(lib, entry_symbols["free"])
    free_fn.restype = None
    free_fn.argtypes = [ctypes.c_void_p]

    class MultiFileAccumulator:
        """Class-based wrapper over the accum_new/_file/_finalize/_free C
        functions, shaped to match the old MultiFileHasher's Python API so
        callers barely change. Every method fails open: a call after the
        handle failed to allocate (self._h is None) or after free() is a
        silent no-op / None return, never an exception."""

        def __init__(self):
            try:
                self._h = new_fn()
            except Exception:
                self._h = None

        def hash_file(self, path: str):
            if not self._h:
                return None
            crc = ctypes.create_string_buffer(CRC_BUF_LEN)
            md5 = ctypes.create_string_buffer(MD5_BUF_LEN)
            sha1 = ctypes.create_string_buffer(SHA1_BUF_LEN)
            try:
                rc = file_fn(self._h, path.encode(), crc, md5, sha1)
            except Exception:
                return None
            if rc != 0:
                return None
            return crc.value.decode(), md5.value.decode(), sha1.value.decode()

        def finalize(self):
            if not self._h:
                return None
            crc = ctypes.create_string_buffer(CRC_BUF_LEN)
            md5 = ctypes.create_string_buffer(MD5_BUF_LEN)
            sha1 = ctypes.create_string_buffer(SHA1_BUF_LEN)
            try:
                rc = finalize_fn(self._h, crc, md5, sha1)
            except Exception:
                return None
            if rc != 0:
                return None
            return crc.value.decode(), md5.value.decode(), sha1.value.decode()

        def free(self):
            if self._h:
                try:
                    free_fn(self._h)
                except Exception:
                    pass
                self._h = None

        def __del__(self):
            self.free()

    return MultiFileAccumulator


def _bind_archive_list(lib, entry_symbols: dict):
    open_fn = getattr(lib, entry_symbols["open"])
    open_fn.restype = ctypes.c_void_p
    open_fn.argtypes = [ctypes.c_char_p]

    count_fn = getattr(lib, entry_symbols["entry_count"])
    count_fn.restype = ctypes.c_int
    count_fn.argtypes = [ctypes.c_void_p]

    at_fn = getattr(lib, entry_symbols["entry_at"])
    at_fn.restype = ctypes.c_int
    at_fn.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(_ArchiveEntry)]

    close_fn = getattr(lib, entry_symbols["close"])
    close_fn.restype = None
    close_fn.argtypes = [ctypes.c_void_p]

    def archive_list(path: str):
        """Returns a list of (name, compressed_size, uncompressed_size,
        crc32_int) tuples, or None on any failure (not a supported archive,
        corrupt, or missing) -- caller falls back to the existing Python
        archive handling."""
        try:
            handle = open_fn(path.encode())
        except Exception:
            return None
        if not handle:
            return None
        try:
            n = count_fn(handle)
            if n < 0:
                return None
            results = []
            for i in range(n):
                entry = _ArchiveEntry()
                rc = at_fn(handle, i, ctypes.byref(entry))
                if rc != 0:
                    return None
                results.append((
                    entry.name.decode(errors="replace"),
                    int(entry.compressed_size),
                    int(entry.uncompressed_size),
                    int(entry.crc32),
                ))
            return results
        except Exception:
            return None
        finally:
            try:
                close_fn(handle)
            except Exception:
                pass

    return archive_list


_HOOK_BINDERS = {
    "hash_file": lambda lib, hook_cfg: _bind_hash_file(lib, hook_cfg["entry_symbol"]),
    "hash_file_accum": lambda lib, hook_cfg: _bind_hash_file_accum(lib, hook_cfg["entry_symbols"]),
    "archive_list": lambda lib, hook_cfg: _bind_archive_list(lib, hook_cfg["entry_symbols"]),
}


def load_plugins(plugin_dir: str) -> None:
    """Discover and load every plugin under plugin_dir/*/plugin.json.
    Never raises: a bad plugin is logged and skipped, not fatal to startup.
    Safe to call with a nonexistent directory (no plugins load, every hook
    stays unavailable -- identical to a fresh install with none configured)."""
    root = pathlib.Path(plugin_dir)
    if not root.is_dir():
        log.info("plugin_manager: %s not found, no plugins loaded", plugin_dir)
        return

    for manifest_path in sorted(root.glob("*/plugin.json")):
        plugin_label = manifest_path.parent.name
        try:
            meta = json.loads(manifest_path.read_text())

            so_path = manifest_path.parent / meta["so_file"]
            if not so_path.is_file():
                raise FileNotFoundError(f"so_file '{meta['so_file']}' not found")

            claimed_sha = meta.get("sha256")
            if not claimed_sha:
                raise ValueError("manifest has no sha256 -- refusing to load unverified .so")
            actual_sha = _sha256_of(so_path)
            if actual_sha != claimed_sha:
                raise ValueError(f"sha256 mismatch (manifest={claimed_sha[:12]}... actual={actual_sha[:12]}...)")

            allowed_signers_path = root / ALLOWED_SIGNERS_FILENAME
            signed = _signature_verified(so_path, allowed_signers_path)
            if not signed:
                if not _allow_unsigned():
                    raise ValueError(
                        f"not signed by the official key (see plugins/README.md) -- "
                        f"set {ALLOW_UNSIGNED_ENV}=1 to load unsigned/third-party plugins anyway"
                    )
                log.warning(
                    "[plugin] %s: loading WITHOUT a verified signature because %s=1 is set -- "
                    "this is running unverified native code",
                    plugin_label, ALLOW_UNSIGNED_ENV,
                )

            manifest_abi = meta.get("abi_version")

            lib = ctypes.CDLL(str(so_path))
            lib.romm_plugin_abi_version.restype = ctypes.c_int
            lib.romm_plugin_abi_version.argtypes = []
            binary_abi = lib.romm_plugin_abi_version()

            # Two distinct failure modes, checked in an order that keeps
            # both reachable (checking each independently against
            # ROMM_PLUGIN_ABI_VERSION first would make this second check
            # unreachable, since two things that both equal a constant
            # necessarily equal each other):
            #   1. manifest and binary disagree with *each other* -- a
            #      stale plugin.json sitting next to a freshly rebuilt .so,
            #      or vice versa, independent of what this loader supports.
            #   2. they agree with each other but not with what this loader
            #      supports -- a plugin genuinely built for a different ABI
            #      generation.
            if manifest_abi != binary_abi:
                raise ValueError(f"manifest claims abi_version={manifest_abi} but .so reports {binary_abi}")
            if binary_abi != ROMM_PLUGIN_ABI_VERSION:
                raise ValueError(f"plugin is abi_version={binary_abi}, this loader supports {ROMM_PLUGIN_ABI_VERSION}")

            hooks = meta.get("hooks", {})
            if not hooks:
                raise ValueError("manifest declares no hooks")

            registered = []
            for hook_name, hook_cfg in hooks.items():
                binder = _HOOK_BINDERS.get(hook_name)
                if binder is None:
                    log.warning("[plugin] %s: unknown hook '%s', skipping that hook", plugin_label, hook_name)
                    continue
                if hook_name in _HOOKS:
                    log.warning(
                        "[plugin] %s: hook '%s' already provided by another plugin, keeping the first one",
                        plugin_label, hook_name,
                    )
                    continue
                _HOOKS[hook_name] = binder(lib, hook_cfg)
                registered.append(hook_name)

            if registered:
                _LOADED_LIBS[plugin_label] = lib
                log.info("[plugin] loaded %s: hooks=%s", plugin_label, registered)
            else:
                log.warning("[plugin] %s: no usable hooks, not registering", plugin_label)

        except Exception as e:
            log.warning("[plugin] skipping %s: %s", plugin_label, e)


def hash_file(path: str):
    """hash_file(path) -> (crc_hex, md5_hex, sha1_hex) | None.
    None means: no plugin provides this hook, or the plugin call failed --
    caller falls back to Python."""
    fn = _HOOKS.get("hash_file")
    if fn is None:
        return None
    return fn(path)


def new_multi_file_accumulator():
    """Returns a MultiFileAccumulator instance, or None if no plugin
    provides the hash_file_accum hook. The returned object's own methods
    also fail open (return None) if anything goes wrong after construction."""
    cls = _HOOKS.get("hash_file_accum")
    if cls is None:
        return None
    return cls()


def archive_list(path: str):
    """archive_list(path) -> [(name, compressed_size, uncompressed_size,
    crc32_int), ...] | None. None means: no plugin provides this hook, the
    archive format isn't one this plugin understands, or the archive is
    corrupt -- caller falls back to Python archive handling."""
    fn = _HOOKS.get("archive_list")
    if fn is None:
        return None
    return fn(path)


def loaded_hooks() -> list:
    """Which hooks currently have a plugin registered. Mainly for
    diagnostics/testing."""
    return sorted(_HOOKS.keys())
