package com.videocall.video_call

object MagicSrNative {
    init {
        System.loadLibrary("magic_sr_jni")
    }

    external fun version(): String

    external fun init(width: Int, height: Int, modelPath: String): Int

    external fun release()

    external fun processI420(
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
        rotation: Int,
        outArgb: IntArray,
        outSize: IntArray,
    ): Int
}
