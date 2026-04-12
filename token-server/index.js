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
const redis = require('./redis');
const db = require('./db');
const auth = require('./auth');

const app = express();

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
// POST /auth/register
// Body: { email, password, displayName }
// Returns: { user, accessToken, refreshToken, expiresIn }
// ---------------------------------------------------------------------------
app.post('/auth/register', rateLimitAuth, async (req, res) => {
  const { email, password, displayName } = req.body;

  try {
    const result = await auth.register(email, password, displayName);
    console.log(`[audit] User registered: ${result.user.email} (${result.user.id})`);
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
    console.log(`[audit] User logged in: ${result.user.email}`);
    res.json(result);
  } catch (err) {
    const status = err.message.includes('Invalid') ? 401
                 : err.message.includes('required') ? 400
                 : 500;
    if (status === 500) throw err;
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
      `SELECT id, user_id, family_id, client_id, expires_at, revoked_at
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
      console.error(`[SECURITY] Refresh token reuse detected. family=${stored.family_id} userId=${stored.user_id}`);
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

    // ── DEVICE BINDING (soft) ────────────────────────────────────────
    if (stored.client_id && clientId && stored.client_id !== clientId) {
      console.warn(`[SECURITY] Client ID mismatch on refresh. stored=${stored.client_id} got=${clientId} userId=${stored.user_id}`);
    }

    // ── ROTATION ─────────────────────────────────────────────────────
    // Revoke old token, issue new one in same family — atomic transaction
    await dbClient.query(
      `UPDATE refresh_tokens SET revoked_at = NOW() WHERE id = $1`,
      [stored.id]
    );

    const newRaw = crypto.randomBytes(32);
    const { clientToken: newClientToken, tokenHash: newHash } = auth.signRefreshToken(newRaw);

    await dbClient.query(
      `INSERT INTO refresh_tokens
         (user_id, token_hash, family_id, client_id, expires_at, predecessor_id)
       VALUES ($1, $2, $3, $4, NOW() + make_interval(days => $5), $6)`,
      [stored.user_id, newHash, stored.family_id, clientId || stored.client_id, auth.REFRESH_TOKEN_DAYS, stored.id]
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

  res.status(204).end();
});

// ---------------------------------------------------------------------------
// POST /auth/logout-all — revoke all refresh tokens for the current user
// Returns: 204 No Content
// ---------------------------------------------------------------------------
app.post('/auth/logout-all', auth.requireAuth, async (req, res) => {
  await auth.revokeAllForUser(req.user.userId);
  res.status(204).end();
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
const { createCheckout, getCustomer, lemonSqueezySetup } = require('@lemonsqueezy/lemonsqueezy.js');
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
// CSP: script-src 'none' — zero client-side JavaScript.
app.get('/billing/plans', async (req, res) => {
  const token = req.query.t;
  if (!token || typeof token !== 'string') {
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    return res.status(400).send(renderErrorPage('Missing or invalid page token. Please reopen Inter and try again.'));
  }

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
function roomLobbyKey(code) { return `room:${code}:lobby`; }
function roomLobbyNamesKey(code) { return `room:${code}:lobby:names`; }
function roomSuspendedKey(code) { return `room:${code}:suspended`; }

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
  await redis.zrem(roomLobbyKey(code), targetIdentity);
  await redis.hdel(roomLobbyNamesKey(code), targetIdentity);

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

  const admittedCount = await admitAllFromLobby(code, roomData);

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
  await redis.zrem(roomLobbyKey(code), targetIdentity);
  await redis.hdel(roomLobbyNamesKey(code), targetIdentity);

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
    // Not an egress event — could be a room or participant event
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
