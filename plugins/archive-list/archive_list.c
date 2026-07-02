/*
 * archive_list.c — romm-fast-scan native plugin implementing the
 * "archive_list" hook from romm_plugin_abi.h.
 *
 * Reads a ZIP archive's central directory (member names, sizes, and the
 * CRC32 the ZIP format already stores per entry) without decompressing any
 * member's contents. Useful as a fast presence/corruption check on an
 * archive before committing to a full extraction+hash pass.
 *
 * Scope: standard (non-ZIP64) ZIP archives only. A ZIP64 file (needed once
 * an archive exceeds ~4 GB or 65535 entries) is detected and rejected
 * cleanly (romm_archive_open returns NULL) rather than parsed incorrectly --
 * same fail-closed-at-the-boundary contract as every other hook: a format
 * this plugin doesn't understand falls back to the existing Python archive
 * handling, it never returns wrong data.
 *
 * No external compression library needed: the central directory is plain,
 * uncompressed binary metadata, regardless of how the *members* themselves
 * are compressed.
 *
 * Build: g++ -shared -fPIC -O2 -o libarchive_list.so archive_list.c
 * (no -l flags needed -- no dependency beyond libc)
 */

#include "../../include/romm_plugin_abi.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define EOCD_SIG 0x06054b50u
#define CDFH_SIG 0x02014b50u
#define EOCD_MIN_SIZE 22
#define EOCD_MAX_COMMENT 65535
#define CDFH_FIXED_SIZE 46

typedef struct {
    romm_archive_entry *entries;
    int count;
} ArchiveHandle;

static uint32_t read_u32le(const unsigned char *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint16_t read_u16le(const unsigned char *p)
{
    return (uint16_t)(p[0] | (p[1] << 8));
}

/* Search the tail of the file for the EOCD signature. ZIP allows a variable-
 * length comment after the EOCD record, up to 65535 bytes, so the record
 * isn't necessarily the last 22 bytes -- scan backward through the maximum
 * possible comment length. Returns the EOCD's absolute file offset, or -1
 * if not found (not a ZIP, truncated, or corrupt). */
static long find_eocd(FILE *fp, long file_size)
{
    long scan_size = file_size < (EOCD_MIN_SIZE + EOCD_MAX_COMMENT)
                          ? file_size
                          : (EOCD_MIN_SIZE + EOCD_MAX_COMMENT);
    if (scan_size < EOCD_MIN_SIZE) return -1;

    unsigned char *buf = (unsigned char *)malloc((size_t)scan_size);
    if (!buf) return -1;

    if (fseek(fp, file_size - scan_size, SEEK_SET) != 0) { free(buf); return -1; }
    if (fread(buf, 1, (size_t)scan_size, fp) != (size_t)scan_size) { free(buf); return -1; }

    long found = -1;
    for (long i = scan_size - EOCD_MIN_SIZE; i >= 0; i--) {
        if (read_u32le(buf + i) == EOCD_SIG) {
            found = (file_size - scan_size) + i;
            break;
        }
    }
    free(buf);
    return found;
}

void *romm_archive_open(const char *path)
{
    FILE *fp = fopen(path, "rb");
    if (!fp) return NULL;

    if (fseek(fp, 0, SEEK_END) != 0) { fclose(fp); return NULL; }
    long file_size = ftell(fp);
    if (file_size < EOCD_MIN_SIZE) { fclose(fp); return NULL; }

    long eocd_off = find_eocd(fp, file_size);
    if (eocd_off < 0) { fclose(fp); return NULL; }

    unsigned char eocd[EOCD_MIN_SIZE];
    if (fseek(fp, eocd_off, SEEK_SET) != 0 ||
        fread(eocd, 1, EOCD_MIN_SIZE, fp) != EOCD_MIN_SIZE) {
        fclose(fp);
        return NULL;
    }

    uint16_t num_entries = read_u16le(eocd + 10);
    uint32_t cd_size     = read_u32le(eocd + 12);
    uint32_t cd_offset   = read_u32le(eocd + 16);

    /* ZIP64 marker: these fields are 0xFFFF/0xFFFFFFFF when the real values
     * live in a ZIP64 end-of-central-directory record this parser doesn't
     * read. Reject rather than misparse. */
    if (num_entries == 0xFFFF || cd_size == 0xFFFFFFFFu || cd_offset == 0xFFFFFFFFu) {
        fclose(fp);
        return NULL;
    }

    romm_archive_entry *entries = NULL;
    if (num_entries > 0) {
        entries = (romm_archive_entry *)calloc(num_entries, sizeof(romm_archive_entry));
        if (!entries) { fclose(fp); return NULL; }
    }

    if (fseek(fp, (long)cd_offset, SEEK_SET) != 0) {
        free(entries);
        fclose(fp);
        return NULL;
    }

    int parsed = 0;
    for (uint16_t i = 0; i < num_entries; i++) {
        unsigned char hdr[CDFH_FIXED_SIZE];
        if (fread(hdr, 1, CDFH_FIXED_SIZE, fp) != CDFH_FIXED_SIZE) break;
        if (read_u32le(hdr) != CDFH_SIG) break;

        uint32_t crc32            = read_u32le(hdr + 16);
        uint32_t compressed_size  = read_u32le(hdr + 20);
        uint32_t uncompressed_size = read_u32le(hdr + 24);
        uint16_t name_len   = read_u16le(hdr + 28);
        uint16_t extra_len  = read_u16le(hdr + 30);
        uint16_t comment_len = read_u16le(hdr + 32);

        romm_archive_entry *e = &entries[parsed];
        memset(e, 0, sizeof(*e));
        e->crc32 = crc32;
        e->compressed_size = compressed_size;
        e->uncompressed_size = uncompressed_size;

        size_t copy_len = name_len < (ROMM_ARCHIVE_NAME_MAX - 1) ? name_len : (ROMM_ARCHIVE_NAME_MAX - 1);
        if (name_len > 0) {
            if (fread(e->name, 1, copy_len, fp) != copy_len) break;
            e->name[copy_len] = '\0';
            if (copy_len < name_len) {
                /* Name longer than our buffer: skip the remainder so the
                 * stream stays aligned for the next header. Truncated but
                 * present -- not a parse failure. */
                if (fseek(fp, (long)(name_len - copy_len), SEEK_CUR) != 0) break;
            }
        } else {
            e->name[0] = '\0';
        }

        if (fseek(fp, (long)extra_len + (long)comment_len, SEEK_CUR) != 0) break;

        parsed++;
    }

    fclose(fp);

    if (parsed != num_entries) {
        /* Central directory was shorter/corrupt relative to what EOCD
         * claimed -- fail closed rather than report a partial listing. */
        free(entries);
        return NULL;
    }

    ArchiveHandle *h = (ArchiveHandle *)malloc(sizeof(ArchiveHandle));
    if (!h) { free(entries); return NULL; }
    h->entries = entries;
    h->count = parsed;
    return h;
}

int romm_archive_entry_count(void *handle)
{
    if (!handle) return -1;
    return ((ArchiveHandle *)handle)->count;
}

int romm_archive_entry_at(void *handle, int index, romm_archive_entry *out)
{
    if (!handle || !out) return 1;
    ArchiveHandle *h = (ArchiveHandle *)handle;
    if (index < 0 || index >= h->count) return 1;
    *out = h->entries[index];
    return 0;
}

void romm_archive_close(void *handle)
{
    if (!handle) return;
    ArchiveHandle *h = (ArchiveHandle *)handle;
    free(h->entries);
    free(h);
}

int romm_plugin_abi_version(void)
{
    return ROMM_PLUGIN_ABI_VERSION;
}
