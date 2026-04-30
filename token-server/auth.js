// ============================================================================
// Authentication Module — Inter Token Server
// Phase 6.3 [G6.3.2]
//
// Provides:
//   register(email, password, displayName)  — create user, return JWT
//   login(email, password)                  — verify credentials, return JWT
//   authenticateToken                       — Express middleware (optional)
//   requireTier(tier)                       — Express middleware (tier gating)
//
// Design:
//   - User auth JWTs are separate from LiveKit room JWTs
//   - Auth is ADDITIVE — anonymous users still work (middleware is optional)
//   - Password hashing uses bcryptjs (12 rounds)
//   - JWTs expire in 7 days (configurable)
// ============================================================================

const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const crypto = require('crypto');
const https = require('https');
const db = require('./db');

// ---------------------------------------------------------------------------
// Secret validation — crash at startup rather than run with a weak secret.
// Generate a suitable secret:
//   node -e "console.log(require('crypto').randomBytes(32).toString('base64url'))"
// ---------------------------------------------------------------------------
const JWT_SECRET = process.env.JWT_SECRET;
if (!JWT_SECRET || Buffer.from(JWT_SECRET, 'utf8').length < 32) {
  console.error('[FATAL] JWT_SECRET must be set and at least 32 bytes. Server will not start.');
  console.error('[FATAL] Generate one with: node -e "console.log(require(\'crypto\').randomBytes(32).toString(\'base64url\'))"');
  process.exit(1);
}

const REFRESH_TOKEN_SECRET = process.env.REFRESH_TOKEN_SECRET;
if (!REFRESH_TOKEN_SECRET || Buffer.from(REFRESH_TOKEN_SECRET, 'utf8').length < 32) {
  console.error('[FATAL] REFRESH_TOKEN_SECRET must be set and at least 32 bytes.');
  console.error('[FATAL] Generate one with: node -e "console.log(require(\'crypto\').randomBytes(32).toString(\'base64url\'))"');
  process.exit(1);
}

const ACCESS_TOKEN_TTL   = process.env.ACCESS_TOKEN_TTL || '15m';
const REFRESH_TOKEN_DAYS = parseInt(process.env.REFRESH_TOKEN_TTL_DAYS || '30', 10);
const ABSOLUTE_SESSION_TTL_DAYS = parseInt(process.env.ABSOLUTE_SESSION_TTL_DAYS || '30', 10);
const BCRYPT_ROUNDS = 12;

// ---------------------------------------------------------------------------
// Concurrent session limits per tier.
// When a new login exceeds the limit, the oldest sessions are revoked.
// ---------------------------------------------------------------------------
const MAX_SESSIONS_BY_TIER = {
  free:   2,
  pro:    3,
  'pro+': 3,
  hiring: 3,
};

// ---------------------------------------------------------------------------
// Timing normalization — pre-computed dummy hash used to equalize response
// times on early-exit paths (email-not-found in login, email-taken in register).
// Without this, an attacker can enumerate valid emails by timing alone.
// Computed synchronously at module load so it is guaranteed to exist before
// any request handler runs. hashSync blocks for ~300 ms once — acceptable at
// startup, unacceptable in a request path.
// ---------------------------------------------------------------------------
const DUMMY_HASH = bcrypt.hashSync('inter-dummy-constant-do-not-change', BCRYPT_ROUNDS);

