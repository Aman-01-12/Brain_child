// ============================================================================
// Team Management Module — Inter Token Server
// Phase 11.4
//
// Provides Express Router for:
//   POST   /teams                 — Create a team
//   GET    /teams                 — List user's teams
//   GET    /teams/:id             — Get team details + members
//   PATCH  /teams/:id             — Update team name/description
//   DELETE /teams/:id             — Delete team (owner only)
//   POST   /teams/:id/members     — Invite member(s) by email
//   PATCH  /teams/:id/members/:mid — Update member role
//   DELETE /teams/:id/members/:mid — Remove member
//   POST   /teams/:id/members/accept — Accept team invitation
//
// Design:
//   - Owner is the user who created the team
//   - Roles: owner, admin, member
//   - Admins can invite/remove members; only owner can delete team or change roles
//   - Invitations keyed by email; user_id linked when accepted
// ============================================================================

const express = require('express');
const router = express.Router();
const crypto = require('crypto');
const multer = require('multer');
const FileType = require('file-type'); // v16 CommonJS — exports fromFile, fromBuffer
const db = require('./db');
const auth = require('./auth');
const redis = require('./redis');
const { requireIdempotencyKey } = require('./idempotency');
const { emitTeamEvent, evictUserFromTeam, evictTeam } = require('./teamsRealtime');
const { isMimeAllowed, sanitizeFilename } = require('./fileValidation');
const { S3Client, PutObjectCommand, GetObjectCommand, DeleteObjectCommand } = require('@aws-sdk/client-s3');
const { getSignedUrl } = require('@aws-sdk/s3-request-presigner');

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function formatTeam(row) {
  return {
    id: row.id,
    name: row.name,
    description: row.description,
    ownerUserId: row.owner_user_id,
    memberCount: parseInt(row.member_count || '0', 10),
    unreadCount: parseInt(row.unread_count || '0', 10),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function formatMember(row) {
  return {
    id: row.id,
    teamId: row.team_id,
    userId: row.user_id,
    email: row.email,
    displayName: row.display_name || row.email,
    role: row.role,
    status: row.status,
    invitedAt: row.invited_at,
    joinedAt: row.joined_at,
  };
}

// ---------------------------------------------------------------------------
// Team chat — constants, membership guard, and helpers (Task 3)
// ---------------------------------------------------------------------------

const MESSAGE_MAX_LENGTH    = 4000; // chars per text message
const MESSAGES_PAGE_DEFAULT = 50;
const MESSAGES_PAGE_MAX      = 100;
const MSG_RATE_MAX           = 60;  // messages per window, per user per team
const MSG_RATE_WINDOW_SEC    = 60;
const MEMBER_ADD_RATE_MAX    = 30;  // add-by-email attempts per window (H9 — bound enumeration)
const MEMBER_ADD_WINDOW_SEC  = 60;

// Validates a v4-style UUID before it reaches a Postgres UUID column comparison
// (a malformed value would otherwise raise a 22P02 invalid-input-syntax error).
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

// Team file sharing (S3-backed, persistent — distinct from the in-call chat's
// local-disk + 24h-TTL files). Bytes live in S3 under a team-prefixed key; only
// metadata is stored in Postgres (team_files).
const AWS_REGION             = process.env.AWS_REGION || 'us-east-1';
const S3_TEAM_FILES_BUCKET   = process.env.S3_TEAM_FILES_BUCKET || 'inter-team-files';
const TEAM_FILE_MAX_BYTES    = 25 * 1024 * 1024;        // 25 MB per file (hard cap via multer)
const TEAM_FILES_MAX_TOTAL_BYTES = 1024 * 1024 * 1024;  // 1 GB per team (soft cumulative guardrail)

// Module-level S3 client (created once, reused across requests) — mirrors the
// recordings client in index.js.
const s3Client = new S3Client({ region: AWS_REGION });

// Multer: hold the upload in memory (we stream it straight to S3, never to disk)
// with a hard per-file size cap and exactly one file per request.
const teamFileUpload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: TEAM_FILE_MAX_BYTES, files: 1 },
});

