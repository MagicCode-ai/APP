package com.videocall.video_call

import org.webrtc.EncodedImage
import org.webrtc.VideoCodecStatus
import org.webrtc.VideoEncoder
import org.webrtc.VideoFrame
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max

/**
 * Closed-loop H.264 residual transcode in front of the hardware encoder.
 *
 * Camera frames are converted with [VideoFrame.Buffer.toI420] and the same
 * I420 is fed to MCS. Packed NV12/NV21 is used when the buffer is already
 * tightly packed chroma.
 */
class MagicStreamingVideoEncoder(private val inner: VideoEncoder) : VideoEncoder {
    private val pending = ConcurrentHashMap<Long, VideoFrame.Buffer>()
    private val gate = Any()
    private var handle: Long = 0
    @Volatile private var released = false
    private var callback: VideoEncoder.Callback? = null
    private val procUs = ArrayList<Int>(1024)
    private val copyUs = ArrayList<Int>(1024)

    override fun createNative(webrtcEnvRef: Long): Long = 0

    override fun isHardwareEncoder(): Boolean = inner.isHardwareEncoder

    override fun initEncode(
        settings: VideoEncoder.Settings,
        callback: VideoEncoder.Callback?,
    ): VideoCodecStatus {
        synchronized(gate) {
            released = false
            this.callback = callback
            procUs.clear()
            copyUs.clear()
            lastCopyUs = 0
            lastNativeUs = 0
        }
        return inner.initEncode(settings) { image, info ->
            val processed = processEncoded(image)
            if (processed != null) {
                callback?.onEncodedFrame(processed, info)
            } else {
                image.release()
            }
        }
    }

    override fun release(): VideoCodecStatus {
        // Stop native work first, then join the encoder output thread, then
        // free the handle. Doing disable before inner.release() races the
        // last deliverEncodedImage callback and abort()s in ctx_check.
        synchronized(gate) {
            released = true
        }
        val status = inner.release()
        synchronized(gate) {
            logProcSummary("release")
            pending.values.forEach { it.release() }
            pending.clear()
            if (handle != 0L) {
                MagicStreamingNative.releaseHandle(handle)
                handle = 0L
            }
            callback = null
        }
        return status
    }

