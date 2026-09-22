package com.videocall.video_call

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MagicStreamingPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "video_call/magic_streaming")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setEnabled" -> {
                MagicStreamingVideoEncoder.setEnabled(call.arguments as? Boolean ?: false)
                result.success(null)
            }
            "isEnabled" -> result.success(MagicStreamingVideoEncoder.isEnabled())
            "log" -> {
                val line = call.arguments as? String
                if (!line.isNullOrEmpty()) {
                    android.util.Log.i("CallStats", line)
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
