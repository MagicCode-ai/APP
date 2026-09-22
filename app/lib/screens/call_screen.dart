import 'dart:async';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';

import '../services/call_session.dart';
import '../services/magic_streaming.dart';

class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    required this.session,
    required this.roomName,
    required this.identity,
    this.magicStreaming = false,
  });

  final CallSession session;
  final String roomName;
  final String identity;
  final bool magicStreaming;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  bool _handledPeerLeft = false;
  Timer? _autoHangup;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSession);
    MagicStreamingControl.log(
      'CallSession start cycle=${widget.session.statsCycle} '
      'magic=${widget.magicStreaming ? 1 : 0} identity=${widget.identity} '
      'recvOnly=$kRecvOnly',
    );
    if (kAutoHangupSec > 0) {
      _autoHangup = Timer(Duration(seconds: kAutoHangupSec), () {
        _hangUp();
      });
    }
  }

  @override
  void dispose() {
    _autoHangup?.cancel();
    widget.session.removeListener(_onSession);
    super.dispose();
  }

  void _onSession() {
    if (!mounted) {
      return;
    }
    setState(() {});
    if (widget.session.disconnected) {
      final message = widget.session.errorMessage ?? '连接已断开';
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
        Navigator.of(context).pop();
      });
      return;
    }
    final message = widget.session.peerLeftMessage;
    if (message != null && !_handledPeerLeft) {
      _handledPeerLeft = true;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _hangUp() async {
    await widget.session.disconnect();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final remoteTrack = session.remoteVideoTrack;
    final localTrack = session.localVideoTrack;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: remoteTrack != null
                  ? VideoTrackRenderer(
                      remoteTrack,
                      fit: VideoViewFit.cover,
                    )
                  : _WaitingPane(
                      remoteName: session.remoteParticipant?.identity,
                    ),
            ),
            Positioned(
              right: 16,
              top: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _PipPreview(track: localTrack),
                  const SizedBox(height: 8),
                  _Badge(text: session.localResolutionLabel),
                  const SizedBox(height: 4),
                  _Badge(text: session.remoteResolutionLabel),
                ],
              ),
            ),
            Positioned(
              left: 16,
              top: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Badge(text: '${widget.roomName} · ${widget.identity}'),
                  const SizedBox(height: 6),
                  _Badge(
                    text: widget.magicStreaming ? '省流 开' : '省流 关',
                  ),
                  const SizedBox(height: 6),
                  _Badge(text: '${session.bweLabel}  ·  ${session.targetBitrateLabel}'),
                  const SizedBox(height: 6),
                  _Badge(text: '${session.sendBitrateLabel}  ·  ${session.receiveBitrateLabel}'),
                  const SizedBox(height: 6),
                  _Badge(text: '${session.rttLabel}  ·  ${session.lossLabel}'),
                  const SizedBox(height: 6),
                  _Badge(text: '${session.nackLabel}  ·  ${session.scoreLabel}'),
                  const SizedBox(height: 6),
                  _Badge(text: session.freezeLabel),
                  if (session.limitationLabel != null) ...[
                    const SizedBox(height: 6),
                    _Badge(text: session.limitationLabel!),
                  ],
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _RoundButton(
                    icon: session.micEnabled ? Icons.mic : Icons.mic_off,
                    label: session.micEnabled ? '静音' : '解除静音',
                    onPressed: session.toggleMic,
                  ),
                  _RoundButton(
                    icon: session.cameraEnabled
                        ? Icons.videocam
                        : Icons.videocam_off,
                    label: session.cameraEnabled ? '关摄像头' : '开摄像头',
                    onPressed: session.toggleCamera,
                  ),
                  _RoundButton(
                    icon: Icons.cameraswitch,
                    label: '翻转',
                    onPressed: session.switchCamera,
                  ),
                  _RoundButton(
                    icon: Icons.call_end,
                    label: '挂断',
                    color: Colors.red,
                    onPressed: _hangUp,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WaitingPane extends StatelessWidget {
  const _WaitingPane({this.remoteName});

  final String? remoteName;

  @override
  Widget build(BuildContext context) {
    final joined = remoteName != null && remoteName!.isNotEmpty;
    return ColoredBox(
      color: const Color(0xFF111111),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.hourglass_empty, color: Colors.white70, size: 48),
            const SizedBox(height: 12),
            Text(
              joined ? '$remoteName 已加入，等待视频' : '等待对方加入',
              style: const TextStyle(color: Colors.white, fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(
              joined
                  ? '对方可能未开摄像头'
                  : '两端房间名要相同，显示名必须不同',
              style: const TextStyle(color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }
}

class _PipPreview extends StatelessWidget {
  const _PipPreview({required this.track});

  final VideoTrack? track;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 120,
        height: 160,
        color: Colors.black54,
        child: track == null
            ? const Center(
                child: Icon(Icons.person, color: Colors.white54),
              )
            : VideoTrackRenderer(
                track!,
                fit: VideoViewFit.cover,
                mirrorMode: VideoViewMirrorMode.mirror,
              ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white, fontSize: 11),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: CircleAvatar(
            radius: 26,
            backgroundColor: color ?? const Color(0xFF2C2C2C),
            child: Icon(icon, color: Colors.white),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }
}
