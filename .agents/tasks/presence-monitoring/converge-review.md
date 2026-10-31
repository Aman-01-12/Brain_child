# Final gate review — candidate presence monitoring (FEAT-001 … FEAT-004)

**Reviewer:** converge gate, iteration 1 (no prior `review.json` existed).
**Method:** files read directly at the absolute paths named in the four FEAT files. No git command was run. Build and test suites were NOT re-run; the recorded evidence in each FEAT's `findings` field was read instead. Two narrow greps and one `find -newermt` were used to establish file-level facts (marker sites, modified-file set), not to re-verify the suites.

**Verdict: CHANGES_REQUESTED — 2 blockers, both on the interviewer client surface, both the same root cause.**

Everything on the server, the schema, the ingest contract, the candidate consent path and the detector is correct and meets the approved requirements. The master flag's zero-impact guarantee holds exactly for the candidate, the server, Redis and the database. It does **not** hold for the interviewer's own surface, which is gated on a client-held request flag instead of a server fact, and which shows the interviewer a sentence that is false in the shipped default configuration.

---

## (a) Master flag — zero impact when off

**Server: provable, one condition per surface.**

* `token-server/presenceConfig.js:46` — `isFeatureEnabled()` is `process.env.PRESENCE_MONITORING_ENABLED === 'true'`, read at call time. Default false.
* Condition 1 — `token-server/presence.js:76-81`, `requirePresenceFeature` is the router's first middleware: `404 {error:'Not found', code:'PRESENCE_DISABLED'}` when the flag is off. It precedes every endpoint, including the five handlers' own auth.
* Condition 2 — `token-server/presenceConfig.js:159` inside `resolvePresenceArming`: `if (featureEnabled !== true) return { armed: false, reason: 'feature_disabled' }`, evaluated first.
* `token-server/index.js:2537-2546` — the arming `hset` is a **second, conditional** `pipeline.hset` placed after the pre-existing one at 2504-2518, which is therefore unchanged. With `armed === false` nothing is written, so a flag-off room hash carries no `presence*` field. Confirmed against the recorded live evidence (18 hash fields, zero beginning `presence`).
* `token-server/index.js:2872-2881` — the join block is `(roomData.presenceMonitoringArmed === 'true') ? {...} : {}` and reaches the response only through the single spread at 2910. An unarmed room yields `{}`, so the response JSON carries no key beginning `presence`. Recorded live evidence: 20 keys, none presence.
* `token-server/index.js:5879` — the sweeper timer is inside `if (presenceConfig.isFeatureEnabled())`, `.unref()`ed, errors caught.

**`-showIntervieweeConfirmationWithCompletion:` is unmodified.** `inter/App/AppDelegate.m:2426-2448`: the method body is the original `NSAlert` — "You are joining an Interview Session", the three secure-mode bullets, the `InterShouldEnforceInterviewExternalDisplayPolicy()` branch, Continue/Cancel, `completion(accepted)`. Nothing presence-related appears inside it. It moved down the file only because text was inserted above it. The new `-showPresenceConsentWithCompletion:` is a separate method beginning at 2464, and it falls back to the legacy alert at 2472 when `presentableMode` is 0.

**Candidate join path: one `if`.** `inter/App/AppDelegate.m:369` inside the existing `preConnectConsentGate`, after the `intervieweeJoiningInterview` guard, reading `activePresenceMonitoringArmed` only; otherwise control falls through to the legacy alert at 373.

**Detector: one `if`.** `inter/UI/Controllers/SecureWindowController.m:612`, on `activePresenceMonitoringGranted`, which only `-recordPresenceConsentWithGranted:state:` writes and only from the candidate's consent screen on the join path.

**Candidate chip: no guard needed.** `SecureCandidateChromeViewModel.presenceMonitoringState` defaults 0 = absent, and `SecureWindowController.pendingPresenceState` defaults 0.

**Interviewer surface: NOT provable from one condition on the flag — see blockers 1 and 2 below.**

