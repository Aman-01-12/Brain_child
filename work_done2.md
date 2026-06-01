# Work Done — Phase 11+ Changelog

> **Continued from**: `work_done.md` (Phases 0–10, Auth, Billing, Recording completion)
> **Reference**: See `implementation_plan.md` § Phase 11 for the full spec.

---

## [14 April 2026] — Phase 11: Scheduling & Productivity — Begin

Starting Phase 11 (Scheduling & Productivity). Prerequisites satisfied:
- PostgreSQL + migrations infrastructure (Phase 6) ✅
- Auth system with JWT + requireAuth middleware ✅
- Email infrastructure (nodemailer + SMTP) ✅
- Billing tiers (free/pro/hiring) ✅

### 11.2.1 — Migration SQL (`015_scheduling.sql`)
- **`scheduled_meetings`** table: UUID PK, host_user_id FK→users, title, description, scheduled_at (TIMESTAMPTZ), duration_minutes (1-1440 CHECK), room_type (call/interview), room_code, password, lobby_enabled, recurrence_rule, host_timezone, status (scheduled/cancelled/completed), timestamps
- **`meeting_invitees`** table: UUID PK, meeting_id FK→scheduled_meetings (CASCADE), email, display_name, status (pending/accepted/declined), invited_at, responded_at, UNIQUE(meeting_id, email)
- 4 indexes + `set_scheduled_meetings_updated_at` trigger
- Migration applied successfully

### 11.2.2 — Scheduling API (`scheduling.js`)
- Express Router mounted at `/meetings` in `index.js`
- 7 routes: POST /schedule, GET /upcoming, GET /:id, PATCH /:id, DELETE /:id, POST /:id/invite, POST /:id/rsvp
- Helpers: generateRoomCode, isValidTimezone, formatMeeting (snake→camel), camelToSnake
- Auth: requireAuth on all routes, host-only enforcement on PATCH/DELETE/invite
- All endpoints tested via curl

### 11.2.6 — Meeting invitation emails (`mailer.js`)
- `sendMeetingInvitationEmail(toEmail, details)` — HTML email + .ics calendar attachment
- RFC 5545 VCALENDAR with VEVENT, METHOD:REQUEST
- Helpers: `toICSDate()`, `icsEscape()`

### 11.2.7 — Client scheduling (Swift + Obj-C)
**InterTokenService.swift** — 4 new methods:
- `fetchUpcomingMeetings(completion:)` — GET /meetings/upcoming, returns (hosted, invited, error)
- `scheduleMeeting(title:description:scheduledAt:durationMinutes:roomType:hostTimezone:password:lobbyEnabled:completion:)` — POST /meetings/schedule
- `cancelMeeting(meetingId:completion:)` — DELETE /meetings/:id
- `inviteToMeeting(meetingId:invitees:completion:)` — POST /meetings/:id/invite

**InterSchedulePanel.h/.m** — New UI panel:
- `InterScheduledMeeting` model class
- `InterSchedulePanelDelegate` protocol (schedule, cancel, join, invite callbacks)
- Schedule form: title, date/time picker, duration popup, room type, password, lobby toggle
- Upcoming meetings table with Hosted/Invited segment, Join/Cancel row buttons
- Dark theme, floating window style matching existing panels

**AppDelegate.m** — Wiring:
- "Schedule Meeting" button on setup screen (auth-gated)
- `handleShowSchedulePanel` — creates floating NSWindow with InterSchedulePanel
- `reloadScheduleData` — fetches meetings from server, parses into models
- `meetingFromDictionary:` — JSON→model with ISO8601 date parsing
- Full `InterSchedulePanelDelegate` implementation: schedule→API, cancel→API, join→fill room code + join, invite→convert emails to dicts + API
- Teardown in `teardownActiveWindows`

**Build: SUCCEEDED ✅**

---

## [14 April 2026] — Phase 11: Calendar Sync, Teams, Encryption — Continued

Completed remaining Phase 11 items: 11.1, 11.2.3, 11.2.4, 11.2.5, 11.4.

### 11.1 + 11.2.3 — Apple Calendar (EventKit) (`InterCalendarService.swift`)
- **NEW** `inter/App/InterCalendarService.swift`
- `InterCalendarServiceDelegate` protocol: 4 optional methods (authorization change, sync event, fail sync, external change)
- `InterCalendarService` class: `EKEventStore`, serial work queue, UserDefaults-persisted `meetingEventMap`
- `requestAccess(completion:)` — macOS 14+ `requestFullAccessToEvents` / legacy `requestAccess(to: .event)`
- `createEvent(meetingId:title:notes:startDate:durationMinutes:hostTimezone:roomCode:)` — creates EKEvent with timezone, 5-min alarm, room code in notes
- `removeEvent(forMeetingId:)` — removes EKEvent by persisted identifier
- `fetchUpcomingEvents(daysAhead:completion:)` — returns array of dicts for 30-day window
- `observeStoreChanges()` — listens to `.EKEventStoreChanged` notification
- **Entitlement**: Added `com.apple.security.personal-information.calendars` to `inter.entitlements`
- **Info.plist**: Added `NSCalendarsUsageDescription` and `NSCalendarsFullAccessUsageDescription`
- **AppDelegate.m wiring**: `calendarService` property, init in `applicationDidFinishLaunching`, schedule delegate creates EKEvent on success, cancel delegate removes EKEvent

### 11.2.4 + 11.2.5 — Google & Outlook Calendar Sync (Server)

**`token-server/crypto.js`** — NEW:
- Key-versioned AES-256-GCM encryption for OAuth refresh tokens
- Format: `v{N}:{iv_hex}:{authTag_hex}:{ciphertext_hex}`
- Multi-key support via `ENCRYPTION_SECRET_V1` through `V100` env vars
- `encryptToken()`, `decryptToken()`, `isEncryptionAvailable()`, `getActiveVersion()`
- Graceful degradation when no keys configured (warns, returns 503 on encrypt attempts)

