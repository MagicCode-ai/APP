#include <jni.h>
#include <android/log.h>
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <sys/stat.h>
#include <cstring>
#include <cstdlib>
#include <cstdint>
#include <cmath>
#include <vector>
#include <mutex>

extern "C" {
#include "mc_interface.h"
}

#define LOG_TAG "MagicSrJni"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

std::mutex g_mu;
void *g_sr_handle = nullptr;
EGLDisplay g_display = EGL_NO_DISPLAY;
EGLContext g_context = EGL_NO_CONTEXT;
EGLSurface g_surface = EGL_NO_SURFACE;
GLuint g_input_tex = 0;
GLuint g_output_tex = 0;
int g_in_w = 0;
int g_in_h = 0;
int g_out_w = 0;
int g_out_h = 0;
int g_session_w = 0;
int g_session_h = 0;
float g_scale = 1.5f;
bool g_logged_first = false;

uint32_t scaled_dimension(uint32_t value, float scaler) {
    double scaled = (double)value * (double)scaler;
    if (scaled < 1.0) return 1;
    if (scaled > (double)UINT32_MAX) return UINT32_MAX;
    return (uint32_t)floor(scaled + 0.5);
}

bool make_current() {
    if (g_display == EGL_NO_DISPLAY || g_context == EGL_NO_CONTEXT || g_surface == EGL_NO_SURFACE) {
        return false;
    }
    return eglMakeCurrent(g_display, g_surface, g_surface, g_context) == EGL_TRUE;
}

void destroy_egl() {
    if (g_display != EGL_NO_DISPLAY) {
        eglMakeCurrent(g_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (g_surface != EGL_NO_SURFACE) eglDestroySurface(g_display, g_surface);
        if (g_context != EGL_NO_CONTEXT) eglDestroyContext(g_display, g_context);
        eglTerminate(g_display);
    }
    g_display = EGL_NO_DISPLAY;
    g_context = EGL_NO_CONTEXT;
    g_surface = EGL_NO_SURFACE;
}

bool create_gles_context() {
    eglBindAPI(EGL_OPENGL_ES_API);
    destroy_egl();
    g_display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (g_display == EGL_NO_DISPLAY) return false;
    if (!eglInitialize(g_display, nullptr, nullptr)) {
        g_display = EGL_NO_DISPLAY;
        return false;
    }
    const EGLint config_attrs[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_NONE
    };
    EGLConfig config = nullptr;
    EGLint num = 0;
    if (!eglChooseConfig(g_display, config_attrs, &config, 1, &num) || num <= 0) {
        destroy_egl();
        return false;
    }
    const EGLint ctx_attrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    g_context = eglCreateContext(g_display, config, EGL_NO_CONTEXT, ctx_attrs);
    if (g_context == EGL_NO_CONTEXT) {
        destroy_egl();
        return false;
    }
    const EGLint surf_attrs[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    g_surface = eglCreatePbufferSurface(g_display, config, surf_attrs);
    if (g_surface == EGL_NO_SURFACE) {
        destroy_egl();
        return false;
    }
    if (!make_current()) {
        destroy_egl();
        return false;
    }
    return true;
}

GLuint create_texture(int width, int height) {
    GLuint tex = 0;
    glGenTextures(1, &tex);
    if (tex == 0) return 0;
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glBindTexture(GL_TEXTURE_2D, 0);
    return tex;
}

void clear_textures() {
    if (g_input_tex) glDeleteTextures(1, &g_input_tex);
    if (g_output_tex) glDeleteTextures(1, &g_output_tex);
    g_input_tex = g_output_tex = 0;
    g_in_w = g_in_h = g_out_w = g_out_h = 0;
}

void release_locked() {
    if (g_sr_handle) {
        make_current();
        MC_Disable(g_sr_handle);
        g_sr_handle = nullptr;
    }
    if (g_display != EGL_NO_DISPLAY && make_current()) {
        clear_textures();
    } else {
        g_input_tex = g_output_tex = 0;
        g_in_w = g_in_h = g_out_w = g_out_h = 0;
    }
    destroy_egl();
    g_session_w = g_session_h = 0;
    g_logged_first = false;
}

void fill_gles_resource(magic_resource_t *res, GLuint tex) {
    memset(res, 0, sizeof(*res));
    res->handle.gl_texture = tex;
    res->format = (uint32_t)GL_RGBA8;
    res->target = (uint32_t)GL_TEXTURE_2D;
    res->mip_count = 1;
}

bool ensure_textures(int in_w, int in_h, int out_w, int out_h) {
    if (!make_current()) return false;
    if (g_input_tex && g_output_tex && g_in_w == in_w && g_in_h == in_h &&
        g_out_w == out_w && g_out_h == out_h) {
        return true;
    }
    clear_textures();
    g_input_tex = create_texture(in_w, in_h);
    g_output_tex = create_texture(out_w, out_h);
    if (!g_input_tex || !g_output_tex) {
        clear_textures();
        return false;
    }
    g_in_w = in_w;
    g_in_h = in_h;
    g_out_w = out_w;
    g_out_h = out_h;
    return true;
}

uint8_t clip8(int v) {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return (uint8_t)v;
}

void i420_to_rgba(const uint8_t *y, int stride_y,
                  const uint8_t *u, int stride_u,
                  const uint8_t *v, int stride_v,
                  int width, int height, uint8_t *rgba) {
    for (int row = 0; row < height; ++row) {
        const uint8_t *y_row = y + row * stride_y;
        const uint8_t *u_row = u + (row / 2) * stride_u;
        const uint8_t *v_row = v + (row / 2) * stride_v;
        uint8_t *dst = rgba + (size_t)row * (size_t)width * 4u;
        for (int col = 0; col < width; ++col) {
            int C = (int)y_row[col] - 16;
            int D = (int)u_row[col / 2] - 128;
            int E = (int)v_row[col / 2] - 128;
            dst[col * 4 + 0] = clip8((298 * C + 409 * E + 128) >> 8);
            dst[col * 4 + 1] = clip8((298 * C - 100 * D - 208 * E + 128) >> 8);
            dst[col * 4 + 2] = clip8((298 * C + 516 * D + 128) >> 8);
            dst[col * 4 + 3] = 255;
        }
    }
}

void rotate_rgba(const uint8_t *src, int width, int height, int rotation, std::vector<uint8_t> *out,
                 int *out_w, int *out_h) {
    rotation = ((rotation % 360) + 360) % 360;
    if (rotation == 0) {
        out->assign(src, src + (size_t)width * height * 4);
        *out_w = width;
        *out_h = height;
        return;
    }
    if (rotation == 180) {
        out->resize((size_t)width * height * 4);
        *out_w = width;
        *out_h = height;
        for (int y = 0; y < height; ++y) {
            for (int x = 0; x < width; ++x) {
                const uint8_t *s = src + ((size_t)y * width + x) * 4;
                uint8_t *d = out->data() + ((size_t)(height - 1 - y) * width + (width - 1 - x)) * 4;
                memcpy(d, s, 4);
            }
        }
        return;
    }
    out->resize((size_t)width * height * 4);
    *out_w = height;
    *out_h = width;
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const uint8_t *s = src + ((size_t)y * width + x) * 4;
            int dx, dy;
            if (rotation == 90) {
                dx = height - 1 - y;
                dy = x;
            } else {
                dx = y;
                dy = width - 1 - x;
            }
            uint8_t *d = out->data() + ((size_t)dy * (*out_w) + dx) * 4;
            memcpy(d, s, 4);
        }
    }
}