// requireTeamMembership — authorization guard for every team-scoped resource.
// Derives membership from the AUTHENTICATED user (req.user.userId) intersected
// with the team id in the path; the client-supplied id is never trusted as an
// authorization input (C1 — cross-tenant / IDOR prevention). On success it
// attaches req.teamRole so handlers can apply role checks without re-querying.
async function requireTeamMembership(req, res, next) {
  try {
    const result = await db.query(
      `SELECT role FROM team_members
       WHERE team_id = $1 AND user_id = $2 AND status = 'active'`,
      [req.params.id, req.user.userId]
    );
    if (result.rows.length === 0) {
      return res.status(403).json({ error: 'Not a member of this team' });
    }
    req.teamRole = result.rows[0].role;
    return next();
  } catch (err) {
    console.error('[Teams] Membership check error:', err);
    return res.status(500).json({ error: 'Failed to verify membership' });
  }
}

// Fixed-window per-user-per-team rate limiter (H8/H9 — flooding / enumeration).
// Mirrors the existing Redis INCR limiter pattern (index.js checkRateLimit).
// Fails OPEN on Redis error, consistent with the idempotency middleware:
// availability is preferred over hard-blocking on a cache outage.
async function checkTeamRateLimit(bucket, teamId, userId, max, windowSec) {
  const key = `ratelimit:team-${bucket}:${teamId}:${userId}`;
  try {
    const count = await redis.incr(key);
    if (count === 1) await redis.expire(key, windowSec);
    return count <= max;
  } catch (err) {
    console.warn(`[Teams] Rate-limit check failed (allowing) bucket=${bucket}:`, err.message);
    return true;
  }
}

// Per-user-per-team message send limiter (H8 — message flooding / DoS).
function checkMessageRateLimit(teamId, userId) {
  return checkTeamRateLimit('msg', teamId, userId, MSG_RATE_MAX, MSG_RATE_WINDOW_SEC);
}

