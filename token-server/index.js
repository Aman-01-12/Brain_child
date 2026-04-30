// ============================================================================
// Token Server for Inter — LiveKit Integration
// Phase 6.1 [G6.1] — Redis-backed
// Phase 9 [G9] — Meeting management: roles, moderation, lobby, passwords
// Phase 10C [G10.3] — Cloud recording via LiveKit Egress
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
// Phase 10C Endpoints:
//   POST /room/record/start  — Start cloud recording (Egress API)
//   POST /room/record/stop   — Stop cloud recording
//   GET  /room/record/status/:code — Get recording status
//   GET  /recordings          — List user's recordings
//   GET  /recordings/:id      — Get recording details
//   GET  /recordings/:id/download — Get presigned download URL
//   DELETE /recordings/:id    — Delete a recording
//   POST /webhooks/egress     — Egress webhook (LiveKit → token-server)
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
const { AccessToken, RoomServiceClient, TrackSource, EgressClient,
        EncodedFileOutput, EncodingOptionsPreset,
        WebhookReceiver } = require('livekit-server-sdk');
const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const path     = require('path');
const fs       = require('fs');
const os       = require('os');
const multer   = require('multer');
const FileType = require('file-type'); // v16 CommonJS — exports fromFile, fromBuffer
const redis = require('./redis');
const db = require('./db');
const auth = require('./auth');
const { requireIdempotencyKey } = require('./idempotency');

const app = express();

