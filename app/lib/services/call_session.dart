import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';

import 'magic_streaming.dart';

/// 1280x720 @ 30fps，编码上限 1.8 Mbps。关闭自适应/多层码流。
const VideoParameters kVideo1280x720 = VideoParameters(
  dimensions: VideoDimensions(1280, 720),
  encoding: VideoEncoding(
    maxBitrate: 1800 * 1000,
    maxFramerate: 30,
  ),
);

RoomOptions buildRoomOptions() {
  return RoomOptions(
    adaptiveStream: false,
    dynacast: false,
    defaultCameraCaptureOptions: const CameraCaptureOptions(
      cameraPosition: CameraPosition.front,
      maxFrameRate: 30,
      params: kVideo1280x720,
    ),
    defaultVideoPublishOptions: VideoPublishOptions(
      simulcast: false,
      videoCodec: 'h264',
      videoEncoding: kVideo1280x720.encoding,
      backupVideoCodec: const BackupVideoCodec(
        enabled: false,
        simulcast: false,
      ),
    ),
  );
}

class CallSession extends ChangeNotifier {
  Room? _room;
  EventsListener<RoomEvent>? _listener;
  Timer? _statsTimer;
  int? _prevRxBytes;
  double? _prevRxTimestamp;
  int? _prevTxBytes;
  double? _prevTxTimestamp;
  int? _prevPacketsSent;
  int? _prevPacketsLostTx;
  int? _prevPacketsReceived;
  int? _prevPacketsLostRx;
  int? _prevNackTx;
  int? _prevNackRx;
  int? _prevFreezeCount;
  double? _prevFreezeDurationSec;
  int? _prevFramesDropped;
  int? _prevPli;
  double? _prevTotalEncodeTimeSec;
  int? _prevFramesEncoded;
  DateTime? _prevStatsAt;
  bool micEnabled = false;
  bool cameraEnabled = true;
  bool connecting = false;
  bool disconnected = false;
  String? errorMessage;
  String? peerLeftMessage;
  int? rttMs;
  int? receiveKbps;
  int? sendKbps;
  int? bweKbps;
  int? targetKbps;
  double? txLossPct;
  double? rxLossPct;
  int? nackTxPerSec;
  int? nackRxPerSec;
  int? freezePerSec;
  int? freezeMsPerSec;
  int freezeLargeCount = 0;
  int? freezeLargePerSec;
  int? recvFps;
  int? jitterMs;
  int? framesDroppedPerSec;
  int? pliPerSec;
  double? encodeMsPerFrame;
  String? qualityLimitation;
  int statsCycle = 0;
  bool statsMagic = false;

  Room? get room => _room;

  LocalParticipant? get localParticipant => _room?.localParticipant;

  RemoteParticipant? get remoteParticipant {
    final participants = _room?.remoteParticipants.values;
    if (participants == null || participants.isEmpty) {
      return null;
    }
    return participants.first;
  }

  VideoTrack? get localVideoTrack {
    final pubs = localParticipant?.videoTrackPublications;
    if (pubs == null || pubs.isEmpty) {
      return null;
    }
    return pubs.first.track;
  }

  VideoTrack? get remoteVideoTrack {
    final participant = remoteParticipant;
    if (participant == null) {
      return null;
    }
    for (final pub in participant.videoTrackPublications) {
      if (pub.track != null) {
        return pub.track;
      }
    }
    return null;
  }

  VideoDimensions? get _localDimensions =>
      localParticipant?.videoTrackPublications.firstOrNull?.dimensions;

  VideoDimensions? get _remoteDimensions =>
      remoteParticipant?.videoTrackPublications.firstOrNull?.dimensions;

  String get localResolutionLabel {
    final dims = _localDimensions;
    if (dims == null) {
      return '采集目标 720x960';
    }
    return '本地 ${dims.width}x${dims.height}';
  }

  String get remoteResolutionLabel {
    final dims = _remoteDimensions;
    if (dims == null) {
      return '等待对方视频';
    }
    return '远端 ${dims.width}x${dims.height}';
  }

