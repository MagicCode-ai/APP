# Reflection from the flutter_webrtc H.264 encoder factory hook.
-keep class com.videocall.video_call.MagicStreamingVideoEncoder {
    public <init>(org.webrtc.VideoEncoder);
    public static boolean isEnabled();
    public static void setEnabled(boolean);
}
-keepclassmembers class com.videocall.video_call.MagicStreamingVideoEncoder {
    public static boolean isEnabled();
    public static void setEnabled(boolean);
}
