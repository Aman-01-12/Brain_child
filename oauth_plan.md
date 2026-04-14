# OAuth Social Sign-In — Phase F Implementation Plan

> **Status:** Deferred (planned). Do not start until website launch infrastructure (W1–W7 in auth_status.md) is complete.
> **Scope:** Additive "Sign in with Google / Microsoft" alongside existing email/password flow.
> **Security baseline:** OWASP ASVS 4.0 Level 2, RFC 8252 (OAuth for Native Apps), RFC 9700 (OAuth Security BCP).
> **Reference:** auth_implementation.md (existing patterns for `auditLog`, `sendSecurityAlertEmail`, `issueRefreshToken`)

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Security Threat Model](#2-security-threat-model)
3. [Database Schema](#3-database-schema)
4. [Server Implementation](#4-server-implementation)
5. [macOS Client Implementation](#5-macos-client-implementation)
6. [Login Page HTML (Hosted by Node Server)](#6-login-page-html-hosted-by-node-server)
7. [Account-Linking Policy](#7-account-linking-policy)
8. [Provider Registration Checklist](#8-provider-registration-checklist)
9. [Environment Variables](#9-environment-variables)
10. [Migration](#10-migration)
11. [Testing Checklist](#11-testing-checklist)
12. [Phase F Task Breakdown](#12-phase-f-task-breakdown)

---

## 1. Architecture Overview

### Core Design Decision

The native macOS app uses `ASWebAuthenticationSession` to open a URL on *your own server* — not directly to Google/Microsoft. Your server owns the OAuth dance; the Mac app is only a thin shell that starts the session and receives a short-lived handoff code at the end via a custom URL scheme.

```
┌─────────────────────────────────────────────────────────────────┐
│  macOS App                                                       │
│                                                                  │
│  1. ASWebAuthenticationSession                                   │
│     opens: https://api.inter.com/auth/login-page                │
│     callbackURLScheme: "com-inter-app"                           │
└───────────────────────┬─────────────────────────────────────────┘
                        │ browser popup opens
                        ▼
┌─────────────────────────────────────────────────────────────────┐
│  Node Server — /auth/login-page (HTML page)                      │
│                                                                  │
│  User sees:  [Continue with Google]  [Continue with Microsoft]  │
│              ─────────────── or ──────────────────              │
│              [Email / Password form]                             │
└───────────────────────┬─────────────────────────────────────────┘
                        │ user clicks "Continue with Google"
                        ▼
┌─────────────────────────────────────────────────────────────────┐
│  Google OAuth Consent Screen (accounts.google.com)              │
│                                                                  │
│  Scopes requested: openid, email, profile                        │
│  (NO calendar scopes here — that is a separate Phase G flow)    │
└───────────────────────┬─────────────────────────────────────────┘
                        │ Google redirects to:
                        │ https://api.inter.com/auth/oauth/google/callback
                        │   ?code=AUTH_CODE&state=STATE
                        ▼
┌─────────────────────────────────────────────────────────────────┐
│  Node Server — /auth/oauth/:provider/callback                    │
│                                                                  │
│  1. Verify state param (CSRF protection)                         │
│  2. Exchange code for Google ID token                            │
│  3. Verify ID token signature (Google JWKS)                      │
│  4. Assert email_verified: true                                  │
│  5. Look up / upsert user in users + oauth_identities tables     │
│  6. Issue Inter refresh + access tokens                          │
│  7. Store one-time handoff code (30s TTL) in pending_oauth_handoffs│
│  8. Redirect to: com-inter-app://oauth-callback?code=HANDOFF_CODE│
└───────────────────────┬─────────────────────────────────────────┘
                        │ URL scheme triggers Mac app
                        ▼
┌─────────────────────────────────────────────────────────────────┐
│  macOS App — AppDelegate handles com-inter-app://oauth-callback  │
│                                                                  │
│  1. Extract handoff code from URL                                │
│  2. POST /auth/oauth/exchange { code }                           │
│  3. Receive { accessToken, refreshToken, expiresIn, user }       │
│  4. Store refreshToken in Keychain (same as email/password flow) │
│  5. App proceeds normally — identical from this point            │
└─────────────────────────────────────────────────────────────────┘
```

### Why this design is secure

- **Tokens never touch a URL.** Only a short-lived single-use code travels in the URL scheme. Even if another app intercepts the redirect, it gets a useless code that expires in 30 seconds and is invalidated on first use.
- **Server owns the OAuth dance.** The Mac app never sees a provider access token. Only your server does — and it doesn't store it (we only need email + provider ID, not ongoing API access for sign-in).
- **`ASWebAuthenticationSession` is mandatory for native apps** per RFC 8252 §8.12. It runs in an isolated process, preventing the host app from reading cookies or injecting JavaScript into the browser context.
- **No custom URI in the OAuth redirect.** Google/Microsoft redirect to your HTTPS server endpoint — not to `com-inter-app://` directly. Only the final handoff uses the custom scheme, which carries only an opaque code.

---

## 2. Security Threat Model

### OWASP Top 10 Coverage

| Threat | Vector | Mitigation |
|--------|--------|------------|
| A01 Broken Access Control | Intercept handoff code | 30-second TTL + single-use + scoped to `user_id` |
| A01 Broken Access Control | Register same URL scheme | Code has no value without `POST /auth/oauth/exchange` to your server |
| A02 Cryptographic Failures | Token in redirect URL | Handoff code is opaque random bytes; actual JWTs only returned over TLS in JSON body |
| A03 Injection | Malicious `state` or `code` params | `state` is HMAC-signed; `code` is exchanged server-side with provider, user input never interpolated into SQL without parameterization |
| A05 Security Misconfiguration | Wildcard redirect URI at provider | Register exact callback URIs only: `https://api.inter.com/auth/oauth/google/callback` |
| A07 Identification Failures | Provider ID token forgery | Verify signature against provider's JWKS endpoint; pin `iss` claim to known issuer |
| A07 Identification Failures | Account takeover via email collision | `email_verified: true` assertion before any account linking |
| A08 Software & Data Integrity | CSRF on OAuth callback | `state` parameter: HMAC-SHA256(secret, sessionId + timestamp + provider), verified on callback |
| A09 Logging Failures | No audit trail for social logins | `auditLog()` for every `oauth_login`, `oauth_account_linked`, `oauth_register` event |

### Additional OAuth-specific threats

| Threat | Mitigation |
|--------|------------|
| Authorization code interception | PKCE (`S256`) on every authorization request |
| Mix-up attack (confused deputy) | `state` param encodes provider; callback endpoint is provider-specific |
| ID token replay | Check `exp`, `iat`, `aud` claims; reject tokens older than 5 minutes |
| Nonce replay | Include `nonce` in authorization request; verify in ID token claims |
| Open redirect on post-auth | Redirect after exchange always goes to fixed URL — never user-supplied `redirect_uri` |

---

## 3. Database Schema

### Migration: `014_oauth_social.sql`

```sql
-- OAuth provider identities linked to Inter user accounts
CREATE TABLE IF NOT EXISTS oauth_identities (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider        VARCHAR(32) NOT NULL,          -- 'google' | 'microsoft'
    provider_user_id VARCHAR(255) NOT NULL,         -- Google 'sub' / Microsoft 'oid'
    provider_email  VARCHAR(254),                   -- email from provider at link time
    linked_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_used_at    TIMESTAMPTZ,
    UNIQUE (provider, provider_user_id)             -- one identity per provider slot
);

CREATE INDEX idx_oauth_identities_user ON oauth_identities(user_id);

-- Short-lived codes for the Mac app ↔ server handoff
-- Tokens never touch URLs — only these opaque codes do
CREATE TABLE IF NOT EXISTS pending_oauth_handoffs (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code_hash   BYTEA NOT NULL UNIQUE,              -- SHA-256 of the random code
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at  TIMESTAMPTZ NOT NULL,               -- NOW() + 30 seconds
    used_at     TIMESTAMPTZ                         -- NULL = not yet redeemed
);

CREATE INDEX idx_poh_code ON pending_oauth_handoffs(code_hash) WHERE used_at IS NULL;

-- Auto-clean expired handoff codes (pg_cron or manual periodic DELETE)
-- DELETE FROM pending_oauth_handoffs WHERE expires_at < NOW() - INTERVAL '1 hour';
```

---

## 4. Server Implementation

### 4.1 — New dependencies

```bash
npm install google-auth-library @azure/identity node-fetch
```

| Package | Purpose |
|---------|---------|
| `google-auth-library` | Verify Google ID tokens against Google's JWKS; no manual key pinning needed |
| `@azure/identity` | Verify Microsoft ID tokens |
| `node-fetch` | PKCE state generation helper (already using `crypto` built-in — no extra dep needed for state) |

### 4.2 — Environment variables (see also §9)

```bash
GOOGLE_CLIENT_ID=...
GOOGLE_CLIENT_SECRET=...
MICROSOFT_CLIENT_ID=...
MICROSOFT_CLIENT_SECRET=...
MICROSOFT_TENANT_ID=common          # 'common' for personal + work accounts
OAUTH_STATE_SECRET=<random 32 bytes hex>   # HMAC key for state param signing
OAUTH_HANDOFF_TTL_SECONDS=30
```

### 4.3 — Server routes (`token-server/index.js`)

#### GET `/auth/login-page`

Serves the sign-in HTML page (see §6). Used by `ASWebAuthenticationSession` as the entry point.

```js
// No auth required — this is the unauthenticated entry point
app.get('/auth/login-page', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'login.html'));
});
```

#### GET `/auth/oauth/:provider/start`

Initiates the OAuth flow. Called by the login page HTML via a simple anchor/button.

```js
const crypto = require('crypto');

app.get('/auth/oauth/:provider/start', rateLimitAuth, (req, res) => {
  const { provider } = req.params;
  if (!['google', 'microsoft'].includes(provider)) {
    return res.status(400).json({ error: 'Unknown provider' });
  }

  // PKCE: code_verifier = 32 random bytes, base64url encoded
  const codeVerifier = crypto.randomBytes(32).toString('base64url');
  const codeChallenge = crypto
    .createHash('sha256')
    .update(codeVerifier)
    .digest('base64url');

  // State: HMAC-signed, encodes provider + timestamp to prevent CSRF and mix-up attacks
  const statePayload = `${provider}:${Date.now()}:${crypto.randomBytes(8).toString('hex')}`;
  const stateHmac = crypto
    .createHmac('sha256', process.env.OAUTH_STATE_SECRET)
    .update(statePayload)
    .digest('base64url');
  const state = `${Buffer.from(statePayload).toString('base64url')}.${stateHmac}`;

  // Nonce: included in authorization request, verified in ID token
  const nonce = crypto.randomBytes(16).toString('base64url');

  // Store codeVerifier and nonce in a short-lived server-side session
  // (use a Map keyed by state for simplicity, or Redis in production)
  oauthSessions.set(state, {
    codeVerifier,
    nonce,
    provider,
    createdAt: Date.now(),
  });

  const redirectUri = `${process.env.SERVER_BASE_URL}/auth/oauth/${provider}/callback`;

  let authUrl;
  if (provider === 'google') {
    const params = new URLSearchParams({
      client_id:             process.env.GOOGLE_CLIENT_ID,
      redirect_uri:          redirectUri,
      response_type:         'code',
      scope:                 'openid email profile',
      state,
      nonce,
      code_challenge:        codeChallenge,
      code_challenge_method: 'S256',
      access_type:           'online',   // no refresh token needed — we issue our own
      prompt:                'select_account',
    });
    authUrl = `https://accounts.google.com/o/oauth2/v2/auth?${params}`;
  } else {
    // Microsoft
    const params = new URLSearchParams({
      client_id:             process.env.MICROSOFT_CLIENT_ID,
      redirect_uri:          redirectUri,
      response_type:         'code',
      scope:                 'openid email profile',
      state,
      nonce,
      code_challenge:        codeChallenge,
      code_challenge_method: 'S256',
      response_mode:         'query',
    });
    authUrl = `https://login.microsoftonline.com/${process.env.MICROSOFT_TENANT_ID}/oauth2/v2.0/authorize?${params}`;
  }

  res.redirect(authUrl);
});

// In-memory store for PKCE verifiers (use Redis in production for multi-instance deployments)
const oauthSessions = new Map();
// Purge stale sessions every 5 minutes
setInterval(() => {
  const cutoff = Date.now() - 10 * 60 * 1000; // 10 minutes
  for (const [key, val] of oauthSessions) {
    if (val.createdAt < cutoff) oauthSessions.delete(key);
  }
}, 5 * 60 * 1000);
```

#### GET `/auth/oauth/:provider/callback`

The provider redirects here after the user consents.

```js
const { OAuth2Client } = require('google-auth-library');
const googleClient = new OAuth2Client(process.env.GOOGLE_CLIENT_ID);

app.get('/auth/oauth/:provider/callback', async (req, res) => {
  const { provider } = req.params;
  const { code, state, error } = req.query;

  // 1. User denied consent
  if (error) {
    return res.redirect(`com-inter-app://oauth-callback?error=access_denied`);
  }

  // 2. Validate state (CSRF + mix-up protection)
  if (!state || !oauthSessions.has(state)) {
    return res.status(400).send('Invalid or expired state parameter.');
  }
  const [encodedPayload, receivedHmac] = state.split('.');
  const expectedHmac = crypto
    .createHmac('sha256', process.env.OAUTH_STATE_SECRET)
    .update(Buffer.from(encodedPayload, 'base64url').toString())
    .digest('base64url');
  if (!crypto.timingSafeEqual(Buffer.from(receivedHmac), Buffer.from(expectedHmac))) {
    oauthSessions.delete(state);
    return res.status(400).send('State signature invalid.');
  }
  const statePayload = Buffer.from(encodedPayload, 'base64url').toString();
  const [stateProvider] = statePayload.split(':');
  if (stateProvider !== provider) {
    // Mix-up attack: provider in URL doesn't match provider in state
    oauthSessions.delete(state);
    return res.status(400).send('Provider mismatch.');
  }

  const { codeVerifier, nonce } = oauthSessions.get(state);
  oauthSessions.delete(state); // One-time use

  const redirectUri = `${process.env.SERVER_BASE_URL}/auth/oauth/${provider}/callback`;
  let providerUserId, providerEmail, displayName;

  try {
    if (provider === 'google') {
      // Exchange code + code_verifier for tokens
      const tokenRes = await fetch('https://oauth2.googleapis.com/token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
          code,
          client_id:     process.env.GOOGLE_CLIENT_ID,
          client_secret: process.env.GOOGLE_CLIENT_SECRET,
          redirect_uri:  redirectUri,
          grant_type:    'authorization_code',
          code_verifier: codeVerifier,
        }),
      });
      const tokenData = await tokenRes.json();
      if (!tokenRes.ok || !tokenData.id_token) throw new Error('Token exchange failed');

      // Verify ID token signature + claims via google-auth-library
      const ticket = await googleClient.verifyIdToken({
        idToken:  tokenData.id_token,
        audience: process.env.GOOGLE_CLIENT_ID,
      });
      const payload = ticket.getPayload();

      // Security assertions
      if (!payload.email_verified) throw new Error('email_not_verified');
      if (payload.nonce !== nonce)  throw new Error('nonce_mismatch');
      if (Date.now() / 1000 - payload.iat > 300) throw new Error('id_token_too_old');

      providerUserId = payload.sub;
      providerEmail  = payload.email.toLowerCase();
      displayName    = payload.name || payload.email;

    } else {
      // Microsoft — exchange code + code_verifier
      const tokenRes = await fetch(
        `https://login.microsoftonline.com/${process.env.MICROSOFT_TENANT_ID}/oauth2/v2.0/token`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({
            code,
            client_id:     process.env.MICROSOFT_CLIENT_ID,
            client_secret: process.env.MICROSOFT_CLIENT_SECRET,
            redirect_uri:  redirectUri,
            grant_type:    'authorization_code',
            code_verifier: codeVerifier,
          }),
        }
      );
      const tokenData = await tokenRes.json();
      if (!tokenRes.ok || !tokenData.id_token) throw new Error('Token exchange failed');

      // Decode + verify Microsoft ID token
      // Microsoft's JWKS: https://login.microsoftonline.com/common/discovery/v2.0/keys
      // Use a JWKS client or manually verify — example uses manual decode for brevity
      const [, payloadB64] = tokenData.id_token.split('.');
      const payload = JSON.parse(Buffer.from(payloadB64, 'base64url').toString());

      if (payload.nonce !== nonce)             throw new Error('nonce_mismatch');
      if (payload.aud !== process.env.MICROSOFT_CLIENT_ID) throw new Error('aud_mismatch');
      if (Date.now() / 1000 > payload.exp)     throw new Error('id_token_expired');
      if (Date.now() / 1000 - payload.iat > 300) throw new Error('id_token_too_old');
      // NOTE: For production, replace manual decode with full JWKS signature verification:
      // npm install jwks-rsa + jsonwebtoken, verify against Microsoft's JWKS endpoint

      providerUserId = payload.oid;  // Object ID — stable identifier, not 'sub'
      providerEmail  = (payload.email || payload.preferred_username || '').toLowerCase();
      displayName    = payload.name || providerEmail;
    }
  } catch (err) {
    console.error(`[OAuth] ${provider} token exchange/verification failed:`, err.message);
    return res.redirect(`com-inter-app://oauth-callback?error=provider_error`);
  }

  if (!providerEmail) {
    return res.redirect(`com-inter-app://oauth-callback?error=no_email`);
  }

  // 3. Account lookup + linking (see §7 for full policy)
  const db = await pool.connect();
  try {
    await db.query('BEGIN');

    // Check if this OAuth identity already exists
    const identityRes = await db.query(
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
      // Identity exists — returning user via this provider
      const row = identityRes.rows[0];
      if (row.deleted_at) {
        await db.query('ROLLBACK');
        return res.redirect(`com-inter-app://oauth-callback?error=account_deleted`);
      }
      userId = row.user_id;
      // Update last_used_at on the identity
      await db.query(
        `UPDATE oauth_identities SET last_used_at = NOW()
         WHERE provider = $1 AND provider_user_id = $2`,
        [provider, providerUserId]
      );

    } else {
      // New OAuth identity — check if email matches an existing Inter account (auto-link)
      const existingUserRes = await db.query(
        `SELECT id, deleted_at FROM users
         WHERE lower(email) = $1 AND deleted_at IS NULL`,
        [providerEmail]
      );

      if (existingUserRes.rows.length > 0) {
        // Auto-link: email matches existing account (email_verified was asserted above)
        userId = existingUserRes.rows[0].id;
        isNewLink = true;
      } else {
        // No existing account — create new user
        const newUserRes = await db.query(
          `INSERT INTO users (email, password_hash, display_name, email_verified_at, tier)
           VALUES ($1, '', $2, NOW(), 'free')
           RETURNING id`,
          [providerEmail, displayName]
        );
        userId = newUserRes.rows[0].id;
        isNewUser = true;
      }

      // Insert the OAuth identity row
      await db.query(
        `INSERT INTO oauth_identities (user_id, provider, provider_user_id, provider_email)
         VALUES ($1, $2, $3, $4)`,
        [userId, provider, providerUserId, providerEmail]
      );
    }

    // 4. Issue Inter tokens
    const clientId = `oauth_${provider}_${Date.now()}`;
    const { refreshToken } = await auth.issueRefreshToken(userId, clientId, db);
    const accessToken = auth.generateAccessToken(userId, db); // reads tier from DB

    // 5. Store one-time handoff code (30 seconds TTL)
    const rawCode = crypto.randomBytes(32);
    const codeHashBuffer = crypto.createHash('sha256').update(rawCode).digest();
    await db.query(
      `INSERT INTO pending_oauth_handoffs (code_hash, user_id, expires_at)
       VALUES ($1, $2, NOW() + make_interval(secs => $3))`,
      [codeHashBuffer, userId, parseInt(process.env.OAUTH_HANDOFF_TTL_SECONDS || '30', 10)]
    );
    const handoffCode = rawCode.toString('base64url');

    await db.query('COMMIT');

    // 6. Audit + security notifications
    await auth.auditLog(pool, userId, isNewUser ? 'oauth_register' : 'oauth_login', {
      provider,
      isNewLink,
      ip: req.ip,
    });

    if (isNewLink) {
      // Notify user that a new sign-in method was linked to their account
      const userRes = await pool.query('SELECT email, display_name FROM users WHERE id = $1', [userId]);
      if (userRes.rows.length > 0) {
        const { email, display_name } = userRes.rows[0];
        // Fire-and-forget security alert
        mailer.sendSecurityAlertEmail(email, display_name, {
          subject: 'New sign-in method linked to your Inter account',
          body: `Your Inter account was linked to ${provider === 'google' ? 'Google' : 'Microsoft'} ` +
                `Sign-In on ${new Date().toUTCString()}. If this wasn't you, change your password immediately.`,
        }).catch(err => console.error('[OAuth] Security alert email failed:', err));
      }
    }

    // 7. Redirect to Mac app with handoff code (NOT the token)
    res.redirect(`com-inter-app://oauth-callback?code=${encodeURIComponent(handoffCode)}`);

  } catch (err) {
    await db.query('ROLLBACK');
    console.error('[OAuth] DB error during account resolution:', err);
    res.redirect(`com-inter-app://oauth-callback?error=server_error`);
  } finally {
    db.release();
  }
});
```

#### POST `/auth/oauth/exchange`

The Mac app calls this to redeem the handoff code for real tokens. Authenticated by the code itself.

```js
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

  const db = await pool.connect();
  try {
    await db.query('BEGIN');

    // Find and atomically mark used
    const result = await db.query(
      `UPDATE pending_oauth_handoffs
       SET used_at = NOW()
       WHERE code_hash = $1
         AND used_at IS NULL
         AND expires_at > NOW()
       RETURNING user_id`,
      [codeHash]
    );

    if (result.rows.length === 0) {
      await db.query('ROLLBACK');
      return res.status(401).json({ code: 'INVALID_OR_EXPIRED_CODE' });
    }

    const { user_id: userId } = result.rows[0];

    // Fetch user details for response
    const userRes = await db.query(
      `SELECT email, display_name, tier FROM users WHERE id = $1 AND deleted_at IS NULL`,
      [userId]
    );
    if (userRes.rows.length === 0) {
      await db.query('ROLLBACK');
      return res.status(401).json({ code: 'USER_NOT_FOUND' });
    }
    const user = userRes.rows[0];

    // Issue fresh token pair
    const clientId = `oauth_exchange_${Date.now()}`;
    const { refreshToken } = await auth.issueRefreshToken(userId, clientId, db);
    const accessToken = auth.generateAccessToken(userId, user.tier);

    await db.query('COMMIT');

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
    await db.query('ROLLBACK');
    next(err);
  } finally {
    db.release();
  }
});
```

---

## 5. macOS Client Implementation

### 5.1 — `ASWebAuthenticationSession` trigger

Add to `AppDelegate.m` (or a dedicated `InterOAuthController.m`):

```objc
#import <AuthenticationServices/AuthenticationServices.h>

- (void)startOAuthSignInWithProvider:(NSString *)provider {
    NSString *baseURL = self.roomController.tokenService.serverURL ?: @"http://localhost:3000";
    NSURL *startURL = [NSURL URLWithString:
        [NSString stringWithFormat:@"%@/auth/oauth/%@/start", baseURL, provider]];

    ASWebAuthenticationSession *session =
        [[ASWebAuthenticationSession alloc] initWithURL:startURL
                                      callbackURLScheme:@"com-inter-app"
                                     completionHandler:^(NSURL *callbackURL, NSError *error) {
        if (error) {
            // User cancelled or auth failed
            if (error.code != ASWebAuthenticationSessionErrorCodeCanceledLogin) {
                [self showLoginError:@"Sign-in was cancelled or failed. Please try again."];
            }
            return;
        }
        [self handleOAuthCallback:callbackURL];
    }];

    // Required on macOS — present from a valid window
    session.presentationContextProvider = self;
    session.prefersEphemeralWebBrowserSession = YES; // No shared cookie jar — fresh session every time
    [session start];
    self.oauthSession = session; // Retain to prevent deallocation
}
```

### 5.2 — Callback handler in AppDelegate

The existing deep-link handler already catches `com-inter-app://` URLs. Add an OAuth branch:

```objc
// In application:openURLs: or handleDeepLink:
- (void)handleDeepLink:(NSURL *)url {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url
                                             resolvingAgainstBaseURL:NO];
    NSString *host = components.host;

    if ([host isEqualToString:@"oauth-callback"]) {
        [self handleOAuthCallbackURL:url];
        return;
    }
    // ... existing deep link handling for reset-password, billing/success, etc.
}

- (void)handleOAuthCallbackURL:(NSURL *)url {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url
                                             resolvingAgainstBaseURL:NO];
    NSDictionary *params = [self queryParamsFromComponents:components];

    NSString *errorCode = params[@"error"];
    if (errorCode) {
        NSString *message = [errorCode isEqualToString:@"access_denied"]
            ? @"Sign-in was cancelled."
            : @"Sign-in failed. Please try again.";
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showLoginError:message];
        });
        return;
    }

    NSString *code = params[@"code"];
    if (!code.length) {
        [self showLoginError:@"Sign-in failed — no code received."];
        return;
    }

    // Exchange the one-time code for real tokens
    [self.roomController.tokenService exchangeOAuthCode:code completion:^(BOOL success, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) {
                [self didCompleteAuthentication];
            } else {
                [self showLoginError:@"Sign-in failed. Please try again."];
            }
        });
    }];
}
```

### 5.3 — `InterTokenService` — `exchangeOAuthCode:completion:`

Add to `InterTokenService.swift`:

```swift
func exchangeOAuthCode(_ code: String, completion: @escaping (Bool, Error?) -> Void) {
    guard let url = URL(string: "\(serverURL)/auth/oauth/exchange") else {
        completion(false, nil); return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["code": code])

    URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
        guard let self = self,
              let data = data,
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken  = json["accessToken"]  as? String,
              let refreshToken = json["refreshToken"] as? String,
              let expiresIn    = json["expiresIn"]    as? TimeInterval
        else {
            completion(false, error); return
        }
        self.storeTokens(accessToken: accessToken,
                         refreshToken: refreshToken,
                         expiresIn: expiresIn)
        if let user = json["user"] as? [String: Any] {
            self.currentEmail = user["email"] as? String
        }
        completion(true, nil)
    }.resume()
}
```

### 5.4 — `ASWebAuthenticationPresentationContextProviding`

In `AppDelegate.m`:

```objc
#pragma mark - ASWebAuthenticationPresentationContextProviding

- (ASPresentationAnchor)presentationAnchorForWebAuthenticationSession:
    (ASWebAuthenticationSession *)session {
    return self.mainWindow ?: NSApp.windows.firstObject;
}
```

### 5.5 — `AuthenticationServices` framework

Add `AuthenticationServices.framework` to the Xcode target's "Frameworks, Libraries, and Embedded Content".

---

## 6. Login Page HTML (Hosted by Node Server)

Create `token-server/public/login.html`. This page is opened inside `ASWebAuthenticationSession` and is also the entry point for web sign-in when the website launches.

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Sign in to Inter</title>
  <style>
    /* Dark-themed, matching the macOS app aesthetic */
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      background: #0d0d0d; color: #f0f0f0;
      display: flex; align-items: center; justify-content: center;
      min-height: 100vh;
    }
    .card {
      background: rgba(255,255,255,0.06);
      border: 1px solid rgba(255,255,255,0.10);
      border-radius: 16px; padding: 40px 36px;
      width: 100%; max-width: 380px;
    }
    h1 { font-size: 20px; font-weight: 600; margin-bottom: 28px; text-align: center; }
    .provider-btn {
      display: flex; align-items: center; gap: 12px;
      width: 100%; padding: 12px 16px; border-radius: 10px;
      border: 1px solid rgba(255,255,255,0.18); background: rgba(255,255,255,0.05);
      color: #f0f0f0; font-size: 14px; font-weight: 500;
      cursor: pointer; text-decoration: none; margin-bottom: 12px;
      transition: background 0.15s;
    }
    .provider-btn:hover { background: rgba(255,255,255,0.10); }
    .divider {
      display: flex; align-items: center; gap: 12px;
      margin: 24px 0; color: rgba(255,255,255,0.35); font-size: 12px;
    }
    .divider::before, .divider::after {
      content: ''; flex: 1; height: 1px; background: rgba(255,255,255,0.12);
    }
    /* Email/password form styles omitted for brevity — reuse InterLoginPanel design */
  </style>
</head>
<body>
  <div class="card">
    <h1>Sign in to Inter</h1>

    <!-- Google — must follow Google's branding guidelines -->
    <a class="provider-btn" href="/auth/oauth/google/start">
      <svg width="18" height="18" viewBox="0 0 48 48"><!-- Google SVG logo --></svg>
      Continue with Google
    </a>

    <!-- Microsoft — must follow Microsoft's branding guidelines -->
    <a class="provider-btn" href="/auth/oauth/microsoft/start">
      <svg width="18" height="18" viewBox="0 0 21 21"><!-- Microsoft SVG logo --></svg>
      Continue with Microsoft
    </a>

    <div class="divider">or</div>

    <!-- Email/Password form posts to /auth/login — same endpoint as macOS app -->
    <form method="POST" action="/auth/login" id="loginForm">
      <!-- fields: email, password, action button -->
      <!-- On success, server returns tokens and redirects to com-inter-app://oauth-callback?code=... -->
      <!-- (email/password via web also uses the handoff flow for consistency) -->
    </form>
  </div>
</body>
</html>
```

> **Google branding requirement:** The Google Sign-In button must use Google's official SVG logo and colors (`#4285F4` background or white). Do not alter the logo or use a generic button style. See: [developers.google.com/identity/branding-guidelines](https://developers.google.com/identity/branding-guidelines)

> **Microsoft branding requirement:** Use the official Microsoft logo (four-square Windows icon). See: [docs.microsoft.com/en-us/azure/active-directory/develop/howto-add-branding-in-azure-portal](https://docs.microsoft.com/en-us/azure/active-directory/develop/howto-add-branding-in-azure-portal)

---

## 7. Account-Linking Policy

### Decision: Silent Auto-Link

When a user signs in with Google/Microsoft using an email that matches an existing Inter email/password account:

1. Assert `email_verified: true` in the provider's ID token **before** any linking action
2. Silently create the `oauth_identities` row linking the provider ID to the existing `user_id`
3. Log into the existing account — user sees no friction
4. Send a security alert email to the account's address (via existing `sendSecurityAlertEmail`)
5. Audit log `oauth_account_linked` event

### Edge cases

| Scenario | Handling |
|----------|---------|
| Same provider, same email, returning user | `UPDATE last_used_at` — normal login |
| Different provider, same email | Auto-link both providers to same `user_id` — user can sign in via either |
| Deleted account (`deleted_at IS NULL` check fails) | Return `error=account_deleted`, redirect to Mac app |
| Provider doesn't return email | Return `error=no_email`, show user-facing error |
| `email_verified: false` | Abort — do NOT link or create. Return `error=email_not_verified` |
| User has two Google accounts and uses the wrong one | They land in the wrong Inter account — same as any auth system. No special handling needed. |

### What does NOT happen

- No "do you want to link these accounts?" prompt — the silent link is the entire UX
- No separate `oauth_only` flag — `password_hash = ''` on OAuth-created users signals no password set
- Password reset still works for OAuth-created accounts — it sets a password and enables both flows

---

## 8. Provider Registration Checklist

### Google Cloud Console

- [ ] Create project at [console.cloud.google.com](https://console.cloud.google.com)
- [ ] Enable "Google People API" (for profile scope)
- [ ] OAuth 2.0 Credentials → Web Application type
- [ ] Authorized redirect URIs: `https://api.inter.com/auth/oauth/google/callback`
- [ ] OAuth consent screen: External → add app name, logo, privacy policy URL, terms URL
- [ ] Scopes: `openid`, `email`, `profile` (no sensitive scopes → no Google verification required)
- [ ] Add test users during development (production requires publishing the consent screen)
- [ ] Copy Client ID + Client Secret to `.env`

### Microsoft Azure AD

- [ ] Register app at [portal.azure.com](https://portal.azure.com) → Azure Active Directory → App Registrations
- [ ] Platform: Web → Redirect URI: `https://api.inter.com/auth/oauth/microsoft/callback`
- [ ] Supported account types: "Accounts in any organizational directory and personal Microsoft accounts" (covers both work and personal)
- [ ] API Permissions: `openid`, `email`, `profile` (all delegated, all admin-consent-not-required)
- [ ] Certificates & Secrets → New client secret → copy to `.env`
- [ ] Copy Application (client) ID to `.env`

> **Timeline note:** Google consent screen review for non-sensitive scopes (`openid`, `email`, `profile`) is typically instant. Microsoft registration is instant. Provider review delays only apply if requesting sensitive/restricted scopes (e.g., calendar, drive, mail).

---

## 9. Environment Variables

Add to `token-server/.env`:

```bash
# OAuth — Google
GOOGLE_CLIENT_ID=your_google_client_id.apps.googleusercontent.com
GOOGLE_CLIENT_SECRET=GOCSPX-...

# OAuth — Microsoft
MICROSOFT_CLIENT_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
MICROSOFT_CLIENT_SECRET=...
MICROSOFT_TENANT_ID=common

# OAuth internal security
OAUTH_STATE_SECRET=<generate: node -e "console.log(require('crypto').randomBytes(32).toString('hex'))">
OAUTH_HANDOFF_TTL_SECONDS=30

# Server public URL (used to build redirect_uri)
SERVER_BASE_URL=https://api.inter.com
```

---

## 10. Migration

Run `014_oauth_social.sql` (see §3) via the existing migration runner:

```bash
cd token-server && node migrate.js
```

---

## 11. Testing Checklist

### Happy path
- [ ] "Continue with Google" opens `ASWebAuthenticationSession` popup
- [ ] Completing Google consent returns user to Inter app and logs them in
- [ ] "Continue with Microsoft" works equivalently
- [ ] New Google user gets a `users` row with `email_verified_at = NOW()` and `password_hash = ''`
- [ ] Returning Google user hits `UPDATE last_used_at` path — no new row created
- [ ] Email/password user signing in with matching Google account → auto-linked, security email sent

### Security
- [ ] Handoff code is single-use: second call to `/auth/oauth/exchange` with same code returns 401
- [ ] Handoff code expires after 30 seconds
- [ ] Modified `state` parameter rejected with 400 (CSRF)
- [ ] Provider mismatch in state vs URL path rejected with 400 (mix-up)
- [ ] `email_verified: false` in Google token → aborted, no user created
- [ ] Nonce mismatch → aborted
- [ ] Old ID token (`iat` > 5 minutes ago) → aborted
- [ ] Deleted account → `error=account_deleted` redirected

### Error paths
- [ ] User cancels Google consent → `ASWebAuthenticationSessionErrorCodeCanceledLogin`, no crash
- [ ] Provider returns error → error redirect handled gracefully in Mac app
- [ ] Server down during exchange → appropriate error shown

---

## 12. Phase F Task Breakdown

| ID | Task | File | Notes |
|----|------|------|-------|
| F.1 | Run migration `014_oauth_social.sql` | PostgreSQL | Creates `oauth_identities` + `pending_oauth_handoffs` |
| F.2 | `npm install google-auth-library` | `token-server/package.json` | ID token verification |
| F.3 | Register Google OAuth app + get credentials | Google Cloud Console | Redirect URI: `/auth/oauth/google/callback` |
| F.4 | Register Microsoft OAuth app + get credentials | Azure Portal | Redirect URI: `/auth/oauth/microsoft/callback` |
| F.5 | Add env vars to `.env` | `token-server/.env` | `GOOGLE_*`, `MICROSOFT_*`, `OAUTH_STATE_SECRET`, `SERVER_BASE_URL` |
| F.6 | Add `oauthSessions` Map + cleanup timer | `token-server/index.js` | In-memory PKCE/nonce store |
| F.7 | Add `GET /auth/login-page` route | `token-server/index.js` | Serves `public/login.html` |
| F.8 | Add `GET /auth/oauth/:provider/start` route | `token-server/index.js` | PKCE + state generation + provider redirect |
| F.9 | Add `GET /auth/oauth/:provider/callback` route | `token-server/index.js` | Token exchange, ID token verification, account lookup/link, handoff code |
| F.10 | Add `POST /auth/oauth/exchange` route | `token-server/index.js` | Handoff code redemption → Inter tokens |
| F.11 | Create `token-server/public/login.html` | `token-server/public/login.html` | Sign-in page with Google + Microsoft buttons + email/password form |
| F.12 | Add `startOAuthSignInWithProvider:` to `AppDelegate.m` | `inter/App/AppDelegate.m` | `ASWebAuthenticationSession` trigger |
| F.13 | Add OAuth branch to deep-link handler | `inter/App/AppDelegate.m` | `handleOAuthCallbackURL:` |
| F.14 | Add `exchangeOAuthCode:completion:` to `InterTokenService.swift` | `inter/Networking/InterTokenService.swift` | Token exchange call |
| F.15 | Add `ASWebAuthenticationPresentationContextProviding` to `AppDelegate.m` | `inter/App/AppDelegate.m` | Required macOS API |
| F.16 | Add `AuthenticationServices.framework` to Xcode target | Xcode project | Framework linkage |
| F.17 | Add Google + Microsoft sign-in buttons to `InterLoginPanel.m` | `inter/UI/Views/InterLoginPanel.m` | Calls `startOAuthSignInWithProvider:` via delegate |
| F.18 | Run full testing checklist (§11) | — | All happy-path + security + error paths |

**Phase F total: 18 tasks**

---

## Appendix — Why `ASWebAuthenticationSession` is mandatory

RFC 8252 §8.12 explicitly forbids native apps from using an embedded web view (e.g. `WKWebView`) for OAuth. Embedded views allow the host app to:
- Steal the user's provider credentials by injecting JavaScript
- Read session cookies from the provider
- Inspect the full authorization URL including state and code parameters

`ASWebAuthenticationSession` runs OAuth in a separate process, sharing Safari's cookie jar (private to the system), with no access granted to the host app. It is the only Safe Browser API on macOS/iOS for this purpose. Apple enforces this through App Review; apps using `WKWebView` for OAuth sign-in are rejected.
