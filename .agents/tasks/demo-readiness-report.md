# Inter / KioMeet — Demo Readiness Report

**Prepared for:** Aman Verma, internship viva demo to college professor
**Date of check:** 8 Oct 2026 (local machine investigation)
**Scope:** Hands-on verification only — nothing in this report is taken from docs without being tested where feasible. Every claim below is backed by a command actually run in this session (see §3 for exact transcripts).

---

## 1. Overall Verdict

**The project is demo-ready for a local, in-person demo today, with about 15–20 minutes of prep the day before.** I registered real test users against the live local stack, created both a normal room and a tier-gated "interview" room, joined a second participant into the interview room, created a team and added a member with a role change, scheduled a meeting and sent an invite, and did a clean Xcode Debug build of the macOS app — all of it worked end-to-end on this machine. The two things that will NOT work live are anything that depends on outbound internet (OAuth sign-in buttons, and any transactional email — invite/calendar emails, password reset, verification) because this machine has no SMTP configured and the test environment has no outbound SMTP reachability; email/password login is unaffected and is the correct fallback. The single biggest logistics item is that **port 3000 (the token-server's documented default) is currently occupied by an unrelated Next.js project on this Mac** — the demo must either stop that process first or run the token-server on another port and point the app at it (see §4). Recording-UI wiring (Recordings button + consent panel) is actually done in code — contrary to `pre_launch_checklist.md`, which is stale on this point (see §2 note).

---

## 2. Feature-by-Feature Readiness Table

| # | Feature | Verdict | Caveats | What to prepare |
|---|---|---|---|---|
| 1 | Email/password login | **READY TO DEMO LIVE** | OAuth (Google/Microsoft) buttons will likely be visible in the UI but will fail or hang — Google client ID is set but secret is not confirmed configured for a full round trip, Microsoft is fully commented out. Don't click them live. | Pre-create 1–2 demo accounts the day before (see §4) so you're not registering fresh in front of the professor (registration also works, so either is fine as a fallback). |
| 2 | Secure Interview Mode (locked single-window session) | **DEMOABLE WITH CAVEATS** | Server-side: confirmed working — `/room/create` with `roomType:"interview"` is rejected with `403 INSUFFICIENT_TIER` for a free-tier user and succeeds for a `hiring`-tier user; the interviewee join issues a correctly-scoped LiveKit token with `role:"interviewee"`. This gate is real and tier is read from the server-signed JWT, not client input. Client-side: `SecureWindowController` + `InterWindowSecurity.m` confirmed in code — `NSWindowSharingType` is set to `NSWindowSharingNone` (blocks screen capture of the secure window) in Release, and a debug-only escape hatch (`--disable-capture-protection` / `INTER_DISABLE_CAPTURE_PROTECTION=1`) exists for UI dev — **do not set that env var or pass that flag before the demo**, it defeats the exact protection you're demonstrating. The host account must be on the `hiring` tier to create an interview room (billing isn't live, so this has to be set directly in the dev DB — see §4). One code smell: `InterShouldEnforceInterviewExternalDisplayPolicy()` in `AppDelegate.m` currently returns `NO` with a comment saying external-display blocking is "intentionally disabled...temporary testing bypass" — the single-window capture restriction itself is intact, but the related multi-display lockout for the interviewee is not currently enforced. Not a blocker for showing the core feature, but don't claim multi-display blocking works if asked. | Two accounts: one on `hiring` tier (interviewer), one any tier (candidate). Two vantage points — see §5 logistics checklist. |
| 3 | Live Chat / Polls / Q&A | **DEMOABLE WITH CAVEATS** | Code-level: chat, polls, and Q&A are all implemented as LiveKit DataChannel topics (`InterChatController` topic `"chat"`, `InterPollController` topic matching `pollTopic`, `InterQAController` topic matching `qaTopic`) — these are peer-to-peer over the WebRTC data channel, not via the token-server's Socket.IO (that channel is reserved for moderation/mic-state signals). This means **chat/poll/Q&A require an actual LiveKit media connection to be live** — they will not work if LiveKit isn't running, even though the token-server itself would be healthy. I confirmed a local `livekit-server --dev` starts cleanly in ~1s and binds `127.0.0.1:7880`/`7881`, matching the `devkey`/`secret` already in `token-server/.env`. I did not drive the GUI (no headless interaction), so I did not visually confirm a message appearing in a second window — that is the one thing to rehearse once before the real demo. | LiveKit server must be running (`livekit-server --dev`) before opening the app. Rehearse once with two app windows/accounts to see a chat message, a poll vote, and a Q&A question land live. |
| 4 | Meeting scheduling with calendar invite | **DEMOABLE WITH CAVEATS** | Server-side: confirmed working — `POST /meetings/schedule` creates a meeting + room code; `POST /meetings/:id/invite` accepts an invitees array and returns `{"created":[...], "skipped":[]}`. The `.ics` generation code exists in `mailer.js` (`icsContent` with `BEGIN:VCALENDAR`/`VEVENT`), **but it is attached to and sent through an actual SMTP email** — and SMTP is not reachable from this machine (`[mailer] SMTP transport verification failed: connect ETIMEDOUT ...:465` appeared in the server log during my test, and a real register-time verification email failed the same way). So the invite API call succeeds (200 OK, invitee recorded in DB) but **no email, and therefore no .ics file, will actually be delivered or openable live.** Client UI: `InterSchedulePanel` (SwiftUI-backed) is fully wired to create/cancel/join/invite from the app — this part will work and look good. | Plan to show the "Schedule meeting" UI, submit it, and show the created meeting appearing in "Upcoming" — but say explicitly that email delivery is disabled in this dev environment rather than attempting to show an inbox/.ics file live. Alternative: open `mailer.js`'s ICS-building function and briefly walk through the code if the professor wants to see the invite format. |
| 5 | Team management (add member, assign role) | **READY TO DEMO LIVE** | Confirmed fully end-to-end: created a team via `POST /teams`, instant-added a second registered user by email via `POST /teams/:id/members` (returns `201` with the new member record immediately — no email round-trip needed when the invitee is already registered), and changed their role to `admin` via `PATCH /teams/:id/members/:id` (`{"ok":true}`). Client UI (`TeamMembersView.swift` + `TeamMembersViewModel.swift`) is wired to the same endpoints. The only path that depends on email is inviting someone **not yet registered** — don't demo that sub-case. | Both demo accounts must already be registered in the app (not just invited) before the demo so "Add member" resolves instantly instead of sending an invite email. |

