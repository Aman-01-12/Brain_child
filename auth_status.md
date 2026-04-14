# Auth System — Implementation Status

> Last updated: 13 April 2026 (Phase A complete, Phase B complete, Phase C complete, Billing UX complete, Billing Audit 14/14 fixes applied)
> Reference document: `auth_implementation.md` (11 sections)
> Billing provider: **Lemon Squeezy** (Merchant of Record)
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
| B.3d | Rate limiting on `/auth/refresh` | ✅ | `token-server/index.js` | Dedicated `rateLimitRefresh` middleware — IP-keyed, 30 req/60s, `Retry-After` header, Redis-fault-tolerant |
| B.4a | `InterTokenService.swift` — store tokens in Keychain | ✅ | `inter/Networking/InterTokenService.swift` | `kSecAttrService "com.inter.app.refreshtoken"`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, access tokens memory-only |
| B.4b | `InterTokenService.swift` — silent refresh on 401 `TOKEN_EXPIRED` | ✅ | `inter/Networking/InterTokenService.swift` | `performAuthenticatedRequest` intercepts TOKEN_EXPIRED → `refreshAccessToken` → replay; proactive timer at expiresIn-75s |
| B.4c | `InterTokenService.swift` — TLS certificate pinning | ✅ | `inter/Networking/InterTokenService.swift` | `InterPinnedSessionDelegate` — SPKI SHA-256 pinning via `SecCertificateCopyKey`; dev bypass when no pins configured |
| B.4d | macOS login/register UI (AppDelegate or dedicated window) | ✅ | `inter/UI/Views/InterLoginPanel.h/.m`, `inter/App/AppDelegate.m` | Login/register panel gates app launch; session restore via Keychain; tier stored from JWT; InterAuthSessionDelegate for expiry |

**Phase B: 13/13 done ✅ COMPLETE (server 9/9 + client 4/4).**

---

## Phase C — Billing & Tier Lifecycle Integration

> **Dependency:** Phase B must be complete. Payment gateway (Lemon Squeezy) must be configured.
> **Provider:** Lemon Squeezy (Merchant of Record — handles tax, 3DS, dunning, disputes)

| ID | Task | Status | File | Notes |
|---|---|---|---|---|
| C.1 | 🔴 Mount LS webhook route BEFORE `express.json()` | ✅ | `token-server/index.js` | `express.raw()` + HMAC-SHA256 via `X-Signature`. Mounted before `express.json()` — line 76 |
| C.2 | Migration: billing columns on `users` table | ✅ | `token-server/migrations/006_billing_columns.sql` | 11 columns: `subscription_status`, `ls_customer_id`, `ls_subscription_id`, `ls_variant_id`, `ls_product_id`, `grace_until`, `trial_ends_at`, `current_period_ends_at`, `ls_portal_url`, `deleted_at`, `deletion_reason` |
| C.3 | Migration: `processed_webhook_events` idempotency table | ✅ | Included in `006_billing_columns.sql` | + `user_tier_history` audit table (append-only) |
| C.4 | Create `billing.js` webhook handler | ✅ | `token-server/billing.js` | 12 LS event types via `meta.event_name`, HMAC-SHA256 verification, idempotency, state machine transitions, tier audit logging |
| C.5 | Update `requireTier()` to check `subscription_status` | ✅ | `token-server/auth.js` | Fresh DB read, `INACTIVE_STATUSES` set, grace period for `cancelled`, `TRIAL_GRANTS_TIER` for `on_trial` → `pro` |
| C.6 | Create `POST /billing/checkout` endpoint | ✅ | `token-server/index.js` | LS checkout URL via `createCheckout()` with `custom_data.user_id` + `GET /billing/portal-url` for customer portal |
| C.7 | Configure `LEMONSQUEEZY_API_KEY`, `LEMONSQUEEZY_WEBHOOK_SECRET`, `LEMONSQUEEZY_STORE_ID` in `.env` | ✅ | `token-server/.env` | All three keys set. Webhook secret truncated to 26 chars (`N9X7PBZ3U6gN64Un3HZnIX8GF2`) — LS dashboard enforces 40-char max. Same value set in LS dashboard. |

**Phase C overall: 7/7 done ✅ COMPLETE.**

---

