// ============================================================================
// Token Server for Inter — LiveKit Integration
// Phase 6.1 [G6.1] — Redis-backed
// Phase 9 [G9] — Meeting management: roles, moderation, lobby, passwords
//
// Endpoints:
//   POST /room/create  — Host creates a room, gets a 6-char code + JWT
//   POST /room/join    — Joiner enters a room code, gets a JWT
//   POST /token/refresh — Refresh an expiring JWT for an active participant
//   GET  /room/info/:code — Check room status without joining
//   GET  /health       — Health check (includes Redis status)
//
// Phase 9 Endpoints:
//   POST /room/promote     — Promote/demote a participant's role
//   POST /room/mute        — Mute a specific participant's track
//   POST /room/mute-all    — Mute all participants' audio
//   POST /room/remove      — Remove a participant from the room
//   POST /room/lock        — Lock the meeting (prevent new joins)
//   POST /room/unlock      — Unlock the meeting
//   POST /room/suspend     — Suspend a participant (mute all + disable chat)
//   POST /room/unsuspend   — Unsuspend a participant
//   POST /room/lobby/enable  — Enable lobby/waiting room
//   POST /room/lobby/disable — Disable lobby/waiting room
//   POST /room/admit       — Admit a participant from the lobby
//   POST /room/admit-all   — Admit all participants from the lobby
//   POST /room/deny        — Deny a participant from the lobby
//   GET  /room/lobby-status/:code/:identity — Check lobby status (polling)
//   POST /room/password    — Set/change meeting password
//
// STORAGE:
//   Room data  → Redis Hash  `room:{CODE}`  (TTL 24h, auto-expires)
//   Participants → Redis Set `room:{CODE}:participants`  (TTL 24h)
//   Rate limits → Redis key  `ratelimit:{identity}`  (TTL 60s, INCR)
//   Meeting lock → Redis key `room:{CODE}:locked`  (TTL 24h)
//   Lobby → Redis Sorted Set `room:{CODE}:lobby`  (score = timestamp)
//   Lobby enabled → Redis Hash field `room:{CODE}` → lobbyEnabled
//   Password → Redis Hash field `room:{CODE}` → passwordHash
//   Suspended → Redis Set `room:{CODE}:suspended`
//   Roles → Redis Hash `room:{CODE}:roles` → {identity: role}
//
// SECURITY:
//   - API key/secret are server-side only. NEVER sent to the client.
//   - Tokens are returned but NEVER logged.
//   - Room codes expire after 24 hours (Redis TTL — no manual cleanup).
//   - Rate limited: 10 requests/minute per identity (Redis INCR+EXPIRE).
//   - Moderation endpoints validate caller role server-side.
// ============================================================================

require('dotenv').config();

const express = require('express');
const { AccessToken, RoomServiceClient, TrackSource } = require('livekit-server-sdk');
const bcrypt = require('bcryptjs');
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
const LIVEKIT_SERVER_URL = process.env.LIVEKIT_SERVER_URL || 'ws://localhost:7880';
const LIVEKIT_HTTP_URL = process.env.LIVEKIT_HTTP_URL || 'http://localhost:7880';
const PORT = process.env.PORT || 3000;
const TOKEN_TTL_SECONDS = 6 * 60 * 60; // 6 hours
const ROOM_CODE_EXPIRY_SECONDS = 24 * 60 * 60; // 24 hours (Redis TTL in seconds)
const MAX_PARTICIPANTS_PER_ROOM = 50; // Phase 7: scaled from 4 to 50

// ---------------------------------------------------------------------------
// LiveKit Room Service Client — for server-side moderation (Phase 9)
// Used for: mute tracks, remove participants, update metadata.
// ---------------------------------------------------------------------------
const roomService = new RoomServiceClient(LIVEKIT_HTTP_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET);

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

// Phase 9 Redis key helpers
function roomRolesKey(code) { return `room:${code}:roles`; }
function roomLockedKey(code) { return `room:${code}:locked`; }
function roomLobbyKey(code) { return `room:${code}:lobby`; }
function roomSuspendedKey(code) { return `room:${code}:suspended`; }