**`token-server/migrations/016_calendar_teams.sql`** — NEW (applied):
- Google Calendar columns on `users`: `google_refresh_token`, `google_token_key_version`, `google_reauth_required`
- Outlook Calendar columns on `users`: `outlook_refresh_token`, `outlook_token_key_version`, `outlook_reauth_required`
- `teams` table + `team_members` table (see 11.4 below)

**`token-server/calendar.js`** — NEW Express Router mounted at `/calendar`:
- Google: POST /google/connect, GET /google/callback, POST /google/disconnect, POST /google/sync/:id
- Outlook: POST /outlook/connect, GET /outlook/callback, POST /outlook/disconnect, POST /outlook/sync/:id
- GET /status — connection status for both providers
- CSRF state tokens with 10-min TTL in Redis
- Encrypted token storage via crypto.js
- Token refresh + rotation on use
- Re-auth flag when refresh token becomes invalid
- Env vars needed: `GOOGLE_CALENDAR_CLIENT_ID/SECRET/REDIRECT_URI`, `OUTLOOK_CALENDAR_CLIENT_ID/SECRET/REDIRECT_URI`, `OUTLOOK_TENANT`

### 11.4 — Team Management

**`token-server/teams.js`** — NEW Express Router mounted at `/teams`:
- POST / (create), GET / (list), GET /:id (details+members), PATCH /:id (update), DELETE /:id (owner-only)
- POST /:id/members (invite), PATCH /:id/members/:mid (role change), DELETE /:id/members/:mid (remove)
- POST /:id/members/accept (accept invitation)
- Role-based access: owner > admin > member
- Fire-and-forget invitation emails via `sendTeamInvitationEmail`

**`token-server/mailer.js`** — Added `sendTeamInvitationEmail(toEmail, {teamName, inviterName})`

**`token-server/index.js`** — Mounted `/calendar` and `/teams` routers

### Migration 016 — DB Schema (applied)
- `teams` table: UUID PK, name (VARCHAR 100), owner_user_id FK→users CASCADE, description (VARCHAR 500), timestamps + update trigger
- `team_members` table: UUID PK, team_id FK→teams CASCADE, user_id FK→users SET NULL, email (VARCHAR 254), role (owner/admin/member), status (pending/active/removed), invited_at, joined_at, UNIQUE(team_id, email)
- Indexes: idx_teams_owner, idx_team_members_team, idx_team_members_user, idx_team_members_email

### Build & Verification
- **Xcode BUILD SUCCEEDED** ✅
- **Server modules load correctly** (verified with dotenv) ✅
- All routers mounted and responding

### Testing Notes
- Auth login returns `accessToken` field (not `token`)
- Calendar OAuth endpoints return 503 until `ENCRYPTION_ACTIVE_VERSION` + `ENCRYPTION_SECRET_V{N}` env vars are configured
- To enable encryption for testing: add `ENCRYPTION_ACTIVE_VERSION=1` and `ENCRYPTION_SECRET_V1=<64-char-hex>` to `.env`
- Generate a key: `node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"`
- Test credentials: `schedtest@test.com` / `vQz9#xL2kP!fWm7R`

## [15 April 2026] — Zoom-Style Offline Session Restore (Signed In But Offline)

**Phase**: Auth resilience
**Files changed**:
- `inter/Networking/InterTokenService.swift` — Added `InterSessionRestoreResult` enum (`.restored`, `.offlineWithPersistedSession`, `.noSession`). Changed `attemptSessionRestore` return from `Bool` to `InterSessionRestoreResult`. Added cached profile UserDefaults keys (`email`, `displayName`, `tier`). Profile cached on login/register and token refresh. `clearAuthState()` clears cached profile. Added `hasPersistedSession` computed property. Added `scheduleSessionRetry()` — 15-second repeating timer that retries token refresh when server becomes reachable, then stops. On `.networkError` during restore, populates in-memory profile from cached UserDefaults.
- `inter/App/AppDelegate.m` — Updated session restore completion handler from `Bool` to `InterSessionRestoreResult` switch. `buildSetupChromeInOverlay:` now recognizes offline-with-session state: shows Sign Out + Settings (gated) + billing buttons with cached tier, plus orange "Name — Offline, reconnecting…" status label. Host/join actions show "Server unreachable — reconnecting…" instead of "Sign in to host" when offline with session. When background retry succeeds, `authSessionDidAuthenticate` fires → `refreshSetupChrome` rebuilds UI to full authenticated state.

**Why**: Previously, if the server was unreachable at launch, the app showed the user as completely logged out (Sign In / Sign Up) even though valid credentials existed in Keychain. This was poor UX — apps like Zoom show "signed in but offline" and silently reconnect.
**Notes**: Background retry fires every 15 seconds. On `.invalidSession` the timer stops and credentials are cleared. On `.success` the timer stops and `authSessionDidAuthenticate` delegate fires, which calls `refreshSetupChrome` to seamlessly transition to authenticated UI. Settings are gated in offline mode since they require server access. Schedule Meeting button hidden in offline mode.

---

## Network Resilience — All 9 Threats from `network_resilience.md`

**Reference**: `network_resilience.md` (276 lines, 9 threats)

### T7: Singleton Refresh Coalescing (CRITICAL)

**Threat**: Multiple concurrent 401s each triggering independent `refreshAccessToken` calls. Server rotates refresh token on each `/auth/refresh`; the second concurrent call presents an already-rotated token → `SESSION_COMPROMISED` → forced re-login.

**Files changed**:
- `inter/Networking/InterTokenService.swift` — Added `isRefreshInFlight` flag, `pendingRefreshCompletions` array, `refreshCoalesceQueue` (serial DispatchQueue), and `drainRefreshCompletions(outcome:originalCompletion:)` method. Modified `refreshAccessTokenWithOutcome` to check `isRefreshInFlight`: if true, queues completion; if false, marks in-flight and proceeds. Replaced all 7 direct `completion(...)` calls with `drainRefreshCompletions` calls.

**Result**: Only one HTTP refresh runs at a time; all concurrent 401s queue their completions and receive the same outcome.

---

### T1: Idempotency Keys (Client + Server)