void pack_argb(const uint8_t *rgba, jint *dst, int pixels) {
    for (int i = 0; i < pixels; ++i) {
        const uint8_t *p = rgba + i * 4;
        dst[i] = (jint)((255u << 24) | ((uint32_t)p[0] << 16) | ((uint32_t)p[1] << 8) | (uint32_t)p[2]);
    }
}

int init_session(int width, int height, const char *model_path) {
    release_locked();
    if (width < 64 || height < 64 || !model_path || !model_path[0]) {
        return -1;
    }
    struct stat st_file;
    memset(&st_file, 0, sizeof(st_file));
    if (stat(model_path, &st_file) != 0 || st_file.st_size < 3000000) {
        LOGE("combined model missing or too small path=%s size=%lld",
             model_path, (long long)st_file.st_size);
        return -5;
    }
    LOGI("init model=%s bytes=%lld %dx%d version=%s",
         model_path, (long long)st_file.st_size, width, height, MC_GetVersion());
    if (!create_gles_context()) {
        LOGE("egl context failed");
        return -2;
    }
    input_param_t param;
    memset(&param, 0, sizeof(param));
    param.struct_size = (uint32_t)sizeof(param);
    param.input_type = INPUT_TEXTURE_RGB8Unorm;
    param.width = (unsigned int)width;
    param.height = (unsigned int)height;
    param.scaler_factor = 1.5f;
    param.alg_mode = SPATIAL_BALANCED_MODE;
    param.log_level = MAGIC_LOG_INFO;
    param.backend = MAGIC_BACKEND_OPENGLES;
    param.spatial_sharpen_level = 1;
    param.gpu_context.native_context = (void *)g_context;
    strncpy(param.model_path, model_path, sizeof(param.model_path) - 1);

    output_status_params_t st;
    memset(&st, 0, sizeof(st));
    g_sr_handle = nullptr;
    int rc = MC_Enable(&g_sr_handle, nullptr, &param, &st);
    if (rc != 0 || !g_sr_handle) {
        LOGE("MC_Enable init rc=%d model=%s", rc, model_path);
        release_locked();
        return rc != 0 ? rc : -3;
    }
    g_scale = st.scaler_factor;
    g_session_w = width;
    g_session_h = height;
    const uint32_t expect_w = scaled_dimension((uint32_t)width, 1.5f);
    const uint32_t expect_h = scaled_dimension((uint32_t)height, 1.5f);
    if (st.width != (unsigned)width || st.height != (unsigned)height ||
        st.output_width != expect_w || st.output_height != expect_h) {
        LOGE("size mismatch session=%ux%u->%ux%u expect=%dx%d->%ux%u",
             st.width, st.height, st.output_width, st.output_height,
             width, height, (unsigned)expect_w, (unsigned)expect_h);
        release_locked();
        return -4;
    }
    LOGI("MC_Init ok %s mode=SPATIAL_BALANCED scale=1.5 sharpen=1 %dx%d -> %ux%u",
         MC_GetVersion(), width, height, st.output_width, st.output_height);
    return 0;
}

}  // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_videocall_video_1call_MagicSrNative_version(JNIEnv *env, jclass) {
    const char *v = MC_GetVersion();
    return env->NewStringUTF(v ? v : "");
}

