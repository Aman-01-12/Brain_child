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