**Threat**: User clicks "Schedule Meeting", request reaches server, response delayed, client shows error, user clicks again → duplicate server-side execution.

**Files changed**:
- `token-server/idempotency.js` — **NEW FILE**. Redis-backed idempotency middleware. UUID v4 validation, 24hr TTL, scoped by `userId:method:path:key`. Fails open if Redis is down.
- `token-server/index.js` — Applied `requireIdempotencyKey` to `/room/create` and `/billing/checkout-redirect`.
- `token-server/scheduling.js` — Applied to `POST /schedule` and `POST /:id/invite`.
- `token-server/teams.js` — Applied to `POST /` (create team) and `POST /:id/members` (invite).
- `token-server/calendar.js` — Applied to `POST /google/sync/:id` and `POST /outlook/sync/:id`.
- `inter/Networking/InterTokenService.swift` — Added optional `idempotencyKey: String?` parameter to `performAuthHTTPRequest` and `performRequest`. Both inject `X-Idempotency-Key` header and forward on retry. Added `UUID().uuidString` at 6 call sites: `createRoom`, `scheduleMeeting`, `inviteToMeeting`, `syncMeetingToCalendar`, `createTeam`, `inviteToTeam`.

**Result**: 7 server routes protected; 6 client call sites send idempotency keys. Duplicate requests return cached original response.

---

### T6: JWT Auth on Moderation Endpoints

**Threat**: Moderation endpoints (mute, lock, remove, etc.) accessible without authentication — anyone with the URL can call them.

**Files changed**:
- `token-server/index.js` — Added `auth.requireAuth` middleware to all 14 moderation endpoints: promote, mute, mute-all, remove, lock, unlock, suspend, unsuspend, lobby/enable, lobby/disable, admit, admit-all, deny, password.
- `inter/Networking/InterModerationController.swift` — Modified `performPOST` to include `Authorization: Bearer` header from `roomController?.tokenService.currentAccessToken`.

**Result**: All moderation endpoints now require valid JWT. Unauthenticated requests receive 401.

---

### T3: Universal Error Sanitization

**Threat**: Raw `NSError.localizedDescription` or Node.js error strings leaked to UI, exposing internal IPs, stack traces, and routing.

**Files changed**:
- `inter/App/AppDelegate.m` — Changed `userFacingMessageForError:` fallthrough from `error.localizedDescription` to `"Something went wrong. Please try again."` with NSLog of full error. Fixed 8 `setStatusText:` call sites to use safe generic messages. Fixed login/register `showError:` — transport errors (code 1005) show generic message.
- `inter/UI/Views/InterRecordingListPanel.m` — NSAlert text changed from `deleteError.localizedDescription` to `"Could not delete the recording file. Please try again."`
- `inter/Media/InterSurfaceShareController.m` — Replaced `error.localizedDescription` with `"Screen sharing encountered an error."`

**Result**: 13 error leak sites fixed. All user-facing errors are now generic; full errors logged server-side only.

---

### T9: Three-State Circuit Breaker with Exponential Backoff

**Threat**: Simple open/closed circuit breaker permanently disables features after brief disruption. No automatic recovery.

**Files changed**:
- `inter/Networking/InterTokenService.swift`:
  - Added `InterCircuitBreaker` class (private) with `.closed`/`.open`/`.halfOpen` states, `failureThreshold` (3), `shouldAllow()`/`recordSuccess()`/`recordFailure()`/`reset()`.
  - `scheduleRecoveryProbe()` — exponential backoff (2s→4s→8s→16s cap) with ±500ms jitter, transitions to `.halfOpen`.
  - Added `circuitBreaker` property. Integrated into `performRequest` and `performAuthHTTPRequest` — `shouldAllow()` check at entry, `recordSuccess()` on 2xx/<500, `recordFailure()` on transport error and >=500.
  - Added `circuitBreaker.reset()` to `clearAuthState()`.
  - Changed session retry timer from fixed 15s to exponential backoff (5s→10s→20s→40s→60s cap, ±1s jitter). Each `.networkError` increments `sessionRetryAttempt` and schedules next tick with doubled delay.

**Result**: After 3 consecutive failures circuit opens; automatic half-open probes with exponential backoff attempt recovery. Session retry also backs off instead of hammering server every 15s.

---

### T8: Native Task Cancellation (URLSessionDataTask Lifecycle)

**Threat**: In-flight network requests continue running after the owning controller is deallocated. Wasted resources and potential state corruption.

**Files changed**:
- `inter/Networking/InterTokenService.swift`:
  - Added `inflightTasks: Set<URLSessionDataTask>` with `inflightLock: NSLock`.
  - Added `trackTask(_:)`, `untrackTask(_:)`, `cancelPendingRequests()` methods.
  - Added `deinit` — cancels all pending requests and invalidates timers.
  - Integrated tracking into `performRequest`, `performAuthHTTPRequest`, `performAuthenticatedRequest` (including retry path), and 3 standalone dataTask calls (fetchCalendarStatus, fetchTeams, fetchTeamDetails).
  - `clearAuthState()` now calls `cancelPendingRequests()`.
- `inter/Networking/InterModerationController.swift`:
  - Added `inflightTasks: Set<URLSessionDataTask>` with `inflightLock: NSLock`.
  - Added `deinit` — cancels all in-flight tasks and invalidates session.
  - `performPOST` now tracks/untracks task.
- `inter/Media/Recording/InterRecordingCoordinator.swift`:
  - Added `inflightSessions: [URLSession]` with `inflightLock: NSLock`.
  - Updated `deinit` to `invalidateAndCancel()` all tracked sessions.
  - Both `fetchRecordingStatus` and `_performTokenServerRequest` now track/untrack their ephemeral sessions.

**Result**: All URLSessionDataTask instances are tracked and cancelled on owner teardown. No more fire-and-forget network requests.

---

### T2: Button Mashing Prevention — ALREADY COVERED

**Audit result**: Teams, calendar, and scheduling buttons already disable on click (`setEnabled:NO`) before delegate calls and re-enable on completion (`resetCreateButton`, etc.). No changes needed.

---