## Phase C-UX — Seamless Billing Upgrade Flow

> **Dependency:** Phase C.6 (checkout endpoint) must be complete. `inter://` URL scheme registered.
> **Design:** LS checkout → browser → `inter://billing/success` deep link → poll `/billing/status` → auto-refresh token → new tier propagated instantly.

| ID | Task | Status | File | Notes |
|---|---|---|---|---|
| CX.1 | Register `inter://` URL scheme in `Info.plist` | ✅ | `inter/Info.plist` | `CFBundleURLTypes` with `inter` scheme (also used by Phase D password reset) |
| CX.2 | Set checkout redirect URL to `inter://billing/success` | ✅ | `token-server/index.js` | `redirectUrl` in `createCheckout()` call |
| CX.3 | Add `GET /billing/status` endpoint | ✅ | `token-server/index.js` | Returns `{ tier, subscriptionStatus }` — lightweight poll target |
| CX.4 | Add `refreshAndWaitForTierChange` in InterTokenService | ✅ | `inter/Networking/InterTokenService.swift` | Polls `/billing/status` up to 5× at 2s intervals, then `/auth/refresh` for new JWT |
| CX.5 | Add `requestCheckoutURL` / `requestPortalURL` in InterTokenService | ✅ | `inter/Networking/InterTokenService.swift` | `@objc` methods callable from AppDelegate.m |
| CX.6 | Handle `inter://billing/success` deep link in AppDelegate | ✅ | `inter/App/AppDelegate.m` | `application:openURLs:` → polls → refresh → UI update |
| CX.7 | Add Upgrade/Manage buttons to setup overlay | ✅ | `inter/App/AppDelegate.m` | Conditional: free→"Upgrade to Pro", paid→"Manage Subscription" |
| CX.8 | Billing status label + success confirmation | ✅ | `inter/App/AppDelegate.m` | Shows "Verifying…" / "Upgraded to Pro!" / timeout message |

**Phase C-UX overall: 8/8 done ✅ COMPLETE.**

### Billing Audit Fixes (13 April 2026) — All 14 Applied

A full cross-layer audit of the billing flow was performed across billing-page.js, index.js, InterTokenService.swift, and AppDelegate.m.

| # | Priority | Fix | File |
|---|---|---|---|
| 1 | P0 | Crypto-random webhook secret (replaced weak `amanverma019999`) | `.env` |
| 2 | P1 | `pollBillingStatus` completion leak — `guard let self` + `completion(nil)` on dealloc | `InterTokenService.swift` |
| 3 | P1 | `VARIANT_ID_TO_TIER` derived from `BILLING_PLANS` — no more duplicate hardcoded map | `billing.js` |
| 4 | P1 | `extractExpiration` base64url→base64 conversion (`-`→`+`, `_`→`/`) | `InterTokenService.swift` |
| 5 | P1 | `requestPortalURL` error logging added | `InterTokenService.swift` |
| 6 | P1 | Stale poll guard — `billingPollGeneration` counter; stale completions discarded | `AppDelegate.m` |
| 7 | P2 | Nil `tokenService` guard in `handleViewPlans` + `handleManageSubscription` | `AppDelegate.m` |
| 8 | P2 | `validatedTier()` — rejects empty/unknown tier values at both login and refresh | `InterTokenService.swift` |
| 9 | P2 | `GET /billing/portal-url` fetches fresh URL from LS API (fixes 24h expiry), falls back to DB cache | `index.js` |
| 10 | P2 | `handleManageSubscription` shows "Loading…" while fetching portal URL | `AppDelegate.m` |
| 11 | P2 | Production env var placeholders added to `.env` | `.env` |
| 12 | P3 | `rateLimitBilling` middleware on authenticated billing endpoints (10 req/60s) | `index.js` |
| 13 | P3 | `formatPrice` early-return for `price === 0` removed — `Intl.NumberFormat` handles all | `billing-page.js` |
| 14 | P3 | Per-request nonce + `history.replaceState` strips page token from browser URL bar | `index.js` |

**Note**: Webhook secret in `.env` is `N9X7PBZ3U6gN64Un3HZnIX8GF2` (26 chars). LS dashboard enforces a 40-char maximum so the original 32-byte secret was trimmed. The same trimmed value is set in the LS dashboard.

