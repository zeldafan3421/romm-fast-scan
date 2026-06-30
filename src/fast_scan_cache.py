"""
fast_scan_cache.py  —  romm fast-scan plugin: hash-skip cache
─────────────────────────────────────────────────────────────
Opt-in optimisation for COMPLETE / "Rescan hashes" scans.

On those scan types RomM re-reads every byte of every ROM to recompute its
CRC32/MD5/SHA1, even when nothing on disk changed. RomM already stores each
file's size and mtime alongside its hashes (models.rom.RomFile). When the file
on disk still has the same size and mtime as the stored record, its content
cannot have changed, so the stored hashes are reused and the full read is
skipped — turning a multi-hour rescan of an unchanged library into a stat pass.

Enable by setting the environment variable:

    FAST_SCAN_HASH_CACHE=1            (1/true/yes/on, case-insensitive)

Everything here is best-effort and fail-safe: any problem (flag off, module
moved upstream, file missing, DB error, no stored record, mismatch) returns
None, and the caller falls back to reading + hashing the file normally. The
cache is therefore never able to produce a wrong hash — at worst it does
nothing and RomM behaves exactly as stock.

Scope: single-file ROMs only (one RomFile whose file_name == rom.fs_name).
Multi-disc / archive ROMs always fall through to the normal path.
"""

import os

_TRUTHY = {"1", "true", "yes", "on"}

# mtime is stored as a float and round-trips through the DB as a double; a tiny
# epsilon absorbs any float noise without ever widening into a real change.
_MTIME_EPS = 1e-6


def is_enabled() -> bool:
    return os.environ.get("FAST_SCAN_HASH_CACHE", "").strip().lower() in _TRUTHY


def cached_file_hash(rom_id, abs_roms_path, file_name):
    """Return (crc_hex, md5_hex, sha1_hex, chd_sha1_hex) if the on-disk file is
    byte-for-byte unchanged from the stored RomFile record, else None.

    Args:
        rom_id:        Rom.id of the ROM being scanned.
        abs_roms_path: absolute directory containing the file.
        file_name:     the file's name (== rom.fs_name for single-file ROMs).
    """
    if not is_enabled():
        return None

    try:
        path = os.path.join(str(abs_roms_path), file_name)
        st = os.stat(path)  # cheap: no content read
    except OSError:
        return None

    try:
        # Imported lazily so a stock RomM that lacks/renames these never breaks
        # import of this module — it just disables the cache.
        from handler.database.base_handler import sync_session
        from models.rom import RomFile
        from sqlalchemy import select
    except Exception:
        return None

    try:
        with sync_session.begin() as session:
            rf = session.scalars(
                select(RomFile)
                .where(RomFile.rom_id == rom_id, RomFile.file_name == file_name)
                .limit(1)
            ).first()

            if rf is None:
                return None

            # Size must match exactly; mtime within float epsilon.
            if rf.file_size_bytes != st.st_size:
                return None
            stored_mtime = rf.last_modified
            if stored_mtime is None or abs(stored_mtime - st.st_mtime) > _MTIME_EPS:
                return None

            crc = rf.crc_hash or ""
            md5 = rf.md5_hash or ""
            sha1 = rf.sha1_hash or ""
            chd = rf.chd_sha1_hash or ""

            # Require at least one real hash on record; an all-empty row means
            # the file was never successfully hashed, so recompute it.
            if not (crc or md5 or sha1 or chd):
                return None

            return (crc, md5, sha1, chd)
    except Exception:
        return None