### T4: Local Queue Manipulation — ALREADY COVERED

**Audit result**: The app never queues state-mutating actions (scheduling, billing, teams) to disk. All network calls hard-fail on error. Only non-critical profile data (email, displayName, tier) cached in UserDefaults for offline UX. API credentials stored in Keychain only. No CoreData, SQLite, or NSKeyedArchiver queuing. No changes needed.

---

### T5: Feature Enumeration via Connectivity Probing — ALREADY COVERED

**Audit result**: UI elements are shown/hidden based on authenticated user role, not live connectivity probes. No changes needed.

---

## [8 May 2026] — Account Management UI + Bug Fixes

**Reference**: `pre_launch_checklist.md` item 3 — "All five backend endpoints are live and tested. The macOS app has no UI surfaces for them yet."

### Account Management — Backend Endpoints (already live, documented here for completeness)
- `POST /auth/change-password` — current + new password, HIBP breach check
- `POST /auth/change-email` — password-verified email change with verification link
- `GET /auth/sessions` — list active refresh token sessions
- `DELETE /auth/sessions/:id` — revoke individual session
- `DELETE /auth/account` — password-verified full account deletion

### `inter/Networking/InterTokenService.swift` — 5 new `@objc` account methods
Added `// MARK: - Account Management` section with:
- `@objc(changePassword:newPassword:completion:) changePassword(currentPassword:newPassword:completion:)` → `POST /auth/change-password`
- `@objc(changeEmail:newEmail:completion:) changeEmail(password:newEmail:completion:)` → `POST /auth/change-email`
- `@objc public func listSessions(completion:)` → `GET /auth/sessions`, returns `[[String: Any]]`
- `@objc(revokeSession:completion:) revokeSession(sessionId:completion:)` → `DELETE /auth/sessions/:id`
- `@objc(deleteAccount:completion:) deleteAccount(password:completion:)` → `DELETE /auth/account`, calls `clearAuthState()` on success
- Explicit `@objc(selector:)` names required because Swift bridges first-argument-labelled methods differently from ObjC

### `inter/UI/Views/InterAccountPanel.h` — NEW FILE
- `InterAccountPanelDelegate` protocol with 5 `@required` methods + 1 `@optional accountPanelDidDeleteAccount:` (panel self-dismisses as fallback)
- `InterAccountPanel` interface with public API: `setEmail:tier:`, `setSessions:`, `setSessionsLoading:`, `showBannerError:`, `clearBanner`

### `inter/UI/Views/InterAccountPanel.m` — NEW FILE
- 460×600 floating window; NSScrollView over 460×780 scrollable content
- 4 sections: Profile (email + change email), Security (change password), Sessions (NSTableView with revoke buttons), Danger Zone (delete account)
- NSNull safety via `_safeString(id)` and `_safeBool(id)` static inline helpers for all JSON field reads in `tableView:viewForTableColumn:row:`
- Both deletion completion paths (sheet modal + runModal fallback) call `[strongSelf.window orderOut:nil]` if delegate doesn't implement `accountPanelDidDeleteAccount:`

### `inter/App/AppDelegate.m` — Wired account panel
- `#import "InterAccountPanel.h"` + `InterAccountPanelDelegate` conformance
- `@property InterAccountPanel *accountPanel` + `@property NSWindow *accountWindow`
- Settings window height 370→410; "Account Settings…" button at `(w-160, 292, 140, 28)`
- `openAccountSettingsWindow` — lazy-creates window, sets email/tier, pre-loads sessions
- All 6 delegate method implementations forwarding to `self.roomController.tokenService`
- `accountPanelDidDeleteAccount:` calls `[self handleLogout]`

### Bug fixes applied during implementation

**Xcode ARC naming error** — Properties starting with `new` trigger ARC ownership convention. Renamed `newPwField`→`updatedPwField`, `newEmailField`→`updatedEmailField`.

**ObjC selector mismatch** — Swift bridges `changePassword(currentPassword:)` as `changePasswordWithCurrentPassword:` not `changePassword:newPassword:`. Fixed with explicit `@objc(changePassword:newPassword:completion:)` etc. on all 4 affected methods.

**`column "created_at" does not exist` on `GET /auth/sessions`** (`token-server/index.js`):
- Root cause: `refresh_tokens` table uses `issued_at` (defined in migration 004), not `created_at`
- Fix: changed SELECT, COALESCE ORDER BY, and response map from `created_at` → `issued_at` (mapped to `createdAt` in JSON response)

**NSNull crash in sessions table** (`InterAccountPanel.m`):
- Root cause: `NSJSONSerialization` deserialises JSON `null` as `[NSNull null]`; `?: @""` doesn't guard because `NSNull` is non-nil
- Fix: added `_safeString()` / `_safeBool()` static inline helpers; all JSON field accesses in `tableView:viewForTableColumn:row:` use them

**HIBP breach error showing "An internal error occurred"** (`token-server/index.js`):
- Root cause 1: `POST /auth/change-password` handler had no `try/catch`, so `checkPwnedPassword`'s `{ status: 400 }` throw fell through to global error handler
- Root cause 2: Global error handler always returned 500 + "An internal error occurred" regardless of `err.status`
- Fix 1: Wrapped entire change-password handler body in try/catch; non-500 errors returned directly
- Fix 2: Global handler now forwards `err.status` + `err.message` for non-500 errors

**`accountPanelDidDeleteAccount:` window stays open if delegate doesn't implement it** (`InterAccountPanel.m`):
- Added `[strongSelf.window orderOut:nil]` fallback at both deletion completion call sites (sheet modal path + runModal path)
- Updated `.h` doc comment to document the fallback behaviour

---

## [8 May 2026] — Code Review Fixes (InterAccountPanel.m)

### Fix 1: Password max-length validation
- **Finding**: `_changePasswordTapped:` only checked `updatedPw.length < 8`; no upper bound matching the "8–72 characters" placeholder. Backend enforces 72-byte bcrypt limit.
- **Fix**: Combined into single condition `updatedPw.length < 8 || updatedPw.length > 72` with message "New password must be between 8 and 72 characters."

