#include "CZlib.h"

#include <stdlib.h>
#include <zlib.h>

int dragon_deflate_init(void **stream, int level) {
    z_stream *strm = calloc(1, sizeof(z_stream));
    if (!strm) {
        return Z_MEM_ERROR;
    }
    int rc = deflateInit2_(strm, level, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY,
                           ZLIB_VERSION, (int)sizeof(z_stream));
    if (rc != Z_OK) {
        free(strm);
        return rc;
    }
    *stream = strm;
    return Z_OK;
}

int dragon_deflate_process(void *stream, const uint8_t *in, size_t in_len,
                           size_t *consumed, uint8_t *out, size_t out_cap,
                           size_t *produced, int finish) {
    z_stream *strm = stream;
    if (in_len > 0xFFFFFFFFU || out_cap > 0xFFFFFFFFU) {
        return Z_BUF_ERROR;
    }
    strm->next_in = (Bytef *)in;
    strm->avail_in = (uInt)in_len;
    strm->next_out = out;
    strm->avail_out = (uInt)out_cap;
    int rc = deflate(strm, finish ? Z_FINISH : Z_NO_FLUSH);
    *consumed = in_len - strm->avail_in;
    *produced = out_cap - strm->avail_out;
    return rc;
}

void dragon_deflate_end(void *stream) {
    if (!stream) {
        return;
    }
    deflateEnd(stream);
    free(stream);
}

int dragon_inflate_init(void **stream) {
    z_stream *strm = calloc(1, sizeof(z_stream));
    if (!strm) {
        return Z_MEM_ERROR;
    }
    int rc = inflateInit2_(strm, -15, ZLIB_VERSION, (int)sizeof(z_stream));
    if (rc != Z_OK) {
        free(strm);
        return rc;
    }
    *stream = strm;
    return Z_OK;
}

int dragon_inflate_process(void *stream, const uint8_t *in, size_t in_len,
                           size_t *consumed, uint8_t *out, size_t out_cap,
                           size_t *produced, int *ended) {
    z_stream *strm = stream;
    if (in_len > 0xFFFFFFFFU || out_cap > 0xFFFFFFFFU) {
        return Z_BUF_ERROR;
    }
    strm->next_in = (Bytef *)in;
    strm->avail_in = (uInt)in_len;
    strm->next_out = out;
    strm->avail_out = (uInt)out_cap;
    int rc = inflate(strm, Z_NO_FLUSH);
    *consumed = in_len - strm->avail_in;
    *produced = out_cap - strm->avail_out;
    *ended = rc == Z_STREAM_END;
    return rc;
}

void dragon_inflate_end(void *stream) {
    if (!stream) {
        return;
    }
    inflateEnd(stream);
    free(stream);
}

uint32_t dragon_crc32(uint32_t crc, const uint8_t *buf, size_t len) {
    uLong value = crc;
    while (len > 0) {
        uInt chunk = len > 0xFFFFFFFFU ? 0xFFFFFFFFU : (uInt)len;
        value = crc32(value, buf, chunk);
        buf += chunk;
        len -= chunk;
    }
    return (uint32_t)value;
}
