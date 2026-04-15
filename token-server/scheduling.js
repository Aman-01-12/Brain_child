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
const db      = require('./db');
const auth    = require('./auth');
const redis   = require('./redis');
const { AccessToken } = require('livekit-server-sdk');

const router = express.Router();

// ---------------------------------------------------------------------------
// LiveKit / Redis helpers — local copies to avoid circular dep with index.js
// ---------------------------------------------------------------------------
const _LIVEKIT_API_KEY    = process.env.LIVEKIT_API_KEY    || 'devkey';
const _LIVEKIT_API_SECRET = process.env.LIVEKIT_API_SECRET || 'secret';
const _LIVEKIT_SERVER_URL = process.env.LIVEKIT_SERVER_URL || 'ws://localhost:7880';
const _TOKEN_TTL_SECONDS  = 6 * 60 * 60;   // 6 hours
const _ROOM_CODE_EXPIRY   = 24 * 60 * 60;  // 24 hours

const _rKey  = code => `room:${code}`;
const _rPKey = code => `room:${code}:participants`;
const _rRKey = code => `room:${code}:roles`;

async function _createLiveKitToken(identity, displayName, roomName, isHost) {
  const lvToken = new AccessToken(_LIVEKIT_API_KEY, _LIVEKIT_API_SECRET, {
    identity,
    name: displayName,
    ttl: _TOKEN_TTL_SECONDS,
  });
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
router.post('/schedule', auth.requireAuth, async (req, res) => {
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
    const roomCode = generateRoomCode();

    const result = await db.query(
      `INSERT INTO scheduled_meetings
         (host_user_id, title, description, scheduled_at, duration_minutes,
          room_type, room_code, password, lobby_enabled, recurrence_rule, host_timezone)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
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
router.post('/:id/invite', auth.requireAuth, async (req, res) => {
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

    // Register room in Redis if not already active (idempotent)
    const alreadyExists = await redis.exists(_rKey(roomCode));
    if (!alreadyExists) {
      const pipe = redis.pipeline();
      pipe.hset(_rKey(roomCode),
        'roomName',     roomName,
        'createdAt',    Date.now().toString(),
        'hostIdentity', identity,
        'roomType',     roomType,
        'hostTier',     req.user.tier || 'free',
        'meetingId',    id
      );
      pipe.expire(_rKey(roomCode), _ROOM_CODE_EXPIRY);
      pipe.sadd(_rPKey(roomCode), identity);
      pipe.expire(_rPKey(roomCode), _ROOM_CODE_EXPIRY);
      await pipe.exec();

      if (isHost) {
        const hostRole = (roomType === 'interview') ? 'interviewer' : 'host';
        await redis.hset(_rRKey(roomCode), identity, hostRole);
        await redis.expire(_rRKey(roomCode), _ROOM_CODE_EXPIRY);
      }
    } else {
      // Room already active — add this participant to the set
      await redis.sadd(_rPKey(roomCode), identity);
    }

    const jwt = await _createLiveKitToken(identity, displayName, roomName, isHost);

    console.log(`[audit] Scheduled meeting started: meeting=${id} code=${roomCode} isHost=${isHost}`);

    res.json({
      roomCode,
      roomName,
      token: jwt,
      serverURL: _LIVEKIT_SERVER_URL,
      roomType,
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

module.exports = router;
