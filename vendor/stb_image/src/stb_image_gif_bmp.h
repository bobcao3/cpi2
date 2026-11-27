#ifndef CPI_STB_IMAGE_GIF_BMP_H
#define CPI_STB_IMAGE_GIF_BMP_H

#ifdef __cplusplus
extern "C" {
#endif

int stbi_info_from_memory(const unsigned char *data, int length, int *width, int *height, int *channels);
unsigned char *stbi_load_from_memory(const unsigned char *data, int length, int *width, int *height, int *channels, int desired_channels);
unsigned char *stbi_load_gif_from_memory(const unsigned char *data, int length, int **delays, int *width, int *height, int *frames, int *channels, int desired_channels);
void stbi_image_free(void *data);
const char *stbi_failure_reason(void);

#ifdef __cplusplus
}
#endif

#endif
