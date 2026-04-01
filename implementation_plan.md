# Inter — Implementation Plan (Phases 6–14)

> **Architect**: Senior SDLC Plan  
> **Date**: 26 March 2026  
> **Baseline**: Phases 0–5A complete. 138 tests passing. 4-participant cap. Token server in-memory.  
> **Reference**: `new_feature.md` (feature strategy), `tasks.txt` (Phases 0–5), `work_done.md` (changelog)  
> **Principle**: Each phase is a shippable increment. No phase breaks existing functionality.

---

## Infrastructure Status

| Service        | Version | Status    | Connection                          |
|:-------------- |:------- |:--------- |:----------------------------------- |
| PostgreSQL     | 15.13   | Running   | `psql -d inter_dev` (localhost:5432)|
| Redis          | 8.6.2   | Running   | `redis-cli` (localhost:6379)        |
| LiveKit Server | 1.9.11  | Available | `ws://localhost:7880`               |
| Token Server   | 1.0.0   | Available | `http://localhost:3000`             |

---

## Feasibility Assessment

Every feature from `new_feature.md` has been evaluated against the current codebase. Here's the honest assessment:

### Immediately Feasible (we have the infrastructure)

| Feature | Why Feasible | Risk |
|:--------|:-------------|:-----|
| Redis migration (token-server) | Drop-in replacement for in-memory Maps. `ioredis` + TTL replaces manual cleanup. | Low — 1 file change. |
| PostgreSQL schema | Standard relational modeling. `pg` npm driver is mature. | Low — new code, no existing breakage. |
| Raise participant cap (4→50) | LiveKit SFU handles this natively. Only change is `MAX_PARTICIPANTS_PER_ROOM` constant + UI grid layout. | Medium — UI layout at 50 tiles needs adaptive grid. |
| In-Meeting Chat (public) | LiveKit `DataChannel` API exists (`room.localParticipant.publish(data:)` / `room.delegate.didReceive(data:)`). Pure additive. | Low — new UI panel + data channel. |
| Raise Hand (basic queue) | Participant metadata update via LiveKit (`participant.metadata`). Chronological array. | Low — metadata + new UI element. |
| Active Speaker Detection | **Already implemented** (`activeSpeakersChanged` delegate in `InterLiveKitSubscriber`). Needs UI highlight wiring. | Very Low — mostly UI work. |
| Roles & Permissions | JWT metadata already stamps `role` (interviewer/interviewee). Extend to host/co-host/presenter. Server-authoritative. | Low — extend existing pattern. |

### Feasible with Moderate Effort

| Feature | Why | Risk |
|:--------|:----|:-----|
| Lobby / Waiting Room | Token server holds participant; LiveKit `roomJoin` grant withheld until host admits. | Medium — new server endpoint + client UI. |
| Advanced Moderation (Mute All) | LiveKit `roomAdmin` grant allows remote mute via server API. Client needs admin panel. | Medium — server-side LiveKit API call. |
| Local Recording (composed layout) | macOS has `AVAssetWriter` + Metal compositing. We have `MetalRenderEngine`. Needs frame-accurate compositing pipeline. | Medium-High — new recording pipeline. Previous one was removed (PF.6). |
| DMs (in-meeting) | LiveKit `DataChannel` supports targeted publish (specific participant SID). | Low-Medium — extend chat system. |
| Chat Transcript Save | Write chat array to JSON/TXT file on disk. | Very Low — after chat is built. |
| Custom Branding (lobby logo) | NSImageView in lobby UI. Image URL from user profile (PostgreSQL). | Low — after lobby is built. |
| Stage & Filmstrip refinement | **Already implemented** (`InterRemoteVideoLayoutManager`). Needs pagination for 50 participants. | Medium — scroll view + lazy tile creation. |

### Feasible with Significant Effort (Future Phases)

| Feature | Why | Complexity |
|:--------|:----|:-----------|
| Cloud Recording | Requires server-side `LiveKit Egress API` to record SFU streams to S3/GCS. Needs cloud storage account + billing metering. | High — infrastructure + metering. |
| Auto-Transcription | Requires speech-to-text service (Whisper API / Deepgram). Real-time via LiveKit audio track forwarding. | High — external API dependency. |
| Calendar Integration | macOS `EventKit` framework for local calendar. Google/Outlook requires OAuth2 flows. | Medium-High — OAuth complexity. |
| Scheduling Links | Web-based booking page. Requires public URL, availability engine, timezone handling. | High — needs web frontend. |
| Team Management | CRUD for teams/orgs in PostgreSQL. Invite flows. | Medium — standard SaaS pattern. |
| Structured Interviews | Scorecard UI, question templates, timer. All client-side with PostgreSQL persistence. | Medium — new UI panels. |
| Live Coding / Whiteboard | Collaborative editor (CRDT/OT) + canvas. This is essentially building a mini-IDE. | Very High — consider embedding Monaco or similar. |
| ATS Integration (Greenhouse, Lever) | REST API integrations. Candidate sync, interview scheduling webhook. | High — third-party API contracts. |
| Candidate Dashboard | Web-based portal for candidates. Separate frontend app. | High — new web app. |
| AI Co-Pilot (Summaries) | LLM integration (OpenAI/Anthropic API). Needs transcription first. | High — depends on transcription. |
| Multi-track Recording | Separate `AVAssetWriter` per participant track. File management + cloud upload. | High — complex pipeline. |
| Automated Camera Framing | Core ML / Vision framework face detection + crop. | Medium — Apple frameworks exist. |
| Low-Light Correction | Core Image `CIFilter` chain or Metal compute shader. | Medium — proven techniques. |
| Watermark (recording) | Metal overlay shader or `AVVideoComposition` layer. | Low — after recording exists. |

---

## Implementation Order — The Dependency Graph

