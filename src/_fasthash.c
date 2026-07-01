/*
 * _fasthash.c – Python C extension for fast ROM file hashing.
 *
 * Computes CRC32 + MD5 + SHA1 in a single 256 KB-buffered pass through a
 * file, releasing the GIL for the entire I/O + computation loop.  This lets
 * multiple worker threads hash different ROMs simultaneously.
 *
 * Public API
 * ----------
 * hash_file(path: str) -> tuple[str, str, str]
 *     Hash a plain file.  Returns (crc32_hex, md5_hex, sha1_hex) where each
 *     string is empty when the file has zero bytes.
 *
 * hash_buffer(data: bytes) -> tuple[str, str, str]
 *     Hash a bytes buffer (e.g. archive-extracted ROM data).
 *
 * class MultiFileHasher
 *     Maintains running CRC32/MD5/SHA1 accumulators across multiple files so
 *     that multi-part ROMs get a single combined hash.
 *
 *     .hash_file(path: str)       -> (crc32_hex, md5_hex, sha1_hex)  per-file
 *     .update_buffer(data: bytes) -> (crc32_hex, md5_hex, sha1_hex)  per-buffer
 *     .finalize()                 -> (crc32_hex, md5_hex, sha1_hex)  combined
 *
 * Thread safety
 * -------------
 * hash_file() and hash_buffer() touch no state beyond their own arguments and
 * a stack-local accumulator, so concurrent calls from different threads (the
 * intended usage -- one call per SCAN_WORKERS thread) never share memory and
 * are safe with no locking.
 *
 * A single MultiFileHasher instance's accumulated state is protected by a
 * per-instance lock, so calling hash_file()/update_buffer()/finalize() on
 * the *same* instance from multiple threads at once is safe (calls
 * serialize) rather than racing. Different instances remain fully
 * independent and never contend with each other or with hash_file()/
 * hash_buffer().
 *
 * Build
 * -----
 *   python setup_fasthash.py build_ext --inplace
 *
 * Requires: libssl-dev (or openssl-dev on Alpine), zlib-dev
 */

#define PY_SSIZE_T_CLEAN
#include <Python.h>

#include <openssl/evp.h>
#include <zlib.h>

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BUF_SIZE (256 * 1024)   /* 256 KB per fread call */

static const EVP_MD *g_md5_type  = NULL;
static const EVP_MD *g_sha1_type = NULL;


/* ══════════════════════════════════════════════════════════════════════════════
 * HashState – running CRC32 + OpenSSL MD5 + SHA1 contexts
 * ══════════════════════════════════════════════════════════════════════════════ */