### Fix 2: Retain cycle in sheet modal completion block
- **Finding**: `beginSheetModalForWindow:completionHandler:` block captured `self` directly for `showBannerError:`, `deleteAccountButton`, and the `accountPanel:` delegate call. `weakSelf` was declared *inside* the block after direct captures, defeating the purpose.
- **Fix**: Moved `__weak typeof(self) weakSelf = self` to just before `beginSheetModalForWindow:`. Outer block promotes to `strongSelf` immediately and uses it for all three captures. Inner delegate completion re-promotes from the same `weakSelf`. `else`/runModal path untouched — those `self` references are in synchronous method-body code, not inside any block.

### Fix 3: Data race on shared NSISO8601DateFormatter in `_formattedDate:`
- **Finding**: The static `isoFmt` was mutated (`isoFmt.formatOptions = ...`) on the fallback parse path after being initialised in `dispatch_once`, causing a data race on any thread that calls `_formattedDate:` concurrently.
- **Fix**: Replaced single mutable static with two immutable statics (`isoFmtWithFractionalSeconds`, `isoFmtWithoutFractionalSeconds`), both fully configured inside `dispatch_once`. Fallback parse now uses the second formatter instead of mutating the first.

**Build: SUCCEEDED ✅** (verified after each fix)

---

## [8 May 2026] — Calendar-First Scheduling UI Redesign (InterSchedulePanel.m)

### Overview
Replaced the single-pane form layout with a Google Meet / Zoom-style two-pane design: a month-view calendar on the left, a form that slides in from the right when the user clicks a date.

### Changes

**`inter/UI/Views/InterSchedulePanel.m`** — complete rewrite (~768 lines)
- **`_InterCalPane`** (new file-private class):
  - Draws a full month grid (6 × 7 cells) with weekday headers (S M T W T F S) and a thin separator line
  - Today's cell: grey circle background; selected date: blue (`#3380FF`) circle
  - Past dates and other-month dates drawn in dim grey — not clickable (`mouseDown:` rejects past dates)
  - Blue 3.5 px dot rendered below the day number for any date that has a meeting
  - Prev/Next month buttons (`‹` / `›`) and a centred "MMMM yyyy" label
  - `setMeetingDays:(NSSet<NSDate *>*)` refreshes the dot layer
  - Notifies `_InterCalPaneDelegate` with the clicked `NSDate`
- **`InterSchedulePanel`** layout (780 × 700 window):
  - Calendar pane: `(0, 0, 302, 400)`, fixed width, `NSViewMaxXMargin`
  - Vertical `NSBoxSeparator` divider at x = 302
  - Form pane: `(303, 0, W−303, 400)`, `NSViewWidthSizable`, starts `hidden=YES, alphaValue=0`
  - Horizontal `NSBoxSeparator` divider at y = 400
  - Bottom section: "Upcoming Meetings" label + Hosted/Invited `NSSegmentedControl` + scroll table (fills remaining height, `NSViewWidthSizable | NSViewHeightSizable`)
- **Form pane contents**: "New Meeting — EEE, MMM d" header, ✕ dismiss button, time-only `NSDatePicker`, Title field, Duration + Room Type pop-ups (side-by-side), Password, Invite emails, Lobby checkbox, Schedule button, status label
- **Slide-in animation** on date click: `CABasicAnimation` on `transform.translation.x` (18 → 0, 0.22 s EaseOut) + `NSAnimationContext` fade (α 0 → 1, 0.22 s)
- **Date pre-fill**: `calendarPane:didSelectDate:` combines selected calendar day with the current time picker's H:M into the `timePicker.dateValue`
- **Public API unchanged**: `setUpcomingMeetings:`, `setInvitedMeetings:`, `resetForm`, `setStatusText:`, `scheduleButton` property — `AppDelegate` delegate calls unmodified

**`inter/App/AppDelegate.m`** — 2 lines changed
- `panelWidth`: `360` → `780`
- `panelHeight`: `640` → `700`
- `minSize`: `NSMakeSize(320, 480)` → `NSMakeSize(680, 560)`

**Build: SUCCEEDED ✅**

---

## [21 May 2026] — Multi-Pin (Up to 5 Participants) + Stage Layout

### Overview
Expanded host pin-for-all from single participant to up to 5 simultaneous pinned participants. Pinned participants appear in a stage sub-grid; the grid automatically switches to stage mode on the first pin and restores on the last unpin.

### Signal encoding

**`inter/Networking/InterModerationController.swift`**
- Added `@objc public private(set) dynamic var forceSpotlightIdentities: [String] = []` alongside the existing single-identity compat property.
- `forceSpotlight` signal handler now reads `extraData["pinnedList"]` (pipe-separated, e.g. `"id1|id2|id3"`); falls back to legacy `targetIdentity` for single-pin backward compat.
- New API:
  - `addPinnedParticipant(identity:)` — adds to list, no-op if already present or list is full (5)
  - `removePinnedParticipant(identity:)` — removes; calls `clearForceSpotlight()` when list becomes empty
  - `broadcastForcedSpotlightList(_:)` — re-sends DataChannel signal without firing delegate (used for re-broadcast after participant departure)
- Delegate protocol updated: `moderationController(_:forceSpotlightOnParticipants:)` replaces single-identity variant.

### Layout manager

**`inter/UI/Views/InterRemoteVideoLayoutManager.h`**
- Replaced single-key pin API with `setHostForcedSpotlightTileKeys:animated:`.
- Added `hostForcedSpotlightChangedHandler` block property (`(NSArray<NSString *> *) → void`) — fired when the pinned list changes locally (participant departure).
- Added `moderationActionHandler` block property for tile context-menu actions.