  String get rttLabel {
    if (rttMs == null) {
      return 'RTT --';
    }
    if (rttMs == 0) {
      return 'RTT <1ms';
    }
    return 'RTT ${rttMs}ms';
  }

  String get receiveBitrateLabel {
    final kbps = receiveKbps;
    if (kbps == null) {
      return '收 --';
    }
    return '收 ${_formatKbps(kbps)}';
  }

  String get sendBitrateLabel {
    final kbps = sendKbps;
    if (kbps == null) {
      return '发 --';
    }
    return '发 ${_formatKbps(kbps)}';
  }

  String get bweLabel {
    final kbps = bweKbps;
    if (kbps == null) {
      return 'BWE --';
    }
    return 'BWE ${_formatKbps(kbps)}';
  }

  String get targetBitrateLabel {
    final kbps = targetKbps;
    if (kbps == null) {
      return '目标 --';
    }
    return '目标 ${_formatKbps(kbps)}';
  }

  String get lossLabel {
    return '丢包 发 ${_formatPct(txLossPct)}  收 ${_formatPct(rxLossPct)}';
  }

  String get nackLabel {
    final tx = nackTxPerSec;
    final rx = nackRxPerSec;
    return 'NACK 发 ${tx == null ? "--" : "$tx/s"}  收 ${rx == null ? "--" : "$rx/s"}';
  }

  String get freezeLabel {
    final n = freezePerSec;
    final ms = freezeMsPerSec;
    final fps = recvFps;
    final jitter = jitterMs;
    return '卡顿 ${n == null ? "--" : "$n/s"} ${ms == null ? "" : "${ms}ms"}  '
        '大卡顿 $freezeLargeCount  '
        'fps ${fps ?? "--"}  jitter ${jitter == null ? "--" : "${jitter}ms"}';
  }

  String get scoreLabel {
    final local = _qualityShort(localParticipant?.connectionQuality);
    final remote = _qualityShort(remoteParticipant?.connectionQuality);
    return 'Score 本$local 对$remote';
  }

  String? get limitationLabel {
    final reason = qualityLimitation;
    if (reason == null || reason.isEmpty || reason == 'none') {
      return null;
    }
    const names = {
      'bandwidth': '带宽',
      'cpu': 'CPU',
      'other': '其他',
    };
    return '编码受限 ${names[reason] ?? reason}';
  }

  static String _formatKbps(int kbps) {
    if (kbps >= 1000) {
      return '${(kbps / 1000).toStringAsFixed(2)} Mbps';
    }
    return '$kbps kbps';
  }

  static String _formatPct(double? value) {
    if (value == null) {
      return '--';
    }
    return '${value.toStringAsFixed(1)}%';
  }

  static String _qualityShort(ConnectionQuality? quality) {
    switch (quality) {
      case ConnectionQuality.excellent:
        return '优';
      case ConnectionQuality.good:
        return '良';
      case ConnectionQuality.poor:
        return '差';
      case ConnectionQuality.lost:
        return '断';
      case ConnectionQuality.unknown:
      case null:
        return '--';
    }
  }