## (b) Ingest rejects the prohibited keys with 400, and does not strip them

Correct.

* `token-server/presenceEvents.js:206-215` — the recursive forbidden scan runs **first**, over the whole body at every depth, before the top-level allowlist, so the response names the prohibited concept rather than a generic unknown key. It returns `{ok:false, status:400, code:'PRESENCE_FORBIDDEN_FIELD', error, field}` — a rejection, with no `events` array alongside it.
* `findForbiddenKey` (`:166-182`) recurses through objects **and** array elements, bounded at depth 16, and returns the key **as written** so the message can quote it.
* All six keys the brief names are in `FORBIDDEN_KEYS`: `landmarks` (`:72`), `score` (`:78`), `emotion` (`:82`), `confidence` (`:87`), `attention` (`:86`), `engagement` (`:86`).
* `token-server/presence.js:418-423` returns `verdict.status` with `verdict.code` and `verdict.field` verbatim, so the HTTP response is the 400 the validator produced. Nothing is stripped and no partial batch is written.
* Covered by passing tests: `token-server/test/presenceEvents.test.js:78-87` is one `test()` per key asserting `ok === false`, `status === 400`, `code === 'PRESENCE_FORBIDDEN_FIELD'`, `field === key`, the message contains the key, and `r.events === undefined` ("no events may be returned alongside a rejection"). `:89-95` repeats it at the top level; `:98-123` covers two-levels-deep and inside-an-array-element; `:124-131` covers forbidden-beats-unknown.
* Recorded evidence: FEAT-004 convergence item 2 — `node --test test/presenceEvents.test.js test/presenceRetention.test.js test/presenceGate.test.js` → "tests 82 / pass 82 / fail 0 / skipped 0" with LiveKit up; item 1 — `npm test` → "tests 162 / pass 159 / fail 0 / skipped 3". Real tool output, not a paraphrase.

## (c) No score, index, percentage, rating, risk level or candidate comparison

Correct, in every layer I read.

* **Schema** — `migrations/023_interview_presence_events.sql`: the event row is `event_type` (CHECK of six enum values), two timestamps, `duration_ms`, `detector_version`, `thresholds`, `source`, `purge_after`. No numeric column that could hold a score, and the header comment states the prohibition.
* **API** — `presence.js:596-601` builds `summary` rows of exactly four keys (`eventType`, `count`, `totalDurationMs`, `liveSurfaceable`). No total across types, no weighting, no normalisation, no percentage, no rating, no level, no cross-session or cross-candidate field anywhere in the timeline payload. The prohibition is a comment on the builder (`:510-520`). `totalDurationMs` is a per-type duration sum and is the shape plan §C specifies — not an aggregate index.
* **UI** — `PresenceTimelineView.swift` / `PresenceTimelineViewModel.swift`: a targeted grep for score/percent/rating/risk/ranking returns only the refusal comments at `PresenceTimelineView.swift:12` and `PresenceTimelineViewModel.swift:40-44`, plus `ScrollView` and an `enumerated()` loop variable named `index`. No computed aggregate exists.
* **Logs** — `presence.js:464` logs `code=` and `accepted=` only; the note path logs `noteLength`; the sweeper logs row counts.
* `FORBIDDEN_KEYS` contains the words `score`, `index`, `percentile`, `rank`, `rating`, `risklevel`, `aggregate`, `total` as **values in the rejection list**. That is the mechanism that refuses them, not an implementation of them.

## (d) No emotion, affect, engagement, attention, confidence, honesty or personality inference

Correct. Nothing in the pipeline computes or stores any of these. The only two per-frame numbers that exist (`PresenceSample.minConfidence`, `maxBoxAreaFraction`) are the Vision detector's own bounding-box confidence and box area; `InterPresenceEventEngine.qualityInsufficient` (`InterPresenceEventEngine.swift:330-336`) is their only consumer and it feeds `image_quality_insufficient` alone. The server names its threshold `detectorConfidenceFloor` for exactly this reason (`presenceConfig.js:118-127`). All other appearances of these words across the server, the engine, the detector, the consent copy and the migration are refusals or the forbidden-key list.