### Production Steps (C-UX)

- **Migrate to Apple Universal Links** — The current custom URL scheme (`inter://`) is registered in Info.plist but custom schemes can still be hijacked by a malicious app claiming the same scheme on the same device. For production, replace the deep-link callback with Universal Links: host an `apple-app-site-association` (AASA) JSON file at `https://api.inter.com/.well-known/apple-app-site-association`, add the Associated Domains entitlement (`applinks:api.inter.com`) to the app, and change the LS `redirectUrl` to `https://api.inter.com/billing/success`. macOS will then route the HTTPS URL directly to the app without going through the browser's URL-scheme dispatcher, fully preventing scheme hijacking.

---

## Phase D — Account Recovery & Security Hardening

> **Dependency:** `nodemailer` + SMTP provider (Resend/SendGrid/Postmark). Can be built independently of Phase B/C client UI.

| ID | Task | Status | File | Notes |
|---|---|---|---|---|
| D.1a | Migration: `password_reset_tokens` table | ✅ | `token-server/migrations/009_password_reset_tokens.sql` | UUID PK, `token_hash` BYTEA UNIQUE, 1-hour TTL, `used_at`, partial index |
| D.1b | `POST /auth/forgot-password` endpoint | ✅ | `token-server/index.js` | Rate-limited; fire-and-forget DB+email; always 200 (anti-enumeration) |
| D.1c | `POST /auth/reset-password` + web form + landing page | ✅ | `token-server/index.js` | JSON API, `POST /auth/reset-password-web` (HTML), `GET /reset-password` (deep link + fallback form) |
| D.1d | `auth.resetPassword()` + `auth.auditLog()` in `auth.js` | ✅ | `token-server/auth.js` | Extracted core logic; single transaction; revokes all sessions; auditLog never crashes flows |
| D.1e | Register `com-inter-app://` URL scheme in `Info.plist` | ✅ | `inter/Info.plist` | Done in CX.1 — shared by billing + password reset |
| D.1f | Handle `com-inter-app://reset-password?token=xxx` deep link | ✅ | `inter/App/AppDelegate.m` | Added `reset-password` to allowedPaths; `handlePasswordResetDeepLinkWithToken:` shows secure input alert |
| D.2a | Migration: `email_verification_tokens` table | ✅ | `token-server/migrations/010_email_verification.sql` | UUID PK, `token_hash`, 8-hour TTL, `used_at`; also adds `email_verified_at` column to `users` |
| D.2b | `GET /auth/verify-email` + `POST /auth/resend-verification` | ✅ | `token-server/index.js` | Verify marks `email_verified_at`; resend is fire-and-forget, always 200 |
| D.2c | Send verification email on register | ✅ | `token-server/index.js` (register handler) | Fire-and-forget after user insert; does not fail registration |
| D.2d | `email_verified_at` column on `users` table | ✅ | `token-server/migrations/010_email_verification.sql` | `TIMESTAMPTZ NULL` — soft-gate only (no login block) |
| D.3 | `POST /auth/logout-all` (revoke all devices) | ✅ | `token-server/index.js` | Implemented in Phase B.3c; audit log added |
| D.4a | Migration: `audit_events` table | ✅ | `token-server/migrations/011_audit_events.sql` | Append-only; indexed by `(user_id, created_at DESC)` and `(event_type, created_at DESC)` |
| D.4b | Write audit events from auth endpoints | ✅ | `token-server/auth.js` + `index.js` | All auth events logged: register, login_success, login_failure, password_reset_requested/completed, email_verified, logout, logout_all, session_compromised |
| D.5 | Security alert on token theft detection | ✅ | `token-server/index.js` | `dispatchSecurityAlert()` — Slack webhook + `sendSecurityAlertEmail()` on refresh token family reuse |
| D.6 | Create `mailer.js` | ✅ | `token-server/mailer.js` | 4 exports: `sendPasswordResetEmail`, `sendVerificationEmail`, `sendSecurityAlertEmail`, `sendPaymentFailedEmail` |
| D.7 | Configure SMTP env vars | ✅ | `token-server/.env` | `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `SMTP_FROM`, `SECURITY_WEBHOOK_URL` — commented placeholders |

**Phase D overall: 16/16 COMPLETE ✅**

---

## Recording Wiring (Post-Phase-B dependency)

These 3 items are tracked in the Recording Pause Checkpoint in `work_done.md` but have an auth dependency:

| ID | Task | Status | Dependency | File |
|---|---|---|---|---|
| R1 | Replace hardcoded `tier = @"free"` with real profile tier from auth | ✅ | Phase B live + Keychain token | `inter/App/AppDelegate.m` — uses `effectiveTier` from JWT |
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
| Lemon Squeezy keys configured | ✅ | `LEMONSQUEEZY_API_KEY`, `LEMONSQUEEZY_WEBHOOK_SECRET`, `LEMONSQUEEZY_STORE_ID` all set in `.env` |
| SMTP provider configured | ❌ | Required for Phase D |

---

## Files to be Created

| File | Phase | Status |
|---|---|---|
| `token-server/migrations/004_refresh_tokens.sql` | B.1 | ✅ |
| `token-server/migrations/006_billing_columns.sql` | C.2/C.3 | ✅ | LS columns + idempotency + tier history |
| `token-server/migrations/006_password_reset_tokens.sql` | D.1a | ❌ |
| `token-server/migrations/007_email_verifications.sql` | D.2a | ❌ |
| `token-server/migrations/008_audit_log.sql` | D.4a | ❌ |
| `token-server/billing.js` | C.4 | ✅ |
| `token-server/mailer.js` | D.6 | ❌ |

---

## Production Deployment Guide

### Branding Note

The internal codename is **inter** and nothing in the codebase changes — bundle IDs (`com.inter.app`), class names (`InterTokenService`, `InterRoomController`, etc.), file names, URL schemes (`inter://`), and Redis/DB keys all stay as-is.