// ---------------------------------------------------------------------------
// escapeHtml — prevent XSS when interpolating user-derived strings into HTML
// ---------------------------------------------------------------------------
function escapeHtml(str) {
  return String(str == null ? '' : str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#x27;')
    .replace(/\//g, '&#x2F;');
}

// ---------------------------------------------------------------------------
// Lemon Squeezy webhook — MUST be mounted BEFORE express.json()
// The raw body bytes are required for HMAC-SHA256 signature verification.
// express.json() would parse the body and destroy the original byte sequence.
// Phase C — Gap G20 (P0)
// ---------------------------------------------------------------------------
app.post(
  '/webhooks/lemonsqueezy',
  express.raw({ type: 'application/json' }),
  require('./billing')
);

app.use(express.json());

// Static files — login page, public assets (Phase F)
app.use(express.static(path.join(__dirname, 'public')));

// ---------------------------------------------------------------------------
// Security response headers — applied to every response
// ---------------------------------------------------------------------------
app.use((_req, res, next) => {
  // Instruct browsers/clients to never connect over plain HTTP
  res.setHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
  // Never cache any response — all endpoints return auth-sensitive data
  res.setHeader('Cache-Control', 'no-store');
  // Prevent MIME sniffing
  res.setHeader('X-Content-Type-Options', 'nosniff');
  // Disallow embedding in iframes
  res.setHeader('X-Frame-Options', 'DENY');
  // Prevent leaking referrer data — pure API server, no referrals needed
  res.setHeader('Referrer-Policy', 'no-referrer');
  next();
});

// Apply optional auth middleware globally — attaches req.user if Bearer token present
app.use(auth.authenticateToken);

// [Phase 11] Mount scheduling router
const schedulingRouter = require('./scheduling');
app.use('/meetings', schedulingRouter);

// [Phase 11.2.4/11.2.5] Mount calendar sync router
const calendarRouter = require('./calendar');
app.use('/calendar', calendarRouter);

// [Phase 11.4] Mount teams router
const teamsRouter = require('./teams');
app.use('/teams', teamsRouter);

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
// LiveKit Egress Client — for cloud recording (Phase 10C)
// ---------------------------------------------------------------------------
const egressClient = new EgressClient(LIVEKIT_HTTP_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET);

// Webhook receiver — validates X-Livekit-Signature on incoming Egress events
const webhookReceiver = new WebhookReceiver(LIVEKIT_API_KEY, LIVEKIT_API_SECRET);

// ---------------------------------------------------------------------------
// Recording Configuration (Phase 10C)
// ---------------------------------------------------------------------------
const VALID_TIERS = ['free', 'pro', 'hiring'];

function getValidatedTier(rawTier) {
  if (typeof rawTier === 'string' && VALID_TIERS.includes(rawTier)) return rawTier;
  return 'free';
}

// Recording quotas (minutes) — configurable via env vars
const RECORDING_QUOTAS = {
  free: 0,
  pro: parseInt(process.env.RECORDING_QUOTA_PRO || '600', 10),       // 10 hours
  hiring: parseInt(process.env.RECORDING_QUOTA_HIRING || '1200', 10), // 20 hours
};

// S3 bucket for cloud recordings (configurable via env var)
const S3_RECORDINGS_BUCKET = process.env.S3_RECORDINGS_BUCKET || 'inter-recordings';
const AWS_REGION = process.env.AWS_REGION || 'us-east-1';

// AWS SDK v3 — hoisted to module level so the client is created once and
// reused across requests (avoids per-request connection pool overhead).
const { S3Client, GetObjectCommand, DeleteObjectCommand, PutObjectCommand } = require('@aws-sdk/client-s3');
const { getSignedUrl } = require('@aws-sdk/s3-request-presigner');
const s3Client = new S3Client({ region: AWS_REGION });

// ---------------------------------------------------------------------------
// Rate limiting — Redis INCR + EXPIRE (10 req/min per identity)
// Atomic: INCR creates key if missing, EXPIRE sets auto-cleanup.
// No manual cleanup needed — Redis handles it.
// ---------------------------------------------------------------------------
const RATE_LIMIT_MAX = 10;
const RATE_LIMIT_WINDOW_SECONDS = 60;

// ---------------------------------------------------------------------------
// Auth endpoint rate limiter — protects /auth/login and /auth/register
// Keyed on email (per-account lockout) to prevent credential stuffing.
// Stricter window than room rate limits: 10 attempts per 15 min per email.
// Redis failure is non-blocking — logs error and allows request through.
// ---------------------------------------------------------------------------
async function rateLimitAuth(req, res, next) {
  const email = req.body?.email;
  const identifier = email
    ? `ratelimit:auth:${email.toLowerCase().trim()}`
    : `ratelimit:auth:ip:${req.ip}`;

  try {
    const count = await redis.incr(identifier);
    if (count === 1) await redis.expire(identifier, 900); // 15-min window

    if (count > 10) {
      const ttl = await redis.ttl(identifier);
      res.setHeader('Retry-After', String(ttl > 0 ? ttl : 900));
      return res.status(429).json({
        error: 'Too many authentication attempts. Please try again later.',
      });
    }
  } catch (redisErr) {
    // Redis unavailability must not block legitimate logins
    console.error('[auth rate limit] Redis error:', redisErr.message);
  }
  next();
}

// ---------------------------------------------------------------------------
// Refresh token endpoint rate limiter — protects /auth/refresh
// Keyed on IP (no authenticated user context yet at this point).
// 30 attempts per 60s per IP — generous enough for normal client behaviour
// (proactive refresh fires once per 15-min token TTL) but blocks brute-force.
// Redis failure is non-blocking — logs error and allows request through.
// ---------------------------------------------------------------------------
async function rateLimitRefresh(req, res, next) {
  const identifier = `ratelimit:refresh:ip:${req.ip}`;
  try {
    const count = await redis.incr(identifier);
    if (count === 1) await redis.expire(identifier, 60); // 60s window

    if (count > 30) {
      const ttl = await redis.ttl(identifier);
      res.setHeader('Retry-After', String(ttl > 0 ? ttl : 60));
      return res.status(429).json({
        error: 'Too many refresh attempts. Please try again later.',
      });
    }
  } catch (redisErr) {
    // Redis unavailability must not block legitimate token refreshes
    console.error('[refresh rate limit] Redis error:', redisErr.message);
  }
  next();
}

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
// pseudonymizeEmail — redacts email PII before writing to audit logs.
// By default (AUDIT_LOG_FULL_EMAIL !== 'true'), the address is HMAC-SHA256
// hashed so raw emails are never stored in logs.
// Key precedence: AUDIT_EMAIL_HMAC_KEY → JWT_SECRET → hard fallback.
// Set AUDIT_LOG_FULL_EMAIL=true only in tightly controlled forensic
// environments; never enable by default in production.
// ---------------------------------------------------------------------------
function pseudonymizeEmail(email) {
  const raw = String(email || '').toLowerCase().trim();
  if (process.env.AUDIT_LOG_FULL_EMAIL === 'true') return raw;
  const salt = process.env.AUDIT_EMAIL_HMAC_KEY || process.env.JWT_SECRET;
  if (!salt) return 'email:redacted';
  return 'hmac256:' + crypto.createHmac('sha256', salt).update(raw).digest('hex').slice(0, 32);
}

// ---------------------------------------------------------------------------
// POST /auth/register
// Body: { email, password, displayName }
// Returns: { user, accessToken, refreshToken, expiresIn }
// ---------------------------------------------------------------------------
app.post('/auth/register', rateLimitAuth, async (req, res) => {
  const { email, password, displayName } = req.body;

  try {
    const result = await auth.register(email, password, displayName);
    auth.auditLog(result.user.id, 'register', req.ip, { email: result.user.email });

    // Fire-and-forget verification email — don't fail registration if email fails
    (async () => {
      try {
        const rawToken  = crypto.randomBytes(32);
        const tokenHash = crypto.createHash('sha256').update(rawToken).digest();
        await db.query(
          `INSERT INTO email_verification_tokens (user_id, token_hash, expires_at)
           VALUES ($1, $2, NOW() + INTERVAL '8 hours')`,
          [result.user.id, tokenHash]
        );
        await sendVerificationEmail(result.user.email, rawToken.toString('base64url'));
      } catch (err) {
        console.error('[auth] verification email on register failed:', err.message);
      }
    })();

    res.status(201).json(result);
  } catch (err) {
    const status = err.status
                 || (err.message.includes('already registered') ? 409
                 :   err.message.includes('required') ? 400
                 :   err.message.includes('at least') ? 400
                 :   err.message.includes('Invalid') ? 400
                 :   err.message.includes('must be') ? 400
                 :   500);
    if (status === 500) throw err;
    res.status(status).json({ error: err.message });
  }
});

// ---------------------------------------------------------------------------
// POST /auth/login
// Body: { email, password }
// Returns: { user, accessToken, refreshToken, expiresIn }
// ---------------------------------------------------------------------------
app.post('/auth/login', rateLimitAuth, async (req, res) => {
  const { email, password } = req.body;

  try {
    const result = await auth.login(email, password);
    auth.auditLog(result.user.id, 'login_success', req.ip, { email: result.user.email });
    res.json(result);
  } catch (err) {
    const status = err.message.includes('Invalid') ? 401
                 : err.message.includes('required') ? 400
                 : 500;
    if (status === 500) throw err;
    if (status === 401) {
      auth.auditLog(null, 'login_failure', req.ip, { email: pseudonymizeEmail(email) });
    }
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
// POST /auth/refresh — rotate refresh token, issue new access token
// Body: { refreshToken (base64url), clientId (optional macOS hardware UUID) }
// Returns: { accessToken, refreshToken, expiresIn }
// No auth middleware — this IS the auth recovery path
// ---------------------------------------------------------------------------
app.post('/auth/refresh', rateLimitRefresh, async (req, res) => {
  const { refreshToken, clientId } = req.body;

  if (!refreshToken || typeof refreshToken !== 'string') {
    return res.status(400).json({ error: 'refreshToken required' });
  }

  // Decode, HMAC-verify, and derive DB lookup hash in one step.
  // verifyRefreshToken throws TOKEN_INVALID on any malformed or tampered input.
  let tokenHash;
  try {
    tokenHash = auth.verifyRefreshToken(refreshToken);
  } catch {
    return res.status(401).json({ error: 'Invalid refresh token', code: 'TOKEN_INVALID' });
  }

  let dbClient;
  try {
    dbClient = await db.getClient();
    await dbClient.query('BEGIN');

    // Fetch the token row — include revoked rows for theft detection
    const { rows } = await dbClient.query(
      `SELECT id, user_id, family_id, client_id, expires_at, revoked_at, absolute_expires_at
       FROM refresh_tokens
       WHERE token_hash = $1
       LIMIT 1`,
      [tokenHash]
    );

    if (rows.length === 0) {
      await dbClient.query('ROLLBACK');
      return res.status(401).json({ error: 'Invalid refresh token', code: 'TOKEN_INVALID' });
    }

    const stored = rows[0];

    // ── THEFT DETECTION ──────────────────────────────────────────────
    // A revoked token being presented means the family is compromised.
    // Kill all active tokens in the family immediately.
    if (stored.revoked_at !== null) {
      await dbClient.query(
        `UPDATE refresh_tokens SET revoked_at = NOW()
         WHERE family_id = $1 AND revoked_at IS NULL`,
        [stored.family_id]
      );
      await dbClient.query('COMMIT');
      auth.auditLog(stored.user_id, 'session_compromised', req.ip, { familyId: stored.family_id });

      // Fetch user email for security alert
      const { rows: alertUserRows } = await db.query('SELECT email FROM users WHERE id = $1', [stored.user_id]);
      dispatchSecurityAlert('Refresh token reuse detected', {
        userId: stored.user_id,
        familyId: stored.family_id,
        email: alertUserRows[0]?.email,
        ip: req.ip,
      });

      return res.status(401).json({
        error: 'Security alert: your session was compromised. Please log in again.',
        code: 'SESSION_COMPROMISED',
      });
    }

    // ── EXPIRY ───────────────────────────────────────────────────────
    if (new Date(stored.expires_at) < new Date()) {
      await dbClient.query('ROLLBACK');
      return res.status(401).json({ error: 'Refresh token expired', code: 'TOKEN_EXPIRED' });
    }

    // ── ABSOLUTE SESSION CUTOFF (G4) ────────────────────────────────
    if (stored.absolute_expires_at && new Date(stored.absolute_expires_at) < new Date()) {
      await dbClient.query('ROLLBACK');
      return res.status(401).json({ error: 'Session expired — please log in again', code: 'SESSION_EXPIRED' });
    }

    // ── DEVICE BINDING (soft) ────────────────────────────────────────
    if (stored.client_id && clientId && stored.client_id !== clientId) {
      console.warn(`[SECURITY] Client ID mismatch on refresh. stored=${stored.client_id} got=${clientId} userId=${stored.user_id}`);
    }

    // ── ROTATION ─────────────────────────────────────────────────────
    // Revoke old token, issue new one in same family — atomic transaction
    await dbClient.query(
      `UPDATE refresh_tokens SET revoked_at = NOW(), last_used_at = NOW() WHERE id = $1`,
      [stored.id]
    );

    const newRaw = crypto.randomBytes(32);
    const { clientToken: newClientToken, tokenHash: newHash } = auth.signRefreshToken(newRaw);

    await dbClient.query(
      `INSERT INTO refresh_tokens
         (user_id, token_hash, family_id, client_id, expires_at, absolute_expires_at, predecessor_id)
       VALUES ($1, $2, $3, $4, NOW() + make_interval(days => $5), $6, $7)`,
      [stored.user_id, newHash, stored.family_id, clientId || stored.client_id, auth.REFRESH_TOKEN_DAYS, stored.absolute_expires_at, stored.id]
    );

    // ── FRESH TIER RE-READ ───────────────────────────────────────────
    // This is the key design point: tier is re-read from DB on every refresh.
    // A billing webhook may have changed it since the last access token was issued.
    const { rows: userRows } = await dbClient.query(
      `SELECT id, email, display_name, tier FROM users WHERE id = $1`,
      [stored.user_id]
    );

    if (userRows.length === 0) {
      await dbClient.query('ROLLBACK');
      return res.status(401).json({ error: 'User account not found', code: 'TOKEN_INVALID' });
    }

    await dbClient.query('COMMIT');

    const accessToken = auth.generateAccessToken(userRows[0], stored.family_id);

    res.json({
      accessToken,
      refreshToken: newClientToken,
      expiresIn: auth.parseTTLtoSeconds(process.env.ACCESS_TOKEN_TTL || '15m'),
      tier: userRows[0].tier || 'free',
    });

  } catch (err) {
    if (dbClient) await dbClient.query('ROLLBACK').catch(() => {});
    throw err;
  } finally {
    if (dbClient) dbClient.release();
  }
});

// ---------------------------------------------------------------------------
// POST /auth/logout — revoke a specific refresh token
// Body: { refreshToken (optional) }
// Returns: 204 No Content
// ---------------------------------------------------------------------------
app.post('/auth/logout', auth.requireAuth, async (req, res) => {
  const { refreshToken } = req.body;

  if (refreshToken) {
    try {
      const tokenHash = auth.verifyRefreshToken(refreshToken);
      // Scope revocation to the authenticated user — prevents one user from
      // revoking another user's token by submitting a known token_hash.
      // rowCount === 0 means either already revoked or not owned by caller;
      // both are treated as success — logout must not leak token ownership.
      const { rowCount } = await db.query(
        `UPDATE refresh_tokens SET revoked_at = NOW()
         WHERE token_hash = $1 AND user_id = $2 AND revoked_at IS NULL`,
        [tokenHash, req.user.userId]
      );
      if (rowCount === 0) {
        console.warn(`[auth] Logout: token not found or not owned by user ${req.user.userId}`);
      }
    } catch (err) {
      // Logout must not fail visibly — log and continue
      console.error('[auth] Logout token revocation failed:', err.message);
    }
  }

  auth.auditLog(req.user.userId, 'logout', req.ip);
  res.status(204).end();
});

// ---------------------------------------------------------------------------
// POST /auth/logout-all — revoke all refresh tokens for the current user
// Returns: 204 No Content
// ---------------------------------------------------------------------------
app.post('/auth/logout-all', auth.requireAuth, async (req, res) => {
  await auth.revokeAllForUser(req.user.userId);
  auth.auditLog(req.user.userId, 'logout_all', req.ip);
  res.status(204).end();
});

// ===========================================================================
// GAP MITIGATIONS — G8, G9, G11 (P1–P3)
// ===========================================================================

// ---------------------------------------------------------------------------
// POST /auth/change-password — authenticated password change (G8, P1)
// Body: { currentPassword, newPassword }
// Keeps the current session alive; revokes all OTHER sessions.
// ---------------------------------------------------------------------------
app.post('/auth/change-password', auth.requireAuth, async (req, res) => {
  const { currentPassword, newPassword } = req.body || {};

  if (!currentPassword || typeof currentPassword !== 'string') {
    return res.status(400).json({ error: 'currentPassword required' });
  }
  if (!newPassword || typeof newPassword !== 'string') {
    return res.status(400).json({ error: 'newPassword required' });
  }
  const passwordBytes = Buffer.byteLength(newPassword, 'utf8');
  if (passwordBytes < 8) {
    return res.status(400).json({ error: 'Password must be at least 8 characters' });
  }
  if (passwordBytes > 72) {
    return res.status(400).json({ error: 'Password must be 72 characters or fewer' });
  }

  const userResult = await db.query(
    'SELECT id, password_hash FROM users WHERE id = $1 AND deleted_at IS NULL',
    [req.user.userId]
  );
  if (userResult.rows.length === 0) {
    return res.status(401).json({ error: 'User not found', code: 'USER_NOT_FOUND' });
  }
  const user = userResult.rows[0];

  const valid = await bcrypt.compare(currentPassword, user.password_hash);
  if (!valid) {
    auth.auditLog(user.id, 'change_password_failure', req.ip);
    return res.status(401).json({ error: 'Current password is incorrect' });
  }

  // HIBP breach check on new password
  await auth.checkPwnedPassword(newPassword);

  const newHash = await bcrypt.hash(newPassword, auth.BCRYPT_ROUNDS);

  // Revoke all sessions EXCEPT the current one (keep the caller logged in)
  const currentTokenFamily = req.user.tokenFamily;
  await db.query(
    `UPDATE refresh_tokens SET revoked_at = NOW()
     WHERE user_id = $1 AND revoked_at IS NULL AND family_id != $2`,
    [user.id, currentTokenFamily]
  );

  await db.query('UPDATE users SET password_hash = $1 WHERE id = $2', [newHash, user.id]);

  auth.auditLog(user.id, 'change_password_success', req.ip);
  res.json({ message: 'Password changed. All other sessions have been revoked.' });
});

// ---------------------------------------------------------------------------
// DELETE /auth/account — account deletion / GDPR right-to-erasure (G9, P1)
// Body: { password }
// Anonymizes PII, revokes all sessions, cancels LS subscription.
// ---------------------------------------------------------------------------
app.delete('/auth/account', auth.requireAuth, async (req, res) => {
  const { password } = req.body || {};
  if (!password || typeof password !== 'string') {
    return res.status(400).json({ error: 'password required to confirm deletion' });
  }

  const userResult = await db.query(
    'SELECT id, password_hash, ls_customer_id, ls_subscription_id FROM users WHERE id = $1 AND deleted_at IS NULL',
    [req.user.userId]
  );
  if (userResult.rows.length === 0) {
    return res.status(404).json({ error: 'User not found' });
  }
  const user = userResult.rows[0];

  const valid = await bcrypt.compare(password, user.password_hash);
  if (!valid) {
    return res.status(401).json({ error: 'Password incorrect' });
  }

  // 1. Cancel active LS subscription — hard failure: abort deletion if this fails
  //    to prevent orphaned paid subscriptions with no associated account.
  if (user.ls_subscription_id) {
    try {
      await cancelSubscription(user.ls_subscription_id);
    } catch (lsErr) {
      console.error('[auth] LS cancellation failed during account deletion:', lsErr);
      return res.status(502).json({
        error: 'Failed to cancel your subscription. Please try again or contact support.',
        code: 'SUBSCRIPTION_CANCEL_FAILED',
      });
    }
  }

  const dbClient = await db.getClient();
  try {
    await dbClient.query('BEGIN');

    // 2. Revoke all refresh tokens
    await dbClient.query(
      'UPDATE refresh_tokens SET revoked_at = NOW() WHERE user_id = $1 AND revoked_at IS NULL',
      [user.id]
    );

    // 3. Anonymize PII — keep row for audit_events FK integrity
    const anonEmail = `deleted_${user.id}@deleted.invalid`;
    await dbClient.query(
      `UPDATE users SET
         email               = $1,
         display_name        = 'Deleted User',
         password_hash       = '',
         email_verified_at   = NULL,
         tier                = 'free',
         subscription_status = 'expired',
         ls_customer_id      = NULL,
         ls_subscription_id  = NULL,
         ls_variant_id       = NULL,
         ls_product_id       = NULL,
         ls_portal_url       = NULL,
         deleted_at          = NOW(),
         deletion_reason     = 'user_request'
       WHERE id = $2`,
      [anonEmail, user.id]
    );

    await dbClient.query('COMMIT');
  } catch (err) {
    await dbClient.query('ROLLBACK');
    // CRITICAL: if LS cancellation already succeeded above but the DB commit failed,
    // the subscription is now cancelled while the account still exists. Ops must
    // manually reconcile (reactivate or re-cancel) for user.id.
    if (user.ls_subscription_id) {
      console.error(
        '[CRITICAL] account_delete DB transaction failed AFTER LS cancellation succeeded.',
        `userId=${user.id} ls_subscription_id=${user.ls_subscription_id}`,
        'Manual reconciliation required.',
        err
      );
    }
    throw err;
  } finally {
    dbClient.release();
  }

  auth.auditLog(user.id, 'account_deleted', req.ip, { reason: 'user_request' });
  res.json({ message: 'Account deleted. All personal data has been removed.' });
});

// ---------------------------------------------------------------------------
// GET /auth/sessions — list active sessions for the current user (G11, P3)
// Returns: { sessions: [{ id, clientId, createdAt, lastUsedAt }] }
// ---------------------------------------------------------------------------
app.get('/auth/sessions', auth.requireAuth, async (req, res) => {
  const result = await db.query(
    `SELECT id, family_id, client_id, created_at, last_used_at
     FROM refresh_tokens
     WHERE user_id = $1
       AND revoked_at IS NULL
       AND expires_at > NOW()
     ORDER BY COALESCE(last_used_at, created_at) DESC`,
    [req.user.userId]
  );
  res.json({
    sessions: result.rows.map(r => ({
      id: r.id,
      clientId: r.client_id,
      createdAt: r.created_at,
      lastUsedAt: r.last_used_at,
      isCurrent: r.family_id === req.user.tokenFamily || false,
    })),
  });
});

// ---------------------------------------------------------------------------
// DELETE /auth/sessions/:id — revoke a specific session (G11, P3)
// ---------------------------------------------------------------------------
app.delete('/auth/sessions/:id', auth.requireAuth, async (req, res) => {
  const { id } = req.params;
  if (!id || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) {
    return res.status(400).json({ error: 'Invalid session id' });
  }
  const result = await db.query(
    `UPDATE refresh_tokens SET revoked_at = NOW()
     WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL`,
    [id, req.user.userId]
  );
  if (result.rowCount === 0) {
    return res.status(404).json({ error: 'Session not found' });
  }
  auth.auditLog(req.user.userId, 'session_revoked', req.ip, { sessionId: id });
  res.json({ revoked: true });
});

// ---------------------------------------------------------------------------
// POST /auth/change-email — initiate email change (G10, P3)
// Body: { password, newEmail }
// Verifies current password, sends verification link to new email.
// ---------------------------------------------------------------------------
app.post('/auth/change-email', auth.requireAuth, rateLimitAuth, async (req, res) => {
  const { password, newEmail } = req.body || {};

  if (!password || typeof password !== 'string') {
    return res.status(400).json({ error: 'password required' });
  }
  if (!newEmail || typeof newEmail !== 'string') {
    return res.status(400).json({ error: 'newEmail required' });
  }

  const emailNormalized = newEmail.toLowerCase().trim();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(emailNormalized) || emailNormalized.length > 254) {
    return res.status(400).json({ error: 'Invalid email address' });
  }

  // Verify password
  const userResult = await db.query(
    'SELECT id, email, password_hash FROM users WHERE id = $1 AND deleted_at IS NULL',
    [req.user.userId]
  );
  if (userResult.rows.length === 0) {
    return res.status(401).json({ error: 'User not found' });
  }
  const user = userResult.rows[0];

  if (emailNormalized === user.email) {
    return res.status(400).json({ error: 'New email is the same as current email' });
  }

  const valid = await bcrypt.compare(password, user.password_hash);
  if (!valid) {
    return res.status(401).json({ error: 'Password incorrect' });
  }

  // Check if new email is already taken
  const existing = await db.query('SELECT id FROM users WHERE email = $1', [emailNormalized]);
  if (existing.rows.length > 0) {
    return res.status(409).json({ error: 'Email already in use' });
  }

  // Generate verification token for the new email
  const rawToken  = crypto.randomBytes(32);
  const tokenHash = crypto.createHash('sha256').update(rawToken).digest();

  await db.query(
    `INSERT INTO email_change_tokens (user_id, new_email, token_hash, expires_at)
     VALUES ($1, $2, $3, NOW() + INTERVAL '1 hour')`,
    [user.id, emailNormalized, tokenHash]
  );

  // Send verification to the NEW email address
  const { sendVerificationEmail: sendVerify } = require('./mailer');
  sendVerify(emailNormalized, rawToken.toString('base64url')).catch(err => {
    console.error('[auth] email change verification send failed:', err.message);
  });

  auth.auditLog(user.id, 'email_change_requested', req.ip, { newEmail: emailNormalized });
  res.json({ message: 'Verification email sent to your new address. Check your inbox.' });
});

// ---------------------------------------------------------------------------
// GET /auth/verify-email-change?token=<base64url> — confirm the new email (G10)
// ---------------------------------------------------------------------------
app.get('/auth/verify-email-change', async (req, res) => {
  const { token } = req.query;
  if (!token) return res.status(400).json({ error: 'token required' });

  const tokenHash = crypto.createHash('sha256')
    .update(Buffer.from(token, 'base64url'))
    .digest();

  const result = await db.query(
    `SELECT id, user_id, new_email FROM email_change_tokens
     WHERE token_hash = $1 AND used_at IS NULL AND expires_at > NOW()`,
    [tokenHash]
  );

  if (result.rows.length === 0) {
    return res.status(400).json({ error: 'Invalid or expired email change link' });
  }

  const { id: tokenId, user_id: userId, new_email: newEmail } = result.rows[0];

  const dbClient = await db.getClient();
  let oldEmail;
  try {
    await dbClient.query('BEGIN');

    // Fetch old email inside the transaction so the read is consistent
    const userResult = await dbClient.query('SELECT email FROM users WHERE id = $1 FOR UPDATE', [userId]);
    oldEmail = userResult.rows[0]?.email;

    // Atomically check the new email isn't taken — race-free inside the transaction
    const existing = await dbClient.query(
      'SELECT id FROM users WHERE email = $1 AND id != $2',
      [newEmail, userId]
    );
    if (existing.rows.length > 0) {
      await dbClient.query('ROLLBACK');
      return res.status(409).json({ error: 'Email already in use by another account' });
    }

    await dbClient.query('UPDATE email_change_tokens SET used_at = NOW() WHERE id = $1', [tokenId]);
    await dbClient.query('UPDATE users SET email = $1, email_verified_at = NOW() WHERE id = $2', [newEmail, userId]);
    await dbClient.query('COMMIT');
  } catch (err) {
    await dbClient.query('ROLLBACK');
    throw err;
  } finally {
    dbClient.release();
  }

  // Notify old email address of the change (security measure)
  if (oldEmail) {
    sendSecurityAlertEmail(oldEmail, 'email_changed', {
      newEmail,
      message: 'Your email address was changed. If you did not do this, contact support immediately.',
    }).catch(err => {
      console.error('[auth] old email notification failed:', err.message);
    });
  }

  auth.auditLog(userId, 'email_changed', null, { oldEmail, newEmail });
  res.json({ message: 'Email updated successfully.' });
});

// ===========================================================================
// PHASE D — ACCOUNT RECOVERY & SECURITY HARDENING
// ===========================================================================

const { sendPasswordResetEmail, sendVerificationEmail, sendSecurityAlertEmail } = require('./mailer');

// ---------------------------------------------------------------------------
// POST /auth/forgot-password
// Body: { email }
// ALWAYS returns 200 with generic message (anti-enumeration).
// ---------------------------------------------------------------------------
app.post('/auth/forgot-password', rateLimitAuth, async (req, res) => {
  const email = String(req.body?.email || '').toLowerCase().trim();

  // Fire-and-forget — never let DB/email timing leak email existence
  (async () => {
    try {
      const result = await db.query('SELECT id FROM users WHERE email = $1', [email]);
      if (result.rows.length === 0) return;

      const rawToken  = crypto.randomBytes(32);
      const tokenHash = crypto.createHash('sha256').update(rawToken).digest();

      await db.query(
        `INSERT INTO password_reset_tokens (user_id, token_hash, expires_at)
         VALUES ($1, $2, NOW() + INTERVAL '1 hour')`,
        [result.rows[0].id, tokenHash]
      );

      await sendPasswordResetEmail(email, rawToken.toString('base64url'));
      auth.auditLog(result.rows[0].id, 'password_reset_requested', req.ip);
    } catch (err) {
      console.error('[auth] forgot-password error:', err.message);
    }
  })();

  res.json({ message: "If that email is registered, you'll receive a reset link shortly." });
});

// ---------------------------------------------------------------------------
// POST /auth/reset-password — JSON API (consumed by macOS client)
// Body: { token (base64url), newPassword }
// ---------------------------------------------------------------------------
app.post('/auth/reset-password', async (req, res) => {
  const { token, newPassword } = req.body || {};
  try {
    const userId = await auth.resetPassword(token, newPassword);
    auth.auditLog(userId, 'password_reset_completed', req.ip);
    res.json({ message: 'Password updated. Please log in again.' });
  } catch (err) {
    const status = err.status || 500;
    if (status === 500) throw err;
    res.status(status).json({ error: err.message });
  }
});

// ---------------------------------------------------------------------------
// POST /auth/reset-password-web — form submission variant (browser fallback)
// Returns HTML instead of JSON.
// ---------------------------------------------------------------------------
app.post('/auth/reset-password-web', express.urlencoded({ extended: false }), async (req, res) => {
  const { token, newPassword } = req.body || {};
  try {
    const userId = await auth.resetPassword(token, newPassword);
    auth.auditLog(userId, 'password_reset_completed', req.ip, { via: 'web' });
    res.send('<p>Password updated. You can close this page and log in to the Inter app.</p>');
  } catch (err) {
    res.status(400).send(`<p>Error: ${escapeHtml(err.message)}. Please request a new reset link.</p>`);
  }
});

// ---------------------------------------------------------------------------
// GET /reset-password — HTML landing page linked from the reset email
// Tries inter:// deep link first; shows web form as fallback.
// ---------------------------------------------------------------------------
app.get('/reset-password', (req, res) => {
  const token = req.query.token;

  // Validate token is base64url before rendering — prevents injection
  if (!token || !/^[A-Za-z0-9_-]{40,}$/.test(token)) {
    return res.status(400).send('<p>Invalid or missing reset token.</p>');
  }

  res.setHeader('Content-Security-Policy', "default-src 'none'; form-action 'self'; script-src 'unsafe-inline'");
  res.setHeader('X-Content-Type-Options', 'nosniff');

  res.send(`<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Reset Password — Inter</title>
</head>
<body>
  <script>
    window.location = 'com-inter-app://reset-password?token=${token}';
  <\/script>
  <h2>Reset your Inter password</h2>
  <p>Enter a new password below (8–72 characters).</p>
  <form method="POST" action="/auth/reset-password-web">
    <input type="hidden" name="token" value="${token}">
    <input type="password" name="newPassword"
           placeholder="New password" required minlength="8" maxlength="72"
           autocomplete="new-password">
    <button type="submit">Reset password</button>
  </form>
</body>
</html>`);
});

// ---------------------------------------------------------------------------
// GET /auth/verify-email?token=<base64url> — confirm email ownership
// ---------------------------------------------------------------------------
app.get('/auth/verify-email', async (req, res) => {
  const { token } = req.query;
  if (!token) return res.status(400).json({ error: 'token required' });

  const tokenHash = crypto.createHash('sha256')
    .update(Buffer.from(token, 'base64url'))
    .digest();

  const result = await db.query(
    `SELECT id, user_id FROM email_verification_tokens
     WHERE token_hash = $1 AND used_at IS NULL AND expires_at > NOW()`,
    [tokenHash]
  );

  if (result.rows.length === 0) {
    return res.status(400).json({ error: 'Invalid or expired verification link' });
  }

  const { id: tokenId, user_id: userId } = result.rows[0];

  await db.query('UPDATE email_verification_tokens SET used_at = NOW() WHERE id = $1', [tokenId]);
  await db.query('UPDATE users SET email_verified_at = NOW() WHERE id = $1', [userId]);

  auth.auditLog(userId, 'email_verified', req.ip);
  res.json({ message: 'Email verified. You can now use all features.' });
});

// ---------------------------------------------------------------------------
// POST /auth/resend-verification — resend verification email
// Body: { email }
// ALWAYS returns 200 with generic message (anti-enumeration).
// ---------------------------------------------------------------------------
app.post('/auth/resend-verification', rateLimitAuth, async (req, res) => {
  const email = String(req.body?.email || '').toLowerCase().trim();

  (async () => {
    try {
      const result = await db.query(
        'SELECT id FROM users WHERE email = $1 AND email_verified_at IS NULL',
        [email]
      );
      if (result.rows.length === 0) return;

      const rawToken  = crypto.randomBytes(32);
      const tokenHash = crypto.createHash('sha256').update(rawToken).digest();

      await db.query(
        `INSERT INTO email_verification_tokens (user_id, token_hash, expires_at)
         VALUES ($1, $2, NOW() + INTERVAL '8 hours')`,
        [result.rows[0].id, tokenHash]
      );

      await sendVerificationEmail(email, rawToken.toString('base64url'));
    } catch (err) {
      console.error('[auth] resend-verification error:', err.message);
    }
  })();

  res.json({ message: "If that email is registered and unverified, you'll receive a verification link shortly." });
});

// ---------------------------------------------------------------------------
// dispatchSecurityAlert — Slack webhook + email on theft detection
// ---------------------------------------------------------------------------
async function dispatchSecurityAlert(type, details) {
  console.error(`[SECURITY ALERT] ${type}:`, JSON.stringify(details));

  if (process.env.SECURITY_WEBHOOK_URL) {
    try {
      await fetch(process.env.SECURITY_WEBHOOK_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          text: `\u{1F6A8} *${type}*\n${JSON.stringify(details, null, 2)}`,
        }),
      });
    } catch (err) {
      console.error('[alert] webhook delivery failed:', err.message);
    }
  }

  // Also send email to the affected user if we have their address
  if (details.email) {
    sendSecurityAlertEmail(details.email, type, details).catch(err => {
      console.error('[alert] security email failed:', err.message);
    });
  }
}

// ===========================================================================
// Phase F — OAuth Social Sign-In
// ===========================================================================
const { OAuth2Client } = require('google-auth-library');
const jwksClient = require('jwks-rsa');

const GOOGLE_CLIENT_ID     = process.env.GOOGLE_CLIENT_ID;
const GOOGLE_CLIENT_SECRET = process.env.GOOGLE_CLIENT_SECRET;
const MS_CLIENT_ID         = process.env.MICROSOFT_CLIENT_ID;
const MS_CLIENT_SECRET     = process.env.MICROSOFT_CLIENT_SECRET;
const MS_TENANT_ID         = process.env.MICROSOFT_TENANT_ID || 'common';
const OAUTH_STATE_SECRET   = process.env.OAUTH_STATE_SECRET;
const HANDOFF_TTL          = parseInt(process.env.OAUTH_HANDOFF_TTL_SECONDS || '30', 10);
const SERVER_BASE_URL      = process.env.SERVER_BASE_URL || `http://localhost:${process.env.PORT || 3000}`;

const googleOAuth = GOOGLE_CLIENT_ID ? new OAuth2Client(GOOGLE_CLIENT_ID) : null;
const msJwks = jwksClient({
  jwksUri: `https://login.microsoftonline.com/${MS_TENANT_ID}/discovery/v2.0/keys`,
  cache: true,
  rateLimit: true,
});

// In-memory PKCE/nonce store (use Redis for multi-instance prod deployments)
const oauthSessions = new Map();
setInterval(() => {
  const cutoff = Date.now() - 10 * 60 * 1000;
  for (const [key, val] of oauthSessions) {
    if (val.createdAt < cutoff) oauthSessions.delete(key);
  }
  // Also purge expired handoff codes from DB (fire-and-forget)
  db.query(`DELETE FROM pending_oauth_handoffs WHERE expires_at < NOW() - INTERVAL '1 hour'`)
    .catch(err => console.error('[OAuth] Handoff cleanup failed:', err.message));
}, 5 * 60 * 1000);

const OAUTH_PROVIDERS = new Set(['google', 'microsoft']);

// ---------------------------------------------------------------------------
// GET /auth/login-page — serves the sign-in HTML
// ---------------------------------------------------------------------------
app.get('/auth/login-page', (_req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'login.html'));
});