// Shape a team_messages row (optionally LEFT JOINed with team_files) for the
// client. The server-only S3 key is never included.
function formatMessage(row) {
  const msg = {
    id: String(row.id),               // BIGSERIAL -> string to avoid 2^53 loss
    teamId: row.team_id,
    senderUserId: row.sender_user_id,
    senderName: row.sender_name,
    kind: row.kind,
    body: row.body,
    createdAt: row.created_at,
  };
  if (row.file_id) {
    msg.file = {
      fileId: row.file_id,
      originalName: row.original_name,
      mimeType: row.mime_type,
      sizeBytes: row.size_bytes != null ? Number(row.size_bytes) : null,
      isImage: row.is_image === true,
    };
  }
  return msg;
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

// POST /teams — Create a new team
router.post('/', auth.requireAuth, requireIdempotencyKey, async (req, res) => {
  try {
    const { name, description } = req.body;

    if (!name || typeof name !== 'string' || name.trim().length === 0) {
      return res.status(400).json({ error: 'Team name is required' });
    }
    if (name.trim().length > 100) {
      return res.status(400).json({ error: 'Team name must be 100 characters or less' });
    }
    if (description && description.length > 500) {
      return res.status(400).json({ error: 'Description must be 500 characters or less' });
    }

    const result = await db.query(
      `INSERT INTO teams (name, owner_user_id, description)
       VALUES ($1, $2, $3)
       RETURNING *`,
      [name.trim(), req.user.userId, description?.trim() || null]
    );

    const team = result.rows[0];

    // Add owner as first member
    await db.query(
      `INSERT INTO team_members (team_id, user_id, email, role, status, joined_at)
       VALUES ($1, $2, $3, 'owner', 'active', NOW())`,
      [team.id, req.user.userId, req.user.email]
    );

    return res.status(201).json(formatTeam({ ...team, member_count: '1' }));
  } catch (err) {
    console.error('[Teams] Create error:', err);
    return res.status(500).json({ error: 'Failed to create team' });
  }
});

// GET /teams — List user's teams
router.get('/', auth.requireAuth, async (req, res) => {
  try {
    const result = await db.query(
      `SELECT t.*, COUNT(tm2.id)::TEXT AS member_count,
              COALESCE((
                SELECT COUNT(*) FROM team_messages msg
                WHERE msg.team_id = t.id
                  AND msg.id > COALESCE((
                    SELECT c.last_read_message_id FROM team_read_cursors c
                    WHERE c.team_id = t.id AND c.user_id = $1
                  ), 0)
              ), 0)::TEXT AS unread_count
       FROM teams t
       JOIN team_members tm ON tm.team_id = t.id AND tm.user_id = $1 AND tm.status = 'active'
       LEFT JOIN team_members tm2 ON tm2.team_id = t.id AND tm2.status = 'active'
       GROUP BY t.id
       ORDER BY t.created_at DESC`,
      [req.user.userId]
    );

    return res.json({ teams: result.rows.map(formatTeam) });
  } catch (err) {
    console.error('[Teams] List error:', err);
    return res.status(500).json({ error: 'Failed to list teams' });
  }
});

// GET /teams/:id — Get team details + members
router.get('/:id', auth.requireAuth, async (req, res) => {
  try {
    // Check membership
    const memberCheck = await db.query(
      `SELECT role FROM team_members
       WHERE team_id = $1 AND user_id = $2 AND status = 'active'`,
      [req.params.id, req.user.userId]
    );

    if (memberCheck.rows.length === 0) {
      return res.status(403).json({ error: 'Not a member of this team' });
    }

    const teamResult = await db.query('SELECT * FROM teams WHERE id = $1', [req.params.id]);
    if (teamResult.rows.length === 0) {
      return res.status(404).json({ error: 'Team not found' });
    }

    const membersResult = await db.query(
      `SELECT tm.*, u.display_name
       FROM team_members tm
       LEFT JOIN users u ON u.id = tm.user_id
       WHERE tm.team_id = $1
       ORDER BY tm.role = 'owner' DESC, tm.role = 'admin' DESC, tm.invited_at ASC`,
      [req.params.id]
    );

    const team = teamResult.rows[0];
    team.member_count = membersResult.rows.filter(m => m.status === 'active').length.toString();

    return res.json({
      team: formatTeam(team),
      members: membersResult.rows.map(formatMember),
      callerRole: memberCheck.rows[0].role,
    });
  } catch (err) {
    console.error('[Teams] Get error:', err);
    return res.status(500).json({ error: 'Failed to get team' });
  }
});

// PATCH /teams/:id — Update team name/description
router.patch('/:id', auth.requireAuth, async (req, res) => {
  try {
    // Only owner or admin can update
    const memberCheck = await db.query(
      `SELECT role FROM team_members
       WHERE team_id = $1 AND user_id = $2 AND status = 'active' AND role IN ('owner', 'admin')`,
      [req.params.id, req.user.userId]
    );

    if (memberCheck.rows.length === 0) {
      return res.status(403).json({ error: 'Only team owner or admin can update the team' });
    }

    const updates = {};
    if (req.body.name !== undefined) {
      if (typeof req.body.name !== 'string' || req.body.name.trim().length === 0) {
        return res.status(400).json({ error: 'Team name cannot be empty' });
      }
      if (req.body.name.trim().length > 100) {
        return res.status(400).json({ error: 'Team name must be 100 characters or less' });
      }
      updates.name = req.body.name.trim();
    }
    if (req.body.description !== undefined) {
      if (req.body.description && req.body.description.length > 500) {
        return res.status(400).json({ error: 'Description must be 500 characters or less' });
      }
      updates.description = req.body.description?.trim() || null;
    }

    if (Object.keys(updates).length === 0) {
      return res.status(400).json({ error: 'Nothing to update' });
    }

    const setClauses = [];
    const params = [];
    let idx = 1;
    for (const [key, value] of Object.entries(updates)) {
      setClauses.push(`${key} = $${idx}`);
      params.push(value);
      idx++;
    }
    params.push(req.params.id);

    const result = await db.query(
      `UPDATE teams SET ${setClauses.join(', ')} WHERE id = $${idx} RETURNING *`,
      params
    );

    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Team not found' });
    }

    return res.json(formatTeam(result.rows[0]));
  } catch (err) {
    console.error('[Teams] Update error:', err);
    return res.status(500).json({ error: 'Failed to update team' });
  }
});