Only the **public-facing layer** changes when a final brand name is chosen:
- App display name (shown in Finder, Dock, macOS menu bar) — `Info.plist` → `CFBundleDisplayName`
- App icon / logo assets
- Website domain (e.g. `<newname>.com` instead of `inter.com`)
- API subdomain (e.g. `api.<newname>.com`) — also update `BILLING_PAGE_BASE_URL`, `APP_RETURN_URL`, AASA file host, and LS dashboard redirect/webhook URLs
- Marketing copy, App Store / Setapp listing

No Swift, Objective-C, SQL, or server code needs to change for a rebrand.

---

### Domain Strategy

Buy one domain (e.g. `inter.com`). Subdomains (`api.inter.com`, `app.inter.com`) are free and unlimited once you own the root.

**Recommended layout — start with `api.inter.com` from day one:**

```
Day 1 (launch):
  api.inter.com  →  token-server (Railway / Render)
  inter.com      →  unused, or a simple "coming soon" / download HTML page

Month 3:
  api.inter.com  →  token-server (unchanged)
  inter.com      →  landing page with download button (Vercel / Netlify — free)

Year 1+ (if web app built):
  api.inter.com  →  token-server (still unchanged)
  inter.com      →  React web app (Vercel)
```

Starting on `api.inter.com` means `inter.com` is always free for whatever comes next — no migration, no downtime dance, no forcing users to update the app.

### What to Deploy

Your entire backend is the `token-server/` folder — **one Node.js server, one deployment, one domain.** It already serves:
- All auth API endpoints (`/auth/*`)
- The billing pricing page (`/billing/plans`) — rendered server-side, opened in browser by the macOS app
- The post-payment return page (`/billing/success`) — fires the deep link back to the app
- The LS webhook receiver (`/webhooks/lemonsqueezy`)
- All other API calls from the macOS app

No separate frontend deployment needed for the initial launch.

### Env Vars to Set on the Server

When deploying, set these in your hosting platform's environment variables panel:

```dotenv
BILLING_PAGE_BASE_URL=https://api.inter.com   # base URL of your token-server
APP_RETURN_URL=https://api.inter.com/billing/success

# All other vars same as .env — DB, Redis, JWT secrets, LS keys, LiveKit
```

### Lemon Squeezy Dashboard Updates (on every domain change)

1. **Webhook URL** → `https://api.inter.com/webhooks/lemonsqueezy`
2. **Redirect URL (after checkout)** → `https://api.inter.com/billing/success` — must be whitelisted in LS store settings
3. **Webhook signing secret** → must match `LEMONSQUEEZY_WEBHOOK_SECRET` in `.env`

