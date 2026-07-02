/*
 * fasthash.c — romm-fast-scan native plugin implementing the "hash_file"
 * and "hash_file_accum" hooks from romm_plugin_abi.h.
 *
 * This is a straight port of the CPython-extension version of this code
 * (src/_fasthash.c) onto the plain C ABI: same HashState/CRC32/OpenSSL core,
 * same non-destructive-finalize trick, same per-handle locking strategy for
 * the multi-file accumulator (see the comment above AccumHandle) -- ported
 * from Python's GIL-aware PyThread_type_lock to a plain pthread_mutex_t,
 * since there's no interpreter here to coordinate with anymore. The lock
 * itself was verified race-free under ThreadSanitizer in the CPython
 * version; the locking *pattern* (acquire only for the duration of the
 * accum-touching work, one lock per handle, never held across an I/O wait
 * on a fresh handle) carries over unchanged.
 *
 * No Python.h. No CPython ABI coupling -- this .so is buildable and loadable
 * against any RomM version, independent of RomM's own Python minor version.
 *
 * Build: g++ -shared -fPIC -O2 -o libfasthash.so fasthash.c -lssl -lcrypto -lz -lpthread
 * (plain gcc works too; .c is valid as either C or C++ here)
 */

#include "../../include/romm_plugin_abi.h"

#include <openssl/evp.h>
#include <zlib.h>
#include <pthread.h>

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BUF_SIZE (256 * 1024)   /* 256 KB per fread call -- see docs/ARCHITECTURE.md */

static const EVP_MD *g_md5_type  = NULL;
static const EVP_MD *g_sha1_type = NULL;
static int g_openssl_ready = 0;

/* ══════════════════════════════════════════════════════════════════════════
 * HashState — running CRC32 + OpenSSL MD5 + SHA1 contexts.
 * Identical logic to src/_fasthash.c's HashState; no Python types touched.
 * ══════════════════════════════════════════════════════════════════════════ */

typedef struct {
    uint32_t    crc;
    EVP_MD_CTX *md5_ctx;
    EVP_MD_CTX *sha1_ctx;
    int         empty;
} HashState;

static int hs_init(HashState *hs)
{
    hs->crc   = 0;
    hs->empty = 1;
    hs->md5_ctx  = EVP_MD_CTX_new();
    hs->sha1_ctx = EVP_MD_CTX_new();
    if (!hs->md5_ctx || !hs->sha1_ctx)                       goto err;
    if (!EVP_DigestInit_ex(hs->md5_ctx,  g_md5_type,  NULL)) goto err;
    if (!EVP_DigestInit_ex(hs->sha1_ctx, g_sha1_type, NULL)) goto err;
    return 1;
err:
    EVP_MD_CTX_free(hs->md5_ctx);
    EVP_MD_CTX_free(hs->sha1_ctx);
    hs->md5_ctx = hs->sha1_ctx = NULL;
    return 0;
}

static void hs_free(HashState *hs)
{
    EVP_MD_CTX_free(hs->md5_ctx);
    EVP_MD_CTX_free(hs->sha1_ctx);
    hs->md5_ctx = hs->sha1_ctx = NULL;
}

static void hs_update(HashState *hs, const uint8_t *data, size_t n)
{
    if (!n) return;
    hs->crc = crc32(hs->crc, data, (uInt)n);
    EVP_DigestUpdate(hs->md5_ctx,  data, n);
    EVP_DigestUpdate(hs->sha1_ctx, data, n);
    hs->empty = 0;
}

/* Non-destructive finalize via EVP_MD_CTX_copy onto temp contexts, so the
 * live context can keep accumulating after this call. Every EVP call here
 * is return-checked before use -- an unchecked EVP_MD_CTX_copy/DigestFinal_ex
 * failure was a real, ThreadSanitizer/logic-review-confirmed segfault risk
 * in the CPython version of this file; same fix, ported verbatim. */
static int hs_hexdigest(const HashState *hs, char *out_crc, char *out_md5, char *out_sha1)
{
    if (hs->empty) {
        out_crc[0] = out_md5[0] = out_sha1[0] = '\0';
        return 1;
    }

    snprintf(out_crc, ROMM_CRC32_HEX_LEN, "%08x", (unsigned)hs->crc);

    EVP_MD_CTX *tmp_md5  = EVP_MD_CTX_new();
    EVP_MD_CTX *tmp_sha1 = EVP_MD_CTX_new();
    if (!tmp_md5 || !tmp_sha1) {
        EVP_MD_CTX_free(tmp_md5);
        EVP_MD_CTX_free(tmp_sha1);
        return 0;
    }

    if (!EVP_MD_CTX_copy(tmp_md5, hs->md5_ctx) ||
        !EVP_MD_CTX_copy(tmp_sha1, hs->sha1_ctx)) {
        EVP_MD_CTX_free(tmp_md5);
        EVP_MD_CTX_free(tmp_sha1);
        return 0;
    }

    uint8_t  digest[20];
    unsigned dlen;

    if (!EVP_DigestFinal_ex(tmp_md5, digest, &dlen)) {
        EVP_MD_CTX_free(tmp_md5);
        EVP_MD_CTX_free(tmp_sha1);
        return 0;
    }
    for (int i = 0; i < 16; i++) sprintf(out_md5 + i * 2, "%02x", digest[i]);
    out_md5[32] = '\0';

    if (!EVP_DigestFinal_ex(tmp_sha1, digest, &dlen)) {
        EVP_MD_CTX_free(tmp_md5);
        EVP_MD_CTX_free(tmp_sha1);
        return 0;
    }
    for (int i = 0; i < 20; i++) sprintf(out_sha1 + i * 2, "%02x", digest[i]);
    out_sha1[40] = '\0';

    EVP_MD_CTX_free(tmp_md5);
    EVP_MD_CTX_free(tmp_sha1);
    return 1;
}

