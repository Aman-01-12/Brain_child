# Implementation Plan — Candidate Presence Monitoring (Phase 0 + Phase 1)

**Spec:** `/Users/aman_01/Documents/inter/.agents/tasks/proctoring-research/gaze-facial-analysis-research.md` Part 7 is the design spec. Implement it faithfully.
**Ground truth for file/symbol/line facts:** `/Users/aman_01/Documents/inter/.agents/tasks/face-verification-design/codebase-recon.md`, re-verified against the working tree on 2026-10-31 (every line number below was read from the tree, not from the recon).
**Patterns to reuse (do NOT implement either feature):** `docs/superpowers/specs/2026-10-27-interview-face-verification-design.md` §13 (human override, mandatory reason, additive records) and `docs/superpowers/specs/2026-06-10-consent-first-moderation-design.md` (persistent indicator, never a toast, one pure derivation function).

**Status after the 2026-10-31 scope adjustment:** this feature is **provisional and evaluation-first**. It ships behind ONE master flag that is OFF by default, and it is designed to be deleted cheaply. The build is not "ship it"; the build is "make it measurable, honest, and removable."

---

## 0. The three decisions that shape everything below

**D0.1 — One master flag, one server condition, four client call sites.**
A single server env var `PRESENCE_MONITORING_ENABLED` (default `false`) is consulted in exactly **two** server places, both inside new files: the `/presence` router's first middleware, and the pure `resolvePresenceArming()` predicate called from `/room/create`. Nothing else reads it. When it is off, the server never writes `presenceMonitoringArmed` to the room hash, so `/room/join` omits the whole presence block, so the client's `activePresenceMonitoringArmed` parses `false` by its backward-compatible default — identical to talking to today's server. The client then has exactly four guarded call sites, each a single `if` on one boolean, each listed in `REMOVAL.md`. Rationale: a reviewer must be able to confirm "flag off ⇒ zero behavioural change" by reading one condition. Chosen over per-signal flags (which would require tracing five) and over not mounting the router at all (which would make the flag unreadable at module scope and the integration tests order-dependent).

**D0.2 — `-showIntervieweeConfirmationWithCompletion:` is KEPT as the live path.**
`AppDelegate.m:2365` stays exactly as it is and remains the path taken whenever the flag is off. The new consent screen is reached only through the new `if`. The monitored consent screen repeats the secure-mode bullets that the `NSAlert` carries (full-screen secure window, screen sharing restricted, external displays blocked when `InterShouldEnforceInterviewExternalDisplayPolicy()`) so the monitored path loses no disclosure, but the alert is **not** deleted and **not** modified.

**D0.3 — Phase 0 is "shippable with the detector stubbed" in this codebase means:**
with `PRESENCE_MONITORING_ENABLED=true` and a `hiring` host arming a room, a candidate sees the real consent screen, chooses, the server records consent + monitoring state + thresholds, the persistent indicator renders the true state for the whole session, the interviewer sees "Presence monitoring on/off" and an (empty) timeline with per-type counts of zero and a working export, the retention sweeper purges on schedule, and every transition lands in `audit_events` — **with zero frames sampled and zero `VNRequest` ever constructed**. Concretely: `InterPresenceCoordinator` exists and is started, but in Phase 0 it is built without an `InterPresenceDetector`/`InterPresenceCaptureSource` (the two are added in Phase 1), so its event stream is empty. Phase 0 is verified green before any Vision code is written.

---

## Phase ordering

- **Items 1–11 = Phase 0** (legal/consent/UX surface + server + schema, detector stubbed). Independently complete, independently verifiable.
- **Items 12–16 = Phase 1** (the on-device detector). Depends on items 1–11 being green.
- **Items 17–18 = documentation** (design note, `REMOVAL.md`). Written last so they record what was actually built.

Every item leaves the tree buildable. No git command is run at any point — the user commits.

---

# Implementation Plan

## Phase 0 — server

- [ ] 1. Create the presence config + arming predicate module (pure, no I/O).
      `PRESENCE_MONITORING_ENABLED` (default `false`), `PRESENCE_EVENT_RETENTION_DAYS` (default `90`, clamped to 1…3650, non-finite → 90), `PRESENCE_MULTIPLE_FACES_ENABLED` (default `false`), `PRESENCE_GAP_SECONDS` (default `60`), `PRESENCE_SWEEP_INTERVAL_MS` (default `3600000`), `PRESENCE_STALE_SESSION_MINUTES` (default `10`), `PRESENCE_RIGHTS_CONTACT` (default `'privacy@kiomeet.invalid'`). Every getter reads `process.env` **at call time**, not at module load, so tests can flip the flag. Exports `isFeatureEnabled()`, `retentionDays()`, `multipleFacesEnabled()`, `gapSeconds()`, `thresholdSnapshot()` (the frozen object written onto every row), `DETECTOR_VERSION = 'presence-1.0.0'`, and the pure `resolvePresenceArming({ featureEnabled, roomType, hostTier, requested, candidateRegionEU, candidateUnder18 })` → `{ armed, reason }` where `reason` ∈ `'feature_disabled' | 'not_interview' | 'tier' | 'eu_region' | 'under_18' | 'not_requested' | 'armed'`. `armed` is true only when every condition passes; EU and under-18 force `false` with a load-bearing comment citing §7.9 items 7 and 8.
      Files: `/Users/aman_01/Documents/inter/token-server/presenceConfig.js`
      Verify: `cd /Users/aman_01/Documents/inter/token-server && npm test` — suite still green (no new tests yet; this item only adds an unreferenced pure module).

- [ ] 2. Write migration `023_interview_presence_events.sql`.
      Three tables, additive, `IF NOT EXISTS` throughout (the 016/020 precedent), header comment block stating intent and an `-- ASSERT:` line for `users`, `meetings` and `trigger_set_updated_at()` (defined in `001_initial_schema.sql`). Full DDL intent in §A below. Also add a `023_interview_presence_events.sql` row to the README migration table at `/Users/aman_01/Documents/inter/README.md:396`.
      Files: `/Users/aman_01/Documents/inter/token-server/migrations/023_interview_presence_events.sql`, `/Users/aman_01/Documents/inter/README.md`
      Verify: `cd /Users/aman_01/Documents/inter/token-server && node migrate.js` prints the 023 application and exits 0; then `psql "$DATABASE_URL" -c "select filename from schema_migrations where filename like '023%'"` returns exactly one row, and `psql "$DATABASE_URL" -c "\d interview_presence_events"` shows the columns and the three indexes. Re-run `node migrate.js` and confirm it reports nothing pending (forward-only, no re-apply). Do NOT drop or alter any pre-existing table.

- [ ] 3. Create the pure ingest validator with the explicit allowlist and rejected-key list.
      `EVENT_TYPES` (the 6 enum values), `CLIENT_EVENT_TYPES` (the 5 a client may send — `monitoring_gap` is server-generated and must be rejected from a client payload), `ALLOWED_EVENT_KEYS`, `FORBIDDEN_KEYS` (§B verbatim), `MAX_BATCH = 100`. `validateEventBatch(body, { multipleFacesEnabled })` → `{ ok: true, events }` or `{ ok: false, status, code, error, field }`. Matching rule for forbidden keys: normalise each key by lowercasing and stripping `_` and `-`, then compare against the normalised forbidden set, applied **recursively to every object key at every depth including inside arrays** — so a nested `{"meta":{"face_score":…}}` is caught. Forbidden key wins over unknown key so the error names the prohibited concept. Strict allowlist rejects anything else. No I/O, no `require` beyond nothing — this is the anti-drift pure function (the `joinGuards.js` / `deriveRemoteTileState` pattern).
      Files: `/Users/aman_01/Documents/inter/token-server/presenceEvents.js`
      Verify: `cd /Users/aman_01/Documents/inter/token-server && node --test test/presenceEvents.test.js` — all cases in item 9 pass.

- [ ] 4. Create the retention sweeper, dependency-injected like `recordingQuota.js`.
      `createPresenceSweeper({ db, auditLog, config, logger = console })` → `sweepOnce()` which (a) `DELETE FROM interview_presence_events WHERE purge_after <= NOW()`, (b) `DELETE FROM interview_presence_sessions WHERE purge_after <= NOW()` (notes and events cascade), (c) `closeStaleSessions()`: for rows with `monitoring_enabled = true AND ended_at IS NULL AND last_report_at < NOW() - interval 'N minutes'`, insert one terminal `monitoring_gap` event spanning `[last_report_at, NOW()]` and set `ended_at = NOW()`. Returns `{ eventRows, sessionRows, staleClosed }`. Idempotent by construction: every statement is guarded by a predicate the first run falsifies (`purge_after <= NOW()`, `ended_at IS NULL`). Writes `presence_events_purged` to `audit_events` via the injected `auditLog` only when something was deleted, `userId` null, metadata `{ eventRows, sessionRows, retentionDays }`.
      Files: `/Users/aman_01/Documents/inter/token-server/presenceRetention.js`
      Verify: `cd /Users/aman_01/Documents/inter/token-server && node --test test/presenceRetention.test.js` — all cases in item 10 pass.

- [ ] 5. Create the `/presence` router (all HTTP, authz, rate limiting), dependency-injected.
      `createPresenceRouter({ db, redis, crypto, tiers, config, auditLog, requireAuth, validateModerator, getRoomData, roomKey, roomLeaveTokenKey, constantTimeEqual, sanitizeFilename, logger })` → an Express `Router`. Endpoints, authz, codes and the rate limiter in §C. First middleware on the router is `requirePresenceFeature` → `404 { error: 'Not found', code: 'PRESENCE_DISABLED' }` when `config.isFeatureEnabled()` is false. Every `audit_events` write goes through the injected `auditLog` (never a hand-rolled INSERT), is not awaited, and carries no raw note text and no email.
      Files: `/Users/aman_01/Documents/inter/token-server/presence.js`
      Verify: `cd /Users/aman_01/Documents/inter/token-server && npm test` — existing suite still green and `node -e "require('./presence.js')"` exits 0.

- [ ] 6. Wire the router, the arming snapshot and the sweeper schedule into `index.js`.
      Four edits, each a single contiguous hunk so it is obvious to delete:
      (a) requires next to `const { createOverdueRecordingSweeper } = require('./recordingQuota');` at line 82;
      (b) `app.use('/presence', presenceRouter)` in the mount block with the other four routers (`index.js:139–152`), after `auth.authenticateToken` so `req.user` is populated — the router is built just above the mount with the real deps including the local `validateModerator` (line 2223), `getRoomData`, `roomKey`, `roomLeaveTokenKey` and `constantTimeEqual` (line 423). NOTE: those helpers are declared *below* line 152 in the file; build the router lazily (`app.use('/presence', (req, res, next) => presenceRouterLazy()(req, res, next))`) **or** move the mount to just after the key-helper block near line 2290 where `sweepOverdueRecordings` is built. Prefer the latter: mounting next to `sweepOverdueRecordings` keeps the deps in scope, keeps the edit to one hunk, and `auth.authenticateToken` at line 135 still runs first because it is app-level;
      (c) in `app.post('/room/create', …)` (line 2375): read `presenceMonitoring`, `candidateRegionEU`, `candidateUnder18` from the body, call `resolvePresenceArming(...)` with `hostTier` (the value already snapshotted at line ~2450) and write `presenceMonitoringArmed`, `presenceRegionEU`, `presenceUnder18`, `presenceMultipleFacesEnabled`, `presenceDetectorVersion`, `presenceThresholds` (JSON string) into the `pipeline.hset(roomKey(roomCode), …)` call **only when `armed` is true** — when not armed, write nothing, so a flag-off room hash is byte-identical to today's;
      (d) in `app.post('/room/join', …)` response object (around line 2800): add the presence block **only** when `roomData.presenceMonitoringArmed === 'true'`, as `presenceMonitoringArmed: true, presenceRetentionDays, presenceRegionEU, presenceUnder18, presenceMultipleFacesEnabled, presenceDetectorVersion, presenceThresholds, presenceRightsContact`. One `if`, one spread.
      (e) inside the `if (require.main === module)` block (line 5762), next to `recordingSweepTimer` (line 5781): a `presenceSweepTimer` `setInterval` at `config.sweepIntervalMs()`, errors caught and logged, `.unref()`ed, started only when `config.isFeatureEnabled()`.
      Files: `/Users/aman_01/Documents/inter/token-server/index.js`
      Verify: `cd /Users/aman_01/Documents/inter/token-server && npm test` — the whole existing suite green, in particular `test/interviewTierGate.test.js` and `test/toolsEntitlement.test.js` unchanged. Then with the flag unset, start `node index.js`, `curl -i localhost:3000/presence/events` → `404` with `code: 'PRESENCE_DISABLED'`, and `curl -s localhost:3000/health` still 200.

