#include <jni.h>
#include <android/log.h>

#include <cstring>

extern "C" {
#include "mc_streaming.h"
}

#define LOG_TAG "MagicStreaming"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

uint8_t *direct_plane(JNIEnv *env, jobject buf, jint off) {
    if (!buf || off < 0) {
        return nullptr;
    }
    auto *base = static_cast<uint8_t *>(env->GetDirectBufferAddress(buf));
    if (!base) {
        return nullptr;
    }
    return base + off;
}

int ensure_session(void **h, int csp) {
    mc_streaming_ctrl_params_t p{};
    int rc;
    if (*h) {
        return MCS_OK;
    }
    p.codec_type = MCS_H264_ZERO_DELAY_8BIT;
    p.pic_csp = static_cast<mc_streaming_csp_e>(csp);
    p.log_level = MCS_LOG_ERROR;
    rc = mc_streaming_control(h, MCS_CMD_SET_PARAMS, &p, NULL);
    if (rc == MCS_OK) {
        mc_streaming_status_params_t st{};
        mc_streaming_control(h, MCS_CMD_GET_STATUS, NULL, &st);
        LOGI("control SET_PARAMS ok handle=%p ver=%s csp=%d max=%dx%d save=%.2f%%",
             *h, mc_streaming_get_version(), csp, st.max_width, st.max_height,
             (double)st.bits_save_rate);
    } else {
        LOGE("control SET_PARAMS failed rc=%d csp=%d", rc, csp);
    }
    return rc;
}

}  // namespace

extern "C" JNIEXPORT void JNICALL
Java_com_videocall_video_1call_MagicStreamingNative_releaseHandle(
        JNIEnv *, jclass, jlong handle) {
    if (handle == 0) {
        return;
    }
    mc_streaming_disable(reinterpret_cast<void *>(handle));
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_videocall_video_1call_MagicStreamingNative_process(
        JNIEnv *env, jclass,
        jlong handle,
        jobject y_buf, jint stride_y, jint y_off,
        jobject u_buf, jint stride_u, jint u_off,
        jobject v_buf, jint stride_v, jint v_off,
        jint width, jint height, jint csp,
        jint is_key,
        jobject bs_buf, jint au_size,
        jintArray out_size) {
    if (!out_size) {
        return handle;
    }
    jint zero = 0;
    env->SetIntArrayRegion(out_size, 0, 1, &zero);

    uint8_t *y = direct_plane(env, y_buf, y_off);
    uint8_t *u = direct_plane(env, u_buf, u_off);
    uint8_t *v = direct_plane(env, v_buf, v_off);
    auto *bs = static_cast<uint8_t *>(env->GetDirectBufferAddress(bs_buf));
    if (csp != MCS_CSP_I420 && csp != MCS_CSP_NV12 && csp != MCS_CSP_NV21) {
        LOGE("process bad csp=%d", csp);
        return handle;
    }
    if (!y || !u || !bs || width <= 0 || height <= 0 || au_size <= 0) {
        LOGE("process bad args w=%d h=%d au=%d csp=%d", width, height, au_size, csp);
        return handle;
    }
    if (csp == MCS_CSP_I420 && !v) {
        LOGE("process I420 missing V plane");
        return handle;
    }
    jlong cap = env->GetDirectBufferCapacity(bs_buf);
    if (cap < au_size) {
        LOGE("process buffer too small cap=%lld au=%d", (long long)cap, au_size);
        return handle;
    }
    mc_streaming_input_t in{};
    in.width = width;
    in.height = height;
    in.y = y;
    in.u = u;
    in.v = v;
    in.stride_y = stride_y;
    in.stride_u = stride_u;
    in.stride_v = stride_v;
    in.frame_type = is_key ? 1 : 0;
    in.au_size = static_cast<size_t>(au_size);
    in.bs = bs;

    mc_streaming_output_t out{};
    out.bs = bs;
    out.bs_size = static_cast<size_t>(cap);

    void *h = reinterpret_cast<void *>(handle);
    if (ensure_session(&h, csp) != MCS_OK) {
        LOGE("process session create failed csp=%d", csp);
        return handle;
    }
    int rc = mc_streaming_enable(&h, &in, &out);
    if (rc != MCS_OK) {
        LOGI("mc_streaming_enable rc=%d out=%zu key=%d %dx%d csp=%d",
             rc, out.bs_size, is_key, width, height, csp);
    } else {
        static int first_ok;
        if (!first_ok) {
            mc_streaming_status_params_t st{};
            mc_streaming_control(&h, MCS_CMD_GET_STATUS, NULL, &st);
            LOGI("mc_streaming_enable first ok out=%zu key=%d %dx%d max=%dx%d save=%.2f%%",
                 out.bs_size, is_key, width, height, st.max_width, st.max_height,
                 (double)st.bits_save_rate);
            first_ok = 1;
        }
    }
    jint written = (out.bs_size > 0 && out.bs_size <= static_cast<size_t>(cap))
                       ? static_cast<jint>(out.bs_size)
                       : 0;
    env->SetIntArrayRegion(out_size, 0, 1, &written);
    return reinterpret_cast<jlong>(h);
}