static int ensure_openssl(void)
{
    if (g_openssl_ready) return 1;
    g_md5_type  = EVP_md5();
    g_sha1_type = EVP_sha1();
    if (!g_md5_type || !g_sha1_type) return 0;
    g_openssl_ready = 1;
    return 1;
}

/* ══════════════════════════════════════════════════════════════════════════
 * File reading (no GIL to release here -- that was only ever a concern for
 * the CPython-extension version; a plain .so has no interpreter lock at
 * all, threading is entirely the caller's business).
 * ══════════════════════════════════════════════════════════════════════════ */

static int read_and_hash(const char *path, HashState *hs_file, HashState *hs_accum)
{
    uint8_t *buf = (uint8_t *)malloc(BUF_SIZE);
    if (!buf) return 0;

    FILE *fp = fopen(path, "rb");
    if (!fp) { free(buf); return 0; }

    size_t n;
    int ok = 1;
    while ((n = fread(buf, 1, BUF_SIZE, fp)) > 0) {
        hs_update(hs_file, buf, n);
        if (hs_accum) hs_update(hs_accum, buf, n);
    }
    if (ferror(fp)) ok = 0;

    fclose(fp);
    free(buf);
    return ok;
}

/* ══════════════════════════════════════════════════════════════════════════
 * ABI: required export
 * ══════════════════════════════════════════════════════════════════════════ */

int romm_plugin_abi_version(void)
{
    return ROMM_PLUGIN_ABI_VERSION;
}

/* ══════════════════════════════════════════════════════════════════════════
 * ABI: hash_file
 * ══════════════════════════════════════════════════════════════════════════ */

int romm_hash_file(const char *path, char *crc_out, char *md5_out, char *sha1_out)
{
    if (!ensure_openssl()) return 1;

    HashState hs;
    if (!hs_init(&hs)) return 1;

    int ok = read_and_hash(path, &hs, NULL);
    if (!ok) { hs_free(&hs); return 1; }

    int digest_ok = hs_hexdigest(&hs, crc_out, md5_out, sha1_out);
    hs_free(&hs);
    return digest_ok ? 0 : 1;
}

/* ══════════════════════════════════════════════════════════════════════════
 * ABI: hash_file_accum (multi-file accumulator)
 *
 * AccumHandle.lock protects `accum` the same way MultiFileHasher's
 * PyThread_type_lock did in the CPython version: two threads calling
 * romm_hash_accum_file()/_finalize() on the *same handle* concurrently
 * serialize instead of racing on the shared HashState. Different handles
 * remain fully independent. See CLAUDE.md's note on this pattern if you
 * touch it -- it was a real, TSan-confirmed data race before the lock
 * existed in the CPython version this was ported from.
 * ══════════════════════════════════════════════════════════════════════════ */

typedef struct {
    HashState accum;
    pthread_mutex_t lock;
} AccumHandle;

void *romm_hash_accum_new(void)
{
    if (!ensure_openssl()) return NULL;

    AccumHandle *h = (AccumHandle *)malloc(sizeof(AccumHandle));
    if (!h) return NULL;

    if (!hs_init(&h->accum)) { free(h); return NULL; }
    if (pthread_mutex_init(&h->lock, NULL) != 0) {
        hs_free(&h->accum);
        free(h);
        return NULL;
    }
    return h;
}

int romm_hash_accum_file(void *handle, const char *path,
                          char *per_file_crc_out,
                          char *per_file_md5_out,
                          char *per_file_sha1_out)
{
    if (!handle) return 1;
    AccumHandle *h = (AccumHandle *)handle;

    HashState hs_file;
    if (!hs_init(&hs_file)) return 1;

    pthread_mutex_lock(&h->lock);
    int ok = read_and_hash(path, &hs_file, &h->accum);
    pthread_mutex_unlock(&h->lock);

    if (!ok) { hs_free(&hs_file); return 1; }

    /* Per-file digest requested? Any of the three out pointers may be NULL
     * independently if the caller only wants the running accumulation. */
    if (per_file_crc_out || per_file_md5_out || per_file_sha1_out) {
        char crc[ROMM_CRC32_HEX_LEN], md5[ROMM_MD5_HEX_LEN], sha1[ROMM_SHA1_HEX_LEN];
        if (!hs_hexdigest(&hs_file, crc, md5, sha1)) { hs_free(&hs_file); return 1; }
        if (per_file_crc_out)  memcpy(per_file_crc_out,  crc,  ROMM_CRC32_HEX_LEN);
        if (per_file_md5_out)  memcpy(per_file_md5_out,  md5,  ROMM_MD5_HEX_LEN);
        if (per_file_sha1_out) memcpy(per_file_sha1_out, sha1, ROMM_SHA1_HEX_LEN);
    }

    hs_free(&hs_file);
    return 0;
}

int romm_hash_accum_finalize(void *handle, char *crc_out, char *md5_out, char *sha1_out)
{
    if (!handle) return 1;
    AccumHandle *h = (AccumHandle *)handle;

    pthread_mutex_lock(&h->lock);
    int ok = hs_hexdigest(&h->accum, crc_out, md5_out, sha1_out);
    pthread_mutex_unlock(&h->lock);

    return ok ? 0 : 1;
}

void romm_hash_accum_free(void *handle)
{
    if (!handle) return;
    AccumHandle *h = (AccumHandle *)handle;
    hs_free(&h->accum);
    pthread_mutex_destroy(&h->lock);
    free(h);
}