## (e) No head pose, gaze, iris, blink, landmark, frame, crop or pixel

Correct.

* `inter/Media/InterPresenceDetector.swift:76-105` constructs one `VNImageRequestHandler` and performs exactly one `VNDetectFaceRectanglesRequest`, reading `results.count`, `boundingBox.width * boundingBox.height` and `confidence`. No landmarks request, no capture-quality request, no feature-print request, no yaw/pitch/roll read. The buffer is used inside the call and released; nothing is retained, copied, encoded or written.
* `PresenceEvent` (`InterPresenceEventEngine.swift:180-240`) is `String`/`Double`/`Int` only — structurally incapable of holding a buffer, image, `Data` or series — and `asPayload()` is the single serialisation path.
* `InterPresenceReporter.swift:135-139` serialises only through `asPayload()`; there is no second encoder.
* `migrations/023` has no frame, crop, landmark, mesh, embedding or template column, and `head_off_axis` is deliberately absent from the `event_type` CHECK, so the database refuses it too.
* Recorded evidence: FEAT-003 item 6/7 — `grep -rln 'import Vision' inter` → exactly `inter/Media/InterPresenceDetector.swift`; the landmarks/capture-quality/feature-print and `.yaw/.pitch/.roll` greps return nothing. The only file write in the feature is `AppDelegate.m:2785`, which writes the CSV **export text** to a path the interviewer chose in an `NSSavePanel`.

## (f) Capture source adds and removes only its own output

Correct, by reading `inter/Media/InterPresenceCaptureSource.swift`.

* `start` (`:137-163`) builds its own `AVCaptureVideoDataOutput`, wraps `canAddOutput` + `addOutput` in `beginConfiguration`/`commitConfiguration`, and bails (committing first) when the session refuses it.
* `stop` (`:168-190`) drops the delegate, then removes **only** `videoDataOutput` inside its own configuration block.
* No `startRunning`/`stopRunning` and no `addInput`/`removeInput` appear anywhere in the file; `sessionRunCalls` exists as a counter so a test can assert the absence rather than trust the comment.
* No LiveKit import, no `mute()`/`unmute()`, and no reference to `recordingFrameObserver`.
* `videoSettings` pinned to `kCVPixelFormatType_32BGRA` (`:120-122`), `alwaysDiscardsLateVideoFrames = true`, delegate queue `inter.presence.detect` at `.utility`.
* The coordinator's `stop` (`InterPresenceCoordinator.swift:195-200`) dispatches `captureSource.stop` onto the session queue with a strong capture of the session, so the output is removed on the queue that owns the session.
* Recorded evidence: `InterPresenceCaptureSourceTests` 14/14 passed; `InterLiveKitCameraSourceTests` 6/6, `InterCameraWiringTests` 15/15, `InterRecordingCoordinatorTests` 17/17 — the pre-existing camera publisher and local recording are undisturbed. `InterLiveKitCameraSource.swift` (mtime 6 Jun) and `InterLocalMediaController.h/.m` (16 Jun) are untouched.

## (g) A detection failure is `image_quality_insufficient`, never `face_absent`

Correct, and the clause is load-bearing rather than incidental.

`InterPresenceEventEngine.swift:383`:

```swift
emitted += step(&faceAbsent, condition: sample.faceCount == 0 && !qualityBad, at: t)
```