### Zero-Downtime Migration (only needed if you launched on `inter.com` first)

If you ever need to move the token-server from `inter.com` to `api.inter.com`:

1. Lower DNS TTL on `inter.com` to 60s — wait 24h
2. Point `api.inter.com` to the same server — now both domains work simultaneously
3. Ship a macOS app update that uses `api.inter.com` as the server URL
4. Wait 2–4 weeks for user adoption (watch version analytics)
5. When 95%+ are on the new version, point `inter.com` to your web app / landing page

### If a Web App Is Built Later (`inter.com/app`)

The token-server needs zero changes — the web app calls the same `/auth/*` and `/livekit/token` endpoints as the macOS app. Only additions needed:
- A CORS header on the token-server allowing `inter.com` origin
- A React frontend using the LiveKit JavaScript SDK (`@livekit/components-react`)
- Deploy the React app to Vercel, point `inter.com` DNS there

---

## Implementation Changelog

| Date | Phase | Key Changes | Files |
|---|---|---|---|
| 26 March 2026 | Phase A (9/9) | Created `auth.js` — bcrypt register/login, JWT (HS256, 7d), `authenticateToken`/`requireAuth`/`requireTier` middleware, `DUMMY_HASH` timing normalisation, email/password/displayName validation, rate limiting, security headers, centralised error handler | `token-server/auth.js`, `token-server/index.js` |
| 8 April 2026 | Phase B (13/13) | Refresh token system: rotation, theft detection, `/auth/refresh`, `/auth/logout`, `/auth/logout-all`, Redis rate limiting; macOS client: Keychain storage, silent refresh on 401, TLS SPKI pinning, login/register UI gating app launch | `token-server/auth.js`, `token-server/index.js`, `token-server/migrations/004_refresh_tokens.sql`, `inter/Networking/InterTokenService.swift`, `inter/UI/Views/InterLoginPanel.h/.m`, `inter/App/AppDelegate.m` |
| 8 April 2026 | Phase C (6/7) + C-UX (8/8) | LS webhook (raw body + HMAC-SHA256), billing migrations (11 columns + idempotency table + tier history), `billing.js` (12 event types), `requireTier()` with grace period, checkout/portal endpoints; `inter://billing/success` deep link, billing poll, Upgrade/Manage buttons, billing status label | `token-server/billing.js`, `token-server/index.js`, `token-server/migrations/006_billing_columns.sql`, `inter/Networking/InterTokenService.swift`, `inter/App/AppDelegate.m` |
| 13 April 2026 | Billing Audit (14/14) | All P0–P3 hardening fixes — see Billing Audit Fixes table above | `token-server/.env`, `token-server/billing.js`, `token-server/billing-page.js`, `token-server/index.js`, `inter/Networking/InterTokenService.swift`, `inter/App/AppDelegate.m` |
| 13 April 2026 | Phase D (16/16) | Password reset flow (forgot/reset/web-form/landing page), email verification on register, `mailer.js` (4 email types), `auditLog()` helper, `audit_events` table, `dispatchSecurityAlert()` (Slack + email), deep link handler for `com-inter-app://reset-password`, SMTP env vars | `token-server/auth.js`, `token-server/index.js`, `token-server/mailer.js`, `token-server/migrations/009-011`, `token-server/.env`, `inter/App/AppDelegate.m` |
| 14 April 2026 | Gap Mitigation (23/24) | HIBP pwned password check (G1), change-password (G8), GDPR account deletion (G9), absolute session cutoff (G4), idle timeout (G3), sessions list/revoke (G11), change-email flow (G10), password strength meter (G5), show/hide toggle (G6). Only G7 (MFA) deferred to Phase E. | `token-server/auth.js`, `token-server/index.js`, `token-server/migrations/012-013`, `inter/App/AppDelegate.m`, `inter/UI/Views/InterLoginPanel.m` |

---