```
Phase 6: Infrastructure Foundation
    ├── 6.1 Redis Migration (token-server)
    ├── 6.2 PostgreSQL Schema + Migrations
    └── 6.3 Auth Middleware (JWT user auth)
            │
Phase 7: Scale to 50 Participants
    ├── 7.1 Raise participant cap
    ├── 7.2 Selective subscription config
    ├── 7.3 Adaptive grid layout (50 tiles)
    └── 7.4 Active speaker highlight UI
            │
Phase 8: In-Meeting Communication
    ├── 8.1 Public Chat (DataChannel)
    ├── 8.2 Raise Hand + Speaker Queue
    ├── 8.3 Direct Messages (Pro)
    ├── 8.4 Chat Transcript Save (Pro)
    ├── 8.5 Live Polls (Pro)
    └── 8.6 Q&A Board (Pro)
            │
Phase 9: Meeting Management (Pro)
    ├── 9.1 Roles & Permissions (co-host, panelist, presenter)
    ├── 9.2 Moderation (Mute All, Ask to Unmute, Lock, Spotlight)
    ├── 9.3 Lobby / Waiting Room (admit one/all)
    └── 9.4 Meeting Passwords
            │
Phase 10: Recording
    ├── 10.1 Local Recording (composed layout, pause/resume)
    ├── 10.2 Watermark (Free tier)
    ├── 10.3 Cloud Recording (Pro — LiveKit Egress)
    └── 10.4 Multi-track Recording (Hiring)
            │
Phase 11: Scheduling & Productivity
    ├── 11.1 Calendar view (EventKit)
    ├── 11.2 Calendar scheduling (Pro — Apple, Google, Outlook)
    ├── 11.3 Scheduling Links (Pro)
    └── 11.4 Team Management
            │
Phase 12: Hiring-Specific Features
    ├── 12.1 Structured Interviews
    ├── 12.2 Live Coding / Whiteboard
    ├── 12.3 ATS Integration
    └── 12.4 Candidate Dashboard
            │
Phase 13: AI & Enhancement
    ├── 13.1 Auto-Transcription
    ├── 13.2 AI Co-Pilot Summaries
    ├── 13.3 Automated Camera Framing
    └── 13.4 Low-Light Correction
            │
Phase 14: Branding & Polish
    └── 14.1 Custom Branding (Pro/Hiring)
```

---

## Phase 6 — Infrastructure Foundation

> **Goal**: Replace the in-memory token-server with Redis + PostgreSQL. Add basic auth. This is the foundation for EVERY future feature. No client-side changes.  
> **Risk to existing code**: ZERO — all changes are in `token-server/`. The macOS client is untouched.  
> **Estimated effort**: 2–3 sessions

### 6.1 — Redis Migration (Token Server)

Replace in-memory `Map` objects in `token-server/index.js` with Redis.

| Step | What | Files | Details |
|:-----|:-----|:------|:--------|
| 6.1.1 | Install `ioredis` | `token-server/package.json` | `npm install ioredis` |
| 6.1.2 | Create Redis client module | `token-server/redis.js` (NEW) | Connection factory with env var `REDIS_URL` (default `redis://localhost:6379`). Graceful error handling. |
| 6.1.3 | Migrate room codes | `token-server/index.js` | Replace `roomCodes` Map with Redis Hash: `room:{code}` → `{roomName, createdAt, hostIdentity, roomType}`. Use `EXPIRE` for 24h TTL (replaces manual cleanup interval). Participant set → Redis Set `room:{code}:participants`. |
| 6.1.4 | Migrate rate limiting | `token-server/index.js` | Replace `rateLimitMap` with Redis key `ratelimit:{identity}` + `INCR` + `EXPIRE 60`. Atomic. No cleanup needed. |
| 6.1.5 | Remove cleanup interval | `token-server/index.js` | Delete the `setInterval` block — Redis TTL handles expiry automatically. |
| 6.1.6 | Add `.env` support | `token-server/.env.example` (NEW), `package.json` | `npm install dotenv`. Document all env vars: `REDIS_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, `LIVEKIT_SERVER_URL`, `PORT`. |
| 6.1.7 | Test all endpoints | Manual | Verify `/room/create`, `/room/join`, `/token/refresh`, `/room/info/:code` work identically. Run existing curl tests. |
| 6.1.8 | Add health check for Redis | `token-server/index.js` | `GET /health` returns Redis connection status. |

**Verification gate**: All existing curl tests pass. Redis-cli shows room keys with correct TTL. Rate limit keys auto-expire.

---

### 6.2 — PostgreSQL Schema + Migrations

Design and create the foundational database schema for persistent application data.

| Step | What | Files | Details |
|:-----|:-----|:------|:--------|
| 6.2.1 | Install `pg` + `dotenv` | `token-server/package.json` | `npm install pg` |
| 6.2.2 | Create DB connection module | `token-server/db.js` (NEW) | Pool with env var `DATABASE_URL` (default `postgresql://localhost:5432/inter_dev`). |
| 6.2.3 | Create migration runner | `token-server/migrations/` (NEW dir) | Simple sequential SQL files: `001_initial_schema.sql`, etc. Runner script: `node migrate.js`. |
| 6.2.4 | Design initial schema | `token-server/migrations/001_initial_schema.sql` | Tables below. |

**Schema (001_initial_schema.sql):**

```sql
-- Users (authentication base)
CREATE TABLE users (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email           VARCHAR(255) UNIQUE NOT NULL,
    display_name    VARCHAR(100) NOT NULL,
    password_hash   VARCHAR(255) NOT NULL,
    tier            VARCHAR(20) NOT NULL DEFAULT 'free',  -- free | pro | hiring
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Meetings (persistent room history)
CREATE TABLE meetings (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    host_user_id    UUID NOT NULL REFERENCES users(id),
    room_code       VARCHAR(6) NOT NULL,
    room_name       VARCHAR(100) NOT NULL,
    room_type       VARCHAR(20) NOT NULL DEFAULT 'call',  -- call | interview
    status          VARCHAR(20) NOT NULL DEFAULT 'active', -- active | ended
    started_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ended_at        TIMESTAMPTZ,
    max_participants INT NOT NULL DEFAULT 50,
    CONSTRAINT fk_host FOREIGN KEY (host_user_id) REFERENCES users(id)
);

-- Meeting participants (join/leave log)
CREATE TABLE meeting_participants (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    meeting_id      UUID NOT NULL REFERENCES meetings(id),
    user_id         UUID REFERENCES users(id),          -- NULL for anonymous guests
    identity        VARCHAR(100) NOT NULL,
    display_name    VARCHAR(100) NOT NULL,
    role            VARCHAR(20) NOT NULL DEFAULT 'participant',
    joined_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    left_at         TIMESTAMPTZ
);

-- Indexes
CREATE INDEX idx_meetings_host ON meetings(host_user_id);
CREATE INDEX idx_meetings_room_code ON meetings(room_code);
CREATE INDEX idx_meetings_status ON meetings(status);
CREATE INDEX idx_participants_meeting ON meeting_participants(meeting_id);
CREATE INDEX idx_users_email ON users(email);
```

