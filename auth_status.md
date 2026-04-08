# Auth System — Implementation Status

> Last updated: 8 April 2026 (Phase A complete, Phase B server-side complete)
> Reference document: `auth_implementation.md` (3,212 lines, 11 sections)
> Build baseline: BUILD SUCCEEDED, 140 tests, 0 failures (5 April 2026, arm64)

**Legend:** ✅ Done · ⚠️ Partial · ❌ Not started · 🔴 Blocking (P0)

---

## Phase A — Immediate Hardening (Server-only, no client deps)

| ID | Task | Status | File | Notes |
|---|---|---|---|---|
| A.1 | Pin JWT algorithm (`algorithms: ['HS256']`), add `issuer` + `audience` to sign and verify | ✅ | `token-server/auth.js` | Lines 48–53, 170–173 |
| A.2 | Crash on weak/missing `JWT_SECRET` at startup | ✅ | `token-server/auth.js` | Lines 27–34 |
| A.3 | Remove LiveKit API key from startup log | ✅ | `token-server/index.js` | Line deleted |
| A.4 | Rate limiting on `/auth/register` and `/auth/login` | ✅ | `token-server/index.js` | `rateLimitAuth` — lines 159, 248, 271 |
| A.5 | Centralized error handler — no raw DB errors to client | ✅ | `token-server/index.js` | `requestId` correlation — line 2096 |
| A.6 | Security response headers (HSTS, X-Content-Type, X-Frame) | ✅ | `token-server/index.js` | Lines 79–85 |
| A.6b | Add missing `Referrer-Policy: no-referrer` header | ✅ | `token-server/index.js` | Added alongside X-Frame-Options in security headers middleware |
| A.7 | Timing normalization — `DUMMY_HASH` in `register()` and `login()` | ✅ | `token-server/auth.js` | `DUMMY_HASH` computed once at module load; `bcrypt.compare`/`bcrypt.hash` on every early-exit path |
| A.8 | Input validation + bcrypt 72-byte guard in `register()` and `login()` | ✅ | `token-server/auth.js` | Email regex + 254 cap, password 8–72 byte range via `Buffer.byteLength`, displayName 1–100 chars |

**Phase A overall: 9/9 done. ✅ COMPLETE**

---

## Phase B — Full Refresh Token System

> **Dependency:** Build server + client together in one sitting. Do NOT split — access tokens expire in 15 min with no recovery path if client-side refresh isn't ready.
> **Server-side verified:** register, login, /auth/refresh (rotation + theft detection), /auth/logout, /auth/logout-all all tested 8 April 2026.

| ID | Task | Status | File | Notes |
|---|---|---|---|---|
| B.1 | Migration: `refresh_tokens` table | ✅ | `token-server/migrations/004_refresh_tokens.sql` | Table created, 3 partial indexes, FK to users(ON DELETE CASCADE) |
| B.2a | Add `issueRefreshToken(userId, clientId, dbClient)` to `auth.js` | ✅ | `token-server/auth.js` | SHA-256 storage, new family per login, `make_interval` for TTL |
| B.2b | Update `login()` + `register()` to return `{ accessToken, refreshToken, expiresIn }` | ✅ | `token-server/auth.js` | Both wrapped in DB transactions; access token TTL = 15 min |
| B.2c | Update `authenticateToken` to handle short-lived access tokens (15 min) | ✅ | `token-server/auth.js` | Returns `TOKEN_EXPIRED` / `TOKEN_INVALID`; includes `tokenFamily` in req.user |
| B.2d | Export `issueRefreshToken`, `revokeAllForUser`, `generateAccessToken`, `parseTTLtoSeconds` | ✅ | `token-server/auth.js` | All exported + `REFRESH_TOKEN_DAYS` constant |
| B.3a | Add `POST /auth/refresh` endpoint | ✅ | `token-server/index.js` | Theft detection, rotation, fresh tier re-read, device binding (soft) |
| B.3b | Add `POST /auth/logout` endpoint | ✅ | `token-server/index.js` | Revokes single refresh token; returns 204 |
| B.3c | Add `POST /auth/logout-all` endpoint | ✅ | `token-server/index.js` | Calls `auth.revokeAllForUser()`; returns 204 |
| B.3d | Apply `rateLimitAuth` to `/auth/refresh` | ✅ | `token-server/index.js` | Consistent with login/register |
| B.4a | `InterTokenService.swift` — store tokens in Keychain | ❌ | `inter/Networking/InterTokenService.swift` | See §4 B.4 — kSecAttrService `"com.inter.auth"`, access tokens in memory only |
| B.4b | `InterTokenService.swift` — silent refresh on 401 `TOKEN_EXPIRED` | ❌ | `inter/Networking/InterTokenService.swift` | Retry original request after successful refresh |
| B.4c | `InterTokenService.swift` — TLS certificate pinning | ❌ | `inter/Networking/InterTokenService.swift` | `URLSessionDelegate` — pin SHA-256 of server cert pubkey |
| B.4d | macOS login/register UI (AppDelegate or dedicated window) | ❌ | `inter/App/AppDelegate.m` or new controller | Gate app launch on successful auth; store `tier` from token payload |