    override fun encode(frame: VideoFrame, encodeInfo: VideoEncoder.EncodeInfo?): VideoCodecStatus {
        if (!released && isEnabled()) {
            val t0 = android.os.SystemClock.elapsedRealtimeNanos()
            val src = frame.buffer
            val stored: VideoFrame.Buffer? = if (src is PackedNv12Buffer) {
                src.retain()
                src
            } else {
                src.toI420()
            }
            if (stored != null) {
                trimPending()
                pending.put(frame.timestampNs, stored)?.release()
                val us = ((android.os.SystemClock.elapsedRealtimeNanos() - t0) / 1000L).toInt()
                val n: Int
                lastCopyUs = us
                synchronized(gate) {
                    copyUs.add(us)
                    n = copyUs.size
                }
                if (n == 1 || n % 30 == 0) {
                    android.util.Log.i(
                        TAG,
                        "copy n=$n us=$us meanUs=${mean(copyUs)} p95Us=${p95(copyUs)} " +
                            "buf=${src.javaClass.simpleName} " +
                            "${src.width}x${src.height} " +
                            "texture=${src is VideoFrame.TextureBuffer} " +
                            "csp=${if (stored is PackedNv12Buffer) {
                                if (stored.nv21) "nv21" else "nv12"
                            } else {
                                "i420"
                            }}",
                    )
                }
                // VideoFrame() does not retain the buffer. Releasing a wrapper
                // frame would drop pending's toI420() ref and SIGSEGV in
                // WrappedNativeI420Buffer.release on the encoder output thread.
                if (src is VideoFrame.TextureBuffer) {
                    val i420 = stored as? VideoFrame.I420Buffer
                    if (i420 != null) {
                        i420.retain()
                        val cpuFrame = VideoFrame(i420, frame.rotation, frame.timestampNs)
                        try {
                            return inner.encode(cpuFrame, encodeInfo)
                        } finally {
                            cpuFrame.release()
                        }
                    }
                }
            }
        }
        return inner.encode(frame, encodeInfo)
    }

    override fun setRateAllocation(
        allocation: VideoEncoder.BitrateAllocation?,
        frameRate: Int,
    ): VideoCodecStatus = inner.setRateAllocation(allocation, frameRate)

    override fun setRates(rcParameters: VideoEncoder.RateControlParameters?): VideoCodecStatus =
        inner.setRates(rcParameters)

    override fun getScalingSettings(): VideoEncoder.ScalingSettings = inner.scalingSettings

    override fun getImplementationName(): String {
        val name = inner.implementationName
        return if (isEnabled()) "$name+mcs" else name
    }

    override fun getResolutionBitrateLimits(): Array<VideoEncoder.ResolutionBitrateLimits> =
        inner.resolutionBitrateLimits

    override fun getEncoderInfo(): VideoEncoder.EncoderInfo = inner.encoderInfo

    private fun trimPending() {
        if (pending.size <= MAX_PENDING) {
            return
        }
        val keys = pending.keys.sorted()
        val drop = keys.take(pending.size - MAX_PENDING)
        for (key in drop) {
            pending.remove(key)?.release()
        }
    }

    private fun processEncoded(image: EncodedImage): EncodedImage? {
        synchronized(gate) {
            if (released || !isEnabled()) {
                return image
            }
            val yuv = pending.remove(image.captureTimeNs)
            if (yuv == null) {
                return image
            }
            try {
                val src = image.buffer.duplicate().apply { rewind() }
                val au = src.remaining()
                if (au <= 0) {
                    return image
                }
                val cap = max(au * 2, au + 4096)
                val work = ByteBuffer.allocateDirect(cap)
                work.put(src)
                work.clear()
                val outSize = intArrayOf(0)
                val isKey = if (image.frameType == EncodedImage.FrameType.VideoFrameKey) 1 else 0
                val t0 = android.os.SystemClock.elapsedRealtimeNanos()
                handle = processYuv(yuv, work, au, isKey, outSize)
                val nativeUs = ((android.os.SystemClock.elapsedRealtimeNanos() - t0) / 1000L).toInt()
                lastNativeUs = nativeUs
                procUs.add(nativeUs)
                if (procUs.size == 1 || procUs.size % 30 == 0) {
                    android.util.Log.i(
                        TAG,
                        "proc n=${procUs.size} nativeUs=$nativeUs meanUs=${mean(procUs)} " +
                            "p95Us=${p95(procUs)} maxUs=${procUs.maxOrNull() ?: 0} " +
                            "copyMeanUs=${mean(copyUs)} au=$au out=${outSize[0]}",
                    )
                }
                val written = outSize[0]
                if (written <= 0 || written > cap) {
                    return image
                }
                work.position(0)
                work.limit(written)
                val outBuf = work.slice()
                val rewritten = EncodedImage.builder()
                    .setBuffer(outBuf, null)
                    .setEncodedWidth(image.encodedWidth)
                    .setEncodedHeight(image.encodedHeight)
                    .setCaptureTimeNs(image.captureTimeNs)
                    .setFrameType(image.frameType)
                    .setRotation(image.rotation)
                    .setQp(image.qp)
                    .createEncodedImage()
                image.release()
                return rewritten
            } catch (err: Throwable) {
                android.util.Log.e(TAG, "process failed", err)
                return image
            } finally {
                yuv.release()
            }
        }
    }

    private fun processYuv(
        yuv: VideoFrame.Buffer,
        work: ByteBuffer,
        au: Int,
        isKey: Int,
        outSize: IntArray,
    ): Long {
        return when (yuv) {
            is PackedNv12Buffer -> {
                val y = yuv.dataY
                val uv = yuv.dataUv
                MagicStreamingNative.process(
                    handle,
                    y,
                    yuv.strideY,
                    y.position(),
                    uv,
                    yuv.strideUv,
                    uv.position(),
                    null,
                    0,
                    0,
                    yuv.width,
                    yuv.height,
                    if (yuv.nv21) MagicStreamingNative.CSP_NV21 else MagicStreamingNative.CSP_NV12,
                    isKey,
                    work,
                    au,
                    outSize,
                )
            }
            is VideoFrame.I420Buffer -> {
                val y = yuv.dataY
                val u = yuv.dataU
                val v = yuv.dataV
                MagicStreamingNative.process(
                    handle,
                    y,
                    yuv.strideY,
                    y.position(),
                    u,
                    yuv.strideU,
                    u.position(),
                    v,
                    yuv.strideV,
                    v.position(),
                    yuv.width,
                    yuv.height,
                    MagicStreamingNative.CSP_I420,
                    isKey,
                    work,
                    au,
                    outSize,
                )
            }
            else -> {
                outSize[0] = 0
                handle
            }
        }
    }

    private fun logProcSummary(why: String) {
        if (procUs.isEmpty() && copyUs.isEmpty()) {
            return
        }
        android.util.Log.i(
            TAG,
            "proc summary $why n=${procUs.size} nativeMeanUs=${mean(procUs)} " +
                "nativeP95Us=${p95(procUs)} nativeMaxUs=${procUs.maxOrNull() ?: 0} " +
                "copyN=${copyUs.size} copyMeanUs=${mean(copyUs)} copyP95Us=${p95(copyUs)} " +
                "copyMaxUs=${copyUs.maxOrNull() ?: 0}",
        )
    }

    companion object {
        private const val TAG = "MagicStreaming"
        private const val MAX_PENDING = 8
        private val enabledFlag = AtomicBoolean(false)

        @JvmStatic
        @Volatile
        var lastCopyUs: Int = 0

        @JvmStatic
        @Volatile
        var lastNativeUs: Int = 0

        @JvmStatic
        fun isEnabled(): Boolean = enabledFlag.get()

        @JvmStatic
        fun setEnabled(value: Boolean) {
            enabledFlag.set(value)
            android.util.Log.i(TAG, "enabled=$value")
        }

        private fun mean(vals: List<Int>): Int {
            if (vals.isEmpty()) {
                return 0
            }
            return (vals.fold(0L) { acc, v -> acc + v } / vals.size).toInt()
        }

        private fun p95(vals: List<Int>): Int {
            if (vals.isEmpty()) {
                return 0
            }
            val sorted = vals.sorted()
            return sorted[((sorted.size - 1) * 95) / 100]
        }
    }
}
