// ============================================================================
// scheduling.js — Meeting Scheduling & Invitations (Phase 11)
//
// Express Router mounted at /meetings in index.js.
// Requires: auth.authenticateToken (global), auth.requireAuth (per-route).
//
// Routes:
//   POST   /meetings/schedule     — Create a scheduled meeting
//   GET    /meetings/upcoming     — List user's upcoming meetings
//   GET    /meetings/:id          — Get single meeting details
//   PATCH  /meetings/:id          — Reschedule or update a meeting
//   DELETE /meetings/:id          — Cancel a meeting
//   POST   /meetings/:id/invite   — Send invitations
//   POST   /meetings/:id/rsvp     — Invitee RSVP (accept/decline)
// ============================================================================

const express = require('express');
const crypto  = require('crypto');
const bcrypt  = require('bcryptjs');
const db      = require('./db');
const auth    = require('./auth');
const redis   = require('./redis');
const tiers   = require('./tiers');
const { AccessToken, RoomServiceClient } = require('livekit-server-sdk');
const { requireIdempotencyKey } = require('./idempotency');

const router = express.Router();

// ---------------------------------------------------------------------------
// LiveKit / Redis helpers — local copies to avoid circular dep with index.js
// ---------------------------------------------------------------------------
const _LIVEKIT_API_KEY    = process.env.LIVEKIT_API_KEY    || 'devkey';
const _LIVEKIT_API_SECRET = process.env.LIVEKIT_API_SECRET || 'secret';
const _LIVEKIT_SERVER_URL = process.env.LIVEKIT_SERVER_URL || 'ws://localhost:7880';
const _LIVEKIT_HTTP_URL   = process.env.LIVEKIT_HTTP_URL   || 'http://localhost:7880';
const _TOKEN_TTL_SECONDS  = 6 * 60 * 60;   // 6 hours
const _ROOM_CODE_EXPIRY   = 24 * 60 * 60;  // 24 hours

const _rKey  = code => `room:${code}`;
const _rPKey = code => `room:${code}:participants`;
const _rRKey = code => `room:${code}:roles`;
// Lobby / ban keys — MUST match index.js exactly so the existing host lobby panel,
// /room/admit, and /room/lobby-status flows handle scheduled-meeting waiters with no changes.
const _rBannedKey      = code => `room:${code}:banned`;
const _rLobbyKey       = code => `room:${code}:lobby`;
const _rLobbyNamesKey  = code => `room:${code}:lobby:names`;
// identity -> userId binding (MUST match index.js roomUserBindingKey exactly so
// validateModerator cross-checks work across both endpoints).
const roomUserBindingKey = code => `room:${code}:user-binding`;

// Scheduled-join password brute-force limit (per authenticated user, per meeting).
// Keyed on the verified JWT userId (not a client-rotatable identity), so it is a
// robust control: an attacker cannot reset it by generating a new identity.
const _PWD_RL_WINDOW = 300;  // seconds
const _PWD_RL_MAX    = 8;     // guesses per window before a 429 lockout

/// Constant-time, length-independent string comparison (SHA-256 digests are always
/// 32 bytes, so timingSafeEqual never throws and no length is leaked).
function _constantTimeStrEqual(a, b) {
  const ha = crypto.createHash('sha256').update(String(a)).digest();
  const hb = crypto.createHash('sha256').update(String(b)).digest();
  return crypto.timingSafeEqual(ha, hb);
}

// Single shared client — avoids constructing a new instance per request.
const _roomSvc = new RoomServiceClient(_LIVEKIT_HTTP_URL, _LIVEKIT_API_KEY, _LIVEKIT_API_SECRET);