// ---------------------------------------------------------------------------
// isPwnedPassword(password) → boolean
//
// Checks against the HaveIBeenPwned breach corpus using k-anonymity.
// Only the first 5 hex chars of the SHA-1 hash leave the server.
// NIST SP 800-63B §5.1.1.2 — REQUIRED before accepting a password.
// Throws on network error — caller decides whether to block or warn.
// ---------------------------------------------------------------------------
async function isPwnedPassword(password) {
  const sha1   = crypto.createHash('sha1').update(password).digest('hex').toUpperCase();
  const prefix = sha1.slice(0, 5);
  const suffix = sha1.slice(5);

  return new Promise((resolve, reject) => {
    const req = https.get(
      `https://api.pwnedpasswords.com/range/${prefix}`,
      { headers: { 'Add-Padding': 'true' } },
      (res) => {
        let data = '';
        res.on('data', chunk => { data += chunk; });
        res.on('end', () => {
          if (res.statusCode !== 200) {
            return reject(new Error(`HIBP API returned status ${res.statusCode}: ${data.slice(0, 200)}`));
          }
          const found = data.split('\r\n').some(line => {
            const [hashSuffix] = line.split(':');
            return hashSuffix === suffix;
          });
          resolve(found);
        });
      }
    );
    req.on('error', reject);
    req.setTimeout(3000, () => { req.destroy(); reject(new Error('HIBP timeout')); });
  });
}

// ---------------------------------------------------------------------------
// checkPwnedPassword(password) — soft-fail wrapper around isPwnedPassword.
// Logs warnings on network failure but never crashes the caller.
// ---------------------------------------------------------------------------
async function checkPwnedPassword(password) {
  try {
    const pwned = await isPwnedPassword(password);
    if (pwned) {
      throw Object.assign(
        new Error('This password has appeared in a data breach. Please choose a different password.'),
        { status: 400, code: 'PASSWORD_PWNED' }
      );
    }
  } catch (err) {
    if (err.code === 'PASSWORD_PWNED') throw err;
    // Network error — log and allow (don't block registration on HIBP outage)
    console.warn('[auth] HIBP check failed:', err.message);
  }
}

// ---------------------------------------------------------------------------
// Parse TTL string (e.g. '15m', '1h', '7d') to seconds for client-side scheduling.
// ---------------------------------------------------------------------------
function parseTTLtoSeconds(ttl) {
  const match = String(ttl).match(/^(\d+)(s|m|h|d)?$/);
  if (!match) return 900; // fallback: 15 min
  const n = parseInt(match[1], 10);
  const unit = match[2] || 's';
  return { s: n, m: n * 60, h: n * 3600, d: n * 86400 }[unit];
}

// ---------------------------------------------------------------------------
// Generate a short-lived access token (JWT, 15 min default).
// Contains userId, email, displayName, tier, and the refresh token family ID.
// The family ID (fam) links this access token to its refresh token session.
// ---------------------------------------------------------------------------
function generateAccessToken(user, familyId) {
  return jwt.sign(
    {
      userId:      user.id,
      email:       user.email,
      displayName: user.display_name,
      tier:        user.tier,
      fam:         familyId,
    },
    JWT_SECRET,
    {
      algorithm:  'HS256',
      expiresIn:  ACCESS_TOKEN_TTL,
      issuer:     'inter-token-server',
      audience:   'inter-macos-client',
    }
  );
}

// ---------------------------------------------------------------------------
// signRefreshToken(rawBytes) → { clientToken, tokenHash }
//
// Given 32 random bytes, produces:
//   clientToken — base64url(raw || HMAC-SHA256(REFRESH_TOKEN_SECRET, raw))
//   tokenHash   — SHA-256(clientToken bytes) stored in DB for lookup
//
// Defense-in-depth: an attacker who can INSERT rows into refresh_tokens
// (e.g. via SQL injection) still cannot forge a valid client token without
// knowing REFRESH_TOKEN_SECRET. Plain SHA-256 storage alone would allow
// a DB-write attacker to plant an arbitrary hash they already know.
// ---------------------------------------------------------------------------
function signRefreshToken(rawBytes) {
  const sig     = crypto.createHmac('sha256', REFRESH_TOKEN_SECRET).update(rawBytes).digest();
  const payload = Buffer.concat([rawBytes, sig]);          // 64 bytes total
  return {
    clientToken: payload.toString('base64url'),
    tokenHash:   crypto.createHash('sha256').update(payload).digest(),
  };
}

