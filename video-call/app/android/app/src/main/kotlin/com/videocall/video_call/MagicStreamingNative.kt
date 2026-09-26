package com.videocall.video_call

object MagicStreamingNative {
    const val CSP_I420 = 0
    const val CSP_NV12 = 1
    const val CSP_NV21 = 2

    init {
        System.loadLibrary("magic_sr_jni")
    }

    external fun process(
        handle: Long,
        y: java.nio.ByteBuffer,
        strideY: Int,
        yOffset: Int,
        u: java.nio.ByteBuffer,
        strideU: Int,
        uOffset: Int,
        v: java.nio.ByteBuffer?,
        strideV: Int,
        vOffset: Int,
        width: Int,
        height: Int,
        csp: Int,
        isKey: Int,
        bitstream: java.nio.ByteBuffer,
        auSize: Int,
        outSize: IntArray,
    ): Long

    external fun releaseHandle(handle: Long)
}
