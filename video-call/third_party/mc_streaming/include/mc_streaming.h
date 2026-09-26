#ifndef MC_STREAMING_H
#define MC_STREAMING_H

#include "mcs_err.h"

#include <stddef.h>
#include <stdint.h>

#if defined(_MSC_VER)
#  if defined(MCS_BUILD_SHARED)
#    define MCS_API __declspec(dllexport)
#  else
#    define MCS_API
#  endif
#elif defined(__GNUC__)
#  define MCS_API __attribute__((visibility("default")))
#else
#  define MCS_API
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

/* Session picture colorspace. Default MCS_CSP_I420. */
typedef enum mc_streaming_csp_e {
    MCS_CSP_I420 = 0, /* planar Y, U, V */
    MCS_CSP_NV12 = 1, /* Y + interleaved UV; u = UV, v unused */
    MCS_CSP_NV21 = 2  /* Y + interleaved VU; u = VU, v unused */
} mc_streaming_csp_e;

typedef enum mc_streaming_cmd_e {
    MCS_CMD_SET_PARAMS = 0,
    MCS_CMD_GET_STATUS = 1
} mc_streaming_cmd_e;

#define MC_STREAMING_MAX_WIDTH  (32 * 1024)
#define MC_STREAMING_MAX_HEIGHT (32 * 1024)

typedef struct mc_streaming_ctrl_params_t {
    mc_streaming_codec_type_e codec_type; /* default MCS_H264_ZERO_DELAY_8BIT */
    mc_streaming_csp_e pic_csp;           /* default MCS_CSP_I420 */
    mc_streaming_log_level_e log_level;   /* default MCS_LOG_ERROR; process-wide */
} mc_streaming_ctrl_params_t;

typedef struct mc_streaming_status_params_t {
    int max_width;          /* session workspace cap; starts 1920, grows on key enlarge */
    int max_height;         /* session workspace cap; starts 1088, grows on key enlarge */
    float bits_save_rate;   /* cumulative (in-out)*100/in; 0 if no emitted AU yet */
} mc_streaming_status_params_t;

typedef struct mc_streaming_input_t {
    /* Display size. Must match coded or display size of the AU.
     * Each dimension must be in (0, MC_STREAMING_MAX_WIDTH/HEIGHT]. */
    int width, height;
    /* I420: y/u/v planes. NV12/NV21: y = luma, u = interleaved chroma, v unused.
     * Plane layout must match the session pic_csp (see MCS_CMD_SET_PARAMS). */
    const uint8_t *y, *u, *v;
    /* I420: plane strides. NV12/NV21: stride_y = luma, stride_u = UV row
     * (typically width); stride_v unused. */
    int stride_y, stride_u, stride_v;

    /* 0 = delta, 1 = key; must match whether the AU is I/IDR. */
    int frame_type;

    /* Annex-B AU at offset 0. Length is au_size. May alias output->bs
     * for in-place EncodedImage processing. */
    const uint8_t *bs;
    size_t au_size;
} mc_streaming_input_t;

typedef struct mc_streaming_output_t {
    /* Output Annex-B buffer. in: capacity; out: bytes written.
     * 0 = drop / nothing emitted. May alias input->bs. */
    size_t bs_size;
    uint8_t *bs;
} mc_streaming_output_t;

/* Init-or-process one EncodedImage. *handle == NULL allocates on first use
 * with default ctrl params (1920*1088 / ZERO_DELAY / I420 / ERROR).
 * Session caps grow on a key reinit when coded size, refs, or B-frames
 * exceed the current allocation. input width/height and coded/display
 * size must be <= MC_STREAMING_MAX_WIDTH/HEIGHT (32*1024).
 * Returns MCS_OK when the AU was processed. A negative MCS_ERR_* still
 * means a legal Annex-B AU was written if output->bs_size > 0 (bypass copy).
 * MCS_ERR_INVAL / MCS_ERR_OUTPUT with output->bs_size == 0: nothing emitted. */
MCS_API int mc_streaming_enable(void **handle,
                        mc_streaming_input_t *input,
                        mc_streaming_output_t *output);

/* Free all session state. Caller sets their pointer to NULL. */
MCS_API int mc_streaming_disable(void *handle);

/* SET_PARAMS: ctrl required (const), status_info may be NULL.
 *   *handle == NULL allocates from ctrl and writes the handle back.
 * GET_STATUS: status_info required, ctrl may be NULL.
 *   *handle == NULL returns MCS_ERR_INVAL and does not allocate.
 * handle == NULL, unknown cmd, or bad magic: MCS_ERR_INVAL (does not abort).
 * log_level on SET is process-wide and takes effect immediately. */
MCS_API int mc_streaming_control(void **handle,
                                 mc_streaming_cmd_e cmd,
                                 const mc_streaming_ctrl_params_t *ctrl,
                                 mc_streaming_status_params_t *status_info);

/* Static version string, e.g. "1.0.0". Do not free. */
MCS_API const char *mc_streaming_get_version(void);

#ifdef __cplusplus
}
#endif

#endif