// ---------------------------------------------------------------------------
// GET /auth/oauth/:provider/start — initiate OAuth flow with PKCE + state
// ---------------------------------------------------------------------------
app.get('/auth/oauth/:provider/start', rateLimitAuth, (req, res) => {
  const { provider } = req.params;
  if (!OAUTH_PROVIDERS.has(provider)) {
    return res.status(400).json({ error: 'Unknown provider' });
  }
  if (!OAUTH_STATE_SECRET) {
    console.error('[OAuth] OAUTH_STATE_SECRET not configured');
    return res.status(500).json({ error: 'OAuth not configured' });
  }
  if (provider === 'google' && !GOOGLE_CLIENT_ID) {
    return res.status(500).json({ error: 'Google OAuth not configured' });
  }
  if (provider === 'microsoft' && !MS_CLIENT_ID) {
    return res.status(500).json({ error: 'Microsoft OAuth not configured' });
  }

  // PKCE S256
  const codeVerifier  = crypto.randomBytes(32).toString('base64url');
  const codeChallenge = crypto.createHash('sha256').update(codeVerifier).digest('base64url');

  // State: HMAC-signed — encodes provider + timestamp for CSRF and mix-up protection
  const statePayload = `${provider}:${Date.now()}:${crypto.randomBytes(8).toString('hex')}`;
  const stateHmac = crypto
    .createHmac('sha256', OAUTH_STATE_SECRET)
    .update(statePayload)
    .digest('base64url');
  const state = `${Buffer.from(statePayload).toString('base64url')}.${stateHmac}`;

  // Nonce for ID token replay prevention
  const nonce = crypto.randomBytes(16).toString('base64url');

  oauthSessions.set(state, { codeVerifier, nonce, provider, createdAt: Date.now() });

  const redirectUri = `${SERVER_BASE_URL}/auth/oauth/${provider}/callback`;

  let authUrl;
  if (provider === 'google') {
    const params = new URLSearchParams({
      client_id:             GOOGLE_CLIENT_ID,
      redirect_uri:          redirectUri,
      response_type:         'code',
      scope:                 'openid email profile',
      state,
      nonce,
      code_challenge:        codeChallenge,
      code_challenge_method: 'S256',
      access_type:           'online',
      prompt:                'select_account',
    });
    authUrl = `https://accounts.google.com/o/oauth2/v2/auth?${params}`;
  } else {
    const params = new URLSearchParams({
      client_id:             MS_CLIENT_ID,
      redirect_uri:          redirectUri,
      response_type:         'code',
      scope:                 'openid email profile',
      state,
      nonce,
      code_challenge:        codeChallenge,
      code_challenge_method: 'S256',
      response_mode:         'query',
    });
    authUrl = `https://login.microsoftonline.com/${MS_TENANT_ID}/oauth2/v2.0/authorize?${params}`;
  }

  res.redirect(authUrl);
});

// ---------------------------------------------------------------------------
// GET /auth/oauth/start-url?provider=google|microsoft
// Returns { "url": "http://…/auth/oauth/{provider}/start" } so the native app
// never needs to hardcode the OAuth start path.  No auth required.
// ---------------------------------------------------------------------------
app.get('/auth/oauth/start-url', rateLimitAuth, (req, res) => {
  const provider = req.query.provider;
  if (!provider || !OAUTH_PROVIDERS.has(provider)) {
    return res.status(400).json({ error: 'Unknown or missing provider' });
  }
  const baseUrl = process.env.BILLING_PAGE_BASE_URL ||
    `http://localhost:${PORT}`;
  res.json({ url: `${baseUrl}/auth/oauth/${provider}/start` });
});

// ---------------------------------------------------------------------------
// verifyMicrosoftIdToken — JWKS-based signature verification for MS ID tokens
// ---------------------------------------------------------------------------
async function verifyMicrosoftIdToken(idToken) {
  const jwt = require('jsonwebtoken');
  const decoded = jwt.decode(idToken, { complete: true });
  if (!decoded || !decoded.header || !decoded.header.kid) {
    throw new Error('Invalid Microsoft ID token');
  }
  const key = await msJwks.getSigningKey(decoded.header.kid);
  const signingKey = key.getPublicKey();

  // When tenant is 'common', the issuer contains the user's real tenant ID,
  // not 'common'. Verify audience + signature but validate issuer pattern manually.
  const verifyOptions = {
    algorithms: ['RS256'],
    audience:   MS_CLIENT_ID,
  };
  if (MS_TENANT_ID !== 'common' && MS_TENANT_ID !== 'organizations' && MS_TENANT_ID !== 'consumers') {
    verifyOptions.issuer = `https://login.microsoftonline.com/${MS_TENANT_ID}/v2.0`;
  }
  const payload = jwt.verify(idToken, signingKey, verifyOptions);

  // For multi-tenant ('common'), validate issuer matches the expected Microsoft pattern
  if (!verifyOptions.issuer) {
    const issuerPattern = /^https:\/\/login\.microsoftonline\.com\/[0-9a-f-]+\/v2\.0$/;
    if (!payload.iss || !issuerPattern.test(payload.iss)) {
      throw new Error(`Unexpected Microsoft issuer: ${payload.iss}`);
    }
  }

  return payload;
}

// ---------------------------------------------------------------------------
// GET /auth/oauth/:provider/callback — provider redirects here after consent
// ---------------------------------------------------------------------------
app.get('/auth/oauth/:provider/callback', rateLimitAuth, async (req, res) => {
  const { provider } = req.params;
  const { code, state, error: providerError } = req.query;

  // User denied consent
  if (providerError) {
    return res.redirect('com-inter-app://oauth-callback?error=access_denied');
  }

  // Missing authorization code
  if (!code || !state) {
    return res.status(400).send('Missing code or state parameter.');
  }

  // Validate state — CSRF + mix-up protection
  if (!state || !oauthSessions.has(state)) {
    return res.status(400).send('Invalid or expired state parameter.');
  }
  const dotIdx = state.lastIndexOf('.');
  if (dotIdx === -1) {
    oauthSessions.delete(state);
    return res.status(400).send('Malformed state parameter.');
  }
  const encodedPayload = state.substring(0, dotIdx);
  const receivedHmac   = state.substring(dotIdx + 1);
  const expectedHmac = crypto
    .createHmac('sha256', OAUTH_STATE_SECRET)
    .update(Buffer.from(encodedPayload, 'base64url').toString())
    .digest('base64url');

  if (receivedHmac.length !== expectedHmac.length ||
      !crypto.timingSafeEqual(Buffer.from(receivedHmac), Buffer.from(expectedHmac))) {
    oauthSessions.delete(state);
    return res.status(400).send('State signature invalid.');
  }

  const statePayload = Buffer.from(encodedPayload, 'base64url').toString();
  const [stateProvider] = statePayload.split(':');
  if (stateProvider !== provider) {
    oauthSessions.delete(state);
    return res.status(400).send('Provider mismatch.');
  }

  const { codeVerifier, nonce } = oauthSessions.get(state);
  oauthSessions.delete(state);

  const redirectUri = `${SERVER_BASE_URL}/auth/oauth/${provider}/callback`;
  let providerUserId, providerEmail, displayName;

  try {
    if (provider === 'google') {
      // Exchange authorization code for tokens
      const tokenRes = await fetch('https://oauth2.googleapis.com/token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
          code,
          client_id:     GOOGLE_CLIENT_ID,
          client_secret: GOOGLE_CLIENT_SECRET,
          redirect_uri:  redirectUri,
          grant_type:    'authorization_code',
          code_verifier: codeVerifier,
        }),
      });
      const tokenData = await tokenRes.json();
      if (!tokenRes.ok || !tokenData.id_token) {
        throw new Error(`Google token exchange failed: ${tokenData.error || 'no id_token'}`);
      }

      // Verify ID token signature + claims via google-auth-library
      const ticket = await googleOAuth.verifyIdToken({
        idToken:  tokenData.id_token,
        audience: GOOGLE_CLIENT_ID,
      });
      const payload = ticket.getPayload();

      if (!payload.email_verified) throw new Error('email_not_verified');
      if (payload.nonce !== nonce)  throw new Error('nonce_mismatch');
      if (Date.now() / 1000 - payload.iat > 300) throw new Error('id_token_too_old');

      providerUserId = payload.sub;
      providerEmail  = payload.email.toLowerCase();
      displayName    = payload.name || payload.email;

    } else {
      // Microsoft — exchange code + code_verifier
      const tokenRes = await fetch(
        `https://login.microsoftonline.com/${MS_TENANT_ID}/oauth2/v2.0/token`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({
            code,
            client_id:     MS_CLIENT_ID,
            client_secret: MS_CLIENT_SECRET,
            redirect_uri:  redirectUri,
            grant_type:    'authorization_code',
            code_verifier: codeVerifier,
          }),
        }
      );
      const tokenData = await tokenRes.json();
      if (!tokenRes.ok || !tokenData.id_token) {
        throw new Error(`MS token exchange failed: ${tokenData.error || 'no id_token'}`);
      }

      // Verify MS ID token via JWKS
      const payload = await verifyMicrosoftIdToken(tokenData.id_token);

      if (payload.nonce !== nonce) throw new Error('nonce_mismatch');
      if (Date.now() / 1000 - payload.iat > 300) throw new Error('id_token_too_old');

      // Microsoft: work/school accounts don't always include email_verified,
      // but the org tenant admin owns the domain — treat as verified.
      // Personal accounts DO include it; reject if explicitly false.
      if (payload.email_verified === false) throw new Error('email_not_verified');

      providerUserId = payload.oid || payload.sub;
      providerEmail  = (payload.email || payload.preferred_username || '').toLowerCase();
      displayName    = payload.name || providerEmail;
    }
  } catch (err) {
    console.error(`[OAuth] ${provider} token exchange/verification failed:`, err.message);
    return res.redirect('com-inter-app://oauth-callback?error=provider_error');
  }

  if (!providerEmail) {
    return res.redirect('com-inter-app://oauth-callback?error=no_email');
  }

  // Account lookup + linking (silent auto-link if email_verified from provider)
  const client = await db.getClient();
  try {
    await client.query('BEGIN');

    // Check if this OAuth identity already exists
    const identityRes = await client.query(
      `SELECT oi.id, u.id AS user_id, u.deleted_at
       FROM oauth_identities oi
       JOIN users u ON u.id = oi.user_id
       WHERE oi.provider = $1 AND oi.provider_user_id = $2`,
      [provider, providerUserId]
    );

    let userId;
    let isNewUser = false;
    let isNewLink = false;

    if (identityRes.rows.length > 0) {
      // Returning user via this provider
      const row = identityRes.rows[0];
      if (row.deleted_at) {
        await client.query('ROLLBACK');
        return res.redirect('com-inter-app://oauth-callback?error=account_deleted');
      }
      userId = row.user_id;
      await client.query(
        `UPDATE oauth_identities SET last_used_at = NOW()
         WHERE provider = $1 AND provider_user_id = $2`,
        [provider, providerUserId]
      );
    } else {
      // New identity — check if email matches an existing Inter account
      const existingRes = await client.query(
        `SELECT id, deleted_at FROM users
         WHERE lower(email) = $1 AND deleted_at IS NULL`,
        [providerEmail]
      );

      if (existingRes.rows.length > 0) {
        // Auto-link: provider asserted email_verified (checked above)
        userId = existingRes.rows[0].id;
        isNewLink = true;
      } else {
        // Create new user — password_hash is empty (OAuth-only account)
        const newUserRes = await client.query(
          `INSERT INTO users (email, password_hash, display_name, email_verified_at, tier)
           VALUES ($1, '', $2, NOW(), 'free')
           RETURNING id`,
          [providerEmail, displayName]
        );
        userId = newUserRes.rows[0].id;
        isNewUser = true;
      }

      await client.query(
        `INSERT INTO oauth_identities (user_id, provider, provider_user_id, provider_email, last_used_at)
         VALUES ($1, $2, $3, $4, NOW())`,
        [userId, provider, providerUserId, providerEmail]
      );
    }

    // Store one-time handoff code (30s TTL)
    // Tokens are NOT issued here — only the exchange endpoint issues tokens.
    // This avoids orphaned refresh token rows in the DB.
    const rawCode = crypto.randomBytes(32);
    const codeHash = crypto.createHash('sha256').update(rawCode).digest();
    await client.query(
      `INSERT INTO pending_oauth_handoffs (code_hash, user_id, expires_at)
       VALUES ($1, $2, NOW() + make_interval(secs => $3))`,
      [codeHash, userId, HANDOFF_TTL]
    );

    await client.query('COMMIT');

    // Audit + security notifications (fire-and-forget, after commit)
    const eventType = isNewUser ? 'oauth_register' : (isNewLink ? 'oauth_account_linked' : 'oauth_login');
    auth.auditLog(userId, eventType, req.ip, { provider });

    if (isNewLink) {
      sendSecurityAlertEmail(providerEmail, 'oauth_account_linked', {
        provider,
        linkedAt: new Date().toUTCString(),
      }).catch(err => console.error('[OAuth] Security alert email failed:', err.message));
    }

    // Redirect to Mac app with handoff code (NOT the actual tokens)
    const handoffCode = rawCode.toString('base64url');
    res.redirect(`com-inter-app://oauth-callback?code=${encodeURIComponent(handoffCode)}`);

  } catch (err) {
    await client.query('ROLLBACK');
    console.error('[OAuth] DB error during account resolution:', err);
    res.redirect('com-inter-app://oauth-callback?error=server_error');
  } finally {
    client.release();
  }
});