| Step | What | Files | Details |
|:-----|:-----|:------|:--------|
| 6.2.5 | Run migration | Terminal | `psql -d inter_dev -f token-server/migrations/001_initial_schema.sql` |
| 6.2.6 | Wire meeting creation | `token-server/index.js` | On `/room/create`: INSERT into `meetings` table (if user is authenticated). Backward-compatible — anonymous users still work. |
| 6.2.7 | Wire participant tracking | `token-server/index.js` | On `/room/join`: INSERT into `meeting_participants`. On disconnect (future webhook): UPDATE `left_at`. |

**Verification gate**: Schema created. `\dt` shows all tables. Room create inserts meeting row. Tests pass.

---

### 6.3 — Authentication Middleware

Add optional JWT-based user authentication. Existing anonymous flow continues to work (backward-compatible).

| Step | What | Files | Details |
|:-----|:-----|:------|:--------|
| 6.3.1 | Install auth deps | `package.json` | `npm install bcryptjs jsonwebtoken` |
| 6.3.2 | Create auth module | `token-server/auth.js` (NEW) | `register(email, password, displayName)` → hash + INSERT user → return user JWT. `login(email, password)` → verify + return JWT. `authenticateToken` middleware (optional — checks `Authorization: Bearer` header, attaches `req.user`). |
| 6.3.3 | Auth endpoints | `token-server/index.js` | `POST /auth/register`, `POST /auth/login`, `GET /auth/me`. |
| 6.3.4 | Optional auth on room endpoints | `token-server/index.js` | Room endpoints check for `req.user` but don't require it. If present, link meeting to user. If absent, anonymous flow (current behavior). |
| 6.3.5 | Tier enforcement middleware | `token-server/auth.js` | `requireTier('pro')` middleware. Checks `req.user.tier`. Returns 403 if insufficient. Used in future phases for gating Pro/Hiring features. |

**Verification gate**: Register + login returns JWT. Authenticated room/create links to user. Anonymous room/create still works. All existing tests pass.

---

## Phase 7 — Scale to 50 Participants

> **Goal**: Raise the hard cap from 4 to 50. Make the UI handle it gracefully.  
> **Risk to existing code**: LOW — cap change is a constant. UI changes are additive.  
> **Dependencies**: None (can be done before or after Phase 6)  
> **Estimated effort**: 2 sessions

### 7.1 — Raise Participant Cap

| Step | What | Files | Details |
|:-----|:-----|:------|:--------|
| 7.1.1 | Change server cap | `token-server/index.js` | `MAX_PARTICIPANTS_PER_ROOM = 50` |
| 7.1.2 | Change client response handling | `inter/Networking/InterTokenService.swift` | Parse `maxParticipants` from response (already does). No code change needed. |
| 7.1.3 | Update InterNetworkTypes | `inter/Networking/InterNetworkTypes.swift` | Add `maxParticipants` to `InterRoomConfiguration` if not already present. |

### 7.2 — Selective Subscription

| Step | What | Files | Details |
|:-----|:-----|:------|:--------|
| 7.2.1 | Enable adaptive stream | `inter/Networking/InterRoomController.swift` | LiveKit `ConnectOptions.autoSubscribe = true` (already set). Add `adaptiveStream = true` to room options. |
| 7.2.2 | Track visibility binding | `inter/Networking/InterLiveKitSubscriber.swift` | When a tile scrolls off-screen, set `RemoteTrackPublication.enabled = false`. When visible, set `true`. LiveKit handles bitrate/resolution automatically. |

### 7.3 — Adaptive Grid Layout

| Step | What | Files | Details |
|:-----|:-----|:------|:--------|
| 7.3.1 | Multi-participant grid | `inter/UI/Views/InterRemoteVideoLayoutManager.m` | Refactor `MultiCamera` layout mode. Dynamic grid: 2→2×1, 3-4→2×2, 5-9→3×3, 10-16→4×4, 17-25→5×5, 26-50→paginated filmstrip. |
| 7.3.2 | Pagination | `inter/UI/Views/InterRemoteVideoLayoutManager.m` | Page indicator. Arrow keys / click to navigate. Max 25 tiles per page. |
| 7.3.3 | Tile recycling | `inter/UI/Views/InterRemoteVideoLayoutManager.m` | Reuse `InterRemoteVideoView` instances for off-screen participants (like UICollectionView cell reuse). Critical for memory at 50 participants. |
| 7.3.4 | Dynamic quality | `inter/Networking/InterLiveKitSubscriber.swift` | Request low-res for filmstrip tiles, high-res for stage/spotlight. Use LiveKit `RemoteTrackPublication.preferredDimensions`. |

### 7.4 — Active Speaker Highlight

| Step | What | Files | Details |
|:-----|:-----|:------|:--------|
| 7.4.1 | Speaker border | `inter/UI/Views/InterRemoteVideoLayoutManager.m` | Green/blue border on the tile of `activeSpeakerIdentity` (already KVO-observed from `InterRoomController`). |
| 7.4.2 | Auto-spotlight | `inter/UI/Views/InterRemoteVideoLayoutManager.m` | Option: automatically bring active speaker to stage in filmstrip+stage mode. |

**Verification gate**: 50 participants join a room. Grid layout adapts. Scrolling is smooth. Memory stays under 500MB. Active speaker highlighted.

---

## Phase 8 — In-Meeting Communication

> **Goal**: Chat and Raise Hand. These use LiveKit DataChannel — pure additive, no existing code modified.  
> **Risk to existing code**: ZERO — all new files.  
> **Dependencies**: None  
> **Estimated effort**: 2 sessions

### 8.1 — Public Chat

| Step | What | Files | Details |
|:-----|:-----|:------|:--------|
| 8.1.1 | Chat message model | `inter/Networking/InterChatMessage.swift` (NEW) | Struct: `id`, `senderIdentity`, `senderName`, `text`, `timestamp`, `type` (public/dm/system). JSON Codable. |
| 8.1.2 | Chat data channel | `inter/Networking/InterChatController.swift` (NEW) | Uses `room.localParticipant.publish(data:)` with topic `"chat"`. Receives via `room.delegate.didReceiveData`. Maintains message array. Delegate protocol for UI updates. |
| 8.1.3 | Chat UI panel | `inter/UI/Views/InterChatPanel.h/.m` (NEW) | NSScrollView + NSTableView (message list). NSTextField (input). Send button. Slide-in from right edge. Toggle with keyboard shortcut (⌘+Shift+C). Dark theme matching app. |
| 8.1.4 | Wire to AppDelegate | `inter/App/AppDelegate.m` | Add chat panel to normal call window. Wire `InterChatController` to `InterRoomController`'s room delegate. |
| 8.1.5 | Wire to SecureWindowController | `inter/UI/Controllers/SecureWindowController.m` | Same wiring for interview mode. |

