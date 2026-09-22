#ifndef MCS_ERR_H
#define MCS_ERR_H

#ifdef __cplusplus
extern "C" {
#endif

/* Return codes for mc_streaming_enable / mc_streaming_disable and internal
 * encode paths. 0 is success. The encoder may also return a positive
 * changed-MB count on success. Negative values are errors. A negative
 * code from mc_streaming_enable can still mean a legal Annex-B AU was
 * written if output->bs_size > 0 (bypass copy). */
enum {
    MCS_OK          = 0,   /* success */
    MCS_ERR_INVAL   = -1,  /* bad arguments; nothing emitted */
    MCS_ERR_NOMEM   = -2,  /* allocation failed */
    MCS_ERR_DECODE  = -3,  /* bitstream parse or decode failed */
    MCS_ERR_ENCODE  = -4,  /* closed-loop encode failed */
    MCS_ERR_REWRITE = -5,  /* slice rewrite / entropy re-encode failed */
    MCS_ERR_OUTPUT  = -6,  /* output buffer too small or emit failed */
    MCS_ERR_SIZE    = -7,  /* resolution, refs, B-frames, or coded size change not allowed */
    MCS_ERR_KEY     = -8,  /* caller key/delta does not match whether the AU is I/IDR */
    MCS_ERR_CROP    = -9,  /* YUV width/height does not match coded or display size */
    MCS_ERR_BYPASS  = -10  /* still copying input NALs until the next I or IDR */
};

#define mcs_ok          MCS_OK
#define mcs_err_inval   MCS_ERR_INVAL
#define mcs_err_nomem   MCS_ERR_NOMEM
#define mcs_err_decode  MCS_ERR_DECODE
#define mcs_err_encode  MCS_ERR_ENCODE
#define mcs_err_rewrite MCS_ERR_REWRITE
#define mcs_err_output  MCS_ERR_OUTPUT
#define mcs_err_size    MCS_ERR_SIZE
#define mcs_err_key     MCS_ERR_KEY
#define mcs_err_crop    MCS_ERR_CROP
#define mcs_err_bypass  MCS_ERR_BYPASS

#ifdef __cplusplus
}
#endif

#endif