`qualityBad` is `detectorFailed || minConfidence < floor || maxBoxAreaFraction < floor` (`:330-336`). A thrown Vision request or a nil results array produces `failedSample()` with `detectorFailed = true` (`InterPresenceDetector.swift:88-98`, `:139-145`), which therefore can only ever open `image_quality_insufficient`. The precedence lock and the "critical rule" are block comments above the state machine (`:252-285`). The complementary decision is also right: an **empty but successful** detection returns the neutral sentinels area 1.0 / confidence 1.0 (`InterPresenceDetector.swift:116-123`), so a genuine absence is recorded as `face_absent` instead of being misfiled as poor quality — zeroes there would have made `face_absent` unreachable. Recorded evidence: three named tests assert `events.contains { $0.eventType == "face_absent" } == false` for detector failure, sub-floor confidence and sub-floor box area; `InterPresenceDetectorTests` 31/31 passed.

## (h) Timeline read is authorised by `requireAuth` + `validateModerator`

Correct.

`presence.js:627-630`: `router.get('/timeline/:code/:identity', requireAuth, makePresenceRateLimiter('presence-timeline', 60, 60), requireModerator, handler)`. `requireModerator` (`:221-266`) re-reads the room, enforces the hiring tier gate, then calls `validateModerator(code, callerIdentity, req.user.userId)`, failing closed on a throw (503) and on `!verdict.valid` (403 `PRESENCE_FORBIDDEN`). The argument order matches the injected helper's signature, `index.js:2230: async function validateModerator(code, callerIdentity, userId = null)`, so the identity→userId binding cross-check at `index.js:2232-2240` genuinely runs — which is what stops an authenticated participant from passing the host's identity as `callerIdentity`. The note and export paths use the same `requireAuth` + `requireModerator` pair (`:689-691`, `:823-826`). `requireAuth` is `auth.requireAuth` (`index.js:2317`), and the app-level `auth.authenticateToken` at `index.js:142` runs before the router so `req.user` is populated.

## (i) Every FK in migration 023 names a deliberate ON DELETE policy

Correct — six FKs, six named policies, each with its reason in a comment:

| Column | Policy | Reason given |
|---|---|---|
| `interview_presence_sessions.meeting_id` | `ON DELETE CASCADE` | `meetings` is the parent record; mirrors `meeting_participants.meeting_id` |
| `interview_presence_sessions.host_user_id` | `ON DELETE SET NULL` | the candidate's record and the retention obligation outlive the recruiter's account |
| `interview_presence_sessions.candidate_user_id` | `ON DELETE SET NULL` | candidates are usually guests; deleting an account must not destroy the retention clock |
| `interview_presence_events.session_id` | `ON DELETE CASCADE` | an event without its session has no thresholds, consent provenance or clock |
| `interview_presence_notes.event_id` | `ON DELETE CASCADE` | a note annotates exactly one event |
| `interview_presence_notes.author_user_id` | `ON DELETE SET NULL` | the note survives the author's account deletion (with the denormalised `author_display_name`) |

`thresholds`, `detector_version` and `purge_after` are `NOT NULL` on both sessions and events; the `event_type` CHECK lists exactly the six types and omits `head_off_axis`; `IF NOT EXISTS` throughout; one `updated_at` trigger, on sessions only, with a preceding `DROP TRIGGER IF EXISTS`. Recorded evidence (FEAT-004 convergence item 3) read `confdeltype` straight out of `pg_constraint`: `c, n, n, c, c, n` — matching the table above — plus `schema_migrations` count 23, one `023%` row, 26 public tables, all seven named indexes present, and `pg_constraint LIKE '%head_off_axis%'` → 0 rows.

## (j) No git command; working-tree change set

* No git command was run by this review, and every FEAT records the same.
* `find inter interTests token-server -newermt 2026-10-30` over source extensions returns 39 files. 37 of them are exactly the files the four FEATs name (plus `token-server/.env.example`; `README.md` is outside the extension filter).
* **Two files are modified but named in no FEAT:** `inter/Networking/InterAppConfig.swift` (30 Oct 21:21) and `interTests/InterAppConfigTests.swift` (30 Oct 21:23). Both contain zero occurrences of "presence", and both predate this task (the task directory was created 31 Oct 00:43 and migration 023 was applied 31 Oct 01:07). They belong to the earlier token-server endpoint/port-forwarding work in the same session. Pre-existing and unrelated — reported for the record, not a blocker.
* `inter.xcodeproj/project.pbxproj` mtime 16 Jun 22:37 — unmodified, as required.

