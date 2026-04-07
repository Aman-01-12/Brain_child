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
6. [Attack Mitigation Matrix](#6-attack-mitigation-matrix)
7. [Files Changed Per Phase](#7-files-changed-per-phase)
8. [Testing Checklist](#8-testing-checklist)

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
| Rate limiting on auth endpoints | — | ❌ Missing (only room endpoints have it) |
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
  next();
});
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

## 5. Phase C — Billing & Tier Lifecycle Integration

> **Dependency**: Payment gateway chosen and integrated. Phase B must be complete first.

### What Phase C adds

1. **DB billing columns** on the `users` table:
   ```sql
   ALTER TABLE users
     ADD COLUMN subscription_status   VARCHAR(20) DEFAULT 'none',
     -- 'none' | 'trialing' | 'active' | 'past_due' | 'canceled'
     ADD COLUMN subscription_id       VARCHAR(255),   -- Stripe/Razorpay subscription ID
     ADD COLUMN customer_id           VARCHAR(255),   -- Stripe customer / Razorpay customer ID
     ADD COLUMN trial_ends_at         TIMESTAMPTZ,
     ADD COLUMN current_period_ends_at TIMESTAMPTZ;
   ```

2. **Webhook receiver** for payment provider lifecycle events:

   | Payment Event | Action |
   |---|---|
   | `customer.subscription.created` | `UPDATE users SET tier = 'pro', subscription_status = 'active'` |
   | `customer.subscription.trial_will_end` | Send user email warning |
   | `customer.subscription.deleted` | `UPDATE users SET tier = 'free', subscription_status = 'canceled'` |
   | `invoice.payment_failed` | `UPDATE users SET subscription_status = 'past_due'` |
   | `customer.subscription.updated` (plan change) | `UPDATE users SET tier = <new_plan>` |

   The tier change in the DB is immediately reflected in the next `/auth/refresh` cycle
   (max 15 min lag via Phase B). No other code needs to change.

3. **Webhook signature validation** — mandatory, not optional:
   ```javascript
   // Stripe: stripe.webhooks.constructEvent(rawBody, sig, STRIPE_WEBHOOK_SECRET)
   // Razorpay: validate X-Razorpay-Signature using HMAC-SHA256 of rawBody + webhook_secret
   // Never process a webhook event without verifying its signature
   ```

4. **Idempotency** — payment webhooks are delivered at-least-once:
   ```sql
   -- Store processed event IDs to prevent double-processing
   CREATE TABLE processed_webhook_events (
       event_id    VARCHAR(255) PRIMARY KEY,  -- Stripe event ID / Razorpay event ID
       processed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
   );
   ```

---

## 6. Attack Mitigation Matrix

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

---

## 7. Files Changed Per Phase

### Phase A (server-only, no client deps)
```
token-server/auth.js          — A.1, A.2, A.5
token-server/index.js         — A.3, A.4, A.5, A.6
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

### Phase C (billing gateway)
```
token-server/migrations/005_billing_columns.sql  — new file
token-server/billing.js                          — new file (webhook receiver + tier update logic)
token-server/index.js                            — POST /webhooks/stripe or /webhooks/razorpay
token-server/.env.example                        — STRIPE_WEBHOOK_SECRET or RAZORPAY_WEBHOOK_SECRET
```

---

## 8. Testing Checklist

### Phase A verification
- [ ] Server refuses to start if `JWT_SECRET` is unset or < 32 bytes
- [ ] `jwt.verify` with a token signed by `alg:none` returns 401
- [ ] `jwt.verify` with `iss: 'wrong-issuer'` returns 401
- [ ] Server startup log contains no LiveKit API key
- [ ] 11 consecutive login attempts from the same email within 15 min → 11th returns 429
- [ ] A deliberately thrown 500 error returns `{ error: "An internal error occurred", requestId }` — no DB detail
- [ ] Response headers include `Strict-Transport-Security` and `Cache-Control: no-store`

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
- [ ] Stripe `customer.subscription.deleted` webhook → `users.tier` updated to `'free'`
- [ ] Replaying the same Stripe event ID a second time → `409` (idempotency table blocks it)
- [ ] Webhook with invalid signature → `400` / `401` — event not processed
- [ ] After tier downgrade in DB: user's next 15-min refresh cycle picks up `free` tier in new access token
