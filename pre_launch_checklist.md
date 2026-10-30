# Inter — Pre-Launch & Production Readiness Checklist

> **Created:** 14 April 2026  
> **Purpose:** Single source of truth for everything remaining before (and shortly after) public launch.  
> Consolidated from: `auth_status.md`, `oauth_status.md`, `auth_implementation.md` (§10.6),  
> `tasks.txt`, `implementation_plan.md`, `work_done.md`, `future_developments.md`, `new_feature.md`.
>
> **Legend:** 🔴 Blocking — cannot ship without this · 🟠 Pre-launch — do before first user · 🟡 Soon-after — within first week of launch · 🟢 Post-v1 — planned for later releases

---

## 1. OAuth Credentials (Blocking — App unusable without these)

Both OAuth providers are fully implemented in code. The only remaining step is registering
the apps with each provider, generating credentials, and uncommenting them in `.env`.

### 1.1 Google OAuth — `GOOGLE_CLIENT_ID` + `GOOGLE_CLIENT_SECRET`

🔴 **Status:** Not configured. All four Google env vars are commented out in `.env`.

**What to do:**
1. Go to [console.cloud.google.com](https://console.cloud.google.com)
2. Create a project (or use an existing one)
3. Enable **Google People API** and **OAuth 2.0**
4. Go to **APIs & Services → Credentials → Create Credentials → OAuth 2.0 Client ID**
5. Application type: **Web application** (not "iOS" — the flow is server-side)
6. Add authorized redirect URI: `http://localhost:3000/auth/oauth/google/callback` (dev) and `https://api.inter.com/auth/oauth/google/callback` (prod)
7. Copy **Client ID** and **Client Secret**
8. In `token-server/.env`, uncomment and fill in:
   ```
   GOOGLE_CLIENT_ID=<your_client_id>.apps.googleusercontent.com
   GOOGLE_CLIENT_SECRET=GOCSPX-<your_secret>
   ```
9. On the OAuth consent screen, add test users and set scopes: `openid`, `email`, `profile`

---

### 1.2 Microsoft OAuth — `MICROSOFT_CLIENT_ID` + `MICROSOFT_CLIENT_SECRET`

🔴 **Status:** Not configured. All Microsoft env vars are commented out in `.env`.

**What to do:**
1. Go to [portal.azure.com](https://portal.azure.com) → **Azure Active Directory → App registrations → New registration**
2. Name: "Inter" (or your final app name)
3. Supported account types: **Accounts in any organizational directory and personal Microsoft accounts** (multi-tenant, `common`)
4. Redirect URI: Web → `http://localhost:3000/auth/oauth/microsoft/callback`
5. After creation, go to **Certificates & secrets → New client secret** → copy the secret value immediately (only visible once)
6. Note the **Application (client) ID** from the Overview page
7. Add the production redirect URI when deploying: `https://api.inter.com/auth/oauth/microsoft/callback`
8. In `token-server/.env`, uncomment and fill in:
   ```
   MICROSOFT_CLIENT_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   MICROSOFT_CLIENT_SECRET=<your_secret_value>
   MICROSOFT_TENANT_ID=common
   ```

---

### 1.3 OAuth Full Testing Checklist (F.18)

🔴 **Status:** Not started. Required before shipping OAuth sign-in to users.

**Run each test scenario against the running server:**

| # | Scenario | Expected Result |
|---|----------|-----------------|
| 1 | Google → first-time sign-in (new email) | New user created, tokens returned, app lands on main screen |
| 2 | Google → sign-in with email that already has a password account | Account auto-linked, existing user returned, security alert email sent |
| 3 | Microsoft → first-time sign-in (new email) | New user created, tokens returned |
| 4 | Microsoft → sign-in with existing Inter account | Account auto-linked |
| 5 | User cancels OAuth consent screen | App shows "Sign-in was cancelled" — no crash |
| 6 | Handoff code used twice | Second exchange returns 401 `INVALID_OR_EXPIRED_CODE` |
| 7 | Handoff code used after 30s | 401 `INVALID_OR_EXPIRED_CODE` |
| 8 | State parameter tampered | Server returns 400 "State signature invalid" |
| 9 | Deleted account attempts OAuth | Redirect with `error=account_deleted` |
| 10 | `email_verified = false` (Google) | Rejected with `email_not_verified` — no account created |
| 11 | PKCE: code_verifier mismatch | Provider token exchange fails |
| 12 | Nonce mismatch | `nonce_mismatch` error — no account created |
| 13 | Token age > 5 minutes | `id_token_too_old` error |
| 14 | Login page OAuth button → app deep link flow | `com-inter-app://oauth-callback?code=…` fires, app exchanges and authenticates |

---

## 2. SMTP Email — Transactional Email Not Configured

🔴 **Status:** `SMTP_HOST` and related vars are not set in `.env`. All 4 email types (password reset, email verification, security alerts, payment failed) will silently fail until this is configured.

**Recommended provider:** [Resend](https://resend.com) — free tier (100 emails/day), 1-minute setup.

**What to do:**
1. Sign up at Resend (or SendGrid / Postmark — all work with the existing `mailer.js` nodemailer transport)
2. Verify your sending domain (add DNS TXT + CNAME records — takes ~5 minutes)
3. Generate an API key
4. In `token-server/.env`, fill in:
   ```
   SMTP_HOST=smtp.resend.com
   SMTP_PORT=465
   SMTP_USER=resend
   SMTP_PASS=<your_resend_api_key>
   SMTP_FROM=Inter <noreply@yourdomain.com>
   ```
5. Restart the token server — `mailer.js` calls `transporter.verify()` on startup and will log success or a specific error
6. Test by triggering `POST /auth/forgot-password` with a registered email and confirming receipt

---

## 3. Account Management UI — ✅ DONE

✅ **Status (updated):** Account Management UI is now implemented in the macOS app. All five
backend endpoints are wired to client screens (Change Password, Change Email, Active Sessions,
Delete Account, plus profile). The subsections below are retained as the original spec / a
verification reference — confirm each flow once against production before launch.

**Implemented approach:** An "Account Settings" surface (Profile / Security / Danger Zone)
backed by the endpoints listed below.

**Pre-launch verification (light):** smoke-test change-password (other sessions revoked,
current stays alive), change-email verification deep link, session list + revoke, and delete
account (Keychain cleared, returns to login). These are checks, not build work.

### 3.1 Change Password Screen

- **Endpoint:** `POST /auth/change-password` (body: `{ currentPassword, newPassword }`)
- **UI needed:** Modal or settings panel with:
  - "Current password" `NSSecureTextField`
  - "New password" `NSSecureTextField` (8–72 bytes enforced client-side too)
  - "Confirm new password" `NSSecureTextField`
  - Submit button → calls `loginWithEmail:…` flow or a dedicated `changePassword:newPassword:completion:` method on `InterTokenService`
  - On success: show "Password changed. All other sessions revoked." and dismiss
  - On 401: "Current password is incorrect"
- **Note:** On success the server revokes all other sessions but keeps the current one alive — the user stays logged in.

### 3.2 Change Email Screen

- **Endpoint:** `POST /auth/change-email` (body: `{ password, newEmail }`) → sends verification to new address
- **Confirmation:** `GET /auth/verify-email-change?token=…` — deep link, already registered in `AppDelegate.m`
- **UI needed:**
  - "Current password" `NSSecureTextField`
  - "New email address" `NSTextField`
  - Submit button → shows "Verification email sent to [new email]. Click the link to confirm."
  - Handle the `com-inter-app://verify-email-change?token=…` deep link in `AppDelegate.m` (the endpoint exists; the deep link handler does not). Add to `allowedPaths` and call `GET /auth/verify-email-change` from the app.

### 3.3 Active Sessions List

- **Endpoints:** `GET /auth/sessions` (list) · `DELETE /auth/sessions/:id` (revoke one)
- **UI needed:** A table view showing each session with columns:
  - Device/client ID (e.g. show last 8 chars of `clientId`)
  - Created (formatted date)
  - Last used (formatted date, or "Current session" if `isCurrent = true`)
  - "Revoke" button (disabled for current session)
- **Implementation note:** `InterTokenService` has no method for sessions yet — add `listSessions(completion:)` and `revokeSession(_:completion:)` methods using `performAuthenticatedRequest`.

### 3.4 Delete Account (Danger Zone)

- **Endpoint:** `DELETE /auth/account` (body: `{ password }`)
- **UI needed:**
  - Clearly separated "Danger Zone" section (red border or section header)
  - "Delete Account" button → shows confirmation alert: "This will permanently delete your account and cancel any active subscription. This cannot be undone."
  - Alert has a `NSSecureTextField` for password confirmation
  - On success: clear Keychain tokens, dismiss all windows, show the login panel
  - On 502 `SUBSCRIPTION_CANCEL_FAILED`: show "Failed to cancel your subscription. Please cancel it manually at [portal URL] then try again."

---

## 4. Recording — UI Wiring Incomplete

🟠 **Status:** Recording engine, cloud recording, and all tiers are fully implemented. Two wiring items remain.

### 4.1 RecordingListPanel — Wire into Call UI (R2)

- **What:** `InterRecordingListPanel` lets users view and access past cloud recordings during a call. It is built but not wired to a button in the call controls.
- **Files:** `inter/App/AppDelegate.m`, `inter/UI/Views/InterLocalCallControlPanel.h/.m`
- **What to do:**
  1. Add a "Recordings" button to `InterLocalCallControlPanel` (Pro/Hiring tier only — hide for free)
  2. In `AppDelegate.m`, handle the button action: call `requestPortalURL` or directly fetch `/recordings` and present `InterRecordingListPanel`
  3. Gate the button behind `[self.roomController.tokenService.effectiveTier isEqualToString:@"pro"]` or `hiring`

### 4.2 RecordingConsentPanel — Show on Participant Join (R3)

- **What:** When recording is active and a new participant joins, they must see a consent screen before their video/audio is captured. The panel is built; the trigger is not wired.
- **Files:** `inter/App/AppDelegate.m` (participant-join handler)
- **What to do:**
  1. In `roomController:didAddParticipant:` (or the equivalent RoomDelegate callback in `AppDelegate.m`), check if recording is active (`InterCallSessionCoordinator.isRecording` or similar flag)
  2. If active, present `InterRecordingConsentPanel` modally over the secure/normal window as appropriate
  3. Hold the participant in a "pending consent" state until they confirm (or disconnect them if they decline)

---

## 5. Production Infrastructure

🟠 **Status:** All services run locally. None are deployed to production.

### 5.1 Choose and Configure Hosting for Token Server

**Recommended:** Railway or Render (both have built-in PostgreSQL + Redis addons, free starter tier, automatic deploys from git).

**What to do:**
1. Create a new project on Railway / Render
2. Connect the `token-server/` directory as the root
3. Add PostgreSQL addon — copy the connection string to `DATABASE_URL` env var
4. Add Redis addon — copy the connection string to `REDIS_URL` env var
5. Set all env vars from `token-server/.env` in the hosting platform's environment panel:
   ```
   JWT_SECRET                    (32+ random bytes — generate fresh for prod)
   REFRESH_TOKEN_SECRET          (32+ random bytes — generate fresh for prod)
   OAUTH_STATE_SECRET            (32+ random bytes — generate fresh for prod)
   LEMONSQUEEZY_API_KEY
   LEMONSQUEEZY_WEBHOOK_SECRET
   LEMONSQUEEZY_STORE_ID
   GOOGLE_CLIENT_ID
   GOOGLE_CLIENT_SECRET
   MICROSOFT_CLIENT_ID
   MICROSOFT_CLIENT_SECRET
   MICROSOFT_TENANT_ID=common
   SMTP_HOST / SMTP_PORT / SMTP_USER / SMTP_PASS / SMTP_FROM
   SERVER_BASE_URL=https://api.inter.com
   BILLING_PAGE_BASE_URL=https://api.inter.com
   APP_RETURN_URL=https://api.inter.com/billing/success
   LIVEKIT_API_KEY
   LIVEKIT_API_SECRET
   LIVEKIT_SERVER_URL            (your deployed LiveKit server WS URL)
   LIVEKIT_HTTP_URL
   ```
6. Run all migrations: `node migrate.js` (or execute `.sql` files in order 001→014 against the production DB)

### 5.2 Configure a Domain

**Recommended structure:**
```
api.inter.com  →  token-server (Railway / Render)
inter.com      →  landing page / download page (start simple — one HTML file is fine)
```

**What to do:**
1. Buy `inter.com` (or your final brand domain) — Cloudflare Registrar recommended (cheap + fast DNS)
2. Add CNAME/A record: `api.inter.com` → your Railway / Render URL
3. Enable HTTPS — Railway/Render provision Let's Encrypt certs automatically
4. Update `SERVER_BASE_URL` and `BILLING_PAGE_BASE_URL` env vars to `https://api.inter.com`

### 5.3 Deploy LiveKit Server

The current setup uses `localhost:7880`. In production you need a LiveKit server with a public IP.

**Options (cheapest → most scalable):**
- **LiveKit Cloud** — managed, pay-per-minute, zero ops. Fastest path to production. [livekit.io/cloud](https://livekit.io/cloud)
- **Self-hosted on a VPS** — `livekit-server` binary on a $10/month DigitalOcean / Hetzner VM. Requires port 7880 (TCP+UDP) and 443 open. TURN server may be needed for restrictive networks.

**What to do:**
1. Choose hosting option
2. Generate production API key/secret (different from dev `devkey`/`secret`)
3. Update `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, `LIVEKIT_SERVER_URL`, `LIVEKIT_HTTP_URL` in production env

### 5.4 Run All Database Migrations

The migration files must be applied in order against the production database before the server starts receiving traffic.

```
001_users.sql
002_...   (if exists)
003_...
004_refresh_tokens.sql
006_billing_columns.sql
009_password_reset_tokens.sql
010_email_verification.sql
011_audit_events.sql
012_session_hardening.sql
013_email_change_tokens.sql
014_oauth_social.sql
```

If a `migrate.js` runner exists in `token-server/`, use `node migrate.js`. Otherwise run each file manually:
```
psql $DATABASE_URL -f migrations/001_users.sql
# ... repeat for all
```

### 5.5 TLS Certificate Pinning — Update Production Pin

`InterTokenService.swift` implements SPKI SHA-256 pinning. In dev mode (no `AUTH_SERVER_PINS` env var configured), pinning is bypassed. In production:

1. Get the SHA-256 SPKI fingerprint of your production certificate:
   ```bash
   openssl s_client -connect api.inter.com:443 2>/dev/null | \
     openssl x509 -pubkey -noout | \
     openssl pkey -pubin -outform der | \
     openssl dgst -sha256 -binary | base64
   ```
2. Add `AUTH_SERVER_PINS=<base64_pin1>,<base64_pin2>` to the production `.env`
3. Ship the app with this pin hardcoded OR loaded from a CDN-hosted pinset with a fallback

**Critical:** Include at least two pins (primary + backup), and have a plan to ship an app update before the cert expires (typically 90 days for Let's Encrypt).

### 5.6 Update Lemon Squeezy Dashboard for Production

After deploying the token server to `api.inter.com`:
1. **Webhook URL** → `https://api.inter.com/webhooks/lemonsqueezy`
2. **Redirect URL after checkout** → `https://api.inter.com/billing/success`
3. Whitelist `https://api.inter.com/billing/success` in LS store settings → Checkout → Redirect URLs
4. Webhook signing secret (`LEMONSQUEEZY_WEBHOOK_SECRET`) must match exactly what is set on the LS dashboard → Settings → Webhooks

### 5.7 Update OAuth Redirect URIs for Production

When the server is on `api.inter.com`:

**Google Cloud Console:**
- Add authorized redirect URI: `https://api.inter.com/auth/oauth/google/callback`

**Azure Portal → App registrations → Authentication:**
- Add redirect URI: `https://api.inter.com/auth/oauth/microsoft/callback`

---

## 6. Apple Universal Links — Replace Custom URL Scheme

🟠 **Status:** The app uses `com-inter-app://` (a custom URL scheme). This works but is not as secure as Universal Links — any app can register the same custom scheme. Universal Links are tied to cryptographic domain ownership.

**What to do:**
1. Create `apple-app-site-association` (AASA) JSON file and host it at `https://api.inter.com/.well-known/apple-app-site-association`:
   ```json
   {
     "applinks": {
       "apps": [],
       "details": [{
         "appID": "<TEAM_ID>.com.inter.app",
         "paths": [
           "/billing/success",
           "/auth/verify-email-change*",
           "/auth/oauth/*/callback*",
           "/reset-password*"
         ]
       }]
     }
   }
   ```
2. The AASA file must be served with `Content-Type: application/json` and **no redirect**
3. Add the Associated Domains entitlement to `inter.entitlements`:
   ```xml
   <key>com.apple.developer.associated-domains</key>
   <array>
     <string>applinks:api.inter.com</string>
   </array>
   ```
4. In `AppDelegate.m`, update `application:continueUserActivity:restorationHandler:` to handle `NSUserActivityTypeBrowsingWeb` (Universal Links) alongside the existing `application:openURLs:` handler for the custom scheme
5. Update all server-side redirects to use `https://api.inter.com/billing/success` etc. instead of `com-inter-app://billing/success` where the AASA paths cover them
6. Keep the custom scheme as a fallback for older OS versions or until Universal Links are confirmed working

### 6.1 Password-Reset Deep-Link Phishing (R5-F1) — security context for this migration

🟠 **Status:** Not addressed. This is the concrete reason §6 matters for auth, plus one fix that §6 does **not** cover on its own.

**The risk.** The reset deep link (`com-inter-app://reset-password?token=…`) drops the user straight into a native `NSAlert` + `NSSecureTextField` password prompt (`handlePasswordResetDeepLinkWithToken:` in `inter/App/AppDelegate.m`). That prompt shows **no account identity and no origin**. Because *any* app can register the same custom scheme, a malicious local app can fire the link with an **attacker-controlled token**; the victim types a new password, which resets the **attacker's** account — leaking a reused password into an account the attacker controls.

**What "bound via `apple-app-site-association`" actually buys us.** A Universal Link is only routed into our app if a file served over TLS from our own domain (`https://api.inter.com/.well-known/apple-app-site-association`) explicitly names our signed app (`<TEAM_ID>.com.inter.app`). The "binding" = **domain ownership + TLS cert + our specific Team ID/bundle ID**, instead of a freely-claimable string. An attacker can't host that file on our domain and can't forge our Team ID, so they **can't silently claim** the link. If the app isn't installed, the link just opens in the browser (safe default). This removes the "any app can grab the scheme" enabler of R5-F1.

**Caveat — step 6 above keeps the custom scheme as a fallback.** While `com-inter-app://reset-password` still routes into the app, the freely-claimable surface remains in parallel. To actually close R5-F1, once Universal Links are confirmed working: **stop routing password reset through the custom scheme** — drop the `reset-password` host from the allowlist in `application:openURLs:` (keep billing/oauth on the scheme if still needed), so reset only arrives via the domain-bound Universal Link.

**The decisive fix (NOT covered by §6, add it too) — show the account identity at the password prompt.** This is what Google/Microsoft do, and it neutralises the phishing variant even before the scheme is retired: before the password field, display *"Reset password for `a••@example.com`"* so the user can tell whose account they're about to change.
- **Safe — no enumeration oracle.** Resolving the email requires a valid, unexpired, single-use token that only the real account owner ever receives (by email). An attacker can therefore only resolve the masked email for accounts they **already control**, so revealing it at redemption leaks nothing.
- **Server:** add an endpoint that takes the token and returns only a masked email, validating the token exactly like redemption (unexpired, unused) but **without consuming it** — e.g. `POST /auth/reset-password/identity` → `{ "maskedEmail": "a••@e•••.com" }`; return a generic failure for an invalid/expired token.
- **Client:** in `handlePasswordResetDeepLinkWithToken:`, after resolving the issuing server, call that endpoint and prepend the masked email to the alert (header line or `informativeText`). If the lookup fails, abort **before** prompting for a password.

---

## 7. App Store / Distribution Prep

🟠 **Status:** Not started. Required if distributing via Mac App Store or Setapp.

### 7.1 App Icon

- Required sizes: 16, 32, 64, 128, 256, 512, 1024 px (all in `AppIcon.appiconset`)
- Export from your design tool and drag into Xcode's asset catalog
- The AppIcon entry in `Assets.xcassets` currently references missing images — this is a build warning, not an error, but App Store submission will reject a missing icon

### 7.2 Info.plist — Add Required Keys

Review and fill in before submission:
```
CFBundleName            → your public app name
CFBundleDisplayName     → your public app name
CFBundleShortVersionString → e.g. "1.0.0"
CFBundleVersion         → e.g. "1" (increments each build)
NSHumanReadableCopyright → © 2026 Your Company Name
NSCameraUsageDescription → "Inter uses your camera for video calls."
NSMicrophoneUsageDescription → "Inter uses your microphone for audio in calls."
NSScreenCaptureUsageDescription → "Inter uses screen capture for screen sharing in interviews."
```

### 7.3 Sandbox Entitlements

Verify `inter.entitlements` covers all needed entitlements:
- `com.apple.security.network.client` ✅ (already set)
- `com.apple.security.device.camera` — needed for sandbox camera access
- `com.apple.security.device.microphone` — needed for sandbox mic access
- `com.apple.security.files.user-selected.read-write` — if file system access is needed (export, recording save)
- `com.apple.security.keychain-access-groups` — needed if sharing Keychain across app + extensions

### 7.4 Notarization

For distribution outside the App Store (direct download), the app must be notarized by Apple:
```bash
xcrun notarytool submit inter.zip \
  --apple-id <your@apple.id> \
  --team-id <TEAM_ID> \
  --password <app-specific-password> \
  --wait
xcrun stapler staple inter.app
```

---

## 8. Security — MFA (Phase E) + TLS Pinning

🟡 **Status:** G7 (MFA) was explicitly deferred to Phase E. TLS certificate pinning (§8.1) is
code-complete but needs production SPKI hashes. All other 23 security gaps are resolved.

### 8.1 TLS Certificate Pinning — Populate Production SPKI Hashes

🟠 **Status:** Pinning logic is fully implemented but **inactive** — the pin set is an empty
placeholder, so the client currently falls back to default system trust. **Do this once the
production API certificate exists** (no keys yet at time of writing).

**Why it's safe to ship dev like this:** With `pinnedSPKIHashes` empty, `InterPinnedSessionDelegate`
calls `performDefaultHandling` (standard CA validation) — fine for `http://localhost` dev, but it
means MITM protection via pinning is **off** until populated. Do not consider pinning "done" until
the hashes are filled in AND every session routes through the pinned delegate.

**What to do (when the prod cert is issued):**
1. Generate the SPKI SHA-256 pin from the live endpoint:
   ```sh
   openssl s_client -connect api.inter.com:443 </dev/null 2>/dev/null \
     | openssl x509 -noout -pubkey \
     | openssl pkey -pubin -outform DER \
     | openssl dgst -sha256 -binary | base64
   ```
2. Generate a **backup pin** from a pre-issued (not-yet-deployed) key pair so an emergency cert
   rotation can't lock users out.
3. Paste both into `pinnedSPKIHashes` in `InterPinnedSessionDelegate` (`inter/Networking/InterTokenService.swift`, ~L3550):
   ```swift
   private let pinnedSPKIHashes: Set<String> = [
       "<primary-base64-sha256>", // api.inter.com primary (expires YYYY-MM)
       "<backup-base64-sha256>",  // api.inter.com backup (pre-generated)
   ]
   ```
4. **Route all server calls through the pinned session.** Today only `authSession` uses the pinned
   delegate. These still use unpinned sessions and must be migrated (or given their own pinned
   delegate) before pinning is meaningful:
   - `InterTokenService` plain `session` (`InterTokenService.swift` ~L870)
   - `InterModerationController` (`InterModerationController.swift` ~L268)
   - `InterRecordingCoordinator` (`InterRecordingCoordinator.swift` ~L1617 and ~L1684)
   - `InterRecordingListPanel` `NSURLSession.sharedSession` (`InterRecordingListPanel.m` ~L304)
5. **Rotation policy:** add the new pin to the set and ship the app **before** deploying the new
   cert; remove the old pin only after the rollover window (24–72 h). Never ship an empty set to prod.
6. **Verify:** with pins populated, point the app at a proxy with a different cert (e.g. Charles/mitmproxy)
   and confirm the connection is **rejected** (`SPKI hash mismatch` in logs), then confirm the real
   endpoint connects normally.

---

### 8.2 MFA (Phase E)

The database schema additions are already designed (from `auth_implementation.md` §10.3 G7):

```sql
ALTER TABLE users
  ADD COLUMN totp_secret_enc   TEXT,
  ADD COLUMN totp_enabled_at   TIMESTAMPTZ,
  ADD COLUMN totp_backup_codes JSONB;
```

**Endpoints to build (Phase E):**
| Endpoint | Purpose |
|----------|---------|
| `POST /auth/mfa/setup` | Generate TOTP secret, return QR code URI |
| `POST /auth/mfa/verify-setup` | Confirm with first TOTP code, enable MFA |
| `POST /auth/mfa/challenge` | Submit TOTP code during login (second factor) |
| `POST /auth/mfa/disable` | Disable MFA (requires password + current TOTP) |
| `GET /auth/mfa/backup-codes` | Download one-time backup codes |

**Login flow change for MFA:** `POST /auth/login` returns `{ mfaRequired: true, mfaToken: <short-lived JWT> }` for MFA-enabled users. Client then calls `POST /auth/mfa/challenge` with TOTP code + mfaToken to get the actual token pair.

**Recommended TOTP library:** `otplib` (Node.js server) + standard QR code display in a macOS sheet via `CIFilter.qrCodeGenerator`.

---

## 9. Pre-Website Launch — When `inter.com` Goes Live

🟡 **Status:** Not needed yet. Required before any browser-based web caller hits `api.inter.com`.

These are additive — no macOS app changes needed.

| # | Change | File | Detail |
|---|--------|------|--------|
| W1 | `npm install cors cookie-parser` | `package.json` | New dependencies |
| W2 | `CORS_ORIGINS=https://inter.com,https://www.inter.com` | `.env` | Never use `*` — we send credentials |
| W3 | Mount `cors({ origin: allowedOrigins, credentials: true })` before all routes | `index.js` | Apply BEFORE static + routes |
| W4 | Mount `cookieParser()` middleware | `index.js` | Needed to read refresh token cookie |
| W5 | `login` + `register`: detect `X-Client: web` header → set `httpOnly; Secure; SameSite=Strict` cookie | `index.js` | Cookie is IN ADDITION to body — macOS app continues using body |
| W6 | `POST /auth/refresh`: fallback to `req.cookies.refreshToken` when body token absent | `index.js` | `const token = req.body.refreshToken ?? req.cookies?.refreshToken` |
| W7 | `POST /auth/logout`: also `res.clearCookie('refreshToken')` | `index.js` | Ensures cookie is cleared for web callers |

---

## 10. Free Tier Enforcement — Meeting Duration Cap

🟡 **Status:** The feature matrix specifies a 90-minute meeting limit for Free tier users. This is not currently enforced.

**Where to implement:**
- **Server-side (authoritative):** In `POST /room/create`, read the host's tier from DB. Store the room start time in Redis (`room:{CODE}:startedAt`). In `POST /token/refresh` (room token, not auth token), check `NOW() - startedAt > 90 min` for free tier and return 403 with `MEETING_DURATION_EXCEEDED`.
- **Client-side (UX):** At T-5 minutes for free users, show a "Your meeting ends in 5 minutes. Upgrade to Pro for unlimited meetings." banner in `InterLocalCallControlPanel`.

**Files:** `token-server/index.js` (create + token refresh endpoints), `inter/UI/Views/InterLocalCallControlPanel.m` (banner)

---

## 11. Branding — Final App Name

🟡 **Status:** Internal codename is "inter". Nothing in the codebase changes for a rebrand — only public-facing layer changes.

**When brand name is decided, change only:**
| Item | Where |
|------|-------|
| App display name | `Info.plist` → `CFBundleDisplayName` |
| App icon | `Assets.xcassets/AppIcon.appiconset` |
| Website domain | Buy domain, update `SERVER_BASE_URL`, `BILLING_PAGE_BASE_URL`, `APP_RETURN_URL` |
| LS dashboard webhook URL | `https://api.<newdomain>.com/webhooks/lemonsqueezy` |
| LS checkout redirect URL | `https://api.<newdomain>.com/billing/success` |
| OAuth redirect URIs | Update in Google Cloud Console and Azure Portal |
| AASA file host | `https://api.<newdomain>.com/.well-known/apple-app-site-association` |
| Marketing copy / App Store listing | Separate from codebase |

No Swift, Objective-C, SQL, or server logic changes needed — all internal identifiers (`com.inter.app`, `InterTokenService`, `inter_dev`, `com-inter-app://`) stay as-is.

---

## 12. Post-v1 Feature Phases

These are confirmed future work, not required for launch. Ordered by dependency.

### Phase E — MFA (see §8 above for full detail)
- TOTP-based two-factor authentication
- Backup codes
- Login flow: login → MFA challenge → token pair

### Phase 11 — Scheduling & Productivity
- **11.1 Calendar View** — macOS `EventKit` integration (read-only local calendar)
- **11.2 Calendar Scheduling (Pro)** — Schedule and manage meetings (Apple Calendar, Google, Outlook OAuth)
- **11.3 Scheduling Links (Pro)** — Calendly-style public booking page with availability engine
- **11.4 Team Management** — CRUD for teams/orgs in PostgreSQL, invite flows (`hiring` tier)

### Phase 12 — Hiring-Specific Features
- **12.1 Structured Interviews** — Scorecard UI, question templates, timer, per-answer rating
- **12.2 Live Coding & Whiteboard** — Collaborative code editor (embed Monaco or custom) + canvas
- **12.3 ATS Integration** — Greenhouse, Lever REST APIs — candidate sync, interview scheduling webhooks
- **12.4 Candidate Dashboard** — Web-based portal for candidates (separate web frontend deployment)

### Phase 13 — AI & Enhancement
- **13.1 Auto-Transcription** — Whisper API / Deepgram via LiveKit audio track forwarding; required by AI Co-Pilot
- **13.2 AI Co-Pilot (Hiring)** — Post-meeting summaries, key moments, hiring recommendation — depends on 13.1
- **13.3 Automated Camera Framing** — Core ML / Vision framework face detection + crop (all tiers)
- **13.4 Low-Light Correction** — Core Image `CIFilter` chain or Metal compute shader (all tiers)

### Phase 14 — Multi-Interviewer Mode (deferred per `future_developments.md`)
Currently, the interview host is always the interviewer and the joiner is always the interviewee. This phase adds:
- Host can promote participant to co-interviewer role
- Interviewer can remotely switch interviewee between secure and normal mode during a live session
- Server-authoritative live session state (cannot be done via JWT metadata alone — requires Redis-backed session authority)
- Requires new Redis keys: `room:{CODE}:permissions:{identity}`, event-sourced role mutations
- See `future_developments.md` for full architecture rationale

---

## Quick Reference — What Blocks Shipping

| # | Item | Effort | Blocks |
|---|------|--------|--------|
| 1 | Register Google OAuth app + set `.env` | 15 min | OAuth sign-in |
| 2 | Register Microsoft OAuth app + set `.env` | 15 min | OAuth sign-in |
| 3 | Run OAuth test checklist (F.18) | 1–2 hours | OAuth confidence |
| 4 | Configure SMTP provider + test emails | 30 min | Password reset, verification, alerts |
| 5 | Deploy token server to production host | 1–2 hours | Any real users |
| 6 | Run all 14 DB migrations on production DB | 30 min | Server startup |
| 7 | Deploy LiveKit server (or sign up for LiveKit Cloud) | 1–3 hours | Video calls |
| 8 | Update LS dashboard URLs (webhook, redirect) | 5 min | Billing webhooks |
| 9 | Update OAuth redirect URIs to production URLs | 10 min | OAuth in prod |
| 10 | Build Account Management UI (§3) | 3–5 days | User self-service |
| 11 | Wire RecordingListPanel into call UI (R2) | 4 hours | In-call recording access |
| 12 | Wire RecordingConsentPanel on participant join (R3) | 2 hours | Recording compliance |
| 13 | App icon + Info.plist usage strings | 1 hour | App Store submission |
| 14 | App notarization setup | 1 hour | Direct download distribution |


---

## 13. Interview Anti-Cheat / Capture-Protection Controls (macOS) — Status & Roadmap

> Added 21 June 2026. This section maps the cross-platform anti-cheat control matrix
> (authored against the Windows API set) to the **macOS** implementation and tracks status.
> The public website will NOT disclose per-platform mechanisms — this is engineering truth.
>
> **Legend:** ✅ Implemented · 🟠 In progress / next · 🟢 Planned · ⚪ Out of scope (software)

### 13.0 Correction — screen-capture exclusion DOES work in production

🟢→✅ **Clarification (owner-confirmed, 21 June 2026):** The secure-window screen-capture
exclusion (`setSharingType:NSWindowSharingNone`, the macOS analog of Windows
`SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`) **is effective in production.** It was only
**disabled in the dev environment** to make the secure UI visible while building/testing it.
Earlier research notes that hedged on this should be read in that light: against third-party
capture/streaming/screenshot tools (OBS, Zoom, Meet, Bandicam, screenshot utilities) the
exclusion works. (macOS's own privileged recorder remains the documented, accepted residual.)
- **Action before launch:** confirm the production build ships with the exclusion ENABLED
  (i.e. the dev-only disable flag is off in Release config) and add a release-gate check.

### 13.1 macOS control matrix (mapped from the Windows matrix)

| # | Cheating vector | Windows mechanism (reference) | macOS mechanism | Status |
|---|---|---|---|---|
| 1 | Software screen capture | `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` | `setSharingType:NSWindowSharingNone` on every secure/call window | ✅ Implemented (prod-on; dev-off) |
| 1b | **Native OS screen recorder** (Cmd-Shift-5 / `screencapture`) — the one path window-exclusion can't block | (n/a — Windows analog via PrintScreen/snipping handling) | **Native screen-capture shortcut blocked for the duration of the session** (+ kiosk lockdown limits other launch routes) | ✅ **Implemented (in production)** |
| 2 | AI overlay window (Interview Coder, Cluely) | `HWND_TOPMOST` + foreground loop | `NSScreenSaverWindowLevel` elevated level + kiosk presentation lockdown + borderless/non-movable | ✅ Implemented (conditions neutralized; not absolute) |
| 3 | App-switching / nav shortcuts (⌘-Tab, etc.) | Low-level keyboard hook | `[NSApp setPresentationOptions:]` — DisableProcessSwitching, HideDock, HideMenuBar, DisableForceQuit, DisableSessionTermination | ✅ Implemented (presentation options; no per-key NSEvent hook) |
| 4 | **Audio loopback / app-audio capture (ParakeetAI, Cluely audio)** | WASAPI session monitor (`IAudioSessionManager2`) | **Core Audio monitor: enumerate devices + detect process taps / virtual + aggregate devices consuming our output during session** | 🟠 **In progress / next** |
| 5 | Renamed capture process | DXGI handle scanner (TypeIndex) | Largely **pre-empted by #1** (capture is excluded regardless of process name). Optional: ScreenCaptureKit-stream / screen-recording-TCC awareness, known-binary scan | 🟢 Planned (lower priority — #1 covers the payload) |
| 6 | Capture DLL in renamed process | Module enumeration | Not directly applicable on macOS; dylib-injection hardening + #1 exclusion | 🟢 Planned / mitigated by #1 |
| 7 | Second monitor connected after preflight | `EnumDisplayMonitors` polling | Continuous `NSScreen` monitoring — single-display policy for interviewee, enforced at runtime (not one-time preflight) | ✅ Implemented |
| 8 | VM — hypervisor presence | `CPUID` ECX[31] | `sysctl kern.hv_vmm_present` (Apple-DTS-endorsed; true under VMware Fusion / QEMU / Apple Virtualization) + CPUID VMM bit | 🟠 **In progress / next** |
| 9 | VM — guest driver artifacts | `SetupDiGetClassDevs` | IOKit / `ioreg` scan for VM device nodes (VMware SVGA, Parallels, VirtualBox, QEMU) | 🟢 Planned (layer 2) |
| 10 | VM — ACPI/firmware fingerprint | `GetSystemFirmwareTable` | `ioreg` / `system_profiler` model & platform identifiers; reject VM model IDs | 🟢 Planned (layer 3) |
| 11 | Hardware capture card — known brands | USB/UVC descriptor scan | IOKit USB device enumeration, keyword match (Elgato, Magewell, AVerMedia, Hauppauge) | 🟢 Planned |
| 12 | Hardware HDMI capture card — generic/PCIe | None (below OS) | None (below OS) | ⚪ Out of scope — interviewer observation |
| 13 | Second physical device (phone camera) | None (analog hole) | None (analog hole) | ⚪ Out of scope — interviewer observation |

### 13.2 Next-up implementation notes

**Audio-capture monitoring (#4) — the ParakeetAI defense.**
- Threat: tools transcribe the **interviewer's voice coming out of our app** by tapping the
  app/system audio directly — they do **not** rely on the speaker→mic acoustic path, so muting
  speakers / using headphones does not stop them.
- macOS has **no per-app "exclude my audio from capture"** API (no audio analog of
  `NSWindowSharingNone`), so the approach is **detect + flag** (mirrors the Windows WASAPI
  loopback monitor):
  1. Enumerate Core Audio devices (`kAudioHardwarePropertyDevices`); flag known virtual /
     loopback drivers (BlackHole, Soundflower, Loopback, VB-Cable) and **Aggregate / Multi-Output**
     devices, especially if the active output device is one of them.
  2. Watch for **new aggregate/tap devices appearing mid-session** — Core Audio process taps
     (`AudioHardwareCreateProcessTap`, macOS 14.4+) surface as device objects; their appearance
     during an interview is a strong signal.
  3. Optional: scan running processes for known assistant binaries/bundle IDs.
- Output is an **alert to the interviewer panel for human review** (not an auto-block), exactly
  like the Windows matrix row — avoids false-positive lockouts from legit system audio services.

**VM detection (#8–#10) — three-layer, any-one-blocks.**
- Layer 1 (primary): `sysctl kern.hv_vmm_present == 1`. Cheap, ring-3, Apple-endorsed.
- Layer 2: IOKit/`ioreg` VM device artifacts. Layer 3: model/platform identifier rejection.
- Caveat (same as Windows): paravirt-hardened/researcher VMs can mask layer 1; layered checks
  raise the bar. Decide policy: block-on-detect vs. flag-to-interviewer (recommend block for
  interviewee secure mode, consistent with single-display enforcement).

### 13.3 Status rollup for launch
- ✅ Shipping now: capture exclusion (third-party tools), **native OS screen-recorder shortcut
  blocked during session**, overlay-condition lockdown (kiosk + window level),
  app-switch lockdown, runtime single-display policy.
- 🟠 Targeted next (pre- or fast-follow launch): audio-capture monitoring, VM hypervisor check.
- 🟢 Later layers: VM driver/firmware fingerprinting, capture-card detection, capture-process
  awareness.
- ⚪ Permanently out of software scope: hardware HDMI capture, phone-camera analog hole →
  covered by interviewer-observation policy + candidate agreement.
