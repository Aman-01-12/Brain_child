# Codebase Recon — Face-Verification for Interview Mode

Date: 2026-06-22
Purpose: factual ground for the design + architecture document. Every path, identifier, column
and error code below was read out of the working tree at `/Users/aman_01/Documents/inter`
(branch `test`, HEAD `3b7df51`). Nothing here is inferred.

Read-only recon. No source file was modified.

---

## 0. Headline facts (the load-bearing ones)

| Question | Answer (verified) |
|---|---|
| Highest applied migration | `022_rename_pro_plus_to_hiring.sql` |
| **Next migration filename** | **`token-server/migrations/023_<snake_case_name>.sql`** |
| Migration runner | `node migrate.js` from `token-server/`, lexicographic order, tracked in `schema_migrations(filename)` |
| Server test command | `npm test` in `token-server/` → `node --test --test-concurrency=1 test/*.test.js` |
| Client build/test | `xcodebuild build -scheme inter -destination 'platform=macOS'` / `xcodebuild test -scheme inter -destination 'platform=macOS'` |
| Fail-closed join hook | inline in `index.js` `app.post('/room/join', …)` — **not** in `joinGuards.js` |
| `crypto.js` reusable? | Yes, as-is, for a *string* secret. Not for binary image bytes. |
| `fileValidation.js` reusable? | Yes — `isMimeAllowed('image/jpeg')` already passes; `image/svg+xml` already blocked. Missing: pixel-dimension cap, image-specific size cap, re-encode/strip-EXIF. |
| `audit_events` writer | `auth.auditLog(userId, eventType, ipAddress, metadata)` from `token-server/auth.js` |
| Client frame grab | Possible today with no disturbance to the published track — two existing seams (§11.3) |
| Vision.framework | **Not yet used anywhere in the client.** Zero hits for `import Vision` / `VNDetectFace` / `CIDetector`. |

---

## 1. `token-server/index.js` — middleware order, mounting, limits

File is 5,784 lines. Export line 5784:

```js
module.exports = { app, httpServer, createToken, toolsEntitlement };
```

Tests import `{ app: mainApp } = require('./index')` — a `require.main` guard means no port is
bound on import (see `test/interviewTierGate.test.js`).

### 1.1 Exact middleware stack, in order

| Line | Middleware | Note |
|---|---|---|
| 106 | `app.post('/webhooks/lemonsqueezy', express.raw({type:'application/json'}), require('./billing'))` | **Before** `express.json()` — raw bytes needed for HMAC |
| 112 | `app.use(express.json())` | **No `limit` option → Express default 100 KB body cap** |
| 115 | `app.use(express.static(path.join(__dirname,'public')))` | |
| 120 | security-headers middleware | HSTS, `Cache-Control: no-store`, `nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer` |
| 135 | `app.use(auth.authenticateToken)` | **Optional** auth — sets `req.user` or `null`; 401s only on a *present but invalid* token |
| 139 | `app.use('/meetings', schedulingRouter)` | `require('./scheduling')` |
| 143 | `app.use('/calendar', calendarRouter)` | |
| 148 | `app.use('/teams', teamsRouter)` | |
| 152 | `app.use('/auth', profileRouter)` | |
| 5401 | global error handler | last `app.use` before `app.listen` |

A new router mounts at the same place as the four above (lines 139–152), i.e. after
`auth.authenticateToken` so `req.user` is populated. Precedent for the mount style:

```js
const schedulingRouter = require('./scheduling');
app.use('/meetings', schedulingRouter);
```

**Body-size consequence for the design:** a base64 JPEG in a JSON body will be rejected by the
100 KB `express.json()` default. The established escape hatch is `multer` + `multipart/form-data`
(§6), which bypasses `express.json()` entirely.

### 1.2 `requestId`

Produced **only** in the global error handler (line 5402), per-error, never per-request:

```js
app.use((err, req, res, _next) => {
  const requestId = require('crypto').randomUUID();
  const status = err.status || 500;
  console.error(`[error] requestId=${requestId} path=${req.path} err=${err.message}`);
  if (status !== 500) {
    return res.status(status).json({ error: err.message, requestId });
  }
  res.status(500).json({ error: 'An internal error occurred', requestId });
});
```

**Correction to the assumed context:** the `{ error, code, requestId }` triple is *not* a uniform
convention. Hand-written route responses emit `{ error, code, … }` **without** `requestId`
(e.g. `INSUFFICIENT_TIER`, `TOKEN_EXPIRED`, `IDEMPOTENCY_KEY_REQUIRED`); `requestId` appears only
on responses that flow through the error handler via a thrown error. A new endpoint matching house
style emits `{ error, code, … }` and gets `requestId` for free on thrown 500s.

### 1.3 Rate limiting + `Retry-After`

Five distinct limiter shapes, all Redis `INCR`+`EXPIRE`:

| Name | Line | Key | Budget | `Retry-After`? | Redis failure |
|---|---|---|---|---|---|
| `makeAuthRateLimiter(ns)` → `rateLimitAuth`, `rateLimitForgotPassword` | 243 | `ratelimit:{ns}:{email}` or `:ip:{ip}` | 10 / 900 s | **Yes** | fail **open** |
| `rateLimitRefresh` | 292 | `ratelimit:refresh:ip:{ip}` | 30 / 60 s | **Yes** | fail open |
| `rateLimitBilling` | 1802 | — | — | **Yes** | fail open |
| `rateLimitJoin` | 330 | `ratelimit:join-ip:{ip}` (60/60 s) + `ratelimit:join-dev:{clientId}` (30/60 s) | | **No** | fail open |
| `rateLimitRoomAction(action, max=60, windowSec=60)` | 383 | `ratelimit:{action}:u:{userId}` or `:ip:{ip}` | 60 / 60 s | **No** | fail open |
| `checkRateLimit(identity)` | 322 | `ratelimit:{identity}` | 10 / 60 s | **No** | throws |

`rateLimitRoomAction` is the factory a new authenticated room-scoped POST should use. Example
call sites: `rateLimitRoomAction('record-start')`, `rateLimitRoomAction('request-screen-share', 20)`.

**Correction:** there is no `RATE_LIMITED` code string anywhere in the server. Rate-limit responses
are `429` with `{ error: '<prose>' }` and **no `code` field**. If the design wants a machine code it
is new, not existing.

### 1.4 Error codes that actually exist

Grepped and confirmed as string literals in the server: `TOKEN_EXPIRED`, `TOKEN_INVALID`,
`INSUFFICIENT_TIER`, `SUBSCRIPTION_INACTIVE`, `USER_NOT_FOUND`, `IDEMPOTENCY_KEY_REQUIRED`,
`IDEMPOTENCY_KEY_INVALID`.

**Correction:** `TIER_INSUFFICIENT` (as written in the assumed context) does **not** exist. The
real code is `INSUFFICIENT_TIER`.

`/room/join` rejections do **not** use codes at all — they use boolean discriminator fields:
`{ notStarted: true }`, `{ banned: true }`, `{ passwordRequired: true }`, `{ lobbyFull: true }`,
`{ hostNotYetJoined: true }`, `{ status: 'waiting', position, pollToken }`. A verification gate
added to `/room/join` must follow this shape to stay consistent, and the client maps it to an
`InterNetworkErrorCode` (§11.2).

---

## 2. `token-server/auth.js` — auth surface

### 2.1 `authenticateToken` (global, optional) — line 472

Sets exactly this on success:

```js
req.user = {
  userId:      decoded.userId,
  email:       decoded.email,
  displayName: decoded.displayName,
  tier:        decoded.tier,
  tokenFamily: decoded.fam || null,
};
```

No header → `req.user = null`, `next()`. Invalid → `401 { error, code: 'TOKEN_INVALID' }`.
Expired → `401 { error: 'Access token expired', code: 'TOKEN_EXPIRED' }`.

`verifyAccessToken` (line 486): HS256 only, `issuer: 'inter-token-server'`,
`audience: 'inter-macos-client'`.

### 2.2 `requireAuth` — line 527

```js
function requireAuth(req, res, next) {
  if (!req.user) {
    return res.status(401).json({ error: 'Authentication required' });
  }
  next();
}
```

Note: no `code` field on this 401.

### 2.3 `requireTier(minTier)` — line 552

Middleware **factory**. Does a **fresh DB read** (`SELECT tier, subscription_status, grace_until
FROM users WHERE id = $1`) because the JWT tier can be 15 min stale. Handles
`INACTIVE_STATUSES = {unpaid, expired, paused}`, `cancelled` + `grace_until`, and
`TRIAL_GRANTS_TIER = { on_trial: 'pro' }`. On insufficient tier:

```js
return res.status(403).json({
  error: `This feature requires a ${minTier} plan or higher`,
  code: 'INSUFFICIENT_TIER',
  currentTier: effectiveTier,
  requiredTier: minTier,
});
```

Mutates `req.user.tier = effectiveTier` and `req.user.subscriptionStatus` for downstream use.

**Important observation for the design:** `requireTier` exists but **is not used by the interview
paths**. Both `/room/create` and `/meetings/schedule` instead do an inline check against the
JWT-carried tier using `tiers.isFeatureAllowed(req.user.tier, tiers.FEATURES.HOST_INTERVIEW)` and
hand-roll the same 403 body. A new interviewer-side endpoint has a genuine choice here; the
*interview-feature precedent* is the inline `tiers.isFeatureAllowed` form (§3, §5.1).

### 2.4 `auditLog` — line 713, the only `audit_events` writer

```js
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
```

Never awaited at call sites — fired and forgotten so it can never break a flow.
Exported from `auth.js`'s `module.exports` (line 725).

Existing `event_type` values (all `snake_case`, all ≤ 50 chars): `register`, `login_success`,
`login_failure`, `session_compromised`, `logout`, `logout_all`, `change_password_failure`,
`change_password_success`, `account_deleted`, `session_revoked`, `email_change_requested`,
`email_changed`, `password_reset_requested`, `password_reset_completed`, `email_verified`,
`oauth_exchange`, `profile_update`.

PII rule already in force: `pseudonymizeEmail(email)` (`index.js:479`) HMAC-SHA256s the address
unless `AUDIT_LOG_FULL_EMAIL === 'true'`. A verification audit trail must not log raw biometric
data or a raw photo reference the same way an email would be redacted.

---

## 3. `token-server/tiers.js` — the tier SSOT

75 lines, pure, dependency-free. Exact contents that matter:

```js
const TIER_RANKS = Object.freeze({ free: 0, pro: 1, hiring: 2 });

const FEATURES = Object.freeze({
  HOST_INTERVIEW:      'hostInterview',
  CLOUD_RECORDING:     'cloudRecording',
  SCHEDULED_MEETINGS:  'scheduledMeetings',
  CHAT_EXPORT:         'chatExport',
  COLLAB_CODE_EDITOR:  'collabCodeEditor',
  COLLAB_WHITEBOARD:   'collabWhiteboard',
});

const FEATURE_MIN_TIER = Object.freeze({
  [FEATURES.HOST_INTERVIEW]:     'hiring',
  [FEATURES.COLLAB_CODE_EDITOR]: 'hiring',
  [FEATURES.COLLAB_WHITEBOARD]:  'hiring',
  [FEATURES.CLOUD_RECORDING]:    'pro',
  [FEATURES.SCHEDULED_MEETINGS]: 'pro',
  [FEATURES.CHAT_EXPORT]:        'pro',
});
```

