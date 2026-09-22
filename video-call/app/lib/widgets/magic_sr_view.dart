import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:livekit_client/livekit_client.dart';

const _kChannel = MethodChannel('video_call/magic_sr');

/// 远端视频：native MagicSR 1.5× 超分后用 Flutter Texture 显示。
class MagicSrView extends StatefulWidget {
  const MagicSrView({
    super.key,
    required this.track,
    this.fit = VideoViewFit.cover,
  });

  final VideoTrack track;
  final VideoViewFit fit;

  @override
  State<MagicSrView> createState() => _MagicSrViewState();
}

class _MagicSrViewState extends State<MagicSrView> {
  int? _textureId;
  String? _error;
  double _outW = 1440;
  double _outH = 810;

  String? get _trackId => widget.track.mediaStreamTrack.id;

  @override
  void initState() {
    super.initState();
    _kChannel.setMethodCallHandler(_onNative);
    _start();
  }

  @override
  void didUpdateWidget(MagicSrView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track.mediaStreamTrack.id != widget.track.mediaStreamTrack.id) {
      _restart();
    }
  }

  @override
  void dispose() {
    _kChannel.setMethodCallHandler(null);
    _stop();
    super.dispose();
  }

  Future<dynamic> _onNative(MethodCall call) async {
    if (call.method == 'onOutputSize') {
      final args = call.arguments;
      if (args is Map) {
        final w = (args['width'] as num?)?.toDouble();
        final h = (args['height'] as num?)?.toDouble();
        if (w != null && h != null && w > 0 && h > 0 && mounted) {
          setState(() {
            _outW = w;
            _outH = h;
          });
        }
      }
      return null;
    }
    if (call.method == 'srFailed') {
      debugPrint('MagicSR failed: ${call.arguments}');
      if (mounted) {
        setState(() => _error = '${call.arguments}');
      }
    }
    return null;
  }

  Future<void> _restart() async {
    await _stop();
    if (mounted) {
      setState(() {
        _textureId = null;
        _error = null;
      });
      await _start();
    }
  }

  Future<void> _start() async {
    if (!(Platform.isAndroid || Platform.isIOS)) {
      if (mounted) {
        setState(() => _error = 'MagicSR only runs on Android / iOS');
      }
      return;
    }
    final trackId = _trackId;
    if (trackId == null || trackId.isEmpty) {
      if (mounted) {
        setState(() => _error = 'video track id is empty');
      }
      return;
    }
    try {
      final id = await _kChannel.invokeMethod<int>('start', {
        'trackId': trackId,
      });
      if (!mounted) {
        if (id != null) {
          await _kChannel.invokeMethod<void>('stop');
        }
        return;
      }
      if (id == null) {
        setState(() => _error = 'MagicSR start returned no texture');
        return;
      }
      setState(() {
        _textureId = id;
        _error = null;
      });
    } catch (err) {
      debugPrint('MagicSR start failed: $err');
      if (mounted) {
        setState(() => _error = err.toString());
      }
    }
  }

  Future<void> _stop() async {
    try {
      await _kChannel.invokeMethod<void>('stop');
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final textureId = _textureId;
    if (textureId == null) {
      return ColoredBox(
        color: const Color(0xFF111111),
        child: Center(
          child: _error == null
              ? const CircularProgressIndicator(color: Colors.white54)
              : Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
        ),
      );
    }
    return FittedBox(
      fit: widget.fit == VideoViewFit.cover ? BoxFit.cover : BoxFit.contain,
      child: SizedBox(
        width: _outW,
        height: _outH,
        child: Texture(textureId: textureId),
      ),
    );
  }
}