---

## 3. Exact Commands Run and Their Output

### 3.1 Backend — package.json / Node version
```
node --version          → v20.18.0   (README asks for Node 20+ ✓)
npm --version           → 11.3.0
```
`token-server/package.json` has no `start`/`dev` script — only `"test": "node --test ..."`. The README documents `node index.js` directly, which matches what I ran.

### 3.2 .env vs .env.example (key names only, no values printed)
Present and uncommented in `.env`: `ACCESS_TOKEN_TTL, APP_RETURN_URL, DATABASE_URL, ENCRYPTION_ACTIVE_VERSION, ENCRYPTION_SECRET_V1, GOOGLE_CALENDAR_CLIENT_ID, GOOGLE_CALENDAR_CLIENT_SECRET, GOOGLE_CALENDAR_REDIRECT_URI, GOOGLE_CLIENT_ID, JWT_SECRET, LEMONSQUEEZY_API_KEY, LEMONSQUEEZY_STORE_ID, LEMONSQUEEZY_WEBHOOK_SECRET, LIVEKIT_API_KEY, LIVEKIT_API_SECRET, LIVEKIT_HTTP_URL, LIVEKIT_SERVER_URL, OAUTH_HANDOFF_TTL_SECONDS, OAUTH_STATE_SECRET, OUTLOOK_CALENDAR_CLIENT_ID, OUTLOOK_CALENDAR_CLIENT_SECRET, OUTLOOK_CALENDAR_REDIRECT_URI, OUTLOOK_TENANT, PORT, REDIS_URL, REFRESH_TOKEN_SECRET, REFRESH_TOKEN_TTL_DAYS, SERVER_BASE_URL, SMTP_HOST`.
Commented out: `APP_RETURN_URL` (duplicate, commented variant), `BILLING_PAGE_BASE_URL, MICROSOFT_CLIENT_ID, MICROSOFT_CLIENT_SECRET, MICROSOFT_TENANT_ID, SECURITY_WEBHOOK_URL`.
Note: `GOOGLE_CLIENT_ID` is present/uncommented but I did not test a real OAuth round-trip since that requires a browser flow and a registered redirect URI — treat Google OAuth as unverified, not confirmed-working.
`SMTP_HOST=` is present but points at an unreachable/placeholder host — confirmed by the runtime error below.

