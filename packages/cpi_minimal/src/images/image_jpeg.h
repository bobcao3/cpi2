#ifndef CPI_IMAGE_JPEG_H
#define CPI_IMAGE_JPEG_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    CPI_JPEG_OK,
    CPI_JPEG_INVALID,
    CPI_JPEG_OUT_OF_MEMORY,
    CPI_JPEG_STOPPED,
};

typedef uint8_t *(*cpi_jpeg_allocate)(void *, uint32_t, uint32_t);
typedef bool (*cpi_jpeg_cancelled)(void *);

int cpi_jpeg_decode(const uint8_t *input, size_t size, cpi_jpeg_allocate allocate,
                    cpi_jpeg_cancelled cancelled, void *context);
int cpi_jpeg_encode(const uint8_t *pixels, uint32_t width, uint32_t height, uint8_t quality,
                    cpi_jpeg_cancelled cancelled, void *context, uint8_t **output, size_t *size);

#ifdef __cplusplus
}
#endif

#endif
