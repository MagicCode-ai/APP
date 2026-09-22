package com.videocall.video_call

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import org.webrtc.VideoFrame
import org.webrtc.VideoSink
import org.webrtc.VideoTrack
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

class MagicSrPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, VideoSink {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var textures: TextureRegistry? = null
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null
    private var videoTrack: VideoTrack? = null
    private val busy = AtomicBoolean(false)
    private var sessionW = 0
    private var sessionH = 0
    private var modelPath: String? = null
    private var outArgb = IntArray(1440 * 810)
    private var bitmap: Bitmap? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val paint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val lock = Any()
    private var failLogCount = 0
    private var lastOutW = 0
    private var lastOutH = 0

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        textures = binding.textureRegistry
        channel = MethodChannel(binding.binaryMessenger, "video_call/magic_sr")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stop()
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val trackId = call.argument<String>("trackId")
                if (trackId.isNullOrEmpty()) {
                    result.error("bad_args", "trackId required", null)
                    return
                }
                try {
                    val textureId = start(trackId)
                    result.success(textureId)
                } catch (err: Throwable) {
                    result.error("start_failed", err.message, null)
                }
            }
            "stop" -> {
                stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun start(trackId: String): Long {
        synchronized(lock) {
            stopLocked()
            modelPath = copyCombinedModel()
            val track = resolveVideoTrack(trackId)
                ?: throw IllegalStateException("video track not found: $trackId")
            val entry = textures?.createSurfaceTexture()
                ?: throw IllegalStateException("no texture registry")
            entry.surfaceTexture().setDefaultBufferSize(1440, 810)
            textureEntry = entry
            surface = Surface(entry.surfaceTexture())
            videoTrack = track
            track.addSink(this)
            android.util.Log.i(TAG, "start track=$trackId model=$modelPath version=${MagicSrNative.version()}")
            return entry.id()
        }
    }

    private fun stop() {
        synchronized(lock) {
            stopLocked()
        }
    }

    private fun stopLocked() {
        videoTrack?.removeSink(this)
        videoTrack = null
        if (sessionW != 0 || sessionH != 0) {
            try {
                MagicSrNative.release()
            } catch (err: Throwable) {
                android.util.Log.e(TAG, "release failed", err)
            }
        }
        sessionW = 0
        sessionH = 0
        failLogCount = 0
        lastOutW = 0
        lastOutH = 0
        surface?.release()
        surface = null
        textureEntry?.release()
        textureEntry = null
        bitmap?.recycle()
        bitmap = null
    }

    private fun resolveVideoTrack(trackId: String): VideoTrack? {
        val clazz = Class.forName("com.cloudwebrtc.webrtc.FlutterWebRTCPlugin")
        val plugin = clazz.getField("sharedSingleton").get(null) ?: return null
        val getTrack = clazz.getMethod("getTrackForId", String::class.java, String::class.java)
        val getRemote = clazz.getMethod("getRemoteTrack", String::class.java)
        return (getTrack.invoke(plugin, trackId, null) as? VideoTrack)
            ?: (getRemote.invoke(plugin, trackId) as? VideoTrack)
    }

    private fun copyCombinedModel(): String {
        val dir = File(context.filesDir, "models")
        if (!dir.exists() && !dir.mkdirs()) {
            throw IllegalStateException("cannot create model dir: ${dir.absolutePath}")
        }
        val out = File(dir, COMBINED_MODEL)
        context.assets.open("model/$COMBINED_MODEL").use { input ->
            out.outputStream().use { input.copyTo(it) }
        }
        if (out.length() < MIN_COMBINED_BYTES) {
            throw IllegalStateException("combined model too small: ${out.length()}")
        }
        android.util.Log.i(TAG, "model ready ${out.absolutePath} bytes=${out.length()}")
        return out.absolutePath
    }

    override fun onFrame(frame: VideoFrame) {
        if (!busy.compareAndSet(false, true)) {
            return
        }
        frame.retain()
        try {
            synchronized(lock) {
                if (videoTrack == null) {
                    return
                }
                process(frame)
            }
        } catch (err: Throwable) {
            android.util.Log.e(TAG, "process failed", err)
        } finally {
            frame.release()
            busy.set(false)
        }
    }

    private fun process(frame: VideoFrame) {
        val path = modelPath ?: return
        val i420 = frame.buffer.toI420() ?: return
        try {
            val rotation = frame.rotation
            val srcW = i420.width
            val srcH = i420.height
            val rotatedW = if (rotation == 90 || rotation == 270) srcH else srcW
            val rotatedH = if (rotation == 90 || rotation == 270) srcW else srcH
            if (rotatedW < 64 || rotatedH < 64) {
                return
            }
            if (sessionW != rotatedW || sessionH != rotatedH) {
                val rc = MagicSrNative.init(rotatedW, rotatedH, path)
                if (rc != 0) {
                    logFail("init rc=$rc ${rotatedW}x$rotatedH model=$path")
                    return
                }
                sessionW = rotatedW
                sessionH = rotatedH
                failLogCount = 0
                val outW = (rotatedW * 3 + 1) / 2
                val outH = (rotatedH * 3 + 1) / 2
                if (outArgb.size < outW * outH) {
                    outArgb = IntArray(outW * outH)
                }
                textureEntry?.surfaceTexture()?.setDefaultBufferSize(outW, outH)
                android.util.Log.i(TAG, "session ${rotatedW}x$rotatedH -> ${outW}x$outH")
            }
            val outSize = intArrayOf(0, 0)
            val rc = MagicSrNative.processI420(
                i420.dataY,
                i420.strideY,
                i420.dataY.position(),
                i420.dataU,
                i420.strideU,
                i420.dataU.position(),
                i420.dataV,
                i420.strideV,
                i420.dataV.position(),
                srcW,
                srcH,
                rotation,
                outArgb,
                outSize,
            )
            if (rc != 0) {
                logFail("process rc=$rc")
                return
            }
            val outW = outSize[0]
            val outH = outSize[1]
            if (outW != lastOutW || outH != lastOutH) {
                lastOutW = outW
                lastOutH = outH
                mainHandler.post {
                    channel.invokeMethod(
                        "onOutputSize",
                        mapOf("width" to outW, "height" to outH),
                    )
                }
            }
            draw(outW, outH)
        } finally {
            i420.release()
        }
    }

    private fun logFail(detail: String) {
        failLogCount++
        if (failLogCount <= 3 || failLogCount % 30 == 0) {
            android.util.Log.e(TAG, "$detail count=$failLogCount")
        }
        if (failLogCount == 1) {
            mainHandler.post {
                channel.invokeMethod("srFailed", mapOf("message" to detail))
            }
        }
    }

    private fun draw(width: Int, height: Int) {
        val surf = surface ?: return
        if (!surf.isValid) return
        var bmp = bitmap
        if (bmp == null || bmp.width != width || bmp.height != height) {
            bmp?.recycle()
            bmp = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            bitmap = bmp
        }
        bmp.setPixels(outArgb, 0, width, 0, 0, width, height)
        val canvas: Canvas = try {
            surf.lockHardwareCanvas()
        } catch (_: Exception) {
            surf.lockCanvas(null) ?: return
        }
        try {
            canvas.drawBitmap(bmp, null, Rect(0, 0, canvas.width, canvas.height), paint)
        } finally {
            surf.unlockCanvasAndPost(canvas)
        }
    }

    companion object {
        private const val TAG = "MagicSr"
        private const val COMBINED_MODEL = "magic_sr_gpu_params.bin"
        private const val MIN_COMBINED_BYTES = 3_000_000L
    }
}