  Future<void> connect({
    required String url,
    required String token,
  }) async {
    errorMessage = null;
    peerLeftMessage = null;
    disconnected = false;
    connecting = true;
    notifyListeners();

    try {
      await _ensurePermissions();
      await _room?.disconnect();
      await _room?.dispose();
      _listener?.dispose();

      final options = buildRoomOptions();
      final room = Room(roomOptions: options);
      _bindRoom(room);
      await room.connect(url, token);

      try {
        if (kRecvOnly) {
          await room.localParticipant?.setCameraEnabled(false);
        } else {
          await room.localParticipant?.setCameraEnabled(true);
        }
      } catch (err) {
        debugPrint('开启摄像头失败（模拟器常见）: $err');
      }
      await room.localParticipant?.setMicrophoneEnabled(false);
      cameraEnabled = room.localParticipant?.isCameraEnabled() ?? !kRecvOnly;
      micEnabled = room.localParticipant?.isMicrophoneEnabled() ?? false;
    } catch (err) {
      errorMessage = err.toString();
      await disconnect();
      rethrow;
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  Future<void> toggleMic() async {
    final participant = localParticipant;
    if (participant == null) {
      return;
    }
    micEnabled = !micEnabled;
    await participant.setMicrophoneEnabled(micEnabled);
    notifyListeners();
  }

  Future<void> toggleCamera() async {
    final participant = localParticipant;
    if (participant == null) {
      return;
    }
    cameraEnabled = !cameraEnabled;
    await participant.setCameraEnabled(cameraEnabled);
    notifyListeners();
  }

  Future<void> switchCamera() async {
    final track = localVideoTrack;
    if (track is! LocalVideoTrack) {
      return;
    }
    try {
      final options = track.currentOptions;
      final current = options is CameraCaptureOptions
          ? options.cameraPosition
          : CameraPosition.front;
      await track.setCameraPosition(
        current == CameraPosition.front
            ? CameraPosition.back
            : CameraPosition.front,
      );
    } catch (err) {
      debugPrint('切换摄像头失败: $err');
    }
    notifyListeners();
  }

  Future<void> disconnect() async {
    _stopStats();
    _listener?.dispose();
    _listener = null;
    try {
      await _room?.disconnect();
    } catch (_) {}
    try {
      await _room?.dispose();
    } catch (_) {}
    _room = null;
    notifyListeners();
  }

  void _bindRoom(Room room) {
    _room = room;
    room.addListener(notifyListeners);
    _startStats();
    _listener = room.createListener()
      ..on<RoomDisconnectedEvent>((event) {
        _stopStats();
        disconnected = true;
        errorMessage = event.reason == DisconnectReason.duplicateIdentity
            ? '显示名与对方重复，已被踢出。请换一个名字再进。'
            : '已断开：${event.reason?.name ?? "未知原因"}';
        notifyListeners();
      })
      ..on<ParticipantConnectedEvent>((_) {
        peerLeftMessage = null;
        notifyListeners();
      })
      ..on<ParticipantDisconnectedEvent>((event) {
        peerLeftMessage = '${event.participant.identity} 已离开';
        notifyListeners();
      })
      ..on<TrackSubscribedEvent>((_) {
        notifyListeners();
      })
      ..on<TrackUnsubscribedEvent>((_) {
        if (remoteVideoTrack == null) {
          receiveKbps = null;
          rxLossPct = null;
          nackRxPerSec = null;
          freezePerSec = null;
          freezeMsPerSec = null;
          recvFps = null;
          jitterMs = null;
          framesDroppedPerSec = null;
          pliPerSec = null;
          _prevRxBytes = null;
          _prevRxTimestamp = null;
          _prevPacketsReceived = null;
          _prevPacketsLostRx = null;
          _prevNackRx = null;
          _prevFreezeCount = null;
          _prevFreezeDurationSec = null;
          _prevFramesDropped = null;
          _prevPli = null;
        }
        notifyListeners();
      })
      ..on<ParticipantConnectionQualityUpdatedEvent>((_) {
        notifyListeners();
      });
  }

  void _startStats() {
    _statsTimer?.cancel();
    _resetStatCounters();
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_pollStats());
    });
    unawaited(_pollStats());
  }

  void _stopStats() {
    _statsTimer?.cancel();
    _statsTimer = null;
    _resetStatCounters();
  }

  void _resetStatCounters() {
    _prevRxBytes = null;
    _prevRxTimestamp = null;
    _prevTxBytes = null;
    _prevTxTimestamp = null;
    _prevPacketsSent = null;
    _prevPacketsLostTx = null;
    _prevPacketsReceived = null;
    _prevPacketsLostRx = null;
    _prevNackTx = null;
    _prevNackRx = null;
    _prevStatsAt = null;
    rttMs = null;
    receiveKbps = null;
    sendKbps = null;
    bweKbps = null;
    targetKbps = null;
    txLossPct = null;
    rxLossPct = null;
    nackTxPerSec = null;
    nackRxPerSec = null;
    freezePerSec = null;
    freezeMsPerSec = null;
    freezeLargeCount = 0;
    freezeLargePerSec = null;
    recvFps = null;
    jitterMs = null;
    framesDroppedPerSec = null;
    pliPerSec = null;
    qualityLimitation = null;
    _prevFreezeCount = null;
    _prevFreezeDurationSec = null;
    _prevFramesDropped = null;
    _prevPli = null;
    _prevTotalEncodeTimeSec = null;
    _prevFramesEncoded = null;
    encodeMsPerFrame = null;
  }

  Future<void> _pollStats() async {
    if (_room == null) {
      return;
    }
    try {
      final snapshot = await _readRtcSnapshot();
      final now = DateTime.now();
      final elapsed = _prevStatsAt == null
          ? 1.0
          : now.difference(_prevStatsAt!).inMilliseconds / 1000.0;
      final dt = elapsed <= 0 ? 1.0 : elapsed;
      _prevStatsAt = now;

      rttMs = snapshot.rttMs ?? rttMs;
      bweKbps = snapshot.availableOutgoingBps == null
          ? bweKbps
          : (snapshot.availableOutgoingBps! / 1000).round();
      targetKbps = snapshot.targetBps == null
          ? targetKbps
          : (snapshot.targetBps! / 1000).round();
      qualityLimitation = snapshot.qualityLimitation ?? qualityLimitation;

      sendKbps = _bitrateFromDelta(
            snapshot.bytesSent,
            snapshot.timestamp,
            _prevTxBytes,
            _prevTxTimestamp,
          ) ??
          sendKbps;
      receiveKbps = _bitrateFromDelta(
            snapshot.bytesReceived,
            snapshot.timestamp,
            _prevRxBytes,
            _prevRxTimestamp,
          ) ??
          receiveKbps;
      if (snapshot.bytesSent != null && snapshot.timestamp != null) {
        _prevTxBytes = snapshot.bytesSent;
        _prevTxTimestamp = snapshot.timestamp;
      }
      if (snapshot.bytesReceived != null && snapshot.timestamp != null) {
        _prevRxBytes = snapshot.bytesReceived;
        _prevRxTimestamp = snapshot.timestamp;
      }

      txLossPct = _txLossPct(
            snapshot.packetsLostTx,
            snapshot.packetsSent,
            _prevPacketsLostTx,
            _prevPacketsSent,
          ) ??
          _fractionToPct(snapshot.txFractionLost) ??
          txLossPct;
      rxLossPct = _rxLossPct(
            snapshot.packetsLostRx,
            snapshot.packetsReceived,
            _prevPacketsLostRx,
            _prevPacketsReceived,
          ) ??
          rxLossPct;
      if (snapshot.packetsSent != null) {
        _prevPacketsSent = snapshot.packetsSent;
      }
      if (snapshot.packetsLostTx != null) {
        _prevPacketsLostTx = snapshot.packetsLostTx;
      }
      if (snapshot.packetsReceived != null) {
        _prevPacketsReceived = snapshot.packetsReceived;
      }
      if (snapshot.packetsLostRx != null) {
        _prevPacketsLostRx = snapshot.packetsLostRx;
      }

      nackTxPerSec = _perSec(snapshot.nackTx, _prevNackTx, dt) ?? nackTxPerSec;
      nackRxPerSec = _perSec(snapshot.nackRx, _prevNackRx, dt) ?? nackRxPerSec;
      freezePerSec =
          _perSec(snapshot.freezeCount, _prevFreezeCount, dt) ?? freezePerSec;
      freezeMsPerSec = _durationMsPerSec(
            snapshot.freezeDurationSec,
            _prevFreezeDurationSec,
            dt,
          ) ??
          freezeMsPerSec;
      final largeThis = _freezeLargeEvents(
        snapshot.freezeCount,
        _prevFreezeCount,
        snapshot.freezeDurationSec,
        _prevFreezeDurationSec,
      );
      freezeLargePerSec = largeThis;
      freezeLargeCount += largeThis;
      framesDroppedPerSec =
          _perSec(snapshot.framesDropped, _prevFramesDropped, dt) ??
              framesDroppedPerSec;
      pliPerSec = _perSec(snapshot.pliCount, _prevPli, dt) ?? pliPerSec;
      recvFps = snapshot.recvFps?.round() ?? recvFps;
      final dEncFrames = snapshot.framesEncoded == null || _prevFramesEncoded == null
          ? null
          : snapshot.framesEncoded! - _prevFramesEncoded!;
      final dEncTime = snapshot.totalEncodeTimeSec == null ||
              _prevTotalEncodeTimeSec == null
          ? null
          : snapshot.totalEncodeTimeSec! - _prevTotalEncodeTimeSec!;
      if (dEncFrames != null && dEncTime != null && dEncFrames > 0 && dEncTime >= 0) {
        encodeMsPerFrame = (dEncTime * 1000.0) / dEncFrames;
      }
      if (snapshot.framesEncoded != null) {
        _prevFramesEncoded = snapshot.framesEncoded;
      }
      if (snapshot.totalEncodeTimeSec != null) {
        _prevTotalEncodeTimeSec = snapshot.totalEncodeTimeSec;
      }
      jitterMs = snapshot.jitterMs ?? jitterMs;
      if (snapshot.nackTx != null) {
        _prevNackTx = snapshot.nackTx;
      }
      if (snapshot.nackRx != null) {
        _prevNackRx = snapshot.nackRx;
      }
      if (snapshot.freezeCount != null) {
        _prevFreezeCount = snapshot.freezeCount;
      }
      if (snapshot.freezeDurationSec != null) {
        _prevFreezeDurationSec = snapshot.freezeDurationSec;
      }
      if (snapshot.framesDropped != null) {
        _prevFramesDropped = snapshot.framesDropped;
      }
      if (snapshot.pliCount != null) {
        _prevPli = snapshot.pliCount;
      }

      final statsLine =
          'CallStats cycle=$statsCycle magic=${statsMagic ? 1 : 0} '
          'bwe=${bweKbps ?? "--"}k target=${targetKbps ?? "--"}k '
          'send=${sendKbps ?? "--"}k recv=${receiveKbps ?? "--"}k '
          'rtt=${rttMs ?? "--"}ms '
          'txLoss=${txLossPct == null ? "--" : txLossPct!.toStringAsFixed(2)}% '
          'rxLoss=${rxLossPct == null ? "--" : rxLossPct!.toStringAsFixed(2)}% '
          'nackTx=${nackTxPerSec ?? "--"}/s nackRx=${nackRxPerSec ?? "--"}/s '
          'freeze=${freezePerSec ?? "--"}/s freezeMs=${freezeMsPerSec ?? "--"} '
          'freezeLarge=$freezeLargeCount freezeBig=$freezeLargePerSec '
          'fps=${recvFps ?? "--"} jitter=${jitterMs ?? "--"}ms '
          'drop=${framesDroppedPerSec ?? "--"}/s pli=${pliPerSec ?? "--"}/s '
          'enc=${encodeMsPerFrame == null ? "--" : encodeMsPerFrame!.toStringAsFixed(1)}ms '
          '$scoreLabel'
          '${qualityLimitation == null || qualityLimitation == "none" ? "" : " limit=$qualityLimitation"}';
      debugPrint(statsLine);
      MagicStreamingControl.log(statsLine);

      notifyListeners();
    } catch (err) {
      debugPrint('poll stats failed: $err');
    }
  }

  static int? _bitrateFromDelta(
    int? bytes,
    double? timestamp,
    int? prevBytes,
    double? prevTs,
  ) {
    if (bytes == null || timestamp == null || prevBytes == null || prevTs == null) {
      return null;
    }
    if (bytes < prevBytes) {
      return null;
    }
    return _bitrateKbps(bytes - prevBytes, timestamp - prevTs);
  }

  static double? _txLossPct(
    int? lost,
    int? sent,
    int? prevLost,
    int? prevSent,
  ) {
    if (lost == null || sent == null || prevLost == null || prevSent == null) {
      return null;
    }
    final dLost = lost - prevLost;
    final dSent = sent - prevSent;
    if (dLost < 0 || dSent <= 0) {
      return 0;
    }
    return (dLost / dSent) * 100;
  }

  static double? _rxLossPct(
    int? lost,
    int? received,
    int? prevLost,
    int? prevReceived,
  ) {
    if (lost == null || received == null || prevLost == null || prevReceived == null) {
      return null;
    }
    final dLost = lost - prevLost;
    final dRecv = received - prevReceived;
    final denom = dLost + dRecv;
    if (dLost < 0 || denom <= 0) {
      return 0;
    }
    return (dLost / denom) * 100;
  }

  static int _freezeLargeEvents(
    int? freezeCount,
    int? prevCount,
    double? freezeDurSec,
    double? prevDurSec,
  ) {
    if (freezeCount == null ||
        prevCount == null ||
        freezeDurSec == null ||
        prevDurSec == null) {
      return 0;
    }
    var dCount = freezeCount - prevCount;
    final dDur = freezeDurSec - prevDurSec;
    if (dCount < 0 || dDur <= 0) {
      return 0;
    }
    if (dCount == 0 && dDur > 0.8) {
      dCount = 1;
    }
    if (dCount <= 0) {
      return 0;
    }
    if (dCount == 1) {
      return dDur * 1000.0 > 800.0 ? 1 : 0;
    }
    if (dDur / dCount > 0.8) {
      return dCount;
    }
    return dDur > 0.8 ? 1 : 0;
  }

  static int? _perSec(int? now, int? prev, double dt) {
    if (now == null || prev == null || dt <= 0) {
      return null;
    }
    final delta = now - prev;
    if (delta < 0) {
      return 0;
    }
    return (delta / dt).round();
  }

  static int? _durationMsPerSec(double? nowSec, double? prevSec, double dt) {
    if (nowSec == null || prevSec == null || dt <= 0) {
      return null;
    }
    final delta = nowSec - prevSec;
    if (delta < 0) {
      return 0;
    }
    return ((delta / dt) * 1000).round();
  }

  static double? _fractionToPct(double? fraction) {
    if (fraction == null || fraction < 0) {
      return null;
    }
    final ratio = fraction > 1 ? fraction / 256 : fraction;
    return ratio * 100;
  }

  Future<_RtcSnapshot> _readRtcSnapshot() async {
    final snapshot = _RtcSnapshot();
    for (final entry in _namedPeerConnections()) {
      await _fillSnapshot(snapshot, entry.pc, isPublisher: entry.isPublisher);
    }
    return snapshot;
  }

  List<_NamedPc> _namedPeerConnections() {
    final room = _room;
    if (room == null) {
      return const [];
    }
    try {
      final engine = (room as dynamic).engine;
      final pcs = <_NamedPc>[];
      final pub = engine.publisher?.pc;
      final sub = engine.subscriber?.pc;
      if (pub is rtc.RTCPeerConnection) {
        pcs.add(_NamedPc(pub, isPublisher: true));
      }
      if (sub is rtc.RTCPeerConnection) {
        pcs.add(_NamedPc(sub, isPublisher: false));
      }
      return pcs;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _fillSnapshot(
    _RtcSnapshot snapshot,
    rtc.RTCPeerConnection pc, {
    required bool isPublisher,
  }) async {
    final reports = await pc.getStats();
    String? selectedPairId;
    final pairs = <String, rtc.StatsReport>{};
    final remotes = <String, rtc.StatsReport>{};

    for (final report in reports) {
      if (report.type == 'transport') {
        selectedPairId =
            _statString(report.values, 'selectedCandidatePairId') ?? selectedPairId;
      } else if (report.type == 'candidate-pair') {
        pairs[report.id] = report;
      } else if (report.type == 'remote-inbound-rtp') {
        remotes[report.id] = report;
      }
    }

    rtc.StatsReport? selected;
    if (selectedPairId != null) {
      selected = pairs[selectedPairId];
    }
    if (selected == null) {
      for (final report in pairs.values) {
        if (_statBool(report.values, 'nominated') ||
            _statBool(report.values, 'selected')) {
          selected = report;
          break;
        }
      }
    }

    if (selected != null) {
      final rtt = _rttSecondsToMs(
        _statNum(selected.values, 'currentRoundTripTime'),
      );
      if (rtt != null && (snapshot.rttMs == null || rtt < snapshot.rttMs!)) {
        snapshot.rttMs = rtt;
      }
      final outgoing = _statNum(selected.values, 'availableOutgoingBitrate') ??
          _statNum(selected.values, 'googAvailableSendBandwidth');
      if (isPublisher && outgoing != null && outgoing > 0) {
        snapshot.availableOutgoingBps = outgoing.toDouble();
      }
    }

    for (final report in reports) {
      if (report.type != 'outbound-rtp' || !_isVideoReport(report.values)) {
        continue;
      }
      snapshot.bytesSent = _statNum(report.values, 'bytesSent')?.round();
      snapshot.packetsSent = _statNum(report.values, 'packetsSent')?.round();
      snapshot.nackTx = _statNum(report.values, 'nackCount')?.round();
      snapshot.targetBps = (_statNum(report.values, 'targetBitrate') ??
              _statNum(report.values, 'googTargetEncBitrate'))
          ?.toDouble();
      snapshot.qualityLimitation =
          _statString(report.values, 'qualityLimitationReason');
      snapshot.framesEncoded = _statNum(report.values, 'framesEncoded')?.round();
      snapshot.totalEncodeTimeSec =
          _statNum(report.values, 'totalEncodeTime')?.toDouble();
      snapshot.timestamp = report.timestamp.toDouble();

      final remoteId = _statString(report.values, 'remoteId');
      rtc.StatsReport? remote = remoteId == null ? null : remotes[remoteId];
      if (remote == null) {
        for (final item in remotes.values) {
          if (_isVideoReport(item.values)) {
            remote = item;
            break;
          }
        }
      }
      if (remote != null) {
        snapshot.packetsLostTx = _statNum(remote.values, 'packetsLost')?.round();
        final fraction = _statNum(remote.values, 'fractionLost');
        if (snapshot.packetsLostTx == null && fraction != null) {
          snapshot.txFractionLost = fraction.toDouble();
        }
        final mediaRtt = _rttSecondsToMs(
          _statNum(remote.values, 'roundTripTime'),
        );
        if (mediaRtt != null &&
            (snapshot.rttMs == null || mediaRtt < snapshot.rttMs!)) {
          snapshot.rttMs = mediaRtt;
        }
      }
    }

    for (final report in reports) {
      if (report.type != 'inbound-rtp' || !_isVideoReport(report.values)) {
        continue;
      }
      snapshot.bytesReceived = _statNum(report.values, 'bytesReceived')?.round();
      snapshot.packetsReceived =
          _statNum(report.values, 'packetsReceived')?.round();
      snapshot.packetsLostRx = _statNum(report.values, 'packetsLost')?.round();
      snapshot.nackRx = _statNum(report.values, 'nackCount')?.round();
      snapshot.freezeCount = (_statNum(report.values, 'freezeCount') ??
              _statNum(report.values, 'googFreezeCount'))
          ?.round();
      final freezeDur = _statNum(report.values, 'totalFreezesDuration');
      final freezeMs = _statNum(report.values, 'freezeDurationMs');
      if (freezeDur != null) {
        snapshot.freezeDurationSec = freezeDur.toDouble();
      } else if (freezeMs != null) {
        snapshot.freezeDurationSec = freezeMs.toDouble() / 1000.0;
      }
      snapshot.framesDropped = _statNum(report.values, 'framesDropped')?.round();
      snapshot.recvFps = _statNum(report.values, 'framesPerSecond')?.toDouble() ??
          _statNum(report.values, 'googFrameRateReceived')?.toDouble();
      final jitter = _statNum(report.values, 'jitter') ??
          _statNum(report.values, 'googJitterReceived');
      if (jitter != null) {
        snapshot.jitterMs =
            jitter > 5 ? jitter.round() : (jitter * 1000).round();
      }
      snapshot.pliCount = _statNum(report.values, 'pliCount')?.round();
      snapshot.timestamp ??= report.timestamp.toDouble();
    }
  }

  static bool _isVideoReport(Map<dynamic, dynamic> values) {
    final kind = _statString(values, 'kind') ?? _statString(values, 'mediaType');
    if (kind == 'video') {
      return true;
    }
    if (kind == 'audio') {
      return false;
    }
    return values.containsKey('frameWidth') ||
        values.containsKey('framesEncoded') ||
        values.containsKey('framesDecoded') ||
        values.containsKey('framesReceived');
  }

  static int? _rttSecondsToMs(num? value) {
    if (value == null || value < 0) {
      return null;
    }
    // WebRTC spec: currentRoundTripTime is seconds.
    final ms = (value * 1000).round();
    return ms < 1 ? 0 : ms;
  }

  static num? _statNum(Map<dynamic, dynamic> values, String key) {
    final value = values[key];
    if (value is num) {
      return value;
    }
    if (value is String) {
      return num.tryParse(value);
    }
    return null;
  }

  static String? _statString(Map<dynamic, dynamic> values, String key) {
    final value = values[key];
    return value?.toString();
  }

  static bool _statBool(Map<dynamic, dynamic> values, String key) {
    final value = values[key];
    if (value is bool) {
      return value;
    }
    if (value is String) {
      return value == 'true' || value == '1';
    }
    if (value is num) {
      return value != 0;
    }
    return false;
  }

  static int? _bitrateKbps(num deltaBytes, num deltaTimestamp) {
    if (deltaBytes < 0 || deltaTimestamp <= 0) {
      return null;
    }
    final seconds = deltaTimestamp > 100000
        ? deltaTimestamp / 1e6
        : deltaTimestamp > 20
            ? deltaTimestamp / 1000
            : deltaTimestamp.toDouble();
    if (seconds <= 0) {
      return null;
    }
    return (deltaBytes * 8 / seconds / 1000).round();
  }

  Future<void> _ensurePermissions() async {
    final permissions = <Permission>[
      Permission.camera,
      Permission.microphone,
    ];
    if (defaultTargetPlatform == TargetPlatform.android) {
      permissions.addAll([
        Permission.bluetooth,
        Permission.bluetoothConnect,
      ]);
    }
    final statuses = await permissions.request();
    final camera = statuses[Permission.camera];
    final microphone = statuses[Permission.microphone];
    if (camera != PermissionStatus.granted ||
        microphone != PermissionStatus.granted) {
      throw Exception('需要摄像头和麦克风权限才能通话');
    }
  }

  @override
  void dispose() {
    _stopStats();
    _listener?.dispose();
    _room?.removeListener(notifyListeners);
    _room?.dispose();
    super.dispose();
  }
}

class _NamedPc {
  const _NamedPc(this.pc, {required this.isPublisher});

  final rtc.RTCPeerConnection pc;
  final bool isPublisher;
}

class _RtcSnapshot {
  int? rttMs;
  double? availableOutgoingBps;
  double? targetBps;
  int? bytesSent;
  int? bytesReceived;
  int? packetsSent;
  int? packetsLostTx;
  int? packetsReceived;
  int? packetsLostRx;
  int? nackTx;
  int? nackRx;
  int? freezeCount;
  double? freezeDurationSec;
  int? framesDropped;
  double? recvFps;
  int? jitterMs;
  int? pliCount;
  int? framesEncoded;
  double? totalEncodeTimeSec;
  double? timestamp;
  double? txFractionLost;
  String? qualityLimitation;
}