### 8.2 — Raise Hand + Speaker Queue

| Step | What | Files | Details |
|:-----|:-----|:------|:--------|
| 8.2.1 | Hand raise via metadata | `inter/Networking/InterChatController.swift` | Send `{type: "raiseHand", identity, timestamp}` on DataChannel topic `"control"`. |
| 8.2.2 | Speaker queue model | `inter/Networking/InterSpeakerQueue.swift` (NEW) | Ordered array of raised hands. Chronological (Free). Host can reorder (Pro — Phase 9). |
| 8.2.3 | Hand raise UI | `inter/UI/Views/InterParticipantOverlayView.m` | Hand icon (✋) on participant tile. Queue counter badge. |
| 8.2.4 | Host queue panel | `inter/UI/Views/InterSpeakerQueuePanel.h/.m` (NEW) | List of raised hands with "Unmute" / "Dismiss" actions (host-only). |

### 8.3 — Direct Messages (Pro Tier)

| Step | What | Files | Details |
|:-----|:-----|:------|:--------|
| 8.3.1 | Targeted data publish | `inter/Networking/InterChatController.swift` | Use `participant.publish(data:destinationIdentities:)` for DMs. |
| 8.3.2 | DM UI | `inter/UI/Views/InterChatPanel.m` | Tab or filter: "Everyone" vs specific participant. Tier-gated — check user tier before allowing DM. |

### 8.4 — Chat Transcript Save (Pro Tier)

| Step | What | Files | Details |
|:-----|:-----|:------|:--------|
| 8.4.1 | Export chat | `inter/Networking/InterChatController.swift` | `exportTranscript() → URL` writes messages to `.txt` or `.json` file. NSSavePanel for location. |

### 8.5 — Live Polls (Pro Tier)

| Step | What | Files | Details |
|:-----|:-----|:------|:--------|
| 8.5.1 | Poll data model | `inter/Networking/InterPollController.swift` (NEW) | `InterPoll` struct: id, question, options (array of `InterPollOption` with label + voteCount), createdBy, isAnonymous, allowMultiSelect, status (draft/active/ended). JSON Codable. |
| 8.5.2 | Poll DataChannel | `inter/Networking/InterPollController.swift` | Topic `"poll"`. Host publishes `{type: "launchPoll", poll}` to all. Participants publish `{type: "vote", pollId, optionIndices}` targeted back to host. Host aggregates and broadcasts `{type: "pollResults", poll}`. |
| 8.5.3 | Host poll creation UI | `inter/UI/Views/InterPollPanel.h/.m` (NEW) | Create poll form: question text, add/remove options (2–10), anonymous toggle, multi-select toggle. "Launch" button publishes to all. "End Poll" stops voting and broadcasts final results. |
| 8.5.4 | Participant vote UI | `inter/UI/Views/InterPollPanel.m` | Non-host view: question + radio/checkbox options + "Submit" button. After voting: shows live results bar chart (if host enabled live results) or "Vote submitted" confirmation. |
| 8.5.5 | Results display | `inter/UI/Views/InterPollPanel.m` | Horizontal bar chart per option with vote count and percentage. Host can "Share Results" to broadcast final tally to all participants. |
| 8.5.6 | Wire to AppDelegate | `inter/App/AppDelegate.m` | Add poll toggle button (📊) to control bar. Wire `InterPollController` through a centralized `InterDataChannelRouter` (see below). |
| 8.5.7 | DataChannel router | `inter/Networking/InterDataChannelRouter.swift` (NEW) | Centralized dispatcher that demultiplexes incoming DataChannel messages by `topic` field. Provides `subscribe(topic: String, handler: (Data) → Void)` API. `InterChatController`, `InterPollController`, `InterQAController`, and `InterModerationController` each register a handler during initialization instead of reading the DataChannel directly. Router is owned by `InterRoomController` and wired in `AppDelegate`. **Migration strategy** (atomic cutover to avoid duplicate/dropped messages): **(a)** Add a `useDataChannelRouter` feature flag (Bool, default `false`) to `InterRoomController`. When `false`, the existing direct `handleReceivedData` call-sites remain active. **(b)** Implement a dual-delivery shim inside the router: when compatibility mode is on, incoming DataChannel frames are forwarded to **both** the router's `subscribe` dispatch **and** the original direct handlers; controllers that have migrated must deduplicate (idempotent `handleReceivedData` or guard via "already-routed" flag). **(c)** Migrate controllers one-at-a-time: each controller registers its `subscribe(topic:handler:)` and removes its direct `handleReceivedData` call-site; verify with per-controller unit test that messages arrive exactly once. **(d)** Deterministic cutover step: once all four controllers are migrated, flip `useDataChannelRouter = true`, remove the dual-delivery shim, and delete all direct DataChannel reads from controllers. **(e)** Required tests: subscription registration/unsubscription, dual-delivery delivers to both paths, single-path post-cutover delivers only via router, unknown topic messages are logged and dropped (not crashed). |

### 8.6 — Q&A Board (Pro Tier)