// DELETE /teams/:id — Delete team (owner only)
router.delete('/:id', auth.requireAuth, async (req, res) => {
  try {
    const memberCheck = await db.query(
      `SELECT role FROM team_members
       WHERE team_id = $1 AND user_id = $2 AND role = 'owner'`,
      [req.params.id, req.user.userId]
    );

    if (memberCheck.rows.length === 0) {
      return res.status(403).json({ error: 'Only the team owner can delete the team' });
    }

    await db.query('DELETE FROM teams WHERE id = $1', [req.params.id]);
    evictTeam(req.params.id); // C3 — force all live members out of the deleted team room
    return res.json({ ok: true });
  } catch (err) {
    console.error('[Teams] Delete error:', err);
    return res.status(500).json({ error: 'Failed to delete team' });
  }
});

// POST /teams/:id/members — Instant-add a registered user by email.
//
// Replaces the legacy invite-by-email/accept flow: an owner/admin types an email
// and, if it belongs to a registered Inter account, that user is added as an
// active member immediately (no acceptance step).
router.post('/:id/members', auth.requireAuth, requireTeamMembership, requireIdempotencyKey, async (req, res) => {
  try {
    // H9 — gate the registration-status disclosure behind the owner/admin role.
    if (req.teamRole !== 'owner' && req.teamRole !== 'admin') {
      return res.status(403).json({ error: 'Only the team owner or admin can add members' });
    }

    const rawEmail = typeof req.body.email === 'string' ? req.body.email : '';
    const email = rawEmail.toLowerCase().trim();
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!emailRegex.test(email) || email.length > 254) {
      return res.status(400).json({ error: 'A valid email is required' });
    }

    // H9 — per-user rate limit bounds the email-enumeration oracle.
    const allowed = await checkTeamRateLimit(
      'member-add', req.params.id, req.user.userId, MEMBER_ADD_RATE_MAX, MEMBER_ADD_WINDOW_SEC
    );
    if (!allowed) {
      return res.status(429).json({ error: 'Too many attempts. Please slow down and try again.' });
    }

    // Registered users only. The "No Inter account" response is an accepted product
    // disclosure (instant-add UX), bounded by the role gate + rate limit above.
    const userRow = await db.query(
      `SELECT id, email, display_name FROM users WHERE LOWER(email) = $1 AND deleted_at IS NULL`,
      [email]
    );
    if (userRow.rows.length === 0) {
      return res.status(404).json({ error: 'No Inter account', code: 'NO_INTER_ACCOUNT' });
    }
    const target = userRow.rows[0];

    // Idempotent add: ON CONFLICT (team_id, email) converges a new or previously
    // removed row to an active member without duplicates. We never touch `role` on
    // conflict, so re-adding an existing owner/admin neither demotes nor escalates.
    const inserted = await db.query(
      `INSERT INTO team_members (team_id, user_id, email, role, status, joined_at)
       VALUES ($1, $2, $3, 'member', 'active', NOW())
       ON CONFLICT (team_id, email)
       DO UPDATE SET status = 'active',
                     user_id = EXCLUDED.user_id,
                     joined_at = COALESCE(team_members.joined_at, NOW())
       RETURNING *`,
      [req.params.id, target.id, email]
    );
    const memberRow = inserted.rows[0];
    memberRow.display_name = target.display_name;

    const member = formatMember(memberRow);
    emitTeamEvent(req.params.id, 'team:member-added', { teamId: req.params.id, member });
    return res.status(201).json({ member });
  } catch (err) {
    console.error('[Teams] Add member error:', err);
    return res.status(500).json({ error: 'Failed to add member' });
  }
});