Exports: `TIER_RANKS, FEATURES, FEATURE_MIN_TIER, rankOf, tierMeets, isFeatureAllowed,
minTierForFeature`. `isFeatureAllowed` fails **closed** on an unknown feature (`return false`).

**Correction:** `tiers.js` contains **no middleware**. `requireTier` lives in `auth.js` (§2.3).
`tiers.js` is pure predicates only.

Client mirror: `inter/Networking/InterFeatureGate.h/.m` (80/95 lines) — `InterFeatureHostInterview`.
Per the header comment in `tiers.js`, adding a feature means editing **both** `FEATURE_MIN_TIER`
here and the one-line entry in `InterFeatureGate.m`.

`toolsEntitlement(hostTier)` (`index.js:464`) is the existing precedent for deriving an in-room
entitlement flag from the **room creator's** tier, not the joiner's:

```js
function toolsEntitlement(hostTier) {
  return tiers.isFeatureAllowed(hostTier, tiers.FEATURES.HOST_INTERVIEW);
}
```

It is stamped into the LiveKit JWT metadata as `{ role, tools }` for every participant, so the
*candidate* of a hiring host's room is entitled regardless of their own plan. Face verification
should follow this same "host tier decides, stamped server-side into metadata" shape.

Tests: `test/tiers.test.js`, `test/toolsEntitlement.test.js`, `test/interviewTierGate.test.js`.

---

## 4. `token-server/joinGuards.js` — **correction to the assumed context**

The assumed context says joinGuards.js holds "join-time gating — likely integration point".
**That is wrong.** The file is 62 lines and contains exactly one factory:

```js
function createJoinCapGuard({ roomService, maxParticipants, logger = console }) {
  return async function isJoinWithinCap({ roomName, redisCount, alreadyIn }) { … };
}
module.exports = { createJoinCapGuard };
```

It is **only** the participant-cap cross-check (Redis count vs authoritative LiveKit
`numParticipants`). It is dependency-injected purely so it unit-tests without Redis/LiveKit
(`test/joinGuards.test.js`). It is **not** a guard chain and has no extension point for a
verification gate.

The real guard chain is written inline inside the `/room/join` handler. See §5.2.

Sibling files with the same DI-for-testability shape (the house pattern for extractable logic):
`roomReconcile.js` (`createReconcileEmptyRoom`), `recordingQuota.js`
(`isRecordingOverCap` + `createOverdueRecordingSweeper`).

---

## 5. The fail-closed hook points — named by file, function and line

### 5.1 Interviewer side: `/room/create` — `index.js:2375`

```js
app.post('/room/create', auth.requireAuth, requireIdempotencyKey, async (req, res) => {
  …
  const roomType = (rawRoomType === 'interview') ? 'interview' : 'call';

  if (roomType === 'interview' &&
      !tiers.isFeatureAllowed(req.user && req.user.tier, tiers.FEATURES.HOST_INTERVIEW)) {
    return res.status(403).json({
      error: 'Hosting an interview requires a hiring plan.',
      code: 'INSUFFICIENT_TIER',
      currentTier: (req.user && req.user.tier) || 'free',
      requiredTier: tiers.minTierForFeature(tiers.FEATURES.HOST_INTERVIEW),
    });
  }
```

Then, in order: enum validation → `checkRateLimit(identity)` → room-code collision loop →
**LiveKit reachability probe** (`roomService.listRooms` → 503 if down, *before* any Redis write) →
Redis pipeline writing the `room:{CODE}` hash → JWT mint → `redis.hset(roomRolesKey, identity,
'interviewer')` → `roomUserBindingKey` (identity→userId) → `leaveToken` → best-effort
`INSERT INTO meetings` + `meeting_participants` → response.

Fields the room hash gets at creation (exact names, all strings):
`roomName, createdAt, hostIdentity, roomType, hostTier, meetingDisplayName, muteOnJoin,
cameraOffOnJoin, joinBeforeHost, allowUnmuting, chatPermissions, sharingPermissions,
shareConflictPolicy, autoRecord, autoTranscript, lobbyEnabled, passwordHash`
— plus `meetingId` written after the DB insert, and `metadata` (JSON string) written by the
recording paths.

**This is where a `requireFaceVerification` room setting would be snapshotted**, alongside
`lobbyEnabled`/`passwordHash`, so it is server-authoritative for the room's whole life.

### 5.2 Candidate side: `/room/join` — `index.js:2558`. The authoritative gate order.

```js
app.post('/room/join', rateLimitJoin, async (req, res) => {
```

Exact sequence, with line numbers:

| # | Line | Gate | Reject shape |
|---|---|---|---|
| 0 | 2558 | `rateLimitJoin` middleware (per-IP 60/60s, per-`clientId` 30/60s) | `429 { error }` |
| 1 | 2561 | body validation: `roomCode, identity, displayName` required | `400 { error }` |
| 2 | 2565 | `checkRateLimit(identity)` (10/60 s) | `429 { error }` |
| 3 | 2570 | `getRoomData(code)`; if absent, look up `scheduled_meetings` and auto-register when `settings.joinBeforeHost === true` | `404 { error, notStarted:true }` / `404 { error }` |
| 4 | 2607 | **ban check** `redis.sismember(roomBannedKey(code), identity)` — deliberately first so nothing can bypass it | `403 { error, banned:true }` |
| 5 | 2619 | **returning-host restoration** — compares `req.user.userId` against `roomUserBindingKey(code)[hostIdentity]`. Sets `isReturningHost`, which exempts #6–#9. | — |
| 6 | 2630 | meeting lock `redis.exists(roomLockedKey(code))` | `423 { error }` |
| 7 | 2637 | password: `bcrypt.compare` + per-principal lockout `ratelimit:join-pwd:{code}:{u:id\|ip:ip}` 8 guesses / 300 s | `401 { error, passwordRequired:true }` / `429` |
| 8 | 2668 | lobby: `zadd` to `roomLobbyKey`, cap `MAX_LOBBY_WAITERS = 200`, mints a 32-byte `pollToken` | `200 { status:'waiting', position, pollToken }` / `503 { error, lobbyFull:true }` |
| 9 | 2702 | join-before-host (host presence in participants set) | `403 { error, hostNotYetJoined:true }` |
| 10 | 2715 | participant cap → `isJoinWithinCap` (the `joinGuards.js` guard) | `403 { error, maxParticipants, participantCount }` |
| 11 | 2731 | **token issuance begins** — role assignment, `createToken`, `addParticipant`, roles/names/binding hsets, `leaveToken`, best-effort `meeting_participants` insert, response | `200 { roomName, token, serverURL, … }` |

Role assignment at step 11 (line 2734) is where `interviewee` is decided:

```js
const joinerRole = isReturningHost
  ? ((roomData.roomType === 'interview') ? 'interviewer' : 'host')
  : ((roomData.roomType === 'interview') ? 'interviewee' : 'participant');
const metadata = { role: joinerRole, tools: toolsEntitlement(roomData.hostTier) };
const jwt = await createToken(identity, displayName, roomData.roomName, isReturningHost, metadata);
await addParticipant(code, identity);
```

Note the stored role is normalised: `storedRole = isReturningHost ? joinerRole : (joinerRole ===
'interviewee' ? 'participant' : joinerRole)` — Redis `roomRolesKey` holds `participant` for a
candidate even though the JWT metadata says `interviewee`.

**The fail-closed verification hook point, precisely:**

> Insert the verification gate **between step 10 and step 11** — i.e. after the cap check and
> **before** `createToken` / `addParticipant`. This is the only position that is genuinely
> fail-closed, because it is the last point at which no LiveKit JWT has been minted and no
> participant-set membership exists. Placing it after step 11 would mean the candidate already
> holds a room-join grant.

The precedent for "gate returns a non-token response that the client then polls" is the **lobby**
at step 8: it returns `200 { status:'waiting', position, pollToken }` with no JWT, and the client
polls `GET /room/lobby-status/:code/:identity` (`index.js:3715`) with an `x-poll-token` header
until the server flips `room:{code}:lobby:{identity}:status` to `admitted` and hands over the
**pre-minted token** stored at `room:{code}:lobby:{identity}:token`. That admitted branch returns
the full settings payload and then `redis.del`s all four per-join keys. This is the exact shape a
face-verification "pending → verified → token" flow should copy; it is proven, rate-limited
(`rateLimitLobbyPoll`, 240/60 s per IP), and authenticated by a per-join secret compared with
`constantTimeEqual` (`index.js:445`, SHA-256-then-`timingSafeEqual`).

### 5.3 Also-relevant: scheduling-time gate — `scheduling.js:163`

`POST /meetings/schedule` repeats the identical inline interview tier check, with
`error: 'Scheduling an interview requires a hiring plan.'`. If the reference photo can be uploaded
at scheduling time, this is the gate that already protects that path.

---

## 6. `token-server/crypto.js` — the real encrypted-column pattern

78 lines of logic. **AES-256-GCM, key-versioned, operating on UTF-8 strings.**

```
Stored format:  v{N}:{iv_hex}:{authTag_hex}:{ciphertext_hex}
ALGORITHM       = 'aes-256-gcm'
IV_LENGTH       = 12   (96-bit, NIST GCM recommendation)
AUTH_TAG_LENGTH = 16   (128-bit)
```

Env vars: `ENCRYPTION_ACTIVE_VERSION` (write-key version, e.g. `1`) and
`ENCRYPTION_SECRET_V{N}`. `loadKeys()` scans `V1`…`V100`; each key is parsed by `parseKeyBuffer`
(hex ≥64 chars → base64url → base64 → utf-8 fallback), must be ≥ 32 bytes, truncated to exactly 32.

Exported API — exact signatures:

```js
encryptToken(plaintext)        // → "v{N}:{iv}:{tag}:{ct}" | null  (null when no active key)
decryptToken(blob)             // → plaintext | null (null on bad format, missing key version, or auth failure)
getActiveVersion()             // → number | null
hasKeyVersion(version)         // → boolean
isEncryptionAvailable()        // → boolean
```

Degrades to warning + `null` when unconfigured — the server still starts.

### 6.1 Env reality

`ENCRYPTION_ACTIVE_VERSION=1` and a 64-hex-char `ENCRYPTION_SECRET_V1` are present in
`token-server/.env` (lines 59–60). **They are absent from `token-server/.env.example`** — a
real gap worth fixing in the design's deployment section, since a fresh clone on a second device
(which the user is explicitly planning) would start with encryption unavailable.

### 6.2 The one existing encrypted-column pattern — `users`, migration 016

