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
    └── 8.4 Chat Transcript Save (Pro)
            │
Phase 9: Meeting Management (Pro)
    ├── 9.1 Roles & Permissions (co-host, presenter)
    ├── 9.2 Moderation (Mute All, Disable Chat)
    └── 9.3 Lobby / Waiting Room
            │
Phase 10: Recording
    ├── 10.1 Local Recording (composed layout)
    ├── 10.2 Watermark (Free tier)
    ├── 10.3 Cloud Recording (Pro — LiveKit Egress)
    └── 10.4 Multi-track Recording (Hiring)
            │
Phase 11: Scheduling & Productivity
    ├── 11.1 Calendar view (EventKit)
    ├── 11.2 Calendar scheduling (Pro)
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

**Verification gate**: Messages appear for all participants in real-time. Raise hand icon appears on tile. DMs are private. Transcript exports correctly.

---

## Phase 9 — Meeting Management (Pro Tier)

> **Goal**: Professional meeting controls. Server-authoritative role enforcement.  
> **Risk to existing code**: LOW — extends existing JWT metadata pattern.  
> **Dependencies**: Phase 6.3 (auth), Phase 8 (chat for "Disable Chat")  
> **Estimated effort**: 2–3 sessions

### 9.1 — Roles & Permissions

| Step | What | Files | Details |
|:-----|:-----|:------|:--------|
| 9.1.1 | Extend JWT metadata | `token-server/index.js` | Metadata: `{role: "host"|"co-host"|"presenter"|"participant"}`. Host can promote via server API call. |
| 9.1.2 | Permission model | `inter/Networking/InterPermissions.swift` (NEW) | Enum-based permissions: `canMuteOthers`, `canRemoveParticipant`, `canStartRecording`, `canDisableChat`. Derived from role. |
| 9.1.3 | Server promotion endpoint | `token-server/index.js` | `POST /room/promote` — host sends `{roomCode, targetIdentity, newRole}`. Server updates metadata, issues new token to target. |
| 9.1.4 | Client role UI | `inter/UI/Views/InterLocalCallControlPanel.m` | Show/hide moderation buttons based on local participant's role. |

### 9.2 — Advanced Moderation

| Step | What | Files | Details |
|:-----|:-----|:------|:--------|
| 9.2.1 | Mute All | `token-server/index.js` | `POST /room/mute-all` — uses LiveKit Server API `MutePublishedTrack` for all participants. |
| 9.2.2 | Disable Chat | `inter/Networking/InterChatController.swift` | Host sends `{type: "disableChat"}` control message. All clients respect it. |
| 9.2.3 | Remove Participant | `token-server/index.js` | `POST /room/remove` — uses LiveKit Server API `RemoveParticipant`. |

### 9.3 — Lobby / Waiting Room

| Step | What | Files | Details |
|:-----|:-----|:------|:--------|
| 9.3.1 | Server-side lobby | `token-server/index.js` | When lobby enabled, `/room/join` returns `{status: "waiting"}` instead of a token. Host gets notified via DataChannel. |
| 9.3.2 | Host admit endpoint | `token-server/index.js` | `POST /room/admit` — host sends identity to admit. Server issues token and notifies waiting client. |
| 9.3.3 | Lobby UI (client) | `inter/UI/Views/InterLobbyView.h/.m` (NEW) | "Please wait, the host will let you in soon." Animated spinner. |
| 9.3.4 | Host lobby panel | `inter/UI/Views/InterLobbyPanel.h/.m` (NEW) | List of waiting participants. "Admit" / "Deny" buttons. |

**Verification gate**: Co-host can mute participants. Lobby holds joiners until admitted. Removed participants are disconnected.

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
| 10.1.3 | Recording coordinator | `inter/Media/Recording/InterRecordingCoordinator.swift` (NEW) | Orchestrates: start/stop, consent notification (DataChannel broadcast), file management. Host-only permission check. |
| 10.1.4 | UI controls | `inter/UI/Views/InterLocalCallControlPanel.m` | "Record" button (red dot). Recording indicator. Timer display. |

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

### 11.2 — Calendar Scheduling (Pro)

Create meetings from within the app. Store in PostgreSQL + sync to system calendar.

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
| **8** | In-Meeting Communication | 2 | Low | Yes (new UI) |
| **9** | Meeting Management | 2–3 | Low | Yes (new UI) |
| **10** | Recording | 4–5 | Medium-High | Yes (new pipeline) |
| **11** | Scheduling | 3–4 | Medium | Yes (new UI) |
| **12** | Hiring Features | 5–6 | High | Yes (new UI + web) |
| **13** | AI & Enhancement | 3–4 | Medium | Yes (new processing) |
| **14** | Branding | 1 | Low | Yes (UI) |
| **Total** | | **~25–32 sessions** | | |