// ---------------------------------------------------------------------------
// verifyRefreshToken(clientToken) → tokenHash (Buffer)
//
// Decodes the base64url token, recomputes HMAC, and validates with a
// constant-time comparison. Returns the SHA-256(payload) hash for DB lookup.
// Throws an error with { code: 'TOKEN_INVALID' } on any failure so callers
// can forward a consistent error response.
// ---------------------------------------------------------------------------
function verifyRefreshToken(clientToken) {
  let payload;
  try {
    payload = Buffer.from(String(clientToken), 'base64url');
  } catch {
    const err = new Error('Invalid refresh token'); err.code = 'TOKEN_INVALID'; throw err;
  }
  if (payload.length !== 64) {
    const err = new Error('Invalid refresh token'); err.code = 'TOKEN_INVALID'; throw err;
  }
  const raw         = payload.subarray(0, 32);
  const sig         = payload.subarray(32);
  const expectedSig = crypto.createHmac('sha256', REFRESH_TOKEN_SECRET).update(raw).digest();
  if (!crypto.timingSafeEqual(sig, expectedSig)) {
    const err = new Error('Invalid refresh token'); err.code = 'TOKEN_INVALID'; throw err;
  }
  return crypto.createHash('sha256').update(payload).digest();
}

// ---------------------------------------------------------------------------
// Issue a new refresh token for a login session.
// Creates a new token family (UUID) — each login gets its own family.
// The signed client token is returned to the caller. Only the SHA-256
// hash of the full signed payload is stored in the DB.
//
// dbClient: a pg client from db.getClient() — caller manages the transaction.
// Returns: { rawToken (base64url signed string), familyId (UUID) }
// ---------------------------------------------------------------------------
async function issueRefreshToken(userId, clientId, dbClient) {
  const rawBytes  = crypto.randomBytes(32);
  const { clientToken, tokenHash } = signRefreshToken(rawBytes);
  const familyId  = crypto.randomUUID();

  await dbClient.query(
    `INSERT INTO refresh_tokens (user_id, token_hash, family_id, client_id, expires_at, absolute_expires_at)
     VALUES ($1, $2, $3, $4, NOW() + make_interval(days => $5), NOW() + make_interval(days => $6))`,
    [userId, tokenHash, familyId, clientId || null, REFRESH_TOKEN_DAYS, ABSOLUTE_SESSION_TTL_DAYS]
  );

  return { rawToken: clientToken, familyId };
}

// ---------------------------------------------------------------------------
// enforceSessionLimit(userId, tier, currentFamilyId, dbClient)
//
// Ensures the user does not exceed MAX_SESSIONS_BY_TIER concurrent sessions.
// Revokes the oldest sessions (by issued_at) that exceed the cap, skipping
// the just-created session (currentFamilyId). Must be called within the same
// transaction that issued the new token.
// ---------------------------------------------------------------------------
async function enforceSessionLimit(userId, tier, currentFamilyId, dbClient) {
  const maxSessions = MAX_SESSIONS_BY_TIER[tier] || MAX_SESSIONS_BY_TIER.free;

  // Lock all active session rows for this user before counting/evicting.
  // Because all callers invoke this inside an open transaction, the FOR UPDATE
  // row locks are held until that transaction commits. A concurrent login that
  // reaches this point will block until the first transaction commits, then
  // re-acquire the locks and see the first transaction's evictions — serializing
  // the count-and-evict pair and preventing session-limit bypass.
  // NOTE: FOR UPDATE cannot be combined with COUNT(DISTINCT) in PostgreSQL, so
  // the distinct family count is derived from the locked rows in JS instead.
  const { rows: activeRows } = await dbClient.query(
    `SELECT family_id
     FROM refresh_tokens
     WHERE user_id = $1 AND revoked_at IS NULL AND expires_at > NOW()
     FOR UPDATE`,
    [userId]
  );

  const activeCount = new Set(activeRows.map(r => r.family_id)).size;
  if (activeCount <= maxSessions) return 0;

  const excess = activeCount - maxSessions;

  // Find the oldest sessions to evict (by earliest issued_at within each family),
  // excluding the session we just created.
  const { rows: toEvict } = await dbClient.query(
    `SELECT family_id
     FROM refresh_tokens
     WHERE user_id = $1 AND revoked_at IS NULL AND expires_at > NOW()
       AND family_id != $2
     GROUP BY family_id
     ORDER BY MIN(issued_at) ASC
     LIMIT $3`,
    [userId, currentFamilyId, excess]
  );

  if (toEvict.length > 0) {
    const familyIds = toEvict.map(r => r.family_id);
    await dbClient.query(
      `UPDATE refresh_tokens SET revoked_at = NOW()
       WHERE user_id = $1 AND family_id = ANY($2) AND revoked_at IS NULL`,
      [userId, familyIds]
    );
    console.log(`[session-limit] Evicted ${familyIds.length} oldest session(s) for user=${userId} tier=${tier} max=${maxSessions}`);
  }

  return toEvict.length;
}