- [ ] 7. Add the presence writes to the audit trail (no new mechanism).
      Event types, all `snake_case` and ≤ 50 chars, written with `auth.auditLog(userId, type, req.ip, metadata)`: `presence_consent_granted`, `presence_consent_declined`, `presence_monitoring_enabled`, `presence_monitoring_disabled`, `presence_timeline_read`, `presence_note_added`, `presence_export`, `presence_events_purged`. `userId` is `null` for a guest candidate and the identity lives in `metadata` — exactly what `audit_events.user_id` (`ON DELETE SET NULL`, migration 011) is designed for. Metadata never contains note text, email, thresholds-as-free-text or any key from the forbidden list.
      Files: `/Users/aman_01/Documents/inter/token-server/presence.js` (call sites)
      Verify: covered by `test/presenceGate.test.js` asserting an `audit_events` row exists for a consent grant and a decline (`SELECT event_type FROM audit_events WHERE event_type LIKE 'presence_%'`), then cleaned up — note `audit_events` forbids `DELETE` at the database, so the test asserts presence only and does not attempt cleanup of those rows.

## Phase 0 — server tests

- [ ] 8. (ordering note) Items 9–11 are the three §7.8 server test files. Write them against the modules from items 1–7; they are the verification gate for the whole server surface.

- [ ] 9. `test/presenceEvents.test.js` — pure unit, no DB, no Redis (the `fileValidation.test.js` style: `node:test` + `node:assert`).
      Cases: every one of the five client event types is accepted; `monitoring_gap` from a client is rejected `400 PRESENCE_EVENT_TYPE_NOT_ALLOWED`; `head_off_axis` is rejected (Phase 2 is out of scope and must not be ingestible); an unknown type is rejected; **a payload containing each of `landmarks`, `score`, `emotion`, `confidence`, `attention`, `engagement` is rejected with HTTP status 400 and `code: 'PRESENCE_FORBIDDEN_FIELD'` and the response names the offending key — asserted individually, one `test()` per key, and asserted as rejection not omission** (the validator must not return `ok: true` with the key stripped); the same for a key nested two levels deep and for a key inside an array element; `faceScore`, `face_score` and `FACE-SCORE` all normalise to the same rejection; `yaw`/`pitch`/`roll` are rejected (head pose is not collected); `frame`/`image`/`landmarks` are rejected (no pixels ever); a well-formed batch of 100 is accepted and 101 is `413 PRESENCE_BATCH_TOO_LARGE`; `multiple_faces` is rejected `409 PRESENCE_EVENT_TYPE_DISABLED` when `multipleFacesEnabled` is false and accepted when true; `durationMs` must be a non-negative integer and `endedAt >= startedAt`; a `thresholds` key supplied by the client is rejected as an unknown key (the server stamps thresholds, never the client).
      Files: `/Users/aman_01/Documents/inter/token-server/test/presenceEvents.test.js`
      Verify: `cd /Users/aman_01/Documents/inter/token-server && node --test test/presenceEvents.test.js` — 0 failures.

- [ ] 10. `test/presenceRetention.test.js` — sweeper with injected fakes (`recordingQuota.test.js` style; no live DB).
      Cases: a fake `db` recording every `query(text, params)` call; due rows (`purge_after <= NOW()`) are purged and the sweeper reports their count; not-yet-due rows are untouched (assert the DELETE statement carries the `purge_after <= NOW()` predicate and that a row with a future `purge_after` is not in the returned count); a second `sweepOnce()` on an already-swept fake returns zeros — idempotent; `closeStaleSessions` inserts exactly one `monitoring_gap` per stale session and sets `ended_at`, and a second run inserts none because `ended_at IS NULL` no longer matches; a `db.query` rejection is caught, logged and does not throw out of `sweepOnce()`; `retentionDays()` honours `PRESENCE_EVENT_RETENTION_DAYS` and falls back to 90 for unset, `'0'`, `'abc'` and a negative value; `auditLog` is called exactly once with `presence_events_purged` when rows were deleted and **not at all** when nothing was deleted.
      Files: `/Users/aman_01/Documents/inter/token-server/test/presenceRetention.test.js`
      Verify: `cd /Users/aman_01/Documents/inter/token-server && node --test test/presenceRetention.test.js` — 0 failures.

- [ ] 11. `test/presenceGate.test.js` — integration against the dev DB + Redis, following `test/interviewTierGate.test.js` verbatim as the template (`require('dotenv')`, import `{ app }` from `./index`, `app.listen(0,'127.0.0.1')`, `h.createUser({tier})`, `h.tokenFor`, `h.api`, track ids, `after()` → `h.cleanupUsers(track)` + `h.db.pool.end()` + `redis.disconnect()`).
      Cases, in two groups.
      **Group A — master flag OFF (the zero-impact proof):** with `PRESENCE_MONITORING_ENABLED` deleted from `process.env`, every `/presence/*` path returns `404` with `code: 'PRESENCE_DISABLED'`; a `hiring` host calling `POST /room/create` with `roomType:'interview', presenceMonitoring:true` succeeds and `redis.hgetall(room:{CODE})` contains **no key starting with `presence`**; the subsequent `POST /room/join` response object contains **no key starting with `presence`**.
      **Group B — master flag ON** (`process.env.PRESENCE_MONITORING_ENABLED = 'true'` set in the test before the requests; the config getters read at call time so no module reload is needed): a **`pro`**-tier host cannot enable monitoring — `POST /room/create` with `roomType:'interview'` returns `403` with `code: 'INSUFFICIENT_TIER'` and `requiredTier: 'hiring'` (the real strings), and separately a `pro`-hosted *call* room created with `presenceMonitoring:true` has `presenceMonitoringArmed` absent from the room hash; `POST /presence/events` against a room whose hash `hostTier` is `pro` returns `403 INSUFFICIENT_TIER` (seed the hash directly so the assertion is about the presence gate, not the create gate); **a declining candidate joins successfully with monitoring off** — `POST /room/join` 200 with a token, then `POST /presence/consent {decision:'decline'}` with the join's `leaveToken` returns `200 { monitoringEnabled: false, consentState: 'declined' }`, the session row has `monitoring_enabled = false`, and the interviewer's timeline reports `monitoringEnabled: false`; **a non-moderator cannot read another identity's timeline** — an authenticated non-host user calling `GET /presence/timeline/:code/:otherIdentity` with their own `callerIdentity` gets `403` and, critically, an authenticated participant passing the *host's* identity as `callerIdentity` also gets `403` (the `validateModerator` → `roomUserBindingKey` cross-check); a missing/ wrong `Leave-Token` on ingest returns `403 PRESENCE_UNAUTHORIZED`; a `hiring` host armed room accepts a 3-event batch and the timeline returns them with per-type counts and `summary.byType`; a note shorter than 10 characters returns `400 PRESENCE_NOTE_REASON_REQUIRED` and a 10+ character note is stored and audited; `GET /presence/export/...?format=csv` returns `text/csv` with a header row and one row per event; the EU and under-18 flags each force `presenceMonitoringArmed` absent even for a `hiring` interview host.
      Cleanup: delete the created room keys from Redis and the `interview_presence_sessions` rows (events/notes cascade) in `after()`, before `cleanupUsers`.
      Files: `/Users/aman_01/Documents/inter/token-server/test/presenceGate.test.js`
      Verify: `cd /Users/aman_01/Documents/inter/token-server && npm test` — all 16 test files pass, 0 failures. State the pass/fail counts, not just the exit code.

## Phase 0 — client

New Swift/Obj-C files dropped under `inter/` and `interTests/` are picked up automatically: `inter.xcodeproj/project.pbxproj` uses `objectVersion = 77` with `PBXFileSystemSynchronizedRootGroup` for both `inter` (id `042FD4042F1A72D60031193C`) and `interTests` (id `04AABB0A2F5CD0000031193C`). **Do not hand-edit `project.pbxproj`.**

- [ ] 12. Plumb the presence settings through the networking layer (additive, backward-compatible).
      (a) `InterRoomConfiguration` (`inter/Networking/InterNetworkTypes.swift:195`–`280`): add `@objc public var presenceMonitoring: Bool` (default `false`), `candidateRegionEU: Bool`, `candidateUnder18: Bool`; set them in `init`, carry them in `copy(with:)`, and add the three keys to `meetingSettingsDict` (line 274) so `createRoom` sends them with zero change to `createRoom` itself (it already merges the dict).
      (b) `InterJoinRoomResponse` (`inter/Networking/InterTokenService.swift:59`): add `presenceMonitoringArmed: Bool = false`, `presenceRetentionDays: Int = 90`, `presenceRegionEU: Bool = false`, `presenceUnder18: Bool = false`, `presenceMultipleFacesEnabled: Bool = false`, `presenceDetectorVersion: String = ""`, `presenceRightsContact: String = ""`; parse them in the `/room/join` branch (around line 1100) with those defaults, matching the existing style exactly. The defaults are the zero-impact guarantee: an omitted block yields `armed == false`.
      (c) `InterRoomController` (`inter/Networking/InterRoomController.swift`): add to the "Active Meeting Settings" block (line ~220–247) `@objc public private(set) dynamic var activePresenceMonitoringArmed/RetentionDays/RegionEU/Under18/MultipleFacesEnabled/DetectorVersion/RightsContact`, plus `@objc public private(set) dynamic var activePresenceMonitoringGranted: Bool = false` and `activePresenceConsentState: String = "pending"`. Assign them in the join branch (line ~479–500) inside the existing `DispatchQueue.main.async` block **before** `handleTokenResponse` is called — the same ordering the existing `activeLobbyEnabled` assignment relies on (both are enqueued from one background thread in order, so the gate at line 608 observes them). Mirror them in `applyMeetingSettingsFromDict` (line ~252) for the lobby-admitted path. Add `@objc public func recordPresenceConsent(granted: Bool, state: String)` as the single writer of the granted/state pair. **Do not change the `preConnectConsentGate` signature at line 348** — the gate block reads these properties instead.
      (d) `InterTokenService`: add `submitPresenceConsent`, `uploadPresenceEvents`, `fetchPresenceTimeline`, `submitPresenceNote`, `fetchPresenceExport` using `performAuthHTTPRequest` (line 3419) for the moderator calls with `bearerToken: currentAccessToken`, and the `Leave-Token` header read from `leaveTokenStore[roomCode]` on the `cacheQueue` (the `uploadChatFile` precedent at line 1205) for the candidate calls. Never log a payload; log only counts.
      Files: `inter/Networking/InterNetworkTypes.swift`, `inter/Networking/InterTokenService.swift`, `inter/Networking/InterRoomController.swift`
      Verify: `cd /Users/aman_01/Documents/inter && xcodebuild build -project inter.xcodeproj -scheme inter -configuration Debug -destination 'platform=macOS'` ends in `** BUILD SUCCEEDED **`; then `xcodebuild test -project inter.xcodeproj -scheme inter -configuration Debug -destination 'platform=macOS' -only-testing:interTests/InterTokenServiceTests -only-testing:interTests/InterRoomControllerTests` passes.