// PATCH /teams/:id/members/:mid — Update member role
router.patch('/:id/members/:mid', auth.requireAuth, async (req, res) => {
  try {
    // Only owner can change roles
    const ownerCheck = await db.query(
      `SELECT role FROM team_members
       WHERE team_id = $1 AND user_id = $2 AND role = 'owner'`,
      [req.params.id, req.user.userId]
    );

    if (ownerCheck.rows.length === 0) {
      return res.status(403).json({ error: 'Only the team owner can change member roles' });
    }

    const { role } = req.body;
    if (!role || !['admin', 'member'].includes(role)) {
      return res.status(400).json({ error: 'Role must be "admin" or "member"' });
    }

    // Cannot change owner role
    const targetMember = await db.query(
      'SELECT role FROM team_members WHERE id = $1 AND team_id = $2',
      [req.params.mid, req.params.id]
    );

    if (targetMember.rows.length === 0) {
      return res.status(404).json({ error: 'Member not found' });
    }
    if (targetMember.rows[0].role === 'owner') {
      return res.status(400).json({ error: 'Cannot change the owner role' });
    }

    await db.query(
      'UPDATE team_members SET role = $1 WHERE id = $2 AND team_id = $3',
      [role, req.params.mid, req.params.id]
    );

    return res.json({ ok: true });
  } catch (err) {
    console.error('[Teams] Role update error:', err);
    return res.status(500).json({ error: 'Failed to update role' });
  }
});

// DELETE /teams/:id/members/:mid — Remove member
router.delete('/:id/members/:mid', auth.requireAuth, async (req, res) => {
  try {
    // Owner or admin can remove. Members can remove themselves.
    const callerCheck = await db.query(
      `SELECT role FROM team_members
       WHERE team_id = $1 AND user_id = $2 AND status = 'active'`,
      [req.params.id, req.user.userId]
    );

    if (callerCheck.rows.length === 0) {
      return res.status(403).json({ error: 'Not a member of this team' });
    }

    const targetMember = await db.query(
      'SELECT * FROM team_members WHERE id = $1 AND team_id = $2',
      [req.params.mid, req.params.id]
    );

    if (targetMember.rows.length === 0) {
      return res.status(404).json({ error: 'Member not found' });
    }

    const callerRole = callerCheck.rows[0].role;
    const target = targetMember.rows[0];

    // Cannot remove the owner
    if (target.role === 'owner') {
      return res.status(400).json({ error: 'Cannot remove the team owner' });
    }

    // Members can only remove themselves
    const isSelf = target.user_id === req.user.userId;
    if (callerRole === 'member' && !isSelf) {
      return res.status(403).json({ error: 'Only owner or admin can remove other members' });
    }

    await db.query(
      "UPDATE team_members SET status = 'removed' WHERE id = $1",
      [req.params.mid]
    );

    // C3 — evict the removed user's live sockets so a still-valid access token
    // cannot keep receiving this team's messages; notify the team for live UI.
    if (target.user_id) {
      evictUserFromTeam(req.params.id, target.user_id);
    }
    emitTeamEvent(req.params.id, 'team:member-removed', {
      teamId: req.params.id,
      memberId: req.params.mid,
      userId: target.user_id || null,
    });

    return res.json({ ok: true });
  } catch (err) {
    console.error('[Teams] Remove error:', err);
    return res.status(500).json({ error: 'Failed to remove member' });
  }
});

// POST /teams/:id/members/accept — Accept team invitation
router.post('/:id/members/accept', auth.requireAuth, async (req, res) => {
  try {
    const result = await db.query(
      `UPDATE team_members
       SET status = 'active', user_id = $1, joined_at = NOW()
       WHERE team_id = $2 AND LOWER(email) = LOWER($3) AND status = 'pending'
       RETURNING *`,
      [req.user.userId, req.params.id, req.user.email]
    );

    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'No pending invitation found for your email' });
    }

    return res.json({ ok: true, member: formatMember(result.rows[0]) });
  } catch (err) {
    console.error('[Teams] Accept error:', err);
    return res.status(500).json({ error: 'Failed to accept invitation' });
  }
});