```sql
ALTER TABLE users ADD COLUMN IF NOT EXISTS google_refresh_token TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS google_token_key_version SMALLINT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS google_reauth_required BOOLEAN NOT NULL DEFAULT false;
-- same triple for outlook_*
```

So the convention is: **`TEXT` for the versioned ciphertext blob + a companion
`*_key_version SMALLINT`**, written together. Write site (`calendar.js:170`):

```js
const encrypted = tokenCrypto.encryptToken(tokenRes.body.refresh_token);
if (!encrypted) {
  return res.status(500).send('<h3>Encryption error</h3>…');   // fail closed
}
await db.query(
  `UPDATE users
   SET google_refresh_token = $1, google_token_key_version = $2, google_reauth_required = false
   WHERE id = $3`,
  [encrypted, tokenCrypto.getActiveVersion(), userId]
);
```

Read site (`calendar.js:228`): `tokenCrypto.decryptToken(userRow.rows[0].google_refresh_token)`.
The `key_version` column is informational/for rotation sweeps — `decryptToken` reads the version
from the blob prefix itself.

Only `calendar.js` uses `crypto.js` today. `crypto.js` is used **nowhere else** in the server.

### 6.3 Verdict for the design

- **Reusable as-is** for a *string* secret bound to the verification record (e.g. a signed decision
  token, a storage key, an embedding serialised to base64).
- **Not suitable for the image bytes themselves.** `encryptToken` takes `plaintext` as
  `'utf8'` and `decryptToken` returns `'utf8'` — binary JPEG bytes would be corrupted unless
  base64-encoded first (≈33 % inflation, whole blob in memory, whole blob in one Postgres `TEXT`).
  If the design encrypts a photo at rest it must either (a) base64 the bytes before
  `encryptToken` and accept the inflation, (b) add a `encryptBuffer`/`decryptBuffer` pair to
  `crypto.js` reusing the same `v{N}:{iv}:{tag}:{ct}` framing and key store, or (c) keep bytes
  out of Postgres entirely (the existing chat-file precedent puts bytes on disk/S3 and metadata in
  Redis — §7.2) and encrypt only the *reference*. (b) is the smallest change that preserves the
  key-versioning SSOT.
- Existing DDL style to match: `TEXT` + `*_key_version SMALLINT`.

---

## 7. `token-server/fileValidation.js` — what we get free, what is missing

68 lines. Pure, no I/O. Exports:

```js
module.exports = { ALLOWED_MIME_PREFIXES, BLOCKED_MIME_EXACT, isMimeAllowed, sanitizeFilename };
```

### 7.1 What it actually does

- `ALLOWED_MIME_PREFIXES` — includes **`'image/'`** first, plus `application/pdf`, `text/`,
  `application/vnd.`, msword, ms-excel, ms-powerpoint, rtf, zip, x-zip-compressed.
- `BLOCKED_MIME_EXACT` — a `Set` checked **before** the prefix allowlist, so it wins. Contains the
  executables *and*, critically for an image upload, **`'image/svg+xml'`**, `'text/html'`,
  `'text/javascript'`, `'text/xml'`, `'application/xhtml+xml'`.
- `isMimeAllowed(mime)` → `false` for null/empty; lowercases; blocklist first, then prefix match.
- `sanitizeFilename(rawName)` → `path.basename` (strips traversal) → `replace(/[^\w.\-]/g,'_')` →
  `.slice(0, 200)` → fallback `'file'`.

Module header states the contract explicitly:

> The MIME passed in MUST be the magic-byte-detected type (e.g. from file-type), never the
> client-supplied Content-Type header, which is trivially spoofed.

Tests: `test/fileValidation.test.js` already asserts `isMimeAllowed('image/png')` and
`isMimeAllowed('image/jpeg')` are `true`.

### 7.2 The upload pipeline it plugs into — `index.js:5157`–`5296`

Constants and wiring (exact):

```js
const CHAT_FILE_MAX_BYTES       = 10 * 1024 * 1024;   // 10 MB per file
const CHAT_ROOM_MAX_TOTAL_BYTES = 200 * 1024 * 1024;  // 200 MB per room
const CHAT_UPLOAD_DIR = path.join(os.tmpdir(), 'inter-chat-uploads');
fs.mkdirSync(CHAT_UPLOAD_DIR, { recursive: true });

const chatFileStorage = multer.diskStorage({
  destination: (_req, _file, cb) => cb(null, CHAT_UPLOAD_DIR),
  filename:    (_req, _file, cb) => cb(null, crypto.randomUUID()),
});
const chatUpload = multer({ storage: chatFileStorage, limits: { fileSize: CHAT_FILE_MAX_BYTES, files: 1 } });
```

`POST /room/:code/file/upload` (line 5205) — the end-to-end sequence worth copying:

1. `chatUpload.single('file')` writes to disk under a **UUID filename** (original name never
   touches the FS).
2. `cleanup()` closure `fs.unlink`s the temp file on *every* early return.
3. Auth is **not** JWT — it is the per-participant `leaveToken` from join/create, compared against
   `redis.get(roomLeaveTokenKey(code, identity))` → `403 { error: 'Unauthorized' }`.
4. `FileType.fromFile(tempPath)` (`file-type@16`, CommonJS) for magic bytes; `undefined` →
   `'text/plain'` fallback. Failure → `500 { error: 'Could not determine file type' }`.
5. `isMimeAllowed(detectedMime)` → `415 { error: 'File type not allowed' }`.
6. Per-room cumulative cap via an **atomic Lua script** (`INCRBY` + conditional `EXPIRE` in one
   round-trip), rolled back with `DECRBY` on overflow → `413`.
7. Metadata JSON into `redis.hset(roomFilesKey(code), fileId, …)` with
   `ROOM_CODE_EXPIRY_SECONDS` TTL. `diskPath` is stored server-side and **never** returned.
8. Response returns only `{ fileId, originalName, mimeType, sizeBytes }`.

Download (`index.js:5304`) re-validates the `leaveToken` (via a `Leave-Token` header) and guards
path traversal with `path.resolve(meta.diskPath).startsWith(path.resolve(CHAT_UPLOAD_DIR) + path.sep)`.

Cleanup: `deleteRoomFiles(code)` is called from `/room/end` (line 3308), `/room/leave` when the
room empties (3372), and the egress webhook path (4529); plus an hourly `setInterval` TTL sweep
that unlinks anything older than 25 h, `.unref()`ed so tests don't hang.

### 7.3 Verdict: reuse vs. add

**Reuse directly:**
- `isMimeAllowed` — `image/jpeg`, `image/png`, `image/heic` pass; `image/svg+xml` is already
  blocked, which is the main stored-XSS risk for an image upload.
- `sanitizeFilename`.
- The whole multer-to-disk-with-UUID + magic-byte + cleanup-on-every-return + Redis-metadata
  shape, and the Lua atomic size cap.
- `multipart/form-data` as the transport, which sidesteps the 100 KB `express.json()` cap (§1.1).