| Step | What | Files | Details |
|:-----|:-----|:------|:--------|
| 8.6.1 | Q&A data model | `inter/Networking/InterQAController.swift` (NEW) | `InterQuestion` struct: id, askerIdentity, askerName, text, timestamp, upvoteCount, isAnswered, isHighlighted. JSON Codable. |
| 8.6.2 | Q&A DataChannel | `inter/Networking/InterQAController.swift` | Topic `"qa"`. Participants submit `askQuestion` via `POST /room/qa/publish` (step 8.6.6) — the server sanitises identity fields before rebroadcasting over DataChannel. Upvotes, markAnswered, highlight, and dismiss remain direct DataChannel publishes (host-only actions or non-sensitive). |
| 8.6.3 | Q&A UI panel | `inter/UI/Views/InterQAPanel.h/.m` (NEW) | Slide-in panel (like chat). Sorted by upvote count (highest first). Each question shows: asker name, text, upvote button + count, timestamp. Host sees additional: "Highlight" (pins to top), "Mark Answered" (checkmark), "Dismiss" (remove). |
| 8.6.4 | Participant Q&A input | `inter/UI/Views/InterQAPanel.m` | Text field at bottom: "Ask a question…". Anonymous option toggle (hides asker name from other participants, visible to host). Anonymity is server-enforced (step 8.6.6) — the client sends `isAnonymous: true` but the server strips identity before rebroadcast. |
| 8.6.5 | Wire to AppDelegate | `inter/App/AppDelegate.m` | Add Q&A toggle button (❓) to control bar. Wire `InterQAController` through `InterDataChannelRouter` (step 8.5.7). |
| 8.6.6 | Server-side Q&A publish | `token-server/index.js` | `POST /room/qa/publish` — accepts `{roomCode, callerIdentity, question}`. Server validates caller is a room participant, then: **(a)** overwrites `question.askerIdentity` with the authenticated caller identity (ignores client-supplied value); **(b)** if `question.isAnonymous == true`, sets `askerName` to `"Anonymous"` and strips `askerIdentity` from the outgoing payload (host receives the real identity in a separate `hostAskerIdentity` field); **(c)** assigns a server-generated UUID for `question.id` (prevents client-forged IDs); **(d)** rebroadcasts the sanitised message to all room participants via LiveKit `DataPublishOptions(topic: "qa")`. Client `InterQAController.submitQuestion()` calls this endpoint instead of direct DataChannel publish. |

**Verification gate**: Messages appear for all participants in real-time. Raise hand icon appears on tile. DMs are private. Transcript exports correctly. Polls launch and collect votes in real-time, results display correctly. Q&A questions sort by upvotes, host can moderate.

---

## Phase 9 — Meeting Management (Pro Tier)

> **Goal**: Professional meeting controls. Server-authoritative role enforcement.  
> **Risk to existing code**: LOW — extends existing JWT metadata pattern.  
> **Dependencies**: Phase 6.3 (auth), Phase 8 (chat for "Disable Chat")  
> **Estimated effort**: 2–3 sessions

### 9.1 — Roles & Permissions

| Step | What | Files | Details |
|:-----|:-----|:------|:--------|
| 9.1.1 | Extend JWT metadata | `token-server/index.js` | Metadata: `{role: "host"|"co-host"|"panelist"|"presenter"|"participant"}`. Host can promote via server API call. **Panelist**: can unmute self and share screen, but cannot moderate others. |
| 9.1.2 | Permission model | `inter/Networking/InterPermissions.swift` (NEW) | Enum-based permissions: `canMuteOthers`, `canRemoveParticipant`, `canStartRecording`, `canDisableChat`, `canLaunchPolls`, `canForceSpotlight`, `canLockMeeting`, `canAdmitFromLobby`. Derived from role via permission matrix. |
| 9.1.3 | Server promotion endpoint | `token-server/index.js` | `POST /room/promote` — host sends `{roomCode, targetIdentity, newRole}`. Server updates LiveKit participant metadata, issues new token to target. Validates: only host/co-host can promote. |
| 9.1.4 | Client role UI | `inter/UI/Views/InterLocalCallControlPanel.m` | Show/hide moderation buttons based on local participant's role. Participant context menu on tiles: "Promote to Co-host", "Make Presenter", "Make Panelist" (host/co-host only). |
| 9.1.5 | Permission matrix | `inter/Networking/InterPermissions.swift` | Role→permission mapping: **Host/Co-host**: all permissions. **Panelist**: canUnmuteSelf, canShareScreen, canLaunchPolls. **Presenter**: canUnmuteSelf, canShareScreen. **Participant**: canUnmuteSelf (if not hard-muted). |

### 9.2 — Advanced Moderation

| Step | What | Files | Details |
|:-----|:-----|:------|:--------|
| 9.2.1 | Mute All / Mute Individual | `token-server/index.js` | `POST /room/mute-all` — uses LiveKit Server API `MutePublishedTrack` for all remote participants (audio). `POST /room/mute` — `{roomCode, targetIdentity, trackSource: "microphone"|"camera"}` — mutes a single participant's specific track. Both server-authoritative via LiveKit admin API. |
| 9.2.2 | Disable Chat | `inter/Networking/InterChatController.swift` | Host sends `{type: "disableChat"}` control message on DataChannel. All clients respect it — input field disabled, system message displayed. Host sends `{type: "enableChat"}` to restore. |
| 9.2.3 | Remove Participant | `token-server/index.js` | `POST /room/remove` — uses LiveKit Server API `RemoveParticipant`. Removed participant sees "You have been removed from the meeting" dialog. Cannot rejoin unless re-admitted. |
| 9.2.4 | Ask to Unmute | `inter/Networking/InterChatController.swift` | Control signal `{type: "askToUnmute", targetIdentity}` on DataChannel. Target client shows modal: "The host is asking you to unmute your microphone" with Accept / Decline buttons. Accept triggers local unmute. No server API needed — P2P via DataChannel. |
| 9.2.5 | Disable Participant Camera | `token-server/index.js` | Same `POST /room/mute` endpoint with `trackSource: "camera"`. Target participant sees "The host has turned off your camera" notification. Participant can re-enable unless hard-muted. |
| 9.2.6 | Lock Meeting | `token-server/index.js`, `inter/Networking/InterChatController.swift` | `POST /room/lock` — sets Redis flag `room:{code}:locked = true`. `/room/join` returns 423 (Locked) when flag set. Host toggle in control panel. Control signal `{type: "meetingLocked"}` broadcast notifies existing participants. `POST /room/unlock` clears the flag. |
| 9.2.7 | Suspend Participant | `token-server/index.js`, `inter/Networking/InterChatController.swift` | `POST /room/suspend` — server hard-mutes all tracks (audio + camera) for target via LiveKit API. Control signal `{type: "suspended", targetIdentity}` disables target's chat input and share controls. Target sees "You have been suspended by the host." Host can unsuspend via `POST /room/unsuspend`. |
| 9.2.8 | Host-Forced Spotlight | `inter/Networking/InterChatController.swift`, `inter/UI/Views/InterRemoteVideoLayoutManager.m` | Control signal `{type: "forceSpotlight", targetIdentity}` on DataChannel. All clients receive it and override their local `spotlightedParticipantKey` in layout manager. Tile context menu: "Pin for Everyone" (host/co-host only). `{type: "clearForceSpotlight"}` restores local control. Supports multi-pin: `targetIdentities` array for webinar/panel layouts. |

### 9.3 — Lobby / Waiting Room