// ---------------------------------------------------------------------------
// POST /auth/oauth/exchange — redeem handoff code for tokens (one-time use)
// ---------------------------------------------------------------------------
app.post('/auth/oauth/exchange', rateLimitAuth, async (req, res, next) => {
  const { code } = req.body;
  if (!code || typeof code !== 'string') {
    return res.status(400).json({ error: 'Missing code' });
  }

  let rawBytes;
  try {
    rawBytes = Buffer.from(code, 'base64url');
    if (rawBytes.length !== 32) throw new Error('bad length');
  } catch {
    return res.status(400).json({ error: 'Invalid code format' });
  }

  const codeHash = crypto.createHash('sha256').update(rawBytes).digest();

  const client = await db.getClient();
  try {
    await client.query('BEGIN');

    // Atomically mark used — prevents double redemption
    const result = await client.query(
      `UPDATE pending_oauth_handoffs
       SET used_at = NOW()
       WHERE code_hash = $1
         AND used_at IS NULL
         AND expires_at > NOW()
       RETURNING user_id`,
      [codeHash]
    );

    if (result.rows.length === 0) {
      await client.query('ROLLBACK');
      return res.status(401).json({ code: 'INVALID_OR_EXPIRED_CODE' });
    }

    const { user_id: userId } = result.rows[0];

    const userRes = await client.query(
      `SELECT id, email, display_name, tier FROM users WHERE id = $1 AND deleted_at IS NULL`,
      [userId]
    );
    if (userRes.rows.length === 0) {
      await client.query('ROLLBACK');
      return res.status(401).json({ code: 'USER_NOT_FOUND' });
    }
    const user = userRes.rows[0];

    // Issue fresh token pair
    const clientId = `oauth_exchange_${Date.now()}`;
    const { rawToken: refreshToken, familyId } = await auth.issueRefreshToken(userId, clientId, client);
    const accessToken = auth.generateAccessToken(user, familyId);

    // Enforce concurrent session cap
    await auth.enforceSessionLimit(userId, user.tier || 'free', familyId, client);

    await client.query('COMMIT');

    auth.auditLog(userId, 'oauth_exchange', req.ip);

    res.json({
      accessToken,
      refreshToken,
      expiresIn: auth.parseTTLtoSeconds(process.env.ACCESS_TOKEN_TTL || '15m'),
      user: {
        id:          userId,
        email:       user.email,
        displayName: user.display_name,
        tier:        user.tier,
      },
    });
  } catch (err) {
    await client.query('ROLLBACK');
    next(err);
  } finally {
    client.release();
  }
});

// ---------------------------------------------------------------------------
// POST /auth/oauth/create-handoff — create a handoff code for an authenticated
// user (used by the login page's email/password form to redirect to the Mac app)
// ---------------------------------------------------------------------------
app.post('/auth/oauth/create-handoff', auth.requireAuth, async (req, res, next) => {
  const userId = req.user.userId;
  try {
    const rawCode = crypto.randomBytes(32);
    const codeHash = crypto.createHash('sha256').update(rawCode).digest();
    await db.query(
      `INSERT INTO pending_oauth_handoffs (code_hash, user_id, expires_at)
       VALUES ($1, $2, NOW() + make_interval(secs => $3))`,
      [codeHash, userId, HANDOFF_TTL]
    );
    res.json({ code: rawCode.toString('base64url') });
  } catch (err) {
    next(err);
  }
});

// ---------------------------------------------------------------------------
// Billing endpoint rate limiter — protects /billing/* authenticated endpoints
// Keyed on authenticated userId — 10 requests per 60s.
// Redis failure is non-blocking — logs error and allows request through.
// ---------------------------------------------------------------------------
async function rateLimitBilling(req, res, next) {
  const userId = req.user?.userId;
  if (!userId) return next(); // requireAuth runs first; this is a safety fallback
  const identifier = `ratelimit:billing:${userId}`;
  try {
    const count = await redis.incr(identifier);
    if (count === 1) await redis.expire(identifier, 60);

    if (count > 10) {
      const ttl = await redis.ttl(identifier);
      res.setHeader('Retry-After', String(ttl > 0 ? ttl : 60));
      return res.status(429).json({
        error: 'Too many billing requests. Please try again later.',
      });
    }
  } catch (redisErr) {
    console.error('[billing rate limit] Redis error:', redisErr.message);
  }
  next();
}

// ---------------------------------------------------------------------------
// Billing endpoints — Phase C (Lemon Squeezy)
// ---------------------------------------------------------------------------
const jwt = require('jsonwebtoken');
const { createCheckout, getCustomer, lemonSqueezySetup, cancelSubscription } = require('@lemonsqueezy/lemonsqueezy.js');
const { VARIANT_ID_TO_TIER } = require('./billing');
const { BILLING_PLANS, renderPricingPage, renderErrorPage } = require('./billing-page');

// Initialize LS SDK — only if API key is configured
if (process.env.LEMONSQUEEZY_API_KEY) {
  lemonSqueezySetup({ apiKey: process.env.LEMONSQUEEZY_API_KEY });
}

// GET /billing/portal-url — Return the user's LS customer portal URL
// The portal URL is pre-signed (24h expiry) and refreshed on every webhook event.
// To avoid serving an expired cached URL, we fetch a fresh one from the LS API
// when the customer ID is available, falling back to the stored URL on failure.
app.get('/billing/portal-url', auth.requireAuth, rateLimitBilling, async (req, res) => {
  const result = await db.query(
    'SELECT ls_customer_id, ls_portal_url, subscription_status FROM users WHERE id = $1',
    [req.user.userId]
  );
  const user = result.rows[0];
  if (!user || (!user.ls_portal_url && !user.ls_customer_id)) {
    return res.status(404).json({ code: 'NO_BILLING', error: 'No billing account found' });
  }

  let portalUrl = user.ls_portal_url;

  // Try to fetch a fresh portal URL from the LS API (pre-signed URLs expire after 24h)
  if (user.ls_customer_id && process.env.LEMONSQUEEZY_API_KEY) {
    try {
      const { data: customer } = await getCustomer(user.ls_customer_id);
      const freshUrl = customer?.data?.attributes?.urls?.customer_portal;
      if (freshUrl) {
        portalUrl = freshUrl;
        // Persist the fresh URL so the DB cache stays current
        await db.query('UPDATE users SET ls_portal_url = $1 WHERE id = $2', [freshUrl, req.user.userId]);
      }
    } catch (err) {
      // Fall back to cached URL — better than failing entirely
      console.error('[billing] Failed to fetch fresh portal URL from LS:', err.message);
    }
  }

  if (!portalUrl) {
    return res.status(404).json({ code: 'NO_BILLING', error: 'No billing portal available' });
  }

  res.json({
    portalUrl,
    subscriptionStatus: user.subscription_status,
  });
});

// GET /billing/status — Lightweight tier + subscription status check
// Used by the macOS client after returning from the LS checkout page to poll
// for the webhook-driven tier update. Returns the current DB state — no
// side effects. The client calls this in a retry loop (up to 5x, 2s apart)
// until tier !== 'free' (or gives up and waits for the proactive refresh).
app.get('/billing/status', auth.requireAuth, rateLimitBilling, async (req, res) => {
  const result = await db.query(
    'SELECT tier, subscription_status FROM users WHERE id = $1',
    [req.user.userId]
  );
  const user = result.rows[0];
  if (!user) {
    return res.status(404).json({ code: 'USER_NOT_FOUND', error: 'User not found' });
  }

  res.json({
    tier: user.tier || 'free',
    subscriptionStatus: user.subscription_status || 'none',
  });
});

// GET /billing/success — Browser-to-app bridge page
// After LS checkout completes, the browser is redirected here. This page
// opens the `com-inter-app://billing/success` deep link to bring the macOS app to
// the foreground, then shows a "you can close this tab" message.
// No auth required — the page contains no sensitive data.
app.get('/billing/success', (_req, res) => {
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.send(`<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Payment Complete — Inter</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
           background: #111; color: #e0e0e0; display: flex; align-items: center;
           justify-content: center; min-height: 100vh; margin: 0; }
    .card { text-align: center; max-width: 420px; padding: 48px 32px;
            background: #1a1a1a; border-radius: 16px; border: 1px solid #333; }
    .check { font-size: 48px; margin-bottom: 16px; }
    h1 { font-size: 22px; margin: 0 0 8px; color: #fff; }
    p  { font-size: 14px; color: #999; margin: 4px 0; line-height: 1.5; }
    .open-link { display: inline-block; margin-top: 20px; padding: 10px 28px;
                 background: #7c3aed; color: #fff; border-radius: 8px;
                 text-decoration: none; font-weight: 600; font-size: 14px; }
    .open-link:hover { background: #6d28d9; }
  </style>
</head>
<body>
  <div class="card">
    <div class="check">✓</div>
    <h1>Payment Complete</h1>
    <p>Your upgrade is being activated.</p>
    <p>Returning you to Inter…</p>
    <a class="open-link" href="com-inter-app://billing/success" id="openApp">Open Inter</a>
    <p id="status-msg" style="margin-top:24px; font-size:12px; color:#666;">
      If the app didn't open automatically, click the button above.<br>
      On mobile or without the app? Your account has been upgraded — open Inter on your Mac to see it.
    </p>
  </div>
  <script>
    // Attempt the deep link redirect immediately (works when macOS app is installed + open)
    setTimeout(function() { window.location.href = 'com-inter-app://billing/success'; }, 500);
  </script>
</body>
</html>`);
});

// ---------------------------------------------------------------------------
// GET /billing/public-plans-url — Return the public (unauthenticated) pricing
// page URL.  No auth required.  The native app calls this instead of
// hardcoding the path, so the server controls the canonical URL.
// ---------------------------------------------------------------------------
app.get('/billing/public-plans-url', (req, res) => {
  const baseUrl = process.env.BILLING_PAGE_BASE_URL ||
    `http://localhost:${PORT}`;
  res.json({ url: `${baseUrl}/billing/plans` });
});

// GET /billing/plans-token — Issue a short-lived page JWT; return the plans URL.
// The app opens this URL in the default browser. Token encodes userId + tier so
// the plans page can render the correct current-plan state without another DB hit.
app.get('/billing/plans-token', auth.requireAuth, rateLimitBilling, async (req, res) => {
  const result = await db.query(
    'SELECT tier FROM users WHERE id = $1',
    [req.user.userId]
  );
  const user = result.rows[0];
  if (!user) {
    return res.status(404).json({ code: 'USER_NOT_FOUND', error: 'User not found' });
  }

  const tier = user.tier || 'free';
  const token = jwt.sign(
    { userId: req.user.userId, tier, purpose: 'billing' },
    process.env.JWT_SECRET,
    {
      audience: 'inter-billing-page',
      issuer: 'inter-token-server',
      expiresIn: '2m',
    }
  );

  const baseUrl = process.env.BILLING_PAGE_BASE_URL ||
    `http://localhost:${PORT}`;
  res.json({ url: `${baseUrl}/billing/plans?t=${encodeURIComponent(token)}` });
});

// GET /billing/plans — Render the pricing page (no JS, pure HTML + form POSTs).
// Validates the short-lived page JWT issued by /billing/plans-token above.
// Also serves a public (unauthenticated) view if no token is provided —
// upgrade buttons are disabled with a "Sign in first" prompt.
// CSP: script-src 'none' — zero client-side JavaScript.
app.get('/billing/plans', async (req, res) => {
  const token = req.query.t;

  // --- Unauthenticated visit (no token) — render public read-only page ---
  if (!token || typeof token !== 'string') {
    const csp = [
      "default-src 'none'",
      "style-src 'unsafe-inline'",
      "script-src 'none'",
      "form-action 'none'",
      "frame-ancestors 'none'",
      "base-uri 'none'",
    ].join('; ');

    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    res.setHeader('Content-Security-Policy', csp);
    res.setHeader('X-Frame-Options', 'DENY');
    res.setHeader('Cache-Control', 'no-store');
    return res.send(renderPricingPage(BILLING_PLANS, null, null));
  }

  // --- Authenticated visit (valid token) — full interactive page ---
  let payload;
  try {
    payload = jwt.verify(token, process.env.JWT_SECRET, {
      audience: 'inter-billing-page',
      issuer: 'inter-token-server',
    });
  } catch (err) {
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    const expired = err.name === 'TokenExpiredError';
    return res.status(401).send(renderErrorPage(
      expired
        ? 'This pricing page link has expired. Please reopen Inter and try again.'
        : 'Invalid page token. Please reopen Inter and try again.'
    ));
  }

  if (payload.purpose !== 'billing') {
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    return res.status(403).send(renderErrorPage('Invalid token purpose.'));
  }

  // Generate a per-request nonce so we can strip the page token from the
  // browser address bar via history.replaceState (prevents token leaking in
  // browser history). The nonce is tied to CSP script-src.
  const nonce = require('crypto').randomBytes(16).toString('base64');

  const csp = [
    "default-src 'none'",
    "style-src 'unsafe-inline'",  // inline <style> block only
    `script-src 'nonce-${nonce}'`,
    "form-action 'self' https://*.lemonsqueezy.com",
    "frame-ancestors 'none'",
    "base-uri 'none'",
  ].join('; ');

  // Minimal inline script to strip the token query param from the URL bar.
  const stripTokenScript = `<script nonce="${nonce}">history.replaceState(null,'',location.pathname)</script>`;

  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.setHeader('Content-Security-Policy', csp);
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Cache-Control', 'no-store');
  res.send(renderPricingPage(BILLING_PLANS, payload.tier, token) + stripTokenScript);
});