- [ ] 13. Create the consent screen triad and the single guarded call site in `AppDelegate.m`.
      (a) `PresenceConsentViewModel.swift` — `@MainActor final class PresenceConsentViewModel: ObservableObject` with `@Published private(set) var state: PresenceConsentState` (`.monitoredOffer`, `.monitoringOffNotice`, `.details`) and intents `acceptMonitoring()`, `declineMonitoring()`, `cancelJoin()`, `showDetails()`, `dismissDetails()`, plus `var onDecision: ((PresenceConsentDecision) -> Void)?` where `PresenceConsentDecision` ∈ `.joinWithMonitoring | .joinWithoutMonitoring | .cancel`. **It holds no camera, no media controller and no capture session** — structurally incapable of enabling a camera, which is what the §7.8 test asserts. Also carries the pure, `nonisolated static` pieces:
        - `enum PresenceConsentMode: Int { case legacyAlert = 0, monitoredOffer = 1, monitoringOffNotice = 2 }` and `static func mode(armed: Bool, regionEU: Bool, under18: Bool) -> PresenceConsentMode` — returns `.legacyAlert` whenever `armed == false` for **every** combination of the other two, `.monitoringOffNotice` when `regionEU || under18`, else `.monitoredOffer`. This is the one function the zero-impact client test enumerates.
        - `struct PresenceDisclosure` — the single source of the eight §7.4 content items as static strings, reused verbatim by the mid-session details sheet so the two can never drift. Copy reviewed against §7.10: never the words cheating, dishonesty, integrity, attention, focus, engagement, emotion, mood, confidence, proctoring, eye tracking, gaze, verify/identity, accuracy, tamper-proof.
        - `static func indicatorLabel(_ state: Int) -> String?` → `nil` / `"Presence monitoring on"` / `"Presence monitoring off"` / `"Presence monitoring paused — camera off"`.
      (b) `PresenceConsentView.swift` — pure SwiftUI reading the view model. §7.6 modal archetype rendered on a stage surface: centred card max 600 pt, `InterColor.stageElevated` fill, `InterRadius.xxl` (10), 1 pt `InterDesignTokens.stageBorder` (white @ 10 %), `InterSpacing.x6` padding, on an `InterColor.stage` scrim; title `InterFont.Size.title` semibold in `InterColor.stageText`; body `InterFont.Size.secondary` in `stageTextSecondary` with `InterFont.lineSpacing(cssLineHeight: 1.6, size: 14)`; list rows at `InterSpacing.x2`. Action row: **two equal-weight `InterButton`s side by side, same width, same `InterControl.primaryHeight` (40)** — "Join with presence monitoring" and "Join with monitoring off" — plus a tertiary "Cancel and leave" text button. Neither join button is styled destructive and neither is greyed; the decline button is not a link. ⏎ confirms the monitored option, Esc routes to cancel. A plain-language negative list block, visually distinct, carrying §7.4 item 2 verbatim. A "What is and isn't measured" disclosure row that opens `.details`.
      (c) `InterPresenceConsentHostView.swift` — `@objc(InterPresenceConsentHostView) public final class … : NSView`, built on the `InterGreenRoomHostView` shape: `@objc init(frame:mode:retentionDays:rightsContact:externalDisplayPolicy:)`, internal `NSHostingView<PresenceConsentView>`, `appearance = NSAppearance(named: .darkAqua)`, `@objc public var onDecision: ((Int) -> Void)?` (0 cancel / 1 monitored / 2 monitoring-off).
      (d) `AppDelegate.m` — **one new `if` inside the existing gate block at lines 334–350**, placed after the `intervieweeJoiningInterview` guard and before the existing `showIntervieweeConfirmationWithCompletion:` call:
      ```objc
      // PRESENCE MONITORING (provisional, server flag default OFF). When the flag is
      // off the server omits the presence block from /room/join, so this is NO and the
      // legacy path below runs byte-for-byte unchanged. Delete this `if` to remove the
      // feature from the join flow. See .agents/tasks/presence-monitoring/REMOVAL.md.
      if (gateSelf.roomController.activePresenceMonitoringArmed) {
          [gateSelf showPresenceConsentWithCompletion:decide];
          return;
      }
      ```
      and a new `-showPresenceConsentWithCompletion:` method placed immediately after `-showIntervieweeConfirmationWithCompletion:` (line 2365, which is **not modified**). It builds `InterPresenceConsentHostView` in a titled non-resizable `NSWindow` with `[win setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]]` and `[win setSharingType:InterWindowSharingType()]` (every protected window does — never hardcode `NSWindowSharingNone`), centres it, and on decision closes the window, calls `[rc recordPresenceConsent:granted state:…]`, then `decide(decision != 0)`. Monitoring-off and monitored both `decide(YES)`; only Cancel `decide(NO)` → the untouched `handleConsentDeclined` slot-release path and `.consentDeclined` (1020), already handled benignly at AppDelegate lines 1327, 2222 and 4495. **No new `InterNetworkErrorCode`** is added and `isExpectedJoinRejection` is not touched — deliberate, because 1020 already carries the only rejection this flow produces.
      (e) After the join completes, POST the recorded decision to `/presence/consent` from the existing post-join routing (AppDelegate lines ~1340–1356 / ~2239–2252 branch on `roomType == "interview"`), one guarded call.
      Files: `inter/UI/SwiftUI/Screens/PresenceConsentViewModel.swift`, `inter/UI/SwiftUI/Screens/PresenceConsentView.swift`, `inter/UI/SwiftUI/Screens/InterPresenceConsentHostView.swift`, `inter/App/AppDelegate.m`
      Verify: `xcodebuild build …` BUILD SUCCEEDED, then `xcodebuild test … -only-testing:interTests/InterPresenceConsentViewModelTests` passes (item 16).