// ---------------------------------------------------------------------------
// Revoke all active refresh tokens for a user (logout-all-devices).
// ---------------------------------------------------------------------------
async function revokeAllForUser(userId) {
  await db.query(
    `UPDATE refresh_tokens SET revoked_at = NOW()
     WHERE user_id = $1 AND revoked_at IS NULL`,
    [userId]
  );
}

// ---------------------------------------------------------------------------
// Register — create new user account
// Returns: { user, accessToken, refreshToken, expiresIn }
// Throws: if email already exists or validation fails
// ---------------------------------------------------------------------------
async function register(email, password, displayName) {
  // Validate presence
  if (!email || !password || !displayName) {
    throw new Error('email, password, and displayName are required');
  }

  // Email: RFC 5321 format + length cap (local ≤63, total ≤254)
  const emailStr = String(email).toLowerCase().trim();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(emailStr) || emailStr.length > 254) {
    throw new Error('Invalid email address');
  }

  // Password: NIST minimum 8 chars, bcrypt hard cap 72 bytes
  const passwordBytes = Buffer.byteLength(String(password), 'utf8');
  if (passwordBytes < 8) {
    throw new Error('Password must be at least 8 characters');
  }
  if (passwordBytes > 72) {
    throw new Error('Password must be 72 characters or fewer');
  }

  // Display name: trim and cap at 100 chars
  const nameStr = String(displayName).trim();
  if (nameStr.length < 1 || nameStr.length > 100) {
    throw new Error('Display name must be between 1 and 100 characters');
  }

  const emailNormalized = emailStr;

  // NIST SP 800-63B §5.1.1.2 — check against breach corpus
  await checkPwnedPassword(password);

  // Check if email already exists
  const existing = await db.query('SELECT id FROM users WHERE email = $1', [emailNormalized]);
  if (existing.rows.length > 0) {
    // Normalize timing — compare against precomputed DUMMY_HASH (same CPU cost as
    // bcrypt.compare in login()) instead of computing a fresh hash on every duplicate.
    await bcrypt.compare('inter-dummy-constant-do-not-change', DUMMY_HASH);
    const err = new Error('Email already registered');
    err.status = 409;
    throw err;
  }

  // Hash password (outside transaction — CPU-bound, no DB needed)
  const passwordHash = await bcrypt.hash(password, BCRYPT_ROUNDS);

  // Transaction: insert user + issue refresh token atomically
  const dbClient = await db.getClient();
  try {
    await dbClient.query('BEGIN');

    const result = await dbClient.query(
      `INSERT INTO users (email, display_name, password_hash)
       VALUES ($1, $2, $3)
       RETURNING id, email, display_name, tier, created_at`,
      [emailNormalized, nameStr, passwordHash]
    );

    const user = result.rows[0];
    const { rawToken, familyId } = await issueRefreshToken(user.id, null, dbClient);

    // Enforce concurrent session cap (new user is always 'free')
    await enforceSessionLimit(user.id, user.tier || 'free', familyId, dbClient);

    await dbClient.query('COMMIT');

    const accessToken = generateAccessToken(user, familyId);

    return {
      user: {
        id: user.id,
        email: user.email,
        displayName: user.display_name,
        tier: user.tier,
        createdAt: user.created_at,
      },
      accessToken,
      refreshToken: rawToken,
      expiresIn: parseTTLtoSeconds(ACCESS_TOKEN_TTL),
    };
  } catch (err) {
    await dbClient.query('ROLLBACK');
    throw err;
  } finally {
    dbClient.release();
  }
}

