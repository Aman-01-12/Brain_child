// ============================================================================
// Token Server for Inter — LiveKit Integration
// Phase 6.1 [G6.1] — Redis-backed
//
// Endpoints:
//   POST /room/create  — Host creates a room, gets a 6-char code + JWT
//   POST /room/join    — Joiner enters a room code, gets a JWT
//   POST /token/refresh — Refresh an expiring JWT for an active participant
//   GET  /room/info/:code — Check room status without joining
//   GET  /health       — Health check (includes Redis status)
//
// STORAGE:
//   Room data  → Redis Hash  `room:{CODE}`  (TTL 24h, auto-expires)
//   Participants → Redis Set `room:{CODE}:participants`  (TTL 24h)
//   Rate limits → Redis key  `ratelimit:{identity}`  (TTL 60s, INCR)
//
// SECURITY:
//   - API key/secret are server-side only. NEVER sent to the client.
//   - Tokens are returned but NEVER logged.
//   - Room codes expire after 24 hours (Redis TTL — no manual cleanup).
//   - Rate limited: 10 requests/minute per identity (Redis INCR+EXPIRE).
// ============================================================================

require('dotenv').config();

const express = require('express');
const { AccessToken } = require('livekit-server-sdk');
const redis = require('./redis');
const db = require('./db');
const auth = require('./auth');

const app = express();
app.use(express.json());

// Apply optional auth middleware globally — attaches req.user if Bearer token present
app.use(auth.authenticateToken);

// ---------------------------------------------------------------------------
// Configuration — from environment or dev defaults
// ---------------------------------------------------------------------------
const LIVEKIT_API_KEY = process.env.LIVEKIT_API_KEY || 'devkey';
const LIVEKIT_API_SECRET = process.env.LIVEKIT_API_SECRET || 'secret';
const PORT = process.env.PORT || 3000;
const TOKEN_TTL_SECONDS = 6 * 60 * 60; // 6 hours
const ROOM_CODE_EXPIRY_SECONDS = 24 * 60 * 60; // 24 hours (Redis TTL in seconds)
const MAX_PARTICIPANTS_PER_ROOM = 4; // Soft cap — designed for N, shipping at 4

// ---------------------------------------------------------------------------
// Rate limiting — Redis INCR + EXPIRE (10 req/min per identity)
// Atomic: INCR creates key if missing, EXPIRE sets auto-cleanup.
// No manual cleanup needed — Redis handles it.
// ---------------------------------------------------------------------------
const RATE_LIMIT_MAX = 10;
const RATE_LIMIT_WINDOW_SECONDS = 60;