async function _createLiveKitToken(identity, displayName, roomName, isHost, role = null, tools = false) {
  const tokenOpts = {
    identity,
    name: displayName,
    ttl: _TOKEN_TTL_SECONDS,
  };
  // Stamp the participant role + server-signed collaborative-tools entitlement into
  // the JWT metadata (mirrors index.js createToken), so LiveKit delivers it to all
  // participants and the client can reconcile the local role + tool gate from
  // authoritative server state. `tools` is keyed on the room's snapshotted hostTier
  // (unforgeable), NOT the joining user's tier (R9.1, R7.3).
  if (role) {
    tokenOpts.metadata = JSON.stringify({ role, tools: !!tools });
  }
  const lvToken = new AccessToken(_LIVEKIT_API_KEY, _LIVEKIT_API_SECRET, tokenOpts);
  lvToken.addGrant({
    room: roomName,
    roomJoin: true,
    canPublish: true,
    canSubscribe: true,
    canPublishData: true,
    roomCreate: isHost,
    roomAdmin: isHost,
  });
  return await lvToken.toJwt();
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const CODE_CHARS = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no I/O/0/1

function generateRoomCode() {
  let code = '';
  const bytes = crypto.randomBytes(6);
  for (let i = 0; i < 6; i++) {
    code += CODE_CHARS[bytes[i] % CODE_CHARS.length];
  }
  return code;
}

/** Validate IANA timezone identifier (basic check). */
function isValidTimezone(tz) {
  try {
    Intl.DateTimeFormat(undefined, { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// POST /meetings/schedule — Create a new scheduled meeting
// ---------------------------------------------------------------------------
router.post('/schedule', auth.requireAuth, requireIdempotencyKey, async (req, res) => {
  try {
    const {
      title,
      description,
      scheduledAt,
      durationMinutes,
      roomType,
      password,
      lobbyEnabled,
      recurrenceRule,
      hostTimezone,
      settings: rawSettings,
    } = req.body;

    // --- Validation ---
    if (!title || typeof title !== 'string' || title.trim().length === 0) {
      return res.status(400).json({ error: 'title is required' });
    }
    if (title.length > 200) {
      return res.status(400).json({ error: 'title must be 200 characters or fewer' });
    }
    if (!scheduledAt) {
      return res.status(400).json({ error: 'scheduledAt is required' });
    }
    const parsedDate = new Date(scheduledAt);
    if (isNaN(parsedDate.getTime())) {
      return res.status(400).json({ error: 'scheduledAt must be a valid ISO 8601 date' });
    }
    if (parsedDate <= new Date()) {
      return res.status(400).json({ error: 'scheduledAt must be in the future' });
    }
    if (!hostTimezone || !isValidTimezone(hostTimezone)) {
      return res.status(400).json({ error: 'hostTimezone must be a valid IANA timezone identifier' });
    }

    const duration = parseInt(durationMinutes, 10) || 60;
    if (duration < 1 || duration > 1440) {
      return res.status(400).json({ error: 'durationMinutes must be between 1 and 1440' });
    }

    const type = roomType === 'interview' ? 'interview' : 'call';

    // Server-side gate: scheduling an INTERVIEW requires the hiring tier (parity with
    // /room/create). Enforced authoritatively here, not just in the client.
    if (type === 'interview' &&
        !tiers.isFeatureAllowed(req.user && req.user.tier, tiers.FEATURES.HOST_INTERVIEW)) {
      return res.status(403).json({
        error: 'Scheduling an interview requires a hiring plan.',
        code: 'INSUFFICIENT_TIER',
        currentTier: (req.user && req.user.tier) || 'free',
        requiredTier: tiers.minTierForFeature(tiers.FEATURES.HOST_INTERVIEW),
      });
    }

    const roomCode = generateRoomCode();

    // Meeting-settings snapshot (mirrors /room/create validation). Stored with
    // the meeting so /meetings/:id/start can apply it to the room hash — the
    // settings must come from the meeting row, not from whichever client
    // arrives first (an invitee may start the room before the host).
    const VALID_CHAT_PERMS      = ['everyone', 'hostOnly', 'disabled'];
    const VALID_SHARE_PERMS     = ['hostOnly', 'everyone', 'request'];
    const VALID_CONFLICT_POLICY = ['oneattime', 'hostCanPreempt', 'anyCanPreempt'];
    const s = (rawSettings && typeof rawSettings === 'object') ? rawSettings : {};
    const settings = {
      muteOnJoin:          s.muteOnJoin          === true,
      cameraOffOnJoin:     s.cameraOffOnJoin     === true,
      joinBeforeHost:      s.joinBeforeHost      === true,
      allowUnmuting:       s.allowUnmuting       !== false, // default true
      chatPermissions:     VALID_CHAT_PERMS.includes(s.chatPermissions)         ? s.chatPermissions     : 'everyone',
      sharingPermissions:  VALID_SHARE_PERMS.includes(s.sharingPermissions)     ? s.sharingPermissions  : 'hostOnly',
      shareConflictPolicy: VALID_CONFLICT_POLICY.includes(s.shareConflictPolicy) ? s.shareConflictPolicy : 'oneattime',
    };

    const result = await db.query(
      `INSERT INTO scheduled_meetings
         (host_user_id, title, description, scheduled_at, duration_minutes,
          room_type, room_code, password, lobby_enabled, recurrence_rule, host_timezone, settings)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
       RETURNING *`,
      [
        req.user.userId,
        title.trim(),
        description || null,
        parsedDate.toISOString(),
        duration,
        type,
        roomCode,
        password || null,
        lobbyEnabled === true,
        recurrenceRule || null,
        hostTimezone,
        JSON.stringify(settings),
      ]
    );

    const meeting = formatMeeting(result.rows[0]);
    res.status(201).json(meeting);
  } catch (err) {
    console.error('[scheduling] POST /schedule error:', err.message);
    res.status(500).json({ error: 'Failed to create scheduled meeting' });
  }
});

// ---------------------------------------------------------------------------
// GET /meetings/upcoming — List user's upcoming scheduled meetings
// ---------------------------------------------------------------------------
router.get('/upcoming', auth.requireAuth, async (req, res) => {
  try {
    const limit = Math.min(parseInt(req.query.limit, 10) || 50, 200);
    const offset = parseInt(req.query.offset, 10) || 0;

    // Meetings the user is hosting
    const hosted = await db.query(
      `SELECT sm.*, 
              (SELECT COUNT(*) FROM meeting_invitees mi WHERE mi.meeting_id = sm.id) AS invitee_count
       FROM scheduled_meetings sm
       WHERE sm.host_user_id = $1
         AND sm.status = 'scheduled'
         AND sm.scheduled_at > NOW()
       ORDER BY sm.scheduled_at ASC
       LIMIT $2 OFFSET $3`,
      [req.user.userId, limit, offset]
    );

    // Meetings the user is invited to
    const invited = await db.query(
      `SELECT sm.*,
              mi.status AS rsvp_status,
              (SELECT COUNT(*) FROM meeting_invitees mi2 WHERE mi2.meeting_id = sm.id) AS invitee_count
       FROM scheduled_meetings sm
       JOIN meeting_invitees mi ON mi.meeting_id = sm.id
       WHERE mi.email = $1
         AND sm.status = 'scheduled'
         AND sm.scheduled_at > NOW()
       ORDER BY sm.scheduled_at ASC
       LIMIT $2 OFFSET $3`,
      [req.user.email, limit, offset]
    );

    res.json({
      hosted:  hosted.rows.map(formatMeeting),
      invited: invited.rows.map(r => ({
        ...formatMeeting(r),
        rsvpStatus: r.rsvp_status,
      })),
    });
  } catch (err) {
    console.error('[scheduling] GET /upcoming error:', err.message);
    res.status(500).json({ error: 'Failed to fetch upcoming meetings' });
  }
});

// ---------------------------------------------------------------------------
// GET /meetings/history — Past + live rooms the user hosted or joined
//
// Backed by the `meetings` / `meeting_participants` tables that /room/create
// and /room/join already write. Registered BEFORE /:id (Express matches in
// declaration order — "history" must not be captured as an :id param).
//
// Status truth policy (the DB alone lies — nothing writes status='ended' today):
//   • status='failed'  → excluded (the room never actually existed).
//   • status='ended'   → 'ended' (future-proof; honored if ever written).
//   • status='active'  → genuinely live ONLY if the Redis room key still exists
//     (same liveness definition as markPhantomMeetingsFailed); otherwise the
//     room expired (24h TTL) or was torn down → reported as 'ended'.
// Durations are only reported when ended_at exists — never fabricated.
// ---------------------------------------------------------------------------
router.get('/history', auth.requireAuth, async (req, res) => {
  try {
    const limit  = Math.min(parseInt(req.query.limit, 10) || 20, 50);
    const offset = parseInt(req.query.offset, 10) || 0;

    // One row per meeting the user hosted OR participated in. `my_role` prefers
    // the host relationship; otherwise the user's first participant row's role.
    // COUNT(DISTINCT identity) so rejoin rows don't inflate the count.
    const result = await db.query(
      `SELECT m.id, m.room_code, m.room_name, m.room_type, m.status,
              m.started_at, m.ended_at,
              CASE WHEN m.host_user_id = $1 THEN 'host'
                   ELSE COALESCE((
                     SELECT mp2.role FROM meeting_participants mp2
                     WHERE mp2.meeting_id = m.id AND mp2.user_id = $1
                     ORDER BY mp2.joined_at ASC LIMIT 1
                   ), 'participant')
              END AS my_role,
              (SELECT COUNT(DISTINCT mp3.identity) FROM meeting_participants mp3
               WHERE mp3.meeting_id = m.id) AS participant_count
       FROM meetings m
       WHERE m.status <> 'failed'
         AND (m.host_user_id = $1
              OR EXISTS (SELECT 1 FROM meeting_participants mp
                         WHERE mp.meeting_id = m.id AND mp.user_id = $1))
       ORDER BY m.started_at DESC
       LIMIT $2 OFFSET $3`,
      [req.user.userId, limit, offset]
    );

    // Liveness check: a DB-'active' row is only truly live if its Redis room
    // key still exists. Bounded fan-out (≤ limit ≤ 50 EXISTS calls).
    const meetings = await Promise.all(result.rows.map(async (row) => {
      let status = row.status;
      if (status === 'active') {
        let live = false;
        try {
          live = (await redis.exists(_rKey(row.room_code))) === 1;
        } catch (_) {
          // Redis unavailable — age fallback: within the 24h room TTL it may
          // still be live; older cannot be.
          live = (Date.now() - new Date(row.started_at).getTime()) < _ROOM_CODE_EXPIRY * 1000;
        }
        status = live ? 'active' : 'ended';
      }
      const durationMinutes = row.ended_at
        ? Math.max(0, Math.round((new Date(row.ended_at) - new Date(row.started_at)) / 60000))
        : null;
      return {
        id: row.id,
        roomCode: row.room_code,
        roomName: row.room_name,
        roomType: row.room_type,
        status,
        startedAt: row.started_at,
        endedAt: row.ended_at,
        durationMinutes,
        participantCount: parseInt(row.participant_count, 10) || 0,
        role: row.my_role,
      };
    }));

    res.json({ meetings });
  } catch (err) {
    console.error('[scheduling] GET /history error:', err.message);
    res.status(500).json({ error: 'Failed to fetch meeting history' });
  }
});

// ---------------------------------------------------------------------------
// GET /meetings/:id — Get a single meeting's details
// ---------------------------------------------------------------------------
router.get('/:id', auth.requireAuth, async (req, res) => {
  try {
    const { id } = req.params;

    const result = await db.query(
      `SELECT sm.*,
              (SELECT json_agg(json_build_object(
                'email', mi.email,
                'displayName', mi.display_name,
                'status', mi.status,
                'invitedAt', mi.invited_at
              )) FROM meeting_invitees mi WHERE mi.meeting_id = sm.id) AS invitees
       FROM scheduled_meetings sm
       WHERE sm.id = $1`,
      [id]
    );

    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    const row = result.rows[0];

    // Only host or invitees can view
    const isHost = row.host_user_id === req.user.userId;
    const isInvitee = (row.invitees || []).some(i => i.email === req.user.email);
    if (!isHost && !isInvitee) {
      return res.status(403).json({ error: 'Access denied' });
    }

    res.json({
      ...formatMeeting(row),
      invitees: row.invitees || [],
    });
  } catch (err) {
    console.error('[scheduling] GET /:id error:', err.message);
    res.status(500).json({ error: 'Failed to fetch meeting' });
  }
});

// ---------------------------------------------------------------------------
// PATCH /meetings/:id — Reschedule or update a meeting
// ---------------------------------------------------------------------------
router.patch('/:id', auth.requireAuth, async (req, res) => {
  try {
    const { id } = req.params;

    // Verify ownership
    const existing = await db.query(
      'SELECT * FROM scheduled_meetings WHERE id = $1',
      [id]
    );
    if (existing.rows.length === 0) {
      return res.status(404).json({ error: 'Meeting not found' });
    }
    if (existing.rows[0].host_user_id !== req.user.userId) {
      return res.status(403).json({ error: 'Only the host can modify this meeting' });
    }
    if (existing.rows[0].status !== 'scheduled') {
      return res.status(400).json({ error: 'Only scheduled meetings can be modified' });
    }

    // Build SET clause from allowed fields
    const allowed = [
      'title', 'description', 'scheduledAt', 'durationMinutes',
      'roomType', 'password', 'lobbyEnabled', 'recurrenceRule', 'hostTimezone',
    ];
    const setClauses = [];
    const values = [];
    let paramIndex = 1;

    for (const field of allowed) {
      if (req.body[field] !== undefined) {
        const col = camelToSnake(field);
        let val = req.body[field];

        // Field-specific validation
        if (field === 'scheduledAt') {
          const d = new Date(val);
          if (isNaN(d.getTime())) {
            return res.status(400).json({ error: 'scheduledAt must be a valid date' });
          }
          val = d.toISOString();
        }
        if (field === 'hostTimezone' && !isValidTimezone(val)) {
          return res.status(400).json({ error: 'hostTimezone must be a valid IANA timezone' });
        }
        if (field === 'durationMinutes') {
          val = parseInt(val, 10);
          if (val < 1 || val > 1440) {
            return res.status(400).json({ error: 'durationMinutes must be 1–1440' });
          }
        }
        if (field === 'title' && (!val || val.length > 200)) {
          return res.status(400).json({ error: 'title must be 1–200 characters' });
        }

        setClauses.push(`${col} = $${paramIndex}`);
        values.push(val);
        paramIndex++;
      }
    }

    if (setClauses.length === 0) {
      return res.status(400).json({ error: 'No fields to update' });
    }

    values.push(id);
    const result = await db.query(
      `UPDATE scheduled_meetings SET ${setClauses.join(', ')}
       WHERE id = $${paramIndex} RETURNING *`,
      values
    );

    res.json(formatMeeting(result.rows[0]));
  } catch (err) {
    console.error('[scheduling] PATCH /:id error:', err.message);
    res.status(500).json({ error: 'Failed to update meeting' });
  }
});

// ---------------------------------------------------------------------------
// DELETE /meetings/:id — Cancel a meeting
// ---------------------------------------------------------------------------
router.delete('/:id', auth.requireAuth, async (req, res) => {
  try {
    const { id } = req.params;

    const existing = await db.query(
      'SELECT * FROM scheduled_meetings WHERE id = $1',
      [id]
    );
    if (existing.rows.length === 0) {
      return res.status(404).json({ error: 'Meeting not found' });
    }
    if (existing.rows[0].host_user_id !== req.user.userId) {
      return res.status(403).json({ error: 'Only the host can cancel this meeting' });
    }

    await db.query(
      `UPDATE scheduled_meetings SET status = 'cancelled' WHERE id = $1`,
      [id]
    );

    res.json({ success: true, message: 'Meeting cancelled' });
  } catch (err) {
    console.error('[scheduling] DELETE /:id error:', err.message);
    res.status(500).json({ error: 'Failed to cancel meeting' });
  }
});

// ---------------------------------------------------------------------------
// POST /meetings/:id/invite — Send invitations for a meeting
// ---------------------------------------------------------------------------
router.post('/:id/invite', auth.requireAuth, requireIdempotencyKey, async (req, res) => {
  try {
    const { id } = req.params;
    const { invitees } = req.body; // [{ email, displayName? }]

    if (!Array.isArray(invitees) || invitees.length === 0) {
      return res.status(400).json({ error: 'invitees array is required' });
    }
    if (invitees.length > 100) {
      return res.status(400).json({ error: 'Maximum 100 invitees per request' });
    }

    // Verify ownership
    const meeting = await db.query(
      'SELECT * FROM scheduled_meetings WHERE id = $1',
      [id]
    );
    if (meeting.rows.length === 0) {
      return res.status(404).json({ error: 'Meeting not found' });
    }
    if (meeting.rows[0].host_user_id !== req.user.userId) {
      return res.status(403).json({ error: 'Only the host can invite participants' });
    }

    const created = [];
    const skipped = [];

    for (const inv of invitees) {
      if (!inv.email || typeof inv.email !== 'string') {
        skipped.push({ email: inv.email, reason: 'invalid email' });
        continue;
      }
      const email = inv.email.trim().toLowerCase();

      try {
        const result = await db.query(
          `INSERT INTO meeting_invitees (meeting_id, email, display_name)
           VALUES ($1, $2, $3)
           ON CONFLICT (meeting_id, email) DO NOTHING
           RETURNING *`,
          [id, email, inv.displayName || null]
        );
        if (result.rows.length > 0) {
          created.push({ email, status: 'invited' });
        } else {
          skipped.push({ email, reason: 'already invited' });
        }
      } catch (insertErr) {
        skipped.push({ email, reason: insertErr.message });
      }
    }

    // Send invitation emails (fire-and-forget)
    if (created.length > 0) {
      const meetingData = meeting.rows[0];
      const { sendMeetingInvitationEmail } = require('./mailer');
      if (typeof sendMeetingInvitationEmail === 'function') {
        for (const inv of created) {
          sendMeetingInvitationEmail(inv.email, {
            title:        meetingData.title,
            scheduledAt:  meetingData.scheduled_at,
            duration:     meetingData.duration_minutes,
            roomCode:     meetingData.room_code,
            hostName:     req.user.displayName,
            hostTimezone: meetingData.host_timezone,
            password:     meetingData.password,
          }).catch(err => console.error('[scheduling] email error:', err.message));
        }
      }
    }

    res.json({ created, skipped });
  } catch (err) {
    console.error('[scheduling] POST /:id/invite error:', err.message);
    res.status(500).json({ error: 'Failed to send invitations' });
  }
});

// ---------------------------------------------------------------------------
// POST /meetings/:id/rsvp — Accept or decline a meeting invitation
// ---------------------------------------------------------------------------
router.post('/:id/rsvp', auth.requireAuth, async (req, res) => {
  try {
    const { id } = req.params;
    const { response } = req.body; // 'accepted' | 'declined'

    if (!['accepted', 'declined'].includes(response)) {
      return res.status(400).json({ error: 'response must be "accepted" or "declined"' });
    }

    const result = await db.query(
      `UPDATE meeting_invitees
       SET status = $1, responded_at = NOW()
       WHERE meeting_id = $2 AND email = $3
       RETURNING *`,
      [response, id, req.user.email]
    );

    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Invitation not found' });
    }

    res.json({ success: true, status: response });
  } catch (err) {
    console.error('[scheduling] POST /:id/rsvp error:', err.message);
    res.status(500).json({ error: 'Failed to update RSVP' });
  }
});

// ---------------------------------------------------------------------------
// POST /meetings/:id/start — Start or join a scheduled meeting
//
// Registers the meeting's pre-assigned room code in Redis (if not already
// active) and issues a LiveKit JWT. Both the host and known invitees may
// call this endpoint. The host receives roomCreate/roomAdmin grants;
// invitees receive participant-level grants.
//
// Requires auth. Body: { identity, displayName }
// Returns: { roomCode, roomName, token, serverURL, roomType }
// ---------------------------------------------------------------------------
router.post('/:id/start', auth.requireAuth, async (req, res) => {
  try {
    const { id } = req.params;
    const { identity, displayName } = req.body;

    if (!identity || typeof identity !== 'string' || identity.trim().length === 0) {
      return res.status(400).json({ error: 'identity is required' });
    }
    if (!displayName || typeof displayName !== 'string' || displayName.trim().length === 0) {
      return res.status(400).json({ error: 'displayName is required' });
    }

    const meetingResult = await db.query(
      'SELECT * FROM scheduled_meetings WHERE id = $1',
      [id]
    );
    if (meetingResult.rows.length === 0) {
      return res.status(404).json({ error: 'Meeting not found' });
    }
    const meeting = meetingResult.rows[0];

    if (meeting.status === 'cancelled') {
      return res.status(410).json({ error: 'This meeting has been cancelled' });
    }

    // Determine caller role: host or invited participant
    const isHost = (meeting.host_user_id === req.user.userId);
    if (!isHost) {
      const inviteCheck = await db.query(
        'SELECT id FROM meeting_invitees WHERE meeting_id = $1 AND email = $2',
        [id, req.user.email]
      );
      if (inviteCheck.rows.length === 0) {
        return res.status(403).json({ error: 'You are not the host or an invitee of this meeting' });
      }
    }

    const roomCode = meeting.room_code;
    const roomName = `inter-${roomCode}`;
    const roomType = meeting.room_type || 'call';

    // -----------------------------------------------------------------------
    // Non-host enforcement: password + waiting room (parity with /room/join).
    //
    // SECURITY: previously the Join button issued a LiveKit token directly from
    // this endpoint, bypassing the meeting's password and lobby entirely. The host
    // (who owns the meeting) bypasses these checks; every other invitee must pass
    // them before a token is ever created. All rejection paths `return` before any
    // token is issued or the room is registered.
    // -----------------------------------------------------------------------
    if (!isHost) {
      // Ban check (parity with /room/join; defense-in-depth, identity-scoped).
      const isBanned = await redis.sismember(_rBannedKey(roomCode), identity);
      if (isBanned) {
        console.log(`[audit] Scheduled join blocked (banned): meeting=${id} identity=${identity}`);
        return res.status(403).json({ error: 'You have been removed from this meeting.', banned: true });
      }

      // Password enforcement: constant-time compare + per-user brute-force lockout.
      if (meeting.password) {
        const supplied = req.body.password;
        if (!supplied) {
          // No password yet — prompt for it (the client shows a password dialog).
          return res.status(401).json({ error: 'This meeting requires a password', passwordRequired: true });
        }
        // Rate-limit ACTUAL guesses (a missing password above is not counted).
        const rlKey = `ratelimit:sched-pwd:${id}:${req.user.userId}`;
        const attempts = await redis.incr(rlKey);
        if (attempts === 1) await redis.expire(rlKey, _PWD_RL_WINDOW);
        if (attempts > _PWD_RL_MAX) {
          console.log(`[audit] Scheduled join pwd rate-limited: meeting=${id} user=${req.user.userId}`);
          return res.status(429).json({ error: 'Too many password attempts. Please wait a few minutes and try again.' });
        }
        if (!_constantTimeStrEqual(supplied, meeting.password)) {
          return res.status(401).json({ error: 'Incorrect password', passwordRequired: true });
        }
        await redis.del(rlKey); // correct password — reset the counter
      }

      // Waiting room enforcement: place the invitee in the lobby and return a
      // waiting response. Uses the SAME Redis keys + pollToken as /room/join so the
      // host's lobby panel, /room/admit, and /room/lobby-status work unchanged.
      if (meeting.lobby_enabled === true) {
        const alreadyAdmitted = await redis.sismember(_rPKey(roomCode), identity);
        if (!alreadyAdmitted) {
          const score = Date.now();
          const pipe = redis.pipeline();
          pipe.zadd(_rLobbyKey(roomCode), score, identity);
          pipe.expire(_rLobbyKey(roomCode), _ROOM_CODE_EXPIRY);
          pipe.hset(_rLobbyNamesKey(roomCode), identity, displayName);
          pipe.expire(_rLobbyNamesKey(roomCode), _ROOM_CODE_EXPIRY);
          await pipe.exec();
          const position = await redis.zrank(_rLobbyKey(roomCode), identity);
          const pollToken = crypto.randomBytes(32).toString('hex');
          await redis.set(`room:${roomCode}:lobby:${identity}:pollToken`, pollToken, 'EX', _ROOM_CODE_EXPIRY);
          console.log(`[audit] Scheduled lobby wait: meeting=${id} identity=${identity} position=${(position || 0) + 1}`);
          return res.json({ status: 'waiting', position: (position || 0) + 1, pollToken, roomCode });
        }
      }
    }

    // Verify LiveKit is reachable before touching Redis or issuing a token.
    // listRooms() makes a real HTTP call to the server; if it throws we know
    // the server is offline and we should fail fast rather than handing the
    // client a token that cannot be used.
    try {
      // Empty filter → list all rooms; this is a real HTTP round-trip to LiveKit
      // regardless of whether roomName exists, so it reliably detects unreachability.
      await _roomSvc.listRooms([]);
    } catch (livekitErr) {
      console.error(`[scheduling] LiveKit unreachable for meeting ${id}:`, livekitErr.message);
      return res.status(503).json({ error: 'Call server is currently unavailable. Please try again shortly.' });
    }

    // Register room in Redis if not already active (idempotent)
    const alreadyExists = await redis.exists(_rKey(roomCode));
    if (!alreadyExists) {
      // Meeting-settings snapshot stored at schedule time (migration 020).
      // The HOST may override the snapshot from the green room's Meeting
      // Settings sheet (req.body.settings) — enum fields are allowlisted.
      let settingsOverride = null;
      if (isHost && req.body.settings && typeof req.body.settings === 'object') {
        const o = req.body.settings;
        const chatAllowed  = ['everyone', 'hostOnly', 'disabled'];
        const shareAllowed = ['hostOnly', 'everyone', 'request'];
        const conflictAllowed = ['oneattime', 'hostCanPreempt', 'anyCanPreempt'];
        settingsOverride = {
          muteOnJoin:          o.muteOnJoin          === true,
          cameraOffOnJoin:     o.cameraOffOnJoin     === true,
          joinBeforeHost:      o.joinBeforeHost      === true,
          allowUnmuting:       o.allowUnmuting       !== false,
          chatPermissions:     chatAllowed.includes(o.chatPermissions) ? o.chatPermissions : 'everyone',
          sharingPermissions:  shareAllowed.includes(o.sharingPermissions) ? o.sharingPermissions : 'hostOnly',
          shareConflictPolicy: conflictAllowed.includes(o.shareConflictPolicy) ? o.shareConflictPolicy : 'oneattime',
        };
        console.log(`[audit] Scheduled start settings override applied: meeting=${id}`);
      }

      const meetingsTableId = await registerScheduledRoom(meeting, {
        hostIdentity: identity,
        hostTier: req.user.tier || 'free',
        settings: settingsOverride,
      });

      if (isHost && meetingsTableId) {
        try {
          await db.query(
            `INSERT INTO meeting_participants (meeting_id, user_id, identity, display_name, role)
             VALUES ($1, $2, $3, $4, $5)`,
            [meetingsTableId, req.user.userId, identity, displayName,
             (roomType === 'interview') ? 'interviewer' : 'host']
          );
        } catch (dbErr) {
          console.error('[warn] Failed to persist scheduled host participant:', dbErr.message);
        }
      }

      if (isHost) {
        const hostRole = (roomType === 'interview') ? 'interviewer' : 'host';
        await redis.hset(_rRKey(roomCode), identity, hostRole);
        await redis.expire(_rRKey(roomCode), _ROOM_CODE_EXPIRY);
      }
    } else {
      // Room already active — add this participant to the set
      await redis.sadd(_rPKey(roomCode), identity);
    }

    // Bind authenticated userId -> identity so validateModerator can cross-check
    // request-body callerIdentity against the verified user (parity with /room/create).
    // Refreshed on every start so a host who rejoins with a new identity is re-bound.
    if (req.user?.userId != null) {
      await redis.hset(roomUserBindingKey(roomCode), identity, String(req.user.userId));
      await redis.expire(roomUserBindingKey(roomCode), _ROOM_CODE_EXPIRY);
    }
    // If the HOST rejoins (e.g. left and came back), their identity changes; point
    // hostIdentity at the current identity so host-presence / join-before-host checks
    // and moderation host-binding stay correct.
    if (isHost) {
      await redis.hset(_rKey(roomCode), 'hostIdentity', identity);
    }

    // Room settings + entitlement basis — read back from the room hash (the
    // authoritative copy, whether this call created it or an earlier one did)
    // so every starter/joiner applies the same host-configured behaviour and the
    // SAME server-snapshotted hostTier. Shape mirrors /room/join's settings block.
    const roomData = await redis.hgetall(_rKey(roomCode));

    // Server-signed collaborative-tools entitlement, derived from the room's
    // snapshotted HOST tier (the same basis as cloud recording), NOT the joining
    // user's tier — so BOTH the interviewer and the candidate of a hiring host's
    // room are entitled regardless of the candidate's own plan (R9.1, R7.2, R7.3).
    const tools = tiers.isFeatureAllowed(roomData.hostTier, tiers.FEATURES.HOST_INTERVIEW);

    // Role for the JWT metadata (authoritative; the client reconciles local role from it).
    const tokenRole = isHost
      ? ((roomType === 'interview') ? 'interviewer' : 'host')
      : ((roomType === 'interview') ? 'interviewee' : 'participant');
    const jwt = await _createLiveKitToken(identity, displayName, roomName, isHost, tokenRole, tools);

    console.log(`[audit] Scheduled meeting started: meeting=${id} code=${roomCode} isHost=${isHost}`);

    res.json({
      roomCode,
      roomName,
      token: jwt,
      serverURL: _LIVEKIT_SERVER_URL,
      roomType,
      isHost,
      roomSettings: {
        meetingDisplayName:  roomData.meetingDisplayName  || meeting.title || '',
        muteOnJoin:          roomData.muteOnJoin          === 'true',
        cameraOffOnJoin:     roomData.cameraOffOnJoin     === 'true',
        joinBeforeHost:      roomData.joinBeforeHost      === 'true',
        allowUnmuting:       roomData.allowUnmuting       !== 'false', // default true
        chatPermissions:     roomData.chatPermissions     || 'everyone',
        sharingPermissions:  roomData.sharingPermissions  || 'hostOnly',
        shareConflictPolicy: roomData.shareConflictPolicy || 'oneattime',
        lobbyEnabled:        roomData.lobbyEnabled        === 'true',
        hasPassword:         !!roomData.passwordHash,
      },
    });
  } catch (err) {
    console.error('[scheduling] POST /:id/start error:', err.message);
    res.status(500).json({ error: 'Failed to start meeting' });
  }
});

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

function formatMeeting(row) {
  return {
    id:              row.id,
    hostUserId:      row.host_user_id,
    title:           row.title,
    description:     row.description,
    scheduledAt:     row.scheduled_at,
    durationMinutes: row.duration_minutes,
    roomType:        row.room_type,
    roomCode:        row.room_code,
    password:        row.password ? true : undefined, // don't leak password value
    lobbyEnabled:    row.lobby_enabled,
    recurrenceRule:  row.recurrence_rule,
    hostTimezone:    row.host_timezone,
    status:          row.status,
    inviteeCount:    row.invitee_count != null ? parseInt(row.invitee_count, 10) : undefined,
    createdAt:       row.created_at,
    updatedAt:       row.updated_at,
  };
}

function camelToSnake(str) {
  return str.replace(/[A-Z]/g, letter => `_${letter.toLowerCase()}`);
}

// ---------------------------------------------------------------------------
// Shared room registration
//
// Registers the Redis room hash + `meetings` table row for a scheduled
// meeting. Used by POST /meetings/:id/start AND /room/join's join-before-host
// auto-registration (index.js): when the meeting allows joining before the
// host, the first participant to arrive opens the room. `hostIdentity` is ''
// in that case — the host's later /start repoints it and binds moderation.
// ---------------------------------------------------------------------------
async function registerScheduledRoom(meeting, { hostIdentity = '', hostTier = 'free', settings = null } = {}) {
  const roomCode = meeting.room_code;
  const roomName = `inter-${roomCode}`;
  const roomType = meeting.room_type || 'call';
  const lobbyEnabledStr = (meeting.lobby_enabled === true) ? 'true' : 'false';
  let passwordHash = '';
  if (meeting.password && typeof meeting.password === 'string' && meeting.password.length > 0) {
    passwordHash = await bcrypt.hash(meeting.password, 10);
  }

  // Settings: explicit override (host green-room edit) > schedule-time snapshot.
  const ms = (settings && typeof settings === 'object')
    ? settings
    : ((meeting.settings && typeof meeting.settings === 'object') ? meeting.settings : {});

  const pipe = redis.pipeline();
  pipe.hset(_rKey(roomCode),
    'roomName',     roomName,
    'createdAt',    Date.now().toString(),
    'hostIdentity', hostIdentity,
    'roomType',     roomType,
    'hostTier',     hostTier,
    // Meeting settings (parity with /room/create's hash fields)
    'meetingDisplayName',  meeting.title || '',
    'muteOnJoin',          ms.muteOnJoin          === true  ? 'true' : 'false',
    'cameraOffOnJoin',     ms.cameraOffOnJoin     === true  ? 'true' : 'false',
    'joinBeforeHost',      ms.joinBeforeHost      === true  ? 'true' : 'false',
    'allowUnmuting',       ms.allowUnmuting       === false ? 'false' : 'true',
    'chatPermissions',     ms.chatPermissions     || 'everyone',
    'sharingPermissions',  ms.sharingPermissions  || 'hostOnly',
    'shareConflictPolicy', ms.shareConflictPolicy || 'oneattime',
    'lobbyEnabled', lobbyEnabledStr,
    'passwordHash', passwordHash
  );
  pipe.expire(_rKey(roomCode), _ROOM_CODE_EXPIRY);
  if (hostIdentity) {
    pipe.sadd(_rPKey(roomCode), hostIdentity);
    pipe.expire(_rPKey(roomCode), _ROOM_CODE_EXPIRY);
  }
  await pipe.exec();

  // Persist a `meetings` table row (parity with /room/create). The room hash's
  // meetingId MUST reference meetings.id — meeting_participants' FK points
  // there, NOT at scheduled_meetings.
  let meetingsTableId = null;
  try {
    const meetingRow = await db.query(
      `INSERT INTO meetings (host_user_id, room_code, room_name, room_type)
       VALUES ($1, $2, $3, $4)
       RETURNING id`,
      [meeting.host_user_id, roomCode, roomName, roomType]
    );
    meetingsTableId = meetingRow.rows[0].id;
    await redis.hset(_rKey(roomCode), 'meetingId', meetingsTableId);
    await redis.hset(_rKey(roomCode), 'scheduledMeetingId', meeting.id);
    console.log(`[audit] Scheduled meeting persisted: meetings.id=${meetingsTableId} for room ${roomCode}`);
  } catch (dbErr) {
    console.error('[warn] Failed to persist scheduled meeting row:', dbErr.message);
  }
  return meetingsTableId;
}

router.registerScheduledRoom = registerScheduledRoom;
// Exposed for integration tests (mirrors index.js `createToken`): lets the
// tier-gate suite decode a scheduled-meeting LiveKit token and assert the
// server-signed `tools` entitlement is stamped from the room's hostTier.
router._createLiveKitToken = _createLiveKitToken;

module.exports = router;