// ---------------------------------------------------------------------------
// Login — verify credentials and return tokens
// Returns: { user, accessToken, refreshToken, expiresIn }
// Throws: if credentials are invalid
// ---------------------------------------------------------------------------
async function login(email, password) {
  if (!email || !password) {
    throw new Error('email and password are required');
  }

  // Reject passwords exceeding bcrypt's 72-byte input limit early
  const passwordBytes = Buffer.byteLength(String(password), 'utf8');
  if (passwordBytes > 72) {
    await bcrypt.compare(password, DUMMY_HASH); // normalize timing
    throw new Error('Invalid email or password');
  }

  const emailNormalized = email.toLowerCase().trim();

  const result = await db.query(
    'SELECT id, email, display_name, password_hash, tier, created_at FROM users WHERE email = $1',
    [emailNormalized]
  );

  if (result.rows.length === 0) {
    // Normalize timing — pay bcrypt cost even when user doesn't exist
    await bcrypt.compare(password, DUMMY_HASH);
    throw new Error('Invalid email or password');
  }

  const user = result.rows[0];
  const isValid = await bcrypt.compare(password, user.password_hash);

  if (!isValid) {
    throw new Error('Invalid email or password');
  }

  // Issue refresh token inside a transaction
  const dbClient = await db.getClient();
  try {
    await dbClient.query('BEGIN');
    const { rawToken, familyId } = await issueRefreshToken(user.id, null, dbClient);

    // Enforce concurrent session cap based on user's tier
    await enforceSessionLimit(user.id, user.tier || 'free', familyId, dbClient);

    await dbClient.query('COMMIT');

    const accessToken = generateAccessToken(user, familyId);

    return {
      user: {
        id: user.id,
        email: user.email,
        displayName: user.display_name,
        tier: user.tier,
        createdAt: user.created_at,
      },
      accessToken,
      refreshToken: rawToken,
      expiresIn: parseTTLtoSeconds(ACCESS_TOKEN_TTL),
    };
  } catch (err) {
    await dbClient.query('ROLLBACK');
    throw err;
  } finally {
    dbClient.release();
  }
}

// ---------------------------------------------------------------------------
// Middleware: authenticateToken (OPTIONAL)
//
// Checks for Authorization: Bearer <token> header.
// If present and valid → attaches req.user = { userId, email, displayName, tier, tokenFamily }
// If absent → req.user = null (anonymous — continues without error)
// If present but invalid → 401 (TOKEN_INVALID or TOKEN_EXPIRED)
// ---------------------------------------------------------------------------
function authenticateToken(req, res, next) {
  const authHeader = req.headers['authorization'];

  if (!authHeader) {
    // No auth header — anonymous user, continue
    req.user = null;
    return next();
  }

  const token = authHeader.startsWith('Bearer ')
    ? authHeader.slice(7)
    : authHeader;

  try {
    const decoded = jwt.verify(token, JWT_SECRET, {
      algorithms: ['HS256'],
      issuer:     'inter-token-server',
      audience:   'inter-macos-client',
    });
    req.user = {
      userId:      decoded.userId,
      email:       decoded.email,
      displayName: decoded.displayName,
      tier:        decoded.tier,
      tokenFamily: decoded.fam || null,
    };
    next();
  } catch (err) {
    if (err.name === 'TokenExpiredError') {
      // Expired — distinguish from invalid so clients can trigger silent refresh (Phase B)
      return res.status(401).json({ error: 'Access token expired', code: 'TOKEN_EXPIRED' });
    }
    // Tampered, wrong issuer, wrong audience, or structurally invalid
    return res.status(401).json({ error: 'Invalid auth token', code: 'TOKEN_INVALID' });
  }
}

