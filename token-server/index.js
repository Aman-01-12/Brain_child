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
const MAX_PARTICIPANTS_PER_ROOM = 4; // Soft cap — designed for N, shipping at 4

// ---------------------------------------------------------------------------
// In-memory room code store (Redis in production — see plan step 5.2.3)
// Map: roomCode → { roomName, createdAt, hostIdentity, roomType, participants }
// roomType: "call" | "interview" (extensible for future types)
// participants: Set<string> of identity strings currently in the room
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
// Cleanup expired room codes and stale rate-limit entries (runs every hour)
// ---------------------------------------------------------------------------
setInterval(() => {
  const now = Date.now();
  for (const [code, data] of roomCodes) {
    if (now - data.createdAt > ROOM_CODE_EXPIRY_MS) {
      roomCodes.delete(code);
      console.log(`[audit] Room code expired and removed: ${code}`);
    }
  }
  // Purge stale rate-limit entries to prevent unbounded memory growth
  for (const [identity, entry] of rateLimitMap) {
    if (now - entry.windowStart > RATE_LIMIT_WINDOW_MS) {
      rateLimitMap.delete(identity);
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
    participants: new Set([identity]),
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
      maxParticipants: MAX_PARTICIPANTS_PER_ROOM,
      participantCount: 1,
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

  // Enforce participant cap (soft — identity dedup means reconnects don't count double)
  if (!roomData.participants.has(identity) && roomData.participants.size >= MAX_PARTICIPANTS_PER_ROOM) {
    console.log(`[audit] Room full: code=${roomCode} rejected=${identity} (${roomData.participants.size}/${MAX_PARTICIPANTS_PER_ROOM})`);
    return res.status(403).json({
      error: 'Room is full',
      maxParticipants: MAX_PARTICIPANTS_PER_ROOM,
      participantCount: roomData.participants.size,
    });
  }

  try {
    // Assign role based on room type — joiners of interview rooms are interviewees
    const joinerRole = (roomData.roomType === 'interview') ? 'interviewee' : null;
    const metadata = joinerRole ? { role: joinerRole } : null;
    const jwt = await createToken(identity, displayName, roomData.roomName, false, metadata);
    roomData.participants.add(identity);
    console.log(`[audit] Room joined: code=${roomCode} type=${roomData.roomType} participant=${identity} (${roomData.participants.size}/${MAX_PARTICIPANTS_PER_ROOM})`);
    res.json({
      roomName: roomData.roomName,
      token: jwt,
      serverURL: process.env.LIVEKIT_SERVER_URL || 'ws://localhost:7880',
      roomType: roomData.roomType,
      maxParticipants: MAX_PARTICIPANTS_PER_ROOM,
      participantCount: roomData.participants.size,
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
// GET /room/info/:code — check room status without joining
// Returns: { roomCode, roomType, participantCount, maxParticipants, isFull }
// ---------------------------------------------------------------------------
app.get('/room/info/:code', (req, res) => {
  const roomCode = req.params.code.toUpperCase();
  const roomData = roomCodes.get(roomCode);

  if (!roomData) {
    return res.status(404).json({ error: 'Invalid room code' });
  }

  if (Date.now() - roomData.createdAt > ROOM_CODE_EXPIRY_MS) {
    roomCodes.delete(roomCode);
    return res.status(410).json({ error: 'Room code has expired' });
  }

  res.json({
    roomCode,
    roomType: roomData.roomType,
    participantCount: roomData.participants.size,
    maxParticipants: MAX_PARTICIPANTS_PER_ROOM,
    isFull: roomData.participants.size >= MAX_PARTICIPANTS_PER_ROOM,
  });
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
