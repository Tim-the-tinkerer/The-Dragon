#ifndef CZlib_h
#define CZlib_h

#include <stddef.h>
#include <stdint.h>

#define DRAGON_Z_OK 0
#define DRAGON_Z_STREAM_END 1
#define DRAGON_Z_DEFAULT_COMPRESSION (-1)

int dragon_deflate_init(void **stream, int level);
int dragon_deflate_process(void *stream, const uint8_t *in, size_t in_len,
                           size_t *consumed, uint8_t *out, size_t out_cap,
                           size_t *produced, int finish);
void dragon_deflate_end(void *stream);

int dragon_inflate_init(void **stream);
int dragon_inflate_process(void *stream, const uint8_t *in, size_t in_len,
                           size_t *consumed, uint8_t *out, size_t out_cap,
                           size_t *produced, int *ended);
void dragon_inflate_end(void *stream);

uint32_t dragon_crc32(uint32_t crc, const uint8_t *buf, size_t len);

#endif
