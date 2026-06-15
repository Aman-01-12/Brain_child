# Teams Group Chat + File Sharing — Design Spec

**Date:** 2026-06-11
**Project:** inter (macOS, Obj-C + Swift, LiveKit; Node/Express token-server)
**Feature:** Turn the Teams panel into a persistent group chat-room per team — real-time text +
file sharing, members added instantly by email, in-app unread badges.
**Status:** Draft — awaiting user review before implementation planning
**Process:** Produced via brainstorming → decision-council (realtime transport) →
paranoid-implementation (Phase 1 research + Phase 2 failure vectors + Phase 3 mitigations, approved).
**Builds on:** existing `token-server/teams.js` (team CRUD + membership), the in-call Socket.IO
mic-state server (`index.js` ~5184+), and the hardened in-call chat file-upload validation
(`index.js` ~4900+). This is the app's **first native real-time client**.

---

## 1. Summary

The Teams screen becomes a **group chat**. Each team is a persistent room with:

- **Text chat** — append-only message history, delivered live to all online members and
  reconciled from the server on open/reconnect.
- **File sharing** — download chips for any file, inline thumbnails for images. Reuses the
  existing magic-byte / allowlist / size-cap upload hardening; team files persist in **S3**.
- **Instant add by email** — an owner/admin types an email; if it belongs to a registered Inter
  user they are added immediately as an active member; otherwise the UI says *"No Inter account"*.
- **In-app unread badges** — a per-team unread count that clears when the team is opened. No OS
  notifications.

Two architectural commitments drive the build:

1. **Persistence is the source of truth; the socket is a best-effort delivery hint.** Every
   message is written via REST and ordered by a monotonic DB id. A dropped, late, or duplicated
   socket frame can never lose or reorder a message — the client reconciles by fetching history.
   This single principle neutralizes most reliability and concurrency failure modes.
2. **A reusable `InterRealtimeClient` façade.** The native client talks to the server through a
   protocol-agnostic Swift seam (connect / join / on / disconnect + state). The wire
   implementation lives *behind* the façade, so the transport choice is reversible and the same
   pipe later serves lobby, moderation, and presence.

Scope is a **casual group chat now**, but the data model and seams keep roles and future features
open (see §13).

---

## 2. Background — why

`token-server/teams.js` already implements team CRUD and membership (roles owner/admin/member,
status pending/active/removed, invitations keyed by email). The existing `InterTeamsPanel` is a
two-pane "teams list + member detail" AppKit view with no messaging.