| Step | What | Files | Details |
|:-----|:-----|:------|:--------|
| 9.3.1 | Server-side lobby | `token-server/index.js` | When lobby enabled, `/room/join` returns `{status: "waiting", position: N}` instead of a token. Waiting participants stored in Redis sorted set `room:{code}:lobby` (score = join timestamp). Host notified via DataChannel `{type: "lobbyJoin", identity, displayName}`. |
| 9.3.2 | Host admit endpoint | `token-server/index.js` | `POST /room/admit` — host sends `{roomCode, identity}`. Server removes from lobby set, issues LiveKit token, and notifies waiting client via polling or SSE. |
| 9.3.3 | Admit All | `token-server/index.js` | `POST /room/admit-all` — iterates Redis lobby set, issues tokens for all waiting participants, clears the set. Returns count of admitted participants. |
| 9.3.4 | Deny participant | `token-server/index.js` | `POST /room/deny` — removes participant from lobby set. Client receives denial and shows "The host has denied your request to join." |
| 9.3.5 | Lobby UI (client) | `inter/UI/Views/InterLobbyView.h/.m` (NEW) | "Please wait, the host will let you in soon." Animated pulsing spinner. Position indicator: "You are #3 in the waiting room." Polls `GET /room/lobby-status/{code}/{identity}` every 3s (or SSE) for admit/deny status. |
| 9.3.6 | Host lobby panel | `inter/UI/Views/InterLobbyPanel.h/.m` (NEW) | List of waiting participants with join timestamp. Per-participant: "Admit" / "Deny" buttons. Top bar: "Admit All" button (enabled when lobby count > 0). Badge on lobby toggle button showing waiting count. |
| 9.3.7 | Lobby toggle | `inter/App/AppDelegate.m`, `token-server/index.js` | `POST /room/lobby/enable` and `/room/lobby/disable`. Redis flag `room:{code}:lobbyEnabled`. Host toggle in room settings or control panel. Default: disabled (direct join). |

### 9.4 — Meeting Passwords

| Step | What | Files | Details |
|:-----|:-----|:------|:--------|
| 9.4.1 | Server password storage | `token-server/index.js` | `POST /room/create` accepts optional `password` field. Stored as bcrypt hash in Redis Hash `room:{code}` field `passwordHash`. |
| 9.4.2 | Password validation on join | `token-server/index.js` | `POST /room/join` requires `password` field when room has `passwordHash` set. Returns 401 "Incorrect password" on mismatch. Omitting password when required returns 401 "This meeting requires a password". **Brute-force mitigation** (multi-layer): **(1) Per-requester rate limit**: For authenticated users, track via `ratelimit:pwd-user:{userId}:{roomCode}`; for anonymous, track via `ratelimit:pwd:{roomCode}:{ip}`. Use Redis `INCR` + explicit `EXPIRE` (base window 60s). Thresholds with exponential backoff lockouts: 5 failures → 60s lockout, 10 failures → 300s lockout, 20 failures → 900s lockout. On each threshold breach, `SET` key with new TTL equal to the lockout duration (prevents counter reset during lockout). Return 429 with `Retry-After` header set to remaining lockout TTL. **(2) Per-room global limit**: Secondary key `ratelimit:pwd-room:{roomCode}` with `INCR` + `EXPIRE 60`. Threshold: 50 attempts / 60s across all IPs/users. Return 429 when breached (mitigates distributed attacks). **(3) TTL hygiene**: Every rate-limit key must be created with an explicit `EXPIRE` — no unbounded keys. Counter resets naturally after base window unless in lockout state. |
| 9.4.3 | Client password UI | `inter/UI/Views/InterConnectionSetupPanel.m` | When `/room/join` returns 401 with password-required flag, show password input field below room code. Re-submit join with password. SecureTextField (dots, not plain text). |
| 9.4.4 | Host password management | `inter/UI/Views/InterConnectionSetupPanel.m` | Optional password field on host create form. Auto-generate option: 8+ character alphanumeric (default) or 8–10 digit numeric PIN, with optional word-based passphrase (3 random words joined by hyphens). Password shown in room info (copyable alongside room code). |

**Verification gate**: Co-host can mute/unmute-request participants. Individual hard-mute and camera disable work. Lobby holds joiners until admitted (one-by-one or all-at-once). Removed participants are disconnected. Locked meeting rejects new joins. Suspended participant cannot interact. Host-forced spotlight overrides all clients' views. Meeting password blocks unauthorized joins.

---

## Phase 10 — Recording

> **Goal**: Local recording with watermark (Free), without (Pro). Cloud recording (Pro). Multi-track (Hiring).  
> **Risk to existing code**: MEDIUM — previous recording was removed in PF.6. New pipeline from scratch.  
> **Dependencies**: Phase 7 (multi-participant layout for composed recording)  
> **Estimated effort**: 4–5 sessions

### 10.1 — Local Recording (Composed Layout)

| Step | What | Files | Details |
|:-----|:-----|:------|:--------|
| 10.1.1 | Recording engine | `inter/Media/Recording/InterRecordingEngine.h/.m` (NEW) | `AVAssetWriter` with video (H.264) + audio (AAC) inputs. Accepts `CVPixelBuffer` frames. |
| 10.1.2 | Composed renderer | `inter/Media/Recording/InterComposedRenderer.h/.m` (NEW) | Metal offscreen render pass. Composites: screen share (main) + active speaker PiP (bottom-right). Outputs CVPixelBuffer at 1080p 30fps. |
| 10.1.3 | Recording coordinator | `inter/Media/Recording/InterRecordingCoordinator.swift` (NEW) | Orchestrates: start/stop/pause/resume, consent notification (DataChannel broadcast `{type: "recordingStarted"}`), file management. Host-only permission check (via `InterPermissions`). |
| 10.1.4 | UI controls | `inter/UI/Views/InterLocalCallControlPanel.m` | "Record" button (red dot). Recording indicator visible to all participants ("REC" badge). Timer display. |
| 10.1.5 | Pause / Resume | `inter/Media/Recording/InterRecordingCoordinator.swift` | `pauseRecording()` — stops appending frames to `AVAssetWriter` inputs, stores pause timestamp. `resumeRecording()` — adjusts presentation timestamps (PTS offset = pause duration) so the output file has no gap. UI: record button toggles to "⏸" while paused, timer pauses. DataChannel broadcast `{type: "recordingPaused"}` / `{type: "recordingResumed"}` to update all clients' REC indicator. |

