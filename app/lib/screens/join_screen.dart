import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import '../config.dart';
import '../services/call_session.dart';
import '../services/magic_streaming.dart';
import '../services/token_api.dart';
import 'call_screen.dart';

String _defaultIdentity() {
  final suffix = Random().nextInt(900) + 100;
  if (Platform.isAndroid) {
    return 'android-$suffix';
  }
  if (Platform.isIOS) {
    return 'ios-$suffix';
  }
  return 'user-$suffix';
}

class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key});

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  final _identityController = TextEditingController(
    text: kJoinIdentity.isEmpty ? _defaultIdentity() : kJoinIdentity,
  );
  final _roomController = TextEditingController(
    text: kJoinRoom.isEmpty ? 'room-1' : kJoinRoom,
  );
  late final TextEditingController _tokenUrlController = TextEditingController(
    text: tokenApiUrlFromEnvironment(),
  );
  bool _joining = false;
  bool _magicStreaming = kAutoJoin ? kAutoMagicStreaming : false;
  int _autoCycle = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (kAutoJoin) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_joining) {
          _runAutoJoins();
        }
      });
    }
  }

  @override
  void dispose() {
    _identityController.dispose();
    _roomController.dispose();
    _tokenUrlController.dispose();
    super.dispose();
  }

  Future<void> _runAutoJoins() async {
    final cycles = kAutoCycles < 1 ? 1 : kAutoCycles;
    for (var i = 0; i < cycles && mounted; i++) {
      _autoCycle = i;
      if (cycles > 1) {
        _magicStreaming =
            (i % 2 == 0) ? kAutoMagicStreaming : !kAutoMagicStreaming;
      }
      await _join();
      if (i + 1 < cycles && mounted) {
        await Future<void>.delayed(const Duration(seconds: 3));
      }
    }
    if (kAutoJoin && cycles > 1) {
      exit(0);
    }
  }

  Future<void> _join() async {
    final identity = _identityController.text.trim();
    final roomName = _roomController.text.trim();
    final tokenUrl = _tokenUrlController.text.trim();
    if (identity.isEmpty || roomName.isEmpty || tokenUrl.isEmpty) {
      setState(() => _error = '显示名、房间名、Token 服务地址都不能为空');
      return;
    }

    setState(() {
      _joining = true;
      _error = null;
    });

    final session = CallSession();
    session.statsCycle = _autoCycle;
    session.statsMagic = _magicStreaming;
    try {
      await MagicStreamingControl.setEnabled(_magicStreaming);
      final token = await TokenApi(tokenUrl).createToken(
        roomName: roomName,
        identity: identity,
      );
      await session.connect(url: token.url, token: token.token);
      if (!mounted) {
        await session.disconnect();
        session.dispose();
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => CallScreen(
            session: session,
            roomName: roomName,
            identity: identity,
            magicStreaming: _magicStreaming,
          ),
        ),
      );
      await session.disconnect();
      session.dispose();
    } on RoomFullException catch (err) {
      session.dispose();
      setState(() => _error = err.toString());
    } catch (err) {
      await session.disconnect();
      session.dispose();
      setState(() => _error = err.toString());
    } finally {
      if (mounted) {
        setState(() => _joining = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('1对1 视频通话')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              '两端必须用不同显示名。默认已经按设备生成，不要都改成同一个。',
              style: TextStyle(height: 1.4, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _identityController,
              decoration: const InputDecoration(
                labelText: '显示名',
                hintText: '两端不要用同一个名字',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _roomController,
              decoration: const InputDecoration(
                labelText: '房间名',
                hintText: '两端填相同房间即可通话',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tokenUrlController,
              enabled: !_joining,
              decoration: const InputDecoration(
                labelText: 'Token 服务地址',
                hintText: 'http://<电脑局域网IP>:3000',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('发送端省流 (magic_streaming)'),
              subtitle: const Text('默认关闭。打开后在硬编 H.264 码流上做码率优化，加入前设置。'),
              value: _magicStreaming,
              onChanged: _joining
                  ? null
                  : (value) => setState(() => _magicStreaming = value),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _joining ? null : _join,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(_joining ? '连接中…' : '加入通话'),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 24),
            const Text(
              '默认使用局域网 Token 服务。请把地址改成电脑当前局域网 IP。两端房间名要相同，显示名必须不同。',
              style: TextStyle(color: Colors.white70, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