**Phase B server-side: 9/9 done ✅. Client-side: 0/4 done.**

---

## Phase C — Billing & Tier Lifecycle Integration

> **Dependency:** Phase B must be complete. Payment gateway (Stripe) must be configured.

| ID | Task | Status | File | Notes |
|---|---|---|---|---|
| C.1 | 🔴 Mount Stripe webhook route BEFORE `express.json()` | ❌ | `token-server/index.js` | **P0 — Gap G20.** `express.raw({ type: 'application/json' })` required. Wrong order = silent failure on all webhooks |
| C.2 | Migration: billing columns on `users` table | ❌ | `token-server/migrations/005_billing_columns.sql` | See §10 migration starter — `subscription_status`, `subscription_id`, `customer_id`, `trial_ends_at`, `current_period_ends_at` |
| C.3 | Migration: `processed_webhook_events` idempotency table | ❌ | Included in `005_billing_columns.sql` | Prevents double-processing of at-least-once Stripe delivery |
| C.4 | Create `billing.js` webhook handler | ❌ | `token-server/billing.js` | See §10 for complete starter — handles 8 Stripe event types |
| C.5 | Update `requireTier()` to check `subscription_status` | ❌ | `token-server/auth.js` | **P0 — Gap G15.** Past-due users currently keep paid access. Must reject if `subscription_status = 'past_due'` |
| C.6 | Wire Stripe customer creation on register/upgrade | ❌ | `token-server/auth.js` or `billing.js` | `stripe.customers.create({email})` — store `customer_id` on user row |
| C.7 | Configure `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET` in `.env` | ❌ | `token-server/.env` | Already in `.env.example` — copy and fill values |

**Phase C overall: 0/7 done.**

---

## Phase D — Account Recovery & Security Hardening

> **Dependency:** `nodemailer` + SMTP provider (Resend/SendGrid/Postmark). Can be built independently of Phase B/C client UI.