// ===========================================================================
// Team Chat — messages + read cursor (Task 3)
// Every route derives the team from requireTeamMembership (C1). Writes persist
// to Postgres first (source of truth), then fan out over the /teams namespace.
// ===========================================================================

// GET /teams/:id/messages?before=<id>&limit=50 — paginated history, newest first.
router.get('/:id/messages', auth.requireAuth, requireTeamMembership, async (req, res) => {
  try {
    let limit = parseInt(req.query.limit, 10);
    if (!Number.isFinite(limit) || limit <= 0) limit = MESSAGES_PAGE_DEFAULT;
    if (limit > MESSAGES_PAGE_MAX) limit = MESSAGES_PAGE_MAX;

    // `before` is an opaque numeric cursor (a message id). Validate it is a
    // positive integer; reject otherwise rather than silently ignoring.
    let before = null;
    if (req.query.before !== undefined) {
      if (!/^\d+$/.test(String(req.query.before))) {
        return res.status(400).json({ error: 'before must be a positive integer message id' });
      }
      before = String(req.query.before);
    }

    const result = await db.query(
      `SELECT m.id, m.team_id, m.sender_user_id, m.sender_name, m.kind, m.body,
              m.file_id, m.created_at,
              f.original_name, f.mime_type, f.size_bytes, f.is_image
       FROM team_messages m
       LEFT JOIN team_files f ON f.id = m.file_id
       WHERE m.team_id = $1 AND ($2::bigint IS NULL OR m.id < $2::bigint)
       ORDER BY m.id DESC
       LIMIT $3`,
      [req.params.id, before, limit]
    );

    return res.json({ messages: result.rows.map(formatMessage) });
  } catch (err) {
    console.error('[Teams] List messages error:', err);
    return res.status(500).json({ error: 'Failed to load messages' });
  }
});

// POST /teams/:id/messages — send a text message.
router.post('/:id/messages', auth.requireAuth, requireTeamMembership, requireIdempotencyKey, async (req, res) => {
  try {
    // Validate body (H7 — reject empty/oversized; SQL is parameterized).
    const raw = typeof req.body.body === 'string' ? req.body.body : '';
    const body = raw.trim();
    if (body.length === 0) {
      return res.status(400).json({ error: 'Message body is required' });
    }
    if (body.length > MESSAGE_MAX_LENGTH) {
      return res.status(400).json({ error: `Message must be ${MESSAGE_MAX_LENGTH} characters or less` });
    }

    // Rate limit (H8). Fail-open on Redis error.
    const allowed = await checkMessageRateLimit(req.params.id, req.user.userId);
    if (!allowed) {
      return res.status(429).json({ error: 'You are sending messages too quickly. Please slow down.' });
    }

    // The idempotency key (a validated UUID from requireIdempotencyKey) doubles
    // as the per-(team,sender) dedup key in the DB (H10 — defense in depth).
    const idemKey = req.headers['x-idempotency-key'];
    const senderName = (req.user.displayName || req.user.email || 'Member').slice(0, 100);

    let row;
    const inserted = await db.query(
      `INSERT INTO team_messages (team_id, sender_user_id, sender_name, kind, body, idempotency_key)
       VALUES ($1, $2, $3, 'text', $4, $5)
       ON CONFLICT (team_id, sender_user_id, idempotency_key) WHERE idempotency_key IS NOT NULL
       DO NOTHING
       RETURNING *`,
      [req.params.id, req.user.userId, senderName, body, idemKey]
    );

    if (inserted.rows.length > 0) {
      row = inserted.rows[0];
    } else {
      // Conflict: a prior send with this key already persisted (e.g. the
      // idempotency cache was unavailable on the first attempt). Return it.
      const existing = await db.query(
        `SELECT * FROM team_messages
         WHERE team_id = $1 AND sender_user_id = $2 AND idempotency_key = $3`,
        [req.params.id, req.user.userId, idemKey]
      );
      row = existing.rows[0];
      if (!row) {
        return res.status(500).json({ error: 'Failed to send message' });
      }
    }

    const payload = formatMessage(row);
    emitTeamEvent(req.params.id, 'team:message', payload); // best-effort fan-out
    return res.status(201).json(payload);
  } catch (err) {
    console.error('[Teams] Send message error:', err);
    return res.status(500).json({ error: 'Failed to send message' });
  }
});

