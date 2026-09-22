package com.videocall.video_call

import org.webrtc.EncodedImage
import org.webrtc.VideoCodecStatus
import org.webrtc.VideoEncoder
import org.webrtc.VideoFrame
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max

class MagicStreamingVideoEncoder(private val inner: VideoEncoder) : VideoEncoder {
    private val pending = ConcurrentHashMap<Long, VideoFrame.I420Buffer>()
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
            val i420 = frame.buffer.toI420()
            if (i420 != null) {
                trimPending()
                pending.put(frame.timestampNs, i420)?.release()
                val us = ((android.os.SystemClock.elapsedRealtimeNanos() - t0) / 1000L).toInt()
                synchronized(gate) {
                    copyUs.add(us)
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
            val i420 = pending.remove(image.captureTimeNs)
            if (i420 == null) {
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
                val y = i420.dataY
                val u = i420.dataU
                val v = i420.dataV
                val outSize = intArrayOf(0)
                val t0 = android.os.SystemClock.elapsedRealtimeNanos()
                handle = MagicStreamingNative.process(
                    handle,
                    y,
                    i420.strideY,
                    y.position(),
                    u,
                    i420.strideU,
                    u.position(),
                    v,
                    i420.strideV,
                    v.position(),
                    i420.width,
                    i420.height,
                    if (image.frameType == EncodedImage.FrameType.VideoFrameKey) 1 else 0,
                    work,
                    au,
                    outSize,
                )
                val nativeUs = ((android.os.SystemClock.elapsedRealtimeNanos() - t0) / 1000L).toInt()
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
                i420.release()
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