### 10.2 — Watermark (Free Tier)

| Step | What | Files | Details |
|:-----|:-----|:------|:--------|
| 10.2.1 | Watermark overlay | `inter/Media/Recording/InterComposedRenderer.m` | Semi-transparent "Inter" logo overlay, bottom-left. Rendered as Metal texture quad. Applied only when `user.tier == "free"`. |

### 10.3 — Cloud Recording (Pro — Future)

| Step | What | Files | Details |
|:-----|:-----|:------|:--------|
| 10.3.1 | LiveKit Egress API | `token-server/index.js` | `POST /room/record/start` → calls LiveKit Egress API. Records server-side to S3/GCS. |
| 10.3.2 | Storage metering | `token-server/db.js` | Track recording hours per user in PostgreSQL. Enforce 10hr/month (Pro) / 20hr/month (Hiring) limits. |

### 10.4 — Multi-track Recording (Hiring — Future)

| Step | What | Files | Details |
|:-----|:-----|:------|:--------|
| 10.4.1 | Per-participant writer | `inter/Media/Recording/InterMultiTrackRecorder.swift` (NEW) | Separate `AVAssetWriter` per remote participant track. Synced timestamps. |
| 10.4.2 | File packaging | `inter/Media/Recording/InterMultiTrackRecorder.swift` | Zip all tracks + manifest JSON. Upload to cloud (Hiring tier). |

**Verification gate**: Host clicks Record → all participants see "REC" indicator → composed video saved locally → watermark visible on Free tier.

---

## Phase 11 — Scheduling & Productivity

> **Dependencies**: Phase 6 (PostgreSQL + auth)  
> **Estimated effort**: 3–4 sessions

### 11.1 — Calendar View (Free)

EventKit integration for viewing upcoming meetings.

### 11.2 — Calendar Scheduling & Sync (Pro)

Create meetings from within the app. Store in PostgreSQL + sync to calendar providers.

| Step | What | Files | Details |
|:-----|:-----|:------|:--------|
| 11.2.1 | Meeting scheduling model | `token-server/migrations/002_scheduling.sql` | `scheduled_meetings` table: id, host_user_id, title, description, scheduled_at (TIMESTAMPTZ), duration_minutes, room_type, password (optional), lobby_enabled, recurrence_rule (iCal RRULE string, nullable), host_timezone (IANA timezone identifier, e.g. `America/New_York`, NOT NULL). **Migration safety note**: `scheduled_meetings` is a brand-new table created in `002_scheduling.sql` — no pre-existing rows, so `NOT NULL` without a default is safe on initial `CREATE TABLE`. The migration SQL must include a comment at the top: `-- ASSERT: scheduled_meetings is a new table (created here). If this migration is ever repurposed to ALTER an existing table, host_timezone must be added as NULLABLE first, backfilled (e.g. SET host_timezone = 'UTC' or derived from users.preferred_timezone via host_user_id), then ALTER COLUMN SET NOT NULL.` All scheduling endpoints accept and return `host_timezone`. Use IANA-aware library (luxon on server, `TimeZone(identifier:)` on client) for DST-correct conversions. |
| 11.2.2 | Scheduling endpoints | `token-server/index.js` | `POST /meetings/schedule` — creates scheduled meeting, returns meeting link. `GET /meetings/upcoming` — list user's upcoming meetings. `PATCH /meetings/:id` — reschedule/cancel. `DELETE /meetings/:id` — cancel with optional notification. |
| 11.2.3 | Apple Calendar sync | `inter/App/InterCalendarService.swift` (NEW) | macOS `EventKit` framework. `EKEventStore` access via `requestAccess(to: .event)`. Create `EKEvent` with meeting link in notes/URL field, setting `timeZone` from `host_timezone` (IANA → `TimeZone(identifier:)`). Request calendar access on first use. Bi-directional sync: schedule from app → creates EKEvent; detect external edits via `EKEventStoreChangedNotification` (immediate) + scheduled background polling (every 5 min via `refreshSources()` / `fetchEvents(matching:)`) with `lastSyncToken`/`lastModified` persistence. Generate `.ics` attachments with `VTIMEZONE` component per RFC 5545. |
| 11.2.4 | Google Calendar sync | `token-server/calendar.js` (NEW) | Google Calendar API v3 via OAuth2. `POST /auth/google/connect` — OAuth flow, store refresh token **encrypted** in `users` table (`google_refresh_token` column, encrypted via AES-256-GCM). Add `encryptToken()`/`decryptToken()` helpers in `token-server/crypto.js` (NEW) with **key-versioned encryption**: **(a) Versioned keys**: Instead of a single `ENCRYPTION_SECRET`, support `ENCRYPTION_SECRET_V1`, `ENCRYPTION_SECRET_V2`, etc. in `.env`. A `ENCRYPTION_ACTIVE_VERSION` env var (e.g. `2`) designates the current write key. `encryptToken(plaintext)` encrypts with the active-version key and prepends a version tag to the ciphertext (format: `v{N}:{iv}:{authTag}:{ciphertext}`). `decryptToken(blob)` parses the version tag, looks up the corresponding key, and decrypts; if no version tag is present (legacy), falls back to `ENCRYPTION_SECRET` (v0). **(b) DB columns**: Migration adds `google_refresh_token TEXT`, `google_token_key_version SMALLINT DEFAULT 1`, `outlook_refresh_token TEXT`, `outlook_token_key_version SMALLINT DEFAULT 1` to `users`. The key-version column is written alongside the encrypted token on every encrypt. **(c) Key rotation migration script** (`token-server/scripts/rotate-encryption-key.js`): Reads all rows with `google_token_key_version < ENCRYPTION_ACTIVE_VERSION` (and likewise for Outlook), decrypts each token with its stored version's key, re-encrypts with the active key, updates both the token and key-version columns. If a key is missing (env var deleted), logs a fatal error and skips that row (does not destroy data). Run via `node scripts/rotate-encryption-key.js` after adding a new key version. **(d) Wipe-and-reauth fallback**: If the old key is irrecoverably lost, a `--wipe` flag on the rotation script sets affected tokens to NULL and sets a `google_reauth_required BOOLEAN DEFAULT false` / `outlook_reauth_required BOOLEAN DEFAULT false` flag; the app prompts users to re-authenticate on next login. **(e) Server startup checks**: On boot, `crypto.js` validates: (1) `ENCRYPTION_ACTIVE_VERSION` is set, (2) the corresponding `ENCRYPTION_SECRET_V{N}` env var exists and is ≥ 32 bytes, (3) all version keys referenced by `*_token_key_version` in the DB are present in env (query on startup). Fails loudly with actionable error message if any check fails. **(f) Documentation**: `.env.example` documents all key vars with comments warning against deletion. README recommends using a secrets manager (AWS Secrets Manager, HashiCorp Vault, or macOS Keychain for dev) instead of bare `.env` values, and mandates backing up keys before rotation. `POST /meetings/:id/sync/google` — creates Google Calendar event with Meet-style link and description, passing `host_timezone` as the event timezone. |
| 11.2.5 | Outlook Calendar sync | `token-server/calendar.js` | Microsoft Graph API via OAuth2 (Azure AD app registration). `POST /auth/outlook/connect` — OAuth flow, store refresh token **encrypted** using the same key-versioned `encryptToken()`/`decryptToken()` from step 11.2.4 (`outlook_refresh_token` + `outlook_token_key_version` columns). Key rotation, wipe-and-reauth fallback, and startup validation apply identically to Outlook tokens. `POST /meetings/:id/sync/outlook` — creates Outlook event via `POST /me/events`, passing `host_timezone` in the `start`/`end` `timeZone` fields. |
| 11.2.6 | Meeting invitations | `token-server/index.js` | `POST /meetings/:id/invite` — sends email invitations with meeting link + password (if set) + calendar attachment (.ics file). Uses nodemailer or SendGrid. Invitation includes "Add to Calendar" links for Google/Outlook/Apple. |
| 11.2.7 | Client scheduling UI | `inter/UI/Views/InterSchedulePanel.h/.m` (NEW) | Schedule meeting form: title, date/time picker, duration, password toggle, lobby toggle, recurrence selector. Calendar provider sync toggles (Apple/Google/Outlook with connection status). Upcoming meetings list with Join/Edit/Cancel actions. |

