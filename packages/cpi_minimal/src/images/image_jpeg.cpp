#include "image_jpeg.h"

#include <climits>
#include <csetjmp>
#include <cstdlib>
#include <cstring>
#include <new>

#include "lib/jpegli/decode.h"
#include "lib/jpegli/encode.h"

namespace {

struct Error {
    jpeg_error_mgr manager;
    std::jmp_buf jump;
};

struct Decoder {
    jpeg_decompress_struct codec;
    Error error;
};

struct Encoder {
    jpeg_compress_struct codec;
    Error error;
    jpeg_destination_mgr destination;
    uint8_t *output;
    size_t capacity;
    size_t size;
};

void fail(j_common_ptr codec) {
    auto *error = reinterpret_cast<Error *>(codec->err);
    const auto *message = codec->err->msg_parm.s;
    constexpr char suffix[] = "Out of memory";
    const auto length = std::strlen(message);
    const bool exhausted = length >= sizeof(suffix) - 1 &&
                           std::strcmp(message + length - (sizeof(suffix) - 1), suffix) == 0;
    std::longjmp(error->jump, exhausted ? CPI_JPEG_OUT_OF_MEMORY : CPI_JPEG_INVALID);
}

jpeg_error_mgr *errors(Error &error) {
    jpegli_std_error(&error.manager);
    error.manager.error_exit = fail;
    error.manager.output_message = [](j_common_ptr) {};
    return &error.manager;
}

boolean missing_end_marker(j_decompress_ptr codec) {
    std::strcpy(codec->err->msg_parm.s, "JPEG ended before EOI");
    fail(reinterpret_cast<j_common_ptr>(codec));
    return FALSE;
}

boolean grow_output(j_compress_ptr codec) {
    auto *state = static_cast<Encoder *>(codec->client_data);
    if (state->capacity > SIZE_MAX / 2) {
        std::longjmp(state->error.jump, CPI_JPEG_OUT_OF_MEMORY);
    }
    auto *buffer = static_cast<uint8_t *>(std::realloc(state->output, state->capacity * 2));
    if (!buffer) std::longjmp(state->error.jump, CPI_JPEG_OUT_OF_MEMORY);
    state->output = buffer;
    state->destination.next_output_byte = buffer + state->capacity;
    state->destination.free_in_buffer = state->capacity;
    state->capacity *= 2;
    return TRUE;
}

int read(Decoder *state, const uint8_t *input, size_t size, cpi_jpeg_allocate allocate,
         cpi_jpeg_cancelled cancelled, void *context) {
    // A fatal jpegli error returns here. The caller owns state on the heap,
    // and every callback returns before a jpegli call can longjmp.
    switch (setjmp(state->error.jump)) {
        case 0: break;
        case CPI_JPEG_OUT_OF_MEMORY: return CPI_JPEG_OUT_OF_MEMORY;
        default: return CPI_JPEG_INVALID;
    }
    auto *codec = &state->codec;
    jpegli_create_decompress(codec);
    jpegli_mem_src(codec, input, static_cast<unsigned long>(size));
    codec->src->fill_input_buffer = missing_end_marker;
    if (jpegli_read_header(codec, TRUE) != JPEG_HEADER_OK) return CPI_JPEG_INVALID;
    auto *pixels = allocate(context, codec->image_width, codec->image_height);
    if (!pixels || cancelled(context)) return CPI_JPEG_STOPPED;
    const bool cmyk = codec->jpeg_color_space == JCS_CMYK || codec->jpeg_color_space == JCS_YCCK;
    codec->out_color_space = cmyk ? JCS_CMYK : JCS_EXT_RGBA;
    if (!jpegli_start_decompress(codec) || codec->output_components != 4) return CPI_JPEG_INVALID;
    const size_t stride = static_cast<size_t>(codec->output_width) * 4;
    while (codec->output_scanline < codec->output_height) {
        if (cancelled(context)) return CPI_JPEG_STOPPED;
        auto *row = pixels + codec->output_scanline * stride;
        if (jpegli_read_scanlines(codec, &row, 1) != 1) return CPI_JPEG_INVALID;
        if (cmyk) for (size_t x = 0; x < stride; x += 4) {
            const unsigned black = codec->saw_Adobe_marker ? row[x + 3] : 255 - row[x + 3];
            for (size_t channel = 0; channel < 3; ++channel) {
                const unsigned ink = codec->saw_Adobe_marker ? row[x + channel] : 255 - row[x + channel];
                row[x + channel] = static_cast<uint8_t>((ink * black + 127) / 255);
            }
            row[x + 3] = 255;
        }
    }
    return jpegli_finish_decompress(codec) ? CPI_JPEG_OK : CPI_JPEG_INVALID;
}

int write(Encoder *state, const uint8_t *pixels, uint32_t width, uint32_t height,
          uint8_t quality, cpi_jpeg_cancelled cancelled, void *context) {
    switch (setjmp(state->error.jump)) {
        case 0: break;
        case CPI_JPEG_OUT_OF_MEMORY: return CPI_JPEG_OUT_OF_MEMORY;
        default: return CPI_JPEG_INVALID;
    }
    auto *codec = &state->codec;
    jpegli_create_compress(codec);
    state->capacity = 4096;
    state->output = static_cast<uint8_t *>(std::malloc(state->capacity));
    if (!state->output) return CPI_JPEG_OUT_OF_MEMORY;
    state->destination.next_output_byte = state->output;
    state->destination.free_in_buffer = state->capacity;
    state->destination.init_destination = [](j_compress_ptr) {};
    state->destination.empty_output_buffer = grow_output;
    state->destination.term_destination = [](j_compress_ptr encoder) {
        auto *owner = static_cast<Encoder *>(encoder->client_data);
        owner->size = owner->capacity - owner->destination.free_in_buffer;
    };
    codec->dest = &state->destination;
    codec->client_data = state;
    codec->image_width = width;
    codec->image_height = height;
    codec->input_components = 4;
    codec->in_color_space = JCS_EXT_RGBA;
    jpegli_set_defaults(codec);
    jpegli_set_quality(codec, quality, TRUE);
    jpegli_start_compress(codec, TRUE);
    const size_t stride = static_cast<size_t>(width) * 4;
    while (codec->next_scanline < height) {
        if (cancelled(context)) return CPI_JPEG_STOPPED;
        auto *row = const_cast<uint8_t *>(pixels + codec->next_scanline * stride);
        if (jpegli_write_scanlines(codec, &row, 1) != 1) return CPI_JPEG_INVALID;
    }
    jpegli_finish_compress(codec);
    return CPI_JPEG_OK;
}

} // namespace