**`inter/UI/Views/InterRemoteVideoLayoutManager.m`**
- `hostForcedSpotlightTileKeys` — `NSMutableArray` (max 5) tracking pinned identities.
- `gridWasEnabledBeforePin` — saves grid state so it can be restored when all pins are cleared.
- `InterRemoteVideoTileView` extended with `allPinSlotsUsed: BOOL` property (disables "Pin for All" menu item when 5 are pinned).
- `setHostForcedSpotlightTileKeys:animated:` — manages `isPinnedByHost`/`allPinSlotsUsed` per tile, flips grid↔stage mode, persists `gridWasEnabledBeforePin`.
- `applyMultiPinStageLayoutAnimated:` — new method; renders 2–5 pinned tiles as a sub-grid inside the stage area. Each tile is pre-sized before `addSubview:` to avoid Metal drawable sizing races.
- `applyStageAndFilmstripLayoutAnimated:` — delegates to `applyMultiPinStageLayoutAnimated:` when count > 1.
- Tile context menu: "Pin for All" disabled when `allPinSlotsUsed`; "Unpin for All" shown when `isPinnedByHost`.
- `handleTileClicked:` blocked when any pins are active (stage tiles not user-switchable while host-pinned).

### AppDelegate wiring

**`inter/App/AppDelegate.m`**
- `handleTileModerationAction:forParticipant:` routes `pinForAll` → `addPinnedParticipant:` and `unpinForAll` → `removePinnedParticipant:`.
- `moderationController:forceSpotlightOnParticipants:` → `setHostForcedSpotlightTileKeys:animated:`.
- `moderationControllerDidClearForceSpotlight:` → `setHostForcedSpotlightTileKeys:@[] animated:YES`.
- `hostForcedSpotlightChangedHandler` wired in `wireNormalCallUI…` → `broadcastForcedSpotlightList:` re-sends DataChannel to all remote clients whenever the local pinned list changes.

**Build: SUCCEEDED ✅**

---

## [21 May 2026] — Pinned Participant Departure Fix

### Problem
When a pinned participant left the meeting their stage tile remained visible as a black/frozen frame and the pin slot was never freed.

### Fix

**`inter/UI/Views/InterRemoteVideoLayoutManager.m` — `removeCameraViewForParticipant:`**
- Before removing the camera view, prunes the departed identity from `hostForcedSpotlightTileKeys`.
- Calls `setHostForcedSpotlightTileKeys:pruned animated:YES` to immediately re-render stage (or restore grid if the list is now empty).
- Fires `hostForcedSpotlightChangedHandler([pruned copy])` so `AppDelegate` re-broadcasts the updated pinned list via `broadcastForcedSpotlightList:` to all remaining remote clients.

**Result**: Stage layout reflows instantly when a pinned participant drops. Remote clients also receive the updated list within one DataChannel round-trip.

**Build: SUCCEEDED ✅**

---

## [21 May 2026] — Metal Drawable Black Tile (Two-Pass Fix)

### Root cause
Tiles moving from the filmstrip (small drawable) to the stage sub-grid (large) had `metalLayer.frame` and `metalLayer.drawableSize` still set to filmstrip dimensions when CVDisplayLink fired on its background thread. This caused Metal to vend a drawable at the old small size, which was then stretched/blank over the larger tile frame.

### Fix — Pass 1: Pre-size before addSubview

**`inter/UI/Views/InterRemoteVideoLayoutManager.m` — `applyMultiPinStageLayoutAnimated:`**
- Set `videoView.frame = NSMakeRect(0, 0, pinTileW, pinTileH)` before calling `addSubview:` so `InterRemoteVideoView.layout()` receives the correct target size on the first layout pass.

### Fix — Pass 2: Force synchronous layout

- After `addSubview:`, call `[tile setNeedsLayout:YES]` then `[tile layoutSubtreeIfNeeded]` to run `layout()` synchronously on the main thread before CVDisplayLink can fire.
- Replaced frame-based animation with alpha fade (`tile.alphaValue = 0 → [tile.animator setAlphaValue:1]`) so the tile frame is already at its final size when it becomes visible — no mid-animation size state for CVDisplayLink to race against.

**Result**: Stage tiles always render at the correct resolution immediately; no black frames on promotion from filmstrip.

**Build: SUCCEEDED ✅**

---

## [21 May 2026] — Self-Pin Blank Tile Fix

### Problem
When the host pinned participants 105 and 106, every client received the full pinned list `[105, 106]`. On participant 105's screen, `applyMultiPinStageLayoutAnimated:` looked up `remoteCameraViews[@"105"]` which returned `nil` (local participant has no remote camera view — their feed is the `localSelfTileView` AVCaptureVideoPreviewLayer). The `nil → continue` left that tile slot blank on their own stage while their camera feed continued streaming correctly in the filmstrip "you" tile. Same issue mirrored for participant 106.

### Fix

**`inter/App/AppDelegate.m` — `moderationController:forceSpotlightOnParticipants:`**
- Before passing the pinned list to the layout manager, filter out the local participant's own identity:
  ```objc
  NSString *localId = self.roomController.localParticipantIdentity;
  NSArray<NSString *> *remoteOnly = localId.length
      ? [identities filteredArrayUsingPredicate:
            [NSPredicate predicateWithFormat:@"SELF != %@", localId]]
      : identities;
  [self.normalRemoteLayout setHostForcedSpotlightTileKeys:remoteOnly animated:YES];
  ```
- `hostForcedSpotlightTileKeys` on the layout manager is NOT modified — it still holds the full host-set list for correct re-broadcast.
- The filtering is purely a rendering concern: each client only tries to render tiles for participants it has a remote camera view for.

**Why**: `remoteCameraViews` only contains remote feeds. A participant's own camera is served by `localSelfTileView`, never by a `remoteCameraView` keyed to their own identity. Attempting to render a pinned tile for self always produces a blank slot.

**UX outcome**: 105 sees only 106's feed on stage (1 tile); 106 sees only 105's feed on stage (1 tile); host (104) sees both tiles since neither identity matches their own `localParticipantIdentity`.

**Build: SUCCEEDED ✅**

---

## [31 May 2026] — Mic Unlock Request Flow (Tasks 1–11)

### Overview
Replaced the legacy "Raise Hand to Speak" mic-unlock mechanism with a unified **"Ask to Unmute"** request-approval flow. Under mute-all, participants tap "Ask to Unmute" → host sees a queue panel → approves/denies. Per-tile host mutes use the same queue but approval fully lifts the per-tile restriction (no one-time slot). Raise-hand stays as an intent signal only, decoupled from mic state.