// POST /teams/:id/read — advance the caller's read cursor (idempotent set-to-max).
router.post('/:id/read', auth.requireAuth, requireTeamMembership, async (req, res) => {
  try {
    const raw = req.body.messageId;
    if (!/^\d+$/.test(String(raw))) {
      return res.status(400).json({ error: 'messageId must be a positive integer' });
    }

    const result = await db.query(
      `INSERT INTO team_read_cursors (team_id, user_id, last_read_message_id, updated_at)
       SELECT $1, $2, LEAST($3::bigint, COALESCE(MAX(id), 0)), NOW()
         FROM team_messages
        WHERE team_id = $1
       ON CONFLICT (team_id, user_id)
       DO UPDATE SET last_read_message_id =
                       GREATEST(team_read_cursors.last_read_message_id, EXCLUDED.last_read_message_id),
                     updated_at = NOW()
       RETURNING last_read_message_id`,
      [req.params.id, req.user.userId, String(raw)]
    );

    return res.json({ lastReadMessageId: String(result.rows[0].last_read_message_id) });
  } catch (err) {
    console.error('[Teams] Read cursor error:', err);
    return res.status(500).json({ error: 'Failed to update read cursor' });
  }
});

// ===========================================================================
// Team Chat — file sharing (S3-backed, persistent)
// A file upload creates a team_files row AND a kind='file' chat message, then
// fans the message out. Validation mirrors the in-call upload (shared
// fileValidation.js): magic-byte MIME, allowlist/blocklist, UUID object key,
// per-file + per-team size caps. Bytes go to S3; the S3 key is server-only.
// ===========================================================================