The user redefined Task 3: *"use it like a group chat where people belonging to the same team …
can create groups and add members (who are registered with our platform) — they write their email
and are added — and that common room will have a chat box where they can share files and chat."*
The user also required this be **real-time regardless of whether the UI is open** ("these things
are meant to be real-time"), production-standard, and secure.

The app has **no native real-time client today** — in-call mic-state uses a *web* Socket.IO client,
and the native app polls (`index.js` line ~4437: "no Socket.IO client in native app"). Team chat
is therefore the first native real-time client and the foundation for later push features.

---

## 3. Scope & non-goals

**In scope**
- Per-team text chat with persistent history and live delivery.
- File sharing (download chips + image thumbnails), persisted in S3, team-scoped.
- Instant-add members by email (registered users only); owner/admin gated.
- Per-team in-app unread badge; clears on open.
- Native `InterRealtimeClient` façade + a `/teams` Socket.IO namespace (isolated from in-call).
- SwiftUI Teams UI hosted in AppKit via the established bridge pattern, reusing shared components.

**Non-goals (this iteration)**
- Channels / threads / reactions / typing indicators / read-receipts-per-message.
- OS-level (Notification Center) notifications.
- Message editing/deletion, search, pinning.
- End-to-end encryption (transport is TLS/WSS; at-rest follows existing S3 posture).
- Migrating in-call moderation/lobby onto the new client (future; the seam is built to allow it).
- Multi-server horizontal scale-out of the socket layer (single instance today; see §11/§13).

---

## 4. Architecture decisions

### 4.1 Write path — REST writes + Socket.IO read-only fan-out (council Option A)

All state changes (send message, add/remove member, upload file, update read cursor) go through
**REST**, reusing the existing `auth.requireAuth`, `requireIdempotencyKey`, validation, rate-limit,
and multer pipelines. After a successful write, the server **fans the result out** over Socket.IO
to the team room. The socket carries **no state-mutating inbound events** — a client cannot post a
message by emitting a frame. This matches the existing server pattern and shrinks the socket attack
surface to "join/leave + receive".

### 4.2 Transport — pinned `socket.io-client-swift` behind `InterRealtimeClient` (council Option B1)

Per the decision-council verdict: implement the `InterRealtimeClient` façade first, then back it
with the **official `socket.io-client-swift`, pinned to an exact version** with its **Starscream
transitive dependency version-locked and checksum-recorded**. Rationale: a frozen client
implementing a *stable, frozen* protocol against a server we already run is lower-risk than
hand-rolling Engine.IO heartbeat/upgrade/reconnect semantics, and the façade makes the wire choice
reversible.

**Fallback (evidence-gated):** a minimal first-party Engine.IO/Socket.IO-over-`URLSessionWebSocketTask`
client (Option B2) is adopted **only if** a one-day connectivity spike shows the pinned client
cannot complete a JWT handshake + round-trip one `team:message` against the real server. Decision
recorded in the plan; no second server stack (Option C is rejected).

**Pin discipline:** the server's `socket.io` major version and the client's `socket.io-client-swift`
major version are linked. Any server-side Socket.IO major bump triggers a re-run of the client
connectivity spike before deploy.

### 4.3 Namespace isolation — `io.of('/teams')`

Team chat runs on a dedicated Socket.IO **namespace** `/teams` with its **own JWT handshake
middleware**. In Socket.IO v4 a namespace `.use()` guard applies only to that namespace, so the
in-call default-namespace (`/`) leaveToken guard is untouched — team chat **cannot break in-call
moderation**. Rooms within the namespace are named `team:<teamId>`.

### 4.4 File storage — S3 (decision M12)

Team files persist in **S3** (durable, scalable, presigned download — consistent with the existing
recordings pipeline `getSignedUrl(..., expiresIn: 900)`), **not** the in-call chat's local-disk +
24h-TTL scheme (that is call-ephemeral by design). Upload **validation** is reused verbatim from the
in-call pipeline (UUID object key, magic-byte MIME, allowlist + executable/script blocklist, size
caps). *User may veto in favor of persistent local disk.*

---

## 5. Data model

Additive migration **`018_team_chat.sql`**. Existing `teams` / `team_members` (migration 016,
UUID PKs) are unchanged.

```sql
-- Files: metadata; bytes live in S3 under a team-prefixed key.
-- Defined before team_messages because team_messages.file_id references it.
CREATE TABLE IF NOT EXISTS team_files (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id           UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    uploader_user_id  UUID REFERENCES users(id) ON DELETE SET NULL,
    s3_key            TEXT NOT NULL,                     -- e.g. team-files/<teamId>/<uuid>
    original_name     VARCHAR(255) NOT NULL,             -- sanitized
    mime_type         VARCHAR(255) NOT NULL,             -- magic-byte detected
    size_bytes        BIGINT NOT NULL,
    is_image          BOOLEAN NOT NULL DEFAULT false,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_team_files_team_id ON team_files(team_id);

-- Messages: BIGSERIAL id is the monotonic per-team ordering source of truth.
CREATE TABLE IF NOT EXISTS team_messages (
    id                BIGSERIAL PRIMARY KEY,
    team_id           UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    sender_user_id    UUID REFERENCES users(id) ON DELETE SET NULL,
    sender_name       VARCHAR(100) NOT NULL,            -- denormalized snapshot at send time
    kind              VARCHAR(16)  NOT NULL DEFAULT 'text', -- 'text' | 'file'
    body              TEXT,                              -- text content (<= 4000 chars), NULL for file-only
    file_id           UUID REFERENCES team_files(id) ON DELETE SET NULL,
    idempotency_key   VARCHAR(255),                      -- per-(team,sender) dedup of retries
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_team_messages_team_id ON team_messages(team_id, id DESC);
CREATE UNIQUE INDEX IF NOT EXISTS uq_team_messages_idem
    ON team_messages(team_id, sender_user_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;

-- Read cursors: per-(user,team) monotonic last-seen message id (idempotent set-to-max).
CREATE TABLE IF NOT EXISTS team_read_cursors (
    team_id              UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    user_id              UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    last_read_message_id BIGINT NOT NULL DEFAULT 0,
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (team_id, user_id)
);
```

**Ordering note (accepted bound).** `BIGSERIAL` ids order messages within a team. Because ids are
assigned at INSERT but transactions commit independently, a reader paginating `before=<id>` can in
a narrow window miss a row whose id is lower but committed later. For a casual chat this is the
industry-standard tradeoff and is self-healing: the live fan-out covers the active case, and the
next history fetch closes any gap. Strict gap-free ordering (logical clocks) is out of scope.

**Unread count** = `COUNT(*) FROM team_messages WHERE team_id=$1 AND id > cursor`, displayed capped
("9+"). Indexed by `(team_id, id DESC)`. A Redis accelerator is optional (M-level), not required.

---

## 6. Server — REST contract

All routes mounted under the existing `/teams` router, gated by `auth.requireAuth`; writes also use
`requireIdempotencyKey`. Every route that names a `:id` (team) passes through a new
`requireTeamMembership` guard (§10, C1) that derives membership from `req.user.userId` — the client
team id is **never** trusted for authorization.

| Method & path | Purpose | Guard / notes |
|---|---|---|
| `GET /teams/:id/messages?before=<id>&limit=50` | Paginated history, `id DESC`, `limit ≤ 100` | membership; JOIN sender; no N+1 |
| `POST /teams/:id/messages` | Send a text message | membership + idempotency + rate-limit + length cap; persists then fans out |
| `POST /teams/:id/files` | Upload a file (multipart `file`) → creates a `team_files` row **and** a `kind='file'` message | membership + multer (UUID key, `files:1`, size cap) + magic-byte MIME + allowlist/blocklist + per-team S3 size cap; persists then fans out |
| `GET /teams/:id/files/:fileId/url` | Presigned S3 download URL (`expiresIn: 900`) | membership + composite `team_id+fileId` check (H4) |
| `POST /teams/:id/read` | Set read cursor to `max(current, messageId)` | membership; idempotent |
| `GET /teams` | Existing list; **extended** with `unreadCount` per team | membership (existing) |
| `POST /teams/:id/members` | **Instant-add** by email (see below) | membership + **owner/admin role** + rate-limit (H9) |

**Instant-add semantics (replaces invite-by-email).** Body `{ email }`. Server normalizes the email,
looks up a registered user:
- **Found** → upsert `team_members` row `status='active', role='member', user_id=<found>` with
  `ON CONFLICT (team_id, email) DO NOTHING` (idempotent re-add; C-E2), fans out `team:member-added`.
- **Not found** → `404 { error: "No Inter account" }`. *(H9: this discloses registration status by
  design — the product chose instant-add UX. Bounded by owner/admin gating + per-user rate limit +
  audit log. User may switch to a uniform non-revealing response.)*

**Message validation.** `body` trimmed; reject empty/whitespace-only; reject `length > 4000`; SQL is
fully parameterized (existing pattern). `sender_name` snapshotted from `req.user.displayName`.

---

## 7. Server — Socket.IO `/teams` namespace contract

```js
const teamsNsp = io.of('/teams');
teamsNsp.use(jwtHandshakeGuard);   // verifies access JWT; binds socket.data.userId/email (C2)
```

**Handshake auth (C2, H6).** Client connects with `io(url + '/teams', { auth: { token: <accessJWT> },
transports: ['websocket'] })`. The guard `jwt.verify(token, JWT_SECRET, { algorithms:['HS256'],
issuer:'inter-token-server', audience:'inter-macos-client' })`, checks `exp`, and binds
`socket.data.userId/email`. No valid token ⇒ handshake rejected (fail-closed). Token travels in the
**auth payload, never the query string** (avoids access-log leakage).

**Inbound events (the only two; both read-only):**
- `team:join { teamId }` → membership re-checked against `socket.data.userId` (C1); on success
  `socket.join('team:'+teamId)` and registers the socket in a `userId → Set<socketId>` map (for C3
  eviction). On failure, no join (silent).
- `team:leave { teamId }` → `socket.leave('team:'+teamId)`.

**Outbound events (server → room `team:<id>`):**
- `team:message { id, teamId, senderUserId, senderName, kind, body, file?, createdAt }`
- `team:member-added { teamId, member }` / `team:member-removed { teamId, userId }`
- `team:membership-revoked { teamId }` — sent to the specific removed user; client leaves the room
  and drops the team from its UI.

**Hardening (H8).** On the `/teams` namespace set a small `maxHttpBufferSize` (e.g. 16 KB — frames
are tiny JSON; file bytes never traverse the socket), `perMessageDeflate: false`, a per-user
connection cap, and rely on Engine.IO heartbeats for dead-connection cleanup. All handlers wrap
body parsing in try/catch and never `eval`.

**Eviction (C3).** When `POST /teams/:id/members` removal, role change to non-member, or team delete
occurs, the REST handler calls into the namespace: for each socket of the affected `userId`,
`socket.leave('team:'+id)`, emit `team:membership-revoked`, and `disconnect` if appropriate. REST
history/file routes **re-check membership on every call**, so access is denied immediately
regardless of socket timing.

---

## 8. Native client — `InterRealtimeClient` façade + chat service

### 8.1 `InterRealtimeClient` (the reusable seam)

A small Swift protocol, transport-agnostic:

```swift
protocol InterRealtimeClient: AnyObject {
    var stateDelegate: InterRealtimeClientStateDelegate? { get set }
    func connect(tokenProvider: @escaping () -> String?)   // pull a fresh access token per (re)connect
    func join(room: String)
    func leave(room: String)
    func on(_ event: String, _ handler: @escaping (Data) -> Void)
    func disconnect()
}
```

- **Implementation:** `SocketIORealtimeClient` backed by pinned `socket.io-client-swift`, connecting
  to the `/teams` namespace, `transports: [.webSocket]`.
- **Reconnect** with bounded exponential backoff; on each (re)connect the client pulls a **fresh
  access token** via `tokenProvider` (integrates the existing refresh flow). On `exp`/`unauthorized`
  it refreshes then reconnects (H6).
- **State delegate** surfaces connecting/connected/reconnecting/disconnected for a subtle UI dot.
- **Teardown (2C):** `disconnect()` removes all handlers, cancels reconnect timers, clears the
  socket. Called on logout and on Teams-window close.

### 8.2 `InterTeamsChatService` + view models

- `InterTeamsChatService` owns the façade, exposes `joinTeam/leaveTeam`, `sendMessage` (REST POST +
  optimistic local echo keyed by client idempotency id), `uploadFile`, `loadHistory(before:)`,
  `markRead`. It merges live `team:message` frames with fetched history, **deduping by `id`** and
  **sorting by `(createdAt, id)`** (H10), and caps the in-memory buffer (older pages re-fetched on
  scroll — 2C).
- View models: `TeamsListViewModel` (teams + unread badges), `TeamChatViewModel` (message list,
  composer, file attach, connection state, member management for owner/admin).

### 8.3 Token service additions

`InterTokenService` gains `teamsMessages/sendTeamMessage/uploadTeamFile/teamFileURL/markTeamRead/
addTeamMember` calls (account-JWT authed), mirroring the existing REST client style.

---

## 9. UI design (SwiftUI in AppKit, bridge pattern)

Follows the established per-screen bridge: SwiftUI `View` + `ObservableObject` view model +
`@objc` `NSView` bridge hosting `NSHostingView` + a thin-shell ObjC `.m` preserving the existing
`InterTeamsPanel.h`/delegate API so `AppDelegate` is untouched. Reuses shared components
(`InterButton`, `InterInputField`, `InterBanner`, `InterToggle`, `InterWindowChrome`, `handCursor`,
`interResignsFocusOnBackgroundTap`) and design tokens.

**Layout — three regions:**
1. **Teams sidebar** — list of the user's teams, each with avatar/initials, name, and an **unread
   badge** (capped "9+"). "New team" action (owner). Selecting a team opens its room and clears its
   badge (`POST /read`).
2. **Chat room (center)** — scrollback of message bubbles (sender name + relative time), **file
   messages** rendered as download **chips** (icon, filename, size) with **inline thumbnails for
   images**; a composer at the bottom (text field + attach button + send). A subtle connection-state
   dot. Empty state for new rooms. Pagination on scroll-to-top.
3. **Members (owner/admin)** — member list with roles; an **instant-add by email** field
   (`InterInputField`) that shows *"Added"* or the inline *"No Inter account"* error
   (`InterBanner`); remove-member control (owner/admin).

All message text rendered with SwiftUI `Text` (no web view, no HTML) — user content cannot execute
(H7). Filenames shown are the server-sanitized names.

---

## 10. Security model — mitigation map

The heart of the spec. Each Critical/High mitigation maps to a concrete construct and a test (§12).

**C1 — Cross-tenant read/join (IDOR).** `requireTeamMembership(req.user.userId, :id)` REST middleware
(composite `team_id ∩ user_id, status='active'`) on every message/file/read/member route; the
`team:join` socket handler runs the same check before `socket.join`. Client-supplied team id is
never an authorization input.

**C2 — Namespace isolation + fail-closed handshake.** `io.of('/teams').use(jwtHandshakeGuard)`;
default-namespace in-call guard untouched; reject handshake without a valid HS256 access JWT
(issuer/audience/exp verified). `socket.data.userId` is the only identity handlers trust.

**C3 — Stale authorization after removal/role-change/delete.** `userId → Set<socketId>` map per
namespace; removal evicts sockets (`leave` + `team:membership-revoked` + `disconnect`); REST routes
re-check membership every call so a 15-min JWT cannot outlive a membership change.

**H4 — File download IDOR.** `GET /teams/:id/files/:fileId/url` verifies the file's `team_id`
matches `:id` **and** the caller is an active member before presigning (composite key).

**H5 — Malicious upload.** Reused hardened pipeline: multer UUID object key + `files:1` + `fileSize`
cap; magic-byte MIME via `file-type`; allowlist prefixes + executable/script blocklist; sanitized
`original_name`; per-team cumulative S3 size cap; `is_image` set only from detected MIME.

**H6 — JWT handshake exposure/expiry.** Token in `auth` payload (not query string); never logged;
`exp` enforced; expiry → refresh → reconnect via the façade.

**H7 — Injection / unsafe rendering.** Parameterized SQL for all writes; SwiftUI `Text` rendering;
server trims + length-caps + rejects empty; `/teams` namespace registers no mutating inbound events.

**H8 — DoS (flooding / connection exhaustion / oversized payload).** Per-user token-bucket rate
limit on `POST /messages` and `POST /members`; small `maxHttpBufferSize`; per-user connection cap;
`perMessageDeflate:false`; heartbeats.

**H9 — Account enumeration via instant-add.** Owner/admin gated + per-user rate limit + audit log;
the "No Inter account" disclosure is an accepted product decision (user-vetoable).

**H10 — Duplicate / out-of-order.** `requireIdempotencyKey` + unique index
`(team_id, sender_user_id, idempotency_key)`; DB id is ordering SoT; client dedups by id, sorts by
`(createdAt, id)`; socket is best-effort, reconciled by history.

**Medium / Low (non-gating):** M11 multi-instance → build `team:<id>` rooms now so a Socket.IO Redis
adapter is a drop-in later. M12 storage = S3 (decided). M13 namespace origin hygiene. L14 logging:
include team context, never log bodies/tokens. L15 empty-state/boundary UI.

---

## 11. Reliability & real-time semantics

- **Source of truth:** Postgres. The socket frame is an optimization; losing it loses nothing.
- **Send:** optimistic local echo (pending) → REST POST → on 2xx reconcile with the persisted row
  (by client idempotency id) → others receive via fan-out. On failure, the echo shows a retry
  affordance; the idempotency key makes the retry safe.
- **Open / reconnect:** fetch latest history page, then join the room; live frames arriving during
  the fetch are merged and de-duplicated by id.
- **Dependency outages:** Postgres down → POST 5xx, message not persisted (never shown-but-lost).
  Redis down → degrade best-effort. Socket down → messages still persist; client catches up on
  reconnect.
- **Scale:** fan-out is O(active members) — trivial for casual teams; single socket instance today
  (same as in-call). The room model is adapter-ready for horizontal scale (§13).

---

## 12. Testing strategy (mitigation → test)

Server (token-server; `node -c` syntax-check + targeted handler tests):
- C1/H4: a member of team A is denied `GET /teams/B/messages` and `…/files/:id/url` (403/404).
- C2: socket handshake without/with-invalid JWT is rejected; with valid JWT binds the right userId.
- C3: after removal, the removed user's socket stops receiving `team:message` and REST history 403s.
- H5: upload of an executable disguised with an image extension is rejected by magic-byte check.
- H7: empty/oversized message rejected; SQL parameterization covered by existing patterns.
- H8: rate-limit returns 429 past the threshold.
- H10: same idempotency key posted twice yields one row; out-of-order ids sort correctly.

Native (interTests; XCTest):
- `InterRealtimeClient` façade: join/on/leave/disconnect lifecycle; reconnect pulls a fresh token;
  teardown removes handlers/timers (2C leak guard).
- `InterTeamsChatService`: history+live merge dedups by id and sorts by `(createdAt,id)`; optimistic
  echo reconciles; unread count clears on `markRead`.
- View models: list badges, composer validation, instant-add success vs "No Inter account".

A mitigation is not "done" until its Critical/High test passes (paranoid Phase 5).

---

## 13. Delivery phases

1. **DB + REST core** — migration 018; `GET/POST messages`, `requireTeamMembership`, idempotency,
   validation, rate-limit; `GET /teams` unread extension; tests. (No socket yet — REST is usable.)
2. **`/teams` namespace + fan-out** — namespace, JWT handshake guard, join/leave, message fan-out,
   eviction; hardening (buffer/deflate/conn-cap); tests.
3. **`InterRealtimeClient` façade + connectivity spike** — façade + pinned `socket.io-client-swift`;
   day-3 spike (JWT handshake + one round-trip) decides B1 vs B2 fallback; record pins + hashes.
4. **Files** — S3 upload route (reused validation) + presigned download + `team_files`; chips +
   image thumbnails; tests.
5. **SwiftUI UI + bridge** — sidebar/chat/members, unread badges, instant-add; visual diff vs
   reference; preserve `InterTeamsPanel.h` API.
6. **Wire-through + verification** — AppDelegate window, logout/close teardown, full Phase-5 test
   sweep.

Each phase is a reviewable unit; phases 1–2 ship value before the native client exists.

## 14. Open decisions (recorded; user-vetoable)

- **H9 — enumeration:** accept the rate-limited, owner/admin-gated *"No Inter account"* response
  (chosen for instant-add UX). Alternative: uniform non-revealing response.
- **M12 — storage:** **S3** for team files (durable, presigned, matches recordings). Alternative:
  persistent local disk (matches in-call chat code, simpler, less durable).

## 15. Future seams (kept open, not built now)

- **Roles/permissions:** `role` column retained; UI currently owner+members only.
- **Channels/threads, reactions, typing, per-message receipts:** schema leaves room; not modeled.
- **OS notifications:** unread is in-app only; a notifier could subscribe to the same fan-out.
- **Reuse the façade for lobby/moderation/presence:** the whole point of `InterRealtimeClient`.
- **Horizontal scale:** add a Socket.IO Redis adapter; the `team:<id>` room model already fits.
```