import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class TokenResponse {
  const TokenResponse({
    required this.url,
    required this.token,
    required this.roomName,
    required this.identity,
  });

  final String url;
  final String token;
  final String roomName;
  final String identity;

  factory TokenResponse.fromJson(Map<String, dynamic> json) {
    return TokenResponse(
      url: json['url'] as String,
      token: json['token'] as String,
      roomName: json['roomName'] as String? ?? '',
      identity: json['identity'] as String? ?? '',
    );
  }
}

class RoomFullException implements Exception {
  @override
  String toString() => '房间已满，仅支持 1 对 1 通话';
}

class TokenConnectException implements Exception {
  TokenConnectException(this.baseUrl, this.cause);

  final String baseUrl;
  final Object cause;

  @override
  String toString() {
    return '连不上 Token 服务 $baseUrl\n'
        '$cause\n'
        '请确认设备和电脑在同一 Wi-Fi，并到「设置 → 隐私与安全性 → 本地网络」打开「视频通话」。';
  }
}

class TokenApi {
  TokenApi(this.baseUrl);

  final String baseUrl;

  Future<TokenResponse> createToken({
    required String roomName,
    required String identity,
  }) async {
    final parsed = Uri.parse(
      baseUrl.endsWith('/') ? '${baseUrl}token' : '$baseUrl/token',
    );

    late final http.Response response;
    try {
      response = await http
          .post(
            parsed,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'roomName': roomName,
              'identity': identity,
            }),
          )
          .timeout(const Duration(seconds: 10));
    } on http.ClientException catch (err) {
      throw TokenConnectException(baseUrl, err);
    } on TimeoutException catch (err) {
      throw TokenConnectException(baseUrl, err);
    }

    if (response.statusCode == 409) {
      throw RoomFullException();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      String message = '获取 token 失败 (${response.statusCode})';
      try {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        message = body['error'] as String? ?? message;
      } catch (_) {}
      throw Exception(message);
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return TokenResponse.fromJson(body);
  }
}
