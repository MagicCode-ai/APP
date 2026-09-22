#!/usr/bin/env bash
# Download local tools: Node, Go, LiveKit server. Install Flutter yourself (e.g. ~/flutter).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/.tools"
mkdir -p "$TOOLS" /tmp/video-call-downloads
cd /tmp/video-call-downloads

echo "==> Node.js"
if [[ ! -x "$TOOLS/node/bin/node" ]]; then
  curl -fL --retry 3 -o node.tar.gz \
    "https://nodejs.org/dist/v22.19.0/node-v22.19.0-darwin-arm64.tar.gz"
  tar -xzf node.tar.gz
  rm -rf "$TOOLS/node"
  mv node-v22.19.0-darwin-arm64 "$TOOLS/node"
fi
"$TOOLS/node/bin/node" --version

echo "==> Go (LiveKit 1.13 needs a recent Go toolchain)"
if [[ ! -x "$TOOLS/go/bin/go" ]]; then
  curl -fL --retry 3 -o go.tgz \
    "https://go.dev/dl/go1.26.8.darwin-arm64.tar.gz" \
    || curl -fL --retry 3 -o go.tgz \
    "https://mirrors.aliyun.com/golang/go1.26.8.darwin-arm64.tar.gz"
  rm -rf "$TOOLS/go-extract"
  mkdir -p "$TOOLS/go-extract"
  tar -xzf go.tgz -C "$TOOLS/go-extract"
  rm -rf "$TOOLS/go"
  mv "$TOOLS/go-extract/go" "$TOOLS/go"
fi
export PATH="$TOOLS/go/bin:$PATH"
export GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}"
export GOTOOLCHAIN=local
go version

echo "==> LiveKit server"
if [[ ! -x "$TOOLS/livekit-server" ]]; then
  export GOPATH="$TOOLS/gopath"
  export GOBIN="$TOOLS/gobin"
  mkdir -p "$GOBIN" "$GOPATH"
  go install github.com/livekit/livekit/cmd/server@v1.13.6
  mv "$GOBIN/server" "$TOOLS/livekit-server"
fi
"$TOOLS/livekit-server" --version || true

echo "==> Flutter SDK"
if command -v flutter >/dev/null 2>&1; then
  flutter --version | head -5
elif [[ -x "$HOME/flutter/bin/flutter" ]]; then
  "$HOME/flutter/bin/flutter" --version | head -5
else
  echo "Flutter is not on PATH. Install it and add it to PATH, for example:"
  echo "  export PATH=\"\$HOME/flutter/bin:\$PATH\""
fi

echo "bootstrap done"