| ID | Task | Status | File | Notes |
|---|---|---|---|---|
| D.1a | Migration: `password_reset_tokens` table | ❌ | `token-server/migrations/006_password_reset_tokens.sql` | See §6 D.1 — UUID PK, `token_hash`, 1-hour TTL, `used_at` |
| D.1b | `POST /auth/forgot-password` endpoint | ❌ | `token-server/index.js` | Rate-limited; generates reset token; sends email; always 200 (anti-enumeration) |
| D.1c | `POST /auth/reset-password` endpoint | ❌ | `token-server/index.js` | Validates token, bcrypt new hash, marks token used, revokes all refresh tokens |
| D.1d | Add `auth.resetPassword(token, newPassword)` to `auth.js` | ❌ | `token-server/auth.js` | See §6 D.1 — extractable function, uses `db.getClient()` (not `db.connect()`) |
| D.1e | 🔴 Register `inter://` URL scheme in `Info.plist` | ❌ | `inter/Info.plist` | **P0 — Gap G12.** macOS deep link for password reset email. Without it the reset link silently drops. See §6 for XML block |
| D.1f | Handle `inter://reset-password?token=xxx` in macOS app | ❌ | `inter/App/AppDelegate.m` | `application:openURL:options:` delegate method |
| D.2a | Migration: `email_verifications` table | ❌ | `token-server/migrations/007_email_verifications.sql` | See §6 D.2 — UUID token, `verified_at`, `expires_at` |
| D.2b | `POST /auth/verify-email` endpoint | ❌ | `token-server/index.js` | Marks email verified; gates features if unverified |
| D.2c | Send verification email on register | ❌ | `token-server/index.js` (register handler) | Call `mailer.sendVerificationEmail()` after user insert |
| D.2d | Add `email_verified` column to `users` table | ❌ | In `007_email_verifications.sql` or new migration | `ALTER TABLE users ADD COLUMN email_verified BOOLEAN DEFAULT FALSE` |
| D.3 | `POST /auth/logout-all` (revoke all devices) | ✅ | `token-server/index.js` | Implemented in Phase B.3c |
| D.4a | Migration: `audit_log` table | ❌ | `token-server/migrations/008_audit_log.sql` | See §6 D.4 — events: `login`, `logout`, `register`, `failed_login`, `token_theft`, `tier_change`, `password_reset` |
| D.4b | Write audit events from auth endpoints | ❌ | `token-server/auth.js` + `index.js` | Replace `console.error` security events with DB writes |
| D.5 | Security alert on token theft detection | ❌ | `token-server/auth.js` (`issueRefreshToken`) | See §6 D.5 — call `mailer.sendSecurityAlert()` + write audit event when family reuse detected |
| D.6 | Create `mailer.js` | ❌ | `token-server/mailer.js` | See §10 for complete starter — `sendPasswordResetEmail`, `sendVerificationEmail`, `sendSecurityAlert` |
| D.7 | Configure SMTP env vars | ❌ | `token-server/.env` | `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `SMTP_FROM` — already in `.env.example` |

**Phase D overall: 0/16 done.**

---

## Recording Wiring (Post-Phase-B dependency)

These 3 items are tracked in the Recording Pause Checkpoint in `work_done.md` but have an auth dependency:

| ID | Task | Status | Dependency | File |
|---|---|---|---|---|
| R1 | Replace hardcoded `tier = @"free"` with real profile tier from auth | ❌ | Phase B live + Keychain token | `inter/App/AppDelegate.m` line ~1988 |
| R2 | Wire `InterRecordingListPanel` into call UI | ❌ | Auth live (endpoint requires token) | `inter/App/AppDelegate.m`, `InterLocalCallControlPanel.m` |
| R3 | Wire `InterRecordingConsentPanel` to show on participant join | ❌ | No auth dependency | `inter/App/AppDelegate.m` (participant-join handler) |

---

## Infrastructure Prerequisites

| Item | Status | Notes |
|---|---|---|
| PostgreSQL 15.13 running locally | ✅ | `localhost:5432`, database `inter_dev` |
| Redis 8.6.2 running locally | ✅ | `localhost:6379` |
| LiveKit Server 1.9.11 running locally | ✅ | `ws://localhost:7880` |
| Token server boots cleanly | ✅ | `node token-server/index.js` |
| `.env` has `JWT_SECRET` (32+ bytes) | ✅ | Generated and set in `.env` |
| `.env` has `REFRESH_TOKEN_SECRET` | ✅ | Generated and set in `.env` |
| Stripe keys configured | ❌ | Required for Phase C |
| SMTP provider configured | ❌ | Required for Phase D |

---

## Files to be Created

| File | Phase | Status |
|---|---|---|
| `token-server/migrations/004_refresh_tokens.sql` | B.1 | ✅ |
| `token-server/migrations/005_billing_columns.sql` | C.2/C.3 | ❌ |
| `token-server/migrations/006_password_reset_tokens.sql` | D.1a | ❌ |
| `token-server/migrations/007_email_verifications.sql` | D.2a | ❌ |
| `token-server/migrations/008_audit_log.sql` | D.4a | ❌ |
| `token-server/billing.js` | C.4 | ❌ |
| `token-server/mailer.js` | D.6 | ❌ |

---

## Summary

| Phase | Tasks | Done | Remaining |
|---|---|---|---|
| A — Hardening | 9 | 9 | 0 ✅ |
| B — Refresh Tokens | 13 | 9 | 4 (client-side) |
| C — Billing | 7 | 0 | 7 |
| D — Account Recovery | 16 | 1 | 15 |
| **Total** | **45** | **19** | **26** |

**Next:** Phase B client-side (B.4a–B.4d) — Keychain storage, silent refresh, TLS pinning, login UI in `InterTokenService.swift`.