- [ ] 14. Add the persistent candidate indicator to the secure-window chrome.
      (a) `SecureCandidateChromeViewModel.swift`: `@Published public var presenceMonitoringState: Int = 0` (0 absent, 1 on, 2 off, 3 paused — camera off) and `public var onOpenPresenceDetails: (() -> Void)?`. Default 0 means the chip never renders unless something sets it, so flag-off needs no guard.
      (b) `SecureCandidateChromeViews.swift`: a `presenceBadge` chip in `SecureCandidateTopBarView`'s `HStack`, next to `recordingBadge` (line 64) and before `candidateBadge` (line 83). Non-dismissible — no × and no auto-hide. Icon + word always paired (`DESIGN-SPEC.md` §8: never signal state by colour alone): `eye` + "Presence monitoring on" tinted `InterStatus.success`, `eye.slash` + "Presence monitoring off" in `InterColor.stageTextMuted`, `pause.circle` + "Presence monitoring paused — camera off" tinted `InterStatus.warning`. The whole chip is the tap target and fires `onOpenPresenceDetails`. **This is a persistent chip, not an `InterLobbyToast` and not any toast** — the consent-first moderation doc rejects toasts because they conflate "declined" with "never saw it."
      (c) `InterSecureChromeBridge.swift`: `@objc public func setPresenceMonitoringState(_ state: Int)` and `@objc public var presenceDetailsHandler: (() -> Void)?`, wired in `init` and nilled in `invalidateHandlers()` (so no block outlives the session, paranoid #8).
      (d) `SecureWindowController.h/.m`: `- (void)setPresenceMonitoringState:(NSInteger)state;` tolerating being called before the window exists by storing `pendingPresenceState` and applying it in `createSecureWindow` — the exact `setRecordingIndicatorActive:` / `pendingRecordingActive` pattern at lines 128–155. Wire `self.controlPanel.presenceDetailsHandler` in `-attachControlPanelInView:` (line ~370) to present `InterPresenceConsentHostView` in `.details` mode in an `NSPanel` one level above the secure window (`NSScreenSaverWindowLevel + 1`, the `setupChatOverlayWindow` pattern at line ~143) with `setSharingType:InterWindowSharingType()`.
      Files: `inter/UI/SwiftUI/Screens/SecureCandidateChromeViewModel.swift`, `inter/UI/SwiftUI/Screens/SecureCandidateChromeViews.swift`, `inter/UI/SwiftUI/Screens/InterSecureChromeBridge.swift`, `inter/UI/Controllers/SecureWindowController.h`, `inter/UI/Controllers/SecureWindowController.m`
      Verify: `xcodebuild test … -only-testing:interTests/SecureCandidateChromeViewModelTests -only-testing:interTests/InterPresenceConsentViewModelTests` passes; `xcodebuild build …` BUILD SUCCEEDED.

- [ ] 15. Add the interviewer live chip, the evaluation timeline and the export actions.
      (a) `CallControlBarViewModel.swift`: `@Published public var presenceAvailable = false`, `presenceMonitoringEnabled = false`, `presenceLiveEventType: String?` (settable **only** to `"multiple_faces"` or `"face_absent"`, enforced by a guard in the setter path), `presenceTimelineVisible = false`; `nonisolated static func presenceChipLabel(available:monitoringEnabled:liveEventType:) -> String?` → `nil` when unavailable, `"Presence monitoring off"` when disabled, `"Second face visible"` / `"Face not visible"` for the two live types, else `"Presence monitoring on"`. `presenceAvailable` defaults false → the chip is absent with no guard.
      (b) New `PresenceTimelineViewModel.swift` + `PresenceTimelineView.swift` under `inter/UI/SwiftUI/Screens/`. The view model holds `rows: [PresenceTimelineRow]`, `summary: [PresenceTypeSummary]` (`eventType`, `count`, `totalDurationMs`), `sessionDurationMs`, `monitoringEnabled`, `consentState`, `detectorVersion`, `thresholdsJSON`, `multipleFacesEnabled`, and intents `refresh()`, `jumpTo(row:)`, `addNote(row:text:)`, `copyJSON()`, `saveCSV()`. Note Save is disabled until `text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10` — a mirror of the server rule, with the server as the control. **Evaluation-first presentation, and no score:** the summary block renders per-type count and total duration as plain rows ("Face not visible — 3 events, 41 s total") with **no total, no weighting, no normalisation, no percentage, no rating and no comparison to any other candidate or session**; add a code comment on the summary struct citing §7.2 so the prohibition travels with the type. A footer states the thresholds and detector version in force, because an event means nothing without its operating point.
      (c) `InterCallControlBarBridge.swift`: `@objc public func setPresenceAvailable(_:)`, `setPresenceMonitoringEnabled(_:)`, `setPresenceLiveEventType(_:)`, `@objc public var presenceTimelineRefreshHandler`, `presenceJumpToHandler: ((Double) -> Void)?`, `presenceNoteHandler: ((String, String) -> Void)?`; present the timeline with `NSPopover` + `NSHostingController(rootView: PresenceTimelineView(viewModel:))`, `behavior = .transient`, `contentSize 420×480` — the `presentRequestsPanel()` pattern at line ~226. `saveCSV()` goes through an `NSSavePanel` (the `files.user-selected.read-write` entitlement is already granted in `inter/inter.entitlements`).
      (d) **Live-chip transport decision:** the interviewer **polls** `GET /presence/timeline/:code/:identity` on a 15 s `NSTimer` while the interview is live, started from AppDelegate's interviewer post-join routing behind one guard. Rationale: §7.6 forbids this data over Socket.IO or the LiveKit DataChannel; the client batches every 15 s so a push channel could not make the chip fresher; and polling reuses the one server-authorised read path (`requireAuth` + `validateModerator` + hiring tier) instead of adding a second, weaker one. The timer is invalidated on mode exit.
      (e) **Jump-to-timestamp decision:** `jumpTo(row:)` emits the event's offset from session start and the bridge routes it to AppDelegate's existing "view recordings" action with that offset. When no recording exists for the session the Jump control is **disabled with the caption "No recording for this session"** rather than hidden — the feature must not imply a clip exists. Building a new player is out of scope; recorded as a Phase-0 scope line.
      (f) One guarded call site in `AppDelegate.m`'s interviewer post-join routing: `if (rc.activePresenceMonitoringArmed) { [bridge setPresenceAvailable:YES]; … start the poll timer; }`.
      Files: `inter/UI/SwiftUI/Screens/CallControlBarViewModel.swift`, `inter/UI/SwiftUI/Screens/CallControlBarView.swift`, `inter/UI/SwiftUI/Screens/PresenceTimelineViewModel.swift`, `inter/UI/SwiftUI/Screens/PresenceTimelineView.swift`, `inter/UI/SwiftUI/Screens/InterCallControlBarBridge.swift`, `inter/App/AppDelegate.m`
      Verify: `xcodebuild build …` BUILD SUCCEEDED; `xcodebuild test … -only-testing:interTests/CallControlBarViewModelTests -only-testing:interTests/InterCallControlBarBridgeTests` still passes.

- [ ] 16. `interTests/InterPresenceConsentViewModelTests.swift`.
      Cases: **zero-impact proof** — `PresenceConsentViewModel.mode(armed: false, regionEU: x, under18: y)` is `.legacyAlert` for all four `(x, y)` combinations; `mode(armed: true, regionEU: false, under18: false)` is `.monitoredOffer`; `mode(armed: true, regionEU: true, under18: false)` and `(false, true)` and `(true, true)` are all `.monitoringOffNotice` (EU and under-18 never see the monitored offer). **Consent state machine** — `acceptMonitoring()` emits exactly `.joinWithMonitoring` once; `declineMonitoring()` emits exactly `.joinWithoutMonitoring` once; `cancelJoin()` emits `.cancel`; a second intent after a decision emits nothing (terminal). **Decline never enables a camera** — assert `PresenceConsentViewModel` exposes no camera/media API and that no `InterLocalMediaController` is reachable from it, by driving the full decline path with a spy on every exposed closure and asserting only `onDecision` fired. **Indicator state tracks monitoring state including the stop case** — `indicatorLabel(0) == nil`, `1 → "Presence monitoring on"`, `2 → "Presence monitoring off"`, `3 → "Presence monitoring paused — camera off"`, and a transition table asserting that a granted session that is later stopped yields label 2 and never leaves label 1 stale. **Copy guard** — assert the concatenated `PresenceDisclosure` strings contain none of the §7.10 forbidden words (`cheat`, `dishonest`, `integrity`, `attention`, `focus`, `engagement`, `emotion`, `mood`, `confidence`, `proctor`, `gaze`, `eye tracking`, `identity`, `tamper`, `accuracy`) — case-insensitive, one assertion per word so a failure names the offender.
      Files: `/Users/aman_01/Documents/inter/interTests/InterPresenceConsentViewModelTests.swift`
      Verify: `cd /Users/aman_01/Documents/inter && xcodebuild test -project inter.xcodeproj -scheme inter -configuration Debug -destination 'platform=macOS' -only-testing:interTests/InterPresenceConsentViewModelTests` — 0 failures, and report the executed-test count.

**Phase 0 gate.** Before starting Phase 1: `cd token-server && npm test` green (16 files), `node migrate.js` applied 023 and `schema_migrations` records it, `xcodebuild build` BUILD SUCCEEDED, `xcodebuild test` green, and with `PRESENCE_MONITORING_ENABLED` unset the candidate join flow is the untouched `NSAlert`.

## Phase 1 — the on-device detector

- [ ] 17. Create the pure hysteresis event engine (no AVFoundation, no Vision, no networking, no clock).
      `InterPresenceEventEngine.swift`: `struct PresenceSample { let faceCount: Int; let maxBoxAreaFraction: Double; let minConfidence: Double; let detectorFailed: Bool; let cameraMuted: Bool }`, `struct PresenceEvent { let eventType: String; let startedAt: Double; let endedAt: Double; let durationMs: Int }` (String/Int/Double only — structurally incapable of carrying a pixel buffer, an image, a `Data`, or a numeric series), and `final class InterPresenceEventEngine { init(thresholds: PresenceThresholds, multipleFacesEnabled: Bool); func ingest(_ sample: PresenceSample, at t: TimeInterval) -> [PresenceEvent]; func flush(at t: TimeInterval) -> [PresenceEvent] }`. Time is injected, never read from the engine, so the tests are deterministic. Thresholds and the precedence lock are §D below. `multipleFacesEnabled == false` (the production default) means the engine **never constructs** a `multiple_faces` event — suppression at the engine, not a filter at upload, so a suppressed event never exists as an uploadable object.
      Files: `/Users/aman_01/Documents/inter/inter/Media/InterPresenceEventEngine.swift`
      Verify: `xcodebuild test … -only-testing:interTests/InterPresenceDetectorTests` passes (item 20).

- [ ] 18. Create the Vision adapter — `VNDetectFaceRectanglesRequest` only.
      `InterPresenceDetector.swift`: `final class InterPresenceDetector { func analyse(pixelBuffer: CVPixelBuffer) -> PresenceSample }` (camera-muted is supplied by the caller). Builds one `VNImageRequestHandler(cvPixelBuffer:orientation:options:)` and performs exactly one `VNDetectFaceRectanglesRequest`; reads **only** `results.count`, each observation's `boundingBox` (for `width * height` as the normalised area fraction) and `confidence`. A thrown error or a `nil` results array sets `detectorFailed = true`. The buffer is used inside the one request and released; nothing is retained, copied, encoded, written to disk or transmitted. `import Vision` appears here and nowhere else in the client — this is the first and only Vision usage. **Forbidden in this file and asserted by code review:** `VNDetectFaceLandmarksRequest`, `VNFaceLandmarks2D`, `VNDetectFaceCaptureQualityRequest`, `VNGenerateImageFeaturePrintRequest`, and any read of `yaw`, `pitch` or `roll`. Decision: `image_quality_insufficient` is driven by `VNFaceObservation.confidence` and `boundingBox` area, which satisfies §7.1's "detector confidence or bounding-box area below floor" without adding the second request the scope forbids.
      Files: `/Users/aman_01/Documents/inter/inter/Media/InterPresenceDetector.swift`
      Verify: `xcodebuild build …` BUILD SUCCEEDED; `grep -c "VNDetectFaceLandmarks\|faceCaptureQuality\|\.yaw\|\.pitch\|\.roll" inter/Media/InterPresenceDetector.swift` returns 0 (a sanity check, not the verification); real verification is item 20's fixture tests.

- [ ] 19. Create the capture source and the reporter, then the coordinator that owns them.
      (a) `InterPresenceCaptureSource.swift` — modelled line-for-line on `inter/Networking/InterLiveKitCameraSource.swift`: `@objc public func start(captureSession:sessionQueue:)` / `stop(captureSession:sessionQueue:)`; adds **only** its own `AVCaptureVideoDataOutput` inside `beginConfiguration`/`commitConfiguration` guarded by `canAddOutput`, with `videoSettings` pinned to `kCVPixelFormatType_32BGRA` (so it cannot renegotiate the session format and disturb the publisher or the preview layer) and `alwaysDiscardsLateVideoFrames = true`; its own serial queue `inter.presence.detect` at **`.utility`** QoS, deliberately below the publisher's `.userInteractive`, so contention costs the detector and never the call. **Invariants, non-negotiable:** never calls `startRunning`/`stopRunning`; never calls `addInput`/`removeInput`/`beginConfiguration` for anything but its own output; never touches any LiveKit track and never calls `mute()`/`unmute()`; removes only its own output on `stop`. Camera discipline: an `@objc public func setCameraState(_ state: Int)` mirror of `InterCameraNetworkState` (`inter/Networking/InterNetworkTypes.swift:69`), and `captureOutput` returns immediately when the state is `.muted` or `.muting`, incrementing `framesSkippedMuted`. 2 Hz throttle: drop any frame arriving within 500 ms of the last sampled one, incrementing `framesSkippedThrottle`. Counters `framesSampled`, `framesSkippedMuted`, `framesSkippedThrottle`, and `outputsAdded`/`outputsRemoved`/`sessionRunCalls` (the last always 0) are exposed for the tests. **Do NOT co-opt `InterLocalMediaController.recordingFrameObserver`** — it is a single-slot `atomic copy` property (`inter/Media/InterLocalMediaController.h`) owned by `InterRecordingCoordinator`, and taking it would break local recording's camera PiP.
      (b) `InterPresenceReporter.swift` — buffers closed `PresenceEvent`s, flushes every **15.0 s** and on stop, through `InterTokenService.uploadPresenceEvents`. The only serialisation path is `PresenceEvent.asPayload() -> [String: Any]` emitting exactly the allowlisted keys; there is no other encoder. Buffer capped at 200 events; overflow drops oldest and counts `eventsDropped` (the resulting silence is itself recorded by the server's `monitoring_gap`, which is the honest outcome). On `403`/`409` from the server it stops reporting and reports monitoring-off upward.
      (c) `InterPresenceCoordinator.swift` — the single owner and the single writer of the indicator state: holds the capture source, detector, engine and reporter; `@objc public func start(captureSession:sessionQueue:roomCode:identity:thresholds:multipleFacesEnabled:detectorVersion:)` and `stop()`; `@objc public var monitoringStateHandler: ((Int) -> Void)?` pushed to `SecureWindowController`. Emits `camera_disabled`/`camera_enabled` from the camera-state transitions and sets the indicator to `paused` while muted. In **Phase 0** the coordinator is constructed without a detector or capture source and produces no events (this is literally "the detector stubbed").
      (d) One guarded call site: `SecureWindowController.m -startLocalMediaFlow` (line 443), after `[weakSelf.localMediaController start]` (line 494) and inside the same completion, dispatched on `self.localMediaController.sessionQueue`:
      ```objc
      // PRESENCE MONITORING (provisional). One guard; delete this block to remove.
      if (weakSelf.roomController.activePresenceMonitoringGranted) { … start coordinator … }
      ```
      and `[self.presenceCoordinator stop]` in `-destroySecureWindow` next to the existing `[self.localMediaController shutdown]` (line 313). The coordinator's `monitoringStateHandler` calls `-setPresenceMonitoringState:`.
      Files: `/Users/aman_01/Documents/inter/inter/Media/InterPresenceCaptureSource.swift`, `/Users/aman_01/Documents/inter/inter/Media/InterPresenceReporter.swift`, `/Users/aman_01/Documents/inter/inter/Media/InterPresenceCoordinator.swift`, `inter/UI/Controllers/SecureWindowController.h`, `inter/UI/Controllers/SecureWindowController.m`
      Verify: `xcodebuild build …` BUILD SUCCEEDED; `xcodebuild test … -only-testing:interTests/InterPresenceCaptureSourceTests -only-testing:interTests/InterLiveKitCameraSourceTests -only-testing:interTests/InterCameraWiringTests` all pass (the last two prove the existing camera path is undisturbed).

- [ ] 20. `interTests/InterPresenceDetectorTests.swift` — hysteresis against synthetic `VNFaceObservation` fixtures.
      Fixtures: a `makeObservation(boundingBox:confidence:)` helper producing real `VNFaceObservation` values, and a `samples(from:)` adapter so the engine is driven both through the Vision-shaped adapter and directly as the pure core. Cases: **a sub-threshold event emits nothing** — zero faces for 9.5 s then a face returns ⇒ no `face_absent` (and the same for 2.5 s of two faces ⇒ no `multiple_faces`, 14 s of low quality ⇒ no `image_quality_insufficient`); **flicker inside the close threshold does not split one event in two** — 20 s of zero faces with a single 0.5 s one-face blip in the middle ⇒ exactly one `face_absent` spanning the whole window; a 1.5 s recovery ⇒ two events; **zero detections with low capture quality yields `image_quality_insufficient` and NEVER `face_absent`** — `faceCount == 0, detectorFailed == true` for 30 s ⇒ exactly one `image_quality_insufficient`, and `events.contains { $0.eventType == "face_absent" }` is asserted `false`; the same for `faceCount == 0` with `minConfidence` below the floor; **camera-muted suppression** — zero faces for 60 s while `cameraMuted == true` ⇒ no `face_absent`, only the `camera_disabled` transition; unmuting emits `camera_enabled` with `durationMs == 0`; **precedence lock** — an overlapping sample that is simultaneously two faces and low quality emits both `multiple_faces` and `image_quality_insufficient` and never `face_absent`; **`multiple_faces` default-off** — with `multipleFacesEnabled: false`, 30 s of two faces emits nothing of that type while `face_absent` behaviour is unaffected; **exact thresholds** — the boundary samples at 9.999 s / 10.001 s, 2.999 s / 3.001 s and 14.999 s / 15.001 s; **`flush` at stop** closes an open event and emits it only if it already exceeded its open threshold; **no forbidden output** — the engine's emitted payload keys, taken from `asPayload()`, are exactly the allowlist and contain none of `score`, `confidence`, `emotion`, `landmarks`, `yaw`, `pitch`, `roll`.
      Files: `/Users/aman_01/Documents/inter/interTests/InterPresenceDetectorTests.swift`
      Verify: `xcodebuild test -project inter.xcodeproj -scheme inter -configuration Debug -destination 'platform=macOS' -only-testing:interTests/InterPresenceDetectorTests` — 0 failures; report the executed-test count.

- [ ] 21. `interTests/InterPresenceCaptureSourceTests.swift` — modelled on `interTests/InterLiveKitCameraSourceTests.swift` (reuse its `createVideoSampleBuffer(width:height:)` helper shape).
      Cases: initial state has `isCapturing == false` and all counters 0; `start(captureSession:sessionQueue:)` on a bare `AVCaptureSession` adds **exactly one** output (`session.outputs.count` grows by 1, `outputsAdded == 1`) and `stop` removes exactly that one (`session.outputs.count` returns to its prior value, and an output added by a different owner before `start` is still present after `stop`); **never touches session inputs** — `session.inputs` is identical by `count` and identity before `start` and after `stop`, including when a dummy input is pre-added; **never calls `startRunning`/`stopRunning`** — `session.isRunning` is `false` throughout and the source's `sessionRunCalls` counter is 0 (plus an `AVCaptureSession` subclass overriding `startRunning`/`stopRunning` to flag a call, asserted never flagged); double `start` is idempotent and adds no second output; `stop` without `start` is a no-op; **drops frames while muted/muting** — feeding 10 synthetic sample buffers with `setCameraState(.muted)` and then `.muting` yields `framesSampled == 0` and `framesSkippedMuted == 10`; **2 Hz throttle** — 30 buffers delivered 100 ms apart yields at most 7 sampled (the `SecureStagePreviewThrottleTests.swift` style); the pinned `videoSettings` equals `[kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]`; rapid create/destroy of 100 sources leaks nothing (the existing `testNoAllocationGrowth_rapidCreateDestroy` shape).
      Files: `/Users/aman_01/Documents/inter/interTests/InterPresenceCaptureSourceTests.swift`
      Verify: `xcodebuild test … -only-testing:interTests/InterPresenceCaptureSourceTests` — 0 failures.

## Documentation

- [ ] 22. Write the design note.
      Path: **`/Users/aman_01/Documents/inter/docs/superpowers/specs/2026-10-31-interview-presence-monitoring-design.md`** — matches the established `YYYY-MM-DD-<kebab-slug>-design.md` convention in that directory (ten existing files, most recent `2026-10-27-interview-face-verification-design.md`). House style: labelled header block with `Date:` / `Project:` / `Feature:` / `Status:` / `Builds on:`; numbered `##` sections, `###` subsections, no deeper; delta tables; fenced pseudo-code for derivation rules; `**[DECISION — RESOLVED]**` markers; SHALL-style capitals; **no Mermaid** (neither reference doc contains any, so introducing it would be a departure). Required content:
      - **The master flag and what OFF guarantees**, naming the two server conditions and the four client call sites.
      - **The EU default-off warning**, stated as a warning and not a footnote: do not enable for EU-resident candidates; the per-room `candidateRegionEU` setting forces `armed = false` server-side; the AI Act Art. 6(3) classification is unresolved and the adjacent Art. 5(1)(f) prohibition carries a €35M/7 % ceiling (§3.1, §7.9 item 7). The same warning is duplicated as a code comment on `resolvePresenceArming`.
      - **Under-18 routing** — forced to monitoring-off, never offered the monitored path (§7.9 item 8).
      - **The `multiple_faces` default-OFF flag and its prerequisite**: the flag MUST NOT be enabled in production until the measured false-positive study passes — ≥ 20 sessions, varied lighting, rooms, webcams and skin tones, per-event-type per-session FP rate reported, `multiple_faces` under 5 % per session (§7.7 Phase 1 exit gate). State plainly that this study needs real humans in real rooms, cannot be done by an agent, and must not be faked, simulated or hand-waved. **Reframe it as its actual purpose: this is the measurement that tells the user whether to keep this feature or delete it.**
      - **The no-score rule** and §7.2's seven reasons in condensed form, plus the concrete consequence: per-type counts and durations only, no total, no weighting, no percentage, no rating, no risk level, no cross-candidate or cross-session comparison, ever.
      - **§7.10's claim checklist** applied to UI copy, log strings and code comments, with the "say instead" sentence quoted as the approved description.
      - **Out of scope / not doing**, item 23's list, each with its reason.
      - **Deferred, and blocking before production** — the two items in §E.
      - **Thresholds and their named owner** (§7.9 item 10): the table of open/close thresholds, the rationale per value, and a `Threshold owner:` line naming the person. Leave it as `Threshold owner: <unassigned — must be filled before the flag is enabled>` and flag it as an open question rather than inventing a name.
      - **What stays untouched** — the `preConnectConsentGate` signature, `-showIntervieweeConfirmationWithCompletion:`, `InterLocalMediaController.recordingFrameObserver`, `InterLiveKitCameraSource`, Socket.IO, the LiveKit DataChannel, `InterNetworkErrorCode`, and every pre-existing table.
      Files: `/Users/aman_01/Documents/inter/docs/superpowers/specs/2026-10-31-interview-presence-monitoring-design.md`
      Verify: `grep -ci "cheat\|dishonest\|integrity score\|attention\|engagement\|emotion\|gaze\|eye track" docs/superpowers/specs/2026-10-31-interview-presence-monitoring-design.md` — occurrences exist only inside the explicit refusal/never-say sections; read them and confirm every one is a refusal, not a capability claim.

- [ ] 23. Write `REMOVAL.md` — the deletion recipe.
      Path: `/Users/aman_01/Documents/inter/.agents/tasks/presence-monitoring/REMOVAL.md`. Contents:
      - **Disable without deleting (1 step):** unset `PRESENCE_MONITORING_ENABLED` (or set it to anything but `true`) and restart the token server. Nothing else. No client release needed, because an unarmed room omits the presence block and the client defaults to `false`.
      - **Full removal — files to delete**, the complete absolute-path list: server `presenceConfig.js`, `presenceEvents.js`, `presenceRetention.js`, `presence.js`, `migrations/023_interview_presence_events.sql`, `test/presenceEvents.test.js`, `test/presenceRetention.test.js`, `test/presenceGate.test.js`; client `inter/UI/SwiftUI/Screens/PresenceConsentView.swift`, `PresenceConsentViewModel.swift`, `InterPresenceConsentHostView.swift`, `PresenceTimelineView.swift`, `PresenceTimelineViewModel.swift`, `inter/Media/InterPresenceEventEngine.swift`, `InterPresenceDetector.swift`, `InterPresenceCaptureSource.swift`, `InterPresenceReporter.swift`, `InterPresenceCoordinator.swift`; tests `interTests/InterPresenceConsentViewModelTests.swift`, `InterPresenceDetectorTests.swift`, `InterPresenceCaptureSourceTests.swift`; docs `docs/superpowers/specs/2026-10-31-interview-presence-monitoring-design.md`. Note that no `project.pbxproj` edit is needed in either direction (synchronized root groups).
      - **Existing files touched, with the specific hunk per file and a stable anchor to find it** — `token-server/index.js` (5 hunks: the require, the router build + mount, the `/room/create` arming block, the `/room/join` response block, the sweeper timer); `token-server/README.md` row; `inter/Networking/InterNetworkTypes.swift` (3 config properties + `copy(with:)` + `meetingSettingsDict` keys); `inter/Networking/InterTokenService.swift` (the `InterJoinRoomResponse` fields + parsing + 5 new methods); `inter/Networking/InterRoomController.swift` (the `activePresence*` block, the join-branch assignments, `applyMeetingSettingsFromDict` mirrors, `recordPresenceConsent`); `inter/App/AppDelegate.m` (the one `if` in the gate block, `-showPresenceConsentWithCompletion:`, the post-join consent POST, the interviewer availability guard + poll timer); `inter/UI/Controllers/SecureWindowController.h/.m` (the `setPresenceMonitoringState:` pair, the details-panel wiring, the coordinator start guard and the stop call); `inter/UI/SwiftUI/Screens/SecureCandidateChromeViewModel.swift` + `SecureCandidateChromeViews.swift` + `InterSecureChromeBridge.swift` (the chip, the state property, the setter, the `invalidateHandlers` line); `inter/UI/SwiftUI/Screens/CallControlBarViewModel.swift` + `CallControlBarView.swift` + `InterCallControlBarBridge.swift` (the chip and the popover). Every one of these must carry a `// PRESENCE MONITORING (provisional)` marker comment in the source so the hunks are greppable: `grep -rn "PRESENCE MONITORING (provisional)" inter token-server`.
      - **The migration.** `token-server/migrate.js` is **forward-only and has no down-migration mechanism** — say so explicitly. Removal is therefore a manual operator step, in this order: `DROP TABLE IF EXISTS interview_presence_notes, interview_presence_events, interview_presence_sessions CASCADE;` then, only if the `.sql` file is also deleted, `DELETE FROM schema_migrations WHERE filename = '023_interview_presence_events.sql';`. If the file is kept, leave the `schema_migrations` row alone — the DDL is `IF NOT EXISTS` and a re-run is harmless.
      - **`audit_events` rows cannot be deleted.** Migration 011 installs `audit_events_no_delete` → `prevent_audit_modification()`, so the `presence_*` rows stay forever. That is correct and intentional; state it rather than letting someone discover it mid-removal.
      - **Env vars to unset:** `PRESENCE_MONITORING_ENABLED`, `PRESENCE_EVENT_RETENTION_DAYS`, `PRESENCE_MULTIPLE_FACES_ENABLED`, `PRESENCE_GAP_SECONDS`, `PRESENCE_SWEEP_INTERVAL_MS`, `PRESENCE_STALE_SESSION_MINUTES`, `PRESENCE_RIGHTS_CONTACT`, `PRESENCE_NOTE_HMAC_KEY` if used.
      - **Post-removal verification:** `cd token-server && npm test` green with the three files deleted; `xcodebuild build` BUILD SUCCEEDED; `xcodebuild test` green; `grep -rn "resence" inter token-server --include=*.swift --include=*.m --include=*.h --include=*.js` returns nothing but unrelated words.
      Files: `/Users/aman_01/Documents/inter/.agents/tasks/presence-monitoring/REMOVAL.md`
      Verify: follow the file's own "files to delete" list against the tree with `ls` and confirm every named path exists; confirm `grep -rn "PRESENCE MONITORING (provisional)" /Users/aman_01/Documents/inter/inter /Users/aman_01/Documents/inter/token-server` lists every existing file named in the "files touched" section and nothing else.

---

## §A. Migration `023_interview_presence_events.sql` — DDL intent

Table name per §7.5: **`interview_presence_events`** is the load-bearing name — it invites honest engineering where `proctoring_flags` would invite a score. Three tables, because the state is mutable, the events are facts, and the notes are a different actor's artefact.

### `interview_presence_sessions` — one row per (room, participant); the mutable state

| Column | Type / constraint | Why |
|---|---|---|
| `id` | `UUID PRIMARY KEY DEFAULT gen_random_uuid()` | house convention |
| `room_code` | `VARCHAR(6) NOT NULL` | matches `meetings.room_code` |
| `participant_identity` | `VARCHAR(128) NOT NULL` | the ephemeral client UUID; **not** a name, **not** an email |
| `meeting_id` | `UUID REFERENCES meetings(id) ON DELETE CASCADE` | nullable (the `meetings` insert is best-effort at `/room/create`). **CASCADE** because `meetings` is the parent record — without it the presence rows have no context and must go. Mirrors `meeting_participants.meeting_id`. |
| `host_user_id` | `UUID REFERENCES users(id) ON DELETE SET NULL` | **SET NULL, not CASCADE.** The candidate's record of what was collected about them, and the retention obligation over it, must outlive the recruiter's account deletion; the sweeper and the candidate's erasure request are the only things that delete it. Mirrors `audit_events.user_id` and `team_files.uploader_user_id`. |
| `candidate_user_id` | `UUID REFERENCES users(id) ON DELETE SET NULL` | nullable — candidates are usually guests. Mirrors `meeting_participants.user_id`. |
| `monitoring_enabled` | `BOOLEAN NOT NULL DEFAULT FALSE` | the per-session state. Default FALSE is the fail-closed default. |
| `consent_state` | `VARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (consent_state IN ('pending','granted','declined','not_offered'))` | `not_offered` is the EU / under-18 route |
| `consent_granted_at`, `consent_declined_at` | `TIMESTAMPTZ` | provenance |
| `consent_version` | `VARCHAR(32)` | pins WHICH notice text was shown; e.g. `'presence-2026-10-31'` |
| `policy_region_eu`, `policy_under_18` | `BOOLEAN NOT NULL DEFAULT FALSE` | why monitoring was off, recorded with the row |
| `multiple_faces_enabled` | `BOOLEAN NOT NULL DEFAULT FALSE` | the §7.7 gate's state at arm time |
| `detector_version` | `TEXT NOT NULL` | the operating point is reconstructible (NISTIR 8280's instruction to system owners) |
| `thresholds` | `JSONB NOT NULL` | the armed config |
| `started_at` | `TIMESTAMPTZ NOT NULL DEFAULT NOW()` | |
| `last_report_at` | `TIMESTAMPTZ` | the `monitoring_gap` clock |
| `ended_at` | `TIMESTAMPTZ` | set by the stale-session closer |
| `purge_after` | `TIMESTAMPTZ NOT NULL` | stamped at insert from `retentionDays()`; a later env change produces new clocks on new rows and **never rewrites old ones** |
| `created_at`, `updated_at` | `TIMESTAMPTZ NOT NULL DEFAULT NOW()`; `updated_at` via `CREATE TRIGGER set_interview_presence_sessions_updated_at BEFORE UPDATE … EXECUTE FUNCTION trigger_set_updated_at()` | house convention |

Indexes: `CREATE UNIQUE INDEX idx_ips_room_identity ON interview_presence_sessions (room_code, participant_identity)` (one live session per identity per room); `idx_ips_purge_due ON (purge_after) WHERE ended_at IS NOT NULL OR true` → use the simpler partial `idx_ips_purge_due ON (purge_after)`; `idx_ips_stale ON (last_report_at) WHERE monitoring_enabled = true AND ended_at IS NULL` (the stale-session closer's only query).

**No email column, no display name.** Decision, taken because the candidate copy/delete endpoint is deferred (§E): storing a contact address would be PII held for a purpose that does not yet exist. Dropping it also removes the only field that needed encryption for identity reasons and strengthens the §7.5 "the artefact is not identity-bearing" claim. When the rights endpoint is built, add `candidate_email_enc TEXT` + `candidate_email_key_version SMALLINT` + a keyed-HMAC `candidate_email_lookup CHAR(64)` in a **later** migration — and use a dedicated `PRESENCE_EMAIL_HMAC_KEY`, **not** `pseudonymizeEmail` (`index.js:479`), whose output is truncated to 32 chars and flips shape under `AUDIT_LOG_FULL_EMAIL`, which would silently orphan rows.

### `interview_presence_events` — the facts

| Column | Type / constraint | Why |
|---|---|---|
| `id` | `BIGSERIAL PRIMARY KEY` | monotonic ordering key for the timeline (the `team_messages` precedent); events are high-cardinality and never referenced by UUID elsewhere |
| `session_id` | `UUID NOT NULL REFERENCES interview_presence_sessions(id) ON DELETE CASCADE` | **CASCADE.** An event without its session has no thresholds, no consent provenance and no retention clock, so it must never survive it. This is also what makes a candidate erasure one `DELETE`. |
| `event_type` | `VARCHAR(32) NOT NULL CHECK (event_type IN ('face_absent','multiple_faces','image_quality_insufficient','camera_disabled','camera_enabled','monitoring_gap'))` | **`head_off_axis` is deliberately absent** so the database itself refuses a Phase-2 event smuggled in early. No Postgres `ENUM` type (none exists anywhere in this schema). |
| `started_at` | `TIMESTAMPTZ NOT NULL` | |
| `ended_at` | `TIMESTAMPTZ` | `= started_at` for the instantaneous camera transitions |
| `duration_ms` | `INTEGER NOT NULL DEFAULT 0 CHECK (duration_ms >= 0)` | |
| `detector_version` | `TEXT NOT NULL` | §7.5 |
| `thresholds` | `JSONB NOT NULL` | **the thresholds in force for THIS event**, stamped by the **server** from the session's armed config, never from the client payload — a client cannot rewrite the operating point of its own record. Direct fix for the Proctorio/Respondus retroactive-recomputation problem (§7.2 reason 3): a stored event is a fact about a moment under a stated threshold; changing the threshold later produces new rows going forward, never different rows looking back. |
| `source` | `VARCHAR(10) NOT NULL DEFAULT 'client' CHECK (source IN ('client','server'))` | `monitoring_gap` is `'server'`; makes provenance explicit |
| `purge_after` | `TIMESTAMPTZ NOT NULL` | per-row clock, same reason as above |
| `created_at` | `TIMESTAMPTZ NOT NULL DEFAULT NOW()` | |

Indexes: `idx_ipe_session_time ON (session_id, started_at)` (the timeline's only query); `idx_ipe_purge_due ON (purge_after)` (the sweeper's only query); `idx_ipe_session_type ON (session_id, event_type)` (the summary's `GROUP BY`).
**No `UPDATE` path exists in any code path** — events are append-only by convention here (not by trigger, because unlike `audit_events` the sweeper must `DELETE` them to honour retention; a DB-level no-delete trigger would make the retention obligation unsatisfiable).

### `interview_presence_notes` — the interviewer's judgement, additive and never destructive

| Column | Type / constraint | Why |
|---|---|---|
| `id` | `UUID PRIMARY KEY DEFAULT gen_random_uuid()` | |
| `event_id` | `BIGINT NOT NULL REFERENCES interview_presence_events(id) ON DELETE CASCADE` | **CASCADE.** A note annotates exactly one event; orphaning it would leave an accusation with nothing to check it against. |
| `author_user_id` | `UUID REFERENCES users(id) ON DELETE SET NULL` | **SET NULL** so the note survives the author's account deletion; non-null is enforced at the API layer, where `validateModerator` guarantees an authenticated moderator |
| `author_display_name` | `VARCHAR(100) NOT NULL` | denormalised snapshot (the `team_messages.sender_name` precedent) so the note still says who wrote it after `author_user_id` goes null |
| `note_text_enc` | `TEXT NOT NULL` | **encrypted via `token-server/crypto.js`.** This is the one field in the feature that warrants it: a free-text human judgement about a named person is the most sensitive string the feature produces, and it is UTF-8, so `encryptToken`/`decryptToken` are reusable **as-is** with no `encryptBuffer` addition. Format `v{N}:{iv}:{tag}:{ct}`. |
| `note_key_version` | `SMALLINT NOT NULL` | the migration-016 companion-column convention (`google_refresh_token` + `google_token_key_version`); informational / for rotation sweeps, since `decryptToken` reads the version from the blob prefix |
| `created_at` | `TIMESTAMPTZ NOT NULL DEFAULT NOW()` | |

Index: `idx_ipn_event ON (event_id, created_at)`.
**Fail closed on encryption:** if `crypto.isEncryptionAvailable()` is false the note endpoint returns `500 { code: 'ENCRYPTION_UNAVAILABLE' }` and writes nothing — the `calendar.js:170` precedent, which returns an error rather than storing a plaintext token. Note that `ENCRYPTION_ACTIVE_VERSION` / `ENCRYPTION_SECRET_V1` exist in `token-server/.env` but **not** in `.env.example`, so a fresh clone starts with encryption unavailable; add both (with placeholder values and a generation hint) to `.env.example` as part of item 6, because otherwise the note path is dead on a second machine.

**Event rows are not encrypted,** deliberately: they are five enum values, two timestamps and an integer. Encrypting them would break the sweeper's and the timeline's index usage for no privacy gain, and the whole point of §7.5 is that the artefact is not identity-bearing.

---

## §B. The ingest contract, verbatim

### Event-type allowlist

```js
// token-server/presenceEvents.js
const EVENT_TYPES = Object.freeze([
  'face_absent',
  'multiple_faces',
  'image_quality_insufficient',
  'camera_disabled',
  'camera_enabled',
  'monitoring_gap',
]);

// What a CLIENT may send. monitoring_gap is server-generated only: it exists so
// client silence is visible rather than indistinguishable from a clean session
// (§7.1), which a client must not be able to forge or suppress.
const CLIENT_EVENT_TYPES = Object.freeze([
  'face_absent',
  'multiple_faces',
  'image_quality_insufficient',
  'camera_disabled',
  'camera_enabled',
]);

// head_off_axis is Phase 2 and OUT OF SCOPE. It is absent from both lists AND
// from the CHECK constraint in migration 023, so neither the API nor the
// database will accept it.
```

### Per-event allowed keys (strict allowlist)

```js
const ALLOWED_EVENT_KEYS = Object.freeze([
  'eventType', 'startedAt', 'endedAt', 'durationMs', 'detectorVersion',
]);
// Top-level body keys: roomCode, identity, events.
// thresholds is NOT accepted from the client — the server stamps it.
```

### Rejected-key list (explicit, tested, and the durable defence)

```js
// A payload containing ANY of these keys is REJECTED with 400
// PRESENCE_FORBIDDEN_FIELD — never silently dropped. The strict allowlist above
// is the actual security control; THIS list is the documentation control, so a
// future contributor trying to smuggle affect inference through this endpoint
// gets a failing test that names the prohibited concept instead of a generic
// "unknown key". EU AI Act Art. 5(1)(f) makes emotion inference in a hiring
// context a PROHIBITED practice and binds this product as provider. See §7.2,
// §7.8, §7.10 of the research memo.
const FORBIDDEN_KEYS = Object.freeze([
  // landmarks / meshes / templates — no geometry beyond a bounding box, ever
  'landmarks', 'landmark', 'landmarkpoints', 'mesh', 'facemesh',
  'blendshapes', 'blendshape', 'embedding', 'embeddings', 'template',
  'faceprint', 'featureprint', 'descriptor', 'vector',
  // scores / aggregates / rankings — §7.2, no score ever
  'score', 'scores', 'suspicionscore', 'integrityscore', 'riskscore',
  'risklevel', 'rating', 'index', 'percentile', 'rank', 'aggregate', 'total',
  // affect / emotion — prohibited practice
  'emotion', 'emotions', 'affect', 'sentiment', 'mood', 'expression', 'valence',
  'arousal',
  // cognition / attitude — the Guidelines treat attitude as equivalent to emotion
  'attention', 'attentive', 'attentionscore', 'engagement', 'engaged',
  'focus', 'distraction', 'interest', 'confidence', 'nervousness', 'stress',
  'anxiety', 'honesty', 'deception', 'personality', 'trait', 'traits',
  // gaze / iris / blink — refused permanently
  'gaze', 'gazedirection', 'iris', 'pupil', 'pupils', 'eyeaspectratio', 'ear',
  'blink', 'blinks', 'eyesclosed',
  // head pose — Phase 2, out of scope, not collected
  'yaw', 'pitch', 'roll', 'headpose', 'pose', 'orientation',
  // pixels — never transmitted, in any form
  'frame', 'frames', 'image', 'images', 'jpeg', 'jpg', 'png', 'pixels',
  'pixelbuffer', 'crop', 'crops', 'thumbnail', 'snapshot', 'base64', 'bytes',
]);

// Matching: normalise(key) = key.toLowerCase().replace(/[_-]/g, '')
// Applied RECURSIVELY to every object key at every depth, including objects
// inside arrays. So {"meta":{"face_score":1}} and [{"Gaze-Direction":…}] are
// both caught. Forbidden wins over unknown so the error names the concept.
```

### Error codes (exact strings)

| Code | HTTP | Meaning |
|---|---|---|
| `INSUFFICIENT_TIER` | 403 | **Existing code, reused** (`TIER_INSUFFICIENT` does not exist in this server) |
| `PRESENCE_DISABLED` | 404 | master flag off — the router's first middleware |
| `PRESENCE_MONITORING_NOT_ARMED` | 409 | room was never armed |
| `PRESENCE_CONSENT_REQUIRED` | 409 | ingest before a `granted` consent record |
| `PRESENCE_EVENT_TYPE_NOT_ALLOWED` | 400 | type not in `CLIENT_EVENT_TYPES` |
| `PRESENCE_EVENT_TYPE_DISABLED` | 409 | `multiple_faces` while the gate is off |
| `PRESENCE_FORBIDDEN_FIELD` | 400 | **the §7.8 assertion** — a `FORBIDDEN_KEYS` key is present; response includes `field` |
| `PRESENCE_UNKNOWN_FIELD` | 400 | a key outside the allowlist |
| `PRESENCE_PAYLOAD_INVALID` | 400 | shape / type / ordering violation |
| `PRESENCE_BATCH_TOO_LARGE` | 413 | more than 100 events |
| `PRESENCE_SESSION_NOT_FOUND` | 404 | no session row for `(code, identity)` |
| `PRESENCE_UNAUTHORIZED` | 403 | missing or mismatched `Leave-Token` |
| `PRESENCE_FORBIDDEN` | 403 | `validateModerator` rejected the caller |
| `PRESENCE_NOTE_REASON_REQUIRED` | 400 | note under 10 characters after trimming |
| `ENCRYPTION_UNAVAILABLE` | 500 | `crypto.isEncryptionAvailable()` false on the note path; fail closed |
| `PRESENCE_UNAVAILABLE` | 503 | Redis or DB unreachable |
| `RATE_LIMITED` | 429 | **NEW code** — no `RATE_LIMITED` string exists in the server today; introduced here with a `Retry-After` header |

`auth.requireAuth`'s 401 carries no `code` field today; do not invent one for it. `requestId` is produced only by the global error handler (`index.js:5402`), so these hand-written 4xx responses emit `{ error, code, … }` **without** `requestId` and get it for free on thrown 500s — matching house practice rather than fabricating it.

---

## §C. Server endpoints

Mounted `app.use('/presence', presenceRouter)`. Router-level first middleware: `requirePresenceFeature` → `404 PRESENCE_DISABLED`.

| Method / path | Auth | Tier | Rate limit (all with `Retry-After`) |
|---|---|---|---|
| `POST /presence/consent` | `Leave-Token` header + `(code, identity)`, compared with `constantTimeEqual` against `redis.get(roomLeaveTokenKey(code, identity))` | `tiers.isFeatureAllowed(roomData.hostTier, FEATURES.HOST_INTERVIEW)` | `presence-consent` 10 / 600 s |
| `POST /presence/events` | same | same | `presence-events` 30 / 60 s |
| `GET /presence/timeline/:code/:identity` | `auth.requireAuth` **+** `validateModerator(code, callerIdentity, req.user.userId)` | same | `presence-timeline` 60 / 60 s |
| `POST /presence/timeline/:code/:identity/note` | same | same | `presence-note` 30 / 600 s |
| `GET /presence/export/:code/:identity?format=json\|csv` | same | same | `presence-export` 10 / 600 s |

**Authorisation, stated precisely.** The timeline, note and export paths call `auth.requireAuth` **then** `validateModerator(code, callerIdentity, req.user.userId)` (`index.js:2223`). That function cross-checks the body/query-supplied `callerIdentity` against `redis.hget(roomUserBindingKey(code), callerIdentity)` and rejects when a binding exists and does not match the authenticated `userId` — which is exactly what stops an authenticated participant passing the host's (peer-visible) identity and reading another candidate's events. It then requires the Redis role to be in `MODERATOR_ROLES = ['host','co-host','interviewer']`. Both halves are asserted in `presenceGate.test.js`. Fail closed: a missing room, a missing session, a Redis error, or an unknown host tier all deny.

**Tier gating** is the inline `tiers.isFeatureAllowed(…, tiers.FEATURES.HOST_INTERVIEW)` form used by `/room/create` (`index.js:2409`) and `/meetings/schedule` (`scheduling.js:163`) — **not** `auth.requireTier`, which the interview paths do not use. No new `FEATURES` key and no change to `FEATURE_MIN_TIER`: monitoring rides the existing `HOST_INTERVIEW → hiring` entitlement, and the candidate-facing endpoints read `roomData.hostTier` (the tier snapshotted at room creation), which is the `toolsEntitlement(hostTier)` shape — host tier decides, stamped server-side, the candidate's own plan irrelevant. `InterFeatureGate.h/.m` is therefore **not** edited.

**Rate limiter.** A new `makePresenceRateLimiter(action, max, windowSec)` in `presence.js`: the same Redis `INCR` + `EXPIRE` shape as `rateLimitRoomAction` (`index.js:383`), but it reads the key's `ttl` and sets `Retry-After: <ttl>` and returns `429 { error, code: 'RATE_LIMITED' }`. `rateLimitRoomAction` sets no `Retry-After` today and only 3 of the 6 existing limiters do, so this is additive, not a change to shared code. Principal key: `u:{userId}` when authenticated, else `lt:{code}:{identity}` for the leave-token paths — **not bare IP**, because a corporate NAT would otherwise share one candidate budget. **On a Redis error these endpoints return `503 PRESENCE_UNAVAILABLE` rather than failing open**, which diverges from the surrounding "fail open" rate-limit convention; the reason is that every one of these handlers already needs Redis for `getRoomData` and the leave token, so there is nothing to fail open to, and an unmetered flood of behavioural-record writes is the worse failure.

**`monitoring_gap` generation.** On ingest, if `monitoring_enabled` and `NOW() - last_report_at > gapSeconds()`, insert one `monitoring_gap` spanning `[last_report_at, NOW()]` with `source = 'server'` **before** the batch, then set `last_report_at = NOW()`. At timeline read, an *open* gap (session live, `last_report_at` older than the threshold) is computed on the fly and returned but **not persisted**, because it is still running. A trailing gap is closed by the sweeper's `closeStaleSessions()` (item 4).

**Timeline response shape** (no score, by construction):

```js
{
  monitoringEnabled: true,
  consentState: 'granted',          // pending | granted | declined | not_offered
  consentVersion: 'presence-2026-10-31',
  policyRegionEU: false, policyUnder18: false,
  detectorVersion: 'presence-1.0.0',
  thresholds: { … },                 // the operating point, shown to the reviewer
  multipleFacesEnabled: false,
  sessionStartedAt: '…', sessionEndedAt: null, sessionDurationMs: 2714000,
  // EVALUATION SURFACE: per-type counts and durations ONLY. No total, no
  // weighting, no percentage, no rating, no risk level, no comparison to any
  // other candidate or session. See §7.2 — do not add one.
  summary: [ { eventType: 'face_absent', count: 3, totalDurationMs: 41200,
               liveSurfaceable: true }, … ],
  events: [ { id, eventType, startedAt, endedAt, durationMs, offsetMs,
              detectorVersion, thresholds, source, liveSurfaceable,
              notes: [ { author, createdAt, text } ] }, … ]
}
```

`liveSurfaceable` is computed **server-side** from a constant `LIVE_SURFACEABLE = ['multiple_faces','face_absent']`, so the client cannot widen what is surfaced live (§7.9 item 4). `offsetMs` is the event's offset from `sessionStartedAt`, which is what jump-to-timestamp consumes.

**CSV export.** Header row `event_type,started_at,ended_at,duration_ms,offset_ms,detector_version,source,thresholds_json`, one row per event, every field quoted with `"` doubled, and any value beginning `=`, `+`, `-` or `@` prefixed with `'` (OWASP formula-injection guard). `Content-Type: text/csv; charset=utf-8`, `Content-Disposition: attachment; filename="presence-<code>-<identity>.csv"` with `identity` passed through `fileValidation.sanitizeFilename` before it reaches the header.

---

## §D. Detector design

**Sampling.** One frame per **500 ms** (2 Hz), on the detector's own `.utility` queue, only while the session the call is already running produces frames. Rationale (§5.6): events here are measured in seconds, so a 3 s threshold needs ~6 samples — plenty of evidence and ~15× less work than a 30 fps pipeline.

**Camera discipline, non-negotiable.** Model on `inter/Networking/InterLiveKitCameraSource.swift`, whose header states the invariant: *"This class never modifies the capture session's input configuration. It only adds/removes its own output."* Therefore the presence source:
1. adds exactly one `AVCaptureVideoDataOutput` of its own and removes exactly that one;
2. pins `videoSettings` to `kCVPixelFormatType_32BGRA` so it cannot renegotiate the session format and disturb the preview layer, the LiveKit publisher or the optional recording output;
3. never calls `startRunning` / `stopRunning` (`InterLocalMediaController.h`: *"Callers MUST NOT call startRunning/stopRunning"*);
4. never calls `addInput` / `removeInput`;
5. never touches any LiveKit track and never calls `mute()` / `unmute()`;
6. skips all work while `cameraState` is `.muted` or `.muting` (`InterCameraNetworkState`, `inter/Networking/InterNetworkTypes.swift:69`), which is also what makes the §7.1 "camera unmuted" precondition for `face_absent` true by construction;
7. does **not** co-opt `InterLocalMediaController.recordingFrameObserver` — a single-slot property owned by `InterRecordingCoordinator`; taking it would break local recording's camera PiP.

**Thresholds (§7.1) and the hysteresis rule (§5.6).** Open an event only after the condition holds continuously for the open threshold; close it only after the condition has cleared continuously for 1.0 s; **discard entirely** any candidate event that never reached its open threshold, so transient detector noise never reaches the store.

| Event | Open condition | Open threshold | Close threshold |
|---|---|---|---|
| `face_absent` | `faceCount == 0` AND quality above floor AND camera unmuted | **10.0 s** | 1.0 s of `faceCount >= 1` |
| `multiple_faces` | `faceCount >= 2` (and the server gate is ON) | **3.0 s** | 1.0 s of `faceCount < 2` |
| `image_quality_insufficient` | `detectorFailed` OR `minConfidence < 0.35` OR `maxBoxAreaFraction < 0.01` | **15.0 s** | 1.0 s clear |
| `camera_disabled` / `camera_enabled` | a `cameraMuted` transition | instantaneous | `durationMs = 0`, `endedAt = startedAt` |

**Precedence lock — fixed by the test suite, not by reading order** (the `deriveRemoteTileState` discipline):

```
cameraMuted                       -> emit camera transitions only; close and DISCARD every
                                     other open candidate; face_absent cannot open
detectorFailed || quality < floor -> feeds image_quality_insufficient ONLY.
                                     It MUST NOT feed face_absent.      // §7.1 critical rule
faceCount == 0 && quality >= floor-> feeds face_absent
faceCount >= 2                    -> feeds multiple_faces (independent of the quality branch;
                                     a frame can be both multi-face and low quality, and the
                                     honest record is both)
```

**The critical rule, restated because it is the ethics of the feature:** a detection failure is a data-quality fact about the **video**, recorded as `image_quality_insufficient`, and **never** as `face_absent`, which would attribute it to the candidate's behaviour. §4.1 is why: detection failure rates are not uniform across skin tones, lighting or webcam quality, and mislabelling a failure as absence converts an equipment inequality into an accusation. Asserted explicitly in `InterPresenceDetectorTests.swift`.

**Batching.** Closed events flush every **15.0 s** and on stop, over HTTPS through `InterTokenService` — **not** over the LiveKit DataChannel and **not** over Socket.IO (§7.6: Socket.IO stays for moderation and mic-state signalling, and no behavioural data crosses the SFU). **Never send pixels, frames, crops, thumbnails or landmarks. Ever.** Enforced structurally: `PresenceEvent` is a struct of `String`/`Int`/`Double` only, and `asPayload()` is the single serialisation path.

**`multiple_faces` gate.** Server-controlled via `PRESENCE_MULTIPLE_FACES_ENABLED`, **default OFF in production**, delivered to the client as `presenceMultipleFacesEnabled` on the join response and honoured by the engine (which never constructs the event when off). The flag **must not** be enabled in production until the §7.7 Phase-1 exit-gate study passes: ≥ 20 sessions with no second person present and no deliberate absence, across varied lighting, rooms, webcams and skin tones, reporting the per-session FP rate **per event type**, with `multiple_faces` under **5 %** per session. That study needs real humans in real rooms, cannot be done by an agent, and must not be faked, simulated or hand-waved. **It is also the measurement that tells the user whether to keep this feature or delete it** — which, after the 2026-10-31 scope adjustment, is its actual purpose.

---

## §E. Deferred — and these are BLOCKERS before the flag is enabled for real candidates

Dropped from this build because they only bite once real candidates' data is processed, which the default-off flag prevents. **Neither is optional; both are prerequisites, not nice-to-haves.** Record them in the design note under a heading that says so.

1. **The published customer-facing "what is and is not measured" transparency page.** §7.4 requires a short plain-language page KioMeet publishes and the customer hands to candidates. It is what makes AIVIA §5(2) and Illinois HB 3773 notice duties satisfiable by the buyer rather than a problem they discover after signing.
2. **The candidate copy/delete (DSAR) endpoint.** §7.4 item 8 and §7.5: satisfies AIVIA §15's 30-day obligation and the DPDP erasure right. Cheap to build because the artefact is event rows and erasure is one `DELETE` from `interview_presence_sessions` (events and notes cascade) — but it needs the candidate-email columns and a verified-request path, both of which are deliberately absent from migration 023 (§A). Until it exists, the consent screen states the `PRESENCE_RIGHTS_CONTACT` address and requests are handled manually by the operator.

Also still outstanding and unchanged from §7.9 item 9: **legal review before any production use**, on the four named questions (BIPA / Md. §3-717 characterisation; AI Act Art. 6(3) derogation vs. profiling; whether AIVIA reaches a live two-way interview; whether DPDP §7(i) reaches candidates).

---

## §F. NOT DOING — explicit

| Not doing | Why |
|---|---|
| **Head pose / `head_off_axis`; `yaw`, `pitch`, `roll` not collected anywhere** | Phase 2 and out of scope; the user dropped it after a feasibility review. Absent from the DB `CHECK`, the allowlist and the detector; `yaw`/`pitch`/`roll` are in `FORBIDDEN_KEYS` |
| **Code-editor interaction telemetry** | Explicitly out of scope, deferred as the next piece of work (§7.2 reason 7, §7.9 item 1) |
| **Face identity verification** | A different feature, explicitly on hold (`2026-10-27-interview-face-verification-design.md`). This build reuses its *patterns* and touches none of its (unbuilt) code. No reference photo, no matching, no `CompareFaces`, no identity claim in any UI string |
| **Gaze / iris tracking** | §5.4 (no commercially licensed model with published accuracy), §5.5 (covers almost nothing head pose does not), §4.2 (disability false positives). ARKit does not exist on macOS |
| **Blink / eye-aspect-ratio / eyes-closed duration** | No integrity interpretation; reads as medical surveillance; pure false-positive surface |
| **Room scan** | §3.7 (*Ogletree*); worse intrusion than every implemented signal combined |
| **Virtual-camera detection** | Cannot be made reliable on macOS; the heuristics falsely reject desktop-Mac users |
| **Audio signals (second voice, whispering)** | Separate consent scope, separate legal analysis, far worse false-positive story in shared rooms |
| **Server-side frame analysis** | §5.6: ~108 MB per candidate per interview, bandwidth the candidate pays for, and it manufactures the centralised biometric pipeline §7.5 exists to avoid |
| **Frame / crop / thumbnail / video retention for analysis** | A `CVPixelBuffer` exists for the duration of one Vision request and is released. Nothing is encoded, written or transmitted |
| **Emotion, affect, sentiment, mood, engagement, attention, focus, confidence, stress, honesty, deception, personality inference** | EU AI Act Art. 5(1)(f) **prohibited practice** in a hiring context, binding this product as provider, applicable since 2 Feb 2025, up to €35 M / 7 % of worldwide turnover. No field, column, API key, log string, code comment or UI string may imply any of them |
| **Any score, index, percentage, rating, risk level, colour-coded level, aggregate total or candidate-to-candidate / session-to-session comparison** | §7.2, seven reasons. Per-type counts and durations only |
| **Any blocking consent variant** — not even as an opt-in room setting | §7.9 item 6; the Thuringian ruling struck down proctoring consent precisely because there was no real alternative. Declining always joins with monitoring off, no reason requested (this is also the disability accommodation path) |
| **Any automated action** — auto-reject, auto-warn the candidate, auto-interrupt, auto-end the session, auto-rank, ATS propagation | §7.3. Ending an interview stays the interviewer's existing explicit action: one capability, one place |
| **Telling the candidate a specific event fired** | §7.3: mid-answer notification is prejudicial and useless since the interviewer adjudicates. The candidate is told at consent what is recorded, and the persistent indicator shows whether monitoring is active — nothing more |
| **A second `AVCaptureSession`, or any change to `InterLiveKitCameraSource` / `InterLocalMediaController`'s session lifecycle** | The camera device is single-owner; §D invariants |
| **New `InterNetworkErrorCode` values, `isExpectedJoinRejection` changes, `InterFeatureGate` changes, `tiers.js` `FEATURES` changes, `project.pbxproj` edits, Socket.IO signals, LiveKit DataChannel topics** | None are needed; each would be surface to remove later |
| **Any git command** | The user commits themselves (`test` → merge to `main` → push). Leave the working tree and staging index exactly as found |

---

## §G. Verification — the exact commands, and what counts as evidence

Run from `/Users/aman_01/Documents/inter` unless stated. Report actual output. **A zero exit code is not evidence on its own** — state what was observed.

1. **Client build**
   `xcodebuild build -project inter.xcodeproj -scheme inter -configuration Debug -destination 'platform=macOS'`
   Evidence: the literal line `** BUILD SUCCEEDED **`, and zero lines matching `error:`. A build that succeeds with new warnings is acceptable; quote any new warning.

2. **Client tests — the three new suites at minimum**
   `xcodebuild test -project inter.xcodeproj -scheme inter -configuration Debug -destination 'platform=macOS' -only-testing:interTests/InterPresenceConsentViewModelTests -only-testing:interTests/InterPresenceDetectorTests -only-testing:interTests/InterPresenceCaptureSourceTests`
   Evidence: `TEST SUCCEEDED` plus the `Executed N tests, with 0 failures` line for each suite, with N > 0 for each. An `Executed 0 tests` result is a **failure** (the suite did not get compiled into the bundle).
   Then the full suite: `xcodebuild test -project inter.xcodeproj -scheme inter -configuration Debug -destination 'platform=macOS'`
   Evidence: `Executed N tests, with 0 failures` overall; N must be ≥ the pre-change count (README records 140 tests, 0 failures as the last recorded build). Integration suites that `XCSkip` when the local servers are unreachable still count as skipped, not failed — say which skipped.

3. **Server tests**
   `cd token-server && npm test`
   Evidence: `node --test` summary showing `fail 0`, and the three new files named in the output: `test/presenceEvents.test.js`, `test/presenceRetention.test.js`, `test/presenceGate.test.js`. Quote the `# pass` / `# fail` lines. If `presenceGate.test.js` cannot reach Postgres/Redis that is a **failure**, not a skip — both are running locally.

4. **Migration**
   `cd token-server && node migrate.js`
   Evidence: the runner's line applying `023_interview_presence_events.sql`, then
   `psql "$DATABASE_URL" -c "SELECT filename, applied_at FROM schema_migrations WHERE filename LIKE '023%';"` returning exactly one row, and
   `psql "$DATABASE_URL" -c "\d interview_presence_events"` / `"\d interview_presence_sessions"` / `"\d interview_presence_notes"` showing the columns, the `CHECK` constraint without `head_off_axis`, the FKs with their delete actions, and the indexes.
   Then re-run `node migrate.js` and show it reports nothing pending.
   Also show `psql "$DATABASE_URL" -c "SELECT count(*) FROM schema_migrations;"` = 23 and confirm no pre-existing table was dropped or altered: `psql "$DATABASE_URL" -c "\dt"` lists every table that existed before, plus the three new ones.

5. **Local-dev default behaviour unchanged**
   With `PRESENCE_MONITORING_ENABLED` unset: start the token server, then
   (a) `curl -i localhost:3000/presence/events` → `404` with `"code":"PRESENCE_DISABLED"`;
   (b) create an interview room as a `hiring` user with `presenceMonitoring: true` and show `redis-cli HGETALL room:<CODE>` contains **no** key starting with `presence`;
   (c) show the `/room/join` response JSON contains **no** key starting with `presence`;
   (d) state that the candidate join path is therefore `-showIntervieweeConfirmationWithCompletion:` (`AppDelegate.m:2365`), unmodified, and show `git`-free evidence by quoting the method body as it stands.
   Evidence: all four, quoted.

6. **Camera path undisturbed**
   `xcodebuild test … -only-testing:interTests/InterLiveKitCameraSourceTests -only-testing:interTests/InterCameraWiringTests -only-testing:interTests/InterRecordingCoordinatorTests`
   Evidence: `0 failures` on all three — the proof that adding a fourth output owner broke neither the publisher nor local recording.

**Cannot be automated, stated plainly:** the §7.7 false-positive study (≥ 20 real sessions) and the §5.7 resource measurement (process CPU, package power, and the LiveKit publisher's sent-frame rate and encode-time percentiles, monitoring off vs on, on the lowest-spec supported Mac, over a 45-minute two-client call with screen-share active). Both are exit gates before the flag is enabled for real candidates. Do not simulate either. A detector that passes CI and has never been measured against a varied population of honest candidates is precisely the artefact §4 and §6.3 warn about.

---

## §H. Open questions (assumptions made, flag if wrong)

1. **Who declares EU residency and age?** No `users` column records region or date of birth (checked: no `region`, `country`, `date_of_birth` or `birth` column in any migration). Assumption: the **interviewer** declares `candidateRegionEU` / `candidateUnder18` per room, as two toggles in the interviewer green room (`InterGreenRoomRole.hostInterview`, the one screen between "Host Interview" and the room existing — interview rooms have no pre-meeting panel). Server-side both force `armed = false`. Alternative (collect it from the candidate) is worse: it would make the candidate self-declare a protected characteristic to the system that is about to monitor them.
2. **Threshold owner.** §7.9 item 10 requires a named person with a written rationale. Left as `<unassigned>` in the design note rather than invented. Must be filled before the flag is enabled.
3. **Jump-to-timestamp target.** Assumed to be the existing recording surface with an offset, and disabled with an honest caption when no recording exists. If the user wants an in-timeline player that is new scope.

