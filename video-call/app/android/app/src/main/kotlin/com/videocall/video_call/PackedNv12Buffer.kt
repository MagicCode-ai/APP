package com.videocall.video_call

import androidx.annotation.Keep
import org.webrtc.NV12Buffer
import org.webrtc.NV21Buffer
import org.webrtc.VideoFrame
import org.webrtc.YuvHelper
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicInteger

/** Tightly packed Y + interleaved chroma (NV12 or NV21). MCS reads Y/UV directly. */
@Keep
class PackedNv12Buffer(
    private val w: Int,
    private val h: Int,
    private val packed: ByteBuffer,
    val nv21: Boolean,
    private val releaseCallback: Runnable? = null,
) : VideoFrame.Buffer {
    private val refCount = AtomicInteger(1)

    override fun getWidth(): Int = w

    override fun getHeight(): Int = h

    val strideY: Int
        get() = w

    val strideUv: Int
        get() = w

    fun duplicatePacked(): ByteBuffer {
        val dup = packed.duplicate()
        dup.clear()
        return dup
    }

    val dataY: ByteBuffer
        get() {
            val dup = packed.duplicate()
            dup.clear()
            dup.limit(w * h)
            return dup.slice()
        }

    val dataUv: ByteBuffer
        get() {
            val dup = packed.duplicate()
            dup.clear()
            dup.position(w * h)
            dup.limit(w * h + uvBytes())
            return dup.slice()
        }

    private fun uvBytes(): Int = w * (h / 2)

    override fun toI420(): VideoFrame.I420Buffer {
        if (nv21) {
            val bytes = ByteArray(w * h + uvBytes())
            val dup = packed.duplicate()
            dup.clear()
            dup.limit(bytes.size)
            dup.get(bytes)
            val nv21Buf = NV21Buffer(bytes, w, h, null)
            try {
                return checkNotNull(nv21Buf.toI420())
            } finally {
                nv21Buf.release()
            }
        }
        val dup = packed.duplicate()
        dup.clear()
        val nv12 = NV12Buffer(w, h, w, h, dup, null)
        try {
            return checkNotNull(nv12.toI420())
        } finally {
            nv12.release()
        }
    }

    override fun retain() {
        val n = refCount.incrementAndGet()
        check(n > 1) { "PackedNv12Buffer retain on released buffer" }
    }

    override fun release() {
        val n = refCount.decrementAndGet()
        check(n >= 0) { "PackedNv12Buffer over-release" }
        if (n == 0) {
            releaseCallback?.run()
        }
    }

    override fun cropAndScale(
        cropX: Int,
        cropY: Int,
        cropWidth: Int,
        cropHeight: Int,
        scaleWidth: Int,
        scaleHeight: Int,
    ): VideoFrame.Buffer {
        if (cropX == 0 && cropY == 0 && cropWidth == w && cropHeight == h &&
            scaleWidth == w && scaleHeight == h
        ) {
            retain()
            return this
        }
        if (scaleWidth == cropWidth && scaleHeight == cropHeight &&
            cropX % 2 == 0 && cropY % 2 == 0 &&
            cropWidth >= 2 && cropHeight >= 2 &&
            cropWidth % 2 == 0 && cropHeight % 2 == 0 &&
            cropX >= 0 && cropY >= 0 &&
            cropX + cropWidth <= w && cropY + cropHeight <= h
        ) {
            return cropPacked(cropX, cropY, cropWidth, cropHeight)
        }
        android.util.Log.w(
            "PackedNv12",
            "cropAndScale toI420 $cropX,$cropY ${cropWidth}x$cropHeight -> ${scaleWidth}x$scaleHeight src=${w}x$h",
        )
        val i420 = toI420()
        try {
            return i420.cropAndScale(cropX, cropY, cropWidth, cropHeight, scaleWidth, scaleHeight)
        } finally {
            i420.release()
        }
    }

    private fun cropPacked(cropX: Int, cropY: Int, cropW: Int, cropH: Int): PackedNv12Buffer {
        val ySize = cropW * cropH
        val dst = ByteBuffer.allocateDirect(ySize + ySize / 2)
        val ySrc = dataY
        dst.position(0)
        dst.limit(ySize)
        YuvHelper.copyPlane(
            sliceAt(ySrc, cropY * w + cropX),
            w,
            dst.slice(),
            cropW,
            cropW,
            cropH,
        )
        val uvSrc = dataUv
        dst.limit(dst.capacity())
        dst.position(ySize)
        YuvHelper.copyPlane(
            sliceAt(uvSrc, (cropY / 2) * w + cropX),
            w,
            dst.slice(),
            cropW,
            cropW,
            cropH / 2,
        )
        dst.clear()
        return PackedNv12Buffer(cropW, cropH, dst, nv21)
    }

    private fun sliceAt(src: ByteBuffer, offset: Int): ByteBuffer {
        val dup = src.duplicate()
        dup.position(offset)
        return dup.slice()
    }
}