int cpi_jpeg_decode(const uint8_t *input, size_t size, cpi_jpeg_allocate allocate,
                    cpi_jpeg_cancelled cancelled, void *context) {
    if (size == 0 || size > LONG_MAX) return CPI_JPEG_INVALID;
    auto *state = new (std::nothrow) Decoder{};
    if (!state) return CPI_JPEG_OUT_OF_MEMORY;
    state->codec.err = errors(state->error);
    int result;
    try {
        result = read(state, input, size, allocate, cancelled, context);
    } catch (const std::bad_alloc &) {
        result = CPI_JPEG_OUT_OF_MEMORY;
    }
    jpegli_destroy_decompress(&state->codec);
    delete state;
    return result;
}

int cpi_jpeg_encode(const uint8_t *pixels, uint32_t width, uint32_t height, uint8_t quality,
                    cpi_jpeg_cancelled cancelled, void *context, uint8_t **output, size_t *size) {
    auto *state = new (std::nothrow) Encoder{};
    if (!state) return CPI_JPEG_OUT_OF_MEMORY;
    state->codec.err = errors(state->error);
    int result;
    try {
        result = write(state, pixels, width, height, quality, cancelled, context);
    } catch (const std::bad_alloc &) {
        result = CPI_JPEG_OUT_OF_MEMORY;
    }
    jpegli_destroy_compress(&state->codec);
    if (result == CPI_JPEG_OK) {
        *output = state->output;
        *size = state->size;
    } else {
        std::free(state->output);
    }
    delete state;
    return result;
}
