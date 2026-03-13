// ============================================================================
// Token Server for Inter — LiveKit Integration
// Phase 0.2 [G7]
//
// Endpoints:
//   POST /room/create  — Host creates a room, gets a 6-char code + JWT
//   POST /room/join    — Joiner enters a room code, gets a JWT
//   POST /token/refresh — Refresh an expiring JWT for an active participant
//
// SECURITY:
//   - API key/secret are server-side only. NEVER sent to the client.
//   - Tokens are returned but NEVER logged.
//   - Room codes expire after 24 hours.
//   - Rate limited: 10 requests/minute per identity.
// ============================================================================

const express = require('express');
const { AccessToken } = require('livekit-server-sdk');

const app = express();
app.use(express.json());

// ---------------------------------------------------------------------------
// Configuration — from environment or dev defaults
// ---------------------------------------------------------------------------
const LIVEKIT_API_KEY = process.env.LIVEKIT_API_KEY || 'devkey';
const LIVEKIT_API_SECRET = process.env.LIVEKIT_API_SECRET || 'secret';
const PORT = process.env.PORT || 3000;
const TOKEN_TTL_SECONDS = 6 * 60 * 60; // 6 hours
const ROOM_CODE_EXPIRY_MS = 24 * 60 * 60 * 1000; // 24 hours

// ---------------------------------------------------------------------------
// In-memory room code store (Redis in production — see plan step 5.2.3)
// Map: roomCode → { roomName, createdAt, hostIdentity, roomType }
// roomType: "call" | "interview" (extensible for future types)
// ---------------------------------------------------------------------------
const roomCodes = new Map();

// ---------------------------------------------------------------------------
// Rate limiting — simple in-memory (10 req/min per identity)
// ---------------------------------------------------------------------------
const rateLimitMap = new Map();
const RATE_LIMIT_MAX = 10;
const RATE_LIMIT_WINDOW_MS = 60 * 1000;

function checkRateLimit(identity) {
  const now = Date.now();
  let entry = rateLimitMap.get(identity);
  if (!entry || now - entry.windowStart > RATE_LIMIT_WINDOW_MS) {
    entry = { windowStart: now, count: 0 };
    rateLimitMap.set(identity, entry);
  }
  entry.count++;
  return entry.count <= RATE_LIMIT_MAX;
}

// ---------------------------------------------------------------------------
// Room code generation — 6 chars, alphanumeric (excluding confusable chars)
// 30^6 = 729 million combinations
// ---------------------------------------------------------------------------
const CODE_CHARS = 'ABCDEFGHJKLMNPQRSTUVWXYZ234567'; // No I, O, 0, 1, 8, 9

function generateRoomCode() {
  let code = '';
  const bytes = require('crypto').randomBytes(6);
  for (let i = 0; i < 6; i++) {
    code += CODE_CHARS[bytes[i] % CODE_CHARS.length];
  }
  return code;
}

// ---------------------------------------------------------------------------
// Token generation
// ---------------------------------------------------------------------------
async function createToken(identity, displayName, roomName, isHost, metadata = null) {
  const tokenOpts = {
    identity,
    name: displayName,
    ttl: TOKEN_TTL_SECONDS,
  };

  // Stamp participant metadata into the JWT (role, etc.) for future features.
  // LiveKit delivers this to all participants via Participant.metadata.
  if (metadata) {
    tokenOpts.metadata = JSON.stringify(metadata);
  }

  const token = new AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET, tokenOpts);

  token.addGrant({
    room: roomName,
    roomJoin: true,
    canPublish: true,
    canSubscribe: true,
    canPublishData: true,
    roomCreate: isHost,
    roomAdmin: isHost,
  });

  return await token.toJwt();
}

// ---------------------------------------------------------------------------
// Cleanup expired room codes (runs every hour)
// ---------------------------------------------------------------------------
setInterval(() => {
  const now = Date.now();
  for (const [code, data] of roomCodes) {
    if (now - data.createdAt > ROOM_CODE_EXPIRY_MS) {
      roomCodes.delete(code);
      console.log(`[audit] Room code expired and removed: ${code}`);
    }
  }
}, 60 * 60 * 1000);