## Verification evidence

Present, and real tool output rather than paraphrase: FEAT-004's convergence section records `npm test` → "tests 162 / suites 17 / pass 159 / fail 0 / skipped 3", the three new server files re-run by name with LiveKit up → "tests 82 / pass 82 / fail 0 / skipped 0", `node migrate.js` → "No pending migrations" twice with the `schema_migrations` and `pg_constraint` reads quoted, `xcodebuild build` → `** BUILD SUCCEEDED **` with `grep -c "error:"` = 0, and the full `xcodebuild test` read out of the `.xcresult` bundle → 794 total / 777 passed / 4 failed / 13 skipped with per-suite counts (`InterPresenceConsentViewModelTests` 39/39, `InterPresenceDetectorTests` 31/31, `InterPresenceCaptureSourceTests` 14/14, so no suite was silently excluded).

The 4 failures are `InterMultiParticipantIntegrationTests` (`testCreateRoom_includesMaxParticipants`, `testRoomFull_rejectsExcessParticipants`, `testRoomFull_sameIdentityDoesNotCountTwice`, `testRoomInfo_returnsParticipantCount`). The recorded diagnosis is specific and checks out: those suites call `/room/create` with no bearer token and are rejected by `app.use(auth.authenticateToken)` at `index.js:142`, which runs **before** the presence router mounts at `index.js:2326`, so no presence code is on that path; their `setUp` uses `try? XCTSkipUnless(...)`, which swallows the skip, so they fail instead of skipping. Pre-existing and out of scope. The two `-skip-testing`'d methods (`SecureToolsWindowAuditTests.testSecureToolsSourcesContainNoWindowSpawningAPIs`, `SecureToolsNetworkAuditTests.testSecureToolsSourcesImportNoNetworkingModules`) enumerate `inter/UI/SwiftUI/SecureTools/*.swift` only; no file this change touches lives there, and the exclusion is recorded with its measured 1793 s runtime. Acceptable.

---

# Blockers

## Blocker 1 — the interviewer's presence surface is not gated on the master flag

**File:** `/Users/aman_01/Documents/inter/inter/App/AppDelegate.m:839-843`
(supporting: `/Users/aman_01/Documents/inter/inter/Networking/InterRoomController.swift:288-290` and `:535-536`)

**What the code does.**

```objc
if (mode == InterCallModeInterview
    && role == InterInterviewRoleInterviewer
    && self.roomController.activePresenceSurfaceVisible) {
    [self startInterviewerPresenceSurface];
}
```

`activePresenceSurfaceVisible` is `activePresenceMonitoringArmed || activePresenceMonitoringRequested` (`InterRoomController.swift:288-290`), and `activePresenceMonitoringRequested` is assigned on the **create** path purely from the host's own green-room tick (`:535-536`) — it never consults the server. `/room/create` returns no presence block, so on the create path there is no server fact in play at all.

**Approved requirement this misses.** Plan item 15(f) specifies the guard verbatim: `if (rc.activePresenceMonitoringArmed) { [bridge setPresenceAvailable:YES]; … start the poll timer; }`. Plan D0.1 states the purpose: "a reviewer must be able to confirm 'flag off ⇒ zero behavioural change' by reading one condition." For this surface that is not possible, because the condition that is actually read is true with the flag off.

**User-visible consequence, in the shipped default configuration (`PRESENCE_MONITORING_ENABLED` unset).** A hiring interviewer who ticks the green-room checkbox gets, for the whole interview: a new chip in the call control bar reading "Presence monitoring off", a timeline panel reading "Could not read the presence timeline.", and a 15 s `NSTimer` poll of `GET /presence/timeline` that returns `404 PRESENCE_DISABLED` every tick. None of that happens on a server without this feature. A secondary effect of the same design: `activePresenceMonitoringRequested` is only reassigned on the create path, so after one ticked create it stays true for later rooms joined in the same app session, and the surface appears there too.

