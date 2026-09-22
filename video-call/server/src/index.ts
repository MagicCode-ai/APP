import cors from 'cors';
import express from 'express';
import { AccessToken, RoomServiceClient } from 'livekit-server-sdk';

const PORT = Number(process.env.PORT || 3000);
const API_KEY = process.env.LIVEKIT_API_KEY || 'devkey';
const API_SECRET =
  process.env.LIVEKIT_API_SECRET ||
  'local_demo_secret_replace_me_32b_';
const LIVEKIT_HTTP_URL =
  process.env.LIVEKIT_HTTP_URL || 'http://127.0.0.1:7880';
const LIVEKIT_WS_URL = process.env.LIVEKIT_WS_URL || 'ws://127.0.0.1:7880';
const MAX_PARTICIPANTS = 2;

const roomService = new RoomServiceClient(
  LIVEKIT_HTTP_URL,
  API_KEY,
  API_SECRET,
);

const app = express();
app.use(cors());
app.use(express.json());

app.get('/health', (_req, res) => {
  res.json({ ok: true, wsUrl: LIVEKIT_WS_URL });
});

async function participantCount(
  roomName: string,
): Promise<{ count: number; identities: string[] }> {
  try {
    const participants = await roomService.listParticipants(roomName);
    return {
      count: participants.length,
      identities: participants.map((p) => p.identity),
    };
  } catch (err: unknown) {
    const anyErr = err as { code?: string; status?: number; message?: string };
    const message = String(anyErr?.message || err);
    const missing =
      anyErr?.code === 'not_found' ||
      anyErr?.status === 404 ||
      /not found|does not exist|no such room/i.test(message);
    if (missing) {
      return { count: 0, identities: [] };
    }
    throw err;
  }
}

app.post('/token', async (req, res) => {
  try {
    const roomName = String(req.body?.roomName ?? '').trim();
    const identity = String(req.body?.identity ?? '').trim();
    if (!roomName || !identity) {
      res.status(400).json({ error: 'roomName 和 identity 必填' });
      return;
    }

    const { count, identities } = await participantCount(roomName);
    const alreadyInRoom = identities.includes(identity);
    if (count >= MAX_PARTICIPANTS && !alreadyInRoom) {
      res.status(409).json({ error: '房间已满，仅支持 1 对 1 通话' });
      return;
    }

    const at = new AccessToken(API_KEY, API_SECRET, {
      identity,
      name: identity,
      ttl: '15m',
    });
    at.addGrant({
      roomJoin: true,
      room: roomName,
      canPublish: true,
      canSubscribe: true,
      canPublishData: true,
    });

    const token = await at.toJwt();
    res.json({
      url: LIVEKIT_WS_URL,
      token,
      roomName,
      identity,
    });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : '签发 token 失败';
    console.error('POST /token failed:', err);
    res.status(500).json({ error: message });
  }
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`token api listening on 0.0.0.0:${PORT}`);
  console.log(`livekit http=${LIVEKIT_HTTP_URL} ws=${LIVEKIT_WS_URL}`);
});