async function checkRateLimit(identity) {
  const key = `ratelimit:${identity}`;
  const count = await redis.incr(key);
  if (count === 1) {
    // First request in this window — set the TTL
    await redis.expire(key, RATE_LIMIT_WINDOW_SECONDS);
  }
  return count <= RATE_LIMIT_MAX;
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

// ===========================================================================
// AUTH ENDPOINTS
// ===========================================================================

// ---------------------------------------------------------------------------
// POST /auth/register
// Body: { email, password, displayName }
// Returns: { user, token }
// ---------------------------------------------------------------------------
app.post('/auth/register', async (req, res) => {
  const { email, password, displayName } = req.body;

  try {
    const result = await auth.register(email, password, displayName);
    console.log(`[audit] User registered: ${result.user.email} (${result.user.id})`);
    res.status(201).json(result);
  } catch (err) {
    const status = err.message.includes('already registered') ? 409
                 : err.message.includes('required') ? 400
                 : err.message.includes('at least') ? 400
                 : 500;
    res.status(status).json({ error: err.message });
  }
});

// ---------------------------------------------------------------------------
// POST /auth/login
// Body: { email, password }
// Returns: { user, token }
// ---------------------------------------------------------------------------
app.post('/auth/login', async (req, res) => {
  const { email, password } = req.body;

  try {
    const result = await auth.login(email, password);
    console.log(`[audit] User logged in: ${result.user.email}`);
    res.json(result);
  } catch (err) {
    const status = err.message.includes('Invalid') ? 401
                 : err.message.includes('required') ? 400
                 : 500;
    res.status(status).json({ error: err.message });
  }
});

// ---------------------------------------------------------------------------
// GET /auth/me — get current user info (requires auth)
// Returns: { userId, email, displayName, tier }
// ---------------------------------------------------------------------------
app.get('/auth/me', auth.requireAuth, (req, res) => {
  res.json(req.user);
});

// ---------------------------------------------------------------------------
// Redis key helpers
// ---------------------------------------------------------------------------
function roomKey(code) { return `room:${code}`; }
function roomParticipantsKey(code) { return `room:${code}:participants`; }

// ---------------------------------------------------------------------------
// Room data helpers — read/write room Hash + participants Set in Redis
// ---------------------------------------------------------------------------
async function getRoomData(code) {
  const data = await redis.hgetall(roomKey(code));
  if (!data || Object.keys(data).length === 0) return null;
  return data; // { roomName, createdAt, hostIdentity, roomType }
}

async function getParticipantCount(code) {
  return await redis.scard(roomParticipantsKey(code));
}

async function isParticipant(code, identity) {
  return await redis.sismember(roomParticipantsKey(code), identity);
}

async function addParticipant(code, identity) {
  return await redis.sadd(roomParticipantsKey(code), identity);
}

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

  if (!(await checkRateLimit(identity))) {
    return res.status(429).json({ error: 'Rate limit exceeded. Try again in 1 minute.' });
  }

  // Generate unique room code (check Redis for collision)
  let roomCode;
  let exists;
  do {
    roomCode = generateRoomCode();
    exists = await redis.exists(roomKey(roomCode));
  } while (exists);

  const roomName = `inter-${roomCode}`;

  // Store room data as a Redis Hash with 24h TTL
  const pipeline = redis.pipeline();
  pipeline.hset(roomKey(roomCode),
    'roomName', roomName,
    'createdAt', Date.now().toString(),
    'hostIdentity', identity,
    'roomType', roomType,
  );
  pipeline.expire(roomKey(roomCode), ROOM_CODE_EXPIRY_SECONDS);
  // Participants stored as a Redis Set (identity dedup is automatic)
  pipeline.sadd(roomParticipantsKey(roomCode), identity);
  pipeline.expire(roomParticipantsKey(roomCode), ROOM_CODE_EXPIRY_SECONDS);
  await pipeline.exec();

  try {
    // Host metadata includes role for future multi-interviewer support
    const hostRole = (roomType === 'interview') ? 'interviewer' : null;
    const metadata = hostRole ? { role: hostRole } : null;
    const jwt = await createToken(identity, displayName, roomName, true, metadata);
    console.log(`[audit] Room created: code=${roomCode} type=${roomType} host=${identity}`);

    // Persist meeting to PostgreSQL (if user is authenticated)
    // Best-effort — don't fail the room creation if DB write fails
    if (req.user) {
      try {
        const meetingResult = await db.query(
          `INSERT INTO meetings (host_user_id, room_code, room_name, room_type)
           VALUES ($1, $2, $3, $4)
           RETURNING id`,
          [req.user.userId, roomCode, roomName, roomType]
        );
        const meetingId = meetingResult.rows[0].id;
        // Also log host as first participant
        await db.query(
          `INSERT INTO meeting_participants (meeting_id, user_id, identity, display_name, role)
           VALUES ($1, $2, $3, $4, $5)`,
          [meetingId, req.user.userId, identity, displayName, 'host']
        );
        // Store meeting ID in Redis so join endpoint can reference it
        await redis.hset(roomKey(roomCode), 'meetingId', meetingId);
        console.log(`[audit] Meeting persisted: ${meetingId} for room ${roomCode}`);
      } catch (dbErr) {
        console.error(`[warn] Failed to persist meeting to DB:`, dbErr.message);
        // Non-fatal — room still works via Redis
      }
    }

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

  if (!(await checkRateLimit(identity))) {
    return res.status(429).json({ error: 'Rate limit exceeded. Try again in 1 minute.' });
  }

  const code = roomCode.toUpperCase();
  const roomData = await getRoomData(code);

  if (!roomData) {
    // Room doesn't exist — either invalid code or expired (Redis TTL auto-deleted)
    return res.status(404).json({ error: 'Invalid or expired room code' });
  }

  // Enforce participant cap (soft — identity dedup means reconnects don't count double)
  const alreadyIn = await isParticipant(code, identity);
  const participantCount = await getParticipantCount(code);

  if (!alreadyIn && participantCount >= MAX_PARTICIPANTS_PER_ROOM) {
    console.log(`[audit] Room full: code=${code} rejected=${identity} (${participantCount}/${MAX_PARTICIPANTS_PER_ROOM})`);
    return res.status(403).json({
      error: 'Room is full',
      maxParticipants: MAX_PARTICIPANTS_PER_ROOM,
      participantCount,
    });
  }

  try {
    // Assign role based on room type — joiners of interview rooms are interviewees
    const joinerRole = (roomData.roomType === 'interview') ? 'interviewee' : null;
    const metadata = joinerRole ? { role: joinerRole } : null;
    const jwt = await createToken(identity, displayName, roomData.roomName, false, metadata);
    await addParticipant(code, identity);
    const newCount = await getParticipantCount(code);
    console.log(`[audit] Room joined: code=${code} type=${roomData.roomType} participant=${identity} (${newCount}/${MAX_PARTICIPANTS_PER_ROOM})`);

    // Persist participant join to PostgreSQL (best-effort)
    if (roomData.meetingId) {
      try {
        const role = joinerRole || 'participant';
        await db.query(
          `INSERT INTO meeting_participants (meeting_id, user_id, identity, display_name, role)
           VALUES ($1, $2, $3, $4, $5)`,
          [roomData.meetingId, req.user?.userId || null, identity, displayName, role]
        );
      } catch (dbErr) {
        console.error(`[warn] Failed to persist participant to DB:`, dbErr.message);
      }
    }

    res.json({
      roomName: roomData.roomName,
      token: jwt,
      serverURL: process.env.LIVEKIT_SERVER_URL || 'ws://localhost:7880',
      roomType: roomData.roomType,
      maxParticipants: MAX_PARTICIPANTS_PER_ROOM,
      participantCount: newCount,
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

  if (!(await checkRateLimit(identity))) {
    return res.status(429).json({ error: 'Rate limit exceeded. Try again in 1 minute.' });
  }

  const code = roomCode.toUpperCase();
  const roomData = await getRoomData(code);

  if (!roomData) {
    return res.status(404).json({ error: 'Invalid or expired room code' });
  }

  const isHost = roomData.hostIdentity === identity;

  try {
    const jwt = await createToken(identity, identity, roomData.roomName, isHost);
    console.log(`[audit] Token refreshed: code=${code} participant=${identity}`);
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
app.get('/room/info/:code', async (req, res) => {
  const code = req.params.code.toUpperCase();
  const roomData = await getRoomData(code);

  if (!roomData) {
    return res.status(404).json({ error: 'Invalid or expired room code' });
  }

  const participantCount = await getParticipantCount(code);

  res.json({
    roomCode: code,
    roomType: roomData.roomType,
    participantCount,
    maxParticipants: MAX_PARTICIPANTS_PER_ROOM,
    isFull: participantCount >= MAX_PARTICIPANTS_PER_ROOM,
  });
});

// ---------------------------------------------------------------------------
// Health check — includes Redis + PostgreSQL connection status
// ---------------------------------------------------------------------------
app.get('/health', async (req, res) => {
  let redisStatus = 'disconnected';
  let dbStatus = 'disconnected';
  let roomCount = 0;

  // Check Redis
  try {
    const pong = await redis.ping();
    redisStatus = pong === 'PONG' ? 'connected' : 'error';
    const keys = await redis.keys('room:*');
    roomCount = keys.filter(k => !k.includes(':participants')).length;
  } catch (err) {
    redisStatus = 'error';
  }

  // Check PostgreSQL
  try {
    const result = await db.query('SELECT 1');
    dbStatus = result.rows.length > 0 ? 'connected' : 'error';
  } catch (err) {
    dbStatus = 'error';
  }

  const isHealthy = redisStatus === 'connected' && dbStatus === 'connected';
  res.status(isHealthy ? 200 : 503).json({
    status: isHealthy ? 'ok' : 'degraded',
    redis: redisStatus,
    postgres: dbStatus,
    rooms: roomCount,
  });
});

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------
app.listen(PORT, () => {
  console.log(`[token-server] Running on http://localhost:${PORT}`);
  console.log(`[token-server] LiveKit API Key: ${LIVEKIT_API_KEY}`);
  console.log(`[token-server] Redis: ${process.env.REDIS_URL || 'redis://localhost:6379'}`);
  console.log(`[token-server] Endpoints: POST /room/create, /room/join, /token/refresh, /auth/register, /auth/login | GET /room/info/:code, /auth/me, /health`);
});
