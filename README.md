# Inter

A native macOS video conferencing application built for teams and technical interviews. Inter runs entirely on your Mac — no browser, no Electron — with a dedicated backend for room management, scheduling, recording, and team collaboration.

---

## Table of Contents

- [Overview](#overview)
- [Feature Highlights](#feature-highlights)
- [Requirements](#requirements)
- [Getting Started](#getting-started)
- [User Flows](#user-flows)
  - [Hosting a Call](#hosting-a-call)
  - [Joining a Call](#joining-a-call)
  - [Interview Mode](#interview-mode)
  - [Screen Sharing](#screen-sharing)
  - [In-Meeting Communication](#in-meeting-communication)
  - [Meeting Moderation](#meeting-moderation)
  - [Recording](#recording)
  - [Scheduling](#scheduling)
  - [Teams](#teams)
- [Backend Setup](#backend-setup)
- [Environment Variables](#environment-variables)
- [Database Migrations](#database-migrations)
- [Authentication & Tiers](#authentication--tiers)
- [Testing](#testing)
- [Project Structure](#project-structure)

---

## Overview

Inter is a macOS-native video conferencing platform designed around two primary use cases:

1. **Team calls** — standard multi-participant video meetings with chat, polls, Q&A, and recording.
2. **Technical interviews** — a dedicated secure mode where the candidate's workspace and tools are isolated from the interviewer's view, preventing content bleed into the video stream.

The app runs as a sandboxed macOS application (Objective-C + Swift) paired with a Node.js token/signalling server, PostgreSQL for persistent data, and Redis for ephemeral room state.

---

## Feature Highlights

### Video & Audio
- Up to **50 participants** per room
- Adaptive video quality — layout and resolution automatically adjust to the number of visible participants
- Two-phase camera and microphone toggles (eliminates frozen/black frames on mute)
- **Microphone toggle does not interrupt the camera feed** — audio and video paths are fully decoupled

### Screen Sharing
- Share your **entire screen** or a **specific window** (visual picker with live thumbnails)
- Optional **system audio** capture alongside screen content
- Screen share in interview mode uses a secure capture path that only streams designated tool surfaces — no accidental leaks of other windows

### In-Meeting Communication
- **Public chat** — persistent in-meeting text chat with full transcript export
- **Direct messages** — private 1:1 messages to any participant
- **Raise hand + speaker queue** — participants raise their hand; host sees an ordered queue and can grant the floor one at a time
- **Hard-mute + speak permission** — host can mute all participants; muted participants must raise their hand and receive explicit permission to unmute (one-time grant)
- **Live polls** — host creates single or multi-select polls; results update in real time for all participants
- **Q&A board** — participants submit questions (optionally anonymous); others upvote; host can highlight, mark as answered, or dismiss

### Layout
- Adaptive grid (1×1 through 5×5) scales with participant count
- Stage + filmstrip layout when screen sharing is active
- Click any tile to spotlight it to the main stage
- Active speaker highlighted with a green border
- Auto-spotlight mode: most recent active speaker is automatically promoted to the main stage

### Participant Management & Moderation
- **Roles**: Host, Co-Host, Presenter, Panelist, Participant — each with distinct permission sets
- **Lobby / waiting room** — host approves each entrant individually, or admits all at once
- **Meeting password** — optional access code set by the host
- **Lock meeting** — prevent new participants from joining mid-call
- **Mute / remove participants**
- **Suspend participant** — temporarily restricts a participant without removing them
- **Promote participants** — elevate any participant to Co-Host or Presenter in real time
- **Disable chat** — host can suppress all participant chat messages

### Recording
- **Local recording** — composed MP4 saved to `~/Documents/Inter Recordings/`
  - Grid layout for 3+ participants, filmstrip sidebar when screen share is active, watermark for free-tier users
  - Disk space monitor — automatically stops recording if free space drops below 500 MB
  - Orphaned file cleanup on startup (crash recovery)
- **Cloud recording** — single composed stream uploaded to S3 via egress
- **Multi-track recording** — per-participant egress stored separately with a manifest JSON for post-processing
- **Recording management panel** — view, open, download (cloud), or delete past recordings from within the app
- **New joiner consent dialog** — participants who join after recording has started see a consent overlay before their video is included

### Meeting Scheduling
- Create scheduled meetings with title, date/time, duration, room type (call or interview), optional password, and lobby settings
- Invite participants by email — invitees receive a calendar invitation with an `.ics` attachment
- View upcoming hosted and invited meetings from the schedule panel
- Join a scheduled meeting directly from the panel — no copy-pasting room codes required
- **Apple Calendar integration** — scheduled meetings are automatically added to and removed from your macOS Calendar
- **Google Calendar integration** — OAuth 2.0 sync; meeting events created, updated, and deleted automatically
- **Outlook Calendar integration** — OAuth 2.0 sync via Microsoft Graph

### Teams
- Create named teams with a description
- Invite members by email; invitees receive an email and can accept from within the app
- Role-based team management: Owner, Admin, Member
- Owners can rename, update, or delete teams; Admins can manage members

### Security & Auth
- JWT-based authentication (access token + refresh token)
- OAuth login support
- Keychain-backed token storage on macOS
- Tier-gated features: free, pro, and hiring tiers control recording capabilities, poll limits, and other premium features
- Room codes: 6-character alphanumeric codes with 24-hour expiry, confusable characters excluded
- All OAuth tokens stored encrypted at rest (AES-256-GCM with key versioning)

---

## Requirements

- **macOS 13 Ventura or later** (ScreenCaptureKit is required for screen sharing and window picker)
- **Xcode 16+** to build the macOS app
- **Node.js 20+** for the backend server
- **PostgreSQL 15+**
- **Redis 7+**
- A LiveKit-compatible WebRTC server (self-hosted or managed) accessible from your network

---

## Getting Started

### 1. Clone the repository

```bash
git clone https://github.com/your-org/inter.git
cd inter
```

### 2. Install backend dependencies

```bash
cd token-server
npm install
```

### 3. Configure environment variables

Copy the example env file and fill in your values:

```bash
cp .env.example .env
```

See [Environment Variables](#environment-variables) for a full reference.

### 4. Run database migrations

```bash
node migrate.js
```

### 5. Start the backend server

```bash
node index.js
```

The server starts on port `3000` by default. Verify with:

```bash
curl http://localhost:3000/health
```

A healthy response looks like:

```json
{
  "status": "ok",
  "redis": "connected",
  "postgres": "connected"
}
```

### 6. Build the macOS app

Open `inter.xcodeproj` in Xcode, select the **inter** scheme, and press **⌘R** to build and run.

On first launch the app presents a connection setup panel where you enter your server URL and token server URL.

---

## User Flows

### Hosting a Call

1. Sign in or continue as guest from the setup panel.
2. Click **Host Call** (normal mode) or **Host Interview** (secure interview mode).
3. The app generates a unique 6-character room code and displays it prominently.
4. Share the room code with participants — they enter it to join.
5. Use the control panel to toggle camera, microphone, screen sharing, and system audio at any time during the call.
6. End the call with the **Leave** button; the room code expires 24 hours after creation.

### Joining a Call

1. Obtain a room code from the host.
2. Enter the code in the **Room Code** field on the setup panel.
3. Click **Join** — the app validates the code and connects you to the room.
4. If the host has enabled the lobby, you will wait in a waiting room until the host admits you.
5. If the room is password-protected, you will be prompted to enter the password.

### Interview Mode

Interview mode is a dedicated secure mode designed for technical hiring:

- The interviewer's screen is a **secure window** — its contents are never captured or leaked into the outgoing video stream, regardless of what screen sharing is active.
- A **secure tool rail** on the right side of the screen provides access to the code editor and whiteboard surfaces. Only the content of these tools is shared with the candidate.
- The candidate sees only the designated tool surface, not any other interviewer windows, browser tabs, or other application content.
- When a candidate joins a room that was hosted as an Interview room, they are prompted to confirm their role before entering.

### Screen Sharing

1. Click the **Share** button in the control panel.
2. Choose a share mode:
   - **Full Screen** — shares your entire display.
   - **Window** — opens a visual picker showing all available windows with live thumbnails. Click a window to select it, then click **Share**.
3. Toggle **Share System Audio** to include desktop audio in the shared stream.
4. Click **Stop Sharing** to end the screen share.

### In-Meeting Communication

**Chat**
- Open the chat panel with the 💬 button or **⌘⇧C**.
- Type a message and press Enter or click **Send**.
- To send a direct message, select the recipient from the dropdown above the input field.
- Use the **Export** button to save the full transcript as a JSON or plain-text file.

**Raise Hand / Speaker Queue**
- Click ✋ to raise your hand. The button changes to indicate your hand is raised.
- The host sees a speaker queue panel (📋) listing raised hands in chronological order.
- The host can allow individual participants to unmute, or dismiss hands from the queue.
- A host can mute all participants at once; participants in hard-mute mode must raise their hand and receive an explicit allow signal before they can unmute.

**Live Polls**
- Host: click 📊 to open the poll panel. Enter a question and up to 10 answer options. Choose anonymous and/or multi-select options and click **Launch**.
- Participants: vote using the radio buttons or checkboxes that appear automatically.
- Results update in real time for everyone. The host can share results to all participants, then end the poll and start a new one.

**Q&A Board**
- Click ❓ to open the Q&A panel.
- Type a question and optionally check **Ask anonymously** before clicking **Ask**.
- Upvote other participants' questions with the ▲ button.
- Host moderation: pin questions (📌), mark as answered (✅), or dismiss (✕).

### Meeting Moderation

1. The ⚙️ **Moderate** button appears in the control panel for hosts and co-hosts.
2. Clicking it opens a menu with:
   - **Mute All** — hard-mutes all participants simultaneously.
   - **Disable / Enable Chat** — suppresses or restores participant messaging.
   - **Lock / Unlock Meeting** — prevents anyone new from joining.
   - **Set Password / Remove Password** — adds or removes the room password on the fly.
3. The 🚪 **Lobby** button opens the waiting room panel where the host can admit or deny individual participants, or click **Admit All**.
4. To promote a participant, right-click their tile or use the participant list — available roles are Co-Host, Presenter, and Panelist.

### Recording

**Starting a recording**

1. Click **Start Recording** in the control panel. Available recording modes depend on your tier:
   - **Local** — recorded and saved on your Mac (all tiers; free tier adds a watermark).
   - **Cloud** — composed stream uploaded to your configured S3 bucket (Pro / Hiring tier).
   - **Multi-track** — per-participant streams stored separately (Hiring tier).
2. A red dot indicator appears in the control panel while recording is active.
3. New participants who join during a recording see a consent overlay and can choose to accept or leave the meeting.

**Stopping and accessing recordings**

1. Click **Stop Recording** to end the session.
2. Click 📁 **Recordings** to open the recording list panel.
3. From the panel you can:
   - **Open** a local recording directly in QuickTime (or any associated player).
   - **Download** a cloud recording (opens the presigned URL in your browser).
   - **Delete** a recording (with confirmation).

### Scheduling

1. Click **Schedule Meeting** on the setup screen (requires sign-in).
2. Fill in the meeting details: title, date and time, duration, room type, optional password, and lobby preference.
3. Add invitee emails in the **Invite** field (comma-separated). Invitees receive an email with an `.ics` calendar file.
4. If calendar access is granted, the meeting is automatically added to your macOS Calendar.
5. To enable Google or Outlook sync, visit your account settings and connect the respective calendar provider via OAuth.

**Joining a scheduled meeting**

1. Open the **Schedule Meeting** panel.
2. Your upcoming hosted and invited meetings are listed under their respective tabs.
3. Click **Join** on any meeting — the app connects you directly without requiring a room code.

### Teams

1. Go to the **Teams** section in the app or use the backend API.
2. Create a new team with a name and optional description.
3. Invite members by email — they receive an invitation email.
4. Invited members click **Accept Invitation** in the app to join the team.
5. Team owners and admins can change member roles or remove members at any time.
6. Owners can delete the team entirely.

---

## Backend Setup

The `token-server/` directory contains the Node.js Express server. It manages:

- Room creation and join validation
- JWT issuance and refresh
- User authentication and registration
- Meeting scheduling and invitations
- Calendar OAuth (Google + Outlook)
- Recording session tracking (local metadata, cloud egress, multi-track manifests)
- Team management
- Redis-backed ephemeral room state (24-hour TTL)
- PostgreSQL for all persistent data

### Starting the server

```bash
cd token-server
node index.js
```

For development with auto-reload:

```bash
npx nodemon index.js
```

### Health check

```
GET /health
```

Returns `200 OK` with Redis and PostgreSQL connection status. Returns `503` if either dependency is unavailable.

---

## Environment Variables

Create `token-server/.env` based on `token-server/.env.example`:

| Variable | Description |
|---|---|
| `PORT` | HTTP port (default: `3000`) |
| `DATABASE_URL` | PostgreSQL connection string (e.g. `postgresql://localhost:5432/inter_dev`) |
| `REDIS_URL` | Redis connection string (e.g. `redis://localhost:6379`) |
| `LIVEKIT_API_KEY` | API key for your WebRTC server |
| `LIVEKIT_API_SECRET` | API secret for your WebRTC server |
| `LIVEKIT_SERVER_URL` | WebSocket URL of your WebRTC server (e.g. `ws://localhost:7880`) |
| `LIVEKIT_HTTP_URL` | HTTP URL of your WebRTC server for room management API |
| `JWT_SECRET` | Secret for signing access tokens |
| `REFRESH_TOKEN_SECRET` | Secret for signing refresh tokens |
| `SMTP_HOST` | SMTP server hostname |
| `SMTP_PORT` | SMTP server port (default: `587`) |
| `SMTP_USER` | SMTP authentication username |
| `SMTP_PASS` | SMTP authentication password |
| `FROM_EMAIL` | Sender address for outgoing emails |
| `GOOGLE_CALENDAR_CLIENT_ID` | Google OAuth 2.0 client ID |
| `GOOGLE_CALENDAR_CLIENT_SECRET` | Google OAuth 2.0 client secret |
| `GOOGLE_CALENDAR_REDIRECT_URI` | OAuth callback URL for Google |
| `OUTLOOK_CALENDAR_CLIENT_ID` | Microsoft Azure app client ID |
| `OUTLOOK_CALENDAR_CLIENT_SECRET` | Microsoft Azure app client secret |
| `OUTLOOK_CALENDAR_REDIRECT_URI` | OAuth callback URL for Outlook |
| `OUTLOOK_TENANT` | Azure AD tenant ID (use `common` for multi-tenant) |
| `AWS_REGION` | AWS region for S3 cloud recording storage |
| `AWS_ACCESS_KEY_ID` | AWS access key (cloud recording) |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key (cloud recording) |
| `S3_BUCKET` | S3 bucket name for cloud recordings |
| `ENCRYPTION_ACTIVE_VERSION` | Key version number for OAuth token encryption (e.g. `1`) |
| `ENCRYPTION_SECRET_V1` | 64-character hex key for version 1 token encryption |

Generate an encryption key:

```bash
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
```

---

## Database Migrations

Migrations are plain `.sql` files in `token-server/migrations/` and are applied in lexicographic order. The migration runner tracks which migrations have been applied in a `schema_migrations` table — re-running is safe and idempotent.

```bash
cd token-server
node migrate.js
```

Current migrations:

| File | Contents |
|---|---|
| `001_initial_schema.sql` | `users`, `meetings`, `meeting_participants` tables |
| `002_recording_sessions.sql` | `recording_sessions` table, billing/tier columns |
| `003_multitrack_tracks.sql` | `recording_tracks` table, `manifest_url` column |
| `015_scheduling.sql` | `scheduled_meetings`, `meeting_invitees` tables |
| `016_calendar_teams.sql` | Calendar OAuth columns on `users`; `teams`, `team_members` tables |

---

## Authentication & Tiers

The server uses JWT access tokens (short-lived) and refresh tokens (long-lived, stored in the macOS Keychain on the client). All protected endpoints require a valid `Authorization: Bearer <token>` header.

Three user tiers control feature access:

| Tier | Recording | Polls | Cloud Recording | Multi-track | Watermark |
|---|---|---|---|---|---|
| **free** | Local only | 3 per meeting | ✗ | ✗ | ✓ (applied) |
| **pro** | Local + Cloud | Unlimited | ✓ | ✗ | ✗ |
| **hiring** | All modes | Unlimited | ✓ | ✓ | ✗ |

---

## Testing

The Xcode project includes a full unit and integration test suite in the `interTests/` target.

**Run all tests from the command line:**

```bash
xcodebuild test \
  -scheme inter \
  -destination 'platform=macOS' \
  | xcpretty
```

**Run only unit tests** (no live servers needed):

Most tests use `URLProtocol` mocks and in-process stubs and run without any external dependencies.

**Run integration tests:**

Integration tests connect to live local server and WebRTC server instances. If either server is unreachable, integration tests skip gracefully with `XCTSkip` rather than failing.

Current test count: **140 tests, 0 failures** (as of last recorded build).

Test files and their coverage:

| File | What it tests |
|---|---|
| `InterTokenServiceTests.swift` | Auth token fetch, caching, HTTP error mapping |
| `InterLiveKitAudioBridgeTests.swift` | Audio bridge lifecycle, buffer safety, performance |
| `InterLiveKitCameraSourceTests.swift` | Camera source state, frame counters |
| `InterLiveKitScreenShareSourceTests.swift` | Screen share lifecycle, FPS throttle |
| `InterLiveKitPublisherTests.swift` | Track publish/unpublish, mute toggles |
| `InterLiveKitSubscriberTests.swift` | Subscriber state, detach safety |
| `InterRoomControllerTests.swift` | Full room lifecycle, KVO, mode transitions |
| `InterRemoteVideoViewTests.swift` | Aspect fit, NV12/BGRA rendering, GPU readback |
| `InterIsolationTests.swift` | G8 isolation invariant — networking is always side-effect-free |
| `InterIntegrationTests.swift` | End-to-end call lifecycle between two real room controllers |
| `InterRecordingCoordinatorTests.swift` | Recording state machine, disk space, concurrency |
| `InterRecordingEngineTests.swift` | Recording pipeline lifecycle, PTS monotonicity |
| `InterComposedRendererTests.swift` | Layout selection, thread-safe frame updates, watermark |

---

## Project Structure

```
inter/
├── App/                        # Application entry point and main coordinator
│   ├── AppDelegate.m/.h        # App lifecycle, window management, feature wiring
│   ├── InterAppSettings        # User preferences
│   ├── InterCalendarService    # Apple Calendar (EventKit) integration
│   └── InterMediaWiringController  # Shared media + network state coordinator
│
├── Networking/                 # Swift networking layer
│   ├── InterNetworkTypes       # Shared types: configuration, state enums, error codes
│   ├── InterTokenService       # Auth, room token fetch, scheduling API client
│   ├── InterRoomController     # Room lifecycle owner (connect, disconnect, mode transitions)
│   ├── InterLiveKitPublisher   # Local track publishing (camera, mic, screen share)
│   ├── InterLiveKitSubscriber  # Remote track subscription and routing
│   ├── InterLiveKitAudioBridge # Audio capture bridge
│   ├── InterLiveKitCameraSource     # Camera capture source
│   ├── InterLiveKitScreenShareSource # Screen share capture source
│   ├── InterRemoteVideoView    # Metal-based remote video renderer (NV12 + BGRA)
│   ├── InterCallStatsCollector # Call quality metrics (circular buffer, JSON export)
│   ├── InterChatController     # In-meeting chat and control signals
│   ├── InterSpeakerQueue       # Raise-hand queue management
│   ├── InterPollController     # Live poll lifecycle
│   ├── InterQAController       # Q&A board lifecycle
│   ├── InterModerationController  # Role-based moderation actions
│   └── InterPermissions        # Permission matrix per role
│
├── Media/                      # Local media capture pipeline
│   ├── InterLocalMediaController   # Camera and mic capture session
│   ├── InterSurfaceShareController # Screen/window share routing
│   ├── Sharing/                    # Share sources, sinks, types, protocols
│   └── Recording/                  # Recording engine, composed renderer, audio capture
│
├── Rendering/                  # Metal GPU rendering
│   ├── MetalRenderEngine       # Shared Metal device and command queue
│   └── MetalSurfaceView        # Local preview rendering surface
│
├── UI/
│   ├── Controllers/
│   │   ├── SecureWindowController  # Secure interview mode window
│   │   └── SecureWindow            # NSWindow subclass with sharing restrictions
│   └── Views/
│       ├── InterConnectionSetupPanel        # Connection form (server URL, room code)
│       ├── InterLocalCallControlPanel       # In-call toolbar (camera, mic, share, etc.)
│       ├── InterRemoteVideoLayoutManager    # Adaptive grid, filmstrip, spotlight layout
│       ├── InterRemoteVideoView (via Networking) # Remote video tile view
│       ├── InterParticipantOverlayView      # Waiting/presence overlay
│       ├── InterNetworkStatusView           # Signal strength bars
│       ├── InterTrackRendererBridge         # ObjC adapter for Swift renderer protocol
│       ├── InterChatPanel                   # Chat side panel
│       ├── InterSpeakerQueuePanel           # Raised-hand queue panel (host)
│       ├── InterPollPanel                   # Live poll create/vote/results panel
│       ├── InterQAPanel                     # Q&A board panel
│       ├── InterLobbyPanel                  # Waiting room management panel
│       ├── InterWindowPickerPanel           # Screen share window selector
│       ├── InterSchedulePanel               # Meeting scheduler + upcoming list
│       ├── InterRecordingListPanel          # Past recordings browser
│       └── InterRecordingConsentPanel       # New-joiner recording consent overlay
│
token-server/
├── index.js            # Express app, router mounting, health check
├── db.js               # PostgreSQL connection pool
├── redis.js            # Redis client
├── auth.js             # JWT middleware and auth routes
├── billing.js          # Subscription and tier management
├── scheduling.js       # Meeting scheduling API
├── calendar.js         # Google + Outlook calendar OAuth and sync
├── teams.js            # Team management API
├── mailer.js           # Email sending (invitations, team invites)
├── crypto.js           # AES-256-GCM encryption for OAuth tokens
├── migrate.js          # Sequential SQL migration runner
└── migrations/         # Ordered .sql migration files

interTests/             # Xcode unit and integration test target
```

---

## License

[Add your license here]

---

## Contributing

[Add your contributing guidelines here]