// ---------------------------------------------------------------------------
// POST /room/create
// Body: { identity, displayName, roomType? }
// Returns: { roomCode, roomName, token, serverURL, roomType }
// ---------------------------------------------------------------------------
app.post('/room/create', async (req, res) => {
  const { identity, displayName, roomType: rawRoomType } = req.body;

  if (!identity || !displayName) {
    return res.status(400).json({ error: 'identity and displayName are required' });
  }

  // Normalize roomType — default to "call" for backward compatibility
  const roomType = (rawRoomType === 'interview') ? 'interview' : 'call';

  if (!checkRateLimit(identity)) {
    return res.status(429).json({ error: 'Rate limit exceeded. Try again in 1 minute.' });
  }

  // Generate unique room code
  let roomCode;
  do {
    roomCode = generateRoomCode();
  } while (roomCodes.has(roomCode));

  const roomName = `inter-${roomCode}`;

  // Store the room code mapping (roomType persisted for join-time lookup)
  roomCodes.set(roomCode, {
    roomName,
    createdAt: Date.now(),
    hostIdentity: identity,
    roomType,
  });

  try {
    // Host metadata includes role for future multi-interviewer support
    const hostRole = (roomType === 'interview') ? 'interviewer' : null;
    const metadata = hostRole ? { role: hostRole } : null;
    const jwt = await createToken(identity, displayName, roomName, true, metadata);
    console.log(`[audit] Room created: code=${roomCode} type=${roomType} host=${identity}`);
    // NEVER log the token
    res.json({
      roomCode,
      roomName,
      token: jwt,
      serverURL: process.env.LIVEKIT_SERVER_URL || 'ws://localhost:7880',
      roomType,
    });
  } catch (err) {
    console.error(`[error] Token creation failed for ${identity}:`, err.message);
    res.status(500).json({ error: 'Failed to create token' });
  }
});

// ---------------------------------------------------------------------------
// POST /room/join
// Body: { roomCode, identity, displayName }
// Returns: { roomName, token, serverURL, roomType }
// ---------------------------------------------------------------------------
app.post('/room/join', async (req, res) => {
  const { roomCode, identity, displayName } = req.body;

  if (!roomCode || !identity || !displayName) {
    return res.status(400).json({ error: 'roomCode, identity, and displayName are required' });
  }

  if (!checkRateLimit(identity)) {
    return res.status(429).json({ error: 'Rate limit exceeded. Try again in 1 minute.' });
  }

  const roomData = roomCodes.get(roomCode.toUpperCase());

  if (!roomData) {
    // Could be invalid or expired — we can't distinguish after cleanup
    // If the code was recently cleaned up, it's expired. Otherwise invalid.
    return res.status(404).json({ error: 'Invalid room code' });
  }

  // Check if expired (before cleanup runs)
  if (Date.now() - roomData.createdAt > ROOM_CODE_EXPIRY_MS) {
    roomCodes.delete(roomCode.toUpperCase());
    return res.status(410).json({ error: 'Room code has expired' });
  }

  try {
    // Assign role based on room type — joiners of interview rooms are interviewees
    const joinerRole = (roomData.roomType === 'interview') ? 'interviewee' : null;
    const metadata = joinerRole ? { role: joinerRole } : null;
    const jwt = await createToken(identity, displayName, roomData.roomName, false, metadata);
    console.log(`[audit] Room joined: code=${roomCode} type=${roomData.roomType} participant=${identity}`);
    res.json({
      roomName: roomData.roomName,
      token: jwt,
      serverURL: process.env.LIVEKIT_SERVER_URL || 'ws://localhost:7880',
      roomType: roomData.roomType,
    });
  } catch (err) {
    console.error(`[error] Token creation failed for ${identity}:`, err.message);
    res.status(500).json({ error: 'Failed to create token' });
  }
});

// ---------------------------------------------------------------------------
// POST /token/refresh
// Body: { roomCode, identity }
// Returns: { token }
// ---------------------------------------------------------------------------
app.post('/token/refresh', async (req, res) => {
  const { roomCode, identity } = req.body;

  if (!roomCode || !identity) {
    return res.status(400).json({ error: 'roomCode and identity are required' });
  }

  if (!checkRateLimit(identity)) {
    return res.status(429).json({ error: 'Rate limit exceeded. Try again in 1 minute.' });
  }

  const roomData = roomCodes.get(roomCode.toUpperCase());

  if (!roomData) {
    return res.status(404).json({ error: 'Invalid room code' });
  }

  if (Date.now() - roomData.createdAt > ROOM_CODE_EXPIRY_MS) {
    roomCodes.delete(roomCode.toUpperCase());
    return res.status(410).json({ error: 'Room code has expired' });
  }

  const isHost = roomData.hostIdentity === identity;

  try {
    const jwt = await createToken(identity, identity, roomData.roomName, isHost);
    console.log(`[audit] Token refreshed: code=${roomCode} participant=${identity}`);
    res.json({ token: jwt });
  } catch (err) {
    console.error(`[error] Token refresh failed for ${identity}:`, err.message);
    res.status(500).json({ error: 'Failed to refresh token' });
  }
});

// ---------------------------------------------------------------------------
// Health check
// ---------------------------------------------------------------------------
app.get('/health', (req, res) => {
  res.json({ status: 'ok', rooms: roomCodes.size });
});

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------
app.listen(PORT, () => {
  console.log(`[token-server] Running on http://localhost:${PORT}`);
  console.log(`[token-server] LiveKit API Key: ${LIVEKIT_API_KEY}`);
  console.log(`[token-server] Endpoints: POST /room/create, /room/join, /token/refresh`);
});