// POST /billing/checkout-redirect — Validate page token + variantId, create a
// Lemon Squeezy checkout session, then 302-redirect the browser directly to it.
// The LS API key is server-side only and never touches the browser.
app.post(
  '/billing/checkout-redirect',
  express.urlencoded({ extended: false }),
  requireIdempotencyKey,
  async (req, res) => {
    if (!process.env.LEMONSQUEEZY_API_KEY || !process.env.LEMONSQUEEZY_STORE_ID) {
      res.setHeader('Content-Type', 'text/html; charset=utf-8');
      return res.status(503).send(renderErrorPage('Billing is not configured on this server.'));
    }

    const { token, variantId } = req.body || {};

    if (!token || typeof token !== 'string' ||
        !variantId || typeof variantId !== 'string') {
      res.setHeader('Content-Type', 'text/html; charset=utf-8');
      return res.status(400).send(renderErrorPage('Invalid request. Please reopen Inter and try again.'));
    }

    // Validate the page token
    let payload;
    try {
      payload = jwt.verify(token, process.env.JWT_SECRET, {
        audience: 'inter-billing-page',
        issuer: 'inter-token-server',
      });
    } catch (err) {
      res.setHeader('Content-Type', 'text/html; charset=utf-8');
      const expired = err.name === 'TokenExpiredError';
      return res.status(401).send(renderErrorPage(
        expired
          ? 'This page has expired. Please reopen Inter to get a fresh link.'
          : 'Invalid token. Please reopen Inter and try again.'
      ));
    }

    if (payload.purpose !== 'billing') {
      res.setHeader('Content-Type', 'text/html; charset=utf-8');
      return res.status(403).send(renderErrorPage('Invalid token purpose.'));
    }

    // Validate variantId against BILLING_PLANS (not VARIANT_ID_TO_TIER which only
    // knows paid variants — BILLING_PLANS is the authoritative list for the page)
    const ALLOWED_VARIANT_IDS = new Set(
      BILLING_PLANS.map(p => p.variantId).filter(Boolean)
    );
    if (!ALLOWED_VARIANT_IDS.has(variantId)) {
      res.setHeader('Content-Type', 'text/html; charset=utf-8');
      return res.status(400).send(renderErrorPage('Invalid plan selected.'));
    }

    // Fetch user email for the LS checkout
    const userResult = await db.query(
      'SELECT email, display_name FROM users WHERE id = $1',
      [payload.userId]
    );
    const user = userResult.rows[0];
    if (!user) {
      res.setHeader('Content-Type', 'text/html; charset=utf-8');
      return res.status(404).send(renderErrorPage('User account not found.'));
    }

    let checkout;
    try {
      checkout = await createCheckout(
        process.env.LEMONSQUEEZY_STORE_ID,
        variantId,
        {
          checkoutData: {
            email: user.email,
            name: user.display_name || undefined,
            custom: { user_id: payload.userId },
          },
          productOptions: {
            redirectUrl: process.env.APP_RETURN_URL || 'com-inter-app://billing/success',
          },
          expiresAt: new Date(Date.now() + 30 * 60 * 1000).toISOString(),
        }
      );
    } catch (err) {
      console.error(`[billing] createCheckout threw for userId=${payload.userId} variantId=${variantId}:`, err.message);
      res.setHeader('Content-Type', 'text/html; charset=utf-8');
      return res.status(502).send(renderErrorPage('Failed to create checkout. Please try again.'));
    }

    const checkoutUrl = checkout?.data?.data?.attributes?.url;
    if (!checkoutUrl) {
      console.error(`[billing] createCheckout returned unexpected shape for userId=${payload.userId}`);
      res.setHeader('Content-Type', 'text/html; charset=utf-8');
      return res.status(502).send(renderErrorPage('Failed to create checkout. Please try again.'));
    }

    res.redirect(302, checkoutUrl);
  }
);

// ---------------------------------------------------------------------------
// Redis key helpers
// ---------------------------------------------------------------------------
function roomKey(code) { return `room:${code}`; }
function roomParticipantsKey(code) { return `room:${code}:participants`; }

// Phase 9 Redis key helpers
function roomRolesKey(code) { return `room:${code}:roles`; }
function roomLockedKey(code) { return `room:${code}:locked`; }
function roomNamesKey(code) { return `room:${code}:names`; }
function roomLobbyKey(code) { return `room:${code}:lobby`; }
function roomLobbyNamesKey(code) { return `room:${code}:lobby:names`; }
function roomSuspendedKey(code) { return `room:${code}:suspended`; }
function roomLeaveTokenKey(code, identity) { return `room:${code}:leavetoken:${identity}`; }
function roomFilesKey(code) { return `room:${code}:files`; }           // Hash: fileId → JSON metadata
function roomFilesTotalSizeKey(code) { return `room:${code}:filesize`; } // String: cumulative bytes uploaded

// ---------------------------------------------------------------------------
// Phase 9 — Role hierarchy and permission validation (server-side mirror)
// Matches InterPermissions.swift permission matrix exactly.
// ---------------------------------------------------------------------------
const ROLE_HIERARCHY = { 'participant': 0, 'presenter': 1, 'panelist': 2, 'co-host': 3, 'host': 4, 'interviewer': 4 };
const MODERATOR_ROLES = ['host', 'co-host', 'interviewer'];

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

/// Admit all lobby members for a room: generate tokens, add as participants,
/// store polling status, then clear lobby keys. Returns the count admitted.
/// Enforces MAX_PARTICIPANTS_PER_ROOM — excess members get status 'room_full'.
async function admitAllFromLobby(code, roomData) {
  const lobbyIdentities = await redis.zrange(roomLobbyKey(code), 0, -1);
  let admittedCount = 0;
  let currentCount = await getParticipantCount(code);

  for (const memberIdentity of lobbyIdentities) {
    // Stop admitting once the room is full
    if (currentCount >= MAX_PARTICIPANTS_PER_ROOM) {
      // Mark remaining lobby members as room_full so clients know why
      const remaining = lobbyIdentities.slice(lobbyIdentities.indexOf(memberIdentity));
      for (const remainingIdentity of remaining) {
        await redis.set(`room:${code}:lobby:${remainingIdentity}:status`, 'room_full', 'EX', 300);
      }
      break;
    }

    try {
      const memberDisplayName = await redis.hget(roomLobbyNamesKey(code), memberIdentity) || memberIdentity;
      await addParticipant(code, memberIdentity);
      await redis.hset(roomRolesKey(code), memberIdentity, 'participant');
      // Store identity → displayName for token refresh
      await redis.hset(roomNamesKey(code), memberIdentity, memberDisplayName);

      // Generate token
      const metadata = { role: 'participant' };
      const jwt = await createToken(memberIdentity, memberDisplayName, roomData.roomName, false, metadata);

      // Store admit status for polling
      await redis.set(`room:${code}:lobby:${memberIdentity}:status`, 'admitted', 'EX', 300);
      await redis.set(`room:${code}:lobby:${memberIdentity}:token`, jwt, 'EX', 300);
      await redis.set(`room:${code}:lobby:${memberIdentity}:serverURL`, LIVEKIT_SERVER_URL, 'EX', 300);

      admittedCount++;
      currentCount++;
    } catch (e) {
      console.error(`[warn] Failed to admit lobby member ${memberIdentity}:`, e.message);
    }
  }

  // Clear the lobby
  if (lobbyIdentities.length > 0) {
    await redis.del(roomLobbyKey(code));
    await redis.del(roomLobbyNamesKey(code));
  }

  return admittedCount;
}