**Correction.** Make the interviewer guard read a server fact. The server already computes the arming outcome at `token-server/index.js:2529-2536`; echo it in the `/room/create` response the same way `/room/join` does — a key emitted **only** when `presenceArming.armed` is true, so a flag-off response stays byte-clean — set `activePresenceMonitoringArmed` from it on the create path, and change `AppDelegate.m:841` to read `activePresenceMonitoringArmed`, deleting `activePresenceSurfaceVisible` and `activePresenceMonitoringRequested`. (Gating on `activePresenceMonitoringArmed` alone, per plan item 15(f) and without the `/room/create` echo, also closes the hole; it costs the interviewer the live chip on the create path.)

## Blocker 2 — the green-room caption tells the interviewer the candidate will be asked for consent when the candidate is never asked

**File:** `/Users/aman_01/Documents/inter/inter/UI/SwiftUI/Screens/GreenRoomViewModel.swift:132-133`
(supporting: `:112`, `showsPresenceControls` is `role == .hostInterview` and consults nothing else)

**What the code does.** With the box ticked and neither policy flag set, `presenceCaption` returns:

> "The candidate is asked first and can join with monitoring off. No decision is automated."

The checkbox is shown to every `hostInterview` role regardless of the master flag.

**Why it is wrong.** With the flag off — the shipped default — the server never arms the room, `/room/join` carries no presence block, `activePresenceMonitoringArmed` is false, and `AppDelegate.m:369` falls straight through to the legacy `NSAlert`. The candidate is **never** asked, and no consent record, session row or event row is created. The caption states the opposite as a fact. The interviewer can reasonably conclude that presence monitoring was armed for the interview and that the candidate consented or declined, when neither happened. This is precisely the class of untrue claim the feature's own copy discipline forbids, and it is live in the default build.

**Correction.** Either gate `showsPresenceControls` (`:112`) on a server-provided capability so the control is absent when the feature is off, or reword the ticked caption so it does not assert that a consent prompt will occur — e.g. state that monitoring is requested for this room and that the candidate is asked first *when the server has it enabled*, with the "nothing is recorded unless the candidate agrees" substance kept. Since the green room renders before `/room/create`, the capability form needs a flag on an existing pre-call response rather than on the create reply; the reworded caption is the smaller fix and is sufficient to remove the false statement.

---

# Non-blocking observations (recorded, no change requested)

1. **Two writers of the candidate chip, with a narrow race.** `AppDelegate.m:2537` and `:2564` write the chip from the consent decision and from the consent POST response, while `InterPresenceCoordinator` is meant to be the single writer. `pushState` deduplicates against the coordinator's own `lastPushedState` (`InterPresenceCoordinator.swift:290-298`), so if a slow consent POST lands after the coordinator has pushed 3 ("paused — camera off"), the chip can read "Presence monitoring on" while the camera is off until the next camera transition. The error direction over-reports monitoring rather than under-reporting it, the dangerous direction ("off" while actually on) is not reachable — a declining candidate never starts the coordinator, and `stop()` pushes 2 last — and FEAT-003 recorded the dual ownership deliberately. Not a blocker.
2. `duration_ms` is `INTEGER`; a `monitoring_gap` longer than ~24.8 days would overflow the `::int` cast in `presence.js:437` and `presenceRetention.js:80`. Unreachable in practice (the stale-session closer runs at `PRESENCE_STALE_SESSION_MINUTES`, default 10, and rows purge at 90 days). Speculative, not filed.
3. `presence.js:63` accepts `roomKey` into the dependency contract and never uses it (eslint-disabled). Recorded as a deviation in FEAT-001; harmless.
4. FEAT-001's findings say `FORBIDDEN_KEYS` has 90 entries; the module has 82. FEAT-004 caught and documented this. No code consequence.