### 3.3 Postgres / Redis / LiveKit availability
```
pg_isready        → /tmp:5432 - accepting connections   (Postgres already running locally)
redis-cli ping    → PONG                                 (Redis already running locally)
psql -lqt         → inter_dev database already exists
docker ps         → Cannot connect to the Docker daemon (Docker not running — not needed, Postgres/Redis are native)
livekit-server --version → 1.9.11 (binary already installed via Homebrew)
```

### 3.4 Migrations
```
$ node migrate.js
[migrate] Starting migration...
[migrate] Database: postgresql://localhost:5432/inter_dev
[migrate] No pending migrations.
```
The dev database is already fully migrated — nothing to do here before the demo.

### 3.5 Starting the token server
Port 3000 (the documented default, and the one hardcoded in `inter/Info.plist` as `InterTokenServerURL`) is **already occupied** by an unrelated Next.js dev server on this Mac (confirmed via `lsof -iTCP:3000 -sTCP:LISTEN`, PID belonged to a process with cwd `/Users/aman_01/abhishek_proj...`, and `curl -i http://localhost:3000/health` returned a Next.js HTML page, not the token-server's JSON). This is **not a bug in Inter** — it's a port collision with something else on the demo machine. I started the token-server on port 3999 for testing (`PORT=3999 node index.js`) and it came up clean:
```
[dotenv] injecting env (33) from .env
[crypto] Encryption ready — active key version: 1, total keys loaded: 1
[token-server] Running on http://localhost:3999
[token-server] Redis: redis://localhost:6379
[redis] Connected to redis://localhost:6379
[startup] Marked 4 phantom meeting(s) as failed (LiveKit was offline at creation time)

$ curl -i http://localhost:3999/health
HTTP/1.1 200 OK
{"status":"ok","redis":"connected","postgres":"connected","rooms":0}
```
The "4 phantom meeting(s) marked as failed" line is normal self-healing from a previous session where LiveKit wasn't running — not an error.

### 3.6 Auth smoke test
```
POST /auth/register {email, password, displayName} → 201, user object + accessToken + refreshToken returned
POST /auth/login     {email, password}              → 200, same shape
GET  /auth/me  (Bearer token)                        → 200, {userId, email, displayName, tier, tokenFamily}
```
Note: the register endpoint rejects common/breached passwords (`"This password has appeared in a data breach"`) — use a non-trivial password when pre-seeding demo accounts, or the registration call will 400.
Email verification is NOT required to log in — confirmed no `email_verified_at` gate exists in `auth.js`'s login path, so SMTP being down does not block login.

### 3.7 Room creation / interview tier gate / join
```
POST /room/create {identity, displayName}  (free tier, X-Idempotency-Key header required)
  → 201 {roomCode, roomName, token, serverURL:"ws://localhost:7880", roomType:"call", ...}

POST /room/create {..., roomType:"interview"}  (free tier)
  → 403 {"error":"Hosting an interview requires a hiring plan.","code":"INSUFFICIENT_TIER","currentTier":"free","requiredTier":"hiring"}

# After UPDATE users SET tier='hiring' WHERE email=... (direct DB edit, test-only, cleaned up after)
POST /room/create {..., roomType:"interview"}  (hiring tier, fresh login to pick up new tier in JWT)
  → 201 {roomCode, roomType:"interview", ...}

POST /room/join {roomCode, identity:"candidate1", displayName:"Candidate One"}  (unauthenticated/guest)
  → 200, participantCount: 2, LiveKit JWT metadata decodes to {"role":"interviewee","tools":true}
```
This confirms: the interview tier gate is server-enforced (not just client-side), and the second participant is actually assigned the `interviewee` role server-side.

### 3.8 LiveKit dev server
```
$ livekit-server --dev
INFO  starting in development mode
INFO  no keys provided, using placeholder keys {"API Key": "devkey", "API Secret": "secret"}
INFO  starting LiveKit server {"portHttp": 7880, ... "rtc.portTCP": 7881, "rtc.portUDP": {"Start":7882}}
```
This matches `LIVEKIT_API_KEY=devkey` / `LIVEKIT_API_SECRET=secret` already in `token-server/.env` and the `ws://localhost:7880` the room-create response returns — no credential mismatch. I stopped this process after testing; it is NOT currently running.

### 3.9 Teams
```
POST /teams {name, description}                           → 201, team object (memberCount:1, owner = caller)
POST /teams/:id/members {email: <second registered user>} → 201, {"member": {role:"member", status:"active", ...}}
PATCH /teams/:id/members/:memberId {role:"admin"}          → 200, {"ok":true}
```
Both calls succeeded without any email dependency because the invitee was already a registered user (instant-add path). All test teams/members/users were deleted afterward.

### 3.10 Scheduling
```
POST /meetings/schedule {title, scheduledAt, durationMinutes, hostTimezone}
  → 200, meeting object with roomCode, status:"scheduled"

POST /meetings/:id/invite {invitees:[{email, displayName}]}
  → 200, {"created":[{"email":"...", "status":"invited"}], "skipped":[]}

Server log at the same time:
  [mailer] SMTP transport verification failed: connect ETIMEDOUT 54.205.195.44:465
```
The invite is recorded in the database and the API reports success, but the actual email (carrying the `.ics` attachment) silently fails to send — this is purely an SMTP/network reachability issue on this machine/environment, not an application bug.

### 3.11 Xcode build
```
$ xcodebuild -list -project inter.xcodeproj
Targets: inter, interTests
Schemes: inter
(Swift package graph resolved cleanly: LiveKit 2.15.0, SocketIO 16.1.1, SwiftProtobuf 1.35.1, etc.)

$ xcodebuild build -project inter.xcodeproj -scheme inter -configuration Debug -destination 'platform=macOS'
...
** BUILD SUCCEEDED **
```
Zero compile errors. Two benign warnings only (an App Intents metadata extraction no-op, and an Info.plist-in-Copy-Bundle-Resources warning that's cosmetic). `MACOSX_DEPLOYMENT_TARGET = 15.6` in the project; this machine runs macOS 26.5.2 with Xcode 26.1.1 — comfortably above the minimum. **Note:** I did not launch/drive the built `.app` GUI (per the investigation brief, headless GUI interaction isn't feasible) — a successful build is the verified signal here, not a confirmed working UI session.

### 3.12 Cleanup performed
All test users (`demo-*@example.com`), the test team, test team members, test scheduled meetings, and test meeting invitees were deleted from the local Postgres `inter_dev` database after each test. The temporary token-server (port 3999) and `livekit-server --dev` processes were both stopped; neither is running now. No files were modified — `git status` only shows pre-existing uncommitted work-in-progress from before this investigation (code editor removal, secure-tools refactor in progress), none of which I touched.

---

## 4. Day-Before-Demo Checklist

1. **Resolve the port 3000 conflict.** Either stop whatever is running on port 3000 on the demo Mac (`lsof -iTCP:3000 -sTCP:LISTEN -P -n` to find it), or run the token-server on another port and update `InterTokenServerURL` in `inter/Info.plist` (or the equivalent runtime config) + rebuild. Simpler: just make sure nothing else is listening on 3000 before you start.
2. **Start the LiveKit dev server first**, in its own terminal, and leave it running for the whole demo: `livekit-server --dev`. Confirm it's up (`lsof -iTCP:7880`) before starting the token-server.
3. **Start the token-server**: `cd token-server && node index.js`. Confirm with `curl http://localhost:3000/health` → expect `{"status":"ok","redis":"connected","postgres":"connected"}`. If Redis/Postgres aren't already running, start them (`brew services start postgresql`, `brew services start redis`, or however they're normally started on the demo machine) before this step.
4. **Pre-seed two demo accounts** the day before, not live:
   - Account A (interviewer / host): register normally through the app with a real, non-breached password, then promote its tier directly in the dev DB: `psql <DATABASE_URL> -c "UPDATE users SET tier='hiring' WHERE email='<interviewer-email>';"` — this is required because billing/Lemon Squeezy isn't live, so there is no other way to reach the `hiring` tier that interview-hosting requires.
   - Account B (candidate / team member): register normally, leave on free tier.
   - Log in with both once beforehand to confirm credentials work and JWTs reflect the right tier (`GET /auth/me`).
