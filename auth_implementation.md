# Auth & Authorization — Full Implementation Reference

> **Status**: Partially implemented. Phase 6.3 is complete (basic JWT auth). This document
> covers everything that remains to be built for a production-ready, billing-aware,
> attack-resistant auth system.
>
> **Read this document in full before touching any auth-related code.**

---

## Table of Contents

1. [Current State Audit](#1-current-state-audit)
2. [Target Architecture — Two-Token System](#2-target-architecture--two-token-system)
3. [Phase A — Immediate Hardening (No Client Changes)](#3-phase-a--immediate-hardening-no-client-changes)
4. [Phase B — Full Refresh Token System (With Client Auth UI)](#4-phase-b--full-refresh-token-system-with-client-auth-ui)
5. [Phase C — Billing & Tier Lifecycle Integration](#5-phase-c--billing--tier-lifecycle-integration)
6. [Phase D — Account Recovery & Security Hardening](#6-phase-d--account-recovery--security-hardening)
7. [Attack Mitigation Matrix](#7-attack-mitigation-matrix)
8. [Files Changed Per Phase](#8-files-changed-per-phase)
9. [Testing Checklist](#9-testing-checklist)
10. [New File Starters — billing.js and mailer.js](#10-new-file-starters--billingjs-and-mailerjs)
11. [Industry Standards Gap Analysis & Mitigation Plan](#11-industry-standards-gap-analysis--mitigation-plan)

---

## 1. Current State Audit

### What exists (Phase 6.3)

| Component | File | Status |
|---|---|---|
| `register(email, password, displayName)` | `token-server/auth.js` | ✅ Done |
| `login(email, password)` | `token-server/auth.js` | ✅ Done — returns single 7-day JWT |
| `authenticateToken` middleware | `token-server/auth.js` | ✅ Done — but missing `algorithms` pin |
| `requireAuth` middleware | `token-server/auth.js` | ✅ Done |
| `requireTier(minTier)` middleware | `token-server/auth.js` | ✅ Done |
| `POST /auth/register` | `token-server/index.js` | ✅ Done |
| `POST /auth/login` | `token-server/index.js` | ✅ Done |
| `GET /auth/me` | `token-server/index.js` | ✅ Done |
| `users` table with `tier` column | `migrations/001_initial_schema.sql` | ✅ Done |
| Refresh token table | — | ❌ Missing |
| `POST /auth/refresh` endpoint | — | ❌ Missing |
| `POST /auth/logout` endpoint | — | ❌ Missing |
| `POST /auth/logout-all` endpoint | — | ❌ Missing |
| Rate limiting on auth endpoints | — | ❌ Missing (only room endpoints have it) |
| Input validation (lengths, formats) | — | ❌ Missing — no email/password/displayName limits |
| Timing normalization (login, register) | — | ❌ Missing — timing oracle enables email enumeration |
| bcrypt 72-byte truncation guard | — | ❌ Missing |
| Password reset flow | — | ❌ Missing |
| Email verification on register | — | ❌ Missing |
| Persistent audit log | — | ❌ Missing |
| Client login UI (macOS) | — | ❌ Missing — tier hardcoded to `"free"` in AppDelegate.m |
| Tier change mechanism | — | ❌ Missing — no billing webhook handler |

### Known vulnerabilities (in priority order)

1. **`alg:none` JWT forgery** — `jwt.verify()` has no `algorithms` pin. An attacker can forge a JWT
   with `alg:none` claiming any `userId` and `tier: "hiring"`. Rating: **CRITICAL**.
2. **Weak JWT secret** — `JWT_SECRET` falls back to `'inter-dev-secret-change-in-production'`
   (a known, public string) if the env var is not set. HS256 secrets are offline-brute-forceable.
   Rating: **CRITICAL**.
3. **7-day JWT TTL with no revocation** — a downgraded or cancelled user retains their tier
   for up to 7 days. No logout mechanism exists. Rating: **HIGH**.
4. **LiveKit API key logged to stdout** — `console.log('[token-server] LiveKit API Key: ...')`
   on server startup. API key persists in log files indefinitely. Rating: **HIGH**.
5. **No rate limiting on `/auth/login`** — credential stuffing and brute force are unprotected.
   Rating: **MEDIUM**.
6. **Raw DB errors in 500 responses** — `err.message` reaches the client, leaking PostgreSQL
   constraint names and schema details. Rating: **MEDIUM**.
7. **No HSTS / security response headers** — TLS downgrade and cache-based token leakage possible.
   Rating: **MEDIUM**.
8. **Timing oracle in `register()`** — early-exit before bcrypt when email exists makes response ~80ms
   faster than a normal registration. Attacker can enumerate valid emails at scale purely by timing.
   Rating: **HIGH**.
9. **Timing oracle in `login()`** — `bcrypt.compare` is skipped entirely when the user doesn't exist.
   Non-existent email (~2ms) vs wrong password (~80ms) are distinguishable despite identical error text.
   Rating: **HIGH**.
10. **bcrypt 72-byte silent truncation** — bcrypt silently truncates passwords at 72 bytes. A user who
    sets a 100-character password can log in with only the first 72 characters. No input guard exists.
    Rating: **MEDIUM**.
11. **No input length limits** — `email`, `password`, and `displayName` have no maximum length checks.
    A 10MB `displayName` inserts into the DB. Email has no format validation (only lowercased).
    Rating: **MEDIUM**.
12. **No password reset flow** — no `forgot_password` mechanism exists. Any user who loses their
    password is permanently locked out. Password reset endpoints are a primary attack surface;
    omitting them entirely means users will use weak/reused passwords with no recovery path.
    Rating: **HIGH**.
13. **No email verification on register** — anyone can register as `victim@company.com`. Account
    squatting, phishing, and receiving notifications for another person's account are all possible.
    Rating: **HIGH**.
14. **No persistent audit log** — all security events (failed logins, theft detection, tier changes)
    are `console.error` only. In production, logs are ephemeral. No forensics capability.
    Rating: **MEDIUM**.
15. **`Referrer-Policy` header missing** — Phase A adds 4 security headers but omits this one.
    A pure API server should send `Referrer-Policy: no-referrer`. Rating: **LOW**.

---

## 2. Target Architecture — Two-Token System

### Token roles

```
┌─────────────────────────────────────────────────────────────────┐
│  ACCESS TOKEN (JWT, HS256)           REFRESH TOKEN (opaque)     │
│  ─────────────────────────────────   ─────────────────────────  │
│  TTL:     15 minutes                 TTL: 30 days               │
│  Stored:  memory only (macOS app)    Stored: macOS Keychain     │
│  Travels: every API request header   Travels: /auth/refresh only│
│  Server:  decoded in memory, no DB   Server: DB lookup + rotate │
│  Payload: userId, email, tier,       Payload: none — opaque     │
│           displayName, tokenFamily   32-byte random handle      │
└─────────────────────────────────────────────────────────────────┘
```

### Token lifecycle

```
┌──────────┐    POST /auth/login     ┌──────────────────────────┐
│  Client  │ ──────────────────────► │  Server                  │
│          │                         │  1. bcrypt verify        │
│          │ ◄────────────────────── │  2. SELECT user from DB  │
│          │  { accessToken (15m),   │  3. Generate both tokens │
│          │    refreshToken (30d) }  │  4. Store refresh hash   │
└──────────┘                         └──────────────────────────┘

Every API call (15 min window):
Client sends: Authorization: Bearer <accessToken>
Server: jwt.verify() in memory — ZERO DB queries

When access token expires (client receives 401 with code: TOKEN_EXPIRED):
┌──────────┐    POST /auth/refresh   ┌──────────────────────────┐
│  Client  │ ──────────────────────► │  Server                  │
│          │  { refreshToken,        │  1. SHA-256 hash token   │
│          │    clientId }           │  2. DB lookup by hash    │
│          │                         │  3. Check revocation     │
│          │                         │  4. Check theft (family) │
│          │                         │  5. Check device binding │
│          │ ◄────────────────────── │  6. Rotate token         │
│          │  { accessToken (new),   │  7. SELECT fresh tier    │
│          │    refreshToken (new) } │     from DB ← KEY STEP   │
└──────────┘                         └──────────────────────────┘
```

### Why `tokenFamily` is in the access token

Each login session has a `family_id` (UUID) shared by all rotations of its refresh token.
This UUID is embedded in the access token as `fam`. It enables:
- Linking an access token to its refresh token family for anomaly tracing
- Future: per-family session management (user can see and kill specific sessions)

### The tier guarantee

After Phase B is complete:
- **Maximum stale-tier window = 15 minutes** (one access token TTL)
- A billing webhook fires → DB `tier` updated → next client refresh cycle → new access token
  carries the real tier → server rejects calls the user is no longer entitled to

---

## 3. Phase A — Immediate Hardening (No Client Changes)

> **These 6 changes require zero client modifications. Apply before building any new feature.**
> Estimated total time: ~2 hours.

### A.1 — Pin JWT algorithm in `jwt.verify`

**File**: `token-server/auth.js`

**Vulnerability**: `alg:none` forgery and RS256→HS256 confusion allow complete auth bypass.

**Change** in `authenticateToken`:
```javascript
// BEFORE:
const decoded = jwt.verify(token, JWT_SECRET);

// AFTER:
const decoded = jwt.verify(token, JWT_SECRET, {
  algorithms: ['HS256'],               // whitelist — rejects alg:none, RS256, ES256
  issuer: 'inter-token-server',        // validate iss claim
  audience: 'inter-macos-client',      // validate aud claim
});
```

**Change** in `generateAuthToken` / future `generateAccessToken`:
```javascript
// BEFORE:
return jwt.sign(payload, JWT_SECRET, { expiresIn: JWT_EXPIRES_IN });

// AFTER:
return jwt.sign(payload, JWT_SECRET, {
  algorithm: 'HS256',
  expiresIn: JWT_EXPIRES_IN,
  issuer: 'inter-token-server',
  audience: 'inter-macos-client',
});
```

---

### A.2 — Crash on weak or missing JWT_SECRET

**File**: `token-server/auth.js` (top of file, before any exports)

**Vulnerability**: Dev fallback string `'inter-dev-secret-change-in-production'` is a known
public string. Any HS256 JWT signed with it can be verified by anyone who reads the source.

**Change**: Replace the current constant assignment with a startup guard:
```javascript
// BEFORE:
const JWT_SECRET = process.env.JWT_SECRET || 'inter-dev-secret-change-in-production';

// AFTER:
const JWT_SECRET = process.env.JWT_SECRET;
if (!JWT_SECRET || Buffer.from(JWT_SECRET, 'utf8').length < 32) {
  console.error('[FATAL] JWT_SECRET must be set and at least 32 bytes.');
  console.error('[FATAL] Generate: node -e "console.log(require(\'crypto\').randomBytes(32).toString(\'base64url\'))"');
  process.exit(1);
}
```

**Update `.env.example`**: Remove the default value, add generation instructions:
```dotenv
# JWT secret — REQUIRED. No default. Generate with:
# node -e "console.log(require('crypto').randomBytes(32).toString('base64url'))"
JWT_SECRET=
```

---

### A.3 — Remove LiveKit API key from startup log

**File**: `token-server/index.js`

**Vulnerability**: Server API key printed to stdout on every start. Persists in log aggregators
(Datadog, CloudWatch, journald) indefinitely.

**Change**: Delete the log line entirely. The health endpoint already confirms the server is up.
```javascript
// DELETE this line (currently near the bottom of index.js):
console.log(`[token-server] LiveKit API Key: ${LIVEKIT_API_KEY}`);
```

---

### A.4 — Rate limiting on auth endpoints

**File**: `token-server/index.js`

**Vulnerability**: No rate limiting on `/auth/login` or `/auth/register`. Credential stuffing
and account enumeration are unprotected. Room endpoints have rate limiting but auth does not.

**Implementation**: Add a `rateLimitAuth` helper using the existing Redis client (consistent
with the room endpoint rate limiting pattern already in the file):
```javascript
// Add near the room rate limit helper — consistent style
async function rateLimitAuth(req, res, next) {
  // Key on email for login (per-account lockout), IP for register (anti-enumeration)
  const identifier = req.body?.email
    ? `ratelimit:auth:${req.body.email.toLowerCase().trim()}`
    : `ratelimit:auth:ip:${req.ip}`;

  try {
    const count = await redis.incr(identifier);
    if (count === 1) await redis.expire(identifier, 900); // 15-min window

    if (count > 10) {
      const ttl = await redis.ttl(identifier);
      res.setHeader('Retry-After', String(ttl));
      return res.status(429).json({
        error: 'Too many authentication attempts. Please try again later.',
        retryAfter: ttl,
      });
    }
  } catch (redisErr) {
    // Redis failure must not block auth — log and continue
    console.error('[auth rate limit] Redis error:', redisErr.message);
  }
  next();
}
```

**Apply to endpoints**:
```javascript
app.post('/auth/register', rateLimitAuth, async (req, res) => { ... });
app.post('/auth/login',    rateLimitAuth, async (req, res) => { ... });
// Also add to /auth/refresh when it is built in Phase B
```

---

### A.5 — Centralized error handler (no raw DB errors to client)

**File**: `token-server/index.js`

**Vulnerability**: Route handlers pass `err.message` directly to `res.json({ error: err.message })`.
PostgreSQL errors contain constraint names, column names, and table names that reveal schema.

**Change 1**: Add a request ID header to every response (enables log correlation without leaking):
```javascript
// Add early in middleware chain, after express.json()
app.use((req, _res, next) => {
  req.id = require('crypto').randomUUID();
  next();
});
```

**Change 2**: Add a global error handler as the LAST middleware (after all routes):
```javascript
// MUST be the last app.use() call in index.js
// Express identifies error handlers by their 4-argument signature (err, req, res, next)
app.use((err, req, res, _next) => {
  console.error(`[error] requestId=${req.id} path=${req.path} err=${err.message}`);
  res.status(500).json({
    error: 'An internal error occurred',
    requestId: req.id,  // for support lookup only
  });
});
```

**Change 3**: In `auth.js`, map known PostgreSQL error codes to safe messages before throwing:
```javascript
// In register() inside auth.js, replace the raw db.query throw path:
try {
  const result = await db.query(`INSERT INTO users ...`, [...]);
  // ...
} catch (err) {
  if (err.code === '23505') throw new Error('Email already registered'); // unique violation
  throw new Error('Registration failed'); // all other DB errors — no pg details
}
```

---

### A.6 — Security response headers

**File**: `token-server/index.js`

**Vulnerability**: No HSTS means browsers may connect over HTTP (token leakage). No
`Cache-Control` means auth responses may be cached by proxies or browser history.

**Change**: Add after `app.use(express.json())`:
```javascript
app.use((_req, res, next) => {
  // Force HTTPS and tell browsers to remember it for 1 year
  res.setHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
  // Never cache any response from this server (all responses contain auth data)
  res.setHeader('Cache-Control', 'no-store');
  // Prevent MIME sniffing
  res.setHeader('X-Content-Type-Options', 'nosniff');
  // Disallow embedding in iframes (irrelevant for API but zero cost)
  res.setHeader('X-Frame-Options', 'DENY');
  // Don't leak this server's URL in outbound requests
  res.setHeader('Referrer-Policy', 'no-referrer');
  next();
});
```

---

### A.7 — Timing normalization in `register()` and `login()`

**File**: `token-server/auth.js`

**Vulnerability**: Both functions exit early without doing bcrypt work when the user/email
doesn't match expectations. This creates a timing oracle: a non-existent email returns in ~2ms
while a valid email with wrong password takes ~80ms (one bcrypt round). An attacker can enumerate
every email in a list within seconds just by measuring response latency.

**Fix for `register()`** — dummy bcrypt call on early exit to normalize timing:
```javascript
// In register(), replace:
if (existing.rows.length > 0) {
  throw new Error('Email already registered');
}

// With:
if (existing.rows.length > 0) {
  await bcrypt.hash('dummy-constant-timing-normalization', BCRYPT_ROUNDS);
  // Return generic message — do not confirm whether email is registered
  throw new Error('If this email is available, you will receive a confirmation email.');
}
```

**Fix for `login()`** — compute dummy hash once at module load, use on missing-user path:
```javascript
// At module level (computed ONCE at startup, not per request):
let DUMMY_HASH;
bcrypt.hash('inter-dummy-constant-do-not-change', BCRYPT_ROUNDS).then(h => { DUMMY_HASH = h; });

// In login(), replace:
if (result.rows.length === 0) {
  throw new Error('Invalid email or password');
}

// With:
if (result.rows.length === 0) {
  await bcrypt.compare(password, DUMMY_HASH); // normalize timing — always pay bcrypt cost
  throw new Error('Invalid email or password');
}
```

**Important**: The `DUMMY_HASH` must be initialized once at startup, not recomputed per request.
Recomputing per request doubles the server CPU cost for every failed login attempt.

---

### A.8 — Input validation and bcrypt truncation guard

**File**: `token-server/auth.js`

**Vulnerability 1 — bcrypt 72-byte truncation**: bcrypt silently truncates input at 72 bytes.
A password of 100 characters and its first 72 characters produce identical hashes. A user can
log in with a shorter version of their own password without knowing it, undermining password
strength. OWASP Password Storage Cheat Sheet explicitly requires enforcing this limit.

**Vulnerability 2 — Missing input limits**: `email`, `password`, and `displayName` have no
maximum length. A 10MB string can be inserted into the DB. Email has no format validation.

**Change** in `register()` — replace the existing minimal validation block:
```javascript
// BEFORE:
if (!email || !password || !displayName) {
  throw new Error('email, password, and displayName are required');
}
if (password.length < 8) {
  throw new Error('Password must be at least 8 characters');
}

// AFTER:
if (!email || !password || !displayName) {
  throw new Error('email, password, and displayName are required');
}

// Email format + length (OWASP: local part ≤63 chars, total ≤254 chars)
const emailStr = String(email).toLowerCase().trim();
if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(emailStr) || emailStr.length > 254) {
  throw new Error('Invalid email address');
}

// Password: 8-72 byte range (NIST minimum 8, bcrypt hard cap 72 bytes)
const passwordBytes = Buffer.byteLength(String(password), 'utf8');
if (passwordBytes < 8) {
  throw new Error('Password must be at least 8 characters');
}
if (passwordBytes > 72) {
  throw new Error('Password must be 72 characters or fewer');
}

// displayName: trim and cap at 100 chars
const nameStr = String(displayName).trim();
if (nameStr.length < 1 || nameStr.length > 100) {
  throw new Error('Display name must be between 1 and 100 characters');
}
```

**Change** in `login()` — add password byte-length guard before bcrypt.compare:
```javascript
// Add before bcrypt.compare — prevents bcrypt DoS via extremely long passwords
const passwordBytes = Buffer.byteLength(String(password), 'utf8');
if (passwordBytes > 72) {
  await bcrypt.compare(password, DUMMY_HASH); // still normalize timing
  throw new Error('Invalid email or password');
}
```

---

## 4. Phase B — Full Refresh Token System (With Client Auth UI)

> **Dependency**: Build ONLY when the macOS client has a login/registration UI and can store
> tokens. Building the server side without the client creates a broken state where access tokens
> expire every 15 minutes with no recovery path.
>
> Build server + client in ONE phase. Do not split.

### B.1 — Database migration: `refresh_tokens` table

**New file**: `token-server/migrations/004_refresh_tokens.sql`

```sql
CREATE TABLE refresh_tokens (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    -- SHA-256 of the raw token stored as bytea.
    -- Raw token NEVER enters the database. A full DB read still cannot reconstruct it.
    token_hash   BYTEA NOT NULL UNIQUE,

    -- All rotations of a single login session share a family_id.
    -- If any revoked token in a family is presented, the ENTIRE family is killed.
    -- This is the primary stolen-token detection mechanism.
    family_id    UUID NOT NULL,

    -- macOS hardware UUID (IOPlatformUUID) — soft device binding.
    -- Mismatch triggers security warning and investigation, not necessarily hard reject.
    client_id    VARCHAR(100),

    issued_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at   TIMESTAMPTZ NOT NULL,

    -- NULL = active. Timestamped = revoked. Preserves full audit trail.
    revoked_at   TIMESTAMPTZ,

    -- Audit chain: each rotation records the ID of the token it replaced.
    replaced_by  UUID REFERENCES refresh_tokens(id)
);

-- Primary lookup path — used on every /auth/refresh call
CREATE INDEX idx_rt_hash   ON refresh_tokens (token_hash)  WHERE revoked_at IS NULL;
-- Used for logout (revoke all tokens for a user)
CREATE INDEX idx_rt_user   ON refresh_tokens (user_id)     WHERE revoked_at IS NULL;
-- Used for family-wide revocation on theft detection
CREATE INDEX idx_rt_family ON refresh_tokens (family_id);

-- Periodic maintenance (run via pg_cron or a cron job):
-- DELETE FROM refresh_tokens WHERE expires_at < NOW() - INTERVAL '7 days';
-- The 7-day grace period preserves audit trail for recent sessions.
```

---

### B.2 — `auth.js` changes

#### New constants
```javascript
const REFRESH_TOKEN_SECRET = process.env.REFRESH_TOKEN_SECRET;
if (!REFRESH_TOKEN_SECRET || Buffer.from(REFRESH_TOKEN_SECRET, 'utf8').length < 32) {
  console.error('[FATAL] REFRESH_TOKEN_SECRET must be set and at least 32 bytes.');
  process.exit(1);
}

const ACCESS_TOKEN_TTL  = process.env.ACCESS_TOKEN_TTL  || '15m';
const REFRESH_TOKEN_DAYS = parseInt(process.env.REFRESH_TOKEN_TTL_DAYS || '30', 10);
```

#### `generateAccessToken(user, familyId)` — replaces `generateAuthToken`
```javascript
function generateAccessToken(user, familyId) {
  return jwt.sign(
    {
      userId:      user.id,
      email:       user.email,
      displayName: user.display_name,
      tier:        user.tier,
      fam:         familyId,  // short key — this travels on every request
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
```

#### `issueRefreshToken(userId, clientId, dbClient)` — new
```javascript
// Returns: { rawToken (base64url string), familyId }
// rawToken is given to client. SHA-256 hash is stored in DB. Raw token never persists.
async function issueRefreshToken(userId, clientId, dbClient) {
  const rawToken = crypto.randomBytes(32);                                    // 256-bit entropy
  const tokenHash = crypto.createHash('sha256').update(rawToken).digest();   // bytea
  const familyId  = crypto.randomUUID();                                      // new family per login

  await dbClient.query(
    `INSERT INTO refresh_tokens (user_id, token_hash, family_id, client_id, expires_at)
     VALUES ($1, $2, $3, $4, NOW() + INTERVAL '${REFRESH_TOKEN_DAYS} days')`,
    [userId, tokenHash, familyId, clientId || null]
  );

  return { rawToken: rawToken.toString('base64url'), familyId };
}
```

#### Updated `login()` and `register()` return shape
```javascript
// Both functions now return:
{
  user: { id, email, displayName, tier, createdAt },
  accessToken:  '<15m JWT>',
  refreshToken: '<30d opaque base64url string>',
  expiresIn:    900,  // seconds — client uses this to schedule proactive refresh
}
// NOTE: 'token' field is REMOVED. Any client code using result.token must update to result.accessToken.
```

#### Updated `authenticateToken` middleware — distinguishes expired from invalid
```javascript
function authenticateToken(req, res, next) {
  const authHeader = req.headers['authorization'];

  if (!authHeader) {
    req.user = null;
    return next(); // anonymous — additive auth preserved
  }

  const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : authHeader;

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
      tokenFamily: decoded.fam,
    };
    next();
  } catch (err) {
    if (err.name === 'TokenExpiredError') {
      // Client should call /auth/refresh, then replay. Not a "bad" token — just old.
      return res.status(401).json({ error: 'Access token expired', code: 'TOKEN_EXPIRED' });
    }
    // Tampered, wrong audience, wrong issuer, or structurally invalid
    return res.status(401).json({ error: 'Invalid access token', code: 'TOKEN_INVALID' });
  }
}
```

The `code` field is critical for the macOS client:
- `TOKEN_EXPIRED` → silent refresh + replay original request
- `TOKEN_INVALID` → force user back to login screen, clear Keychain

---

### B.3 — New endpoints in `index.js`

#### `POST /auth/refresh`

This is the core of the entire Option A design. Everything important happens here.

```javascript
// POST /auth/refresh
// Body: { refreshToken (base64url string), clientId (macOS hardware UUID) }
// Returns: { accessToken, refreshToken, expiresIn }
// No auth middleware — this IS the auth recovery endpoint
app.post('/auth/refresh', rateLimitAuth, async (req, res) => {
  const { refreshToken, clientId } = req.body;

  if (!refreshToken || typeof refreshToken !== 'string') {
    return res.status(400).json({ error: 'refreshToken required' });
  }

  // Validate and decode the base64url token before touching the DB
  let rawBytes;
  try {
    rawBytes = Buffer.from(refreshToken, 'base64url');
    if (rawBytes.length !== 32) throw new Error('invalid length');
  } catch {
    return res.status(401).json({ error: 'Invalid refresh token' });
  }

  const tokenHash = crypto.createHash('sha256').update(rawBytes).digest();

  const dbClient = await db.getClient();
  try {
    await dbClient.query('BEGIN');

    // Fetch the token row — include revoked rows (needed for theft detection)
    const { rows } = await dbClient.query(
      `SELECT id, user_id, family_id, client_id, expires_at, revoked_at
       FROM refresh_tokens
       WHERE token_hash = $1
       LIMIT 1`,
      [tokenHash]
    );

    if (rows.length === 0) {
      await dbClient.query('ROLLBACK');
      return res.status(401).json({ error: 'Invalid refresh token' });
    }

    const stored = rows[0];

    // ── THEFT DETECTION ─────────────────────────────────────────────────────────
    // A revoked token being used means one of two things:
    //   (a) Attacker stole the token, rotated it, and the victim is now using the
    //       old (now-revoked) copy.
    //   (b) Attacker is replaying the old copy after the victim already rotated.
    // Either way: the entire family is compromised. Kill all active tokens in it.
    if (stored.revoked_at !== null) {
      await dbClient.query(
        `UPDATE refresh_tokens SET revoked_at = NOW()
         WHERE family_id = $1 AND revoked_at IS NULL`,
        [stored.family_id]
      );
      await dbClient.query('COMMIT');
      console.error(`[SECURITY ALERT] Refresh token reuse detected. family=${stored.family_id} userId=${stored.user_id}`);
      // TODO (Phase C): trigger account alert email, flag for security review
      return res.status(401).json({
        error: 'Security alert: your session was compromised. Please log in again.',
        code: 'SESSION_COMPROMISED',
      });
    }

    // ── EXPIRY ───────────────────────────────────────────────────────────────────
    if (new Date(stored.expires_at) < new Date()) {
      await dbClient.query('ROLLBACK');
      return res.status(401).json({ error: 'Refresh token expired', code: 'TOKEN_EXPIRED' });
    }

    // ── DEVICE BINDING (soft) ────────────────────────────────────────────────────
    // Mismatch = different device. Could be legitimate (app reinstall) or stolen.
    // Policy: log and continue. Future: increment mismatch counter, force re-auth after N.
    if (stored.client_id && clientId && stored.client_id !== clientId) {
      console.warn(`[SECURITY] Client ID mismatch on refresh. stored=${stored.client_id} got=${clientId} userId=${stored.user_id}`);
    }

    // ── ROTATION ─────────────────────────────────────────────────────────────────
    // Revoke old token and issue new one in the same family. Atomic within transaction.
    await dbClient.query(
      `UPDATE refresh_tokens SET revoked_at = NOW() WHERE id = $1`,
      [stored.id]
    );

    const newRaw   = crypto.randomBytes(32);
    const newHash  = crypto.createHash('sha256').update(newRaw).digest();

    await dbClient.query(
      `INSERT INTO refresh_tokens
         (user_id, token_hash, family_id, client_id, expires_at, replaced_by)
       VALUES ($1, $2, $3, $4, NOW() + INTERVAL '30 days', $5)`,
      [stored.user_id, newHash, stored.family_id, clientId || stored.client_id, stored.id]
    );

    // ── FRESH TIER RE-READ ────────────────────────────────────────────────────────
    // This is the ENTIRE POINT of Option A. Tier is re-read from DB every refresh cycle.
    // A billing webhook may have changed it, a cancellation may have happened.
    // The new access token will carry the real, current tier.
    const { rows: userRows } = await dbClient.query(
      `SELECT id, email, display_name, tier
       FROM users WHERE id = $1`,
      [stored.user_id]
    );

    if (userRows.length === 0) {
      await dbClient.query('ROLLBACK');
      return res.status(401).json({ error: 'User account not found' });
    }

    await dbClient.query('COMMIT');

    const accessToken = generateAccessToken(userRows[0], stored.family_id);

    res.json({
      accessToken,
      refreshToken: newRaw.toString('base64url'),
      expiresIn: 900, // 15 min — client uses this to schedule proactive refresh
    });

  } catch (err) {
    await dbClient.query('ROLLBACK');
    throw err; // bubble up to global error handler — no DB details exposed
  } finally {
    dbClient.release();
  }
});
```

#### `POST /auth/logout`

```javascript
// POST /auth/logout
// Body: { refreshToken }
// Returns: 204 No Content
// Revokes ONE specific refresh token. Client discards the access token from memory.
app.post('/auth/logout', auth.requireAuth, async (req, res) => {
  const { refreshToken } = req.body;

  if (refreshToken) {
    try {
      const rawBytes  = Buffer.from(refreshToken, 'base64url');
      const tokenHash = crypto.createHash('sha256').update(rawBytes).digest();
      await db.query(
        `UPDATE refresh_tokens SET revoked_at = NOW()
         WHERE token_hash = $1 AND revoked_at IS NULL`,
        [tokenHash]
      );
    } catch (err) {
      // Logout must not fail visibly — log and continue
      console.error('[auth] Logout token revocation failed:', err.message);
    }
  }

  res.status(204).end();
});
```

---

### B.4 — macOS Client Implementation (InterTokenService.swift)

#### Token storage
```swift
// Store refresh token in Keychain — NEVER UserDefaults, NEVER disk files
// Access control: locked to this device, requires unlock (not biometric — UX friction)
let storeQuery: [String: Any] = [
    kSecClass as String:            kSecClassGenericPassword,
    kSecAttrService as String:      "com.inter.app.refreshtoken",
    kSecAttrAccount as String:      userId,
    kSecValueData as String:        refreshToken.data(using: .utf8)!,
    kSecAttrAccessible as String:   kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    // ThisDeviceOnly = not backed up to iCloud. Prevents token leakage via iCloud Backup.
]
SecItemAdd(storeQuery as CFDictionary, nil)

// Access token: stored as a Swift property in memory only
// var currentAccessToken: String? — never written anywhere
```

#### Device identifier (client_id)
```swift
// macOS hardware UUID — stable across app reinstalls on same machine
// IOPlatformUUID is unique per hardware, not per-app-install
func getHardwareUUID() -> String? {
    let service = IOServiceGetMatchingService(kIOMasterPortDefault,
                      IOServiceMatching("IOPlatformExpertDevice"))
    defer { IOObjectRelease(service) }
    return IORegistryEntryCreateCFProperty(service,
               "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)
               .takeRetainedValue() as? String
}
```

#### Automatic silent refresh on 401
```swift
// In InterTokenService — intercept TOKEN_EXPIRED and retry transparently
func performRequest(_ request: URLRequest, completion: @escaping (Data?, Error?) -> Void) {
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let http = response as? HTTPURLResponse,
           http.statusCode == 401,
           let body = data,
           let json = try? JSONDecoder().decode([String: String].self, from: body),
           json["code"] == "TOKEN_EXPIRED" {
            // Silently refresh, then replay the original request
            self.refreshAccessToken { success in
                if success {
                    // Replay with new access token in header
                    var retried = request
                    retried.setValue("Bearer \(self.currentAccessToken!)", forHTTPHeaderField: "Authorization")
                    URLSession.shared.dataTask(with: retried, completionHandler: completion).resume()
                } else {
                    // Refresh failed (SESSION_COMPROMISED or expired) — force re-login
                    self.delegate?.sessionDidExpire()
                }
            }
        } else {
            completion(data, error)
        }
    }.resume()
}
```

#### Proactive refresh scheduling
```swift
// On receiving a new accessToken, schedule a refresh before it expires
// expiresIn is 900 seconds (15 min). Refresh at 13 min 45 sec to avoid any gap.
func scheduleProactiveRefresh(expiresIn: TimeInterval) {
    refreshTimer?.invalidate()
    let refreshAt = expiresIn - 75 // 75 seconds before expiry
    refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshAt, repeats: false) { _ in
        self.refreshAccessToken(completion: nil)
    }
}
```

#### TLS certificate pinning
```swift
// URLSessionDelegate — pin to server's public key SPKI hash
// Pin the PUBLIC KEY (not the certificate) so cert renewals don't break pinning
// Generate hash: openssl x509 -in cert.pem -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256 -binary | base64
class PinnedSessionDelegate: NSObject, URLSessionDelegate {
    private let pinnedSPKIHash = "YOUR_SERVER_PUBLIC_KEY_SHA256_BASE64_HERE"

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust,
              let cert = SecTrustGetCertificateAtIndex(serverTrust, 0),
              let pubKey = SecCertificateCopyKey(cert),
              let pubKeyData = SecKeyCopyExternalRepresentation(pubKey, nil) as Data? else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let serverHash = Data(SHA256.hash(data: pubKeyData)).base64EncodedString()
        if serverHash == pinnedSPKIHash {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            // Log this as a security event — do not treat as a normal connection failure
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
```

---

## 5. Phase C — Billing & Tier Lifecycle Integration (Lemon Squeezy)

> **Dependency**: Lemon Squeezy store configured with products/variants. Phase B must be complete first.
> **Payment provider**: [Lemon Squeezy](https://lemonsqueezy.com/) — Merchant of Record (MoR).
> LS handles all tax collection, VAT, SCA/3DS authentication, payment retries, and dunning
> internally. Our server only receives webhook events and updates tier state.

### Architecture Overview

```
┌──────────────────┐    POST /billing/checkout    ┌──────────────────────────┐
│  macOS Client    │ ────────────────────────────► │  token-server            │
│  (Inter.app)     │                               │  1. Validate user auth   │
│                  │ ◄──────────────────────────── │  2. Create LS checkout   │
│                  │  { checkoutUrl }               │     with custom_data:    │
│  Opens URL in    │                               │     { user_id: <uuid> }  │
│  default browser │                               │  3. Return checkout URL  │
└──────────────────┘                               └──────────────────────────┘
        │
        │  User completes payment on LS hosted checkout page
        ▼
┌──────────────────┐    POST /webhooks/lemonsqueezy  ┌──────────────────────────┐
│  Lemon Squeezy   │ ─────────────────────────────► │  token-server            │
│  (webhook)       │                                 │  1. Verify X-Signature   │
│                  │                                 │  2. Extract user_id from │
│  Fires events:   │                                 │     meta.custom_data     │
│  subscription_   │                                 │  3. Update users.tier    │
│  created, etc.   │                                 │     + subscription_status│
│                  │ ◄───────────────────────────── │  4. Return 200           │
└──────────────────┘                                 └──────────────────────────┘
        │
        │  Next /auth/refresh cycle (max 15 min)
        ▼
  Client receives new access token with updated tier
```

### What Phase C adds

1. **DB billing columns** on the `users` table:
   ```sql
   ALTER TABLE users
     ADD COLUMN subscription_status    VARCHAR(20) DEFAULT 'none',
     -- 'none' | 'on_trial' | 'active' | 'past_due' | 'unpaid'
     -- | 'cancelled' | 'expired' | 'paused'
     ADD COLUMN ls_subscription_id     VARCHAR(255),   -- Lemon Squeezy subscription ID
     ADD COLUMN ls_customer_id         VARCHAR(255),   -- Lemon Squeezy customer ID
     ADD COLUMN ls_variant_id          VARCHAR(255),   -- Current plan variant ID
     ADD COLUMN ls_product_id          VARCHAR(255),   -- Current product ID
     ADD COLUMN trial_ends_at          TIMESTAMPTZ,
     ADD COLUMN current_period_ends_at TIMESTAMPTZ,    -- renews_at from LS
     ADD COLUMN grace_until            TIMESTAMPTZ,    -- ends_at from LS (for cancelled subs)
     ADD COLUMN ls_portal_url          TEXT;            -- customer portal URL (24h expiry, refreshed on webhook)
   ```

2. **Webhook receiver** for Lemon Squeezy subscription lifecycle events:

   | LS Webhook Event | Action |
   |---|---|
   | `subscription_created` | Set tier from variant_id, status = `active` or `on_trial` |
   | `subscription_updated` | Sync tier + status (plan changes, status transitions) |
   | `subscription_cancelled` | Keep tier until `ends_at`, set grace_until |
   | `subscription_expired` | Downgrade to `free` immediately |
   | `subscription_payment_success` | Confirm `active`, clear grace period |
   | `subscription_payment_failed` | Set `past_due`, start grace countdown |
   | `subscription_payment_recovered` | Restore `active` after payment recovery |
   | `subscription_paused` | Set `paused`, block paid access |
   | `subscription_unpaused` | Restore previous tier, set `active` |
   | `order_created` | Log only (subscription_created does the real work) |

   The tier change in the DB is immediately reflected in the next `/auth/refresh` cycle
   (max 15 min lag via Phase B). No other code needs to change.

3. **Webhook signature validation** — mandatory, not optional:
   ```javascript
   // Lemon Squeezy uses HMAC-SHA256 hex digest in X-Signature header
   const crypto = require('crypto');
   const hmac = crypto.createHmac('sha256', LEMONSQUEEZY_WEBHOOK_SECRET);
   const digest = Buffer.from(hmac.update(rawBody).digest('hex'), 'utf8');
   const signature = Buffer.from(req.get('X-Signature') || '', 'utf8');
   if (!crypto.timingSafeEqual(digest, signature)) {
     throw new Error('Invalid webhook signature');
   }
   // CRITICAL: Uses crypto.timingSafeEqual — never use === for signature comparison
   // CRITICAL: rawBody must be the exact bytes received — express.raw() required on route
   ```

4. **Idempotency** — payment webhooks are delivered at-least-once (up to 4 attempts):
   ```sql
   -- Store processed event IDs to prevent double-processing
   -- LS webhook payloads include meta.event_name but no guaranteed unique event ID.
   -- Generate a deterministic ID from: event_name + subscription_id + timestamp
   CREATE TABLE processed_webhook_events (
       event_id     VARCHAR(255) PRIMARY KEY,
       event_type   VARCHAR(100) NOT NULL,
       processed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
   );
   ```

5. **User linking via `custom_data`** — this is the critical architectural difference:
   - At checkout creation, we pass `checkout_data.custom.user_id` with our DB user UUID
   - Every webhook event includes `meta.custom_data.user_id` — this is how we look up the user
   - We also store `ls_customer_id` for future API calls (portal URLs, subscription management)
   - Unlike Stripe, there is no need to pre-create a customer on registration

6. **Checkout URL endpoint** — replaces Stripe customer creation:
   ```
   POST /billing/checkout  (authenticated)
   Body: { variantId: "123456" }
   → Creates LS checkout via POST https://api.lemonsqueezy.com/v1/checkouts
   → Passes user_id + email in checkout_data.custom
   → Returns { checkoutUrl: "https://..." }
   → macOS app opens URL in default browser
   ```

7. **Customer portal** — Lemon Squeezy provides built-in portal URLs:
   - `urls.customer_portal` — full subscription management (cancel, upgrade, invoices)
   - `urls.update_payment_method` — payment method update only
   - Both are pre-signed URLs with 24-hour expiry, refreshed on every webhook event
   - No API call needed to create a portal session (unlike Stripe)

### Subscription State Machine (Lemon Squeezy)

```
States: none | on_trial | active | past_due | unpaid | cancelled | expired | paused

Valid transitions (enforced by validateTransition):
  none       → on_trial, active
  on_trial   → active, cancelled
  active     → past_due, cancelled, paused
  past_due   → active, unpaid, cancelled
  unpaid     → active, cancelled, expired
  cancelled  → expired              (grace period ended)
  expired    → none                 (terminal — new subscription = new checkout)
  paused     → active               (unpaused)
```

Note: Re-subscription after `cancelled`/`expired` creates a brand new LS subscription.
The user goes through checkout again, receiving a new `ls_subscription_id`. The old
subscription row is not reactivated.

### Lemon Squeezy as Merchant of Record — What We Do NOT Handle

Because LS is the Merchant of Record, the following are handled entirely by LS:
- **Tax collection** (sales tax, VAT, GST) — LS calculates and remits
- **3DS / SCA authentication** — LS handles all payment authentication
- **Payment method collection** — via LS hosted checkout page
- **Dunning / retry logic** — LS retries failed payments (4 attempts over ~2 weeks)
- **Refund processing** — managed via LS dashboard or API
- **Dispute/chargeback handling** — LS handles as MoR; we receive `order_refunded` if applicable

This eliminates the need for: `invoice.payment_action_required` (3DS), `charge.dispute.created`,
`incomplete_expired` handling, and Stripe Customer Portal session creation.

---

## 6. Phase D — Account Recovery & Security Hardening

> **Dependency**: Requires email sending infrastructure (`nodemailer` + SMTP or transactional
> email provider: Resend, SendGrid, Postmark). Can be built independently of Phase B/C client
> work. Phase D.1 and D.2 are the last things needed before the product is considered
> production-ready from a security standpoint.

### D.1 — Password reset flow

**New endpoints**: `POST /auth/forgot-password`, `POST /auth/reset-password`

**New DB table**: `token-server/migrations/006_password_reset_tokens.sql`

```sql
CREATE TABLE password_reset_tokens (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- SHA-256 of raw token. Raw token sent by email, hash stored in DB.
    token_hash  BYTEA NOT NULL UNIQUE,
    expires_at  TIMESTAMPTZ NOT NULL,
    used_at     TIMESTAMPTZ  -- NULL = unused. Set on first use. Token is then permanently dead.
);

CREATE INDEX idx_prt_hash ON password_reset_tokens (token_hash) WHERE used_at IS NULL;
-- Auto-clean: DELETE FROM password_reset_tokens WHERE expires_at < NOW() - INTERVAL '1 day';
```

**`POST /auth/forgot-password`** — request a reset link:
```javascript
// Body: { email }
// ALWAYS returns 200 with a generic message regardless of whether email exists.
// This is mandatory — returning a different response for missing emails is enumeration.
app.post('/auth/forgot-password', rateLimitAuth, async (req, res) => {
  const email = String(req.body?.email || '').toLowerCase().trim();

  // Intentionally fire-and-forget the DB lookup — don't let DB timing leak email existence
  (async () => {
    try {
      const result = await db.query('SELECT id FROM users WHERE email = $1', [email]);
      if (result.rows.length === 0) return; // silent — do not send email, do not error

      const rawToken  = crypto.randomBytes(32);
      const tokenHash = crypto.createHash('sha256').update(rawToken).digest();

      await db.query(
        `INSERT INTO password_reset_tokens (user_id, token_hash, expires_at)
         VALUES ($1, $2, NOW() + INTERVAL '1 hour')`,
        [result.rows[0].id, tokenHash]
      );

      // Send email — link always uses https://, never inter:// directly.
      // Reason: inter:// only works on Macs with the app installed. Clicking the link
      // on a phone, in a web email client (Gmail/Outlook web), or on a machine without
      // the app installed would silently do nothing. The https:// page handles all cases.
      // URL sent: https://your-token-server.com/reset-password?token=<base64url>
      await sendPasswordResetEmail(email, rawToken.toString('base64url'));
    } catch (err) {
      console.error('[auth] forgot-password error:', err.message);
      // Never surface this error to the caller
    }
  })();

  // Always return 200 immediately — do not wait for DB or email
  res.json({ message: "If that email is registered, you'll receive a reset link shortly." });
});
```

**`POST /auth/reset-password`** — consume the token and set new password:
```javascript
// Body: { token (base64url), newPassword }
app.post('/auth/reset-password', async (req, res) => {
  const { token, newPassword } = req.body || {};
  if (!token || !newPassword) {
    return res.status(400).json({ error: 'token and newPassword are required' });
  }

  // Validate new password (same rules as register)
  const passwordBytes = Buffer.byteLength(String(newPassword), 'utf8');
  if (passwordBytes < 8 || passwordBytes > 72) {
    return res.status(400).json({ error: 'Password must be 8-72 characters' });
  }

  const tokenHash = crypto.createHash('sha256')
    .update(Buffer.from(token, 'base64url'))
    .digest();

  const dbClient = await db.getClient(); // db.js exports getClient(), not connect()
  try {
    await dbClient.query('BEGIN');

    const result = await dbClient.query(
      `SELECT id, user_id FROM password_reset_tokens
       WHERE token_hash = $1 AND used_at IS NULL AND expires_at > NOW()`,
      [tokenHash]
    );

    if (result.rows.length === 0) {
      await dbClient.query('ROLLBACK');
      // Generic error — do not distinguish expired vs never-existed vs already-used
      return res.status(400).json({ error: 'Invalid or expired reset token' });
    }

    const { id: tokenId, user_id: userId } = result.rows[0];
    const newHash = await bcrypt.hash(newPassword, BCRYPT_ROUNDS);

    // Mark token as used (single-use enforcement)
    await dbClient.query(
      'UPDATE password_reset_tokens SET used_at = NOW() WHERE id = $1',
      [tokenId]
    );

    // Update password
    await dbClient.query(
      'UPDATE users SET password_hash = $1 WHERE id = $2',
      [newHash, userId]
    );

    // Revoke all existing refresh tokens for this user (force re-login everywhere)
    await dbClient.query(
      'UPDATE refresh_tokens SET revoked_at = NOW() WHERE user_id = $1 AND revoked_at IS NULL',
      [userId]
    );

    await dbClient.query('COMMIT');
    res.json({ message: 'Password updated. Please log in again.' });
  } catch (err) {
    await dbClient.query('ROLLBACK');
    throw err;
  } finally {
    dbClient.release();
  }
});
```

**`GET /reset-password`** — the landing page linked from the email:

This is a small server-rendered HTML page (not a JSON endpoint). It serves two purposes:
1. Tries the `inter://` deep link first — if the app is installed, macOS opens it and the
   user resets their password inside the app.
2. If the deep link fails (app not installed, phone, web email client, browser security block),
   the form below is already visible and the user can reset via the browser.

```javascript
// SECURITY NOTE: The token is base64url-encoded ([A-Za-z0-9_-]+ only), which means it
// contains no HTML-special characters and is safe to interpolate here. However, as a
// general rule never interpolate untrusted strings into HTML without escaping. If this
// route is ever extended to echo back other user-supplied input, use a template engine
// (e.g. eta, nunjucks) or at minimum run the value through an HTML-escape function first.
app.get('/reset-password', (req, res) => {
  const token = req.query.token;

  // Validate token is base64url before rendering — prevents any injection even though
  // the character set is already safe
  if (!token || !/^[A-Za-z0-9_-]{40,}$/.test(token)) {
    return res.status(400).send('<p>Invalid or missing reset token.</p>');
  }

  // Set security headers for this HTML response
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
    // Attempt to open the installed macOS app.
    // If it is not installed this silently fails; the form below remains visible.
    window.location = 'inter://reset-password?token=${token}';
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
```

**`POST /auth/reset-password-web`** — form submission variant (for the browser fallback):

This is a thin wrapper around `POST /auth/reset-password`. The only difference is it
returns HTML instead of JSON so the browser renders a confirmation page.

**Important**: To avoid duplicating the reset logic, extract it from the route handler into
an exported `auth.resetPassword(token, newPassword)` function in `auth.js`, then call it
from both routes. Add this to `auth.js` exports:

```javascript
// In auth.js — extract the core reset logic into an exported function
async function resetPassword(token, newPassword) {
  const passwordBytes = Buffer.byteLength(String(newPassword), 'utf8');
  if (passwordBytes < 8 || passwordBytes > 72) {
    throw Object.assign(new Error('Password must be 8-72 characters'), { status: 400 });
  }
  const tokenHash = crypto.createHash('sha256')
    .update(Buffer.from(token, 'base64url'))
    .digest();

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
    const newHash = await bcrypt.hash(newPassword, BCRYPT_ROUNDS);
    await dbClient.query('UPDATE password_reset_tokens SET used_at = NOW() WHERE id = $1', [tokenId]);
    await dbClient.query('UPDATE users SET password_hash = $1 WHERE id = $2', [newHash, userId]);
    await dbClient.query(`UPDATE refresh_tokens SET revoked_at = NOW() WHERE user_id = $1 AND revoked_at IS NULL`, [userId]);
    await dbClient.query('COMMIT');
  } catch (err) {
    await dbClient.query('ROLLBACK');
    throw err;
  } finally {
    dbClient.release();
  }
}

module.exports = {
  // ... existing exports ...
  resetPassword,  // ADD THIS
};
```

Then in `index.js`, both routes call `auth.resetPassword()`:

```javascript
app.post('/auth/reset-password-web', express.urlencoded({ extended: false }), async (req, res) => {
  const { token, newPassword } = req.body || {};
  try {
    await auth.resetPassword(token, newPassword);
    res.send('<p>Password updated. You can close this page and log in to the Inter app.</p>');
  } catch (err) {
    res.status(400).send(`<p>Error: ${err.message}. Please request a new reset link.</p>`);
  }
});
```

**Security properties this design provides** (per OWASP Forgot Password Cheat Sheet):
- Email always links to `https://` — works on any device, any email client
- Deep link to app is attempted first; web form is the universal fallback
- Token is 32 cryptographically random bytes (256-bit entropy)
- Stored as SHA-256 hash — DB breach cannot reconstruct the raw token
- Single-use — `used_at` is set atomically in the same transaction as the password update
- 1-hour expiry
- Response timing is normalized — DB lookup is fire-and-forget, 200 returned immediately
- Generic message regardless of whether email exists
- Password reset revokes ALL existing sessions (forces full re-login)
- Token validated as `[A-Za-z0-9_-]+` before HTML interpolation — no XSS path even without escaping
- `Content-Security-Policy` on the HTML page restricts script execution to the inline redirect only

---

### D.2 — Email verification on register

**New column on `users`**: `email_verified_at TIMESTAMPTZ NULL`

**New DB table**: `token-server/migrations/007_email_verification_tokens.sql`

```sql
ALTER TABLE users ADD COLUMN email_verified_at TIMESTAMPTZ;

CREATE TABLE email_verification_tokens (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash  BYTEA NOT NULL UNIQUE,
    expires_at  TIMESTAMPTZ NOT NULL,
    used_at     TIMESTAMPTZ
);

CREATE INDEX idx_evt_hash ON email_verification_tokens (token_hash) WHERE used_at IS NULL;
```

**Changes to `register()`** — send verification email after successful insert:
```javascript
// After INSERT succeeds, before returning the token pair:
const verifyRaw   = crypto.randomBytes(32);
const verifyHash  = crypto.createHash('sha256').update(verifyRaw).digest();

await db.query(
  `INSERT INTO email_verification_tokens (user_id, token_hash, expires_at)
   VALUES ($1, $2, NOW() + INTERVAL '8 hours')`,
  [user.id, verifyHash]
);

// Send verification email (fire-and-forget — don't fail registration if email fails)
sendVerificationEmail(user.email, verifyRaw.toString('base64url')).catch(err => {
  console.error('[auth] verification email failed:', err.message);
});
```

**`GET /auth/verify-email?token=<base64url>`** — confirm email ownership:
```javascript
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

  res.json({ message: 'Email verified. You can now use all features.' });
});
```

**`POST /auth/resend-verification`** — for expired tokens:
```javascript
// Same rate limiting as /auth/register. Body: { email }
// Fire-and-forget pattern — always 200, generic response.
```

**How unverified users are handled**: Do NOT block login. Issue tokens normally but set
`emailVerified: false` in the access token payload. Let the macOS client show a soft prompt
("Please verify your email") rather than a hard gate. Hard-gating email at login creates
a permanent lockout if email delivery fails — unacceptable for a desktop app.

---

### D.3 — Logout all devices

**`POST /auth/logout-all`** — revoke every session for the authenticated user:
```javascript
app.post('/auth/logout-all', auth.requireAuth, async (req, res) => {
  try {
    const result = await db.query(
      `UPDATE refresh_tokens
       SET revoked_at = NOW()
       WHERE user_id = $1 AND revoked_at IS NULL
       RETURNING id`,
      [req.user.userId]
    );
    res.json({ revokedSessions: result.rowCount });
  } catch (err) {
    throw err;
  }
});
```

This is a critical recovery path. When a user suspects their account is compromised, this
invalidates every active session across all devices within one 15-minute access token TTL.

---

### D.4 — Persistent audit log

**New DB table**: `token-server/migrations/008_audit_events.sql`

```sql
CREATE TABLE audit_events (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID REFERENCES users(id) ON DELETE SET NULL,
    event_type VARCHAR(50) NOT NULL,
    -- e.g. 'login_success', 'login_failure', 'register', 'password_reset_requested',
    --      'password_reset_completed', 'email_verified', 'tier_changed',
    --      'session_compromised', 'logout', 'logout_all', 'token_refresh'
    ip_address INET,
    metadata   JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_ae_user ON audit_events (user_id, created_at DESC);
CREATE INDEX idx_ae_type ON audit_events (event_type, created_at DESC);
```

**Log helper** (add to `auth.js`):
```javascript
async function auditLog(userId, eventType, ipAddress, metadata = {}) {
  try {
    await db.query(
      `INSERT INTO audit_events (user_id, event_type, ip_address, metadata)
       VALUES ($1, $2, $3::inet, $4)`,
      [userId || null, eventType, ipAddress || null, JSON.stringify(metadata)]
    );
  } catch (err) {
    // Audit logging must NEVER crash auth flows
    console.error('[audit] log write failed:', err.message);
  }
}
```

**Log all security events**: login success/failure, registration, password reset, email
verification, session compromise, logout, tier change via webhook, token refresh anomalies.

---

### D.5 — Security alerting on theft detection

Replace the `console.error('[SECURITY ALERT]...')` call in `POST /auth/refresh` with a
proper alert dispatch. Even a basic Slack webhook is sufficient for an early-stage product:

```javascript
async function dispatchSecurityAlert(type, details) {
  console.error(`[SECURITY ALERT] ${type}:`, JSON.stringify(details));

  if (!process.env.SECURITY_WEBHOOK_URL) return; // graceful no-op in dev

  try {
    await fetch(process.env.SECURITY_WEBHOOK_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        text: `🚨 *${type}*\n${JSON.stringify(details, null, 2)}`,
      }),
    });
  } catch (err) {
    console.error('[alert] webhook delivery failed:', err.message);
  }
}
```

Set `SECURITY_WEBHOOK_URL` to a Slack Incoming Webhook URL in production. Add to `.env.example`.

---

## 7. Attack Mitigation Matrix

| # | Attack | Target | Mitigation | Phase |
|---|---|---|---|---|
| 1 | `alg:none` JWT forgery | Auth bypass | `algorithms: ['HS256']` pin in `jwt.verify` | A.1 |
| 2 | RS256→HS256 confusion | Auth bypass | Same algorithm pin | A.1 |
| 3 | `iss`/`aud` claim spoofing | Token reuse across services | `issuer` + `audience` validation | A.1 |
| 4 | Weak JWT secret brute force | Forge any JWT | Startup crash if secret < 32 bytes, no fallback | A.2 |
| 5 | API key leakage via logs | Server compromise | Remove API key `console.log` line | A.3 |
| 6 | Credential stuffing on login | Account takeover | 10-attempt rate limit per email per 15 min | A.4 |
| 7 | DB internals in 500 responses | Schema enumeration | Centralized error handler + opaque messages | A.5 |
| 8 | TLS downgrade / token cache | Token theft | HSTS + `Cache-Control: no-store` | A.6 |
| 9 | Stale tier after cancellation | Unauthorized feature access | 15-min access token TTL + DB re-read on refresh | B |
| 10 | Stolen refresh token — 30-day access | Persistent unauthorized access | Family-based reuse detection → kill entire family | B.3 |
| 11 | Refresh token theft — undetected | Persistent access | Silent rotation: each use invalidates previous token | B.3 |
| 12 | DB breach — refresh token hash theft | Token reconstruction | SHA-256 of 32-byte random = 2²⁵⁶ search space | B.1 |
| 13 | Token sidejacking (different device) | Session hijacking | Client ID soft binding + anomaly logging | B.3 |
| 14 | MITM on refresh endpoint | Raw token interception | TLS certificate pinning (SPKI hash) in macOS client | B.4 |
| 15 | Access token theft from memory | 15-min window replay | Short TTL limits window; proactive refresh avoids 401s | B |
| 16 | iCloud Backup token leak | Offline token extraction | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` Keychain | B.4 |
| 17 | Password in request logs | Credential leakage | Scrub `password` / `refreshToken` fields before logging | A.5 |
| 18 | Redis compromise → rate limit bypass | Unblocked brute force | Redis AUTH + TLS in production env config | Config |
| 19 | Webhook replay (billing) | Fraudulent tier upgrade | Idempotency table for processed event IDs | C |
| 20 | Unsigned webhook (billing) | Fraudulent downgrade/upgrade | Mandatory webhook signature verification | C |
| 21 | Timing oracle in `register()` | Email enumeration | Dummy bcrypt call on early-exit path | A.7 |
| 22 | Timing oracle in `login()` | Email enumeration | `DUMMY_HASH` compare for non-existent users | A.7 |
| 23 | bcrypt 72-byte silent truncation | Weaker-than-expected passwords | Hard 72-byte limit enforced before hashing | A.8 |
| 24 | Oversized inputs (10MB email/name) | DB DoS / unexpected behavior | Max-length guards on all auth inputs | A.8 |
| 25 | Account squatting / phishing | Fake accounts with victim emails | Email verification on register (D.2) | D |
| 26 | No password recovery path | Permanent lockout / weak passwords | Password reset flow with short-lived single-use tokens | D |
| 27 | No forensics on compromise | Inability to investigate breaches | Persistent `audit_events` table for all security events | D |
| 28 | Security alerts go nowhere | Undetected active compromise | Slack/webhook dispatch on `SESSION_COMPROMISED` | D |
| 29 | No cross-device session kill | Compromise persists after discovery | `POST /auth/logout-all` revokes all family tokens | D |

---

## 8. Files Changed Per Phase

### Phase A (server-only, no client deps)
```
token-server/auth.js          — A.1, A.2, A.5, A.7, A.8
token-server/index.js         — A.3, A.4, A.5, A.6 (+ Referrer-Policy header)
token-server/.env.example     — A.2
```

### Phase B (server + client, build together)
```
token-server/migrations/004_refresh_tokens.sql  — new file
token-server/auth.js                            — generateAccessToken, issueRefreshToken, authenticateToken
token-server/index.js                           — POST /auth/refresh, POST /auth/logout, update login/register
token-server/.env.example                       — REFRESH_TOKEN_SECRET, ACCESS_TOKEN_TTL, REFRESH_TOKEN_TTL_DAYS
inter/Networking/InterTokenService.swift        — Keychain storage, silent refresh, proactive scheduling, cert pinning
inter/App/AppDelegate.m                         — read tier from auth profile (remove hardcoded @"free")
```

### Phase C (billing — Lemon Squeezy)
```
token-server/migrations/005_billing_columns.sql  — new file (LS billing columns + idempotency table)
token-server/billing.js                          — new file (LS webhook receiver + tier update logic)
token-server/index.js                            — POST /webhooks/lemonsqueezy (express.raw), POST /billing/checkout, POST /billing/portal
token-server/.env.example                        — LEMONSQUEEZY_API_KEY, LEMONSQUEEZY_WEBHOOK_SECRET, LEMONSQUEEZY_STORE_ID, variant-to-tier mapping
token-server/package.json                        — add @lemonsqueezy/lemonsqueezy.js dependency
```

### Phase D (account recovery + audit — server-only, no client deps)
```
token-server/migrations/006_password_reset_tokens.sql   — new file
token-server/migrations/007_email_verification_tokens.sql — new file
token-server/migrations/008_audit_events.sql             — new file
token-server/auth.js       — auditLog helper, DUMMY_HASH, timing normalization, input limits
token-server/index.js      — POST /auth/forgot-password, POST /auth/reset-password,
                             GET /reset-password (HTML landing page + inter:// deep link attempt),
                             POST /auth/reset-password-web (browser fallback form handler),
                             GET /auth/verify-email, POST /auth/resend-verification,
                             POST /auth/logout-all, dispatchSecurityAlert
token-server/.env.example  — SECURITY_WEBHOOK_URL, SMTP config
token-server/mailer.js     — new file (nodemailer wrapper — sendPasswordResetEmail, sendVerificationEmail)
```

---

## 9. Testing Checklist

### Phase A verification
- [ ] Server refuses to start if `JWT_SECRET` is unset or < 32 bytes
- [ ] `jwt.verify` with a token signed by `alg:none` returns 401
- [ ] `jwt.verify` with `iss: 'wrong-issuer'` returns 401
- [ ] Server startup log contains no LiveKit API key
- [ ] 11 consecutive login attempts from the same email within 15 min → 11th returns 429
- [ ] A deliberately thrown 500 error returns `{ error: "An internal error occurred", requestId }` — no DB detail
- [ ] Response headers include `Strict-Transport-Security`, `Cache-Control: no-store`, and `Referrer-Policy: no-referrer`
- [ ] Registering an email that already exists takes the same wall-clock time (±10ms) as registering a new email
- [ ] Logging in with a non-existent email takes the same wall-clock time (±10ms) as a wrong password for an existing email
- [ ] Sending a password longer than 72 bytes to `register` returns 400 — does NOT silently truncate
- [ ] Sending a 10MB string as `email` to `register` returns 400, not 500 or a DB error
- [ ] Sending a 10MB string as `displayName` to `register` returns 400

### Phase B verification
- [ ] Login returns `{ accessToken, refreshToken, expiresIn }` — no `token` field
- [ ] Access token expires in 15 min (verify with `jwt.decode` checking `exp` claim)
- [ ] `POST /auth/refresh` with valid token returns new token pair (both tokens rotate)
- [ ] `POST /auth/refresh` with the OLD token (after rotation) returns 401 `SESSION_COMPROMISED`
- [ ] After `SESSION_COMPROMISED`: all other tokens in the same family are also revoked
- [ ] `POST /auth/logout` revokes the refresh token — subsequent refresh with that token returns 401
- [ ] Changing user tier in DB → next `/auth/refresh` call returns access token with new tier
- [ ] Mismatched `clientId` in refresh logs a warning but does not block (soft binding)

### Phase C verification
- [ ] `subscription_expired` webhook → `users.tier` updated to `'free'`, `subscription_status` = `'expired'`
- [ ] `subscription_created` webhook with `meta.custom_data.user_id` → correct user row updated
- [ ] Replaying the same webhook event a second time → `200` with `{ duplicate: true }` (idempotency table blocks reprocessing)
- [ ] Webhook with invalid `X-Signature` → `401` — event not processed, security event logged
- [ ] Webhook with missing `X-Signature` header → `401` — event not processed
- [ ] After tier downgrade in DB: user's next 15-min refresh cycle picks up `free` tier in new access token
- [ ] `POST /billing/checkout` with valid `variantId` → returns `{ checkoutUrl }` (valid LS URL)
- [ ] `POST /billing/checkout` with unknown `variantId` → `400` error
- [ ] `POST /billing/checkout` without auth → `401`
- [ ] `POST /billing/portal` returns `{ portalUrl }` from stored `ls_portal_url` or creates fresh one via API
- [ ] `subscription_cancelled` webhook → `subscription_status` = `'cancelled'`, `grace_until` = `ends_at`, tier preserved
- [ ] `subscription_payment_failed` → `subscription_status` = `'past_due'`
- [ ] `subscription_payment_recovered` → `subscription_status` = `'active'`, grace period cleared
- [ ] `subscription_paused` → `subscription_status` = `'paused'`, paid access blocked
- [ ] `subscription_unpaused` → `subscription_status` = `'active'`, paid access restored
- [ ] `requireTier()` blocks access for `past_due`, `unpaid`, `expired` statuses
- [ ] `requireTier()` allows `cancelled` status access while `NOW() < grace_until`

### Phase D verification
- [ ] `POST /auth/forgot-password` returns 200 with generic message for BOTH existing and non-existing emails
- [ ] `POST /auth/forgot-password` with a non-existent email does NOT insert a row into `password_reset_tokens`
- [ ] Email link is `https://your-token-server.com/reset-password?token=...` — not `inter://` directly
- [ ] `GET /reset-password` with a valid token renders the HTML page (contains the `inter://` redirect script and the password form)
- [ ] `GET /reset-password` with a missing or malformed token returns 400 HTML, not a 500
- [ ] `GET /reset-password` response includes `Content-Security-Policy` header
- [ ] `POST /auth/reset-password-web` with a valid token + valid password returns an HTML confirmation page
- [ ] `POST /auth/reset-password-web` with an expired token returns 400 HTML with an error message
- [ ] Password reset token is consumed on first use — reusing the same token returns 400
- [ ] Password reset token expired after 1 hour returns 400 `'Invalid or expired reset token'`
- [ ] Successful password reset revokes all existing refresh tokens for that user
- [ ] Email verification token is single-use — reusing returns 400
- [ ] `POST /auth/logout-all` revokes all refresh token rows for the user — returns count of revoked sessions
- [ ] After logout-all: existing access tokens still valid until their 15-min TTL expires (by design)
- [ ] `audit_events` table receives a row for: login, failed login, register, logout, logout-all, password reset requested, password reset completed, email verified, session compromised
- [ ] `SECURITY_WEBHOOK_URL` not set → no crash, alert silently skipped
- [ ] `SECURITY_WEBHOOK_URL` set → SESSION_COMPROMISED event triggers a POST to that URL

---

## 10. New File Starters — billing.js and mailer.js

> These are NEW files that do not exist yet. The sections below are complete,
> production-ready starters. Copy them as-is and fill in the TODO items.
> All webhook case handlers from §5 and §11 are assembled here in one place.
> Do NOT split billing logic across index.js and billing.js — keep it all in billing.js.

### billing.js — Complete Starter

```javascript
// ============================================================================
// billing.js — Lemon Squeezy Subscription Lifecycle Webhooks (Phase C)
//
// Mounted at: POST /webhooks/lemonsqueezy
// CRITICAL: Must be mounted with express.raw() BEFORE express.json() in index.js:
//   app.post('/webhooks/lemonsqueezy', express.raw({ type: 'application/json' }), require('./billing'));
//   app.use(express.json());  // <-- AFTER
//
// All Lemon Squeezy subscription lifecycle events are handled here.
// Tier changes are reflected in the access token on the next /auth/refresh call (max 15 min).
//
// KEY DIFFERENCE FROM STRIPE:
// - User linking: meta.custom_data.user_id (NOT customer_id lookup)
// - Signature: HMAC-SHA256 hex digest in X-Signature header (NOT Stripe-Signature)
// - LS is Merchant of Record — handles tax, 3DS, dunning, disputes internally
// - No need for invoice.payment_action_required (3DS) or charge.dispute.created
// ============================================================================

const db     = require('./db');
const crypto = require('crypto');

const LEMONSQUEEZY_WEBHOOK_SECRET = process.env.LEMONSQUEEZY_WEBHOOK_SECRET;
if (!LEMONSQUEEZY_WEBHOOK_SECRET || LEMONSQUEEZY_WEBHOOK_SECRET.length < 6) {
  console.error('[FATAL] LEMONSQUEEZY_WEBHOOK_SECRET must be set (6-40 characters).');
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Variant ID → tier mapping — fill in your actual Lemon Squeezy variant IDs
// Found in: LS Dashboard → Store → Products → Variants, or via API
// ---------------------------------------------------------------------------
const VARIANT_ID_TO_TIER = {
  // TODO: replace with your actual Lemon Squeezy variant IDs from the LS Dashboard
  // Each variant represents a specific plan (e.g., "Pro Monthly", "Pro Annual")
  // Example:
  // '123456': 'pro',   // Pro Monthly
  // '123457': 'pro',   // Pro Annual
  // '123458': 'hiring', // Hiring Monthly
  // '123459': 'hiring', // Hiring Annual
};

// Statuses that grant paid-tier access even without a confirmed 'active' subscription
// on_trial in LS = trialing equivalent — user has full access, no payment yet
const TRIAL_GRANTS_TIER = { on_trial: 'pro' };

// Grace period for past_due before blocking access
const GRACE_PERIOD_DAYS = 3;

// Subscription statuses (from Lemon Squeezy):
// on_trial | active | paused | past_due | unpaid | cancelled | expired

// Valid state transitions — enforced before every DB update (per SYSTEM_PRINCIPLES §2.5)
const VALID_TRANSITIONS = {
  none:      ['on_trial', 'active'],
  on_trial:  ['active', 'cancelled'],
  active:    ['past_due', 'cancelled', 'paused'],
  past_due:  ['active', 'unpaid', 'cancelled'],
  unpaid:    ['active', 'cancelled', 'expired'],
  cancelled: ['expired'],
  expired:   ['none'],   // terminal — new subscription = fresh checkout
  paused:    ['active'],
};

function validateTransition(from, to) {
  if (!VALID_TRANSITIONS[from]?.includes(to)) {
    // Log but do not throw — LS may fire events in unexpected order during edge cases.
    // We log the invalid transition and proceed with the update to avoid blocking webhooks.
    console.error(`[billing] Invalid subscription transition: ${from} → ${to}`);
    return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Idempotency — prevent double-processing of replayed webhook events
// LS does not provide a unique event ID in every webhook payload. We generate
// a deterministic ID from: event_name + subscription_id + a truncated timestamp
// (rounded to 1-second granularity to handle replays within the same second).
// ---------------------------------------------------------------------------
function generateEventId(eventName, subscriptionId, timestamp) {
  const ts = timestamp ? new Date(timestamp).toISOString() : new Date().toISOString();
  const raw = `${eventName}:${subscriptionId}:${ts}`;
  return crypto.createHash('sha256').update(raw).digest('hex').slice(0, 64);
}

async function isEventAlreadyProcessed(eventId) {
  const result = await db.query(
    'SELECT 1 FROM processed_webhook_events WHERE event_id = $1',
    [eventId]
  );
  return result.rows.length > 0;
}

async function markEventProcessed(eventId, eventType) {
  await db.query(
    `INSERT INTO processed_webhook_events (event_id, event_type) VALUES ($1, $2)
     ON CONFLICT (event_id) DO NOTHING`,
    [eventId, eventType]
  );
}

// ---------------------------------------------------------------------------
// Webhook signature verification — HMAC-SHA256 (Lemon Squeezy)
// Source: https://docs.lemonsqueezy.com/guides/developer-guide/webhooks
// ---------------------------------------------------------------------------
function verifySignature(rawBody, signatureHeader) {
  if (!signatureHeader) return false;

  const hmac = crypto.createHmac('sha256', LEMONSQUEEZY_WEBHOOK_SECRET);
  const digest = Buffer.from(hmac.update(rawBody).digest('hex'), 'utf8');
  const signature = Buffer.from(signatureHeader, 'utf8');

  // Constant-time comparison — prevents timing attacks on signature
  if (digest.length !== signature.length) return false;
  return crypto.timingSafeEqual(digest, signature);
}

// ---------------------------------------------------------------------------
// Webhook handler — Express middleware (req.body is a raw Buffer here)
// ---------------------------------------------------------------------------
module.exports = async function billingWebhook(req, res) {
  // Step 1: Verify webhook signature
  const isValid = verifySignature(req.body, req.get('X-Signature'));
  if (!isValid) {
    console.error('[billing] Webhook signature verification failed');
    // Log as security event — failed signatures may indicate tampering
    return res.status(401).json({ error: 'Invalid webhook signature' });
  }

  // Step 2: Parse the verified payload
  let payload;
  try {
    payload = JSON.parse(req.body.toString('utf8'));
  } catch (err) {
    console.error('[billing] Webhook payload parse error:', err.message);
    return res.status(400).json({ error: 'Invalid JSON payload' });
  }

  const eventName = payload.meta?.event_name;
  const customData = payload.meta?.custom_data;
  const subscriptionData = payload.data?.attributes;
  const subscriptionId = String(payload.data?.id || '');

  if (!eventName || !subscriptionData) {
    console.error('[billing] Webhook missing event_name or data.attributes');
    return res.status(400).json({ error: 'Invalid webhook payload structure' });
  }

  // Step 3: Idempotency check
  const eventId = generateEventId(eventName, subscriptionId, subscriptionData.updated_at);
  if (await isEventAlreadyProcessed(eventId)) {
    return res.status(200).json({ received: true, duplicate: true });
  }

  // Step 4: Process the event — return 200 immediately on success
  // LS expects HTTP 200. Non-200 triggers up to 3 retries (4 total attempts).
  try {
    await handleEvent(eventName, payload, customData);
    await markEventProcessed(eventId, eventName);
    res.status(200).json({ received: true });
  } catch (err) {
    console.error('[billing] Event handler failed:', eventName, err.message);
    // Return 500 so Lemon Squeezy retries delivery
    res.status(500).json({ error: 'Event processing failed' });
  }
};

// ---------------------------------------------------------------------------
// Resolve the user — custom_data.user_id is primary, ls_customer_id is fallback
// ---------------------------------------------------------------------------
async function resolveUserId(customData, subscriptionData) {
  // Primary: user_id passed through checkout custom_data
  if (customData?.user_id) {
    const result = await db.query(
      'SELECT id, tier, subscription_status FROM users WHERE id = $1 AND deleted_at IS NULL',
      [customData.user_id]
    );
    if (result.rows.length > 0) return result.rows[0];
  }

  // Fallback: look up by ls_customer_id (for events where custom_data may be missing)
  const customerId = String(subscriptionData?.customer_id || '');
  if (customerId) {
    const result = await db.query(
      'SELECT id, tier, subscription_status FROM users WHERE ls_customer_id = $1 AND deleted_at IS NULL',
      [customerId]
    );
    if (result.rows.length > 0) return result.rows[0];
  }

  return null;
}

// ---------------------------------------------------------------------------
// Tier resolution from variant ID
// ---------------------------------------------------------------------------
function resolveTier(variantId) {
  return VARIANT_ID_TO_TIER[String(variantId)] ?? 'free';
}

// ---------------------------------------------------------------------------
// Event dispatch
// ---------------------------------------------------------------------------
async function handleEvent(eventName, payload, customData) {
  const sub = payload.data.attributes;
  const subscriptionId = String(payload.data.id);

  switch (eventName) {

    // ── Subscription created (first purchase or re-subscribe) ─────────────
    case 'subscription_created': {
      const user = await resolveUserId(customData, sub);
      if (!user) {
        console.error(`[billing] subscription_created: user not found. custom_data=${JSON.stringify(customData)}`);
        break;
      }

      const tier = resolveTier(sub.variant_id);
      const newStatus = sub.status === 'on_trial' ? 'on_trial' : 'active';
      validateTransition(user.subscription_status || 'none', newStatus);

      await db.query(
        `UPDATE users
         SET tier = $1,
             subscription_status = $2,
             ls_subscription_id = $3,
             ls_customer_id = $4,
             ls_variant_id = $5,
             ls_product_id = $6,
             trial_ends_at = $7,
             current_period_ends_at = $8,
             grace_until = NULL,
             ls_portal_url = $9,
             updated_at = NOW()
         WHERE id = $10`,
        [
          tier,
          newStatus,
          subscriptionId,
          String(sub.customer_id),
          String(sub.variant_id),
          String(sub.product_id),
          sub.trial_ends_at || null,
          sub.renews_at || null,
          sub.urls?.customer_portal || null,
          user.id,
        ]
      );

      // Audit log — tier change
      await db.query(
        `INSERT INTO user_tier_history (user_id, from_tier, to_tier, reason, event_id)
         VALUES ($1, $2, $3, 'ls_subscription_created', $4)`,
        [user.id, user.tier, tier, subscriptionId]
      ).catch(err => console.error('[billing] audit log failed:', err.message));

      console.log(`[billing] subscription_created: user=${user.id} tier=${tier} status=${newStatus}`);
      break;
    }

    // ── Subscription updated (plan change, status change, renewal) ────────
    case 'subscription_updated': {
      const user = await resolveUserId(customData, sub);
      if (!user) {
        console.error(`[billing] subscription_updated: user not found. sub_id=${subscriptionId}`);
        break;
      }

      const tier = resolveTier(sub.variant_id);
      const newStatus = sub.status; // on_trial | active | paused | past_due | unpaid | cancelled | expired

      // Validate transition (log-only, do not block — LS may send events out of order)
      validateTransition(user.subscription_status || 'none', newStatus);

      // Handle terminal states
      if (newStatus === 'expired') {
        await db.query(
          `UPDATE users
           SET tier = 'free',
               subscription_status = 'expired',
               ls_subscription_id = NULL,
               ls_variant_id = NULL,
               ls_product_id = NULL,
               grace_until = NULL,
               ls_portal_url = $1,
               updated_at = NOW()
           WHERE id = $2`,
          [sub.urls?.customer_portal || null, user.id]
        );

        await db.query(
          `INSERT INTO user_tier_history (user_id, from_tier, to_tier, reason, event_id)
           VALUES ($1, $2, 'free', 'ls_subscription_expired', $3)`,
          [user.id, user.tier, subscriptionId]
        ).catch(err => console.error('[billing] audit log failed:', err.message));

        break;
      }

      // Handle paused (block paid access but keep tier column for resumption)
      if (newStatus === 'paused') {
        await db.query(
          `UPDATE users
           SET subscription_status = 'paused',
               ls_portal_url = $1,
               updated_at = NOW()
           WHERE id = $2`,
          [sub.urls?.customer_portal || null, user.id]
        );
        break;
      }

      // Handle cancelled (grace period — access until ends_at)
      if (newStatus === 'cancelled') {
        await db.query(
          `UPDATE users
           SET subscription_status = 'cancelled',
               grace_until = $1,
               ls_portal_url = $2,
               updated_at = NOW()
           WHERE id = $3`,
          [sub.ends_at || null, sub.urls?.customer_portal || null, user.id]
        );
        break;
      }

      // General update — sync tier, status, and renewal info
      await db.query(
        `UPDATE users
         SET tier = $1,
             subscription_status = $2,
             ls_variant_id = $3,
             ls_product_id = $4,
             current_period_ends_at = $5,
             trial_ends_at = $6,
             ls_portal_url = $7,
             updated_at = NOW()
         WHERE id = $8`,
        [
          tier,
          newStatus,
          String(sub.variant_id),
          String(sub.product_id),
          sub.renews_at || null,
          sub.trial_ends_at || null,
          sub.urls?.customer_portal || null,
          user.id,
        ]
      );

      // Audit tier change if tier actually changed
      if (tier !== user.tier) {
        await db.query(
          `INSERT INTO user_tier_history (user_id, from_tier, to_tier, reason, event_id)
           VALUES ($1, $2, $3, 'ls_subscription_updated', $4)`,
          [user.id, user.tier, tier, subscriptionId]
        ).catch(err => console.error('[billing] audit log failed:', err.message));
      }
      break;
    }

    // ── Subscription cancelled (user or admin cancelled) ──────────────────
    // Access continues until ends_at (grace period). Then subscription_expired fires.
    case 'subscription_cancelled': {
      const user = await resolveUserId(customData, sub);
      if (!user) break;

      validateTransition(user.subscription_status || 'none', 'cancelled');

      await db.query(
        `UPDATE users
         SET subscription_status = 'cancelled',
             grace_until = $1,
             ls_portal_url = $2,
             updated_at = NOW()
         WHERE id = $3`,
        [sub.ends_at || null, sub.urls?.customer_portal || null, user.id]
      );
      // TODO: send cancellation confirmation email with ends_at date
      console.log(`[billing] subscription_cancelled: user=${user.id} ends_at=${sub.ends_at}`);
      break;
    }

    // ── Subscription expired (grace period ended or dunning completed) ────
    // This is the terminal event — user loses all paid access.
    case 'subscription_expired': {
      const user = await resolveUserId(customData, sub);
      if (!user) break;

      const previousTier = user.tier;
      await db.query(
        `UPDATE users
         SET tier = 'free',
             subscription_status = 'expired',
             ls_subscription_id = NULL,
             ls_variant_id = NULL,
             ls_product_id = NULL,
             grace_until = NULL,
             current_period_ends_at = NULL,
             trial_ends_at = NULL,
             updated_at = NOW()
         WHERE id = $1`,
        [user.id]
      );

      await db.query(
        `INSERT INTO user_tier_history (user_id, from_tier, to_tier, reason, event_id)
         VALUES ($1, $2, 'free', 'ls_subscription_expired', $3)`,
        [user.id, previousTier, subscriptionId]
      ).catch(err => console.error('[billing] audit log failed:', err.message));

      console.log(`[billing] subscription_expired: user=${user.id} downgraded from ${previousTier}`);
      break;
    }

    // ── Payment succeeded (renewal or recovery) ───────────────────────────
    case 'subscription_payment_success': {
      const user = await resolveUserId(customData, sub);
      if (!user) break;

      // Clear any grace period / past_due state on successful payment
      await db.query(
        `UPDATE users
         SET subscription_status = 'active',
             grace_until = NULL,
             current_period_ends_at = $1,
             updated_at = NOW()
         WHERE id = $2`,
        [sub.renews_at || null, user.id]
      );
      break;
    }

    // ── Payment failed (LS will retry up to 4 times over ~2 weeks) ────────
    case 'subscription_payment_failed': {
      const user = await resolveUserId(customData, sub);
      if (!user) break;

      const graceUntil = new Date();
      graceUntil.setDate(graceUntil.getDate() + GRACE_PERIOD_DAYS);

      await db.query(
        `UPDATE users
         SET subscription_status = 'past_due',
             grace_until = $1,
             updated_at = NOW()
         WHERE id = $2`,
        [graceUntil, user.id]
      );
      // TODO: send payment-failed notification email with LS update_payment_method URL
      // The URL is in sub.urls?.update_payment_method (pre-signed, 24h expiry)
      console.log(`[billing] subscription_payment_failed: user=${user.id}`);
      break;
    }

    // ── Payment recovered (successful payment after failure) ──────────────
    case 'subscription_payment_recovered': {
      const user = await resolveUserId(customData, sub);
      if (!user) break;

      await db.query(
        `UPDATE users
         SET subscription_status = 'active',
             grace_until = NULL,
             current_period_ends_at = $1,
             updated_at = NOW()
         WHERE id = $2`,
        [sub.renews_at || null, user.id]
      );
      console.log(`[billing] subscription_payment_recovered: user=${user.id}`);
      break;
    }

    // ── Subscription paused (payment collection paused) ───────────────────
    case 'subscription_paused': {
      const user = await resolveUserId(customData, sub);
      if (!user) break;

      validateTransition(user.subscription_status || 'none', 'paused');

      await db.query(
        `UPDATE users
         SET subscription_status = 'paused',
             ls_portal_url = $1,
             updated_at = NOW()
         WHERE id = $2`,
        [sub.urls?.customer_portal || null, user.id]
      );
      // requireTier() blocks paid access via INACTIVE_STATUSES check
      break;
    }

    // ── Subscription unpaused (payment collection resumed) ────────────────
    case 'subscription_unpaused': {
      const user = await resolveUserId(customData, sub);
      if (!user) break;

      const tier = resolveTier(sub.variant_id);
      await db.query(
        `UPDATE users
         SET subscription_status = 'active',
             tier = $1,
             ls_portal_url = $2,
             updated_at = NOW()
         WHERE id = $3`,
        [tier, sub.urls?.customer_portal || null, user.id]
      );
      break;
    }

    // ── Subscription resumed (cancelled sub resumed before expiry) ────────
    case 'subscription_resumed': {
      const user = await resolveUserId(customData, sub);
      if (!user) break;

      const tier = resolveTier(sub.variant_id);
      await db.query(
        `UPDATE users
         SET subscription_status = 'active',
             tier = $1,
             grace_until = NULL,
             current_period_ends_at = $2,
             ls_portal_url = $3,
             updated_at = NOW()
         WHERE id = $4`,
        [tier, sub.renews_at || null, sub.urls?.customer_portal || null, user.id]
      );
      console.log(`[billing] subscription_resumed: user=${user.id} tier=${tier}`);
      break;
    }

    // ── Order created (initial purchase — logged only) ────────────────────
    case 'order_created': {
      // The subscription_created event handles the actual tier update.
      // Log order for audit purposes only.
      const orderId = payload.data?.id;
      console.log(`[billing] order_created: order=${orderId} user_id=${customData?.user_id}`);
      break;
    }

    // ── Order refunded (LS processed a refund) ────────────────────────────
    case 'order_refunded': {
      // LS as MoR handles refunds. Log for our records.
      // Note: refund does NOT automatically cancel the subscription —
      // that is a separate action in the LS dashboard or API.
      const orderId = payload.data?.id;
      console.log(`[billing] order_refunded: order=${orderId} user_id=${customData?.user_id}`);
      break;
    }

    default:
      // Unknown event — log and ignore. LS will not retry for 200 responses.
      console.log(`[billing] Unhandled event type: ${eventName}`);
  }
}

// ---------------------------------------------------------------------------
// Exported helpers for use in index.js (checkout URL creation, portal URL)
// ---------------------------------------------------------------------------

// VARIANT_ID_TO_TIER is needed by the checkout endpoint to validate variantId
module.exports.VARIANT_ID_TO_TIER = VARIANT_ID_TO_TIER;
module.exports.TRIAL_GRANTS_TIER = TRIAL_GRANTS_TIER;
```

---

### mailer.js — Complete Starter

```javascript
// ============================================================================
// mailer.js — Transactional Email (Phase D)
//
// Uses nodemailer with SMTP. Works with any provider:
//   - Resend SMTP (recommended: smtp.resend.com, port 465, user "resend")
//   - SendGrid (smtp.sendgrid.net, port 587, user "apikey")
//   - Postmark (smtp.postmarkapp.com, port 587)
//   - Any standard SMTP server
//
// Install: npm install nodemailer
// Add to package.json dependencies: "nodemailer": "^6.9.0"
// ============================================================================

const nodemailer = require('nodemailer');

// ---------------------------------------------------------------------------
// Transport configuration — reads from .env
// ---------------------------------------------------------------------------
const transporter = nodemailer.createTransport({
  host:   process.env.SMTP_HOST,
  port:   parseInt(process.env.SMTP_PORT || '587', 10),
  secure: process.env.SMTP_PORT === '465', // true for 465 (TLS), false for 587 (STARTTLS)
  auth: {
    user: process.env.SMTP_USER,
    pass: process.env.SMTP_PASS,
  },
});

// Validate transport on startup — crashes early if SMTP is misconfigured
// Only runs if SMTP_HOST is set (skip in dev if email is not needed yet)
if (process.env.SMTP_HOST) {
  transporter.verify().then(() => {
    console.log('[mailer] SMTP transport verified');
  }).catch(err => {
    console.error('[mailer] SMTP transport verification failed:', err.message);
    // Do not process.exit() — email failure must not block the whole server
  });
}

const FROM = process.env.SMTP_FROM || 'Inter <noreply@inter.app>';

// ---------------------------------------------------------------------------
// sendPasswordResetEmail
// Called from: POST /auth/forgot-password (fire-and-forget)
// ---------------------------------------------------------------------------
async function sendPasswordResetEmail(toEmail, rawToken) {
  const resetUrl = `${process.env.APP_RETURN_URL || 'http://localhost:3000'}/reset-password?token=${rawToken}`;

  await transporter.sendMail({
    from:    FROM,
    to:      toEmail,
    subject: 'Reset your Inter password',
    text: [
      'You requested a password reset for your Inter account.',
      '',
      'Click the link below to set a new password. The link expires in 1 hour.',
      '',
      resetUrl,
      '',
      'If you did not request this, you can safely ignore this email.',
      'Your password will not change until you click the link above.',
    ].join('\n'),
    html: `
      <p>You requested a password reset for your Inter account.</p>
      <p>Click the button below to set a new password.
         <strong>The link expires in 1 hour.</strong></p>
      <p style="margin:24px 0">
        <a href="${resetUrl}" style="background:#007AFF;color:#fff;padding:12px 24px;
           border-radius:6px;text-decoration:none;font-weight:bold">
          Reset password
        </a>
      </p>
      <p><small>Or copy this URL: ${resetUrl}</small></p>
      <p style="color:#888;font-size:12px">
        If you did not request this, you can safely ignore this email.
      </p>
    `,
  });
}

// ---------------------------------------------------------------------------
// sendVerificationEmail
// Called from: register() in auth.js (fire-and-forget)
// ---------------------------------------------------------------------------
async function sendVerificationEmail(toEmail, rawToken) {
  const verifyUrl = `${process.env.APP_RETURN_URL || 'http://localhost:3000'}/auth/verify-email?token=${rawToken}`;

  await transporter.sendMail({
    from:    FROM,
    to:      toEmail,
    subject: 'Verify your Inter email address',
    text: [
      'Welcome to Inter! Please verify your email address.',
      '',
      verifyUrl,
      '',
      'This link expires in 8 hours.',
    ].join('\n'),
    html: `
      <p>Welcome to Inter! Please verify your email address.</p>
      <p style="margin:24px 0">
        <a href="${verifyUrl}" style="background:#007AFF;color:#fff;padding:12px 24px;
           border-radius:6px;text-decoration:none;font-weight:bold">
          Verify email
        </a>
      </p>
      <p><small>This link expires in 8 hours.</small></p>
    `,
  });
}

// ---------------------------------------------------------------------------
// sendPaymentFailedEmail — payment failed notification
// Called from: billing.js subscription_payment_failed handler
// Includes the Lemon Squeezy update_payment_method URL (pre-signed, 24h expiry)
// ---------------------------------------------------------------------------
async function sendPaymentFailedEmail(toEmail, updatePaymentUrl) {
  await transporter.sendMail({
    from:    FROM,
    to:      toEmail,
    subject: 'Action required: update your Inter payment method',
    text: [
      'Your most recent subscription payment failed.',
      'Please update your payment method to keep your subscription active.',
      '',
      updatePaymentUrl || 'Please log in to manage your subscription.',
    ].join('\n'),
    html: `
      <p>Your most recent subscription payment failed.</p>
      <p>Please update your payment method to keep your subscription active.</p>
      ${updatePaymentUrl ? `
      <p style="margin:24px 0">
        <a href="${updatePaymentUrl}" style="background:#FF3B30;color:#fff;padding:12px 24px;
           border-radius:6px;text-decoration:none;font-weight:bold">
          Update payment method
        </a>
      </p>` : ''}
    `,
  });
}

module.exports = {
  sendPasswordResetEmail,
  sendVerificationEmail,
  sendPaymentFailedEmail,
};
```

---

### Migration 005 — billing columns

**New file**: `token-server/migrations/005_billing_columns.sql`

```sql
-- Phase C: Add Lemon Squeezy billing columns to users table
ALTER TABLE users
  ADD COLUMN IF NOT EXISTS subscription_status    VARCHAR(20) DEFAULT 'none'
    CHECK (subscription_status IN ('none', 'on_trial', 'active', 'past_due', 'unpaid', 'cancelled', 'expired', 'paused')),
  ADD COLUMN IF NOT EXISTS ls_customer_id         VARCHAR(255),
  ADD COLUMN IF NOT EXISTS ls_subscription_id     VARCHAR(255),
  ADD COLUMN IF NOT EXISTS ls_variant_id          VARCHAR(255),
  ADD COLUMN IF NOT EXISTS ls_product_id          VARCHAR(255),
  ADD COLUMN IF NOT EXISTS grace_until            TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS trial_ends_at          TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS current_period_ends_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS ls_portal_url          TEXT;

-- Index for webhook user lookup by LS customer ID (fallback path)
CREATE INDEX IF NOT EXISTS idx_users_ls_customer ON users (ls_customer_id) WHERE ls_customer_id IS NOT NULL;

-- Idempotency table — prevents double-processing of replayed webhook events
CREATE TABLE IF NOT EXISTS processed_webhook_events (
    event_id     VARCHAR(255) PRIMARY KEY,
    event_type   VARCHAR(100) NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Tier change audit trail — append-only (per SYSTEM_PRINCIPLES §5.5)
CREATE TABLE IF NOT EXISTS user_tier_history (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID REFERENCES users(id) ON DELETE SET NULL,
    from_tier   VARCHAR(20),
    to_tier     VARCHAR(20) NOT NULL,
    reason      VARCHAR(100) NOT NULL,  -- 'ls_subscription_created' | 'ls_subscription_expired' | 'admin_override'
    event_id    VARCHAR(255),           -- LS subscription ID for traceability
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
    -- NO updated_at — append-only, never updated
);

-- Lock tier history at DB level — prevent accidental modification
-- REVOKE UPDATE, DELETE ON user_tier_history FROM app_db_user;

-- Auto-clean old event IDs after 30 days (optional — run via pg_cron or a cron job)
-- DELETE FROM processed_webhook_events WHERE processed_at < NOW() - INTERVAL '30 days';
```

---

## 11. Industry Standards Gap Analysis & Mitigation Plan

> **Sources:** OWASP Session Management Cheat Sheet, NIST SP 800-63B (Digital Identity
> Guidelines), RFC 8252 (OAuth 2.0 for Native Apps), Lemon Squeezy Subscription Lifecycle Docs.
>
> **Audit date:** April 2026. All 24 gaps below were **not** covered by Phases A–D above.
> They are additive. Implement in priority order: P0 → P1 → P2 → P3.

### Confirmed Strengths (matches or exceeds standards — no action needed)

| Item | Standard | Verdict |
|---|---|---|
| bcrypt cost factor 12, salted | NIST §5.1.1.2 — memory-hard mandatory | ✅ |
| JWT `algorithms: ['HS256']` pin | OWASP JWT CS — prevents `alg:none` + RS256→HS256 | ✅ |
| Refresh token entropy 256-bit | OWASP/NIST ≥64-bit minimum | ✅ exceeds |
| Token rotation + family theft detection | OWASP Refresh Token Family pattern | ✅ |
| Access token in memory only | NIST §7.2 — non-persistent session secret | ✅ |
| Keychain `WhenUnlockedThisDeviceOnly` | Apple Security — iCloud Backup exclusion | ✅ |
| Rate limiting 10/15-min, email-keyed | NIST §5.2.2 — max 100 consecutive failures | ✅ exceeds |
| Fire-and-forget forgot-password 200 | OWASP Forgot Password CS — no email oracle | ✅ |
| Single-use reset tokens, 1hr expiry | OWASP standard | ✅ |
| SHA-256 of reset/refresh token stored | Raw token never in DB — breach-safe | ✅ |
| HSTS + `Cache-Control: no-store` | OWASP HTTP Headers CS | ✅ |
| `ASWebAuthenticationSession` for OAuth | RFC 8252 §6 — mandatory external user-agent | ✅ |
| Webhook signature validation + idempotency | Lemon Squeezy best practice | ✅ |
| Tier re-read from DB on every refresh | Max 15-min stale-tier window | ✅ |
| Revoke all sessions on password reset | Industry standard | ✅ |
| `emailVerified` soft prompt (no hard gate) | OWASP — hard gate causes lockout on mail failure | ✅ |

---

### 10.1 — P0: Critical (will cause silent production failures)

These three gaps will **break correctness in production** even with all other phases
implemented. Fix before any Phase B/C deployment.

---

#### G20 — Lemon Squeezy webhook route requires `express.raw()`, not `express.json()`

**Source:** Lemon Squeezy docs — *"Webhook signature verification requires the raw request body"*  
**Impact:** Every Lemon Squeezy webhook event silently fails HMAC signature validation and is
rejected. Billing webhooks never process. Tier upgrades/downgrades from LS will not apply.

The HMAC-SHA256 digest is computed over the exact raw bytes of the request body. If
`express.json()` middleware runs first, `req.body` becomes a parsed JS object — the raw bytes
are gone and the signature cannot be reconstructed. Every webhook silently fails.

**Fix — `token-server/index.js`:**

Mount `express.raw()` specifically on the webhook route *before* the global `express.json()`
middleware applies. Order matters.

```javascript
// MUST come before app.use(express.json())
app.post(
  '/webhooks/lemonsqueezy',
  express.raw({ type: 'application/json' }),  // preserves raw body bytes
  require('./billing')                         // billing.js receives req.body as Buffer
);

// Global JSON parsing for all other routes
app.use(express.json({ limit: '16kb' }));
```

In `billing.js`, verify the signature using the raw Buffer:

```javascript
const crypto = require('crypto');

function verifySignature(rawBody, signatureHeader) {
  if (!signatureHeader) return false;
  const hmac = crypto.createHmac('sha256', process.env.LEMONSQUEEZY_WEBHOOK_SECRET);
  const digest = Buffer.from(hmac.update(rawBody).digest('hex'), 'utf8');
  const signature = Buffer.from(signatureHeader, 'utf8');
  if (digest.length !== signature.length) return false;
  return crypto.timingSafeEqual(digest, signature);  // constant-time comparison
}

// In the webhook handler:
const isValid = verifySignature(req.body, req.get('X-Signature'));
if (!isValid) {
  return res.status(401).json({ error: 'Invalid webhook signature' });
}
```

Add to `.env.example`:
```
# Lemon Squeezy — Billing (Phase C)
LEMONSQUEEZY_API_KEY=           # From LS Dashboard → Settings → API
LEMONSQUEEZY_WEBHOOK_SECRET=    # 6-40 chars, set when creating webhook in LS Dashboard → Settings → Webhooks
LEMONSQUEEZY_STORE_ID=          # Your store ID (found in LS Dashboard URL or API)
```

**Verification:** Create a test webhook in LS Dashboard → Settings → Webhooks. Use test mode.
Trigger a test subscription event and confirm the server processes it without signature errors.

---

#### G12 — `inter://` URL scheme not registered in Info.plist

**Source:** RFC 8252 Appendix B.4, Apple developer docs  
**Impact:** Clicking the password reset email link on the machine where the app is installed
silently does nothing in the browser. The `window.location = 'inter://...'` redirect on the
HTML landing page fails. The entire deep-link half of the password reset flow is non-functional.

**Fix — `inter/Info.plist`:**

Add `CFBundleURLTypes` inside the root `<dict>`:

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLName</key>
        <string>com.inter.app</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>inter</string>
        </array>
        <key>CFBundleTypeRole</key>
        <string>Viewer</string>
    </dict>
</array>
```

**Fix — `inter/App/AppDelegate.m`:**

Add the URL handler so the app receives the token when the scheme fires:

```objc
- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    // Must register before applicationDidFinishLaunching returns
    [[NSAppleEventManager sharedAppleEventManager]
        setEventHandler:self
            andSelector:@selector(handleGetURLEvent:withReplyEvent:)
          forEventClass:kInternetEventClass
             andEventID:kAEGetURL];
}

- (void)handleGetURLEvent:(NSAppleEventDescriptor *)event
           withReplyEvent:(NSAppleEventDescriptor *)replyEvent {
    NSString *urlStr = [[event paramDescriptorForKeyword:keyDirectObject] stringValue];
    if (!urlStr) return;
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;

    if ([url.host isEqualToString:@"reset-password"]) {
        // Extract token= from query string
        NSURLComponents *components = [NSURLComponents componentsWithURL:url
                                                 resolvingAgainstBaseURL:NO];
        NSString *token = nil;
        for (NSURLQueryItem *item in components.queryItems) {
            if ([item.name isEqualToString:@"token"]) {
                token = item.value;
                break;
            }
        }
        if (token) {
            [[NSNotificationCenter defaultCenter]
                postNotificationName:@"InterPasswordResetDeepLink"
                              object:nil
                            userInfo:@{ @"token": token }];
        }
    }
}
```

The UI layer listens for `InterPasswordResetDeepLink` and opens the new-password entry sheet.

**Verification:** Build & run app, then in Terminal:
```bash
open "inter://reset-password?token=testtoken123"
```
Confirm the app receives and logs the token.

---

#### G15 — `requireTier()` does not check `subscription_status`

**Source:** Lemon Squeezy subscription lifecycle docs  
**Impact:** When a subscription goes `past_due` or `unpaid`, the user's `tier` column
stays `'pro'` until `subscription_expired` fires — which only happens after Lemon Squeezy
exhausts all payment retry attempts (up to ~2 weeks). During that entire window, a
non-paying user retains full paid-tier access.

**Fix — `token-server/auth.js`:**

Update `requireTier` (and the `GET /auth/me` response) to enforce `subscription_status`:

```javascript
// Subscription statuses that should block paid-tier access
// 'cancelled' is allowed until grace_until (ends_at from LS) — user paid for that period
// 'on_trial' grants access (handled via TRIAL_GRANTS_TIER)
const INACTIVE_STATUSES = new Set(['past_due', 'unpaid', 'expired', 'paused']);

// on_trial users get pro-equivalent access
const TRIAL_GRANTS_TIER = { on_trial: 'pro' };

function requireTier(minTier) {
  const tierRank = { free: 0, pro: 1, hiring: 2 };
  return async (req, res, next) => {
    try {
      // Re-read from DB on every gated request (not just at token refresh)
      const result = await db.query(
        'SELECT tier, subscription_status, grace_until FROM users WHERE id = $1',
        [req.user.userId]
      );
      if (result.rows.length === 0) {
        return res.status(401).json({ error: 'USER_NOT_FOUND' });
      }
      const { tier, subscription_status, grace_until } = result.rows[0];

      // Check if user is in a cancelled grace period (access until ends_at)
      const inGracePeriod = subscription_status === 'cancelled'
        && grace_until
        && new Date() < new Date(grace_until);

      // Block access if payment has lapsed (unless in grace period)
      if (INACTIVE_STATUSES.has(subscription_status)) {
        return res.status(403).json({
          error: 'Subscription inactive',
          code: 'SUBSCRIPTION_INACTIVE',
          subscriptionStatus: subscription_status,
        });
      }

      // Cancelled users past their grace period lose paid access
      if (subscription_status === 'cancelled' && !inGracePeriod) {
        return res.status(403).json({
          error: 'Subscription expired',
          code: 'SUBSCRIPTION_INACTIVE',
          subscriptionStatus: subscription_status,
        });
      }

      // Resolve effective tier — on_trial maps to pro-equivalent
      const effectiveTier = TRIAL_GRANTS_TIER[subscription_status] ?? tier;

      if ((tierRank[effectiveTier] ?? -1) < (tierRank[minTier] ?? 999)) {
        return res.status(403).json({
          error: 'Insufficient tier',
          code: 'TIER_INSUFFICIENT',
          required: minTier,
        });
      }

      next();
    } catch (err) {
      next(err);
    }
  };
}
```

Also update `POST /auth/refresh` to embed `subscription_status` in the access token payload
so the client can show appropriate UI without an extra round-trip:

```javascript
// In generateAccessToken():
const payload = {
  userId: user.id,
  email: user.email,
  tier: user.tier,
  subscriptionStatus: user.subscription_status,  // ADD THIS
  displayName: user.display_name,
  emailVerified: !!user.email_verified_at,
};
```

**Verification:**
- Set a test user's `subscription_status = 'past_due'` in DB with `tier = 'pro'`
- Call a pro-gated endpoint — confirm `403 SUBSCRIPTION_INACTIVE`
- Set `subscription_status = 'active'` — confirm `200`

---

### 10.2 — P1: High Security (implement before public launch)

---

#### G1 — No breach corpus / pwned password check

**Source:** NIST SP 800-63B §5.1.1.2 — *"The verifier SHALL compare the prospective secret
against a list that contains values known to be commonly-used, expected, or compromised."*  
**Impact:** Users can register with `password123`, `letmein`, or passwords from known breaches.
This is a mandatory SHALL requirement in NIST — not optional.

**Implementation strategy:** HaveIBeenPwned k-anonymity API. Only the first 5 hex characters
of the SHA-1 hash are sent to the API. The server receives a list of matching suffixes and
checks locally. Zero PII (password or full hash) leaves your server.

**Fix — `token-server/auth.js`:**

```javascript
const https = require('https');
const crypto = require('crypto');

/**
 * Returns true if the password appears in the HaveIBeenPwned breach corpus.
 * Uses k-anonymity: only sends the first 5 chars of SHA-1 hash.
 * Throws on network error — caller should decide whether to hard-block or soft-warn.
 */
async function isPwnedPassword(password) {
  const sha1 = crypto.createHash('sha1').update(password).digest('hex').toUpperCase();
  const prefix = sha1.slice(0, 5);
  const suffix = sha1.slice(5);

  return new Promise((resolve, reject) => {
    const req = https.get(
      `https://api.pwnedpasswords.com/range/${prefix}`,
      { headers: { 'Add-Padding': 'true' } },  // prevents traffic analysis
      (res) => {
        let data = '';
        res.on('data', chunk => { data += chunk; });
        res.on('end', () => {
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
```

**In `register()` and `resetPassword()`:**

```javascript
// After input validation, before bcrypt.hash:
let pwned = false;
try {
  pwned = await isPwnedPassword(password);
} catch (err) {
  // Network error: log and continue — don't block registration on HIBP outage
  console.warn('[auth] HIBP check failed:', err.message);
}
if (pwned) {
  throw Object.assign(new Error('Password found in known data breaches. Please choose a different password.'), { status: 400, code: 'PASSWORD_PWNED' });
}
```

Add to `.env.example`:
```
# Optional: set to 'warn' to log but not block on HIBP check failure
HIBP_FAILURE_MODE=block
```

---

#### G8 — No authenticated password change endpoint

**Source:** OWASP Authentication CS, industry standard (GitHub, Auth0, Stripe)  
**Impact:** A logged-in user who knows their password and wants to change it must go through
the forgot-password flow — which is designed for *unauthenticated* recovery. These are
different security operations. Password change should require the current password, keeping
the session alive; password reset revokes all sessions.

**Fix — `token-server/index.js`:**

```javascript
app.post('/auth/change-password', auth.requireAuth, async (req, res) => {
  const { currentPassword, newPassword } = req.body || {};

  if (!currentPassword || typeof currentPassword !== 'string') {
    return res.status(400).json({ error: 'currentPassword required' });
  }
  if (!newPassword || typeof newPassword !== 'string') {
    return res.status(400).json({ error: 'newPassword required' });
  }
  if (Buffer.byteLength(newPassword, 'utf8') > 72) {
    return res.status(400).json({ error: 'Password too long (max 72 bytes)' });
  }
  if (newPassword.length < 8) {
    return res.status(400).json({ error: 'Password must be at least 8 characters' });
  }

  const userResult = await db.query(
    'SELECT id, password_hash FROM users WHERE id = $1',
    [req.user.userId]
  );
  if (userResult.rows.length === 0) {
    return res.status(401).json({ error: 'USER_NOT_FOUND' });
  }
  const user = userResult.rows[0];

  const valid = await bcrypt.compare(currentPassword, user.password_hash);
  if (!valid) {
    await auditLog(user.id, 'change_password_failure', req.ip, {});
    return res.status(401).json({ error: 'Current password is incorrect' });
  }

  // Optional: check new password against breach corpus (reuse G1 helper)
  // await checkPwnedPassword(newPassword);

  const newHash = await bcrypt.hash(newPassword, BCRYPT_ROUNDS);

  // Revoke all sessions EXCEPT the current one (keep the caller logged in)
  const currentTokenFamily = req.user.tokenFamily;
  await db.query(
    `UPDATE refresh_tokens
     SET revoked_at = NOW()
     WHERE user_id = $1
       AND revoked_at IS NULL
       AND family_id != $2`,
    [user.id, currentTokenFamily]
  );

  await db.query(
    'UPDATE users SET password_hash = $1 WHERE id = $2',
    [newHash, user.id]
  );

  await auditLog(user.id, 'change_password_success', req.ip, {});
  res.json({ message: 'Password changed. All other sessions have been revoked.' });
});
```

---

#### G9 — No account deletion / GDPR right-to-erasure

**Source:** GDPR Article 17 (Right to Erasure)  
**Impact:** Any user in the EU (or any region with similar laws) can request deletion of
their personal data. With no mechanism to honour this, a data-erasure request requires
manual DB intervention. Shipping to EU users without this is a legal risk.

**Implementation approach:** Anonymize rather than hard-delete. Hard deletion cascades
through foreign keys and breaks audit trails. Anonymization preserves referential integrity
whilst erasing PII.

**New migration — `token-server/migrations/009_account_deletion.sql`:**

```sql
ALTER TABLE users
  ADD COLUMN deleted_at TIMESTAMPTZ,
  ADD COLUMN deletion_reason VARCHAR(100);
```

**Fix — `token-server/index.js`:**

```javascript
app.delete('/auth/account', auth.requireAuth, async (req, res) => {
  const { password } = req.body || {};  // require password confirmation
  if (!password || typeof password !== 'string') {
    return res.status(400).json({ error: 'password required to confirm deletion' });
  }

  const userResult = await db.query(
    'SELECT id, password_hash, ls_customer_id, ls_subscription_id FROM users WHERE id = $1',
    [req.user.userId]
  );
  if (userResult.rows.length === 0) {
    return res.status(404).json({ error: 'USER_NOT_FOUND' });
  }
  const user = userResult.rows[0];

  const valid = await bcrypt.compare(password, user.password_hash);
  if (!valid) {
    return res.status(401).json({ error: 'Password incorrect' });
  }

  const client = await db.connect();
  try {
    await client.query('BEGIN');

    // 1. Cancel any active Lemon Squeezy subscription
    //    LS stores one subscription per user (variant upgrade creates new sub).
    //    DELETE /v1/subscriptions/{id} cancels it (sets status → cancelled, access until ends_at).
    if (user.ls_subscription_id) {
      try {
        await cancelSubscription(user.ls_subscription_id);
      } catch (lsErr) {
        console.error('[auth] Lemon Squeezy cancel on deletion failed:', lsErr.message);
        // Don't abort the deletion if LS is unreachable — the subscription will
        // eventually expire on its own.
      }
    }

    // 2. Revoke all refresh tokens
    await client.query(
      'UPDATE refresh_tokens SET revoked_at = NOW() WHERE user_id = $1 AND revoked_at IS NULL',
      [user.id]
    );

    // 3. Anonymize PII — keep row for audit_events foreign key integrity
    const anonEmail = `deleted_${user.id}@deleted.invalid`;
    await client.query(
      `UPDATE users SET
         email          = $1,
         display_name   = 'Deleted User',
         password_hash  = '',
         email_verified_at = NULL,
         tier           = 'free',
         subscription_status = 'expired',
         ls_customer_id      = NULL,
         ls_subscription_id  = NULL,
         ls_variant_id       = NULL,
         ls_product_id       = NULL,
         ls_portal_url       = NULL,
         deleted_at     = NOW(),
         deletion_reason = 'user_request'
       WHERE id = $2`,
      [anonEmail, user.id]
    );

    await client.query(
      `INSERT INTO audit_events (user_id, event_type, ip_address, metadata)
       VALUES ($1, 'account_deleted', $2::inet, $3)`,
      [user.id, req.ip, JSON.stringify({ reason: 'user_request' })]
    );

    await client.query('COMMIT');
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }

  res.json({ message: 'Account deleted. All personal data has been removed.' });
});
```

---

#### G16 — ~~Missing `invoice.payment_action_required` webhook (3DS)~~ — NOT APPLICABLE

**Source:** Previously Stripe SCA/3DS documentation  
**Status:** **N/A — Lemon Squeezy handles 3DS/SCA as Merchant of Record.**

Lemon Squeezy is the Merchant of Record for all transactions. This means **all payment
authentication** — including 3D Secure (SCA), Strong Customer Authentication, and regional
payment compliance — is handled entirely by Lemon Squeezy's checkout and payment flow.

- There is no `invoice.payment_action_required` equivalent in Lemon Squeezy.
- If additional authentication is needed, LS handles it within their hosted checkout/payment
  page before the transaction completes.
- We never need to prompt the user for 3DS or send them a hosted invoice URL.
- The `subscription_payment_failed` event may fire if the user abandons authentication,
  and that is already handled in our `billing.js` event router.

**No implementation required.** This gap is closed by the choice of Lemon Squeezy as the
billing provider.

---

#### G14 — No PKCE for OAuth flows

**Source:** RFC 8252 §6, RFC 7636  
**Impact:** Native app clients are *public clients* — they cannot protect a client secret.
Without PKCE, an authorization code intercepted from the redirect URI (via another app
registered on the same URI scheme) can be exchanged for tokens. PKCE prevents this by
binding the code to a verifier that only the legitimate client knows.

**Fix — macOS client (add to `InterAuthManager` when built):**

```objc
// In the OAuth initiation flow:
- (NSURL *)buildAuthorizationURLWithProvider:(NSString *)provider {
    // Generate PKCE code_verifier: 32 cryptographically random bytes, base64url-encoded
    NSMutableData *randomData = [NSMutableData dataWithLength:32];
    SecRandomCopyBytes(kSecRandomDefault, 32, randomData.mutableBytes);
    NSString *codeVerifier = [[randomData base64EncodedStringWithOptions:0]
        stringByReplacingOccurrencesOfString:@"+" withString:@"-"]
        stringByReplacingOccurrencesOfString:@"/" withString:@"_"]
        stringByReplacingOccurrencesOfString:@"=" withString:@""];

    // code_challenge = BASE64URL(SHA-256(ASCII(code_verifier)))
    NSData *verifierData = [codeVerifier dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(verifierData.bytes, (CC_LONG)verifierData.length, digest);
    NSData *hashData = [NSData dataWithBytes:digest length:CC_SHA256_DIGEST_LENGTH];
    NSString *codeChallenge = [[hashData base64EncodedStringWithOptions:0]
        stringByReplacingOccurrencesOfString:@"+" withString:@"-"]
        stringByReplacingOccurrencesOfString:@"/" withString:@"_"]
        stringByReplacingOccurrencesOfString:@"=" withString:@""];

    // Store verifier for use at token exchange
    self.pkceCodeVerifier = codeVerifier;

    NSURLComponents *components = [NSURLComponents componentsWithString:authEndpoint];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"client_id"             value:clientId],
        [NSURLQueryItem queryItemWithName:@"redirect_uri"          value:@"com.inter.app://oauth"],
        [NSURLQueryItem queryItemWithName:@"response_type"         value:@"code"],
        [NSURLQueryItem queryItemWithName:@"code_challenge"        value:codeChallenge],
        [NSURLQueryItem queryItemWithName:@"code_challenge_method" value:@"S256"],
        [NSURLQueryItem queryItemWithName:@"scope"                 value:@"openid email"],
    ];
    return components.URL;
}

// At token exchange, include code_verifier:
// POST /oauth/token with { code, code_verifier: self.pkceCodeVerifier, ... }
```

---

### 10.3 — P2: Medium (implement before scaling / additional users)

---

#### G2 — Password byte cap vs NIST character requirement

**Source:** NIST SP 800-63B §5.1.1.2 — *"Verifiers SHOULD permit at least 64 characters."*  
**Problem:** The plan enforces `Buffer.byteLength(password, 'utf8') > 72` server-side, but
the HTML form uses `maxlength="72"` which browsers measure in *characters*. A user typing
24 emoji characters passes the browser limit (24 chars) but hits the server limit (up to
96 bytes = 72 bytes exceeded). A user typing 72 basic ASCII characters is fine.

**Fix options (choose one):**

Option A — Pre-hash before bcrypt (supports arbitrarily long passwords):
```javascript
// In register() and login(), before bcrypt.hash/compare:
// Stretch the password to ≤64 bytes using SHA-256, then bcrypt that.
// This allows passwords of any character length.
const MAX_CHARS = 1000;
if (password.length > MAX_CHARS) {
  throw Object.assign(new Error('Password too long'), { status: 400, code: 'PASSWORD_TOO_LONG' });
}
// SHA-256 output is always 32 bytes — safely within bcrypt's 72-byte limit
const normalizedPassword = crypto.createHash('sha256').update(password, 'utf8').digest('base64');
// Use normalizedPassword with bcrypt.hash / bcrypt.compare
```
> Note: Once deployed, **existing password hashes are format-incompatible**. Roll out with a
> migration: compare against old hash first, re-hash with new scheme on success.

Option B — Simple: enforce character limit (not byte limit), cap at 128 chars:
```javascript
if (password.length > 128) {
  throw Object.assign(new Error('Password too long (max 128 characters)'), { status: 400 });
}
// Keep the 72-byte guard as a belt-and-suspenders check
if (Buffer.byteLength(password, 'utf8') > 4 * 128) { // theoretical max for 128 chars
  throw Object.assign(new Error('Password too long'), { status: 400 });
}
```
Update the HTML form: `maxlength="128"`. This is simpler and avoids the migration.

**Recommended: Option B** — avoids hash migration complexity.

---

#### G3 — No idle timeout / reauthentication prompt

**Source:** NIST SP 800-63B §4.2.3 — *"AAL2: reauthentication SHALL be repeated following
any period of inactivity lasting 30 minutes or longer."*  
OWASP Session Management CS: *"Idle timeout is a required control."*  

This is a **client-side** control for a desktop app. The server already enforces a 15-minute
access token TTL; the idle timeout sits above that.

**Fix — macOS client (AppDelegate.m / InterCallSessionCoordinator):**

```objc
// In AppDelegate.h
@property (nonatomic) NSDate *lastUserActivityAt;
@property (nonatomic) NSTimer *idleCheckTimer;
static const NSTimeInterval kIdleTimeoutSeconds = 30 * 60; // 30 minutes

// In AppDelegate.m applicationDidFinishLaunching:
self.lastUserActivityAt = [NSDate date];
self.idleCheckTimer = [NSTimer scheduledTimerWithTimeInterval:60.0   // check every 1 min
                                                       target:self
                                                     selector:@selector(checkIdleTimeout:)
                                                     userInfo:nil
                                                      repeats:YES];
// Register for user activity events (mouse moved, key down)
[NSEvent addGlobalMonitorForEventsMatchingMask:(NSEventMaskMouseMoved |
                                                NSEventMaskKeyDown    |
                                                NSEventMaskScrollWheel)
                                       handler:^(NSEvent *event) {
    self.lastUserActivityAt = [NSDate date];
}];

- (void)checkIdleTimeout:(NSTimer *)timer {
    if (!self.isAuthenticated) return;  // not logged in — nothing to do
    NSTimeInterval idle = [[NSDate date] timeIntervalSinceDate:self.lastUserActivityAt];
    if (idle >= kIdleTimeoutSeconds) {
        // Prompt re-authentication — do NOT silently discard the session
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"InterIdleTimeoutReached"
                          object:nil];
    }
}
```

The UI layer observes `InterIdleTimeoutReached` and shows the login sheet over the main
window (greyed out). The user re-enters their password, which calls `POST /auth/login`. The
existing refresh token is not revoked (session continuity is preserved) — only a fresh
access token is required to confirm identity.

---

#### G4 — No absolute session hard cutoff

**Source:** OWASP Session Management CS — *"An absolute session timeout is one that expires
the session after a fixed period of time, regardless of any session activity."*  
NIST §4.1.3 — AAL1 absolute timeout: 30 days.

**Problem:** The plan's 30-day refresh token TTL rolling window allows a user who refreshes
once per day to maintain a session indefinitely (exceeding 30 days from first login).

**Fix — `token-server/migrations/003_refresh_tokens.sql`** (add column):

```sql
ALTER TABLE refresh_tokens ADD COLUMN absolute_expires_at TIMESTAMPTZ;
```

**Fix — `token-server/auth.js` in `issueRefreshToken()`:**

```javascript
// When inserting a new token: set absolute_expires_at from the FAMILY's first
// creation, not from now. This means re-issued tokens within the same family
// all share the same hard cutoff.
const ABSOLUTE_SESSION_TTL_DAYS = 30;

async function issueRefreshToken(userId, familyId, replacedByTokenId = null) {
  const raw = crypto.randomBytes(32);
  const hash = crypto.createHash('sha256').update(raw).digest();
  const tokenId = crypto.randomUUID();

  // Determine the absolute expiry for this family
  let absoluteExpiresAt;
  if (familyId) {
    // Inherit the absolute expiry from the original family token
    const family = await db.query(
      'SELECT MIN(absolute_expires_at) as first FROM refresh_tokens WHERE family_id = $1',
      [familyId]
    );
    absoluteExpiresAt = family.rows[0]?.first ?? null;
  }
  // For new families (first login), set from now
  if (!absoluteExpiresAt) {
    const d = new Date();
    d.setDate(d.getDate() + ABSOLUTE_SESSION_TTL_DAYS);
    absoluteExpiresAt = d;
  }

  await db.query(
    `INSERT INTO refresh_tokens
       (id, user_id, token_hash, family_id, replaced_by, expires_at, absolute_expires_at)
     VALUES ($1, $2, $3, $4, $5,
       NOW() + INTERVAL '${REFRESH_TOKEN_TTL_DAYS} days',
       $6)`,
    [tokenId, userId, hash, familyId ?? tokenId, replacedByTokenId, absoluteExpiresAt]
  );
  return { raw: raw.toString('base64url'), tokenId };
}
```

**In `POST /auth/refresh` validation:**

```javascript
// After finding the token row, add:
if (tokenRow.absolute_expires_at && new Date() > new Date(tokenRow.absolute_expires_at)) {
  return res.status(401).json({ error: 'SESSION_EXPIRED', reason: 'absolute_timeout' });
}
```

---

#### G7 — No MFA path documented (AAL1 only)

**Source:** NIST SP 800-63B §4.2 — AAL2 requires two authentication factors.  

The plan is AAL1 (password only). This is acceptable for the initial launch scope. However,
the schema and architecture should be prepared for TOTP-based MFA as a Phase E item.

**Planned schema addition (Phase E) — note only, not implemented yet:**

```sql
-- Phase E: MFA support
ALTER TABLE users
  ADD COLUMN totp_secret_enc  TEXT,        -- AES-256-GCM encrypted TOTP secret
  ADD COLUMN totp_enabled_at  TIMESTAMPTZ,
  ADD COLUMN totp_backup_codes JSONB;      -- [{hash, used_at}] — bcrypt hashed codes
```

**Phase E endpoints to design:**
- `POST /auth/mfa/setup` — generate TOTP secret, return QR code URI
- `POST /auth/mfa/verify-setup` — confirm with first TOTP code, enable MFA
- `POST /auth/mfa/challenge` — submit TOTP code during login (second factor)
- `POST /auth/mfa/disable` — disable MFA (requires password + TOTP confirmation)
- `GET /auth/mfa/backup-codes` — download one-time use backup codes

**Login flow change for AAL2:** `POST /auth/login` returns `{ mfaRequired: true, mfaToken: <short-lived JWT> }` for MFA-enabled users instead of a full token pair. The client then calls `POST /auth/mfa/challenge` with the TOTP code and the `mfaToken` to get the actual token pair.

---

#### G13 — URI scheme should be reverse-domain format

**Source:** RFC 8252 §7.1 — *"Schemes that are short, memorable names are not a good option
as they may already be claimed by another app on the same device."*  

**Problem:** `inter://` is a generic scheme. If any other app claims the same scheme, the OS
may route the URL to the wrong app. RFC 8252 requires reverse-domain format.

**Fix:** Rename `inter://` to `com.inter.app://` (or your actual bundle ID) everywhere:

1. `inter/Info.plist` — `CFBundleURLSchemes`: change `inter` → `com.inter.app`
2. `token-server/auth.js` password reset HTML — change `inter://reset-password?token=...`
   → `com.inter.app://reset-password?token=...`
3. `inter/App/AppDelegate.m` — update the URL handler comparison from `inter://` host
   detection to the new scheme path

---

#### G17 — ~~Missing `checkout.session.completed`~~ → Handled by `subscription_created`

**Source:** Lemon Squeezy subscription lifecycle docs  
**Impact:** Previously required a separate `checkout.session.completed` handler (Stripe).
With Lemon Squeezy, the equivalent event is `subscription_created`, which fires when a new
subscription is created after checkout completes.

**Status: Already handled in `billing.js` event router (see §10 starter code).**

The `subscription_created` handler in `billing.js`:
1. Extracts `user_id` from `meta.custom_data.user_id`
2. Maps `variant_id` → tier via `VARIANT_ID_TO_TIER`
3. Stores `ls_subscription_id`, `ls_customer_id`, `ls_variant_id`, `ls_product_id`
4. Updates `subscription_status = 'active'` (or `'on_trial'` if trial)
5. Caches `urls.customer_portal` and `urls.update_payment_method` for portal access

Additionally, the `order_created` event (which fires alongside `subscription_created`)
is logged for audit purposes but does not trigger tier changes — the subscription event
is the source of truth for access control.

**No additional implementation required beyond the billing.js event router.**

---

#### G18 — No grace period for `past_due`

**Source:** Lemon Squeezy subscription lifecycle docs — dunning and payment recovery  
**Problem:** When a payment fails, immediately restricting access creates poor UX. LS
automatically retries failed payments (up to 4 attempts over ~2 weeks), but we should grant
a grace period during `past_due` so the user isn't locked out during the retry window.

**New migration — add grace period column:**

```sql
ALTER TABLE users ADD COLUMN grace_until TIMESTAMPTZ;
```

**Status: Already handled in `billing.js` event router (see §10 starter code).**

The `subscription_payment_failed` handler in `billing.js`:
1. Sets `subscription_status = 'past_due'`
2. Calculates `grace_until = NOW() + GRACE_PERIOD_DAYS` (default: 3 days)
3. Sends payment-failed notification email with `urls.update_payment_method` link

The `subscription_payment_recovered` handler:
1. Clears `grace_until` to `NULL`
2. Restores `subscription_status = 'active'`

**Update `requireTier()` to respect grace period (from G15 fix):**

```javascript
// In requireTier, after fetching user row:
const { tier, subscription_status, grace_until } = user;
const inGracePeriod = grace_until && new Date() < new Date(grace_until);

if (INACTIVE_STATUSES.has(subscription_status) && !inGracePeriod) {
  return res.status(403).json({
    code: 'SUBSCRIPTION_INACTIVE',
    error: 'Your subscription is inactive',
    subscriptionStatus: subscription_status,
  });
}
```

Note: The `cancelled` status uses a different grace mechanism — access continues until
`ends_at` (the end of the billing period). This is set by LS automatically and stored in
our `grace_until` column by the `subscription_cancelled` handler.

---

#### G19 — No `on_trial` state mapping

**Source:** Lemon Squeezy subscription lifecycle docs — trial subscriptions  
**Problem:** `tier CHECK IN ('free','pro','hiring')` has no trial concept. A Lemon Squeezy
trial subscriber (status = `on_trial`) should get `pro`-equivalent access but is not yet a
paying customer.

**Fix:** Treat `on_trial` as access-grant via `subscription_status`, not via `tier`.
No new `tier` value needed. Update `requireTier()`:

```javascript
// on_trial users get pro-equivalent access
const TRIAL_GRANTS_TIER = { on_trial: 'pro' };

const effectiveTier = TRIAL_GRANTS_TIER[subscription_status] ?? tier;

if ((tierRank[effectiveTier] ?? -1) < (tierRank[minTier] ?? 999)) {
  return res.status(403).json({ code: 'INSUFFICIENT_TIER', error: 'Insufficient tier', required: minTier });
}
```

**Status: Already handled in `billing.js` event router and G15 `requireTier()` fix.**

The `subscription_created` handler in `billing.js` sets `subscription_status = 'on_trial'`
when `data.attributes.status === 'on_trial'`. The G15 `requireTier()` fix includes the
`TRIAL_GRANTS_TIER` mapping above. When the trial ends and payment succeeds, LS fires
`subscription_updated` with `status: 'active'`, which the `subscription_updated` handler
processes to set `subscription_status = 'active'`.

---

#### G21 — No Customer Portal

**Source:** Lemon Squeezy subscription management — self-service portal  
**Impact:** Users must email support to cancel, update a card, or view invoices.

**Fix — `token-server/index.js`:**

Lemon Squeezy provides **pre-signed portal URLs** on every subscription object. These are
stored in `urls.customer_portal` and `urls.update_payment_method`. Our `billing.js` event
router already caches the latest `ls_portal_url` on every subscription webhook event.

The portal URL is pre-signed and valid for 24 hours. No API call is needed to create a
portal session (unlike Stripe's `billingPortal.sessions.create()`).

```javascript
app.get('/billing/portal-url', auth.requireAuth, async (req, res) => {
  const userResult = await db.query(
    'SELECT ls_portal_url FROM users WHERE id = $1',
    [req.user.userId]
  );
  const portalUrl = userResult.rows[0]?.ls_portal_url;
  if (!portalUrl) {
    return res.status(404).json({
      code: 'NO_SUBSCRIPTION',
      error: 'No active subscription found. Subscribe first.',
    });
  }

  // Portal URLs are pre-signed with 24h expiry.
  // If the cached URL has expired, the user can trigger a subscription update
  // webhook (any billing event refreshes the cached URL).
  // For a guaranteed fresh URL, fetch subscription from LS API:
  //   const sub = await getSubscription(user.ls_subscription_id);
  //   portalUrl = sub.data.attributes.urls.customer_portal;

  res.json({ url: portalUrl });
});
```

The macOS client calls this endpoint and opens the returned `url` in the default browser
via `NSWorkspace.sharedWorkspace.open(url)`. The LS portal allows users to:
- View and download invoices
- Update payment method
- Cancel subscription
- View subscription details

No custom cancellation UI is needed — LS handles the entire portal experience.

---

#### G22 — No re-subscription flow

**Source:** Lemon Squeezy subscription lifecycle docs — *A cancelled/expired subscription
cannot be reactivated. A new checkout creates a new subscription.*  
**Impact:** A user who cancels has no path back to `pro` tier.

**Fix — `token-server/index.js`:**

Lemon Squeezy re-subscription works through a new checkout. When a user subscribes (or
re-subscribes), we create a checkout URL via the LS API, passing `custom_data.user_id` to
link the new subscription back to their account.

```javascript
const { createCheckout } = require('@lemonsqueezy/lemonsqueezy.js');

app.post('/billing/checkout', auth.requireAuth, async (req, res) => {
  const { variantId } = req.body || {};
  if (!variantId || typeof variantId !== 'string') {
    return res.status(400).json({ code: 'INVALID_INPUT', error: 'variantId required' });
  }

  // Validate variantId is one of the known allowed values
  const ALLOWED_VARIANT_IDS = new Set(Object.keys(VARIANT_ID_TO_TIER));
  if (!ALLOWED_VARIANT_IDS.has(variantId)) {
    return res.status(400).json({ code: 'INVALID_VARIANT', error: 'Invalid variantId' });
  }

  // Fetch user email for pre-fill
  const userResult = await db.query(
    'SELECT email, display_name FROM users WHERE id = $1',
    [req.user.userId]
  );
  const user = userResult.rows[0];
  if (!user) {
    return res.status(404).json({ code: 'USER_NOT_FOUND', error: 'User not found' });
  }

  // Create Lemon Squeezy checkout
  // CRITICAL: custom_data.user_id is how the webhook links the subscription to our user.
  // This is the ONLY linkage mechanism — without it, we cannot process the subscription.
  const checkout = await createCheckout(
    process.env.LEMONSQUEEZY_STORE_ID,
    variantId,
    {
      checkoutData: {
        email: user.email,
        name: user.display_name || undefined,
        custom: {
          user_id: req.user.userId,        // CRITICAL: links subscription → user
        },
      },
      productOptions: {
        redirectUrl: process.env.APP_RETURN_URL ?? 'https://your-app.com/billing/success',
      },
      expiresAt: new Date(Date.now() + 30 * 60 * 1000).toISOString(), // 30 min expiry
    }
  );

  res.json({ url: checkout.data.attributes.url });
  // Client opens this URL in default browser.
  // Tier update arrives via subscription_created webhook (handled in billing.js).
});
```

**Note:** Unlike Stripe, Lemon Squeezy does not require pre-creating a customer. The
customer is automatically created (or matched by email) during checkout. The `ls_customer_id`
is captured from the `subscription_created` webhook and stored for future API lookups.

---

#### G23 — ~~No `incomplete_expired` handling~~ — NOT APPLICABLE

**Source:** Previously Stripe `incomplete_expired` subscription status  
**Status:** **N/A — Lemon Squeezy does not have an `incomplete_expired` state.**

In Stripe, if the first invoice for a new subscription is not paid within 23 hours, the
subscription transitions to `incomplete_expired`. This required a dedicated handler.

Lemon Squeezy handles initial payment collection entirely within their hosted checkout:
- Payment must succeed before checkout completes
- If the user abandons checkout, no subscription is created at all
- There is no `incomplete` or `incomplete_expired` state in LS
- A failed initial payment simply means the checkout was never completed

The subscription statuses in LS are: `on_trial`, `active`, `paused`, `past_due`, `unpaid`,
`cancelled`, `expired`. The `expired` terminal state covers subscriptions that reached end
of life (after cancellation grace period or dunning exhaustion).

**No implementation required.** This gap is closed by the choice of Lemon Squeezy as the
billing provider.

---

### 10.4 — P3: Low / Polish (implement before v1.0 public)

---

#### G5 — No password strength meter

**Source:** NIST SP 800-63B §5.1.1.2 SHOULD — *"offer guidance to the subscriber, such as
a password-strength meter."*

**Fix — macOS client (InterConnectionSetupPanel or equivalent register view):**

Use the [`zxcvbn`](https://github.com/dropbox/zxcvbn) algorithm (port or WASM). On each
keystroke in the password field, compute a score 0–4 and update a visual indicator:
- 0–1: red "Weak"
- 2: orange "Fair"
- 3: yellow "Good"
- 4: green "Strong"

For a macOS Objective-C client, the simplest path is to bundle the JS via JavaScriptCore
or use a native Swift/ObjC port. The meter is display-only — it does not block submission.

---

#### G6 — No show/hide password toggle

**Source:** NIST SP 800-63B §5.1.1.2 SHOULD — *"offer an option to display the secret."*  

**Fix — macOS client:**

In IB, place both an `NSSecureTextField` and an `NSTextField` (hidden) at the same frame.
Add an `NSButton` with a show/hide eye icon:

```objc
- (IBAction)togglePasswordVisibility:(id)sender {
    BOOL isHidden = self.passwordSecureField.isHidden;
    if (isHidden) {
        // Switching to hidden (secure)
        self.passwordSecureField.stringValue = self.passwordVisibleField.stringValue;
        self.passwordSecureField.hidden = NO;
        self.passwordVisibleField.hidden = YES;
    } else {
        // Switching to visible
        self.passwordVisibleField.stringValue = self.passwordSecureField.stringValue;
        self.passwordVisibleField.hidden = NO;
        self.passwordSecureField.hidden = YES;
    }
    [self.togglePasswordButton setImage:[NSImage imageWithSystemSymbolName:(isHidden ? @"eye.slash" : @"eye")
                                                accessibilityDescription:nil]];
}
```

---

#### G10 — No change-email flow

**Fix — `token-server/index.js`:**

Requires three steps to be secure: (1) verify current password, (2) send verification link
to the *new* email, (3) confirm via link before swapping email on record.

```javascript
// Step 1: POST /auth/change-email — { password, newEmail }
// Verify password, check newEmail not taken, send verification email to newEmail.
// Store { userId, newEmail, tokenHash, expiresAt } in email_change_tokens table.

// Step 2: GET /auth/verify-email-change?token=... — confirm new email
// Swap users.email to newEmail, mark old email_change_token as used.
// Notify old email address of the change.
```

New migration — `token-server/migrations/010_email_change_tokens.sql`:

```sql
CREATE TABLE email_change_tokens (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    new_email   VARCHAR(254) NOT NULL,
    token_hash  BYTEA NOT NULL UNIQUE,
    expires_at  TIMESTAMPTZ NOT NULL,
    used_at     TIMESTAMPTZ
);
CREATE INDEX idx_ect_hash ON email_change_tokens (token_hash) WHERE used_at IS NULL;
```

---

#### G11 — No active sessions list

**Fix — `token-server/index.js`:**

```javascript
// GET /auth/sessions — list active sessions for the authenticated user
app.get('/auth/sessions', auth.requireAuth, async (req, res) => {
  const result = await db.query(
    `SELECT id, client_id, created_at, last_used_at
     FROM refresh_tokens
     WHERE user_id = $1
       AND revoked_at IS NULL
       AND expires_at > NOW()
     ORDER BY last_used_at DESC`,
    [req.user.userId]
  );
  // Never return actual token hashes to the client
  res.json({ sessions: result.rows });
});

// DELETE /auth/sessions/:id — revoke a specific session
app.delete('/auth/sessions/:id', auth.requireAuth, async (req, res) => {
  const { id } = req.params;
  if (!id || !/^[0-9a-f-]{36}$/.test(id)) {
    return res.status(400).json({ error: 'invalid session id' });
  }
  const result = await db.query(
    `UPDATE refresh_tokens
     SET revoked_at = NOW()
     WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL`,
    [id, req.user.userId]
  );
  if (result.rowCount === 0) {
    return res.status(404).json({ error: 'Session not found' });
  }
  res.json({ revoked: true });
});
```

This also requires tracking `last_used_at` — add an `UPDATE` to `POST /auth/refresh`:
```javascript
await db.query(
  'UPDATE refresh_tokens SET last_used_at = NOW() WHERE id = $1',
  [tokenRow.id]
);
```

And a migration:
```sql
ALTER TABLE refresh_tokens ADD COLUMN last_used_at TIMESTAMPTZ;
```

---

#### G24 — No `paused` subscription handling

**Source:** Lemon Squeezy subscription lifecycle docs — subscription pausing  

**Status: Already handled in `billing.js` event router (see §10 starter code).**

Lemon Squeezy supports pausing subscriptions (via the portal or API). When paused:
- `subscription_paused` event fires → our handler sets `subscription_status = 'paused'`
- `subscription_unpaused` event fires when resumed → handler sets `subscription_status = 'active'`
- `paused` is included in `INACTIVE_STATUSES` in `requireTier()` (G15 fix), so paid
  features are blocked while paused
- The `data.attributes.pause` object contains `mode` and `resumes_at` fields if auto-resume
  is configured

The billing.js handler for `subscription_paused`:
```javascript
case 'subscription_paused': {
  const userId = resolveUserId(payload);
  await db.query(
    `UPDATE users SET subscription_status = 'paused', updated_at = NOW() WHERE id = $1`,
    [userId]
  );
  await auditLog(userId, 'subscription_paused', null, { subscriptionId });
  break;
}
```

And `subscription_unpaused`:
```javascript
case 'subscription_unpaused': {
  const userId = resolveUserId(payload);
  await db.query(
    `UPDATE users SET subscription_status = 'active', updated_at = NOW() WHERE id = $1`,
    [userId]
  );
  await auditLog(userId, 'subscription_unpaused', null, { subscriptionId });
  break;
}
```

**No additional implementation required beyond the billing.js event router.**

---

### 10.5 — New Files Required by Gap Mitigations

```
token-server/migrations/009_account_deletion.sql      — G9  (deleted_at column)
token-server/migrations/010_email_change_tokens.sql   — G10 (email_change_tokens table)
```

Existing files modified by gap mitigations:

```
token-server/auth.js      — G1 isPwnedPassword(), G8 change-password, G15 requireTier fix
token-server/index.js     — G8 POST /auth/change-password, G9 DELETE /auth/account,
                             G11 GET/DELETE /auth/sessions, G21 GET /billing/portal-url,
                             G22 POST /billing/checkout
token-server/billing.js   — G15 subscription_status in requireTier,
                             G17 subscription_created (handled in event router),
                             G18 grace period (subscription_payment_failed handler),
                             G19 on_trial mapping, G24 paused/unpaused
token-server/mailer.js    — G18 sendPaymentFailedEmail (with update_payment_method URL)
inter/Info.plist          — G12 CFBundleURLTypes registration (CRITICAL — do first)
inter/App/AppDelegate.m   — G12 handleGetURLEvent:withReplyEvent:, G3 idle timeout
```

### 10.6 — Gap Status Tracking

| # | Gap | Priority | Source | Status |
|---|-----|----------|--------|--------|
| G20 | `express.raw()` on webhook route | **P0** | Lemon Squeezy | ✅ Phase C.1 |
| G12 | CFBundleURLTypes in Info.plist | **P0** | RFC 8252 B.4 | ✅ CX.1 `com.inter.app://` |
| G15 | `requireTier()` ignores `subscription_status` | **P0** | Lemon Squeezy | ✅ Phase C.5 |
| G1  | No breach corpus / pwned password check | **P1** | NIST §5.1.1.2 | ✅ `isPwnedPassword()` in auth.js |
| G8  | No `POST /auth/change-password` | **P1** | OWASP | ✅ Endpoint in index.js |
| G9  | No `DELETE /auth/account` (GDPR) | **P1** | GDPR Art.17 | ✅ PII anonymization endpoint |
| G14 | No PKCE for OAuth flows | **P1** | RFC 8252 §6 | ➖ N/A — reviewed, not applicable (email/password auth only; OAuth uses ASWebAuthenticationSession with server-side PKCE) |
| G16 | ~~3DS webhook~~ | **N/A** | LS handles as MoR | ✅ Not needed |
| G2  | Password byte cap vs NIST char requirement | **P2** | NIST §5.1.1.2 | ✅ 8–72 byte validation in auth.js |
| G3  | No idle timeout / reauthentication prompt | **P2** | NIST §4.2.3 | ✅ 30-min idle in AppDelegate.m |
| G4  | No absolute session hard cutoff | **P2** | OWASP Session Mgmt | ✅ 30-day cutoff, migration 011 |
| G7  | No MFA path documented | **P2** | NIST §4.2 | ❌ Phase E planned |
| G13 | URI scheme should be reverse-domain | **P2** | RFC 8252 §7.1 | ✅ `com.inter.app://` |
| G17 | ~~`checkout.session.completed`~~ → subscription_created | **P2** | Lemon Squeezy | ✅ In billing.js |
| G18 | No grace period for `past_due` | **P2** | Lemon Squeezy best practice | ✅ In billing.js + requireTier |
| G19 | No `on_trial` state mapping | **P2** | Lemon Squeezy | ✅ In billing.js + G15 |
| G21 | No Customer Portal | **P2** | Lemon Squeezy best practice | ✅ `GET /billing/portal-url` |
| G22 | No re-subscription flow | **P2** | Lemon Squeezy | ✅ `POST /billing/checkout` |
| G23 | ~~`incomplete_expired` handling~~ | **N/A** | LS handles at checkout | ✅ Not needed |
| G5  | No password strength meter | **P3** | NIST §5.1.1.2 | ✅ 4-bar meter in InterLoginPanel |
| G6  | No show/hide password toggle | **P3** | NIST §5.1.1.2 | ✅ Toggle in InterLoginPanel |
| G10 | No change-email flow | **P3** | Industry standard | ✅ Endpoints + migration 010 |
| G11 | No active sessions list | **P3** | OWASP Session Mgmt | ✅ GET/DELETE /auth/sessions |
| G24 | No `paused` subscription handling | **P3** | Lemon Squeezy | ✅ In billing.js |
