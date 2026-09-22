import 'package:flutter/services.dart';

const _kChannel = MethodChannel('video_call/magic_streaming');

const kAutoJoin = bool.fromEnvironment('AUTO_JOIN');
const kAutoMagicStreaming = bool.fromEnvironment('MAGIC_STREAMING');
const kAutoHangupSec = int.fromEnvironment('AUTO_HANGUP_SEC', defaultValue: 0);
const kAutoCycles = int.fromEnvironment('AUTO_CYCLES', defaultValue: 1);
const kRecvOnly = bool.fromEnvironment('RECV_ONLY');
const kJoinIdentity = String.fromEnvironment('IDENTITY');
const kJoinRoom = String.fromEnvironment('ROOM', defaultValue: 'room-1');

class MagicStreamingControl {
  static Future<void> setEnabled(bool enabled) {
    return _kChannel.invokeMethod<void>('setEnabled', enabled);
  }

  static Future<void> log(String line) {
    return _kChannel.invokeMethod<void>('log', line);
  }
}
