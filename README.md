# 1对1 实时视频通话（Flutter + LiveKit）

Android / iOS / iPadOS 客户端底层走 WebRTC。两端各自和 **LiveKit SFU** 建连：

`发送端摄像头 → 本机 Token 服务签发 JWT → LiveKit 服务器转发 RTP → 接收端`

分辨率锁定 **1280x720**，编码上限 1.8 Mbps。可选打开发送端 `libmc_streaming` 省流，以及接收端 MagicSR 超分。

本仓库默认只跑**局域网**。Token 示例地址是 `http://192.168.1.8:3000`，请改成你电脑当前的局域网 IP。

## 许可

- 应用源码、`server/`、`scripts/`、`infra/`：**MIT**（见 `LICENSE`）
- `third_party/mc_streaming/` 与 `third_party/magic_sr/` 里的 `.a`、公开头文件、超分模型：**专有闭源二进制，不是 MIT**（见 `NOTICE`）

## 目录

```
video-call/
  app/                 Flutter 客户端
  server/              Token API（只签发 JWT）
  infra/               局域网 LiveKit 配置
  scripts/             bootstrap.sh / dev.sh
  third_party/         预编译 libmc_streaming、libmagic_sr 和超分模型
```

## 本机依赖

```bash
chmod +x scripts/*.sh
./scripts/bootstrap.sh
```

需要：

- Flutter SDK（可装到 `~/flutter` 并加入 PATH）
- Android Studio / NDK（打 Android 包）
- Xcode（打 iOS 包）
- Node.js、Go、LiveKit server（`bootstrap.sh` 会准备后两项）

## 启动局域网服务器

```bash
./scripts/dev.sh
```

终端会打印局域网 IP，例如：

- LiveKit：`ws://192.168.1.8:7880`
- Token 服务：`http://192.168.1.8:3000`

两台手机必须和电脑同一 Wi‑Fi。**真机不要填 `127.0.0.1`。**

`infra/livekit.yaml` 和 `.env.example` 里的密钥只用于本机演示，上线前请换成自己的随机密钥，且不要写进 App。

## 跑客户端

```bash
cd app
export PATH="$HOME/flutter/bin:$PATH"
flutter pub get
flutter run --dart-define=TOKEN_URL=http://<电脑局域网IP>:3000
```

加入页两端填**相同房间名、不同显示名**。第三人进同一房间会收到 409「房间已满」。

### iOS 签名

开源包使用示例 Bundle ID `com.example.videocall`，`DEVELOPMENT_TEAM` 为空。请在 Xcode 里选你自己的 Team，并按系统提示信任开发者证书：

1. `open app/ios/Runner.xcworkspace`（或 `Runner.xcodeproj`）
2. Runner → Signing & Capabilities → Automatically manage signing
3. Team 选个人或公司团队（不要使用仓库里的空示例值直接上架）

### 原生库

- Android 通过 JNI 链接 `third_party/mc_streaming` 与 `third_party/magic_sr`
- iOS 在 `Debug.xcconfig` / `Release.xcconfig` 里链接同样的库；`libmagic_sr.a` 需要 `-force_load`
- Android 构建会把一份修改过的 `SimulcastVideoEncoderFactoryWrapper.kt` 拷进 `flutter_webrtc` 的 pub-cache，以便 H.264 编码结果进入 `libmc_streaming`（该文件原授权为 Apache 2.0）

## Token API

`POST /token`

```json
{ "roomName": "room-1", "identity": "alice" }
```

成功：

```json
{ "url": "ws://192.168.1.8:7880", "token": "...", "roomName": "room-1", "identity": "alice" }
```

房间已有 2 人且 identity 不是其中之一时返回 `409`。
