# System Principles — Auth, Backend Business Logic & Database
> **Purpose**: Authoritative reference for coding agents implementing or modifying any part of
> this system. Every principle here is a hard rule unless explicitly marked as advisory.
> Read this file in full before touching auth, billing, or database code.
>
> **Scope**: Applies to all systems that involve user authentication, tier-based access,
> and purchase/subscription lifecycle management.

---

## Table of Contents

1. [Authentication Principles](#1-authentication-principles)
2. [Backend Business Logic Principles](#2-backend-business-logic-principles)
3. [Billing & Tier Lifecycle Principles](#3-billing--tier-lifecycle-principles)
4. [API Design Principles](#4-api-design-principles)
5. [Database Principles](#5-database-principles)
6. [Security Principles](#6-security-principles)
7. [Implementation Checklist](#7-implementation-checklist)

---

## 1. Authentication Principles

### 1.1 Token Architecture — Non-Negotiable

The system uses a **two-token model**. Never collapse this into a single long-lived token.

| Token | Type | TTL | Storage | Travels on |
|---|---|---|---|---|
| Access Token | JWT (HS256) | 15 minutes | Memory only | Every API request header |
| Refresh Token | Opaque (32-byte random) | 30 days | macOS Keychain | `/auth/refresh` only |

```
RULE: Access token TTL must never exceed 15 minutes.
RULE: Refresh token must never be stored in UserDefaults, disk files, or logs.
RULE: Raw refresh token must never enter the database — store SHA-256 hash only.
```

### 1.2 JWT Signing — Non-Negotiable

Every `jwt.sign()` call must include:
```javascript
jwt.sign(payload, JWT_SECRET, {
  algorithm: 'HS256',           // explicit — never rely on default
  expiresIn: ACCESS_TOKEN_TTL,  // from env var — never hardcoded
  issuer: 'inter-token-server',
  audience: 'inter-macos-client',
});
```

Every `jwt.verify()` call must include:
```javascript
jwt.verify(token, JWT_SECRET, {
  algorithms: ['HS256'],        // whitelist — rejects alg:none, RS256, ES256
  issuer: 'inter-token-server',
  audience: 'inter-macos-client',
});
```

```
RULE: jwt.verify() without algorithms pin is a CRITICAL vulnerability (alg:none forgery).
RULE: JWT_SECRET must be >= 32 bytes. Server must crash on startup if not set.
RULE: Never use a fallback/default value for JWT_SECRET.
```

### 1.3 Token Expiry Error Codes

`authenticateToken` middleware must distinguish between expired and invalid tokens:

```javascript
// TOKEN_EXPIRED → client should silently refresh + replay request
// TOKEN_INVALID → client must force re-login, clear Keychain
if (err.name === 'TokenExpiredError') {
  return res.status(401).json({ error: 'Access token expired', code: 'TOKEN_EXPIRED' });
}
return res.status(401).json({ error: 'Invalid access token', code: 'TOKEN_INVALID' });
```

### 1.4 Refresh Token Rotation & Theft Detection

Every `/auth/refresh` call must:
1. Look up the token hash in DB (include revoked rows)
2. If token is already revoked → **kill entire family**, return `SESSION_COMPROMISED`
3. If token is valid → revoke old token, issue new token in same family (atomic transaction)
4. Re-read `users.tier` from DB — this is the ONLY point where fresh tier enters the JWT

```javascript
// Family-based theft detection — do not skip or simplify this logic
if (stored.revoked_at !== null) {
  await dbClient.query(
    `UPDATE refresh_tokens SET revoked_at = NOW()
     WHERE family_id = $1 AND revoked_at IS NULL`,
    [stored.family_id]
  );
  // alert, log, return 401 SESSION_COMPROMISED
}
```

```
RULE: Rotation and revocation of the old token must be atomic (single DB transaction).
RULE: A revoked token being presented means the family is compromised — revoke all siblings.
RULE: Fresh tier MUST be re-read from DB on every refresh — never carry tier from old JWT.
```

### 1.5 Password Handling

```javascript
// bcrypt cost factor must be >= 12
const hash = await bcrypt.hash(password, 12);

// Never store, log, or transmit raw passwords
// Scrub password from req.body before any logging
```

```
RULE: Enforce minimum password length of 8 characters at the API level (input validation).
RULE: bcrypt cost factor < 12 is not acceptable in production.
```

### 1.6 Session Management

- `POST /auth/logout` — revokes the specific refresh token provided
- A "Logout All Devices" endpoint must be implemented that revokes all active refresh tokens for the user (all family_ids)
- Client discards access token from memory on logout (no server call needed for access token)

---

## 2. Backend Business Logic Principles

### 2.1 Single Source of Truth for Tier

```
RULE: users.tier is the ONLY authority on what tier a user is on.
RULE: Never derive tier from JWT claims alone, payment status alone, or subscription status alone.
RULE: The flow is always: billing event → DB update → next /auth/refresh picks it up.
```

The 15-minute access token TTL is the maximum stale-tier window. This is by design.

### 2.2 Never Trust the Client for Anything Financial

```
RULE: The client never tells the server what tier to assign.
RULE: The client never tells the server what price was paid.
RULE: The client never tells the server that a payment succeeded.
```

All financial state comes from the payment provider's signed webhook directly to the backend. A frontend call to `/upgrade?tier=pro` without a verified payment backend confirmation is a critical business logic vulnerability.

### 2.3 Fail-Safe Defaults

When system state is ambiguous, always default to the **lower privilege**:

```javascript
// users.tier is NULL for any reason → treat as 'free'
const tier = user.tier ?? 'free';

// Billing webhook processing fails → keep current tier, do not upgrade
// Webhook signature fails → reject and alert, do not process

// requireTier middleware — fail closed, not open
function requireTier(minTier) {
  return (req, res, next) => {
    if (!TIER_RANK[req.user?.tier] || TIER_RANK[req.user.tier] < TIER_RANK[minTier]) {
      return res.status(403).json({ error: 'Insufficient tier', code: 'TIER_INSUFFICIENT' });
    }
    next();
  };
}
```

### 2.4 Separation of Concerns — Hard Boundary Between Auth and Billing

```
RULE: auth.js must contain zero billing logic.
RULE: billing.js must not generate JWTs or touch token state.
RULE: The only connection between auth and billing is users.tier in the database.
```

File responsibilities:
- `auth.js` → login, logout, token issuance, token verification, password ops
- `billing.js` → webhook handling, tier updates, subscription state management
- `middleware.js` → requireAuth, requireTier, requireVerified (reads state, decides nothing)

### 2.5 Subscription State Machine

A subscription has exactly these states and only these valid transitions:

```
States: none | trialing | active | past_due | canceled | disputed

Valid transitions:
  none     → trialing, active
  trialing → active, canceled
  active   → past_due, canceled
  past_due → active, canceled
  canceled → active              (re-subscription)
  disputed → canceled            (chargeback resolved)
```

```javascript
const VALID_TRANSITIONS = {
  none:     ['trialing', 'active'],
  trialing: ['active', 'canceled'],
  active:   ['past_due', 'canceled'],
  past_due: ['active', 'canceled'],
  canceled: ['active'],
  disputed: ['canceled'],
};

function validateTransition(from, to) {
  if (!VALID_TRANSITIONS[from]?.includes(to)) {
    throw new Error(`Invalid subscription transition: ${from} → ${to}`);
  }
}
```

```
RULE: Every subscription state change must pass validateTransition() before executing.
RULE: Log every transition with: from_state, to_state, reason, triggered_by, timestamp.
```

### 2.6 Tier-Based Rate Limiting

Rate limits are a business concern, not just a security concern. They enforce tier fairness and protect infrastructure costs. Limits must be:
- Defined in a central config object (not hardcoded in route handlers)
- Enforced server-side per tier
- Communicated to the client via `Retry-After` header on 429

```javascript
// Central config — single place to update
const TIER_LIMITS = {
  free:    { requestsPerMin: 30,  rooms: 1,         storage: '100MB' },
  pro:     { requestsPerMin: 300, rooms: 10,        storage: '10GB'  },
  hiring:  { requestsPerMin: null, rooms: null,     storage: '1TB'   }, // null = unlimited
};
```

### 2.7 Audit Logging — Mandatory Events

Every action below must write an immutable audit log entry. No exceptions.

| Event | Must Log |
|---|---|
| Tier change | user_id, from_tier, to_tier, reason, event_id, timestamp |
| Login (success + fail) | user_id or email, ip, device/client_id, result, timestamp |
| Password reset requested | user_id, ip, timestamp |
| Webhook received | event_id, type, processed_at, result (success/fail/skipped) |
| Refund issued | user_id, amount, reason, processed_by, timestamp |
| Admin action on user | admin_id, target_user_id, action, timestamp |
| Session compromised / theft detected | family_id, user_id, ip, timestamp |

```
RULE: Audit log tables are append-only. REVOKE UPDATE, DELETE on them from the app DB user.
RULE: Never delete audit records. Archive to cold storage after retention period if needed.
```

### 2.8 Security Alert Escalation

`console.error` is not an alert. When `SESSION_COMPROMISED` fires, or when a webhook signature fails, the system must actively notify:

```javascript
// Minimum: send to a monitored Slack webhook or alert email
// Do not leave security events only in log files
async function fireSecurityAlert(event) {
  await notifySlack(`[SECURITY] ${event.type}: ${JSON.stringify(event)}`);
  await db.query(`INSERT INTO security_events ...`, [...]);
}
```

---

## 3. Billing & Tier Lifecycle Principles

### 3.1 Billing is Event-Driven, Not Cron-Driven

```
RULE: Never use a cron job to downgrade trial users or check subscription expiry.
RULE: Tier changes happen exclusively through payment provider webhook events.
```

Payment provider fires:
- `customer.subscription.trial_will_end` → warn user (3 days before)
- `customer.subscription.deleted` → downgrade tier immediately
- `invoice.payment_failed` → set `past_due`, warn user
- `charge.dispute.created` → set `disputed`, flag account, downgrade immediately

### 3.2 Webhook Idempotency — Non-Negotiable

Payment webhooks are delivered **at-least-once**. Processing the same event twice must be safe.

```javascript
// Before processing ANY webhook event:
const exists = await db.query(
  'SELECT id FROM processed_webhook_events WHERE event_id = $1',
  [event.id]
);
if (exists.rows.length > 0) return res.status(200).json({ status: 'already_processed' });

// After processing, inside the same transaction:
await dbClient.query(
  'INSERT INTO processed_webhook_events (event_id, processed_at) VALUES ($1, NOW())',
  [event.id]
);
```

### 3.3 Webhook Signature Validation — Mandatory

```
RULE: Every incoming webhook must have its signature validated before any processing.
RULE: Never process a webhook event that fails signature validation.
RULE: A failed signature must be logged as a security event and return 400.
```

```javascript
// Stripe
const event = stripe.webhooks.constructEvent(rawBody, sig, STRIPE_WEBHOOK_SECRET);

// Razorpay
const expectedSig = crypto
  .createHmac('sha256', RAZORPAY_WEBHOOK_SECRET)
  .update(rawBody)
  .digest('hex');
if (expectedSig !== req.headers['x-razorpay-signature']) {
  return res.status(400).json({ error: 'Invalid webhook signature' });
}
```

### 3.4 Chargeback Handling

A chargeback is not a cancellation. It implies potential fraud.

```javascript
case 'charge.dispute.created':
  await db.query(
    `UPDATE users SET tier = 'free', subscription_status = 'disputed' WHERE customer_id = $1`,
    [customerId]
  );
  await flagAccountForReview(userId, 'chargeback');
  await fireSecurityAlert({ type: 'CHARGEBACK', userId });
  break;
```

### 3.5 Never Store Payment Method Data

```
RULE: Never store card numbers, CVVs, or bank account numbers.
RULE: Store only the payment provider's token/payment_method_id as a reference.
RULE: Your database must never see raw payment method data — that's the provider's vault.
```

```sql
-- Correct: store a reference, not data
ALTER TABLE users ADD COLUMN stripe_payment_method_id VARCHAR(255);
ALTER TABLE users ADD COLUMN stripe_customer_id       VARCHAR(255);
```

### 3.6 Graceful Degradation on Payment Provider Outage

```
RULE: If the payment provider is unreachable, existing paid users must not lose access.
RULE: Tier is authoritative in your DB — trust it until you receive a webhook saying otherwise.
RULE: Never make a real-time call to the payment provider to verify tier on API requests.
```

---

## 4. API Design Principles

### 4.1 Consistent Error Contract

Every error response from every endpoint must follow this exact shape:

```javascript
{
  error: "Human readable message",   // for display
  code:  "MACHINE_READABLE_CODE",    // client switches on this — never changes
  requestId: "uuid"                  // for support lookup, correlates with server logs
}
```

**Canonical error codes the client must handle:**

| Code | HTTP Status | Client Action |
|---|---|---|
| `TOKEN_EXPIRED` | 401 | Silent refresh + replay request |
| `TOKEN_INVALID` | 401 | Force re-login, clear Keychain |
| `SESSION_COMPROMISED` | 401 | Force re-login, show security warning |
| `TIER_INSUFFICIENT` | 403 | Show upgrade prompt |
| `PAYMENT_REQUIRED` | 402 | Redirect to billing |
| `EMAIL_NOT_VERIFIED` | 403 | Show verification prompt |
| `RATE_LIMITED` | 429 | Respect `Retry-After` header |

### 4.2 Input Validation — Every Endpoint

```
RULE: Every endpoint that accepts a request body must validate it before processing.
RULE: Validation must check: presence of required fields, types, lengths, and formats.
RULE: Validation errors return 400 with field-level detail (not 500).
```

```javascript
// Use zod or express-validator — never validate manually ad-hoc
const registerSchema = z.object({
  email:       z.string().email().max(255),
  password:    z.string().min(8).max(128),
  displayName: z.string().min(1).max(100),
});

// Apply as middleware before route handler
app.post('/auth/register', validate(registerSchema), rateLimitAuth, async (req, res) => { ... });
```

### 4.3 Principle of Least Privilege for Middleware

```
RULE: Each endpoint applies only the middleware it actually needs.
RULE: Tier checks always go through requireTier() middleware, never ad-hoc in route handlers.
RULE: Never apply a stricter check than necessary (don't requireTier('pro') on a free endpoint).
```

```javascript
app.get('/profile',       requireAuth,                    handler);
app.post('/room/create',  requireAuth, requireTier('pro'), handler);
app.get('/admin/users',   requireAuth, requireRole('admin'), handler);
```

### 4.4 Security Response Headers — Every Response

Applied globally via middleware, not per-route:

```javascript
app.use((_req, res, next) => {
  res.setHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  next();
});
```

### 4.5 Log Scrubbing — Non-Negotiable

```
RULE: password, refreshToken, and any raw secret must never appear in logs.
RULE: Scrub these fields before any req.body logging or error reporting.
```

```javascript
const SCRUBBED_FIELDS = ['password', 'refreshToken', 'token', 'secret', 'cvv'];

function scrubSensitive(obj) {
  return Object.fromEntries(
    Object.entries(obj).map(([k, v]) =>
      SCRUBBED_FIELDS.some(f => k.toLowerCase().includes(f)) ? [k, '[REDACTED]'] : [k, v]
    )
  );
}
```

### 4.6 `expiresIn` Must Be Dynamic, Never Hardcoded

```javascript
// WRONG: hardcoding 900 when ACCESS_TOKEN_TTL is an env var
res.json({ accessToken, refreshToken, expiresIn: 900 });

// CORRECT: derive from the same env var used to sign the token
const parseTTLtoSeconds = (ttl) => {
  const match = String(ttl).match(/^(\d+)(m|h|d|s)?$/);
  const unit = match?.[2] ?? 's';
  const n = parseInt(match?.[1]);
  return { m: n * 60, h: n * 3600, d: n * 86400, s: n }[unit];
};
const expiresIn = parseTTLtoSeconds(ACCESS_TOKEN_TTL); // e.g. '15m' → 900
res.json({ accessToken, refreshToken, expiresIn });
```

---

## 5. Database Principles

### 5.1 Financial Records Are Immutable

```
RULE: Never UPDATE or DELETE a payment, invoice, or transaction row.
RULE: Corrections are made by inserting a compensating/reversal record.
RULE: The payments table is a ledger — it must be able to reconstruct account state at any timestamp.
```

```sql
-- WRONG
UPDATE payments SET amount = 0 WHERE id = $1;

-- CORRECT — insert a reversal
INSERT INTO payments (user_id, amount, type, reference_id, created_at)
  VALUES ($1, -2999, 'refund', $original_payment_id, NOW());
```

### 5.2 Soft Deletes for Users

```
RULE: Never DELETE FROM users.
RULE: Account deletion sets deleted_at = NOW() and anonymizes PII.
RULE: All queries on users must include WHERE deleted_at IS NULL.
```

```sql
ALTER TABLE users ADD COLUMN deleted_at TIMESTAMPTZ DEFAULT NULL;

-- "Deleting" a user:
UPDATE users
  SET deleted_at  = NOW(),
      email       = 'deleted_' || id || '@deleted.invalid',  -- anonymize PII (GDPR)
      display_name = 'Deleted User'
  WHERE id = $1;

-- All standard queries:
SELECT * FROM users WHERE id = $1 AND deleted_at IS NULL;
```

### 5.3 Referential Integrity via Foreign Keys — Always

```
RULE: Every relationship is enforced at the DB level, not just the application level.
RULE: ON DELETE behavior (CASCADE / RESTRICT / SET NULL) must be a deliberate decision, documented inline.
```

```sql
-- Purchases: RESTRICT — cannot delete a user who has purchase history (financial record)
user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,

-- Refresh tokens: CASCADE — deleting a user removes their sessions (no orphaned tokens)
user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

-- Audit logs: SET NULL — preserve the log even if user is hard-deleted
user_id UUID REFERENCES users(id) ON DELETE SET NULL,
```

### 5.4 Required Columns on Every Table

```sql
-- Every table must have at minimum:
id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()   -- updated via trigger below

-- User-owned tables also need:
user_id    UUID NOT NULL REFERENCES users(id) ON DELETE <deliberate choice>,

-- Soft-deletable tables also need:
deleted_at TIMESTAMPTZ DEFAULT NULL
```

```sql
-- Auto-update trigger — apply to every table with updated_at:
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER set_updated_at
  BEFORE UPDATE ON <table_name>
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();
```

### 5.5 Append-Only Audit Tables

Critical entities need a dedicated, append-only history table separate from the main table:

```sql
CREATE TABLE user_tier_history (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID REFERENCES users(id) ON DELETE SET NULL,
  from_tier   VARCHAR(20),
  to_tier     VARCHAR(20) NOT NULL,
  reason      VARCHAR(100) NOT NULL, -- 'stripe_webhook' | 'admin_override' | 'trial_end'
  event_id    VARCHAR(255),          -- payment provider event ID for traceability
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
  -- NO updated_at — append-only, never updated
);

-- Lock it at the DB level:
REVOKE UPDATE, DELETE ON user_tier_history FROM app_db_user;
```

### 5.6 Enum Columns Use CHECK Constraints

```
RULE: Enum-like columns must have a CHECK constraint enforced at the DB level.
RULE: Adding a new valid value requires a migration — this is intentional (forces deliberate decisions).
```

```sql
tier VARCHAR(20) NOT NULL DEFAULT 'free'
  CHECK (tier IN ('free', 'pro', 'hiring')),

subscription_status VARCHAR(20) NOT NULL DEFAULT 'none'
  CHECK (subscription_status IN ('none', 'trialing', 'active', 'past_due', 'canceled', 'disputed')),
```

### 5.7 Index Strategy Must Match Query Patterns

```
RULE: Every index has a write cost. Index what you query, not what seems right.
RULE: Use partial indexes where only a subset of rows is ever queried (e.g. active tokens).
RULE: Use composite indexes where multiple columns are always queried together.
```

```sql
-- Login: users looked up by email on every login
CREATE UNIQUE INDEX idx_users_email ON users (lower(email));
-- lower() prevents case-sensitivity bugs on login

-- Refresh: token looked up by hash on every /auth/refresh
CREATE INDEX idx_rt_hash   ON refresh_tokens (token_hash)  WHERE revoked_at IS NULL;
-- Partial: revoked tokens are never looked up by hash

-- Logout: revoke all tokens for a user
CREATE INDEX idx_rt_user   ON refresh_tokens (user_id)     WHERE revoked_at IS NULL;

-- Theft detection: family-wide revocation
CREATE INDEX idx_rt_family ON refresh_tokens (family_id);

-- Purchase history: common query is "get user's recent purchases"
CREATE INDEX idx_purchases_user ON purchases (user_id, created_at DESC);
```

### 5.8 ACID Compliance — Transactions for All Multi-Step Operations

```
RULE: Any operation touching more than one row or table must be wrapped in a transaction.
RULE: If any step in a transaction fails, all steps roll back. No partial state is acceptable.
```

```sql
-- Tier upgrade: atomic, audit-logged, idempotent
BEGIN;
  UPDATE users
    SET tier = 'pro', subscription_status = 'active'
    WHERE id = $1;

  INSERT INTO user_tier_history (user_id, from_tier, to_tier, reason, event_id)
    VALUES ($1, 'free', 'pro', 'stripe_webhook', $2);

  INSERT INTO processed_webhook_events (event_id, processed_at)
    VALUES ($2, NOW());
COMMIT;
-- If any INSERT fails, the UPDATE rolls back. Tier never changes without an audit record.
```

### 5.9 Migrations — Forward-Only, Non-Destructive, Reversible

```
RULE: Never edit a migration that has already run in production. Add a new one.
RULE: Never drop a column in the same migration that removes it from code.
      Deploy code first, drop column in a separate subsequent migration.
RULE: Every migration must have a corresponding down migration.
RULE: Naming convention: NNN_description.sql (e.g. 006_add_email_verified_column.sql)
```

**Safe pattern for adding NOT NULL columns on large tables (avoids full table lock):**

```sql
-- WRONG on large tables: locks the table
ALTER TABLE users ADD COLUMN email_verified_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- CORRECT: 3-step migration
-- Step 1 (this migration): add nullable — fast, no lock
ALTER TABLE users ADD COLUMN email_verified_at TIMESTAMPTZ DEFAULT NULL;

-- Step 2 (next deploy): backfill in batches — no lock
UPDATE users SET email_verified_at = created_at WHERE email_verified_at IS NULL;

-- Step 3 (following migration): add NOT NULL constraint — fast since column is populated
ALTER TABLE users ALTER COLUMN email_verified_at SET NOT NULL;
```

### 5.10 Sensitive Data in the Database

```
RULE: Never store raw passwords — bcrypt hash only.
RULE: Never store raw refresh tokens — SHA-256 hash only (as bytea).
RULE: Never store card numbers, CVVs, or bank account numbers — store provider's token only.
RULE: Never store raw webhook secrets or API keys.
```

For PII (email addresses, names), consider column-level encryption using `pgcrypto` if targeting enterprise customers who will conduct security reviews:

```sql
-- pgcrypto: encrypt PII at rest
UPDATE users SET email = pgp_sym_encrypt(email, $ENCRYPTION_KEY) WHERE id = $1;
-- Query: WHERE pgp_sym_decrypt(email, $ENCRYPTION_KEY) = $input_email
-- Note: encrypted columns cannot use standard indexes — requires separate hash index
```

### 5.11 Row-Level Security

Even though application code enforces `WHERE user_id = $currentUser`, add PostgreSQL RLS as a second layer that prevents cross-user data access even in case of SQL injection:

```sql
ALTER TABLE purchases ENABLE ROW LEVEL SECURITY;

CREATE POLICY user_owns_purchases ON purchases
  USING (user_id = current_setting('app.current_user_id', true)::UUID);

-- Set per-request in the connection:
await db.query(`SET LOCAL app.current_user_id = '${userId}'`);
```

### 5.12 Connection Pool and Query Timeout Configuration

```javascript
// RULE: Always configure statement_timeout to prevent runaway queries
// RULE: Always configure connectionTimeoutMillis to fail fast under load
const pool = new Pool({
  max:                        20,     // max concurrent connections
  idleTimeoutMillis:          30000,  // release idle connections after 30s
  connectionTimeoutMillis:    2000,   // fail fast if pool exhausted
  statement_timeout:          5000,   // kill any query running over 5s
});
```

---

## 6. Security Principles

### 6.1 Email Verification

- Add `email_verified_at TIMESTAMPTZ DEFAULT NULL` to users table at initial schema creation
- Even if verification is not enforced at launch, the column must exist now to avoid a schema migration later
- A `requireVerified` middleware must exist but can be unenforced until activation

```
RULE: If the system sends transactional emails, email verification is pre-launch mandatory.
RULE: If the system does not send emails at launch, email verification can follow post-launch.
```

### 6.2 Password Reset Flow

Password reset tokens must:
- Be cryptographically random (32 bytes minimum)
- Be stored as a hash (not raw) in the DB
- Have a short TTL (15–30 minutes)
- Be single-use (invalidated immediately on use)
- Not reveal whether an email exists in the system (return identical response for registered and unregistered emails)

```
RULE: "Email already registered" on register leaks account existence — return generic response instead.
RULE: Password reset endpoint must return the same response regardless of whether email is found.
```

### 6.3 Rate Limiting Scope

| Endpoint | Key | Limit | Window |
|---|---|---|---|
| `POST /auth/login` | email (lowercase) | 10 attempts | 15 min |
| `POST /auth/register` | IP | 10 attempts | 15 min |
| `POST /auth/refresh` | IP | 30 attempts | 15 min |
| `POST /auth/password-reset-request` | email + IP | 5 attempts | 60 min |

```
RULE: Rate limiting Redis failure must not block auth — log and continue (fail open for availability).
RULE: Rate limit responses must include Retry-After header.
```

### 6.4 TLS Certificate Pinning (macOS Client)

- Pin the public key SPKI hash, not the certificate (key pinning survives cert renewal)
- Always pin 2 keys: current + backup
- Document the forced app update strategy for key rotation

```
RULE: Pinning a single key with no backup will break all clients on cert renewal.
RULE: The backup key hash must be stored in the app before the primary key is rotated.
```

---

## 7. Implementation Checklist

### Authentication
- [ ] JWT algorithm pinned to `HS256` in both sign and verify
- [ ] `issuer` and `audience` set on all JWTs and validated on verify
- [ ] `JWT_SECRET` crashes server on startup if unset or < 32 bytes
- [ ] `REFRESH_TOKEN_SECRET` crashes server on startup if unset or < 32 bytes
- [ ] Refresh tokens stored as SHA-256 hash (bytea) — raw token never in DB
- [ ] Token rotation is atomic (single DB transaction)
- [ ] Family-based theft detection implemented in `/auth/refresh`
- [ ] `TOKEN_EXPIRED` and `TOKEN_INVALID` return distinct error codes
- [ ] `POST /auth/logout` revokes specific refresh token
- [ ] "Logout all devices" endpoint revokes all refresh tokens for user
- [ ] bcrypt cost factor >= 12

### Business Logic
- [ ] `users.tier` is the only tier authority — never derived from JWT alone
- [ ] Subscription state machine with `validateTransition()` guards all state changes
- [ ] Tier limits defined in a central config object, not per-route
- [ ] Security alerts go to monitored channel (Slack/email), not just logs
- [ ] Audit log table exists and is append-only (UPDATE/DELETE revoked)
- [ ] All 8 mandatory audit events are logged

### Billing
- [ ] All billing operations are idempotent (processed_webhook_events table)
- [ ] All webhook signatures are validated before processing
- [ ] Chargebacks trigger immediate tier downgrade + account flag
- [ ] Tier changes are atomic with audit log entry (single transaction)
- [ ] No payment method data stored — only provider token/customer ID
- [ ] Billing logic is in `billing.js` — zero billing code in `auth.js`

### API
- [ ] All endpoints have input validation middleware (zod/express-validator)
- [ ] All error responses follow `{ error, code, requestId }` contract
- [ ] All canonical error codes (`TOKEN_EXPIRED`, `TIER_INSUFFICIENT`, etc.) are defined
- [ ] Security headers applied globally (HSTS, Cache-Control: no-store, X-Content-Type-Options)
- [ ] `password`, `refreshToken`, and secrets are scrubbed before logging
- [ ] `expiresIn` in auth responses is derived from `ACCESS_TOKEN_TTL` env var (not hardcoded)

### Database
- [ ] Financial/payment tables have no UPDATE/DELETE in application code
- [ ] Users table has `deleted_at` column (soft delete)
- [ ] All relationships enforced with foreign keys (ON DELETE behavior explicit)
- [ ] All user-owned tables have `created_at`, `updated_at` (with trigger), `user_id`
- [ ] `updated_at` trigger applied to all tables with that column
- [ ] Enum columns have CHECK constraints
- [ ] Indexes match query patterns (partial indexes for active-only queries)
- [ ] Multi-step operations use transactions
- [ ] Migrations are numbered sequentially, have down migrations, and are never edited post-deploy
- [ ] RLS enabled on user-owned tables
- [ ] Connection pool has `statement_timeout` and `connectionTimeoutMillis` configured

---