// ---------------------------------------------------------------------------
// Middleware: requireAuth
//
// Must be used AFTER authenticateToken. Returns 401 if req.user is null.
// Use this for endpoints that REQUIRE authentication.
// ---------------------------------------------------------------------------
function requireAuth(req, res, next) {
  if (!req.user) {
    return res.status(401).json({ error: 'Authentication required' });
  }
  next();
}

// ---------------------------------------------------------------------------
// Middleware Factory: requireTier(minTier)
//
// Checks the user's effective tier against a tier hierarchy: free < pro < pro+ < hiring.
// Also checks subscription_status from DB (fresh read) — rejects users whose
// subscription is inactive (unpaid/expired/paused) unless in grace period.
//
// IMPORTANT: past_due is NOT in INACTIVE_STATUSES. Per LS docs, past_due means
// LS is retrying the payment (up to 4 times over 2 weeks) and the user KEEPS access.
// Only when status becomes 'unpaid' (all retries failed) should access be restricted.
//
// Trial users (on_trial) get pro-equivalent access via TRIAL_GRANTS_TIER.
// Phase C — Gap G15 (P0)
// ---------------------------------------------------------------------------
const TIER_LEVELS = { free: 0, pro: 1, 'pro+': 2, hiring: 3 };
const INACTIVE_STATUSES = new Set(['unpaid', 'expired', 'paused']);
const TRIAL_GRANTS_TIER = { on_trial: 'pro' };

function requireTier(minTier) {
  return async (req, res, next) => {
    if (!req.user) {
      return res.status(401).json({ error: 'Authentication required' });
    }

    try {
      // Fresh read from DB — JWT tier may be up to 15 min stale
      const result = await db.query(
        'SELECT tier, subscription_status, grace_until FROM users WHERE id = $1',
        [req.user.userId]
      );
      if (result.rows.length === 0) {
        return res.status(401).json({ error: 'User not found', code: 'USER_NOT_FOUND' });
      }

      const { tier, subscription_status, grace_until } = result.rows[0];

      // Check if subscription is inactive (and not in grace period)
      if (INACTIVE_STATUSES.has(subscription_status)) {
        const inGracePeriod = grace_until && new Date() < new Date(grace_until);
        if (!inGracePeriod) {
          return res.status(403).json({
            error: 'Your subscription is inactive',
            code: 'SUBSCRIPTION_INACTIVE',
            subscriptionStatus: subscription_status,
          });
        }
      }

      // Cancelled users keep access until grace_until (end of billing period)
      if (subscription_status === 'cancelled') {
        const inGracePeriod = grace_until && new Date() < new Date(grace_until);
        if (!inGracePeriod) {
          return res.status(403).json({
            error: 'Your subscription has ended',
            code: 'SUBSCRIPTION_INACTIVE',
            subscriptionStatus: subscription_status,
          });
        }
      }

      // on_trial users get pro-equivalent access
      const effectiveTier = TRIAL_GRANTS_TIER[subscription_status] ?? tier;

      const userLevel = TIER_LEVELS[effectiveTier] ?? 0;
      const requiredLevel = TIER_LEVELS[minTier] ?? 0;

      if (userLevel < requiredLevel) {
        return res.status(403).json({
          error: `This feature requires a ${minTier} plan or higher`,
          code: 'INSUFFICIENT_TIER',
          currentTier: effectiveTier,
          requiredTier: minTier,
        });
      }

      // Update req.user with fresh tier for downstream use
      req.user.tier = effectiveTier;
      req.user.subscriptionStatus = subscription_status;

      next();
    } catch (err) {
      console.error('[auth] requireTier DB error:', err.message);
      return res.status(500).json({ error: 'Internal error checking subscription' });
    }
  };
}