// ---------------------------------------------------------------------------
// POST /room/create
// Body: { identity, displayName, roomType? }
// Returns: { roomCode, roomName, token, serverURL, roomType }
// ---------------------------------------------------------------------------
app.post('/room/create', requireIdempotencyKey, async (req, res) => {
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
  // hostTier is snapshotted at creation so in-meeting tier checks use the
  // tier the host had when the room was created, not the current JWT tier.
  const hostTier = (req.user && req.user.tier) ? req.user.tier : 'free';
  const pipeline = redis.pipeline();
  pipeline.hset(roomKey(roomCode),
    'roomName', roomName,
    'createdAt', Date.now().toString(),
    'hostIdentity', identity,
    'roomType', roomType,
    'hostTier', hostTier,
  );
  pipeline.expire(roomKey(roomCode), ROOM_CODE_EXPIRY_SECONDS);
  // Participants stored as a Redis Set (identity dedup is automatic)
  pipeline.sadd(roomParticipantsKey(roomCode), identity);
  pipeline.expire(roomParticipantsKey(roomCode), ROOM_CODE_EXPIRY_SECONDS);
  // Store identity → displayName mapping for token refresh
  pipeline.hset(roomNamesKey(roomCode), identity, displayName);
  pipeline.expire(roomNamesKey(roomCode), ROOM_CODE_EXPIRY_SECONDS);
  await pipeline.exec();

  try {
    // Host metadata includes role — always include it for Phase 9 role enforcement.
    const hostRole = (roomType === 'interview') ? 'interviewer' : 'host';
    const metadata = { role: hostRole };
    const jwt = await createToken(identity, displayName, roomName, true, metadata);
    console.log(`[audit] Room created: code=${roomCode} type=${roomType} host=${identity}`);

    // Store host role in Redis for server-side validation (Phase 9)
    await redis.hset(roomRolesKey(roomCode), identity, hostRole);
    await redis.expire(roomRolesKey(roomCode), ROOM_CODE_EXPIRY_SECONDS);

    // Issue a single-use leave token so only the legitimate participant can call /room/leave
    const leaveToken = crypto.randomBytes(32).toString('hex');
    await redis.set(roomLeaveTokenKey(roomCode, identity), leaveToken, 'EX', ROOM_CODE_EXPIRY_SECONDS);

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
      leaveToken,
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
      await redis.zadd(roomLobbyKey(code), score, identity);
      await redis.expire(roomLobbyKey(code), ROOM_CODE_EXPIRY_SECONDS);
      await redis.hset(roomLobbyNamesKey(code), identity, displayName);
      await redis.expire(roomLobbyNamesKey(code), ROOM_CODE_EXPIRY_SECONDS);
      const position = await redis.zrank(roomLobbyKey(code), identity);

      // Generate a per-join secret so only the legitimate joiner can poll lobby-status
      const pollToken = require('crypto').randomBytes(32).toString('hex');
      await redis.set(`room:${code}:lobby:${identity}:pollToken`, pollToken, 'EX', ROOM_CODE_EXPIRY_SECONDS);

      console.log(`[audit] Lobby join: code=${code} identity=${identity} position=${position + 1}`);
      return res.json({ status: 'waiting', position: (position || 0) + 1, pollToken });
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

    // Store identity → displayName mapping for token refresh
    await redis.hset(roomNamesKey(code), identity, displayName);

    // Store participant role in Redis for server-side validation (Phase 9)
    await redis.hset(roomRolesKey(code), identity, joinerRole === 'interviewee' ? 'participant' : joinerRole);

    // Issue a single-use leave token so only the legitimate participant can call /room/leave
    const leaveToken = crypto.randomBytes(32).toString('hex');
    await redis.set(roomLeaveTokenKey(code, identity), leaveToken, 'EX', ROOM_CODE_EXPIRY_SECONDS);

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
      leaveToken,
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
    // Look up stored display name — fall back to identity only as last resort
    const storedName = await redis.hget(roomNamesKey(code), identity);
    const displayName = storedName || identity;
    const jwt = await createToken(identity, displayName, roomData.roomName, isHost);
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
app.post('/room/promote', auth.requireAuth, async (req, res) => {
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
app.post('/room/mute', auth.requireAuth, async (req, res) => {
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

  // Cannot mute someone of equal or higher role
  const targetRole = await getParticipantRole(code, targetIdentity);
  const callerRole = validation.role;
  if (roleLevel(targetRole) >= roleLevel(callerRole)) {
    return res.status(403).json({ error: 'Cannot mute a participant with equal or higher privileges.' });
  }

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
app.post('/room/mute-all', auth.requireAuth, async (req, res) => {
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
    const callerRole = validation.role;
    let mutedCount = 0;
    let skippedCount = 0;

    for (const p of participants) {
      // Skip the caller (don't mute yourself)
      if (p.identity === callerIdentity) continue;

      // Skip participants with equal or higher privileges
      const targetRole = await getParticipantRole(code, p.identity);
      if (roleLevel(targetRole) >= roleLevel(callerRole)) {
        skippedCount++;
        continue;
      }

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

    console.log(`[audit] Mute all: code=${code} muted=${mutedCount} skipped=${skippedCount} by=${callerIdentity}`);
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
app.post('/room/remove', auth.requireAuth, async (req, res) => {
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
// POST /room/leave — Participant voluntarily leaves the room
// Body: { roomCode, identity }
// Returns: { success }
// NOTE: intentionally NOT gated by auth.requireAuth — guests (unauthenticated
// users) must be able to signal departure so Redis is kept consistent.
// The operation is safe: srem can only remove the caller's own identity, and
// knowing the roomCode + identity grants no read access to other participants.
// ---------------------------------------------------------------------------
app.post('/room/leave', async (req, res) => {
  const { roomCode, identity, leaveToken } = req.body;

  if (!roomCode || !identity) {
    return res.status(400).json({ error: 'roomCode and identity are required' });
  }

  if (!leaveToken) {
    return res.status(401).json({ error: 'leaveToken is required' });
  }

  const code = roomCode.toUpperCase();
  const roomData = await getRoomData(code);
  if (!roomData) return res.status(404).json({ error: 'Invalid or expired room code' });

  // Verify leaveToken — atomically compare-and-delete so concurrent leave
  // requests cannot both pass the check (GET+compare+DEL race condition).
  // Returns 1 if the token matched and was deleted, 0 otherwise.
  const leaveTokenLua = `
    if redis.call('GET', KEYS[1]) == ARGV[1] then
      return redis.call('DEL', KEYS[1])
    else
      return 0
    end
  `;
  const tokenConsumed = await redis.eval(leaveTokenLua, 1, roomLeaveTokenKey(code, identity), leaveToken);
  if (!tokenConsumed) {
    return res.status(403).json({ error: 'Invalid leave token' });
  }

  const wasMember = await redis.srem(roomParticipantsKey(code), identity);
  await redis.hdel(roomRolesKey(code), identity);
  await redis.hdel(roomNamesKey(code), identity);

  const remaining = await getParticipantCount(code);
  console.log(`[audit] Leave: code=${code} identity=${identity} removed=${wasMember} remaining=${remaining}`);

  // When the last participant leaves, clean up any uploaded files for this room
  if (remaining === 0) {
    deleteRoomFiles(code).catch(() => {});
  }

  res.json({ success: true, participantCount: remaining });
});

// ---------------------------------------------------------------------------
// POST /room/lock — Lock the meeting (prevent new joins)
// Body: { roomCode, callerIdentity }
// Returns: { success }
// ---------------------------------------------------------------------------
app.post('/room/lock', auth.requireAuth, async (req, res) => {
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
app.post('/room/unlock', auth.requireAuth, async (req, res) => {
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
app.post('/room/suspend', auth.requireAuth, async (req, res) => {
  const { roomCode, callerIdentity, targetIdentity } = req.body;

  if (!roomCode || !callerIdentity || !targetIdentity) {
    return res.status(400).json({ error: 'roomCode, callerIdentity, and targetIdentity are required' });
  }

  const code = roomCode.toUpperCase();
  const roomData = await getRoomData(code);
  if (!roomData) return res.status(404).json({ error: 'Invalid or expired room code' });

  const validation = await validateModerator(code, callerIdentity);
  if (!validation.valid) return res.status(403).json({ error: validation.error });

  // Cannot suspend someone of equal or higher role
  const targetRole = await getParticipantRole(code, targetIdentity);
  const callerRole = validation.role;
  if (roleLevel(targetRole) >= roleLevel(callerRole)) {
    return res.status(403).json({ error: 'Cannot suspend a participant with equal or higher privileges.' });
  }

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
app.post('/room/unsuspend', auth.requireAuth, async (req, res) => {
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
app.post('/room/lobby/enable', auth.requireAuth, async (req, res) => {
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
app.post('/room/lobby/disable', auth.requireAuth, async (req, res) => {
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

  // Admit all waiting participants automatically (real admission — tokens + participant records)
  const admittedCount = await admitAllFromLobby(code, roomData);

  console.log(`[audit] Lobby disabled: code=${code} by=${callerIdentity} (${admittedCount} auto-admitted)`);
  res.json({ success: true, autoAdmitted: admittedCount });
});

// ---------------------------------------------------------------------------
// POST /room/admit — Admit a participant from the lobby
// Body: { roomCode, callerIdentity, targetIdentity, targetDisplayName }
// Returns: { token, serverURL }
// ---------------------------------------------------------------------------
app.post('/room/admit', auth.requireAuth, async (req, res) => {
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
  await redis.zrem(roomLobbyKey(code), targetIdentity);
  await redis.hdel(roomLobbyNamesKey(code), targetIdentity);

  // Add to participants
  await addParticipant(code, targetIdentity);
  await redis.hset(roomRolesKey(code), targetIdentity, 'participant');

  // Generate token for the admitted participant
  const displayName = targetDisplayName || targetIdentity;
  // Store identity → displayName for token refresh
  await redis.hset(roomNamesKey(code), targetIdentity, displayName);
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
app.post('/room/admit-all', auth.requireAuth, async (req, res) => {
  const { roomCode, callerIdentity } = req.body;

  if (!roomCode || !callerIdentity) {
    return res.status(400).json({ error: 'roomCode and callerIdentity are required' });
  }

  const code = roomCode.toUpperCase();
  const roomData = await getRoomData(code);
  if (!roomData) return res.status(404).json({ error: 'Invalid or expired room code' });

  const validation = await validateModerator(code, callerIdentity);
  if (!validation.valid) return res.status(403).json({ error: validation.error });

  const admittedCount = await admitAllFromLobby(code, roomData);

  console.log(`[audit] Admit all: code=${code} admitted=${admittedCount} by=${callerIdentity}`);
  res.json({ success: true, admittedCount });
});

// ---------------------------------------------------------------------------
// POST /room/deny — Deny a participant from the lobby
// Body: { roomCode, callerIdentity, targetIdentity }
// Returns: { success }
// ---------------------------------------------------------------------------
app.post('/room/deny', auth.requireAuth, async (req, res) => {
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
  await redis.zrem(roomLobbyKey(code), targetIdentity);
  await redis.hdel(roomLobbyNamesKey(code), targetIdentity);

  // Store denied status for lobby polling
  await redis.set(`room:${code}:lobby:${targetIdentity}:status`, 'denied', 'EX', 300);

  console.log(`[audit] Denied from lobby: code=${code} identity=${targetIdentity} by=${callerIdentity}`);
  res.json({ success: true });
});

// ---------------------------------------------------------------------------
// GET /room/lobby/list/:code — List all participants waiting in the lobby
// Requires: auth (host/co-host only, validated via validateModerator)
// Query: ?callerIdentity=...
// Returns: { participants: [{ identity, displayName, position, waitingSince }] }
// ---------------------------------------------------------------------------
app.get('/room/lobby/list/:code', auth.requireAuth, async (req, res) => {
  const code = req.params.code.toUpperCase();
  const callerIdentity = req.query.callerIdentity;

  if (!callerIdentity) {
    return res.status(400).json({ error: 'callerIdentity query parameter is required' });
  }

  const roomData = await getRoomData(code);
  if (!roomData) return res.status(404).json({ error: 'Invalid or expired room code' });

  const validation = await validateModerator(code, callerIdentity);
  if (!validation.valid) return res.status(403).json({ error: validation.error });

  try {
    // Get all lobby members with their scores (join timestamps)
    const membersWithScores = await redis.zrangebyscore(
      roomLobbyKey(code), '-inf', '+inf', 'WITHSCORES'
    );
    const names = await redis.hgetall(roomLobbyNamesKey(code)) || {};

    const participants = [];
    for (let i = 0; i < membersWithScores.length; i += 2) {
      const identity = membersWithScores[i];
      const score = parseInt(membersWithScores[i + 1], 10);
      participants.push({
        identity,
        displayName: names[identity] || identity,
        position: (i / 2) + 1,
        waitingSince: new Date(score).toISOString(),
      });
    }

    res.json({ participants });
  } catch (err) {
    console.error(`[error] Lobby list failed for code=${code}:`, err.message);
    res.status(500).json({ error: 'Failed to list lobby participants' });
  }
});

// ---------------------------------------------------------------------------
// GET /room/lobby-status/:code/:identity — Check lobby status (polling)
// Returns: { status: "waiting"|"admitted"|"denied", position?, token?, serverURL? }
// ---------------------------------------------------------------------------
app.get('/room/lobby-status/:code/:identity', async (req, res) => {
  const code = req.params.code.toUpperCase();
  const identity = req.params.identity;

  // Validate per-join pollToken to prevent unauthenticated JWT scraping
  const pollToken = req.headers['x-poll-token'] || req.query.pollToken;
  if (!pollToken) {
    return res.status(401).json({ error: 'pollToken is required' });
  }
  const storedPollToken = await redis.get(`room:${code}:lobby:${identity}:pollToken`);
  if (!storedPollToken || storedPollToken !== pollToken) {
    return res.status(403).json({ error: 'Invalid pollToken' });
  }

  // Check for admit/deny status
  const status = await redis.get(`room:${code}:lobby:${identity}:status`);

  if (status === 'admitted') {
    const token = await redis.get(`room:${code}:lobby:${identity}:token`);
    const serverURL = await redis.get(`room:${code}:lobby:${identity}:serverURL`);
    const roomData = await getRoomData(code);

    // Clean up lobby status keys (including the one-time pollToken)
    await redis.del(`room:${code}:lobby:${identity}:status`);
    await redis.del(`room:${code}:lobby:${identity}:token`);
    await redis.del(`room:${code}:lobby:${identity}:serverURL`);
    await redis.del(`room:${code}:lobby:${identity}:pollToken`);

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
    await redis.del(`room:${code}:lobby:${identity}:pollToken`);
    return res.json({ status: 'denied' });
  }

  if (status === 'room_full') {
    await redis.del(`room:${code}:lobby:${identity}:status`);
    await redis.del(`room:${code}:lobby:${identity}:pollToken`);
    return res.json({ status: 'room_full' });
  }

  // Still waiting — calculate position
  const rank = await redis.zrank(roomLobbyKey(code), identity);

  if (rank === null) {
    // Not in lobby — might have been removed or room expired
    return res.json({ status: 'not_found' });
  }

  res.json({ status: 'waiting', position: rank + 1 });
});

// ---------------------------------------------------------------------------
// POST /room/password — Set or change meeting password
// Body: { roomCode, callerIdentity, password } (password = null to remove)
// Returns: { success }
// ---------------------------------------------------------------------------
app.post('/room/password', auth.requireAuth, async (req, res) => {
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

// ===========================================================================
// PHASE 10C — CLOUD RECORDING ENDPOINTS
// ===========================================================================

// ---------------------------------------------------------------------------
// Helper: check if caller is host or co-host in the LiveKit room right now.
// Queries LiveKit RoomService participant metadata.
// ---------------------------------------------------------------------------
async function isHostOrCoHostInRoom(userId, roomName) {
  try {
    const participants = await roomService.listParticipants(roomName);
    for (const p of participants) {
      if (p.identity !== String(userId)) continue;
      const meta = p.metadata ? JSON.parse(p.metadata) : {};
      if (meta.role === 'host' || meta.role === 'co-host') return true;
    }
  } catch {
    // If query fails (room closed, etc.), deny by default
  }
  return false;
}

// ---------------------------------------------------------------------------
// Helper: check recording quota for a user.
// Returns { allowed, used, quota, remainingMinutes }.
// ---------------------------------------------------------------------------
async function checkRecordingQuota(userId, tier) {
  const validatedTier = getValidatedTier(tier);
  const quota = RECORDING_QUOTAS[validatedTier] || 0;
  if (quota === 0) {
    return { allowed: false, used: 0, quota: 0, remainingMinutes: 0, reason: 'Cloud recording not available on free tier' };
  }

  const result = await db.query(
    'SELECT recording_minutes_used FROM users WHERE id = $1',
    [userId]
  );
  if (result.rows.length === 0) {
    return { allowed: false, used: 0, quota, remainingMinutes: 0, reason: 'User not found' };
  }

  const used = result.rows[0].recording_minutes_used || 0;
  const remaining = quota - used;

  if (remaining <= 0) {
    return { allowed: false, used, quota, remainingMinutes: 0, reason: 'Recording quota exceeded' };
  }

  return { allowed: true, used, quota, remainingMinutes: remaining };
}

// ---------------------------------------------------------------------------
// POST /room/record/start — Start cloud recording (Egress API)
// Body: { roomCode, callerIdentity, mode?, estimatedDurationMinutes? }
// mode: "cloud_composed" (default) | "multi_track"
// Requires: auth + host/co-host role
// Tier check uses the room's hostTier (snapshotted at creation) so that
// mid-meeting tier downgrades do not block recording during an active meeting.
// Returns: { success, egressId, recordingSessionId }
// ---------------------------------------------------------------------------
app.post('/room/record/start', auth.requireAuth, async (req, res) => {
  const { roomCode, callerIdentity, mode, estimatedDurationMinutes } = req.body;

  if (!roomCode || !callerIdentity) {
    return res.status(400).json({ error: 'roomCode and callerIdentity are required' });
  }

  const code = roomCode.toUpperCase();
  const roomData = await getRoomData(code);
  if (!roomData) return res.status(404).json({ error: 'Invalid or expired room code' });

  // Use the room's creation-time tier for feature gating. This ensures that
  // a host who was Pro when the meeting started retains Pro features for the
  // entire meeting duration, even if their account tier changes mid-session.
  const TIER_LEVELS = { free: 0, pro: 1, hiring: 2 };
  const roomTier = roomData.hostTier || 'free';
  if ((TIER_LEVELS[roomTier] ?? 0) < (TIER_LEVELS['pro'] ?? 0)) {
    return res.status(403).json({
      error: 'This feature requires a pro plan or higher',
      currentTier: roomTier,
      requiredTier: 'pro',
    });
  }

  // Validate caller is a moderator (host/co-host)
  const validation = await validateModerator(code, callerIdentity);
  if (!validation.valid) return res.status(403).json({ error: validation.error });

  // Validate estimated duration
  const rawEstimate = estimatedDurationMinutes;
  if (
    rawEstimate === undefined || rawEstimate === null ||
    typeof rawEstimate !== 'number' || !Number.isFinite(rawEstimate) || rawEstimate <= 0
  ) {
    return res.status(400).json({
      error: 'estimatedDurationMinutes is required and must be a positive number',
    });
  }
  const estimatedMinutes = Math.ceil(rawEstimate);

  // Check quota using the room's creation-time tier (same grace period logic)
  const quotaCheck = await checkRecordingQuota(req.user.userId, roomTier);
  if (!quotaCheck.allowed) {
    return res.status(403).json({ error: quotaCheck.reason, quota: quotaCheck });
  }
  if (quotaCheck.remainingMinutes < estimatedMinutes) {
    return res.status(403).json({
      error: `Estimated duration (${estimatedMinutes}m) exceeds remaining quota (${quotaCheck.remainingMinutes}m)`,
      quota: quotaCheck,
    });
  }

  // Check for existing active recording in this room (prevent double-start)
  const existingResult = await db.query(
    `SELECT id FROM recording_sessions WHERE room_name = $1 AND status = 'active'`,
    [roomData.roomName]
  );
  if (existingResult.rows.length > 0) {
    return res.status(409).json({ error: 'A recording is already active in this room' });
  }

  // [Gap #9] Acquire a Redis distributed lock to prevent concurrent start attempts.
  // SET NX EX 30 → lock expires after 30 s even if the holder crashes.
  const lockKey = `recording:lock:${roomData.roomName}`;
  const lockAcquired = await redis.set(lockKey, callerIdentity, 'EX', 30, 'NX');
  if (!lockAcquired) {
    return res.status(409).json({ error: 'Another recording start is already in progress for this room' });
  }

  const validatedTier = getValidatedTier(roomTier);
  const recordingMode = mode === 'multi_track' ? 'multi_track' : 'cloud_composed';

  try {
    let egressInfo;

    if (recordingMode === 'cloud_composed') {
      // Room Composite Egress — single composed video with speaker layout
      const fileOutput = new EncodedFileOutput({
        filepath: `recordings/${validatedTier}/${roomData.roomName}/{time}.mp4`,
        output: {
          case: 's3',
          value: {
            bucket: S3_RECORDINGS_BUCKET,
            region: AWS_REGION,
            // accessKey and secret intentionally omitted — resolved by IAM role
          },
        },
      });

      egressInfo = await egressClient.startRoomCompositeEgress(roomData.roomName, {
        file: fileOutput,
        layout: 'speaker',
        preset: EncodingOptionsPreset.H264_1080P_30,
      });
    } else {
      // Multi-track: start per-participant egress (Phase 10D)
      const participants = await roomService.listParticipants(roomData.roomName);
      const egressIds = [];
      for (const p of participants) {
        try {
          const fileOutput = new EncodedFileOutput({
            filepath: `recordings/${validatedTier}/${roomData.roomName}/multitrack/{publisher_identity}-{time}.mp4`,
            output: {
              case: 's3',
              value: {
                bucket: S3_RECORDINGS_BUCKET,
                region: AWS_REGION,
              },
            },
          });

          const pInfo = await egressClient.startParticipantEgress(roomData.roomName, p.identity, {
            file: fileOutput,
            preset: EncodingOptionsPreset.H264_1080P_30,
            screenShare: true,
          });
          egressIds.push({
            participantIdentity: p.identity,
            participantName: p.name || p.identity,
            egressId: pInfo.egressId,
          });
        } catch (pErr) {
          console.warn(`[warn] Failed to start egress for participant ${p.identity}: ${pErr.message}`);
        }
      }
      if (egressIds.length === 0) {
        return res.status(500).json({ error: 'Failed to start egress for any participant' });
      }
      // Use the first egress ID as the primary reference on the session
      egressInfo = { egressId: egressIds[0].egressId, _multiTrackEgressIds: egressIds };
    }

    // Helper: stop all started egresses to avoid orphans when a downstream operation fails.
    // Used in the catch block below. Errors from individual stops are logged and swallowed
    // so the original error can propagate cleanly.
    const stopStartedEgresses = async () => {
      const toStop = egressInfo && egressInfo._multiTrackEgressIds
        ? egressInfo._multiTrackEgressIds.map(t => t.egressId)
        : egressInfo ? [egressInfo.egressId] : [];
      for (const eid of toStop) {
        try {
          await egressClient.stopEgress(eid);
          console.log(`[cleanup] Stopped orphaned egress ${eid} after DB failure`);
        } catch (stopErr) {
          console.warn(`[warn] Failed to stop orphaned egress ${eid}: ${stopErr.message}`);
        }
      }
    };

    // Record in DB — wrapped so that any failure here triggers egress cleanup.
    let sessionId;
    try {
      const sessionResult = await db.query(
        `INSERT INTO recording_sessions (user_id, room_name, room_code, egress_id, recording_mode, watermarked, status)
         VALUES ($1, $2, $3, $4, $5, $6, 'active')
         RETURNING id`,
        [req.user.userId, roomData.roomName, code, egressInfo.egressId, recordingMode, validatedTier === 'free']
      );
      sessionId = sessionResult.rows[0].id;

      // For multi-track, insert per-participant track records
      if (recordingMode === 'multi_track' && egressInfo._multiTrackEgressIds) {
        for (const track of egressInfo._multiTrackEgressIds) {
          await db.query(
            `INSERT INTO recording_tracks (session_id, participant_identity, participant_name, egress_id, status)
             VALUES ($1, $2, $3, $4, 'active')`,
            [sessionId, track.participantIdentity, track.participantName, track.egressId]
          );
        }
      }
    } catch (dbErr) {
      // DB insert failed — stop all egresses that were successfully started so they don't run untracked.
      console.error(`[error] DB insert failed after starting egress(es); stopping orphaned egresses:`, dbErr.message);
      await stopStartedEgresses();
      return res.status(500).json({ error: 'Failed to persist recording session: ' + dbErr.message });
    }

    // Update room metadata to indicate recording is active
    try {
      const existingMeta = await redis.hget(roomKey(code), 'metadata');
      const meta = existingMeta ? JSON.parse(existingMeta) : {};
      meta.recording = true;
      meta.recordingMode = recordingMode;
      meta.recordingSessionId = sessionId;
      await redis.hset(roomKey(code), 'metadata', JSON.stringify(meta));
    } catch (metaErr) {
      console.warn(`[warn] Failed to update room metadata for recording: ${metaErr.message}`);
    }

    console.log(`[audit] Recording started: code=${code} mode=${recordingMode} egress=${egressInfo.egressId} by=${callerIdentity}`);
    res.json({ success: true, egressId: egressInfo.egressId, recordingSessionId: sessionId });
  } catch (err) {
    console.error(`[error] Start recording failed:`, err.message);
    // Check if egress service is unavailable
    if (err.message && err.message.includes('UNAVAILABLE')) {
      return res.status(503).json({ error: 'LiveKit Egress service is not available. Ensure egress is running.' });
    }
    res.status(500).json({ error: 'Failed to start recording: ' + err.message });
  } finally {
    // [Gap #9] Release the distributed lock atomically — only if we still own it.
    // A plain DEL would delete a lock re-acquired by another process if our 30s TTL
    // expired during a slow egress/DB operation. The Lua script atomically checks
    // that the stored value still matches callerIdentity before deleting.
    const releaseLua = `
      if redis.call('GET', KEYS[1]) == ARGV[1] then
        return redis.call('DEL', KEYS[1])
      else
        return 0
      end
    `;
    await redis.eval(releaseLua, 1, lockKey, callerIdentity).catch((err) => {
      console.warn(`[warn] Failed to release recording lock for ${lockKey}: ${err.message}`);
    });
  }
});

// ---------------------------------------------------------------------------
// POST /room/record/stop — Stop cloud recording
// Body: { roomCode, callerIdentity, egressId }
// Requires: auth + host/co-host role
// Returns: { success, message }
// ---------------------------------------------------------------------------
app.post('/room/record/stop', auth.requireAuth, async (req, res) => {
  const { roomCode, callerIdentity, egressId } = req.body;

  if (!roomCode || !callerIdentity || !egressId) {
    return res.status(400).json({ error: 'roomCode, callerIdentity, and egressId are required' });
  }

  const code = roomCode.toUpperCase();
  const roomData = await getRoomData(code);
  if (!roomData) return res.status(404).json({ error: 'Invalid or expired room code' });

  // Validate caller is a moderator
  const validation = await validateModerator(code, callerIdentity);
  if (!validation.valid) return res.status(403).json({ error: validation.error });

  // Verify the egress belongs to this room
  const sessionResult = await db.query(
    `SELECT user_id, room_name FROM recording_sessions WHERE egress_id = $1 AND status IN ('active', 'finalizing')`,
    [egressId]
  );
  if (sessionResult.rows.length === 0) {
    return res.status(404).json({ error: 'Recording session not found' });
  }
  const session = sessionResult.rows[0];
  if (session.room_name !== roomData.roomName) {
    return res.status(403).json({ error: 'Not authorized to stop this recording' });
  }

  try {
    // Check if this is a multi-track session — need to stop all participant egresses
    const tracksResult = await db.query(
      `SELECT egress_id FROM recording_tracks WHERE session_id = (
         SELECT id FROM recording_sessions WHERE egress_id = $1
       ) AND status = 'active'`,
      [egressId]
    );

    if (tracksResult.rows.length > 0) {
      // Multi-track: stop all participant egresses
      for (const track of tracksResult.rows) {
        try {
          await egressClient.stopEgress(track.egress_id);
        } catch (trackErr) {
          console.warn(`[warn] Failed to stop track egress ${track.egress_id}: ${trackErr.message}`);
        }
      }
      await db.query(
        `UPDATE recording_tracks SET status = 'finalizing'
         WHERE session_id = (SELECT id FROM recording_sessions WHERE egress_id = $1) AND status = 'active'`,
        [egressId]
      );
    } else {
      // Single egress (cloud_composed): stop the one egress
      await egressClient.stopEgress(egressId);
    }

    // Mark session as finalizing — webhook will complete the rest
    await db.query(
      `UPDATE recording_sessions SET status = 'finalizing' WHERE egress_id = $1`,
      [egressId]
    );

    // Clear recording metadata on the room
    try {
      const existingMeta = await redis.hget(roomKey(code), 'metadata');
      const meta = existingMeta ? JSON.parse(existingMeta) : {};
      meta.recording = false;
      delete meta.recordingMode;
      delete meta.recordingSessionId;
      await redis.hset(roomKey(code), 'metadata', JSON.stringify(meta));
    } catch (metaErr) {
      console.warn(`[warn] Failed to clear room recording metadata: ${metaErr.message}`);
    }

    console.log(`[audit] Recording stop initiated: code=${code} egress=${egressId} by=${callerIdentity}`);
    res.json({ success: true, message: 'Recording stop initiated; file will be available shortly' });
  } catch (err) {
    console.error(`[error] Stop recording failed:`, err.message);
    res.status(500).json({ error: 'Failed to stop recording: ' + err.message });
  }
});

// ---------------------------------------------------------------------------
// GET /room/record/status/:code — Get recording status for a room
// Returns: { recording, mode, egressId, sessionId, startedAt }
// ---------------------------------------------------------------------------
app.get('/room/record/status/:code', async (req, res) => {
  const code = req.params.code.toUpperCase();
  const roomData = await getRoomData(code);
  if (!roomData) return res.status(404).json({ error: 'Invalid or expired room code' });

  const result = await db.query(
    `SELECT id, egress_id, recording_mode, started_at, status
     FROM recording_sessions
     WHERE room_name = $1 AND status IN ('active', 'finalizing')
     ORDER BY started_at DESC LIMIT 1`,
    [roomData.roomName]
  );

  if (result.rows.length === 0) {
    return res.json({ recording: false });
  }

  const session = result.rows[0];
  res.json({
    recording: session.status === 'active',
    mode: session.recording_mode,
    egressId: session.egress_id,
    sessionId: session.id,
    startedAt: session.started_at,
    status: session.status,
  });
});

// ---------------------------------------------------------------------------
// GET /recordings — List user's recordings
// Query: ?limit=20&offset=0
// Requires: auth
// Returns: { recordings: [...], total }
// ---------------------------------------------------------------------------
app.get('/recordings', auth.requireAuth, async (req, res) => {
  const limit = Math.min(parseInt(req.query.limit || '20', 10), 100);
  const offset = parseInt(req.query.offset || '0', 10);

  try {
    const countResult = await db.query(
      `SELECT COUNT(*) FROM recording_sessions WHERE user_id = $1 AND status IN ('completed', 'failed')`,
      [req.user.userId]
    );
    const total = parseInt(countResult.rows[0].count, 10);

    const result = await db.query(
      `SELECT id, room_name, room_code, recording_mode, started_at, ended_at,
              duration_seconds, file_size_bytes, watermarked, status
       FROM recording_sessions
       WHERE user_id = $1 AND status IN ('completed', 'failed')
       ORDER BY created_at DESC
       LIMIT $2 OFFSET $3`,
      [req.user.userId, limit, offset]
    );

    res.json({ recordings: result.rows, total });
  } catch (err) {
    console.error(`[error] List recordings failed:`, err.message);
    res.status(500).json({ error: 'Failed to list recordings' });
  }
});

// ---------------------------------------------------------------------------
// GET /recordings/:id — Get recording details
// Requires: auth (owner only)
// Returns: full recording session data
// ---------------------------------------------------------------------------
app.get('/recordings/:id', auth.requireAuth, async (req, res) => {
  const result = await db.query(
    `SELECT * FROM recording_sessions WHERE id = $1`,
    [req.params.id]
  );

  if (result.rows.length === 0) return res.status(404).json({ error: 'Recording not found' });

  const session = result.rows[0];
  if (session.user_id !== req.user.userId) {
    return res.status(403).json({ error: 'Not authorized to view this recording' });
  }

  res.json(session);
});

// ---------------------------------------------------------------------------
// GET /recordings/:id/download — Get presigned download URL
// Requires: auth (owner only)
// Returns: { url, expiresInSeconds }
// ---------------------------------------------------------------------------
app.get('/recordings/:id/download', auth.requireAuth, async (req, res) => {
  const result = await db.query(
    `SELECT storage_url, user_id FROM recording_sessions WHERE id = $1 AND status = 'completed'`,
    [req.params.id]
  );

  if (result.rows.length === 0) return res.status(404).json({ error: 'Recording not found' });

  const session = result.rows[0];
  if (session.user_id !== req.user.userId) {
    return res.status(403).json({ error: 'Not authorized to download this recording' });
  }

  if (!session.storage_url) {
    return res.status(404).json({ error: 'Recording file not available (local recording or still processing)' });
  }

  // Resolve S3 key from storage_url — handles absolute URLs and relative paths.
  let s3Key;
  try {
    s3Key = new URL(session.storage_url).pathname.slice(1);
  } catch (_urlErr) {
    if (!session.storage_url.includes('://')) {
      // Relative path (e.g. "recordings/abc.mp4" or "/recordings/abc.mp4") — trim leading slashes.
      s3Key = session.storage_url.replace(/^\/+/, '');
      console.warn(`[warn] storage_url for recording ${req.params.id} is not an absolute URL` +
        ` ("${session.storage_url}"); derived s3Key="${s3Key}" by trimming leading slashes`);
    } else {
      console.error(`[error] Malformed storage_url for recording ${req.params.id}:` +
        ` "${session.storage_url}" — ${_urlErr.message}`);
      return res.status(400).json({ error: 'Recording has an invalid storage URL' });
    }
  }

  try {
    // Generate a presigned URL using the module-level shared S3 client.
    const command = new GetObjectCommand({ Bucket: S3_RECORDINGS_BUCKET, Key: s3Key });
    const presignedUrl = await getSignedUrl(s3Client, command, { expiresIn: 900 });

    // Audit log
    await db.query(
      `INSERT INTO recording_download_audit (session_id, user_id, ip_address)
       VALUES ($1, $2, $3)`,
      [req.params.id, req.user.userId, req.ip]
    );

    res.json({ url: presignedUrl, expiresInSeconds: 900 });
  } catch (err) {
    console.error(`[error] Download URL generation failed for recording ${req.params.id}:`, err.message);
    res.status(500).json({ error: 'Failed to generate download URL' });
  }
});

// ---------------------------------------------------------------------------
// DELETE /recordings/:id — Delete a recording
// Requires: auth (owner only)
// Returns: { success }
// ---------------------------------------------------------------------------
app.delete('/recordings/:id', auth.requireAuth, async (req, res) => {
  const result = await db.query(
    `SELECT id, user_id, storage_url FROM recording_sessions WHERE id = $1`,
    [req.params.id]
  );

  if (result.rows.length === 0) return res.status(404).json({ error: 'Recording not found' });

  const session = result.rows[0];
  if (session.user_id !== req.user.userId) {
    return res.status(403).json({ error: 'Not authorized to delete this recording' });
  }

  // [Gap #11] Delete the recording file from S3 before removing the DB row.
  if (session.storage_url) {
    // Resolve S3 key — handles absolute URLs and relative paths.
    let s3Key;
    try {
      s3Key = new URL(session.storage_url).pathname.slice(1);
    } catch (_urlErr) {
      if (!session.storage_url.includes('://')) {
        // Relative path — derive key by trimming leading slashes.
        s3Key = session.storage_url.replace(/^\/+/, '');
        console.warn(`[warn] storage_url for recording ${req.params.id} is not an absolute URL` +
          ` ("${session.storage_url}"); derived s3Key="${s3Key}" by trimming leading slashes`);
      } else {
        console.error(`[error] Malformed storage_url for recording ${req.params.id}:` +
          ` "${session.storage_url}" — ${_urlErr.message}; skipping S3 deletion`);
        s3Key = null;
      }
    }

    if (s3Key) {
      try {
        await s3Client.send(new DeleteObjectCommand({ Bucket: S3_RECORDINGS_BUCKET, Key: s3Key }));
        console.log(`[audit] S3 object deleted: key=${s3Key}`);
      } catch (s3Err) {
        console.error(`[warn] Failed to delete S3 object for recording ${req.params.id}:`, s3Err.message);
        // Continue with DB deletion even if S3 delete fails — orphaned objects
        // can be cleaned up by S3 lifecycle rules.
      }
    }
  }

  await db.query(`DELETE FROM recording_sessions WHERE id = $1`, [req.params.id]);

  console.log(`[audit] Recording deleted: id=${req.params.id} by=${req.user.userId}`);
  res.json({ success: true });
});

// ---------------------------------------------------------------------------
// POST /webhooks/egress — LiveKit Egress webhook handler
// Receives EgressInfo events as recording progresses.
// Validates X-Livekit-Signature header.
// ---------------------------------------------------------------------------
app.post('/webhooks/egress', express.raw({ type: 'application/webhook+json' }), async (req, res) => {
  let event;
  try {
    event = await webhookReceiver.receive(req.body, req.get('Authorization'));
  } catch (err) {
    console.error(`[warn] Invalid egress webhook signature:`, err.message);
    return res.status(400).json({ error: 'Invalid webhook signature' });
  }

  const egressInfo = event.egressInfo;
  if (!egressInfo) {
    // Handle participant lifecycle events
    if (event.event === 'participant_left' && event.participant) {
      const participant = event.participant;
      const roomName = event.room && event.room.name ? event.room.name : null;
      const identity = participant.identity;

      if (roomName && identity) {
        // Look up the room code from the room name by scanning known room keys.
        // Room names are stored as a field in the room:{code} hash.
        // We iterate to find the matching code (rooms are short-lived, so this is acceptable).
        let matchedCode = null;
        let cursor = '0';
        outer: do {
          const scanResult = await redis.scan(cursor, 'MATCH', 'room:*', 'COUNT', 200);
          cursor = scanResult[0];
          // Keep only top-level room:{CODE} keys
          const keys = scanResult[1].filter(k => /^room:[^:]+$/.test(k));
          for (const key of keys) {
            const storedName = await redis.hget(key, 'roomName');
            if (storedName === roomName) {
              matchedCode = key.replace('room:', '');
              break outer;
            }
          }
        } while (cursor !== '0' && !matchedCode);

        if (matchedCode) {
          const wasMember = await redis.srem(roomParticipantsKey(matchedCode), identity);
          await redis.hdel(roomRolesKey(matchedCode), identity);
          await redis.hdel(roomNamesKey(matchedCode), identity);
          const remaining = await getParticipantCount(matchedCode);
          console.log(`[webhook] participant_left: room=${roomName} code=${matchedCode} identity=${identity} removed=${wasMember} remaining=${remaining}`);
        } else {
          console.log(`[webhook] participant_left: room=${roomName} identity=${identity} — no matching room code found`);
        }
      }
    }
    return res.status(200).json({ ignored: true });
  }

  const { egressId, status } = egressInfo;
  console.log(`[egress-webhook] egressId=${egressId} status=${status}`);

  try {
    if (status === 'EGRESS_ENDING' || status === 2) {
      // Egress is shutting down — mark as finalizing (idempotent)
      await db.query(
        `UPDATE recording_sessions SET status = 'finalizing' WHERE egress_id = $1 AND status = 'active'`,
        [egressId]
      );
      // Also check if this is a multi-track participant egress
      await db.query(
        `UPDATE recording_tracks SET status = 'finalizing' WHERE egress_id = $1 AND status = 'active'`,
        [egressId]
      );

    } else if (status === 'EGRESS_COMPLETE' || status === 3) {
      // File is fully written and uploaded
      const fileResults = egressInfo.fileResults || egressInfo.file_results || [];
      const storageUrl = fileResults.length > 0 ? (fileResults[0].location || fileResults[0].download_url || null) : null;
      const fileSizeBytes = fileResults.length > 0 ? (fileResults[0].size || null) : null;

      // Calculate duration from egress timestamps (nanoseconds).
      // BigInt() throws for floats and non-numeric strings, so we coerce to a
      // safe integer string first and catch any remaining edge cases.
      let durationSeconds = null;
      const startedAt = egressInfo.startedAt || egressInfo.started_at;
      const endedAt   = egressInfo.endedAt   || egressInfo.ended_at;
      if (startedAt && endedAt) {
        try {
          // Convert to integer (handles both Number and numeric-string inputs;
          // Math.trunc drops any fractional part that would cause BigInt to throw).
          const startNs = BigInt(Math.trunc(Number(startedAt)));
          const endNs   = BigInt(Math.trunc(Number(endedAt)));
          durationSeconds = Math.max(0, Math.floor(Number(endNs - startNs) / 1e9));
        } catch (tsErr) {
          console.error(
            `[warn] Could not compute duration for egress ${egressId}:` +
            ` startedAt=${startedAt} endedAt=${endedAt} — ${tsErr.message}; defaulting to 0`
          );
          durationSeconds = 0;
        }
      }

      // Check if this egress belongs to a multi-track participant track
      const trackResult = await db.query(
        `UPDATE recording_tracks
         SET status = 'completed', storage_url = $1, duration_seconds = $2, file_size_bytes = $3
         WHERE egress_id = $4
         RETURNING session_id, participant_identity`,
        [storageUrl, durationSeconds, fileSizeBytes, egressId]
      );

      if (trackResult.rows.length > 0) {
        // This is a multi-track participant egress — check if all tracks are done
        const sessionId = trackResult.rows[0].session_id;
        const pendingResult = await db.query(
          `SELECT COUNT(*) FROM recording_tracks WHERE session_id = $1 AND status NOT IN ('completed', 'failed')`,
          [sessionId]
        );
        const pendingCount = parseInt(pendingResult.rows[0].count, 10);

        if (pendingCount === 0) {
          // All tracks complete — generate manifest and finalize session
          const allTracks = await db.query(
            `SELECT participant_identity, participant_name, storage_url, duration_seconds, has_screen_share
             FROM recording_tracks WHERE session_id = $1 AND status = 'completed'`,
            [sessionId]
          );

          const sessionInfo = await db.query(
            `SELECT room_name, started_at FROM recording_sessions WHERE id = $1`,
            [sessionId]
          );

          // Calculate total duration as max of all track durations
          const maxDuration = allTracks.rows.reduce((max, t) => Math.max(max, t.duration_seconds || 0), 0);

          // Generate manifest JSON (uploaded to S3 alongside tracks)
          const manifest = {
            roomName: sessionInfo.rows[0]?.room_name || 'unknown',
            recordingMode: 'multi_track',
            startedAt: sessionInfo.rows[0]?.started_at || new Date().toISOString(),
            endedAt: new Date().toISOString(),
            tracks: allTracks.rows.map(t => ({
              participantIdentity: t.participant_identity,
              participantName: t.participant_name,
              videoUrl: t.storage_url,
              duration: t.duration_seconds,
              hasScreenShare: t.has_screen_share || false,
            })),
          };

          // Derive the S3 key for the manifest (same prefix as the first track).
          // firstTrackUrl may be an absolute URL or a relative path; we need a
          // bare S3 key (no scheme/host) for PutObjectCommand.
          const firstTrackUrl = allTracks.rows[0]?.storage_url || null;
          let manifestKey;
          if (firstTrackUrl) {
            let trackPath;
            try {
              // Absolute URL — extract the pathname and strip the leading '/'.
              trackPath = new URL(firstTrackUrl).pathname.slice(1);
            } catch {
              // Relative path already — just trim leading slashes.
              trackPath = firstTrackUrl.replace(/^\/+/, '');
            }
            // Replace the final filename segment with manifest.json.
            manifestKey = trackPath.replace(/\/[^/]+$/, '/manifest.json');
          } else {
            manifestKey = `recordings/${sessionId}/manifest.json`;
          }

          // Upload the manifest JSON to S3 before finalizing the session.
          // Failure here is surfaced as an exception so the outer try/catch marks
          // the session as failed rather than writing a dangling manifest_url.
          await s3Client.send(new PutObjectCommand({
            Bucket: S3_RECORDINGS_BUCKET,
            Key: manifestKey,
            Body: JSON.stringify(manifest, null, 2),
            ContentType: 'application/json',
          }));
          console.log(`[audit] Manifest uploaded: key=${manifestKey} sessionId=${sessionId}`);

          // Build the canonical S3 URL stored in manifest_url.
          const manifestUrl = `https://${S3_RECORDINGS_BUCKET}.s3.${AWS_REGION}.amazonaws.com/${manifestKey}`;

          // Finalize the parent session
          const sessionResult2 = await db.query(
            `UPDATE recording_sessions
             SET status = 'completed', ended_at = NOW(),
                 duration_seconds = $1, manifest_url = $2
             WHERE id = $3
             RETURNING user_id`,
            [maxDuration, manifestUrl, sessionId]
          );

          // Update metering
          if (sessionResult2.rows.length > 0 && maxDuration > 0) {
            const { user_id: userId } = sessionResult2.rows[0];
            await db.query(
              `UPDATE users SET recording_minutes_used = recording_minutes_used + $1 WHERE id = $2`,
              [Math.ceil(maxDuration / 60), userId]
            );
          }

          console.log(`[egress-webhook] Multi-track recording completed: session=${sessionId} tracks=${allTracks.rows.length} duration=${maxDuration}s`);
          console.log(`[egress-webhook] Manifest: ${JSON.stringify(manifest)}`);
        }
      } else {
        // Single egress (cloud_composed) — update session directly
        const sessionResult = await db.query(
          `UPDATE recording_sessions
           SET status = 'completed', ended_at = NOW(),
               duration_seconds = $1, storage_url = $2, file_size_bytes = $3
           WHERE egress_id = $4
           RETURNING user_id`,
          [durationSeconds, storageUrl, fileSizeBytes, egressId]
        );

        // Update metering on the user
        if (sessionResult.rows.length > 0 && durationSeconds !== null && durationSeconds > 0) {
          const { user_id: userId } = sessionResult.rows[0];
          await db.query(
            `UPDATE users SET recording_minutes_used = recording_minutes_used + $1 WHERE id = $2`,
            [Math.ceil(durationSeconds / 60), userId]
          );
        }

        console.log(`[egress-webhook] Recording completed: egress=${egressId} duration=${durationSeconds}s url=${storageUrl}`);
      }

    } else if (status === 'EGRESS_FAILED' || status === 4) {
      // Recording failed
      const egressError = egressInfo.error || egressInfo.error_message || 'Unknown error';
      // Check if this is a multi-track participant egress
      const failedTrack = await db.query(
        `UPDATE recording_tracks SET status = 'failed' WHERE egress_id = $1 RETURNING session_id`,
        [egressId]
      );
      // Also try the main session
      await db.query(
        `UPDATE recording_sessions SET status = 'failed', ended_at = NOW() WHERE egress_id = $1`,
        [egressId]
      );
      console.error(`[egress-webhook] Recording failed: egress=${egressId} error=${egressError}`);
    }

    // ACK only after all processing succeeds — LiveKit will retry on non-2xx.
    res.status(200).json({ received: true });
  } catch (err) {
    console.error(`[error] Webhook processing failed for egress=${egressId}:`, err.message);
    console.error(err.stack);
    // Return 5xx so LiveKit retries the delivery on transient failures
    // (DB unavailable, S3 upload error, etc.).
    res.status(500).json({ error: 'processing_failed' });
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
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// File Sharing — Chat file upload / download / cleanup
//
// Security properties:
//   - Files stored under OS temp dir with UUID filename (no path traversal)
//   - Original filename stored in Redis metadata only; never used as disk path
//   - MIME type validated server-side via file-type (magic bytes), not client header
//   - Caller must be an active room participant (Redis set membership check)
//   - 10 MB per-file cap enforced by multer before data reaches disk
//   - 200 MB per-room cumulative cap enforced before accepting each upload
//   - Files served through authenticated Express route — no static folder exposure
//   - Files deleted on room end and by a 24-hour cron-style TTL fallback
//   - Allowed types: images and documents (executables explicitly rejected)
// ---------------------------------------------------------------------------

const CHAT_FILE_MAX_BYTES       = 10 * 1024 * 1024;   // 10 MB per file
const CHAT_ROOM_MAX_TOTAL_BYTES = 200 * 1024 * 1024;  // 200 MB per room

// Disk path where uploaded files are stored temporarily
const CHAT_UPLOAD_DIR = path.join(os.tmpdir(), 'inter-chat-uploads');
fs.mkdirSync(CHAT_UPLOAD_DIR, { recursive: true });

// Allowed MIME prefixes (validated against magic-byte detection, not the client header)
const ALLOWED_MIME_PREFIXES = [
  'image/',
  'application/pdf',
  'text/',
  'application/vnd.',                     // MS Office + OpenDocument formats
  'application/msword',
  'application/vnd.ms-excel',
  'application/vnd.ms-powerpoint',
  'application/rtf',
  'application/zip',                      // .zip archives (often docx/xlsx containers)
  'application/x-zip-compressed',
];

// MIME types that are explicitly blocked regardless of prefix match
const BLOCKED_MIME_EXACT = new Set([
  'application/x-msdownload',
  'application/x-dosexec',
  'application/x-executable',
  'application/x-mach-binary',
  'application/x-sh',
  'application/x-shellscript',
  'application/x-httpd-php',
  'application/javascript',
  'application/x-javascript',
  'application/x-perl',
  'application/x-python-code',
]);

function isMimeAllowed(mime) {
  if (!mime) return false;
  const lower = mime.toLowerCase();
  if (BLOCKED_MIME_EXACT.has(lower)) return false;
  return ALLOWED_MIME_PREFIXES.some(prefix => lower.startsWith(prefix));
}

// Multer: store with UUID filename (original name never touches the filesystem)
const chatFileStorage = multer.diskStorage({
  destination: (_req, _file, cb) => cb(null, CHAT_UPLOAD_DIR),
  filename:    (_req, _file, cb) => cb(null, crypto.randomUUID()),
});

const chatUpload = multer({
  storage: chatFileStorage,
  limits: { fileSize: CHAT_FILE_MAX_BYTES, files: 1 },
});

// ---------------------------------------------------------------------------
// POST /room/:code/file/upload
// Body: multipart/form-data with field "file" + text fields "identity", "leaveToken"
// We reuse the leaveToken as the per-participant auth credential (already issued at join/create).
// ---------------------------------------------------------------------------
app.post('/room/:code/file/upload', chatUpload.single('file'), async (req, res) => {
  const { code } = req.params;
  const { identity, leaveToken } = req.body;

  // Clean up the temp file on any early return
  const tempPath = req.file ? req.file.path : null;
  const cleanup = () => { if (tempPath) fs.unlink(tempPath, () => {}); };

  if (!code || !identity || !leaveToken) {
    cleanup();
    return res.status(400).json({ error: 'roomCode, identity and leaveToken are required' });
  }
  if (!req.file) {
    return res.status(400).json({ error: 'No file attached' });
  }

  // Validate caller is a participant and the leaveToken is current
  const storedLeaveToken = await redis.get(roomLeaveTokenKey(code, identity)).catch(() => null);
  if (!storedLeaveToken || storedLeaveToken !== leaveToken) {
    cleanup();
    return res.status(403).json({ error: 'Unauthorized' });
  }

  // Validate MIME type via file-type (magic-byte check, not client-supplied header)
  let detectedMime = null;
  try {
    const result = await FileType.fromFile(tempPath);
    // FileType.fromFile returns undefined for plain text — fall back to text/plain
    detectedMime = result ? result.mime : 'text/plain';
  } catch (_) {
    cleanup();
    return res.status(500).json({ error: 'Could not determine file type' });
  }

  if (!isMimeAllowed(detectedMime)) {
    cleanup();
    return res.status(415).json({ error: 'File type not allowed' });
  }

  // Enforce per-room cumulative size cap — atomically INCRBY then check.
  // The Lua script increments the counter and (on first write) sets the expiry
  // in a single round-trip so concurrent uploads cannot both slip past the limit.
  // If the new total exceeds the cap, roll back with DECRBY and reject.
  const sizeCapLua = `
    local newTotal = redis.call('INCRBY', KEYS[1], ARGV[1])
    if newTotal == tonumber(ARGV[1]) then
      redis.call('EXPIRE', KEYS[1], ARGV[2])
    end
    return newTotal
  `;
  const newRoomTotal = await redis.eval(
    sizeCapLua, 1,
    roomFilesTotalSizeKey(code),
    req.file.size,
    ROOM_CODE_EXPIRY_SECONDS
  );
  if (newRoomTotal > CHAT_ROOM_MAX_TOTAL_BYTES) {
    await redis.decrby(roomFilesTotalSizeKey(code), req.file.size);
    cleanup();
    return res.status(413).json({ error: 'Room file storage limit reached (200 MB)' });
  }

  // Sanitise the original filename: strip directory components, limit length
  const rawName    = req.file.originalname || 'file';
  const safeName   = path.basename(rawName).replace(/[^\w.\-]/g, '_').slice(0, 200);
  const fileId     = path.basename(tempPath); // the UUID we used as the disk filename

  const metadata = {
    fileId,
    originalName: safeName,
    mimeType:     detectedMime,
    sizeBytes:    req.file.size,
    uploaderIdentity: identity,
    roomCode:     code,
    uploadedAt:   Date.now(),
    diskPath:     tempPath,  // absolute path; stored server-side, never sent to clients
  };

  // Store metadata in Redis alongside the room (same 24-hour TTL)
  await redis.hset(roomFilesKey(code), fileId, JSON.stringify(metadata));
  await redis.expire(roomFilesKey(code), ROOM_CODE_EXPIRY_SECONDS);

  console.log(`[file-share] uploaded fileId=${fileId} room=${code} size=${req.file.size} mime=${detectedMime}`);

  // Return only the fileId and safe metadata — never the disk path
  return res.json({
    fileId,
    originalName: safeName,
    mimeType:     detectedMime,
    sizeBytes:    req.file.size,
  });
});

// ---------------------------------------------------------------------------
// GET /room/:code/file/:fileId
// Query params: identity
// Headers: Leave-Token
// Serves the file as an attachment with the original filename in Content-Disposition.
// ---------------------------------------------------------------------------
app.get('/room/:code/file/:fileId', async (req, res) => {
  const { code, fileId } = req.params;
  const { identity } = req.query;
  const leaveToken = req.headers['leave-token'];

  if (!identity || !leaveToken) {
    return res.status(400).json({ error: 'identity and Leave-Token header are required' });
  }

  // Validate caller auth
  const storedLeaveToken = await redis.get(roomLeaveTokenKey(code, identity)).catch(() => null);
  if (!storedLeaveToken || storedLeaveToken !== leaveToken) {
    return res.status(403).json({ error: 'Unauthorized' });
  }

  // Look up file metadata
  const metaRaw = await redis.hget(roomFilesKey(code), fileId).catch(() => null);
  if (!metaRaw) {
    return res.status(404).json({ error: 'File not found' });
  }

  let meta;
  try { meta = JSON.parse(metaRaw); } catch (_) {
    return res.status(500).json({ error: 'Corrupt file metadata' });
  }

  // Guard against path traversal: ensure the resolved disk path stays inside CHAT_UPLOAD_DIR
  const resolvedPath = path.resolve(meta.diskPath);
  if (!resolvedPath.startsWith(path.resolve(CHAT_UPLOAD_DIR) + path.sep)) {
    console.error(`[file-share] path traversal attempt: ${meta.diskPath}`);
    return res.status(403).json({ error: 'Forbidden' });
  }

  if (!fs.existsSync(resolvedPath)) {
    return res.status(404).json({ error: 'File no longer available' });
  }

  res.setHeader('Content-Type', meta.mimeType);
  res.setHeader('Content-Disposition', `attachment; filename="${meta.originalName}"`);
  res.setHeader('Content-Length', meta.sizeBytes);
  res.sendFile(resolvedPath);
});

// ---------------------------------------------------------------------------
// Helper: delete all uploaded files for a room (called on room end + TTL fallback)
// ---------------------------------------------------------------------------
async function deleteRoomFiles(code) {
  try {
    const allMeta = await redis.hgetall(roomFilesKey(code));
    if (!allMeta) return;
    for (const [, raw] of Object.entries(allMeta)) {
      try {
        const meta = JSON.parse(raw);
        const resolvedPath = path.resolve(meta.diskPath);
        if (resolvedPath.startsWith(path.resolve(CHAT_UPLOAD_DIR) + path.sep)) {
          fs.unlink(resolvedPath, () => {});
        }
      } catch (_) { /* ignore corrupt entries */ }
    }
    await redis.del(roomFilesKey(code));
    await redis.del(roomFilesTotalSizeKey(code));
    console.log(`[file-share] cleaned up files for room=${code}`);
  } catch (err) {
    console.error(`[file-share] cleanup failed for room=${code}: ${err.message}`);
  }
}

// ---------------------------------------------------------------------------
// TTL fallback: scan for orphaned temp files older than 25 hours every hour.
// Handles crash-recovery cases where deleteRoomFiles was never called.
// ---------------------------------------------------------------------------
const CHAT_FILE_MAX_AGE_MS = 25 * 60 * 60 * 1000;
setInterval(() => {
  try {
    const files = fs.readdirSync(CHAT_UPLOAD_DIR);
    const now   = Date.now();
    for (const name of files) {
      const filePath = path.join(CHAT_UPLOAD_DIR, name);
      try {
        const stat = fs.statSync(filePath);
        if (now - stat.mtimeMs > CHAT_FILE_MAX_AGE_MS) {
          fs.unlink(filePath, () => {});
        }
      } catch (_) { /* file already gone */ }
    }
  } catch (err) {
    console.error(`[file-share] TTL scan error: ${err.message}`);
  }
}, 60 * 60 * 1000); // every hour

// Global error handler — MUST be the last app.use() before app.listen
// Catches any error thrown from route handlers (throw err pattern above).
// Returns a safe, opaque message — never leaks DB errors, stack traces, or paths.
// ---------------------------------------------------------------------------
app.use((err, req, res, _next) => {
  const requestId = require('crypto').randomUUID();
  console.error(`[error] requestId=${requestId} path=${req.path} err=${err.message}`);
  res.status(500).json({
    error: 'An internal error occurred',
    requestId, // returned for support lookup — never the stack trace
  });
});

app.listen(PORT, () => {
  console.log(`[token-server] Running on http://localhost:${PORT}`);
  // NOTE: API key intentionally NOT logged — would persist in log aggregators
  console.log(`[token-server] Redis: ${process.env.REDIS_URL || 'redis://localhost:6379'}`);
  console.log(`[token-server] Endpoints: POST /room/create, /room/join, /token/refresh, /auth/register, /auth/login | GET /room/info/:code, /auth/me, /health`);
});