**Must be added — `fileValidation.js` does not have it:**
1. **No image-specific allowlist.** `isMimeAllowed` admits *any* `image/*` not on the blocklist
   (`image/gif`, `image/tiff`, `image/vnd.*`, `image/webp`, …). A reference photo needs a narrow
   allowlist, e.g. a new exported `ALLOWED_IMAGE_MIMES = new Set(['image/jpeg','image/png','image/heic'])`
   plus an `isReferencePhotoMimeAllowed(mime)` predicate in the same file, so the two upload paths
   still share one hardened module (the file's stated reason for existing).
2. **No pixel-dimension bounds.** Nothing guards a decompression bomb (a 50 KB PNG that expands to
   30 000 × 30 000). Needs an explicit min/max dimension check before any decode into memory.
3. **No size cap tuned for a photo.** 10 MB is the chat cap; a face photo wants something like
   ≤ 5 MB with a sensible minimum (reject a 40 × 40 thumbnail).
4. **No EXIF/metadata stripping or re-encode.** The stored reference photo will carry GPS,
   device, and timestamp EXIF straight from the interviewer's file. For biometric data this is a
   privacy obligation, not a nicety. Re-encoding also normalises away polyglot files.
5. **No animated-image rejection** (animated PNG/WebP), and no `file-type`-vs-decoder agreement
   check.
6. **No per-user upload quota.** `recordingQuota.js` is the only quota accounting in the server and
   it is recording-specific; a photo-upload budget is new (§9).

---

## 8. Scheduling path — can the photo be uploaded at scheduling time?

### 8.1 `scheduled_meetings` — real columns

From `015_scheduling.sql` + `020_scheduled_meeting_settings.sql`:

| Column | Type / constraint |
|---|---|
| `id` | `UUID PRIMARY KEY DEFAULT gen_random_uuid()` |
| `host_user_id` | `UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE` |
| `title` | `VARCHAR(200) NOT NULL` |
| `description` | `TEXT` |
| `scheduled_at` | `TIMESTAMPTZ NOT NULL` |
| `duration_minutes` | `INT NOT NULL DEFAULT 60 CHECK (>0 AND <=1440)` |
| `room_type` | `VARCHAR(20) NOT NULL DEFAULT 'call' CHECK (IN ('call','interview'))` |
| `room_code` | `VARCHAR(6)` |
| `password` | `VARCHAR(100)` — **stored plaintext** (`scheduling.js:198` passes `password \|\| null`) |
| `lobby_enabled` | `BOOLEAN NOT NULL DEFAULT FALSE` |
| `recurrence_rule` | `TEXT` |
| `host_timezone` | `VARCHAR(100) NOT NULL` |
| `status` | `VARCHAR(20) NOT NULL DEFAULT 'scheduled' CHECK (IN ('scheduled','cancelled','completed'))` |
| `created_at`, `updated_at` | `TIMESTAMPTZ NOT NULL DEFAULT NOW()`; `updated_at` maintained by trigger `set_scheduled_meetings_updated_at` → `trigger_set_updated_at()` |
| `settings` | `JSONB NOT NULL DEFAULT '{}'` (migration 020) |

Indexes: `idx_scheduled_meetings_host_upcoming (host_user_id, scheduled_at) WHERE status='scheduled'`;
`idx_scheduled_meetings_room_code (room_code) WHERE room_code IS NOT NULL AND status='scheduled'`.

### 8.2 `meeting_invitees` — real columns

| Column | Type |
|---|---|
| `id` | `UUID PRIMARY KEY DEFAULT gen_random_uuid()` |
| `meeting_id` | `UUID NOT NULL REFERENCES scheduled_meetings(id) ON DELETE CASCADE` |
| `email` | `VARCHAR(255) NOT NULL` |
| `display_name` | `VARCHAR(100)` |
| `status` | `VARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (IN ('pending','accepted','declined'))` |
| `invited_at` | `TIMESTAMPTZ NOT NULL DEFAULT NOW()` |
| `responded_at` | `TIMESTAMPTZ` |

Indexes: `idx_meeting_invitees_meeting (meeting_id)`, `idx_meeting_invitees_email (email)`,
unique `idx_meeting_invitees_unique (meeting_id, email)`.

### 8.3 The `settings` JSONB snapshot pattern

`scheduling.js:176`–`190` validates and whitelists the settings object at schedule time:

```js
const settings = {
  muteOnJoin:          s.muteOnJoin          === true,
  cameraOffOnJoin:     s.cameraOffOnJoin     === true,
  joinBeforeHost:      s.joinBeforeHost      === true,
  allowUnmuting:       s.allowUnmuting       !== false,
  chatPermissions:     VALID_CHAT_PERMS.includes(s.chatPermissions)          ? s.chatPermissions     : 'everyone',
  sharingPermissions:  VALID_SHARE_PERMS.includes(s.sharingPermissions)      ? s.sharingPermissions  : 'hostOnly',
  shareConflictPolicy: VALID_CONFLICT_POLICY.includes(s.shareConflictPolicy) ? s.shareConflictPolicy : 'oneattime',
};
```

Migration 020's comment states the design rule plainly: the settings must come from the meeting
row, **not** from whichever client arrives first, because an invitee may start the room before the
host. `registerScheduledRoom(meeting, {hostIdentity, hostTier, settings})` (`scheduling.js:903`,
re-exported as `router.registerScheduledRoom`) applies them to the Redis room hash, and
`/room/join` calls it for the join-before-host auto-register case (`index.js:2583`).

### 8.4 Concrete evaluation for "upload the reference photo at scheduling time"

- The hook exists and is clean: a `requireFaceVerification` boolean belongs in the `settings`
  JSONB (no migration needed for the flag itself), and `registerScheduledRoom` already carries
  settings into the room hash.
- The **photo itself** does not belong in `settings` — it is binary, and `settings` is a
  validated flat-boolean/enum whitelist.
- A per-candidate reference photo maps naturally onto `meeting_invitees` (one row per expected
  candidate, already uniquely keyed by `(meeting_id, email)`), which is the right grain if the
  design wants "the photo is bound to the person who was invited".
- But an **ad-hoc** interview created via `/room/create` has **no** `scheduled_meetings` row at all
  — the host just gets a room code. So a scheduling-time-only upload cannot cover the ad-hoc path,
  which is the path the user's words describe ("at the starting of the interview"). The design
  needs a room-scoped upload that works for both, with the scheduled path as an optional
  pre-stage.
- `scheduled_meetings.password` being stored plaintext is a pre-existing wart; do not copy it as
  a precedent for anything sensitive.

---

## 9. Redis / ephemeral room state — keys and TTLs

`token-server/redis.js` is 40 lines: a single `ioredis` instance from `REDIS_URL`
(default `redis://localhost:6379`), `maxRetriesPerRequest: 3`, backoff `min(times*200, 2000)` ms
giving up after 10 attempts, `lazyConnect: false`. Exported as the client itself
(`module.exports = redis`).

TTL constant: `ROOM_CODE_EXPIRY_SECONDS = 24 * 60 * 60` (`index.js:165`).

### 9.1 Key helpers — `index.js:2160`–`2178` (verbatim)

```js
function roomKey(code)                      { return `room:${code}`; }
function roomParticipantsKey(code)          { return `room:${code}:participants`; }
function roomRolesKey(code)                 { return `room:${code}:roles`; }
function roomLockedKey(code)                { return `room:${code}:locked`; }
function roomNamesKey(code)                 { return `room:${code}:names`; }
function roomLobbyKey(code)                 { return `room:${code}:lobby`; }
function roomLobbyNamesKey(code)            { return `room:${code}:lobby:names`; }
function roomSuspendedKey(code)             { return `room:${code}:suspended`; }
function roomBannedKey(code)                { return `room:${code}:banned`; }
function roomScreenShareQueueKey(code)      { return `room:${code}:screenshare-queue`; }
function roomScreenShareQueueNamesKey(code) { return `room:${code}:screenshare-queue:names`; }
function roomCameraLockedKey(code)          { return `room:${code}:camera-locked`; }
function roomMicLockedKey(code)             { return `room:${code}:mic-locked`; }
function roomUserBindingKey(code)           { return `room:${code}:user-binding`; }
function roomLeaveTokenKey(code, identity)  { return `room:${code}:leavetoken:${identity}`; }
function roomFilesKey(code)                 { return `room:${code}:files`; }
function roomFilesTotalSizeKey(code)        { return `room:${code}:filesize`; }
```

Not-helper-ised, inline per-identity lobby keys (the template a per-identity verification key
should follow):

```
room:{CODE}:lobby:{identity}:pollToken     // SET … EX ROOM_CODE_EXPIRY_SECONDS
room:{CODE}:lobby:{identity}:status         // 'admitted' | 'denied' | 'room_full'
room:{CODE}:lobby:{identity}:token          // pre-minted LiveKit JWT
room:{CODE}:lobby:{identity}:serverURL
```

Accessors: `getRoomData(code)` = `redis.hgetall(roomKey(code))` → `null` when empty;
`getParticipantCount` = `scard`; `isParticipant` = `sismember`; `addParticipant` = `sadd`.

Every write path sets the TTL explicitly right after the first write (`pipeline.expire(...)` or
`await redis.expire(...)`), because Redis hashes/sets do not inherit a TTL.

Rate-limit namespace (non-room): `ratelimit:*` with its own short TTLs.
Idempotency namespace: `idempotency:{userId}:{METHOD}:{path}:{clientKey}` TTL 86400.

**Where a verification decision should live:** a per-identity Redis key under the room, mirroring
the lobby quartet, TTL `ROOM_CODE_EXPIRY_SECONDS`, e.g. a
`room:{CODE}:faceverify:{identity}` hash holding status/attempts/score plus a separate
pre-minted-token key. Postgres is for the persistent audit record, not the live decision.

### 9.2 `idempotency.js` — the pattern for an idempotent POST

95 lines. `requireIdempotencyKey(req, res, next)`:
- Requires header `X-Idempotency-Key`; missing → `400 { error, code: 'IDEMPOTENCY_KEY_REQUIRED' }`.
- Validates against a strict UUID-v4 regex; bad → `400 { error, code: 'IDEMPOTENCY_KEY_INVALID' }`.
- Redis key: `idempotency:{userId|'anon'}:{method}:{baseUrl}{path}:{clientKey}`, TTL
  `IDEMPOTENCY_TTL = 86400`.
- Cache hit → replays `{statusCode, body}` without running the handler. Corrupt entry → treated
  as a miss.
- Miss → monkey-patches `res.json` to capture and cache **only 2xx** responses (errors stay
  retryable).
- **Redis down → fails open** ("Duplicates are better than a total outage").

Used today on exactly three endpoints: `POST /room/create`, `POST /meetings/schedule`,
`POST /meetings/:id/invite`. A reference-photo upload is a state-mutating POST that a flaky
network will retry, so it is a natural fourth. Note it caches `res.json` only — a multipart
handler must still respond via `res.json` for the cache to engage.

### 9.3 `recordingQuota.js` — the quota/sweeper pattern

97 lines, DI'd. Two pieces:
- `isRecordingOverCap(elapsedSeconds, maxDurationSeconds)` — a pure predicate; `null` cap means
  "never force-stopped"; non-finite/≤0 → `false`.
- `createOverdueRecordingSweeper({db, egressClient, redis, roomKey, logger})` → `sweepOnce()`,
  which selects active rows, stops the over-cap ones, marks them `finalizing`, and clears the
  room's `metadata.recording` flag best-effort.

The transferable idea: **persist the limit at the moment of the decision** (the recording stores
`max_duration_seconds` = remaining quota at start) and have a periodic sweeper enforce it, rather
than trusting a client-supplied number. For face verification the analogue is persisting the
attempt budget / expiry server-side at gate time.

Per-user quota accounting itself lives in `index.js` (`RECORDING_QUOTAS = { free: 0, pro: 600,
hiring: 1200 }` minutes, env-overridable via `RECORDING_QUOTA_PRO` / `RECORDING_QUOTA_HIRING`).

---

## 10. Migrations — the real inventory and DDL house style

### 10.1 Inventory (verified `ls`)

`001_initial_schema` · `002_recording_sessions` · `003_multitrack_tracks` · `004_refresh_tokens` ·
`005_rename_predecessor_id` · `006_billing_columns` · `007_add_pro_plus_tier` ·
`008_payment_url_and_sub_index` · `009_password_reset_tokens` · `010_email_verification` ·
`011_audit_events` · `012_session_hardening` · `013_email_change_tokens` · `014_oauth_social` ·
`015_scheduling` · `016_calendar_teams` · `017_meetings_failed_status` · `018_team_chat` ·
`019_user_prefs` · `020_scheduled_meeting_settings` · `021_recording_max_duration` ·
`022_rename_pro_plus_to_hiring`

**Highest = 022. Next filename = `023_<snake_case_description>.sql`.**

Naming convention: zero-padded 3-digit prefix, `_`, lower `snake_case` description, `.sql`.
`README.md` carries a (stale — only 6 of 22 rows) migration table at line ~392 that a new
migration should extend.

### 10.2 Runner — `migrate.js`

- `ensureMigrationsTable()` creates `schema_migrations(id SERIAL PK, filename VARCHAR(255) UNIQUE
  NOT NULL, applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW())`.
- Pending = files ending `.sql`, `.sort()`ed lexicographically, minus applied.
- Each migration runs in its **own transaction**: `BEGIN` → the whole file → `INSERT INTO
  schema_migrations` → `COMMIT`; any error → `ROLLBACK` and `process.exit(1)`.
- Forward-only. There is **no down-migration mechanism**.
- Invoked as `node migrate.js` from `token-server/`.

### 10.3 DDL style, as practised

- `id UUID PRIMARY KEY DEFAULT gen_random_uuid()` on every new table.
- FKs always name the policy explicitly: `ON DELETE CASCADE` for ownership
  (`scheduled_meetings.host_user_id`, `meeting_invitees.meeting_id`, `teams.owner_user_id`,
  `team_members.team_id`); `ON DELETE SET NULL` where the row must survive the user
  (`audit_events.user_id`, `team_members.user_id`).
- Enumerations as `VARCHAR(n) NOT NULL DEFAULT '…' CHECK (col IN (…))` — no Postgres `ENUM` types
  anywhere.
- Timestamps: `TIMESTAMPTZ NOT NULL DEFAULT NOW()` for `created_at`/`updated_at`;
  `updated_at` maintained by `CREATE TRIGGER set_<table>_updated_at BEFORE UPDATE … EXECUTE
  FUNCTION trigger_set_updated_at()` (the function is defined in `001_initial_schema.sql`).
- Index naming: `idx_<table-or-abbrev>_<purpose>`, e.g. `idx_scheduled_meetings_host_upcoming`,
  `idx_ae_user`. **Partial indexes are used liberally** (`WHERE status = 'scheduled'`).
- `ALTER TABLE … ADD COLUMN IF NOT EXISTS` for additive changes (016, 020) so re-runs are safe.
- Later migrations use `IF NOT EXISTS` on `CREATE TABLE`/`CREATE INDEX` (016); earlier ones don't.
- Migrations carry a header comment block stating the phase and the intent, and sometimes an
  explicit `-- ASSERT:` precondition (see the top of 015) — a convention worth matching.
- Encrypted columns: `TEXT` for the blob + `*_key_version SMALLINT` (§6.2).

### 10.4 `audit_events` — the real DDL (`011_audit_events.sql`, verbatim)

```sql
CREATE TABLE audit_events (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID REFERENCES users(id) ON DELETE SET NULL,
    event_type VARCHAR(50) NOT NULL,
    ip_address INET,
    metadata   JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_ae_user ON audit_events (user_id, created_at DESC);
CREATE INDEX idx_ae_type ON audit_events (event_type, created_at DESC);

CREATE OR REPLACE FUNCTION prevent_audit_modification()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'audit_events is append-only: % is not permitted', TG_OP;
END;
$$;

CREATE TRIGGER audit_events_no_update
  BEFORE UPDATE ON audit_events
  FOR EACH ROW EXECUTE FUNCTION prevent_audit_modification();

CREATE TRIGGER audit_events_no_delete
  BEFORE DELETE ON audit_events
  FOR EACH ROW EXECUTE FUNCTION prevent_audit_modification();
```

Consequences the design must respect:

1. **Append-only is enforced by DB triggers**, not convention. No `UPDATE`/`DELETE` is possible
   from any code path. A verification record that needs to *change* (pending → verified) cannot be
   an `audit_events` row; it needs its own table (or Redis), with `audit_events` recording the
   immutable *transitions*.
2. `event_type` is capped at **50 characters**.
3. There is **no room_code / meeting_id column** — room correlation must go in `metadata` JSONB.
4. `user_id` is nullable and `ON DELETE SET NULL`. A guest candidate (no account) has no
   `user_id`, so a candidate-side verification event is a `NULL user_id` row with the identity in
   `metadata`. `index.js:858` notes account deletion "anonymize[s] PII — keep row for audit_events
   FK integrity".
5. Retention: **none**. No purge job, no partitioning. Biometric-adjacent audit rows accumulate
   forever; the design should say something about this.

**How to write to it:** `auth.auditLog(userId, 'face_verify_…', req.ip, { roomCode, identity, … })`,
not awaited. Do not hand-roll an `INSERT`.

---

## 11. Client (macOS) reality

Project: `inter.xcodeproj`, single shared scheme `inter.xcscheme`,
`MACOSX_DEPLOYMENT_TARGET = 15.6`. SPM pins (exact versions):
`livekit/client-sdk-swift` **2.15.0** (exactVersion), `socketio/socket.io-client-swift` **16.1.1**,
`apple/swift-atomics` upToNextMajor 1.2.0. LiveKit SDK version in the assumed context is correct.

Entitlements (`inter/inter.entitlements`): app-sandbox **on**, `device.camera`,
`device.audio-input`, `files.user-selected.read-write` (so an `NSOpenPanel` photo pick works),
`network.client`, `network.server`, `personal-information.calendars`.
`Info.plist` already declares `NSCameraUsageDescription` and `NSMicrophoneUsageDescription`.

### 11.1 Endpoint configuration — `inter/Networking/InterAppConfig.swift` (59 lines)

```
liveKitServerURL : env INTER_LIVEKIT_URL → Info.plist InterLiveKitServerURL → "ws://localhost:7880"
tokenServerURL   : env INTER_TOKEN_URL   → Info.plist InterTokenServerURL   → "http://localhost:3000"
```

`Info.plist` currently holds `ws://localhost:7880` and `http://localhost:3000`.
There is also `InterAppConfig.isInsecureRemote(_:)` which flags cleartext `http`/`ws` to a
**non-loopback** host — the guard that will fire the moment a LiveKit Cloud or remote token URL is
pasted without TLS.

**Relevant to the parallel LiveKit-Cloud task:** the *server* also decides the URL it hands
clients. `/room/join` and `/room/create` return
`serverURL: process.env.LIVEKIT_SERVER_URL || 'ws://localhost:7880'`, and the server talks to
LiveKit over `LIVEKIT_HTTP_URL` for `RoomServiceClient`/`EgressClient`. So switching to cloud is
three env values (`LIVEKIT_SERVER_URL`, `LIVEKIT_HTTP_URL`, `LIVEKIT_API_KEY`/`SECRET`) plus,
optionally, the client's `InterLiveKitServerURL` — but the client normally uses the
server-supplied `serverURL` from the join/create response, not its own config, so the env values
are the operative ones.

### 11.2 `InterTokenService.swift` (3,887 lines) — request + error surfacing + pinning

**Request helpers** (the ones to extend): `performRequest(url:body:retryCount:bearerToken:completion:)`
and `performAuthHTTPRequest(url:method:body:bearerToken:retryCount:completion:)`. Both take a
`bearerToken` (usually `currentAccessToken`) and complete on the main queue via `completeOnMain`.
There is an `InterCircuitBreaker` (line 193) in front of the auth session and a `cacheQueue`-guarded
`leaveTokenStore[roomCode]` and token cache keyed `"roomCode:identity"`.

**Error surfacing to the UI** is a two-step mapping:
1. `InterNetworkErrorCode` (`inter/Networking/InterNetworkTypes.swift:330`) — an `Int` enum
   starting at 1000. Currently 1000–**1020**, so **the next free raw value is 1021**. Existing:
   1000 `tokenFetchFailed`, 1001 `connectionFailed`, 1002 `publishFailed`, 1003 `subscribeFailed`,
   1004 `tokenExpired`, 1005 `serverUnreachable`, 1006 `roomCodeInvalid`, 1007 `roomCodeExpired`,
   1008 `roomFull`, 1009 `meetingLocked`, 1010 `lobbyWaiting`, 1011 `passwordRequired`,
   1012 `authFailed`, 1013 `sessionExpired`, 1014 `sessionCompromised`, 1015 `passwordIncorrect`,
   1016 `roomBanned`, 1017 `hostNotPresent`, 1018 `callServerUnavailable`, 1019 `tooManyAttempts`,
   1020 `consentDeclined`.
2. `isExpectedJoinRejection` (same file) — a computed `Bool` that lists the benign join
   rejections. Anything in this list is surfaced inline by the setup panel and must **not** drive
   the room to `.disconnectedWithError` (which would pop the mid-call "Connection Lost" alert).
   **A new face-verification rejection code must be added to this switch**, or the candidate will
   see a bogus connection-lost alert.
3. `AppDelegate -userFacingMessageForError:` (`AppDelegate.m:2387`) maps each numeric code to a
   user-facing string and ends with a `T3` rule: never leak raw `NSError.localizedDescription`;
   log it and return a generic string.

`joinRoom` (line 1019) shows how a non-token 200 is turned into an error: the lobby
`{status:"waiting"}` branch builds an `NSError` with code `.lobbyWaiting` and stuffs `position`
and `pollToken` into `userInfo`. A verification-required response should be surfaced the same way.

**TLS pinning** — `class InterPinnedSessionDelegate: NSObject, URLSessionDelegate`, same file,
line 3741. Installed only on the auth session (`InterTokenService.init()` line 883 builds
`authConfig` with `timeoutIntervalForRequest = 10.0` and `delegate: pinnedDelegate`; the test
initialiser at line 907 bypasses pinning).

```swift
private let pinnedSPKIHashes: Set<String> = [
    // TODO: Populate with production server SPKI SHA-256 hashes before shipping.
]
```

- The set is **empty today**, and the delegate explicitly falls through to
  `completionHandler(.performDefaultHandling, nil)` when it is empty — "development/CI mode only.
  This branch must never execute in production."
- When populated: extracts the leaf cert (`SecTrustCopyCertificateChain` on macOS 12+),
  `SecCertificateCopyKey`, then `spkiHash(for:)` reconstructs SubjectPublicKeyInfo DER by
  prepending a hardcoded ASN.1 header (RSA 2048/4096, EC P-256/P-384 only — anything else is
  rejected) and returns base64 SHA-256. Mismatch → `.cancelAuthenticationChallenge`.
- Rotation policy is documented in the header comment: add the new pin **before** deploying the
  cert, remove the old one after a 24–72 h window, always keep a backup pin.

**Implications for the design, both of which matter:**
- A new verification endpoint on the token server is automatically covered by whatever pinning
  state exists — nothing extra to wire, but also nothing protecting it today.
- **Pinning does not cover LiveKit.** The LiveKit Swift SDK makes its own WebSocket/WebRTC
  connections and never sees `pinnedDelegate`. So a LiveKit Cloud URL is protected by system
  trust only. Worth stating explicitly rather than implying pinning is end-to-end.
- The chat-file upload (`uploadChatFile`, line 1205) uses `session.dataTask` — the **non**-pinned
  session — not `authSession`. A photo upload modelled on it would inherit that.

### 11.3 Media layer — can a still frame be grabbed without disturbing the published track?

**Yes, and there are two existing seams. No new AVCaptureSession is needed, and adding one would
be wrong (the camera device is single-owner).**

`inter/Media/InterLocalMediaController.h/.m` owns the one `AVCaptureSession`. Public contract:

```objc
@property (nonatomic, readonly, nullable) AVCaptureSession *captureSession;
@property (nonatomic, readonly, nullable) dispatch_queue_t sessionQueue;
// "Callers MUST use sessionQueue for all session-related work.
//  Callers MUST NOT call startRunning/stopRunning."

typedef void (^InterLocalMediaVideoFrameObserver)(CVPixelBufferRef pixelBuffer);
@property (atomic, copy, nullable) InterLocalMediaVideoFrameObserver recordingFrameObserver;
@property (atomic, copy, nullable) InterLocalMediaCameraStateObserver recordingCameraStateObserver;
```

**Seam A — `recordingFrameObserver`.** Already exactly a "give me local camera CVPixelBuffers"
hook. Setting it non-nil causes `InterLocalMediaController.m` to add its own
`AVCaptureVideoDataOutput` (`_videoDataOutput`, line 38) delivering BGRA buffers on
`_videoFrameOutputQueue` (`"secure.inter.media.local.video.recording"`, line 83); setting it nil
removes the output. The setter (line 920) copies the block and hops to `_sessionQueue`.
**Caveat: it is a single-slot property, already owned by `InterRecordingCoordinator`.** Taking it
would break local recording's camera PiP. Either the property becomes multi-observer, or
verification uses Seam B.

**Seam B — the LiveKit camera source's delegate.**
`inter/Networking/InterLiveKitCameraSource.swift` (318 lines) adds a *second*
`AVCaptureVideoDataOutput` to the same session and forwards every frame zero-copy into
`BufferCapturer.capture(sampleBuffer)`:

```swift
public func captureOutput(_ output: AVCaptureOutput,
                          didOutput sampleBuffer: CMSampleBuffer,
                          from connection: AVCaptureConnection) {
    guard isCapturing, let capturer = bufferCapturer else { return }
    guard cameraState != .muted && cameraState != .muting else { framesDropped += 1; return }
    if cameraState == .enabling, let callback = pendingUnmuteCallback { … }
    capturer.capture(sampleBuffer)
    framesSent += 1
}
```

Its own header states the isolation invariant: *"This class never modifies the capture session's
input configuration. It only adds/removes its own output."* So the established, sanctioned pattern
for a new consumer is **to add its own `AVCaptureVideoDataOutput` to the existing session** — the
session already carries ≥2 outputs in practice (preview layer + LiveKit + optional recording), and
`output.videoSettings` is pinned to `kCVPixelFormatType_32BGRA` precisely to stop format
renegotiation from disturbing the other outputs.

The state machine to respect: `cameraState` ∈ `.active / .muting / .muted / .enabling`
(`InterCameraNetworkState`), with `preMute()`, `beginMute(completion:)`, `beginEnable()`. A
verification frame grab must not fire while `.muted` or the candidate's camera is off, and must not
call `track.mute()/unmute()` itself.

**What is NOT available today:**
- **No `AVCapturePhotoOutput`, no `AVCaptureStillImageOutput`.** Zero hits across the client. A
  "take a photo" API does not exist; a still must be derived from a video frame.
- **No `Vision` framework usage at all** — no `import Vision`, no `VNDetectFaceRectanglesRequest`,
  no `CIDetector`. On-device face detection/embedding is entirely greenfield. (It is available on
  macOS 15.6 with no new dependency; it is just not wired.)
- **No JPEG/PNG encoder path for a camera frame.** The closest prior art is
  `inter/Media/Sharing/Sources/InterViewSnapshotVideoSource.m` which does the *inverse*
  (`CGImage` → `CVPixelBuffer`, lines 336–380) and uses `cacheDisplayInRect:` to snapshot an
  `NSView`. The `CVPixelBuffer` → `CGImage`/JPEG direction would be new code, though
  `CIImage(cvPixelBuffer:)` makes it short.
- Related test prior art: `interTests/AVPipeline/InterViewSnapshotScalingTests.swift`,
  `interTests/CaptureFidelitySpikeTests.swift` (proves `cacheDisplayInRect:` is safe for SwiftUI
  surfaces), `interTests/InterLiveKitCameraSourceTests.swift`,
  `interTests/InterCameraWiringTests.swift`.

**Files that would change for a frame grab:** either
`inter/Media/InterLocalMediaController.h/.m` (to make `recordingFrameObserver` multi-slot or add a
dedicated one-shot `captureStillFrameWithCompletion:`), **or** a new source file alongside
`InterLiveKitCameraSource.swift` following its exact isolation invariant. The latter is more
consistent with how this codebase has added every previous consumer.

### 11.4 `AppDelegate.m` (7,316 lines) — where a pre-join verification gate sits

**The gate already exists.** `AppDelegate.m:334`–`350`, wired once at launch:

```objc
// Pre-connect consent gate: an interviewee joining an interview room must confirm
// the secure-interview restrictions BEFORE the LiveKit connection is established.
// A declining candidate therefore never gains presence, never auto-subscribes to
// the interviewer's media, and never enters a recording. All other connects (host,
// normal calls, returning interview host) proceed immediately. Invoked on main.
__weak typeof(self) gateWeakSelf = self;
self.roomController.preConnectConsentGate =
    ^(NSString *roomType, BOOL isHost, void (^decide)(BOOL)) {
    __strong typeof(gateWeakSelf) gateSelf = gateWeakSelf;
    if (!gateSelf) { decide(YES); return; }
    BOOL intervieweeJoiningInterview = [roomType isEqualToString:@"interview"] && !isHost;
    if (!intervieweeJoiningInterview) { decide(YES); return; }
    [gateSelf showIntervieweeConfirmationWithCompletion:^(BOOL accepted) {
        decide(accepted);
    }];
};
```

Server side of the contract: `InterRoomController.swift:348`

```swift
@objc public var preConnectConsentGate: ((_ roomType: String, _ isHost: Bool,
                                          _ decide: @escaping (Bool) -> Void) -> Void)?
```

and line 608: if a gate is installed, `performLiveKitConnect` is deferred behind it; a `false`
decision routes to `handleConsentDeclined`, which calls `tokenService.leaveRoom(...)` to **release
the server-side slot reserved by token issuance**, resets `isConnecting`, sets `.disconnected`
(not `.disconnectedWithError`), and completes with `.consentDeclined` (1020).

**This is the client-side verification hook point**, by file and symbol:
`AppDelegate.m` → `self.roomController.preConnectConsentGate` → currently
`-showIntervieweeConfirmationWithCompletion:` (`AppDelegate.m:2365`, a bare `NSAlert` with
"Continue"/"Cancel" listing the secure-mode restrictions). The face-matching stage replaces or
chains behind that alert, with the same `decide(BOOL)` contract and the same slot-release
semantics on failure. Note this gate runs **after** the server has already minted a token — so the
client gate alone is not fail-closed; it must be paired with the server gate at §5.2.

Interview mode entry/exit, verified:
- Entry: `-createInterviewAsInterviewer` (512) / `-joinInterviewAsInterviewee` (516) →
  `-enterMode:role:` (682). `isIntervieweeMode = (mode == InterCallModeInterview && role ==
  InterInterviewRoleInterviewee)`; at 769–788 it allocates `SecureWindowController`, sets
  `exitSessionHandler` → `[weakSelf requestExitCurrentMode]`, then `createSecureWindow`.
- External-display policy: `InterShouldEnforceInterviewExternalDisplayPolicy()` (217) gates the
  multi-display block for the interviewee path.
- Exit: SwiftUI leave → `SecureWindowController.exitSessionHandler` →
  `-requestExitCurrentMode` (572) → `-exitCurrentMode` (525). Matches the assumed context.
- Post-join routing: 1340–1356 and 2239–2252 branch on `roomType == "interview"` and
  `rc.isHost` to pick interviewer vs interviewee mode; `error.code == 1020` is handled as benign
  at three sites (1327, 2222, 4495) with `"Declined interview session."`.
- Green-room pre-join: `-showGreenRoomWithRole:panel:roomCode:` (1851) with
  `InterGreenRoomRole` ∈ `{HostCreate, Join, ScheduledStart, HostInterview}`
  (`InterGreenRoomHostView.swift:34`); submit → `-greenRoomDidSubmitWithRole:` (1915) →
  `-connectAndEnterMode:role:` (1998). `InterGreenRoomRoleHostInterview` (1696) is reached from
  `-setupPanelDidRequestHostInterview:` (1686) and is itself gated by
  `[self requireFeature:InterFeatureHostInterview]`.
  **This is where the interviewer's "provide the candidate's photo" step belongs** for the ad-hoc
  path: it is the one screen the interviewer sees between pressing "Host Interview" and the room
  existing, and it already collects meeting name / password / device choices.

### 11.5 Window capture protection — `inter/App/InterWindowSecurity.h/.m`

```objc
BOOL InterCaptureProtectionDisabled(void);
NSWindowSharingType InterWindowSharingType(void);
```

Default `NSWindowSharingNone`. Relaxed to `NSWindowSharingReadOnly` **only** when `#if DEBUG`
**and** (`--disable-capture-protection` argv **or** `INTER_DISABLE_CAPTURE_PROTECTION=1`). Cannot
ship relaxed. Every protected window calls `[window setSharingType:InterWindowSharingType()]`
rather than hardcoding — a new verification window must do the same.

`SecureWindowController` (`inter/UI/Controllers/SecureWindowController.h`) API worth knowing:
`secureWindow`, `exitSessionHandler`, `roomController`, `startWithMicrophoneOff`,
`startWithCameraOff` (set **before** `-createSecureWindow`), `chatController`,
`-createSecureWindow`, `-destroySecureWindow`, `-setRecordingIndicatorActive:`,
`-hideSecureWindow`. Its header notes interview rooms have **no** pre-meeting, so only the
candidate's green-room choices shape initial device state — which means a verification stage that
needs the camera on must reconcile with `startWithCameraOff`.

### 11.6 SwiftUI structure and conventions

`inter/UI/SwiftUI/` → `Components/` (7 files: `InterButton`, `InterInputField`, `InterBanner`,
`InterDropdown`, `InterToggle`, `InterLobbyToast`, `BrandIcons`), `Foundation/`
(`InterHostingController`, `ComponentGallery`, `View+Cursor`), `Screens/` (57 files),
`SecureTools/` (CodeEditor + Whiteboard).

The established pattern is a **three-file triad per screen**:
1. `XView.swift` — pure SwiftUI, reads an `@ObservedObject` view model.
2. `XViewModel.swift` — `@Published` state + intent methods + handler closures. Unit-tested
   directly (`interTests/*ViewModelTests.swift`).
3. `InterXHostView.swift` / `InterXBridge.swift` — an `@objc` `NSObject`/`NSView` bridge exposing
   `setFoo:` mutators and `fooHandler` closures so `AppDelegate.m` can drive it.

The candidate-side chrome is exactly this: `SecureCandidateChromeViews.swift` +
`SecureCandidateChromeViewModel.swift` (`@Published cameraEnabled, cameraInteractive,
cameraTitleOverride, micEnabled, mediaStatusText, connectionStatusText, roomCode, recordingActive,
chatUnread, chatVisible, selectedTool, sharingActive, sharePending, shareStatusText,
audioInputs, selectedAudioInputID`) + `InterSecureChromeBridge.swift`
(`@objc(InterSecureChromeBridge)`, exposing `topBarView`, `bottomBarView`,
`cameraToggleHandler`, `microphoneToggleHandler`, `leaveHandler`, `setCameraInteractive:`,
`setMediaStatusText:`, `setRecordingActive:`, `invalidateHandlers`, …).

A candidate-side verification screen should be a fourth such triad, hosted in the secure window,
and should use the existing `setCameraInteractive:` / `setMediaStatusText:` levers rather than
inventing parallel ones.

---

## 12. Design system — the tokens and rules a new candidate flow must follow

Canon lives in `inter-design-handoff/`: `DESIGN-SPEC.md` (the rules),
`DesignTokens.md` (the value reference), `DesignTokens.swift` (the code),
`PORTING-PLAYBOOK.md`, `prinsiples.md`, `react-reference/` (the React source of truth, including
`mocks/SecureInterviewMock.tsx` and `mocks/SecureInterviewCandidateMock.tsx`), and
`reference-screens/` (30 PNGs, `ref_<screen>_<light|dark>.png`).

**Both `ref_secure_dark.png` and `ref_secure-candidate_dark.png` exist, and so do their `_light`
counterparts** — a small correction to the step prompt, which named only the dark pair.

The compiled copies that the app actually uses live at
`inter/UI/DesignSystem/DesignTokens.swift` and `inter/UI/DesignSystem/InterDesignTokens.swift`
(plus `InterAppearance+Window.swift`, `InterTileBadge.swift`, `InterWindowChrome.swift`).
Tested by `interTests/InterDesignTokensTests.swift`.

### 12.1 The rule that governs this feature: stage surfaces are fixed dark

> The call window reads dark like Zoom/Teams even when the app is in light mode. **Never** make
> these appearance-aware.

| Token | Swift | Value | Use |
|---|---|---|---|
| `stage` | `InterColor.stage` | `#101012` | deepest chrome — footers, side rails |
| `stage-surface` | `InterColor.stageSurface` | `#18181B` | main video canvas / panels |
| `stage-elevated` | `InterColor.stageElevated` | `#27272A` | menus / popovers on the stage |

On stage: text white / `#E5E5E5` / `#D4D4D4` / `#A3A3A3`; dividers white at 5–10 %. This is the
**only** place white-on-dark raw neutrals are correct. The candidate verification stage lives
inside the secure window, so it is a stage surface and must be dark in both appearances.

Appearance-aware theme tokens (for anything that is app chrome rather than stage), `InterColor.*`:
`background` `#E2E5F8`/`#0B0F19`, `foreground` `#201C34`/`#F1F5F9`, `card` `#F5F6FD`/`#11161F`,
`secondary` `#CED2F3`/`#1E293B`, `muted` `#D4D7F4`/`#1E293B`,
`mutedForeground` `#635F89`/`#94A3B8`, `inputBackground` `#D4D7F4`/`#1E293B`,
`border` `rgba(45,40,110,0.108)`/`rgba(148,163,184,0.14)`, `primary` `#7C3AED`/`#8B5CF6`,
`primaryForeground` `#FFFFFF`, `ring` = primary,
`destructive` `#D4183D`/`#82181A`, `destructiveForeground` `#FFFFFF`/`#FB2C36`.

### 12.2 Status hues — `InterStatus.*` (same in both appearances)

`success` `#10B981` (emerald-500, also "live") · `warning` `#F59E0B` (amber-500, also "Pro") ·
`danger` `#EF4444` (red-500, also leave/record) · `dm` `#9333EA` · `brand` `#7C3AED`.

A verification flow needs exactly these three states: pending → `warning`, matched → `success`,
rejected → `danger`. Badge recipe: tinted bg + saturated text; light `#ECFDF5` bg / `#047857` text,
dark `rgba(emerald,.2)` bg / `#34D399` text. **Accessibility rule: never signal state by colour
alone — pair with an icon or label** (the spec's own example is "REC dot + 'REC'").

### 12.3 Typography — General Sans

`InterFont.family = "General Sans"`. Standard scale `InterFont.Size`: `display` 24 semibold,
`title` 20 semibold, `heading` 18 semibold, `body` 16 regular, `secondary` 14, `caption` 12.
Dense scale (call HUD / rails — keep exact): `dense11` 11, `dense10` 10, `dense9` 9, `menu13` 13.
Helpers: `InterFont.swiftUI(_:_:)`, `InterFont.appKit(_:_:)`,
`InterFont.tracking(em:size:)` (points = em × size; headings `-0.018em`, body `-0.006em`),
`InterFont.lineSpacing(cssLineHeight:size:)` (body paragraphs 1.6, everything else 1.5),
`InterFont.registerBundledFonts()`.

### 12.4 Spacing, radius, controls, elevation

`InterSpacing`: `x0_5` 2 (dense only), `x1` 4, `x1_5` 6, `x2` 8 (**preferred rhythm**), `x2_5` 10,
`x3` 12, `x4` 16 (**default card padding**), `x5` 20, `x6` 24, `x8` 32.
**Forbidden: off-grid values (no 5, 7, 13 pt).**

`InterRadius` (base 10): `sm` 6, `md` 8, `lg` 10 (buttons, inputs, rows, chips), `xl` 14 (cards,
input groups), `2xl` 16 (modals, major panels, call window), `full` → `Capsule()`/`Circle()`.
**Do not invent new radii.**

`InterControl` heights: primary CTA 40, secondary 36, text input 36, compact 32, toolbar 28.
Minimum interactive target ≥ 32 pt.

Elevation: `sm` black 10 %·2·1 · `lg` 18 %·8·4 · `xl` 22 %·14·8 · `2xl` 28 %·24·12 (modals, call
window, stage popovers) · CTA coloured = **fill colour @ 20 %**·10·4 — **`/20` only, no other
opacity**.

### 12.5 Component recipes to reuse verbatim

```swift
// Primary CTA — h-10, violet, /20 shadow
Text("Join Now")
    .font(InterFont.swiftUI(InterFont.Size.secondary, .semibold))
    .foregroundStyle(.interPrimaryForeground)
    .frame(height: InterControl.primaryHeight).frame(maxWidth: .infinity)
    .background(.interPrimary, in: RoundedRectangle(cornerRadius: InterRadius.lg))
    .interShadow(.cta(.interPrimary))

// Card / panel — p-4, rounded-xl, hairline, sm shadow
VStack { /* … */ }
    .padding(InterSpacing.x4)
    .background(.interCard, in: RoundedRectangle(cornerRadius: InterRadius.xl))
    .overlay(RoundedRectangle(cornerRadius: InterRadius.xl).stroke(.interBorder))
    .interShadow(.sm)
```

Existing in-repo components to compose from rather than re-build: `InterButton`,
`InterInputField`, `InterBanner`, `InterDropdown`, `InterToggle`, `InterLobbyToast`.
`InterLobbyToast` is the closest prior art for a "you are waiting, here is your position" state,
which is structurally what a verification-pending state is.

### 12.6 Archetypes the new screens fall into (`DESIGN-SPEC.md` §7)

- Candidate verification stage → **§7.5 Full-stage / call surface**: fixed-dark stage window,
  main canvas + three-zone control bar (primary left / secondary centre / destructive isolated
  right). States must cover media on/off, waiting, all-left, compact vs normal tiles.
- Interviewer photo upload → **§7.6 Sheet / modal / dialog** (`rounded-2xl bg-card shadow-2xl`,
  title → body → action row with the primary on the right, ⏎ confirms, Esc cancels, backdrop
  blocks) **or** an extension of the green room, which is **§7.1 centred/focused-entry**.
- §7.7 is a checklist: a new screen is not done until it is reachable, classified, has
  empty/loading/error/first-run states, and works in **both** appearances (stage stays dark).

Icons: lucide SVGs as template images, or the nearest SF Symbol — but never mix the two for the
*same* icon in the *same* view. The spec's map includes `shield`→`lock.shield`, which is the
obvious glyph for a verification state.

---

## 13. House style for the design document itself

Both reference docs sit in `docs/superpowers/specs/` with filenames
`YYYY-MM-DD-<kebab-slug>-design.md`. Ten files exist; the two to match are
`2026-06-10-consent-first-moderation-design.md` (19 KB) and
`2026-06-19-interviewer-collaborative-tools-design.md` (12 KB).

### 13.1 Header block

Two variants are in use. The consent doc uses a labelled list:

```
# Consent-First Moderation State Model — Design Spec

**Date:** 2026-06-10
**Project:** inter (macOS, Obj-C + Swift, LiveKit)
**Feature:** Host moderation that mirrors real participant state and never force-activates a mic/camera
**Status:** Draft — awaiting user review before implementation planning
**Builds on:** `2026-05-31-mic-unlock-request-design.md` (one-time slot / approve flow), and the
P1/P3/P4 correctness fixes shipped 2026-06-10.

---
```

The newer collaborative-tools doc uses a terser form:

```
# Design: Interviewer-Side Collaborative Tools, Interview Recording Layout, and Tool UX Improvements

Date: 2026-06-19
Status: **DESIGN — awaiting review**
Related: completes integration intent of `.kiro/specs/collaborative-code-editor` …
```

Either is in-house. `Status:` is always present and always says the review state.

### 13.2 Section skeleton

Numbered `##` sections, `###` subsections, no deeper. The consent doc runs:
1 Summary · 2 Background — why · 3 Core component (the pure function) · 4 Surfaces ·
5 Semantics changes · 6 What stays untouched · 7 Phasing & testing · 8 Open questions / risks ·
9 Out of scope (future).

The collaborative-tools doc runs: 1 Problem · 2 Goals / Non-goals · 3 Shared-session model ·
4 Per-side lifecycle · 5 Architecture / components · 6 Local recording layout · 7 Unified source ·
8 UX improvements · 9 Entitlement / security / open decisions · 10 Testing.

Common spine: **problem/why → the one core abstraction → surfaces → semantics deltas → what is
untouched → phasing & testing → open decisions → out of scope.** Both end with an explicit
testing section naming the actual suites and commands, and both have a "what stays untouched"
guarantee.

### 13.3 Decision tables

Heavy use, and they are *delta* tables, not feature lists. The dominant shapes:

```
| Path | Before | After (normal mode) | After (interview mode) |
| Input | Source today |
| Output | Meaning |
| Cause (caption) | Primary action | Secondary action |
```

Fenced pseudo-code blocks are used for derivation rules, with `->` and inline `//` comments:

```
(caption, micPrimaryAction, micSecondaryAction) =
  hostMicBlocked   -> ("Muted by you",      RemoveMuteAndAsk, None)     // lift my block + nudge
  globalMute       -> ("Muted (mute-all)",  AllowToSpeak,     BlockMic) // grant slot
```

### 13.4 Mermaid usage

**There is none.** Neither doc contains a single Mermaid block, and a grep for ` ```mermaid `
across `docs/superpowers/specs/` returns nothing. The house convention for structure is
**markdown tables + fenced pseudo-code + prose**, not diagrams. A new doc may introduce Mermaid,
but it would be a departure, and it should be a deliberate one.

### 13.5 Tone and markers

- First person plural is absent; the voice is declarative and impersonal.
- **Decision markers are explicit and bracketed**: `**[DECISION — RESOLVED]**`,
  `(Finding A)`, `(Finding D, resolved)`, `(user decision)`, `**Open decisions to confirm during
  planning:**`. Findings are numbered/lettered and referenced back by that label.
- Requirement strength is signalled with SHALL-style capitals: "MUST show", "MUST NOT",
  "never silent", "fails safe", "fail closed", "by construction".
- Cross-references are inline section refs (`§3`, `§4.3`, `(§9)`) and backticked real paths
  (`AppDelegate.m`, `InterModerationTileState`, `inter-design-handoff/prinsiples.md`).
- Rejected alternatives are recorded, not deleted: "Option 3 … was considered and declined for
  now"; "WKWebView-hosted tools (rejected: …)". External grounding is cited by name
  ("Google Meet's privacy model", "Jakob's & Hick's Laws", "CodeMirror `closeBrackets` semantics",
  "OWASP File Upload", "Excalidraw commits on blur").
- Both docs name the **verification lever** that substitutes for what cannot be automated — the
  consent doc's "Unit-test matrix (PR #1)" enumerates the required assertion rows explicitly, and
  both flag "manual two-client test" as a residual risk the phasing contains.
- Phasing is stated as concrete PRs with a gate between them ("PR #1 = microphone, PR #2 =
  camera … After PR #1 is live-verified").

### 13.6 Consent patterns the new design must stay consistent with

These are substantive constraints, not style:

1. **Consent-first principle**, with interview mode as the *named exception*: the interviewer may
   force-activate the candidate's mic and camera "because the interviewee consents to
   proctoring-style control by joining" — but **every force-activation MUST show the interviewee
   a persistent indicator, never silent**. Face verification is proctoring; it inherits both the
   permission and the obligation.
2. **Persistent affordance until resolved**, not a transient toast. The doc explicitly rejects
   toasts because "the toast conflated 'declined' with 'never saw it'". A verification prompt must
   persist until acted on.
3. **The pre-connect gate is the consent boundary.** The candidate confirms secure-interview
   restrictions *before* any LiveKit connection, so a decline means "no presence, no autoSubscribe,
   no recording exposure" (§11.4). A verification stage placed after connect would break that
   property.
4. **Option 3 was declined**: "explicit, revocable, join-time consent" was considered and not
   adopted. If the face-verification design wants revocable biometric consent, that is a reversal
   of a recorded decision and must be argued, not assumed.
5. **No separate accept/decline dialog** for host requests; no "declined" signal is sent upstream;
   dismiss is local-only. Host-side feedback is a transient `"Asked ✓"` plus a cooldown.
6. **Server authority for roles/locks; LiveKit-native events as the real-state source (no
   Socket.IO)** — listed under "What stays untouched". A verification decision must not be
   signalled over Socket.IO.
7. **One pure, exhaustively unit-tested derivation function** as the anti-drift device. The
   consent doc's whole architecture rests on `deriveRemoteTileState` being pure and enumerable.
   The equivalent here would be a pure match/decision predicate (threshold → verdict) separated
   from all I/O — which is also exactly the `joinGuards.js` / `recordingQuota.js` server pattern
   (§4).

---

## 14. Testing — the real commands and patterns

### 14.1 Server

```
cd token-server && npm test      # node --test --test-concurrency=1 test/*.test.js
cd token-server && node migrate.js
```

13 test files: `fileValidation`, `interviewTierGate`, `joinGuards`, `meetingHistory`, `profile`,
`recordingQuota`, `roomReconcile`, `teams`, `teamsRealtime`, `tiers`, `toolsEntitlement`
(+ `helpers.js`, and two non-`.test.js` spike files).

Two established styles:
- **Pure unit** (`fileValidation.test.js`, `tiers.test.js`): `node:test` `describe`/`test` +
  `node:assert`, no DB/Redis.
- **Integration against the dev DB + Redis** (`interviewTierGate.test.js`): `require('dotenv')`,
  import the real `{ app }` from `./index` (no port bound thanks to the `require.main` guard),
  `app.listen(0,'127.0.0.1')` on an ephemeral port, drive it with `h.api(baseURL, {method, path,
  token: h.tokenFor(u), body})`, create users with `h.createUser({tier})`, track created ids and
  clean up in `after()` with `h.cleanupUsers(track)` + `h.db.pool.end()` + `redis.disconnect()`.

`interviewTierGate.test.js` is the direct template for testing a new interview-mode gate — it
already proves the "gate fires before any LiveKit side effect, so the 403 case is fully
deterministic and needs no LiveKit" property that a verification gate test will want.

### 14.2 Client

```
xcodebuild build -scheme inter -destination 'platform=macOS'
xcodebuild test  -scheme inter -destination 'platform=macOS' | xcpretty
```

README states integration tests `XCSkip` gracefully when the local servers are unreachable, and
records "140 tests, 0 failures" as of the last recorded build. Relevant existing suites:
`InterRoomControllerTests`, `InterLiveKitCameraSourceTests`, `InterCameraWiringTests`,
`CaptureFidelitySpikeTests`, `AVPipeline/InterViewSnapshotScalingTests`,
`AVPipeline/SecureStagePreviewThrottleTests`, `InterDesignTokensTests`, and the
`*ViewModelTests.swift` family that is the pattern for testing a new verification view model.

---

## 15. Corrections to the assumed context

Things the code contradicts:

1. **`joinGuards.js` is not the join gate.** It contains only `createJoinCapGuard` — the
   participant-cap cross-check against LiveKit occupancy. The real admission gate chain is written
   inline in `index.js`'s `/room/join` handler (lines 2558–2836). There is no extension point in
   `joinGuards.js`. (§4, §5.2)
2. **`TIER_INSUFFICIENT` does not exist.** The real code string is `INSUFFICIENT_TIER`. (§1.4)
3. **`RATE_LIMITED` does not exist.** 429s return `{ error: '<prose>' }` with no `code`, and only
   3 of the 6 limiters set `Retry-After`. (§1.3)
4. **`{ error, code, requestId }` is not a uniform contract.** `requestId` is generated *only* in
   the global error handler; hand-written route responses omit it. (§1.2)
5. **`requireTier` is in `auth.js`, not `tiers.js`**, and the interview paths do not use it —
   they inline `tiers.isFeatureAllowed(req.user.tier, FEATURES.HOST_INTERVIEW)`. (§2.3, §5.1)
6. **Migrations are at exactly 022, not "at least 022".** Next file: `023_*.sql`. (§10.1)
7. **`/room/create` does not reject "a second window grant".** The one-shared-window behaviour
   claimed in the assumed context is a *client-side* property of the secure window plus the
   `sharingPermissions`/`shareConflictPolicy` room settings (`'hostOnly'` / `'oneattime'`
   defaults) and the screen-share queue endpoints — not a server rule in `/room/create`. I found
   no server code that counts or rejects window grants.
8. **The candidate exit flow is `SecureWindowController.exitSessionHandler`**, a block property —
   not a method named `exitSession`. `AppDelegate.m:786` assigns
   `self.secureController.exitSessionHandler = ^{ [weakSelf requestExitCurrentMode]; }`. The rest
   of the chain (`requestExitCurrentMode` → `exitCurrentMode`) is as described. (§11.4)
9. **Encryption env vars are missing from `.env.example`.** `ENCRYPTION_ACTIVE_VERSION` and
   `ENCRYPTION_SECRET_V1` exist in `.env` but not in `.env.example`, so a fresh clone starts with
   encryption unavailable. (§6.1)
10. **Light-mode reference screens for the secure views exist too** (`ref_secure_light.png`,
    `ref_secure-candidate_light.png`), not only the dark pair named in the prompt. (§12)
11. **The LiveKit SFU version could not be verified from the repo.** The client pins SDK 2.15.0
    (confirmed in `Package.resolved`) and the server uses `livekit-server-sdk ^2.15.0`, but the
    locally-running SFU binary version ("LiveKit v1.9.11") is not recorded anywhere in the tree —
    no docker-compose, no `livekit.yaml`. `.env.example` mentions `-e LIVEKIT_URL=ws://localhost:7880`
    in a commented docker snippet only. Stated as unverified rather than asserted.
12. **Pinning is not configured.** `pinnedSPKIHashes` is an empty set with a TODO, so the client
    currently does default system trust validation. Any claim that the app "has TLS pinning" is
    true only of the *mechanism*, not the *policy*. (§11.2)

Things I could **not** verify and am explicitly not asserting:

- Whether chat/polls/Q&A ride LiveKit DataChannel topics exclusively. `InterChatController`,
  `InterPollController`, `InterQAController` exist and the server's Socket.IO default namespace
  handles `client:join-room`, `participant:self-mute`, `participant:self-unmute`,
  `participant:raise-hand`, `participant:lower-hand` (`index.js:5570`–5750) — consistent with the
  claim, but I did not read the controllers' transport code end to end.
- The exact `audit_events` row count / retention in the live DB (no DB query was run — this was a
  read-only code recon).
- Whether `recordingFrameObserver` can be safely co-opted while a local recording is active. The
  property is single-slot and `InterRecordingCoordinator` owns it; I read the declaration and
  setter but did not trace every coordinator state in which it is installed.
- The Redis/Postgres instance state (nothing was connected to).

---

## 16. Quick file index for the designer

| Concern | Path |
|---|---|
| Route mounting, middleware order, rate limiters, `/room/create`, `/room/join`, file upload | `token-server/index.js` |
| `requireAuth`, `requireTier`, `authenticateToken`, `auditLog` | `token-server/auth.js` |
| Tier SSOT, `FEATURES`, `FEATURE_MIN_TIER` | `token-server/tiers.js` |
| Participant-cap guard only | `token-server/joinGuards.js` |
| AES-256-GCM key-versioned encryption | `token-server/crypto.js` |
| Shared upload allowlist + filename sanitiser | `token-server/fileValidation.js` |
| Scheduling routes + `registerScheduledRoom` | `token-server/scheduling.js` |
| Idempotent-POST middleware | `token-server/idempotency.js` |
| Quota predicate + sweeper pattern | `token-server/recordingQuota.js` |
| Redis client | `token-server/redis.js` |
| Migration runner | `token-server/migrate.js` |
| `audit_events` DDL | `token-server/migrations/011_audit_events.sql` |
| `scheduled_meetings` / `meeting_invitees` DDL | `token-server/migrations/015_scheduling.sql` |
| Encrypted-column DDL precedent | `token-server/migrations/016_calendar_teams.sql` |
| `settings` JSONB snapshot | `token-server/migrations/020_scheduled_meeting_settings.sql` |
| Next migration goes here | `token-server/migrations/023_*.sql` |
| HTTP client, error mapping, TLS pinning | `inter/Networking/InterTokenService.swift` |
| Error-code enum + `isExpectedJoinRejection` | `inter/Networking/InterNetworkTypes.swift` |
| Pre-connect consent gate (client contract) | `inter/Networking/InterRoomController.swift:348,608` |
| Endpoint config resolution | `inter/Networking/InterAppConfig.swift` |
| Client tier mirror | `inter/Networking/InterFeatureGate.h/.m` |
| Shared `AVCaptureSession` owner + frame-observer seam | `inter/Media/InterLocalMediaController.h/.m` |
| LiveKit camera output + isolation invariant | `inter/Networking/InterLiveKitCameraSource.swift` |
| `CGImage`↔`CVPixelBuffer` prior art | `inter/Media/Sharing/Sources/InterViewSnapshotVideoSource.m` |
| Consent gate wiring, interview entry/exit, green room | `inter/App/AppDelegate.m:334,512,682,1851,2365` |
| Capture-protection policy | `inter/App/InterWindowSecurity.h/.m` |
| Secure window lifecycle | `inter/UI/Controllers/SecureWindowController.h/.m` |
| Candidate chrome triad | `inter/UI/SwiftUI/Screens/SecureCandidateChromeView{s,Model}.swift`, `InterSecureChromeBridge.swift` |
| Design tokens (compiled) | `inter/UI/DesignSystem/DesignTokens.swift`, `InterDesignTokens.swift` |
| Design rules / values / screens | `inter-design-handoff/DESIGN-SPEC.md`, `DesignTokens.md`, `reference-screens/` |
| Consent prior art (read fully) | `docs/superpowers/specs/2026-06-10-consent-first-moderation-design.md` |
| Format/depth reference | `docs/superpowers/specs/2026-06-19-interviewer-collaborative-tools-design.md` |
| Server gate test template | `token-server/test/interviewTierGate.test.js` |