### 11.3 — Scheduling Links (Pro)

Public booking page. Requires a lightweight web frontend (likely a separate repo).

### 11.4 — Team Management

CRUD for teams/organizations. Invite via email. Org-level settings.

---

## Phase 12 — Hiring-Specific Features

> **Dependencies**: Phase 6 (auth + DB), Phase 9 (roles), Phase 10 (recording)  
> **Estimated effort**: 5–6 sessions

### 12.1 — Structured Interviews

Scorecard templates, question banks, per-question timer, rating system.

### 12.2 — Live Coding / Whiteboard

Embedded code editor (Monaco via WKWebView) + real-time sync over DataChannel (CRDT).

### 12.3 — ATS Integration

REST API clients for Greenhouse, Lever. Webhook endpoints for candidate status sync.

### 12.4 — Candidate Dashboard

Web-based portal for candidates to view scheduled interviews and join meetings.

---

## Phase 13 — AI & Enhancement

> **Dependencies**: Phase 10 (recording/audio pipeline for transcription)  
> **Estimated effort**: 3–4 sessions

### 13.1 — Auto-Transcription

Real-time speech-to-text via Whisper API or Deepgram. Display as live captions.

### 13.2 — AI Co-Pilot Summaries

Post-meeting summary generation using LLM (OpenAI/Anthropic API). Requires transcription.

### 13.3 — Automated Camera Framing

Vision framework face detection → dynamic crop → smooth pan/zoom animation.

### 13.4 — Low-Light Correction

Core Image filter chain: noise reduction + exposure correction + brightness.

---

## Phase 14 — Branding & Polish

### 14.1 — Custom Branding (Pro/Hiring)

Custom logo in lobby screen. Custom accent colors. Stored in user profile (PostgreSQL).

---

## Execution Strategy — What to Build First

### Immediate Next Session (Phase 6.1): Redis Migration

This is the **single most important thing to do next** because:

1. **Zero risk** — only `token-server/index.js` changes. macOS client is untouched.
2. **Foundational** — every future feature (auth, meetings, chat transcripts) needs persistent storage.
3. **Already designed** — the existing code literally has the comment `// Redis in production — see plan step 5.2.3`.
4. **Fast** — ~1 hour of work. Install `ioredis`, replace 2 Maps, add TTL.

### Recommended First 3 Phases (in order):

| Order | Phase | Why First | Sessions |
|:------|:------|:----------|:---------|
| 1st | **6.1 Redis Migration** | Foundation. Zero client risk. | 1 |
| 2nd | **6.2 PostgreSQL Schema** | Foundation. Enables auth, meetings, tiers. | 1 |
| 3rd | **7.1–7.4 Scale to 50** | Biggest user-visible impact. Competitive necessity. | 2 |

After these 3, the app has a real backend, real storage, and supports 50 participants — which is enough to start beta testing with real users.

---

## Guardrails — Rules for Safe Implementation

1. **No phase modifies files from a previous phase** unless explicitly listed. New code goes in new files.
2. **Every phase has a verification gate** — a concrete test that proves it works without breaking existing behavior.
3. **All 138 existing tests must pass** after every phase. If any test breaks, the phase is not complete.
4. **G8 isolation invariant** is sacred — network failures never affect local media. Every new networking feature must be wrapped in `@try/@catch` or Swift error handling.
5. **Backward compatibility** — anonymous users (no auth) must always be able to create and join rooms. Auth is optional, not required.
6. **Feature flags** — Pro/Hiring features are gated by user tier, not by code removal. The code exists for all tiers; the server enforces access.

---

## Summary

| Phase | Name | Sessions | Risk | Client Changes? |
|:------|:-----|:---------|:-----|:----------------|
| **6** | Infrastructure Foundation | 2–3 | Low | No |
| **7** | Scale to 50 | 2 | Medium | Yes (UI) |
| **8** | In-Meeting Communication | 3 | Low | Yes (new UI — chat, polls, Q&A) |
| **9** | Meeting Management | 3–4 | Medium | Yes (new UI — moderation, lobby, passwords, spotlight) |
| **10** | Recording | 4–5 | Medium-High | Yes (new pipeline + pause/resume) |
| **11** | Scheduling | 4–5 | Medium-High | Yes (new UI + OAuth for Google/Outlook) |
| **12** | Hiring Features | 5–6 | High | Yes (new UI + web) |
| **13** | AI & Enhancement | 3–4 | Medium | Yes (new processing) |
| **14** | Branding | 1 | Low | Yes (UI) |
| **Total** | | **~28–36 sessions** | | |
