# OAuth Social Sign-In — Phase F Status

> Tracking implementation progress for `oauth_plan.md`.

## Task Progress

| ID | Task | Status |
|----|------|--------|
| F.1 | Migration `014_oauth_social.sql` | ✅ Done |
| F.2 | `npm install google-auth-library jwks-rsa` | ✅ Done |
| F.3 | Register Google OAuth app (Google Cloud Console) | ⬜ Manual — needs real credentials |
| F.4 | Register Microsoft OAuth app (Azure Portal) | ⬜ Manual — needs real credentials |
| F.5 | Add env vars to `.env` | ✅ Done |
| F.6 | `oauthSessions` Map + cleanup timer | ✅ Done |
| F.7 | `GET /auth/login-page` route | ✅ Done |
| F.8 | `GET /auth/oauth/:provider/start` route | ✅ Done |
| F.9 | `GET /auth/oauth/:provider/callback` route | ✅ Done |
| F.10 | `POST /auth/oauth/exchange` route | ✅ Done |
| F.11 | `token-server/public/login.html` | ✅ Done |
| F.12 | `startOAuthSignInWithProvider:` in AppDelegate.m | ✅ Done |
| F.13 | OAuth branch in deep-link handler | ✅ Done |
| F.14 | `exchangeOAuthCode:completion:` in InterTokenService.swift | ✅ Done |
| F.15 | `ASWebAuthenticationPresentationContextProviding` in AppDelegate.m | ✅ Done |
| F.16 | `AuthenticationServices.framework` linkage | ✅ Auto-linked (CLANG_ENABLE_MODULES=YES) |
| F.17 | OAuth buttons in InterLoginPanel | ✅ Done |
| F.18 | Full testing checklist | ⬜ Not started |

**Progress: 15/18 tasks done** (F.3, F.4 require manual provider registration; F.18 requires testing)

## Extra Endpoints Added

- `POST /auth/oauth/create-handoff` — Authenticated endpoint for the web login page's email/password form to create a handoff code for the Mac app redirect.

## Files Modified

| File | Changes |
|------|---------|
| `token-server/migrations/014_oauth_social.sql` | **Created** — `oauth_identities` + `pending_oauth_handoffs` tables |
| `token-server/package.json` | Added `google-auth-library`, `jwks-rsa` |
| `token-server/.env` | Added OAuth env vars (Google/MS commented out pending credentials) |
| `token-server/index.js` | OAuth routes, session map, PKCE/state, provider callback, exchange, create-handoff |
| `token-server/public/login.html` | **Created** — Dark-themed login page with OAuth + email/password |
| `inter/App/AppDelegate.m` | OAuth methods, deep link dispatch, ASWebAuth support, delegate wiring |
| `inter/Networking/InterTokenService.swift` | `exchangeOAuthCode(_:completion:)` method |
| `inter/UI/Views/InterLoginPanel.h` | Added `loginPanel:didRequestOAuthWithProvider:` to delegate protocol |
| `inter/UI/Views/InterLoginPanel.m` | Google/Microsoft buttons + divider in buildUI |

## Remaining Work

1. **F.3/F.4**: Register OAuth apps with Google/Microsoft and fill in `.env` credentials
2. **F.18**: Run migration (`node migrate.js`), then test:
   - Happy path: Google sign-in → new account → tokens returned
   - Happy path: Microsoft sign-in → existing account auto-link
   - Error: User cancels OAuth → panel shows cancellation message
   - Error: Invalid/expired handoff code → 401
   - Security: PKCE verification, state CSRF protection, nonce binding
   - Security: Handoff code single-use enforcement
   - Security: ID token `email_verified` assertion