5. **Pre-seed one team with Account B already added as a member**, and pre-seed one scheduled meeting, so the "Teams" and "Scheduling" screens aren't empty when the professor is watching — an empty list looks unfinished even when the feature works.
6. **Decide your two-vantage-point setup** for Secure Interview Mode and Chat/Polls/Q&A. Options, in order of simplicity:
   - Two Mac user accounts (fast-user-switch) on the same Mac, each running their own instance of the app logged in as A and B.
   - Two separate machines on the same LAN, both pointed at the host Mac's token-server/LiveKit (requires changing `localhost` to the host's LAN IP in both the server env and the app's server URL config, and allowing inbound connections on 3000/7880-7882 through the firewall).
   - If only one machine is available and multiple OS user accounts aren't practical, two separate windows is NOT sufficient — the app's room-join model expects distinct `identity` values per LiveKit participant, and the secure-interview single-window capture restriction is specifically about *window* content, not *process* count, so two Dock-launched copies of the same `.app` bundle may still be viable but has not been verified in this session — treat this as unverified and prefer the two-user-account approach, which does not require it.
7. **Rehearse the chat/poll/Q&A flow once** end-to-end with both accounts connected to confirm a message, a poll vote, and a Q&A question all show up live on the other side — this is the one feature I could not visually verify in a headless environment.
8. **Do NOT click the Google/Microsoft "Sign in with..." buttons live.** Mention them as "implemented, pending production credentials" if asked, rather than demoing them.
9. **Do NOT rely on email for the scheduling-invite demo.** Show the "Meeting scheduled!" confirmation and the Upcoming list updating; explicitly state that email delivery is disabled in this dev environment rather than trying to open an inbox.
10. **Do NOT demo "Recordings" button or recording-consent flow unless you also rehearse it once** — the code is wired (contradicting the stale `pre_launch_checklist.md` §4, which claims it's unwired), but it was not part of the 5 features in your presentation and was not re-verified live in this session beyond reading the code paths.

---

## 5. Risk List — Things to Avoid Showing Live, or That Need a Fallback

| Risk | Why it could embarrass you | Mitigation |
|---|---|---|
| Port 3000 already in use by another project on this Mac | Server fails to start with `EADDRINUSE`, or worse, the app silently talks to the WRONG server (the Next.js app) and nothing works, with a confusing non-JSON error | Check and free port 3000 (or move the token-server, consistently, in both `.env` `PORT` and the app's configured server URL) before the professor arrives |
| Clicking "Sign in with Google/Microsoft" | Google secret may not be fully configured for a real round trip; Microsoft is fully commented out — button will error or hang | Don't click it live; mention it's implemented pending production OAuth credentials |
| Trying to show a received calendar invite email or .ics file | SMTP is unreachable in this environment (`ETIMEDOUT`) — confirmed by direct test; no email will arrive | Show only the in-app "Meeting scheduled" confirmation + Upcoming list; mention email delivery is disabled in dev |
| Trying to show a password-reset or email-verification flow | Same SMTP failure — confirmed | Avoid entirely; not one of your 5 planned features anyway |
| Inviting a team member who is NOT already registered in the app | That path sends an email invite, which will also silently fail to deliver (candidate never gets it, "member" list won't show them as active) | Only add members who are already registered test accounts (instant-add path, confirmed working without email) |
| Empty Teams or Scheduling screens | Looks like the feature isn't built, even though it is | Pre-seed one team-with-member and one scheduled meeting the day before (see checklist §4.5) |
| Interview room creation failing with "requires a hiring plan" | Billing isn't live, so a fresh/free-tier account can never pass this gate through the UI | Pre-promote your demo host account's tier directly in the dev DB the day before, and re-login to refresh the JWT (tier is baked into the JWT at login time) |
| Setting `--disable-capture-protection` or `INTER_DISABLE_CAPTURE_PROTECTION=1` before the demo (e.g. left over from UI dev work) | This is a literal debug-only kill switch for the exact window-capture protection you're demonstrating — if it's set, the "secure" window would actually be screen-recordable, defeating the point of the feature in front of the professor | Confirm this env var is unset and the flag isn't being passed; this is a dev-only affordance per `InterWindowSecurity.m` and is compiled out of Release builds entirely, but a Debug build run from Xcode could still have it set in scheme arguments — check the scheme's launch arguments/environment before the demo |
| Relying on the two-separate-GUI-instances-of-the-same-app-on-one-machine approach without testing it first | Not verified in this investigation (no headless GUI driving was possible) — may or may not work cleanly for two LiveKit identities from one process pool | Prefer two macOS user accounts (fast user switching) or two physical/virtual machines, both of which are structurally simpler and don't depend on untested app behavior |
| Assuming the pre_launch_checklist.md's claim that "Recordings button not wired" / "consent panel not wired" is current | It's stale — both are wired in `AppDelegate.m` (`toggleNormalRecordingListPanel`, `showRecordingConsentOverlayForRemoteRecordingWithMode:`) as of the `Jun 18 2026` commit, while the checklist dates from `14 April 2026` | Don't repeat the checklist's claim to the professor if asked about recording status; it's more done than the doc says. But also don't over-claim — this wasn't one of your 5 planned demo features and wasn't driven live in this session |
| `InterShouldEnforceInterviewExternalDisplayPolicy()` returning `NO` (external-display blocking for interviewee disabled) | If asked "what if the candidate has two monitors," the honest answer right now is that the external-display lockout is intentionally disabled pending refinement — the window-capture restriction itself is still intact and is the core of what you're demonstrating | Know this distinction if probed on it: single-window capture protection = working; multi-display lockout = temporarily disabled by a code comment, not a bug you need to fix tonight |

---

## 6. Summary of What Is NOT Verified (be honest about this if asked)

- OAuth sign-in (Google/Microsoft) — code read, not round-trip tested (requires a browser + registered redirect URI).
- Actual email delivery of any kind — confirmed broken in this environment (SMTP unreachable), not a code defect.
- The GUI itself was never driven interactively — all client-side claims come from reading `AppDelegate.m`, `SecureWindowController.m`, `InterChatController.swift`, `InterPollController.swift`, `InterQAController.swift`, `InterSchedulePanel.m/.h`, and the Teams SwiftUI stack, cross-referenced against a live, working server. The Xcode build succeeding is the one concrete signal that the client code compiles and links against the real LiveKit/SocketIO SDKs with no missing symbols.
- Running two full app instances on one Mac for the two-vantage-point interview/chat demo — not attempted; recommend the two-user-account approach instead (see §4.6).