// ---------------------------------------------------------------------------
// resetPassword(token, newPassword) → void
//
// Core logic for both JSON and web-form password reset routes.
// Validates the token, updates the password, and revokes all refresh tokens
// in a single transaction. Throws on invalid/expired token or bad password.
// ---------------------------------------------------------------------------
async function resetPassword(token, newPassword) {
  if (!token || !newPassword) {
    throw Object.assign(new Error('token and newPassword are required'), { status: 400 });
  }

  const passwordBytes = Buffer.byteLength(String(newPassword), 'utf8');
  if (passwordBytes < 8 || passwordBytes > 72) {
    throw Object.assign(new Error('Password must be 8-72 characters'), { status: 400 });
  }

  // NIST SP 800-63B §5.1.1.2 — check against breach corpus
  await checkPwnedPassword(newPassword);

  const tokenHash = crypto.createHash('sha256')
    .update(Buffer.from(token, 'base64url'))
    .digest();

  // Compute bcrypt hash BEFORE opening the transaction — bcrypt is CPU-bound
  // (~300 ms) and would hold the DB connection/transaction lock unnecessarily.
  const newHash = await bcrypt.hash(newPassword, BCRYPT_ROUNDS);

  const dbClient = await db.getClient();
  try {
    await dbClient.query('BEGIN');

    const result = await dbClient.query(
      `SELECT id, user_id FROM password_reset_tokens
       WHERE token_hash = $1 AND used_at IS NULL AND expires_at > NOW()`,
      [tokenHash]
    );

    if (result.rows.length === 0) {
      throw Object.assign(new Error('Invalid or expired reset token'), { status: 400 });
    }

    const { id: tokenId, user_id: userId } = result.rows[0];

    await dbClient.query(
      'UPDATE password_reset_tokens SET used_at = NOW() WHERE id = $1',
      [tokenId]
    );
    await dbClient.query(
      'UPDATE users SET password_hash = $1 WHERE id = $2',
      [newHash, userId]
    );
    await dbClient.query(
      `UPDATE refresh_tokens SET revoked_at = NOW()
       WHERE user_id = $1 AND revoked_at IS NULL`,
      [userId]
    );

    await dbClient.query('COMMIT');
    return userId;
  } catch (err) {
    await dbClient.query('ROLLBACK');
    throw err;
  } finally {
    dbClient.release();
  }
}

// ---------------------------------------------------------------------------
// auditLog(userId, eventType, ipAddress, metadata) → void
//
// Writes to audit_events table. Must NEVER crash auth flows — all DB errors
// are caught and logged to console.error as a fallback.
// ---------------------------------------------------------------------------
async function auditLog(userId, eventType, ipAddress, metadata = {}) {
  try {
    await db.query(
      `INSERT INTO audit_events (user_id, event_type, ip_address, metadata)
       VALUES ($1, $2, $3::inet, $4)`,
      [userId || null, eventType, ipAddress || null, JSON.stringify(metadata)]
    );
  } catch (err) {
    console.error('[audit] log write failed:', err.message);
  }
}

module.exports = {
  register,
  login,
  authenticateToken,
  requireAuth,
  requireTier,
  generateAccessToken,
  signRefreshToken,
  verifyRefreshToken,
  issueRefreshToken,
  enforceSessionLimit,
  revokeAllForUser,
  resetPassword,
  auditLog,
  checkPwnedPassword,
  parseTTLtoSeconds,
  REFRESH_TOKEN_DAYS,
  BCRYPT_ROUNDS,
  MAX_SESSIONS_BY_TIER,
};