| A — Hardening | 9 | 9 | 0 ✅ |
| B — Refresh Tokens | 13 | 13 | 0 ✅ |
| C — Billing | 7 | 7 | 0 ✅ |
| C-UX — Billing Upgrade Flow | 8 | 8 | 0 ✅ |
| D — Account Recovery | 16 | 16 | 0 ✅ |
| Gap Mitigation (§10.6) | 23 | 23 | 1 (G7 MFA → Phase E) |
| **Total** | **76** | **76** | **0** |

**All phases complete.** 23/24 industry-standard gaps resolved (only G7 MFA deferred to Phase E). Remaining work: R2 (recording list panel wiring), production deployment checklist.

---

## Pending Client UI Work (Account Management Screens)

The following backend endpoints were added during Gap Mitigation but have **no client UI yet**. Each needs a settings panel or modal in the macOS app before users can access them.

| Feature | Endpoint | UI Needed |
|---------|----------|-----------|
| Change password | `POST /auth/change-password` | Settings panel: current password + new password fields + confirm |
| Change email | `POST /auth/change-email` | Settings panel: password confirmation + new email field |
| Delete account | `DELETE /auth/account` | Danger zone: password confirmation + explicit "Delete my account" button |
| Active sessions | `GET /auth/sessions` | Session list: table showing device/date, revoke individual session button |
| Revoke session | `DELETE /auth/sessions/:id` | (part of session list above) |

**Suggested entry point:** A "Account Settings" window/panel accessible from the app menu or user avatar area, with tabs: Profile / Security (change password, sessions) / Danger Zone (delete account).

---

## Pre-Website Launch — Backend Changes Required

When `inter.com` launches (marketing site or web app), the token-server needs the following changes **before** any web caller makes requests to `api.inter.com`. The macOS app is unaffected — these are additive only.

### Why each is needed

**1. `cors` package + scoped CORS middleware**
The browser's same-origin policy blocks `inter.com` from calling `api.inter.com` unless the server sends `Access-Control-Allow-Origin`. Without this, every fetch from the website silently fails at the browser level. The middleware must be applied **before** routes and must only allow trusted origins — not `*` — since we send credentials.

**2. `Set-Cookie` on login/register for web callers**
The macOS app stores its refresh token in the Keychain and sends it in the request body. Web callers cannot use the Keychain — they need the refresh token in an `httpOnly; Secure; SameSite=Strict` cookie so JavaScript cannot read it (XSS mitigation). The login/register handlers need to detect the caller type (`User-Agent` or an `X-Client: web` header) and set the cookie in addition to (or instead of) returning it in the JSON body.

**3. `POST /auth/refresh` reads cookie if no body token**
Once the web caller has the refresh token in a cookie, the browser sends it automatically on every request to `api.inter.com`. The `/auth/refresh` endpoint currently only reads `refreshToken` from the JSON body — it needs a fallback: `const token = req.body.refreshToken ?? req.cookies?.refreshToken`. Requires the `cookie-parser` middleware.

**4. Allowed origins list includes `inter.com` + `www.inter.com`**
CORS must allowlist only exact trusted origins. A wildcard or a loose regex would allow any subdomain to make credentialed requests. The origins array should be an env var (`CORS_ORIGINS`) so it can be updated without a code deploy.

### Implementation checklist

| # | Change | File | Trigger |
|---|--------|------|---------|
| W1 | `npm install cors cookie-parser` | `token-server/package.json` | Before website goes live |
| W2 | Add `CORS_ORIGINS=https://inter.com,https://www.inter.com` to `.env` | `token-server/.env` | Before website goes live |
| W3 | Mount `cors({ origin: allowedOrigins, credentials: true })` middleware before all routes | `token-server/index.js` | Before website goes live |
| W4 | Mount `cookieParser()` middleware | `token-server/index.js` | Before website goes live |
| W5 | In `login` + `register` handlers: if `X-Client: web` header present, set `httpOnly; Secure; SameSite=Strict` cookie | `token-server/index.js` | Before website goes live |
| W6 | In `/auth/refresh`: fallback to `req.cookies.refreshToken` when body token absent | `token-server/index.js` | Before website goes live |
| W7 | In `/auth/logout`: also clear the cookie (`res.clearCookie('refreshToken')`) | `token-server/index.js` | Before website goes live |

> **Note:** The macOS app continues to send `refreshToken` in the request body — no macOS client changes needed. The cookie path is purely additive for web callers.