// ---------------------------------------------------------------------------
// Phase 9 — Role hierarchy and permission validation (server-side mirror)
// Matches InterPermissions.swift permission matrix exactly.
// ---------------------------------------------------------------------------
const ROLE_HIERARCHY = { 'participant': 0, 'presenter': 1, 'panelist': 2, 'co-host': 3, 'host': 4 };
const MODERATOR_ROLES = ['host', 'co-host'];

function isModeratorRole(role) {
  return MODERATOR_ROLES.includes(role);
}

function roleLevel(role) {
  return ROLE_HIERARCHY[role] || 0;
}

/// Get a participant's role from Redis (falls back to checking if they're the host).
async function getParticipantRole(code, identity) {
  // Check explicit role assignment
  const role = await redis.hget(roomRolesKey(code), identity);
  if (role) return role;
  // Check if they're the original host
  const roomData = await redis.hgetall(roomKey(code));
  if (roomData && roomData.hostIdentity === identity) return 'host';
  return 'participant';
}

/// Validate that the caller has moderator privileges. Returns { valid, role, error }.
async function validateModerator(code, callerIdentity) {
  const role = await getParticipantRole(code, callerIdentity);
  if (!isModeratorRole(role)) {
    return { valid: false, role, error: 'Insufficient permissions. Moderator role required.' };
  }
  return { valid: true, role, error: null };
}

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
    // Host metadata includes role — always include it for Phase 9 role enforcement.
    const hostRole = (roomType === 'interview') ? 'interviewer' : 'host';
    const metadata = { role: hostRole };
    const jwt = await createToken(identity, displayName, roomName, true, metadata);
    console.log(`[audit] Room created: code=${roomCode} type=${roomType} host=${identity}`);

    // Store host role in Redis for server-side validation (Phase 9)
    await redis.hset(roomRolesKey(roomCode), identity, 'host');
    await redis.expire(roomRolesKey(roomCode), ROOM_CODE_EXPIRY_SECONDS);

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

  // Phase 9.2.6 — Check if meeting is locked
  const isLocked = await redis.exists(roomLockedKey(code));
  if (isLocked) {
    return res.status(423).json({ error: 'This meeting is locked. No new participants can join.' });
  }

  // Phase 9.4 — Check if meeting has a password
  const passwordHash = roomData.passwordHash;
  if (passwordHash) {
    const { password } = req.body;
    if (!password) {
      return res.status(401).json({ error: 'This meeting requires a password', passwordRequired: true });
    }
    const passwordValid = await bcrypt.compare(password, passwordHash);
    if (!passwordValid) {
      return res.status(401).json({ error: 'Incorrect password', passwordRequired: true });
    }
  }

  // Phase 9.3 — Check if lobby is enabled
  const lobbyEnabled = roomData.lobbyEnabled === 'true';
  if (lobbyEnabled) {
    // Check if this participant is already admitted (reconnecting)
    const alreadyAdmitted = await isParticipant(code, identity);
    if (!alreadyAdmitted) {
      // Add to lobby waiting room
      const score = Date.now();
      await redis.zadd(roomLobbyKey(code), score, JSON.stringify({ identity, displayName }));
      await redis.expire(roomLobbyKey(code), ROOM_CODE_EXPIRY_SECONDS);
      const position = await redis.zrank(roomLobbyKey(code), JSON.stringify({ identity, displayName }));
      console.log(`[audit] Lobby join: code=${code} identity=${identity} position=${position + 1}`);
      return res.json({ status: 'waiting', position: (position || 0) + 1 });
    }
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
    // Assign role based on room type — Phase 9: always include role in metadata
    const joinerRole = (roomData.roomType === 'interview') ? 'interviewee' : 'participant';
    const metadata = { role: joinerRole };
    const jwt = await createToken(identity, displayName, roomData.roomName, false, metadata);
    await addParticipant(code, identity);

    // Store participant role in Redis for server-side validation (Phase 9)
    await redis.hset(roomRolesKey(code), identity, joinerRole === 'interviewee' ? 'participant' : joinerRole);

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

// ===========================================================================
// PHASE 9 — MEETING MANAGEMENT ENDPOINTS
// ===========================================================================

// ---------------------------------------------------------------------------
// POST /room/promote — Promote or demote a participant's role
// Body: { roomCode, callerIdentity, targetIdentity, newRole }
// Returns: { success, identity, previousRole, newRole }
// ---------------------------------------------------------------------------
app.post('/room/promote', async (req, res) => {
  const { roomCode, callerIdentity, targetIdentity, newRole } = req.body;

  if (!roomCode || !callerIdentity || !targetIdentity || !newRole) {
    return res.status(400).json({ error: 'roomCode, callerIdentity, targetIdentity, and newRole are required' });
  }

  const code = roomCode.toUpperCase();
  const roomData = await getRoomData(code);
  if (!roomData) return res.status(404).json({ error: 'Invalid or expired room code' });

  // Validate caller has promote permission
  const callerRole = await getParticipantRole(code, callerIdentity);
  if (!isModeratorRole(callerRole)) {
    return res.status(403).json({ error: 'Insufficient permissions. Moderator role required.' });
  }

  // Validate the new role is valid
  if (!ROLE_HIERARCHY.hasOwnProperty(newRole)) {
    return res.status(400).json({ error: `Invalid role: ${newRole}. Valid roles: ${Object.keys(ROLE_HIERARCHY).join(', ')}` });
  }

  // Cannot promote to host
  if (newRole === 'host') {
    return res.status(403).json({ error: 'Cannot promote to host role.' });
  }

  // Co-hosts can only promote up to panelist
  if (callerRole === 'co-host' && roleLevel(newRole) > roleLevel('panelist')) {
    return res.status(403).json({ error: 'Co-hosts can only promote up to panelist.' });
  }

  // Cannot demote someone of equal or higher role
  const targetCurrentRole = await getParticipantRole(code, targetIdentity);
  if (roleLevel(targetCurrentRole) >= roleLevel(callerRole)) {
    return res.status(403).json({ error: 'Cannot modify role of a participant with equal or higher privileges.' });
  }

  try {
    // Update role in Redis
    const previousRole = targetCurrentRole;
    await redis.hset(roomRolesKey(code), targetIdentity, newRole);

    // Update LiveKit participant metadata so all clients see the role change
    const metadata = JSON.stringify({ role: newRole });
    try {
      await roomService.updateParticipant(roomData.roomName, targetIdentity, { metadata });
    } catch (lkErr) {
      console.error(`[warn] LiveKit metadata update failed for ${targetIdentity}:`, lkErr.message);
      // Non-fatal — role is stored in Redis regardless
    }

    console.log(`[audit] Role changed: code=${code} target=${targetIdentity} ${previousRole}->${newRole} by=${callerIdentity}`);
    res.json({ success: true, identity: targetIdentity, previousRole, newRole });
  } catch (err) {
    console.error(`[error] Promote failed:`, err.message);
    res.status(500).json({ error: 'Failed to update participant role' });
  }
});

// ---------------------------------------------------------------------------
// POST /room/mute — Mute a specific participant's track
// Body: { roomCode, callerIdentity, targetIdentity, trackSource }
// trackSource: "microphone" | "camera"
// Returns: { success }
// ---------------------------------------------------------------------------
app.post('/room/mute', async (req, res) => {
  const { roomCode, callerIdentity, targetIdentity, trackSource } = req.body;

  if (!roomCode || !callerIdentity || !targetIdentity || !trackSource) {
    return res.status(400).json({ error: 'roomCode, callerIdentity, targetIdentity, and trackSource are required' });
  }

  if (!['microphone', 'camera'].includes(trackSource)) {
    return res.status(400).json({ error: 'trackSource must be "microphone" or "camera"' });
  }

  const code = roomCode.toUpperCase();
  const roomData = await getRoomData(code);
  if (!roomData) return res.status(404).json({ error: 'Invalid or expired room code' });

  const validation = await validateModerator(code, callerIdentity);
  if (!validation.valid) return res.status(403).json({ error: validation.error });

  try {
    // Get participant's tracks and find the matching one
    const participant = await roomService.getParticipant(roomData.roomName, targetIdentity);
    if (!participant) {
      return res.status(404).json({ error: 'Participant not found in room' });
    }

    // Find the track by source
    const tracks = participant.tracks || [];
    const sourceMap = { 'microphone': TrackSource.MICROPHONE, 'camera': TrackSource.CAMERA };
    const targetTrack = tracks.find(t => t.source === sourceMap[trackSource]);

    if (targetTrack) {
      await roomService.mutePublishedTrack(roomData.roomName, targetIdentity, targetTrack.sid, true);
    }

    console.log(`[audit] Mute: code=${code} target=${targetIdentity} track=${trackSource} by=${callerIdentity}`);
    res.json({ success: true });
  } catch (err) {
    console.error(`[error] Mute failed:`, err.message);
    res.status(500).json({ error: 'Failed to mute participant' });
  }
});

// ---------------------------------------------------------------------------
// POST /room/mute-all — Mute all participants' audio
// Body: { roomCode, callerIdentity }
// Returns: { success, mutedCount }
// ---------------------------------------------------------------------------
app.post('/room/mute-all', async (req, res) => {
  const { roomCode, callerIdentity } = req.body;

  if (!roomCode || !callerIdentity) {
    return res.status(400).json({ error: 'roomCode and callerIdentity are required' });
  }

  const code = roomCode.toUpperCase();
  const roomData = await getRoomData(code);
  if (!roomData) return res.status(404).json({ error: 'Invalid or expired room code' });

  const validation = await validateModerator(code, callerIdentity);
  if (!validation.valid) return res.status(403).json({ error: validation.error });

  try {
    const participants = await roomService.listParticipants(roomData.roomName);
    let mutedCount = 0;

    for (const p of participants) {
      // Skip the caller (don't mute yourself)
      if (p.identity === callerIdentity) continue;

      const tracks = p.tracks || [];
      const micTrack = tracks.find(t => t.source === TrackSource.MICROPHONE);
      if (micTrack && !micTrack.muted) {
        try {
          await roomService.mutePublishedTrack(roomData.roomName, p.identity, micTrack.sid, true);
          mutedCount++;
        } catch (muteErr) {
          console.error(`[warn] Failed to mute ${p.identity}:`, muteErr.message);
        }
      }
    }

    console.log(`[audit] Mute all: code=${code} muted=${mutedCount} by=${callerIdentity}`);
    res.json({ success: true, mutedCount });
  } catch (err) {
    console.error(`[error] Mute all failed:`, err.message);
    res.status(500).json({ error: 'Failed to mute all participants' });
  }
});

// NOTE: /room/unmute-all removed — LiveKit does not allow server-side unmute
// ("remote unmute not enabled"). Unmute is now handled client-side via the
// requestUnmuteAll DataChannel control signal broadcast by the host.

// ---------------------------------------------------------------------------
// POST /room/remove — Remove a participant from the room
// Body: { roomCode, callerIdentity, targetIdentity }
// Returns: { success }
// ---------------------------------------------------------------------------
app.post('/room/remove', async (req, res) => {
  const { roomCode, callerIdentity, targetIdentity } = req.body;

  if (!roomCode || !callerIdentity || !targetIdentity) {
    return res.status(400).json({ error: 'roomCode, callerIdentity, and targetIdentity are required' });
  }

  const code = roomCode.toUpperCase();
  const roomData = await getRoomData(code);
  if (!roomData) return res.status(404).json({ error: 'Invalid or expired room code' });

  const validation = await validateModerator(code, callerIdentity);
  if (!validation.valid) return res.status(403).json({ error: validation.error });

  // Cannot remove someone of equal or higher role
  const targetRole = await getParticipantRole(code, targetIdentity);
  const callerRole = validation.role;
  if (roleLevel(targetRole) >= roleLevel(callerRole)) {
    return res.status(403).json({ error: 'Cannot remove a participant with equal or higher privileges.' });
  }

  try {
    await roomService.removeParticipant(roomData.roomName, targetIdentity);
    await redis.srem(roomParticipantsKey(code), targetIdentity);
    await redis.hdel(roomRolesKey(code), targetIdentity);

    console.log(`[audit] Remove: code=${code} target=${targetIdentity} by=${callerIdentity}`);
    res.json({ success: true });
  } catch (err) {
    console.error(`[error] Remove failed:`, err.message);
    res.status(500).json({ error: 'Failed to remove participant' });
  }
});

// ---------------------------------------------------------------------------
// POST /room/lock — Lock the meeting (prevent new joins)
// Body: { roomCode, callerIdentity }
// Returns: { success }
// ---------------------------------------------------------------------------
app.post('/room/lock', async (req, res) => {
  const { roomCode, callerIdentity } = req.body;

  if (!roomCode || !callerIdentity) {
    return res.status(400).json({ error: 'roomCode and callerIdentity are required' });
  }

  const code = roomCode.toUpperCase();
  const roomData = await getRoomData(code);
  if (!roomData) return res.status(404).json({ error: 'Invalid or expired room code' });

  const validation = await validateModerator(code, callerIdentity);
  if (!validation.valid) return res.status(403).json({ error: validation.error });

  await redis.set(roomLockedKey(code), '1');
  await redis.expire(roomLockedKey(code), ROOM_CODE_EXPIRY_SECONDS);

  console.log(`[audit] Meeting locked: code=${code} by=${callerIdentity}`);
  res.json({ success: true });
});

// ---------------------------------------------------------------------------
// POST /room/unlock — Unlock the meeting
// Body: { roomCode, callerIdentity }
// Returns: { success }
// ---------------------------------------------------------------------------
app.post('/room/unlock', async (req, res) => {
  const { roomCode, callerIdentity } = req.body;

  if (!roomCode || !callerIdentity) {
    return res.status(400).json({ error: 'roomCode and callerIdentity are required' });
  }

  const code = roomCode.toUpperCase();
  const roomData = await getRoomData(code);
  if (!roomData) return res.status(404).json({ error: 'Invalid or expired room code' });

  const validation = await validateModerator(code, callerIdentity);
  if (!validation.valid) return res.status(403).json({ error: validation.error });

  await redis.del(roomLockedKey(code));

  console.log(`[audit] Meeting unlocked: code=${code} by=${callerIdentity}`);
  res.json({ success: true });
});

// ---------------------------------------------------------------------------
// POST /room/suspend — Suspend a participant (mute all tracks + disable chat)
// Body: { roomCode, callerIdentity, targetIdentity }
// Returns: { success }
// ---------------------------------------------------------------------------
app.post('/room/suspend', async (req, res) => {
  const { roomCode, callerIdentity, targetIdentity } = req.body;

  if (!roomCode || !callerIdentity || !targetIdentity) {
    return res.status(400).json({ error: 'roomCode, callerIdentity, and targetIdentity are required' });
  }

  const code = roomCode.toUpperCase();
  const roomData = await getRoomData(code);
  if (!roomData) return res.status(404).json({ error: 'Invalid or expired room code' });

  const validation = await validateModerator(code, callerIdentity);
  if (!validation.valid) return res.status(403).json({ error: validation.error });

  try {
    // Mute all tracks
    const participant = await roomService.getParticipant(roomData.roomName, targetIdentity);
    if (participant) {
      for (const track of (participant.tracks || [])) {
        try {
          await roomService.mutePublishedTrack(roomData.roomName, targetIdentity, track.sid, true);
        } catch (muteErr) {
          console.error(`[warn] Failed to mute track ${track.sid}:`, muteErr.message);
        }
      }
    }

    // Mark as suspended in Redis
    await redis.sadd(roomSuspendedKey(code), targetIdentity);
    await redis.expire(roomSuspendedKey(code), ROOM_CODE_EXPIRY_SECONDS);

    console.log(`[audit] Suspended: code=${code} target=${targetIdentity} by=${callerIdentity}`);
    res.json({ success: true });
  } catch (err) {
    console.error(`[error] Suspend failed:`, err.message);
    res.status(500).json({ error: 'Failed to suspend participant' });
  }
});

// ---------------------------------------------------------------------------
// POST /room/unsuspend — Unsuspend a participant
// Body: { roomCode, callerIdentity, targetIdentity }
// Returns: { success }
// ---------------------------------------------------------------------------
app.post('/room/unsuspend', async (req, res) => {
  const { roomCode, callerIdentity, targetIdentity } = req.body;

  if (!roomCode || !callerIdentity || !targetIdentity) {
    return res.status(400).json({ error: 'roomCode, callerIdentity, and targetIdentity are required' });
  }

  const code = roomCode.toUpperCase();
  const roomData = await getRoomData(code);
  if (!roomData) return res.status(404).json({ error: 'Invalid or expired room code' });

  const validation = await validateModerator(code, callerIdentity);
  if (!validation.valid) return res.status(403).json({ error: validation.error });

  await redis.srem(roomSuspendedKey(code), targetIdentity);

  console.log(`[audit] Unsuspended: code=${code} target=${targetIdentity} by=${callerIdentity}`);
  res.json({ success: true });
});

// ---------------------------------------------------------------------------
// POST /room/lobby/enable — Enable lobby/waiting room
// Body: { roomCode, callerIdentity }
// Returns: { success }
// ---------------------------------------------------------------------------
app.post('/room/lobby/enable', async (req, res) => {
  const { roomCode, callerIdentity } = req.body;

  if (!roomCode || !callerIdentity) {
    return res.status(400).json({ error: 'roomCode and callerIdentity are required' });
  }

  const code = roomCode.toUpperCase();
  const roomData = await getRoomData(code);
  if (!roomData) return res.status(404).json({ error: 'Invalid or expired room code' });

  const validation = await validateModerator(code, callerIdentity);
  if (!validation.valid) return res.status(403).json({ error: validation.error });

  await redis.hset(roomKey(code), 'lobbyEnabled', 'true');

  console.log(`[audit] Lobby enabled: code=${code} by=${callerIdentity}`);
  res.json({ success: true });
});

// ---------------------------------------------------------------------------
// POST /room/lobby/disable — Disable lobby/waiting room
// Body: { roomCode, callerIdentity }
// Returns: { success }
// ---------------------------------------------------------------------------
app.post('/room/lobby/disable', async (req, res) => {
  const { roomCode, callerIdentity } = req.body;

  if (!roomCode || !callerIdentity) {
    return res.status(400).json({ error: 'roomCode and callerIdentity are required' });
  }

  const code = roomCode.toUpperCase();
  const roomData = await getRoomData(code);
  if (!roomData) return res.status(404).json({ error: 'Invalid or expired room code' });

  const validation = await validateModerator(code, callerIdentity);
  if (!validation.valid) return res.status(403).json({ error: validation.error });

  await redis.hdel(roomKey(code), 'lobbyEnabled');

  // Admit all waiting participants automatically
  const lobbyMembers = await redis.zrange(roomLobbyKey(code), 0, -1);
  if (lobbyMembers.length > 0) {
    await redis.del(roomLobbyKey(code));
  }

  console.log(`[audit] Lobby disabled: code=${code} by=${callerIdentity} (${lobbyMembers.length} auto-admitted)`);
  res.json({ success: true, autoAdmitted: lobbyMembers.length });
});

// ---------------------------------------------------------------------------
// POST /room/admit — Admit a participant from the lobby
// Body: { roomCode, callerIdentity, targetIdentity, targetDisplayName }
// Returns: { token, serverURL }
// ---------------------------------------------------------------------------
app.post('/room/admit', async (req, res) => {
  const { roomCode, callerIdentity, targetIdentity, targetDisplayName } = req.body;

  if (!roomCode || !callerIdentity || !targetIdentity) {
    return res.status(400).json({ error: 'roomCode, callerIdentity, and targetIdentity are required' });
  }

  const code = roomCode.toUpperCase();
  const roomData = await getRoomData(code);
  if (!roomData) return res.status(404).json({ error: 'Invalid or expired room code' });

  const validation = await validateModerator(code, callerIdentity);
  if (!validation.valid) return res.status(403).json({ error: validation.error });

  // Remove from lobby
  const lobbyMembers = await redis.zrange(roomLobbyKey(code), 0, -1);
  const memberEntry = lobbyMembers.find(m => {
    try { return JSON.parse(m).identity === targetIdentity; } catch { return false; }
  });
  if (memberEntry) {
    await redis.zrem(roomLobbyKey(code), memberEntry);
  }

  // Add to participants
  await addParticipant(code, targetIdentity);
  await redis.hset(roomRolesKey(code), targetIdentity, 'participant');

  // Generate token for the admitted participant
  const displayName = targetDisplayName || targetIdentity;
  const metadata = { role: 'participant' };
  const jwt = await createToken(targetIdentity, displayName, roomData.roomName, false, metadata);

  // Store admit status for lobby polling
  await redis.set(`room:${code}:lobby:${targetIdentity}:status`, 'admitted', 'EX', 300);
  await redis.set(`room:${code}:lobby:${targetIdentity}:token`, jwt, 'EX', 300);
  await redis.set(`room:${code}:lobby:${targetIdentity}:serverURL`, LIVEKIT_SERVER_URL, 'EX', 300);

  console.log(`[audit] Admitted from lobby: code=${code} identity=${targetIdentity} by=${callerIdentity}`);
  res.json({ success: true, identity: targetIdentity });
});

// ---------------------------------------------------------------------------
// POST /room/admit-all — Admit all participants from the lobby
// Body: { roomCode, callerIdentity }
// Returns: { success, admittedCount }
// ---------------------------------------------------------------------------
app.post('/room/admit-all', async (req, res) => {
  const { roomCode, callerIdentity } = req.body;

  if (!roomCode || !callerIdentity) {
    return res.status(400).json({ error: 'roomCode and callerIdentity are required' });
  }

  const code = roomCode.toUpperCase();
  const roomData = await getRoomData(code);
  if (!roomData) return res.status(404).json({ error: 'Invalid or expired room code' });

  const validation = await validateModerator(code, callerIdentity);
  if (!validation.valid) return res.status(403).json({ error: validation.error });

  const lobbyMembers = await redis.zrange(roomLobbyKey(code), 0, -1);
  let admittedCount = 0;

  for (const memberStr of lobbyMembers) {
    try {
      const member = JSON.parse(memberStr);
      await addParticipant(code, member.identity);
      await redis.hset(roomRolesKey(code), member.identity, 'participant');

      // Generate token
      const metadata = { role: 'participant' };
      const jwt = await createToken(member.identity, member.displayName || member.identity, roomData.roomName, false, metadata);

      // Store admit status for polling
      await redis.set(`room:${code}:lobby:${member.identity}:status`, 'admitted', 'EX', 300);
      await redis.set(`room:${code}:lobby:${member.identity}:token`, jwt, 'EX', 300);
      await redis.set(`room:${code}:lobby:${member.identity}:serverURL`, LIVEKIT_SERVER_URL, 'EX', 300);

      admittedCount++;
    } catch (e) {
      console.error(`[warn] Failed to admit lobby member:`, e.message);
    }
  }

  // Clear the lobby
  await redis.del(roomLobbyKey(code));

  console.log(`[audit] Admit all: code=${code} admitted=${admittedCount} by=${callerIdentity}`);
  res.json({ success: true, admittedCount });
});

// ---------------------------------------------------------------------------
// POST /room/deny — Deny a participant from the lobby
// Body: { roomCode, callerIdentity, targetIdentity }
// Returns: { success }
// ---------------------------------------------------------------------------
app.post('/room/deny', async (req, res) => {
  const { roomCode, callerIdentity, targetIdentity } = req.body;

  if (!roomCode || !callerIdentity || !targetIdentity) {
    return res.status(400).json({ error: 'roomCode, callerIdentity, and targetIdentity are required' });
  }

  const code = roomCode.toUpperCase();
  const roomData = await getRoomData(code);
  if (!roomData) return res.status(404).json({ error: 'Invalid or expired room code' });

  const validation = await validateModerator(code, callerIdentity);
  if (!validation.valid) return res.status(403).json({ error: validation.error });

  // Remove from lobby
  const lobbyMembers = await redis.zrange(roomLobbyKey(code), 0, -1);
  const memberEntry = lobbyMembers.find(m => {
    try { return JSON.parse(m).identity === targetIdentity; } catch { return false; }
  });
  if (memberEntry) {
    await redis.zrem(roomLobbyKey(code), memberEntry);
  }

  // Store denied status for lobby polling
  await redis.set(`room:${code}:lobby:${targetIdentity}:status`, 'denied', 'EX', 300);

  console.log(`[audit] Denied from lobby: code=${code} identity=${targetIdentity} by=${callerIdentity}`);
  res.json({ success: true });
});

// ---------------------------------------------------------------------------
// GET /room/lobby-status/:code/:identity — Check lobby status (polling)
// Returns: { status: "waiting"|"admitted"|"denied", position?, token?, serverURL? }
// ---------------------------------------------------------------------------
app.get('/room/lobby-status/:code/:identity', async (req, res) => {
  const code = req.params.code.toUpperCase();
  const identity = req.params.identity;

  // Check for admit/deny status
  const status = await redis.get(`room:${code}:lobby:${identity}:status`);

  if (status === 'admitted') {
    const token = await redis.get(`room:${code}:lobby:${identity}:token`);
    const serverURL = await redis.get(`room:${code}:lobby:${identity}:serverURL`);
    const roomData = await getRoomData(code);

    // Clean up lobby status keys
    await redis.del(`room:${code}:lobby:${identity}:status`);
    await redis.del(`room:${code}:lobby:${identity}:token`);
    await redis.del(`room:${code}:lobby:${identity}:serverURL`);

    return res.json({
      status: 'admitted',
      token,
      serverURL: serverURL || LIVEKIT_SERVER_URL,
      roomName: roomData?.roomName,
      roomType: roomData?.roomType || 'call',
    });
  }

  if (status === 'denied') {
    await redis.del(`room:${code}:lobby:${identity}:status`);
    return res.json({ status: 'denied' });
  }

  // Still waiting — calculate position
  const lobbyMembers = await redis.zrange(roomLobbyKey(code), 0, -1);
  let position = 0;
  for (let i = 0; i < lobbyMembers.length; i++) {
    try {
      const member = JSON.parse(lobbyMembers[i]);
      if (member.identity === identity) {
        position = i + 1;
        break;
      }
    } catch {}
  }

  if (position === 0) {
    // Not in lobby — might have been removed or room expired
    return res.json({ status: 'not_found' });
  }

  res.json({ status: 'waiting', position });
});

// ---------------------------------------------------------------------------
// POST /room/password — Set or change meeting password
// Body: { roomCode, callerIdentity, password } (password = null to remove)
// Returns: { success }
// ---------------------------------------------------------------------------
app.post('/room/password', async (req, res) => {
  const { roomCode, callerIdentity, password } = req.body;

  if (!roomCode || !callerIdentity) {
    return res.status(400).json({ error: 'roomCode and callerIdentity are required' });
  }

  const code = roomCode.toUpperCase();
  const roomData = await getRoomData(code);
  if (!roomData) return res.status(404).json({ error: 'Invalid or expired room code' });

  const validation = await validateModerator(code, callerIdentity);
  if (!validation.valid) return res.status(403).json({ error: validation.error });

  if (password === null || password === undefined || password === '') {
    // Remove password
    await redis.hdel(roomKey(code), 'passwordHash');
    console.log(`[audit] Password removed: code=${code} by=${callerIdentity}`);
    res.json({ success: true, hasPassword: false });
  } else {
    // Set password — bcrypt hash, 10 rounds
    const hash = await bcrypt.hash(password, 10);
    await redis.hset(roomKey(code), 'passwordHash', hash);
    console.log(`[audit] Password set: code=${code} by=${callerIdentity}`);
    res.json({ success: true, hasPassword: true });
  }
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
