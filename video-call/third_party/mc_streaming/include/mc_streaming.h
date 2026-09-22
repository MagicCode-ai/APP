#ifndef MC_STREAMING_H
#define MC_STREAMING_H

#include "mcs_err.h"

#include <stddef.h>
#include <stdint.h>

#if defined(__GNUC__)
#define MCS_API __attribute__((visibility("default")))
#else
#define MCS_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Higher value is more verbose. A message prints when the current level
 * is >= the message level. Default is MCS_LOG_ERROR. MCS_LOG_NONE silences all. */
typedef enum mc_streaming_log_level_e {
    MCS_LOG_NONE = 0,
    MCS_LOG_ERROR,
    MCS_LOG_WARNING,
    MCS_LOG_INFO,
    MCS_LOG_DEBUG
} mc_streaming_log_level_e;

typedef enum mc_streaming_codec_type_e {
    MCS_H264_ZERO_DELAY_8BIT = 0, /* recommended for real-time calls */
    MCS_H264_8BIT            = 1, /* P and B processing; higher CPU */
    MCS_MAX_CODEC
} mc_streaming_codec_type_e;

typedef struct mc_streaming_input_t {
    uint32_t struct_size;

    /* I420, matching VideoFrame.buffer.toI420() */
    int width, height;
    const uint8_t *y, *u, *v;
    int stride_y, stride_u, stride_v;

    /* 0 = delta, 1 = key; must match whether the AU is I/IDR. */
    int frame_type;

    /* Annex-B AU length at output->bs[0]. 0 = legacy: trim trailing zeros
     * from output->bs_size. Prefer this over zero-filling the unused tail. */
    size_t au_size;
} mc_streaming_input_t;

typedef struct mc_streaming_output_t {
    /* EncodedImage.buffer: on entry holds the Annex-B AU at offset 0.
     * in: buffer capacity; out: bytes written; 0 = drop / nothing emitted.
     * Unused tail need not be zero if input->au_size is the AU length. */
    size_t bs_size;
    uint8_t *bs;
} mc_streaming_output_t;

/* Init-or-process one EncodedImage. *handle == NULL allocates on first use.
 * Session caps start at 1920*1088 / 2 refs / 1 B-frame and grow on a key
 * reinit. MCS_H264_ZERO_DELAY_8BIT and MCS_H264_8BIT are implemented.
 * Returns MCS_OK when the AU was processed. A negative MCS_ERR_* still
 * means a legal Annex-B AU was written if output->bs_size > 0 (bypass copy).
 * MCS_ERR_INVAL / MCS_ERR_OUTPUT with output->bs_size == 0: nothing emitted. */
MCS_API int mc_streaming_enable(void **handle, mc_streaming_codec_type_e codec_type,
                        mc_streaming_input_t *input,
                        mc_streaming_output_t *output);

/* Free all session state. Caller sets their pointer to NULL. */
MCS_API int mc_streaming_disable(void *handle);

/* Process-wide log threshold. Default MCS_LOG_ERROR. */
MCS_API void mc_streaming_set_log_level(mc_streaming_log_level_e level);

/* Static version string, e.g. "1.0.0". Do not free. */
MCS_API const char *mc_streaming_get_version(void);

#ifdef __cplusplus
}
#endif

#endif