// POST /teams/:id/files — upload a file (multipart field "file").
// Middleware order: auth + membership + idempotency are checked BEFORE multer
// parses the body, so a non-member's upload is rejected before we process bytes.
router.post('/:id/files',
  auth.requireAuth, requireTeamMembership, requireIdempotencyKey,
  teamFileUpload.single('file'),
  async (req, res) => {
    if (!req.file || !req.file.buffer) {
      return res.status(400).json({ error: 'No file attached' });
    }

    // H5 — detect the true type from magic bytes; never trust the client header.
    // file-type returns undefined for plain text, which we map to text/plain.
    let detectedMime;
    try {
      const result = await FileType.fromBuffer(req.file.buffer);
      detectedMime = result ? result.mime : 'text/plain';
    } catch (_) {
      return res.status(500).json({ error: 'Could not determine file type' });
    }
    if (!isMimeAllowed(detectedMime)) {
      return res.status(415).json({ error: 'File type not allowed' });
    }

    // Per-team cumulative size cap (soft guardrail; the per-file hard cap is
    // enforced by multer above). A small read-then-write race here can only
    // overshoot by at most one in-flight file — acceptable for a storage cap.
    try {
      const sumRow = await db.query(
        'SELECT COALESCE(SUM(size_bytes), 0)::bigint AS total FROM team_files WHERE team_id = $1',
        [req.params.id]
      );
      if (Number(sumRow.rows[0].total) + req.file.size > TEAM_FILES_MAX_TOTAL_BYTES) {
        return res.status(413).json({ error: 'Team file storage limit reached' });
      }
    } catch (err) {
      // Non-fatal: the per-file multer cap still bounds a single upload.
      console.warn('[Teams] File size-cap check failed (allowing):', err.message);
    }

    const safeName  = sanitizeFilename(req.file.originalname);
    const isImage   = detectedMime.startsWith('image/');
    const s3Key     = `team-files/${req.params.id}/${crypto.randomUUID()}`;

    // Upload to S3 FIRST so a committed DB row can never reference a missing object.
    try {
      await s3Client.send(new PutObjectCommand({
        Bucket: S3_TEAM_FILES_BUCKET,
        Key: s3Key,
        Body: req.file.buffer,
        ContentType: detectedMime,
        ContentDisposition: `attachment; filename="${safeName}"`,
      }));
    } catch (err) {
      console.error('[Teams] S3 upload failed:', err.message);
      return res.status(502).json({ error: 'Failed to store file' });
    }

    // Persist file metadata + the file chat message atomically. If the DB write
    // fails, best-effort delete the orphaned S3 object so storage stays consistent.
    const idemKey    = req.headers['x-idempotency-key'];
    const senderName = (req.user.displayName || req.user.email || 'Member').slice(0, 100);
    const client = await db.getClient();
    try {
      await client.query('BEGIN');
      const fileRes = await client.query(
        `INSERT INTO team_files (team_id, uploader_user_id, s3_key, original_name, mime_type, size_bytes, is_image)
         VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING *`,
        [req.params.id, req.user.userId, s3Key, safeName, detectedMime, req.file.size, isImage]
      );
      const fileRow = fileRes.rows[0];
      const msgRes = await client.query(
        `INSERT INTO team_messages (team_id, sender_user_id, sender_name, kind, file_id, idempotency_key)
         VALUES ($1, $2, $3, 'file', $4, $5) RETURNING *`,
        [req.params.id, req.user.userId, senderName, fileRow.id, idemKey]
      );
      await client.query('COMMIT');

      const row = {
        ...msgRes.rows[0],
        original_name: fileRow.original_name,
        mime_type:     fileRow.mime_type,
        size_bytes:    fileRow.size_bytes,
        is_image:      fileRow.is_image,
      };
      const payload = formatMessage(row);
      emitTeamEvent(req.params.id, 'team:message', payload);
      return res.status(201).json(payload);
    } catch (err) {
      await client.query('ROLLBACK').catch(() => {});
      s3Client.send(new DeleteObjectCommand({ Bucket: S3_TEAM_FILES_BUCKET, Key: s3Key })).catch(() => {});
      console.error('[Teams] File message persist failed:', err.message);
      return res.status(500).json({ error: 'Failed to record file message' });
    } finally {
      client.release();
    }
  }
);

// GET /teams/:id/files/:fileId/url — presigned S3 download URL.
// H4 — composite (team_id + fileId) lookup ensures the file belongs to a team the
// caller is an active member of; mere knowledge of a fileId is not enough.
router.get('/:id/files/:fileId/url', auth.requireAuth, requireTeamMembership, async (req, res) => {
  try {
    const fileId = req.params.fileId;
    if (!UUID_RE.test(fileId)) {
      return res.status(404).json({ error: 'File not found' });
    }
    const fileRes = await db.query(
      'SELECT s3_key, original_name, mime_type FROM team_files WHERE id = $1 AND team_id = $2',
      [fileId, req.params.id]
    );
    if (fileRes.rows.length === 0) {
      return res.status(404).json({ error: 'File not found' });
    }
    const file = fileRes.rows[0];
    const command = new GetObjectCommand({ Bucket: S3_TEAM_FILES_BUCKET, Key: file.s3_key });
    const url = await getSignedUrl(s3Client, command, { expiresIn: 900 });
    return res.json({
      url,
      expiresInSeconds: 900,
      originalName: file.original_name,
      mimeType: file.mime_type,
    });
  } catch (err) {
    console.error('[Teams] File URL error:', err);
    return res.status(500).json({ error: 'Failed to generate download URL' });
  }
});

module.exports = router;