typedef struct {
    uint32_t    crc;
    EVP_MD_CTX *md5_ctx;
    EVP_MD_CTX *sha1_ctx;
    int         empty;   /* 1 if no bytes fed yet */
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

static inline void hs_update(HashState *hs, const uint8_t *data, size_t n)
{
    if (!n) return;
    hs->crc = crc32(hs->crc, data, (uInt)n);
    EVP_DigestUpdate(hs->md5_ctx,  data, n);
    EVP_DigestUpdate(hs->sha1_ctx, data, n);
    hs->empty = 0;
}

/* Non-destructive finalize: copies the live contexts before calling Final.
 * Returns 1 on success.  Callers must ensure the HashState stays alive
 * after this call (so further hs_update calls still work). */
static int hs_hexdigest(const HashState *hs,
                        char out_crc [9],
                        char out_md5 [33],
                        char out_sha1[41])
{
    if (hs->empty) {
        out_crc[0] = out_md5[0] = out_sha1[0] = '\0';
        return 1;
    }

    snprintf(out_crc, 9, "%08x", (unsigned)hs->crc);

    EVP_MD_CTX *tmp_md5  = EVP_MD_CTX_new();
    EVP_MD_CTX *tmp_sha1 = EVP_MD_CTX_new();
    if (!tmp_md5 || !tmp_sha1) {
        EVP_MD_CTX_free(tmp_md5);
        EVP_MD_CTX_free(tmp_sha1);
        return 0;
    }

    /* EVP_MD_CTX_copy can fail (allocation failure, digest implementation
     * that doesn't support duplication, ...). Proceeding to Final on a
     * context that failed to copy leaves its internal digest state
     * unbound/partial, and EVP_DigestFinal_ex then dereferences that state
     * -- a segfault, not a clean error. Bail out via the normal failure
     * path (-> Python RuntimeError) instead. */
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
    for (int i = 0; i < 16; i++) sprintf(out_md5  + i * 2, "%02x", digest[i]);
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

/* Build a Python (crc_hex, md5_hex, sha1_hex) tuple from a HashState. */
static PyObject *hs_to_tuple(const HashState *hs)
{
    char crc[9], md5[33], sha1[41];
    if (!hs_hexdigest(hs, crc, md5, sha1)) {
        PyErr_SetString(PyExc_RuntimeError, "OpenSSL context copy/finalize failed");
        return NULL;
    }
    return Py_BuildValue("(sss)", crc, md5, sha1);
}


/* ══════════════════════════════════════════════════════════════════════════════
 * Internal no-GIL file reader used by hash_file and MultiFileHasher.hash_file
 * ══════════════════════════════════════════════════════════════════════════════ */

typedef struct {
    const char *path;
    HashState  *hs_file;   /* per-file state  (always updated)        */
    HashState  *hs_accum;  /* accumulated state (updated when non-NULL) */
    uint8_t    *buf;
    int         ok;
    int         saved_errno;
} ReadArgs;

static void read_and_hash(ReadArgs *a)
{
    FILE *fp = fopen(a->path, "rb");
    if (!fp) { a->ok = 0; a->saved_errno = errno; return; }

    size_t n;
    while ((n = fread(a->buf, 1, BUF_SIZE, fp)) > 0) {
        hs_update(a->hs_file, a->buf, n);
        if (a->hs_accum)
            hs_update(a->hs_accum, a->buf, n);
    }
    if (ferror(fp)) { a->ok = 0; a->saved_errno = EIO; } else { a->ok = 1; }
    fclose(fp);
}


/* ══════════════════════════════════════════════════════════════════════════════
 * hash_file(path: str) -> (crc_hex, md5_hex, sha1_hex)
 * ══════════════════════════════════════════════════════════════════════════════ */

static PyObject *py_hash_file(PyObject *self, PyObject *args)
{
    const char *path;
    if (!PyArg_ParseTuple(args, "s", &path)) return NULL;

    uint8_t *buf = malloc(BUF_SIZE);
    if (!buf) return PyErr_NoMemory();

    HashState hs;
    if (!hs_init(&hs)) {
        free(buf);
        PyErr_SetString(PyExc_RuntimeError, "hash_file: context init failed");
        return NULL;
    }

    ReadArgs a = { path, &hs, NULL, buf, 1, 0 };

    Py_BEGIN_ALLOW_THREADS
    read_and_hash(&a);
    Py_END_ALLOW_THREADS

    free(buf);

    if (!a.ok) {
        hs_free(&hs);
        errno = a.saved_errno;
        return PyErr_SetFromErrnoWithFilenameObject(
            PyExc_OSError, PyUnicode_FromString(path));
    }

    PyObject *r = hs_to_tuple(&hs);
    hs_free(&hs);
    return r;
}


/* ══════════════════════════════════════════════════════════════════════════════
 * hash_buffer(data: bytes) -> (crc_hex, md5_hex, sha1_hex)
 * ══════════════════════════════════════════════════════════════════════════════ */

static PyObject *py_hash_buffer(PyObject *self, PyObject *args)
{
    Py_buffer view;
    if (!PyArg_ParseTuple(args, "y*", &view)) return NULL;

    HashState hs;
    if (!hs_init(&hs)) {
        PyBuffer_Release(&view);
        PyErr_SetString(PyExc_RuntimeError, "hash_buffer: context init failed");
        return NULL;
    }

    const uint8_t *data = (const uint8_t *)view.buf;
    Py_ssize_t     len  = view.len;

    Py_BEGIN_ALLOW_THREADS
    for (Py_ssize_t off = 0; off < len; ) {
        size_t chunk = (size_t)(len - off);
        if (chunk > BUF_SIZE) chunk = BUF_SIZE;
        hs_update(&hs, data + off, chunk);
        off += (Py_ssize_t)chunk;
    }
    Py_END_ALLOW_THREADS

    PyBuffer_Release(&view);
    PyObject *r = hs_to_tuple(&hs);
    hs_free(&hs);
    return r;
}


/* ══════════════════════════════════════════════════════════════════════════════
 * MultiFileHasher – Python type
 * ══════════════════════════════════════════════════════════════════════════════ */

/* `accum` is mutable state shared by every method call on a given instance.
 * hash_file()/update_buffer() mutate it (crc, EVP_MD_CTX buffers) with the
 * GIL released, and finalize() reads it via EVP_MD_CTX_copy. Two threads
 * calling methods on the *same instance* concurrently -- e.g. two
 * asyncio.to_thread() calls sharing one hasher, or hash_file() racing
 * finalize() -- would race on `accum` with the GIL providing no protection
 * (it's released for exactly the work that touches accum). `lock` makes
 * that safe by serializing accum access per-instance: callers block instead
 * of corrupting state, while unrelated instances and the plain module-level
 * hash_file()/hash_buffer() (which never touch a shared HashState) are
 * unaffected and keep running fully in parallel. Confirmed via ThreadSanitizer
 * that concurrent hash_file() calls on one instance raced on this field
 * before this lock was added, and that the module-level functions do not. */
typedef struct {
    PyObject_HEAD
    HashState accum;
    PyThread_type_lock lock;
} MultiFileHasher;

static int MFH_tp_init(MultiFileHasher *self, PyObject *args, PyObject *kw)
{
    if (!hs_init(&self->accum)) {
        PyErr_SetString(PyExc_RuntimeError, "MultiFileHasher: context init failed");
        return -1;
    }
    self->lock = PyThread_allocate_lock();
    if (!self->lock) {
        hs_free(&self->accum);
        PyErr_SetString(PyExc_RuntimeError, "MultiFileHasher: lock allocation failed");
        return -1;
    }
    return 0;
}

static void MFH_tp_dealloc(MultiFileHasher *self)
{
    hs_free(&self->accum);
    if (self->lock) PyThread_free_lock(self->lock);
    Py_TYPE(self)->tp_free((PyObject *)self);
}

/* hash_file(path: str) -> (crc_hex, md5_hex, sha1_hex)
 * Hashes the named file and folds its bytes into the accumulated state. */
static PyObject *MFH_hash_file(MultiFileHasher *self, PyObject *args)
{
    const char *path;
    if (!PyArg_ParseTuple(args, "s", &path)) return NULL;

    uint8_t *buf = malloc(BUF_SIZE);
    if (!buf) return PyErr_NoMemory();

    HashState hs_file;
    if (!hs_init(&hs_file)) {
        free(buf);
        PyErr_SetString(PyExc_RuntimeError, "MultiFileHasher.hash_file: init failed");
        return NULL;
    }

    ReadArgs a = { path, &hs_file, &self->accum, buf, 1, 0 };

    /* hs_file is private to this call -- only accum needs the lock. But
     * read_and_hash updates both from the same fread loop, and the file
     * read itself dominates the cost anyway, so we hold the lock for the
     * whole no-GIL section rather than split it per-chunk. The lock is
     * acquired *after* releasing the GIL and released *before* reacquiring
     * it, so a thread blocked here never holds the GIL while waiting --
     * it can't stall unrelated Python threads or deadlock against a
     * concurrent finalize() (see MFH_finalize). */
    Py_BEGIN_ALLOW_THREADS
    PyThread_acquire_lock(self->lock, WAIT_LOCK);
    read_and_hash(&a);
    PyThread_release_lock(self->lock);
    Py_END_ALLOW_THREADS

    free(buf);

    if (!a.ok) {
        hs_free(&hs_file);
        errno = a.saved_errno;
        return PyErr_SetFromErrnoWithFilenameObject(
            PyExc_OSError, PyUnicode_FromString(path));
    }

    PyObject *r = hs_to_tuple(&hs_file);
    hs_free(&hs_file);
    return r;
}

/* update_buffer(data: bytes) -> (crc_hex, md5_hex, sha1_hex)
 * Hashes a bytes object and folds it into the accumulated state. */
static PyObject *MFH_update_buffer(MultiFileHasher *self, PyObject *args)
{
    Py_buffer view;
    if (!PyArg_ParseTuple(args, "y*", &view)) return NULL;

    HashState hs_file;
    if (!hs_init(&hs_file)) {
        PyBuffer_Release(&view);
        PyErr_SetString(PyExc_RuntimeError, "MultiFileHasher.update_buffer: init failed");
        return NULL;
    }

    const uint8_t *data = (const uint8_t *)view.buf;
    Py_ssize_t     len  = view.len;

    Py_BEGIN_ALLOW_THREADS
    PyThread_acquire_lock(self->lock, WAIT_LOCK);
    for (Py_ssize_t off = 0; off < len; ) {
        size_t chunk = (size_t)(len - off);
        if (chunk > BUF_SIZE) chunk = BUF_SIZE;
        hs_update(&hs_file,     data + off, chunk);
        hs_update(&self->accum, data + off, chunk);
        off += (Py_ssize_t)chunk;
    }
    PyThread_release_lock(self->lock);
    Py_END_ALLOW_THREADS

    PyBuffer_Release(&view);
    PyObject *r = hs_to_tuple(&hs_file);
    hs_free(&hs_file);
    return r;
}

/* finalize() -> (crc_hex, md5_hex, sha1_hex)
 * Returns the combined hash of all files/buffers passed so far.
 * Takes the same per-instance lock as hash_file()/update_buffer() before
 * reading accum, so a finalize() that lands mid-update on another thread
 * blocks for that update instead of copying inconsistent digest state. */
static PyObject *MFH_finalize(MultiFileHasher *self, PyObject *_unused)
{
    Py_BEGIN_ALLOW_THREADS
    PyThread_acquire_lock(self->lock, WAIT_LOCK);
    Py_END_ALLOW_THREADS

    PyObject *r = hs_to_tuple(&self->accum);

    PyThread_release_lock(self->lock);
    return r;
}

static PyMethodDef MFH_methods[] = {
    {"hash_file",     (PyCFunction)MFH_hash_file,     METH_VARARGS, "Hash a file and update accumulated state"},
    {"update_buffer", (PyCFunction)MFH_update_buffer, METH_VARARGS, "Hash bytes and update accumulated state"},
    {"finalize",      (PyCFunction)MFH_finalize,      METH_NOARGS,  "Return combined hash of all input so far"},
    {NULL, NULL, 0, NULL},
};

static PyTypeObject MultiFileHasher_Type = {
    PyVarObject_HEAD_INIT(NULL, 0)
    .tp_name      = "_fasthash.MultiFileHasher",
    .tp_basicsize = sizeof(MultiFileHasher),
    .tp_dealloc   = (destructor)MFH_tp_dealloc,
    .tp_flags     = Py_TPFLAGS_DEFAULT,
    .tp_doc       = "Accumulate CRC32/MD5/SHA1 across multiple files or buffers",
    .tp_methods   = MFH_methods,
    .tp_init      = (initproc)MFH_tp_init,
    .tp_new       = PyType_GenericNew,
};


/* ══════════════════════════════════════════════════════════════════════════════
 * Module definition
 * ══════════════════════════════════════════════════════════════════════════════ */

static PyMethodDef module_methods[] = {
    {"hash_file",   py_hash_file,   METH_VARARGS, "hash_file(path) -> (crc_hex, md5_hex, sha1_hex)"},
    {"hash_buffer", py_hash_buffer, METH_VARARGS, "hash_buffer(data) -> (crc_hex, md5_hex, sha1_hex)"},
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef module_def = {
    PyModuleDef_HEAD_INIT,
    "_fasthash",
    "Fast CRC32/MD5/SHA1 hashing for ROM files (GIL released during I/O)",
    -1,
    module_methods,
};

PyMODINIT_FUNC PyInit__fasthash(void)
{
    g_md5_type  = EVP_md5();
    g_sha1_type = EVP_sha1();
    if (!g_md5_type || !g_sha1_type) {
        PyErr_SetString(PyExc_RuntimeError,
                        "_fasthash: OpenSSL MD5/SHA1 algorithm unavailable");
        return NULL;
    }

    if (PyType_Ready(&MultiFileHasher_Type) < 0)
        return NULL;

    PyObject *m = PyModule_Create(&module_def);
    if (!m) return NULL;

    Py_INCREF(&MultiFileHasher_Type);
    if (PyModule_AddObject(m, "MultiFileHasher",
                           (PyObject *)&MultiFileHasher_Type) < 0) {
        Py_DECREF(&MultiFileHasher_Type);
        Py_DECREF(m);
        return NULL;
    }
    return m;
}