### Signal Layer

**`inter/Networking/InterChatMessage.swift`**
- Added case `.requestMicUnlock = 43` — participant → host: "I'd like to unmute"
- Added case `.approveMicUnlock = 44` — host → participant: "you may unmute"

**`inter/Networking/InterChatController.swift`** — Phase 9 routing
- `requestMicUnlock` and `approveMicUnlock` cases handled in the moderator/participant routing branches
- Both signals routed to `InterModerationController` delegate callbacks

**`inter/Networking/InterModerationController.swift`**
- `requestMicUnlockWithIdentity:` — sends `.requestMicUnlock` DataChannel signal with sender identity
- `approveMicUnlockWithIdentity:` — sends `.approveMicUnlock` DataChannel signal targeting specific participant
- Delegate methods: `moderationControllerReceivedMicUnlockRequest:fromIdentity:displayName:` and `moderationControllerReceivedMicUnlockApproval:`

### Data Model

**`inter/Networking/InterMicUnlockQueue.swift`** — NEW
- `InterMicUnlockEntry`: `participantIdentity`, `displayName`, `timestamp`
- `InterMicUnlockQueue`: ordered array, `addRequest(identity:displayName:)` (silent duplicate drop — F10 mitigation), `removeRequestWithIdentity:`, `reset()`, `count`, `entries`

### Participant State Machine

**`inter/App/InterMediaWiringController.m`** — rewritten `deriveParticipantMicButton` + new flags
- New flags: `micUnlockRequestPending`, `micUnlockApproved`, `micWasUnmutedWhileApproved`, `micUnlockRequestTimer`
- `deriveParticipantMicButton` — 4-priority chain:
  1. `restricted + approved + revoke detected` → "Ask to Unmute" (reset)
  2. `restricted + approved` → normal toggle ("Turn Mic On/Off")
  3. `restricted + pending` → "Request Sent…" (disabled)
  4. `restricted` → "Ask to Unmute" (enabled)
  5. `not restricted` → clear all flags, `setMicrophoneButtonTitle:nil`
- `applyMicUnlockRequestPending` — sets pending flag, starts 30-second safety-net timer (F6 mitigation)
- `applyMicUnlockApproved` — **split into two paths**:
  - `hostMuted && !globalMuteActive` (per-tile): clears `hostMuted=NO` entirely — participant toggles freely, no one-time slot
  - Global mute-all path: sets `micUnlockApproved=YES` — one-time slot with revoke-on-self-mute detection
  - F16 guard: moot approval (restriction already lifted) is a no-op
- `resetMicUnlockFlowState` — clears all flags + timer
- `applyRemoteMicMute` / `applyRemoteMicMuteOne` — both clear all pending unlock state on new mute
- `applyAllowToSpeak` — now a no-op (mic unlock fully handled by new approval flow)

### Host Queue Panel UI

**`inter/UI/Views/InterMicUnlockQueuePanel.h/.m`** — NEW
- `InterMicUnlockEntry`-backed `NSTableView` with participant name + "Approve" and "Dismiss" per-row buttons
- "Approve All" and "Dismiss All" header buttons
- `InterMicUnlockQueuePanelDelegate` protocol
- Floating dark panel matching existing moderation panels

### AppDelegate Wiring

**`inter/App/AppDelegate.m`**
- Mic button handler: restricted path routes through request flow; approved path calls `twoPhaseToggleMicrophone`; [R3] guard blocks "unmute" when host has disabled it and mic is network-muted
- F1 filter in `receivedMicUnlockRequest:`: discards requests from participants who are neither globally muted (`isAllMuted`) nor in `hostMutedParticipants` — prevents queue spam from unrestricted participants
- `moderationControllerReceivedMicUnlockApproval:` → `[normalMediaWiring applyMicUnlockApproved]`
- `moderationControllerReceivedMuteOneRequest:` → `applyRemoteMicMuteOne` (cancel queue on new mute — Task 10)
- Full `InterMicUnlockQueuePanelDelegate` implementation: approve single, deny single, approve all, deny all

### Token Server — Redis Persistence

**`token-server/index.js`**
- `roomMicLockedKey(roomCode)` helper → `room:{code}:mic-locked`
- `POST /room/mute`: atomic `redis.multi().sadd().expire().exec()` adds identity to locked set (F7 mitigation — atomic with TTL)
- `POST /room/mic-lift-one`: `SREM` removes identity from locked set
- `GET /room/mic-locked`: returns locked identities (full set for moderators, self-only for participants)
- Try/catch on all Redis ops (F17 mitigation)

### Snapshot Restore

**`inter/App/AppDelegate.m` — `fetchMicLockedSnapshot`**
- On call join: `GET /room/mic-locked` → applies `applyRemoteMicMuteOne` for self if in set, sets `setHostMuted:YES` badge for remote participants
- Populates `hostMutedParticipants` from snapshot for correct F1 filter state on rejoin

### Paranoid Mitigations Verified
| ID | Mitigation | Location |
|----|-----------|----------|
| F1 | Discard requests from non-restricted senders | `AppDelegate.m receivedMicUnlockRequest:` |
| F6 | 30-second safety-net timer clears pending state | `applyMicUnlockRequestPending` |
| F7 | Atomic `SADD + EXPIRE` in single Redis transaction | `token-server/index.js POST /room/mute` |
| F10 | Silent duplicate drop in `addRequest:` | `InterMicUnlockQueue.swift` |
| F16 | Moot approval guard in `applyMicUnlockApproved` | `InterMediaWiringController.m` |
| F17 | Try/catch on all Redis mic-lock ops | `token-server/index.js` |

**Commits**: `8081347`, `e1f5172`, `a9a1654`, `981fb1b`, `82238c0`, `28528fa`, `baa8360`, `c7855e2`, `3fefd40`, `de64627`, `1da4c9b`
**Build: SUCCEEDED ✅**

---

## [31 May 2026] — Bug Fix: Per-Tile Mic Unlock Approval Shows "Ask to Unmute" After Self-Mute

