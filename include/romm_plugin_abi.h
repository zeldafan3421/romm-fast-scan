/*
 * romm_plugin_abi.h — the C ABI contract for romm-fast-scan native plugins.
 *
 * This is the only header a plugin author needs. A plugin is a shared
 * library (.so) that exports a small set of `extern "C"` functions matching
 * the shapes declared here, plus a `plugin.json` manifest (see
 * plugins/README.md) that tells the Python-side loader (src/plugin_manager.py)
 * which hook it implements, which symbol to call, and a SHA256 of the .so
 * for a cheap tamper/corruption check before it's ever loaded.
 *
 * Design rules (non-negotiable — the whole fail-open contract depends on them):
 *
 *   1. Only primitives, fixed-size buffers, and structs of primitives cross
 *      this boundary. No STL, no C++ exceptions escaping a plugin function,
 *      no Python objects, no ownership of memory that crosses languages
 *      without an explicit alloc/free pair declared here.
 *
 *   2. Every hook function returns a status code: 0 = success, nonzero =
 *      failure. On failure the caller (plugin_manager.py) falls back to the
 *      existing pure-Python implementation — a plugin can never be the only
 *      way a feature works, and a bug in a plugin can never be worse than
 *      "as slow as stock RomM used to be."
 *
 *   3. A plugin must never crash the process on bad input (a missing file,
 *      a corrupt archive, an unreadable image). Catch it, return nonzero.
 *      A segfault in a plugin still takes down the whole RomM worker process
 *      exactly like a segfault anywhere else in a shared library would --
 *      this header cannot protect you from that, only your own code can.
 *
 *   4. Every plugin .so must export romm_plugin_abi_version() returning
 *      ROMM_PLUGIN_ABI_VERSION below. The loader checks this *and*
 *      cross-checks it against the "abi_version" claimed in plugin.json
 *      before calling anything else -- a mismatch in either direction
 *      (stale manifest next to a rebuilt .so, or vice versa) is rejected
 *      before any hook function is ever invoked.
 *
 * ABI version history:
 *   1 — initial: hash_file hook (single-file + multi-file accumulator),
 *       archive_list hook (ZIP central directory listing).
 */

#ifndef ROMM_PLUGIN_ABI_H
#define ROMM_PLUGIN_ABI_H

#include <stddef.h>

#define ROMM_PLUGIN_ABI_VERSION 1

/* Buffer sizes for hex-digest output params (hex digits + NUL terminator). */
#define ROMM_CRC32_HEX_LEN  9   /* 8 hex chars + NUL */
#define ROMM_MD5_HEX_LEN   33   /* 32 hex chars + NUL */
#define ROMM_SHA1_HEX_LEN  41   /* 40 hex chars + NUL */

#ifdef __cplusplus
extern "C" {
#endif

/* ══════════════════════════════════════════════════════════════════════════
 * Required export — every plugin .so must have this, regardless of which
 * hook(s) it implements. The loader calls this before trusting anything
 * else the .so exports.
 * ══════════════════════════════════════════════════════════════════════════ */
int romm_plugin_abi_version(void);

/* ══════════════════════════════════════════════════════════════════════════
 * Hook: "hash_file" — CRC32 + MD5 + SHA1 of a single file.
 *
 * hook name in plugin.json: "hash_file"
 * default entry_symbol:     "romm_hash_file"
 *
 * out buffers must be at least ROMM_{CRC32,MD5,SHA1}_HEX_LEN bytes. On
 * success they're written as lowercase hex + NUL. On a zero-byte file, all
 * three are written as empty strings (matches the existing _fasthash.c
 * convention carried over from the CPython-extension version of this).
 *
 * Returns 0 on success, nonzero on any failure (file not found, read error,
 * hashing error) -- caller falls back to Python.
 * ══════════════════════════════════════════════════════════════════════════ */
int romm_hash_file(const char *path,
                    char *crc_out,
                    char *md5_out,
                    char *sha1_out);

/* ── Multi-file accumulator variant, for multi-disc ROMs ────────────────────
 * hook name in plugin.json: "hash_file_accum"
 * default entry_symbols:    "romm_hash_accum_new" / "_file" / "_finalize" / "_free"
 *
 * Mirrors the existing MultiFileHasher: create a handle, feed it files one
 * at a time (each call also yields that file's own individual digest),
 * finalize for the combined digest across everything fed in, free the
 * handle when done. A plugin implementing this hook must serialize access
 * to a single handle's state itself if it expects concurrent use from
 * multiple threads on the same handle -- the loader does not add locking
 * (see the note on MultiFileHasher's PyThread_type_lock in the old
 * CPython-extension version of this code; same hazard, same fix, now the
 * plugin's own responsibility instead of ours).
 */

/* Returns an opaque handle, or NULL on failure (e.g. OOM, crypto init failure). */
void *romm_hash_accum_new(void);

/* Hash `path` and fold its bytes into `handle`'s running accumulator.
 * per_file_{crc,md5,sha1}_out may each be NULL individually if the caller
 * doesn't need that file's own digest (only the running accumulation).
 * Returns 0 on success. On failure, `handle`'s accumulated state is left
 * unchanged (the file that failed to read contributes nothing). */
int romm_hash_accum_file(void *handle, const char *path,
                          char *per_file_crc_out,
                          char *per_file_md5_out,
                          char *per_file_sha1_out);

/* Writes the combined digest of everything fed to `handle` so far. Does
 * NOT free or reset the handle -- more files may be added after this and
 * finalize called again. Returns 0 on success. */
int romm_hash_accum_finalize(void *handle,
                              char *crc_out,
                              char *md5_out,
                              char *sha1_out);

/* Frees a handle created by romm_hash_accum_new. NULL-safe (no-op on NULL). */
void romm_hash_accum_free(void *handle);

/* ══════════════════════════════════════════════════════════════════════════
 * Hook: "archive_list" — list a ZIP archive's members without decompressing
 * their contents (reads the central directory only: name, sizes, the CRC32
 * ZIP already stores per-entry). Useful for a fast archive
 * presence/integrity check before committing to a full extraction.
 *
 * hook name in plugin.json: "archive_list"
 * default entry_symbols:    "romm_archive_open" / "_entry_count" / "_entry_at" / "_close"
 * ══════════════════════════════════════════════════════════════════════════ */

#define ROMM_ARCHIVE_NAME_MAX 260  /* matches common ZIP filename length conventions */

typedef struct {
    char name[ROMM_ARCHIVE_NAME_MAX];
    unsigned long long compressed_size;
    unsigned long long uncompressed_size;
    unsigned int crc32;   /* as stored in the ZIP central directory */
} romm_archive_entry;

/* Opens `path` and parses its ZIP central directory. Returns an opaque
 * handle, or NULL if the file doesn't exist, isn't a ZIP, or is corrupt. */
void *romm_archive_open(const char *path);

/* Number of entries found, or -1 if `handle` is invalid. */
int romm_archive_entry_count(void *handle);

/* Fills `out` with the entry at `index` (0-based). Returns 0 on success,
 * nonzero if `index` is out of range or `handle`/`out` is invalid. */
int romm_archive_entry_at(void *handle, int index, romm_archive_entry *out);

/* Frees a handle created by romm_archive_open. NULL-safe (no-op on NULL). */
void romm_archive_close(void *handle);

#ifdef __cplusplus
}
#endif

#endif /* ROMM_PLUGIN_ABI_H */
