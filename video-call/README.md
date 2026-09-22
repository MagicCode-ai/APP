# 1-to-1 real-time video calling (Flutter + LiveKit)

The Android / iOS / iPadOS clients use WebRTC under the hood. Each side connects to a **LiveKit SFU**:

`sender camera → local token service issues a JWT → LiveKit forwards RTP → receiver`

Resolution is locked to **1280x720**, with a 1.8 Mbps encode cap. Optionally enable sender-side `libmc_streaming` to save bitrate, and receiver-side MagicSR super-resolution.

This repo is set up for a **LAN** only. The sample token URL is `http://192.168.1.8:3000` — replace it with this computer’s current LAN IP.

## License

- App source, `server/`, `scripts/`, and `infra/`: **MIT** (see `LICENSE`)
- The `.a` libraries, public headers, and super-resolution model in `third_party/mc_streaming/` and `third_party/magic_sr/`: **proprietary closed-source binaries, not MIT** (see `NOTICE`)

## Layout

```
video-call/
  app/                 Flutter client
  server/              Token API (issues JWTs only)
  infra/               LAN LiveKit config
  scripts/             bootstrap.sh / dev.sh
  third_party/         Prebuilt libmc_streaming, libmagic_sr, and SR model
```

## Local dependencies

```bash
chmod +x scripts/*.sh
./scripts/bootstrap.sh
```

You need:

- Flutter SDK (can be installed to `~/flutter` and added to `PATH`)
- Android Studio / NDK (Android builds)
- Xcode (iOS builds)
- Node.js, Go, and a LiveKit server (`bootstrap.sh` prepares the last two)

## Start the LAN servers

```bash
./scripts/dev.sh
```

The terminal prints the LAN IP, for example:

- LiveKit: `ws://192.168.1.8:7880`
- Token service: `http://192.168.1.8:3000`

Both phones must be on the same Wi‑Fi as the computer. **Do not use `127.0.0.1` on a real device.**

The keys in `infra/livekit.yaml` and `.env.example` are local demo secrets. Replace them with your own random keys before going online, and do not bake them into the app.

## Run the client

```bash
cd app
export PATH="$HOME/flutter/bin:$PATH"
flutter pub get
flutter run --dart-define=TOKEN_URL=http://<LAN-IP>:3000
```

On the join screen, both sides enter the **same room name and different display names**. A third person joining the same room gets `409` (room full).

### iOS signing

The open-source package uses the sample bundle ID `com.example.videocall` and an empty `DEVELOPMENT_TEAM`. Pick your own Team in Xcode and trust the developer certificate when prompted:

1. `open app/ios/Runner.xcworkspace` (or `Runner.xcodeproj`)
2. Runner → Signing & Capabilities → Automatically manage signing
3. Choose your personal or company team (do not ship the empty sample values from this repo)

### Native libraries

- Android links `third_party/mc_streaming` and `third_party/magic_sr` through JNI
- iOS links the same libraries from `Debug.xcconfig` / `Release.xcconfig`; `libmagic_sr.a` needs `-force_load`
- The Android build copies a patched `SimulcastVideoEncoderFactoryWrapper.kt` into the `flutter_webrtc` pub-cache so H.264 encode output goes through `libmc_streaming` (the original file is Apache 2.0)

## Token API

`POST /token`

```json
{ "roomName": "room-1", "identity": "alice" }
```

Success:

```json
{ "url": "ws://192.168.1.8:7880", "token": "...", "roomName": "room-1", "identity": "alice" }
```

Returns `409` when the room already has 2 participants and the identity is not one of them.