extern "C" JNIEXPORT jint JNICALL
Java_com_videocall_video_1call_MagicSrNative_init(
        JNIEnv *env, jclass, jint width, jint height, jstring model_path) {
    const char *path = env->GetStringUTFChars(model_path, nullptr);
    std::lock_guard<std::mutex> lock(g_mu);
    int rc = init_session(width, height, path);
    env->ReleaseStringUTFChars(model_path, path);
    return rc;
}

extern "C" JNIEXPORT void JNICALL
Java_com_videocall_video_1call_MagicSrNative_release(JNIEnv *, jclass) {
    std::lock_guard<std::mutex> lock(g_mu);
    release_locked();
}

extern "C" JNIEXPORT jint JNICALL
Java_com_videocall_video_1call_MagicSrNative_processI420(
        JNIEnv *env, jclass,
        jobject y_buf, jint stride_y, jint y_off,
        jobject u_buf, jint stride_u, jint u_off,
        jobject v_buf, jint stride_v, jint v_off,
        jint width, jint height, jint rotation,
        jintArray out_argb, jintArray out_size) {
    if (!y_buf || !u_buf || !v_buf || !out_argb || !out_size) return -1;
    auto *y = (uint8_t *)env->GetDirectBufferAddress(y_buf);
    auto *u = (uint8_t *)env->GetDirectBufferAddress(u_buf);
    auto *v = (uint8_t *)env->GetDirectBufferAddress(v_buf);
    if (!y || !u || !v) return -2;
    if (y_off < 0 || u_off < 0 || v_off < 0) return -2;
    y += y_off;
    u += u_off;
    v += v_off;

    std::vector<uint8_t> rgba((size_t)width * height * 4);
    i420_to_rgba(y, stride_y, u, stride_u, v, stride_v, width, height, rgba.data());
    std::vector<uint8_t> rotated;
    int rw = width, rh = height;
    rotate_rgba(rgba.data(), width, height, rotation, &rotated, &rw, &rh);

    std::lock_guard<std::mutex> lock(g_mu);
    if (!g_sr_handle || g_session_w != rw || g_session_h != rh) {
        return -10;
    }
    if (!make_current()) {
        LOGE("eglMakeCurrent failed before process");
        return -11;
    }
    const int out_w = (int)scaled_dimension((uint32_t)rw, g_scale);
    const int out_h = (int)scaled_dimension((uint32_t)rh, g_scale);
    if (!ensure_textures(rw, rh, out_w, out_h)) return -11;

    glBindTexture(GL_TEXTURE_2D, g_input_tex);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, rw, rh, GL_RGBA, GL_UNSIGNED_BYTE, rotated.data());
    glBindTexture(GL_TEXTURE_2D, 0);

    magic_frame_t frame;
    memset(&frame, 0, sizeof(frame));
    fill_gles_resource(&frame.image_in, g_input_tex);
    fill_gles_resource(&frame.image_out, g_output_tex);
    int ret = MC_Enable(&g_sr_handle, &frame, nullptr, nullptr);
    if (ret != 0) {
        LOGE("MC_Enable process ret=%d", ret);
        return ret;
    }
    if (!g_logged_first) {
        g_logged_first = true;
        LOGI("MC_Enable first ok in=%dx%d out=%dx%d", rw, rh, out_w, out_h);
    }
    glFinish();

    GLuint fbo = 0;
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, g_output_tex, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glDeleteFramebuffers(1, &fbo);
        return -12;
    }
    std::vector<uint8_t> out_rgba((size_t)out_w * out_h * 4);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, out_w, out_h, GL_RGBA, GL_UNSIGNED_BYTE, out_rgba.data());
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glDeleteFramebuffers(1, &fbo);

    const jsize need = (jsize)(out_w * out_h);
    if (env->GetArrayLength(out_argb) < need) return -13;
    jint *dst = env->GetIntArrayElements(out_argb, nullptr);
    if (!dst) return -14;
    pack_argb(out_rgba.data(), dst, out_w * out_h);
    env->ReleaseIntArrayElements(out_argb, dst, 0);
    jint sizes[2] = {out_w, out_h};
    env->SetIntArrayRegion(out_size, 0, 2, sizes);
    return 0;
}
