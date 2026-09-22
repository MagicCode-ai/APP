package com.videocall.video_call

object MagicStreamingNative {
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
        v: java.nio.ByteBuffer,
        strideV: Int,
        vOffset: Int,
        width: Int,
        height: Int,
        isKey: Int,
        bitstream: java.nio.ByteBuffer,
        auSize: Int,
        outSize: IntArray,
    ): Long

    external fun releaseHandle(handle: Long)
}
