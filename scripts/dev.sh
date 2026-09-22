#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/.tools"
export PATH="$TOOLS/node/bin:$TOOLS/go126/bin:$TOOLS/go/bin:$TOOLS:$PATH"

LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 127.0.0.1)"

export LIVEKIT_API_KEY="${LIVEKIT_API_KEY:-devkey}"
export LIVEKIT_API_SECRET="${LIVEKIT_API_SECRET:-local_demo_secret_replace_me_32b_}"
export LIVEKIT_HTTP_URL="${LIVEKIT_HTTP_URL:-http://127.0.0.1:7880}"
export LIVEKIT_WS_URL="${LIVEKIT_WS_URL:-ws://${LAN_IP}:7880}"
export PORT="${PORT:-3000}"

LIVEKIT_BIN="${LIVEKIT_BIN:-}"
if [[ -z "$LIVEKIT_BIN" ]]; then
  if [[ -x "$TOOLS/livekit-server" ]]; then
    LIVEKIT_BIN="$TOOLS/livekit-server"
  elif command -v livekit-server >/dev/null 2>&1; then
    LIVEKIT_BIN="$(command -v livekit-server)"
  else
    echo "找不到 livekit-server，请先运行 scripts/bootstrap.sh" >&2
    exit 1
  fi
fi

if ! command -v node >/dev/null 2>&1; then
  echo "找不到 node，请先运行 scripts/bootstrap.sh" >&2
  exit 1
fi

CONFIG_DIR="$(mktemp -d)"
trap 'rm -rf "$CONFIG_DIR"; kill 0' EXIT
sed "s/NODE_IP_PLACEHOLDER/${LAN_IP}/" "$ROOT/infra/livekit.yaml" > "$CONFIG_DIR/livekit.yaml"

echo "LAN IP:     $LAN_IP"
echo "LiveKit:    ws://${LAN_IP}:7880"
echo "Token API:  http://${LAN_IP}:${PORT}/token"
echo "真机加入页默认 Token 服务: http://${LAN_IP}:${PORT}"
echo

"$LIVEKIT_BIN" --config "$CONFIG_DIR/livekit.yaml" &
LIVEKIT_PID=$!

# 等 LiveKit HTTP 起来再签 token
for _ in $(seq 1 40); do
  if curl -sf "http://127.0.0.1:7880" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

cd "$ROOT/server"
if [[ ! -d node_modules ]]; then
  npm install --registry=https://registry.npmmirror.com
fi
node --experimental-strip-types src/index.ts &
TOKEN_PID=$!

wait "$LIVEKIT_PID" "$TOKEN_PID"