### Problem
After the host approved a per-tile mic unlock request, when the participant self-muted, the button reverted to "Ask to Unmute" instead of staying as a normal toggle — as if their approval had been revoked.

### Root Cause
`applyMicUnlockApproved` set `micUnlockApproved=YES` while leaving `hostMuted=YES`. When the participant self-muted after using the slot, the revoke-detection branch in `deriveParticipantMicButton` (`micWasUnmutedWhileApproved && isMicNetworkMuted`) fired and reset to "Ask to Unmute" — even though the approval should have permanently lifted the per-tile restriction.

### Fix (`inter/App/InterMediaWiringController.m`)
Split `applyMicUnlockApproved` into two paths:
- **Per-tile path** (`hostMuted=YES && globalMuteActive=NO`): clears `hostMuted=NO`, resets all unlock flags — participant is permanently unrestricted; revoke detection cannot fire
- **Global mute-all path** (`globalMuteActive=YES`): retains one-time slot semantics with revoke detection

**Commit**: `092cb21` | **Build: SUCCEEDED ✅**

---

## [31 May 2026] — Bug Fix: Per-Tile Camera Unlock Approval — Stale Badge + Revoke

### Problem
After the host approved a per-tile camera unlock request, the participant's tile still showed the "camera locked" badge on the host side, and the participant saw the "Ask to Unlock Camera" button reappear after turning their camera off — same one-time-slot semantics applied incorrectly to per-tile camera mutes.

### Root Cause
1. `applyHostCameraApprovalForParticipant` left `isHostCameraLocked=YES` (wrong — per-tile approval should lift the lock entirely)
2. `cameraUnlockQueuePanel:didApproveParticipant:` sent `approveCameraUnlock` signal (wrong) instead of `liftCameraLockOneWithIdentity:`, never called `setIsHostCameraLocked:NO` on the host tile, and never removed from Redis

### Fix
- `applyHostCameraApprovalForParticipant` (`InterMediaWiringController.m`): now clears `isHostCameraLocked=NO` and resets all camera unlock flags — mirrors the per-tile mic fix
- `cameraUnlockQueuePanel:didApproveParticipant:` (`AppDelegate.m`): now calls `liftCameraLockOneWithIdentity:` + `setIsHostCameraLocked:NO` tile update + `persistCameraLock:NO` Redis removal
- `cameraUnlockQueuePanelDidApproveAll:` (`AppDelegate.m`): same pattern applied to batch approval

**Commit**: `064001e` | **Build: SUCCEEDED ✅**

---

## [31 May 2026] — Bug Fix: Race Condition — Mute-All + Per-Tile + Approval Corrupts F1 Filter

### Problem (exact scenario)
1. Host enables mute-all → participant sees "Ask to Unmute"
2. Host per-tile mutes the same participant (`hostMuted=YES`, `globalMuteActive=YES`)
3. Participant sends request → host approves (global mute-all path: one-time slot)
4. Participant uses slot then self-mutes → revoke fires → "Ask to Unmute"
5. Host lifts mute-all (`globalMuteActive=NO`) — `hostMuted=YES` remains
6. Participant taps "Ask to Unmute" → sends request → **host never sees it**
7. Button stuck on "Ask to Unmute" with no request sent

### Root Cause
`micUnlockQueuePanel:didApproveParticipant:` unconditionally called `[hostMutedParticipants removeObject:identity]`. When `isAllMuted=YES` the approval is a one-time slot — the per-tile restriction (`hostMuted=YES`) survives. Removing from `hostMutedParticipants` poisoned the F1 filter: after mute-all lifted, F1's check (`!isAllMuted && !inHostMutedParticipants`) became `true` and silently dropped every subsequent request.

### Fix (`inter/App/AppDelegate.m`)
Gated the `hostMutedParticipants` removal and tile-badge clear on `!isAllMuted`:
- When `isAllMuted=YES` at approve time: send the signal, keep `hostMutedParticipants` intact, keep tile badge — one-time slot granted, per-tile restriction survives
- When `isAllMuted=NO` at approve time: previous behaviour, full per-tile state cleared
- Same guard added to `micUnlockQueuePanelDidApproveAll:` (`muteAllActive` captured once before the loop for consistent batch treatment)

**Commit**: `1ccb3d1` | **Build: SUCCEEDED ✅**

---

## [1 June 2026] — Bug Fix: Stale "Raise Hand to Speak" Traces

### Problem
When mute-all was active and the host clicked "Unmute Mic" from a participant's per-tile context menu, the participant's UI showed "✋ Raise Hand to Speak" instead of the correct "Ask to Unmute" or unlock slot button.

### Root Cause (three related issues)
1. **`chatController:participantDidLowerHand:`** — stale Phase 8 block directly set `"✋ Raise Hand to Speak"` on the mic button whenever `globalMuteActive=YES && !speakPermissionGranted`. This fired because the tile "Unmute Mic" path (and the speaker-queue "Allow" path) both sent `lowerHandForParticipant:` as a side-effect.
2. **Tile "Unmute Mic" during mute-all** — called `allowToSpeakWithIdentity:` which was neutered to a no-op in Phase 9. Its only live effect was emitting the `lowerHand` DataChannel signal, which triggered the stale override above.
3. **Speaker queue "Allow" button** — same `allowToSpeakWithIdentity:` no-op + `lowerHand` trigger.

### Fix (`inter/App/AppDelegate.m`)
- `chatController:participantDidLowerHand:` — removed the mic button override entirely. The raise-hand button title is still reset; mic button state is managed exclusively by `deriveParticipantMicButton`
- Tile "Unmute Mic" during mute-all — replaced `allowToSpeakWithIdentity:` with `approveMicUnlockWithIdentity:`: sends the proper Phase 9 approval signal; participant's `applyMicUnlockApproved` takes the global-mute path (one-time slot)
- Speaker queue "Allow" — same replacement: raise-hand approval now grants a mic unlock slot through the new flow

**Commit**: `f6ed039` | **Build: SUCCEEDED ✅**

