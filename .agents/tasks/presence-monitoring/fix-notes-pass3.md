# fix-notes-pass3.md — the pass-3 blocker fix, with its evidence

**Blocker fixed:** `review.json` pass-3 blocker — per-connection presence state was never reset on
the app-lifetime `InterRoomController`, and the scheduled-meeting connect path assigned none of it,
so with `PRESENCE_MONITORING_ENABLED` on (a) a stale `activePresenceMonitoringGranted` started the
detector in a later interview the candidate was never asked about and (b) a stale
`activePresenceMonitoringArmed` drove the consent screen and the interviewer surface in a scheduled
room the server never armed.

**No `git` command was run** — not `add`, not `commit`, not `status`, not `diff`, nothing. The
working tree and index are exactly as they were found, apart from the four files listed below. The
one throwaway probe script was written to `/tmp`.

**Written:** 2026-10-31, after the fix and after every gate below had been run.

---

## 1. Files created or modified

| File | Change |
|---|---|
| `/Users/aman_01/Documents/inter/inter/Networking/InterRoomController.swift` | **The fix.** Added `resetPresenceConsentForNewConnection()` and `applyPresenceSettingsFromScheduledMeeting(_:)`; call the reset at the top of both public connect entry points; call the scheduled assignment in the `/meetings/:id/start` branch |
| `/Users/aman_01/Documents/inter/interTests/InterPresenceSessionIsolationTests.swift` | **New file.** Five regression tests for per-connection isolation of the presence block |
| `/Users/aman_01/Documents/inter/docs/superpowers/specs/2026-10-31-interview-presence-monitoring-design.md` | §2.2 corrected: the false "assigned unconditionally on both paths" claim is replaced by new §2.2.1, which states the claim was wrong, enumerates the **four** connect paths, and records the three ordering facts the reset depends on |
| `/Users/aman_01/Documents/inter/.agents/tasks/presence-monitoring/REMOVAL.md` | Kept accurate: new test file added to §2 (3 → 4 client tests, 21 → 22 files), the `InterRoomController.swift` row in §3.3 re-anchored (4 → 7 hunks, with the new line numbers), and the §3.1 marker-grep counts re-measured |
| `/Users/aman_01/Documents/inter/.agents/tasks/presence-monitoring/fix-notes-pass3.md` | This note (new file) |

Nothing else was touched. In particular: no server file, no migration, no `AppDelegate.m`, no
`SecureWindowController.m`, no `project.pbxproj` (both `inter` and `interTests` are
`PBXFileSystemSynchronizedRootGroup`, so the new test file needs no project edit), and
`-showIntervieweeConfirmationWithCompletion:` remains byte-for-byte unchanged.

---

## 2. Where the entry-point resets landed, and what was NOT added

Both resets are a single call to one private method, placed in
`inter/Networking/InterRoomController.swift`:

| Symbol | Line | What is reset |
|---|---|---|
| `connect(configuration:completion:)` | `:485` | `resetPresenceConsentForNewConnection()` |
| `connect(withToken:serverURL:configuration:completion:)` | `:678` | `resetPresenceConsentForNewConnection()` |
| `resetPresenceConsentForNewConnection()` (the method) | `:319` | `activePresenceMonitoringGranted = false`, `activePresenceConsentState = "pending"` |

**Nothing was added to `handleTokenResponse`.** Confirmed by reading it end to end (it begins at
`:696`): it contains no reference to any `activePresence*` property and no call to either new
method. The only occurrence of the word "presence" in it is the pre-existing consent-gate comment
about LiveKit participant presence. The reviewer's
ordering constraint is respected for the stated reason — `handleTokenResponse` runs on the token
completion's thread and its main-queue hop would land *after* the join branch's assignment and
clobber the server's answer.

Three ordering properties hold, and each is asserted by a test:

* The reset is **synchronous** on the caller's (main) queue — the same place `isConnecting = true`
  and `self.configuration = …` are already assigned — so it is ordered strictly before the server's
  answer (which arrives later inside a `DispatchQueue.main.async` block) and before the pre-connect
  consent gate. Test 2 asserts the cleared value in the same run-loop turn as the `connect` call,
  so it cannot be satisfied by a later hop. Test 1 asserts it from *inside* the gate.
* It is placed **after** the state and double-connect guards, so a refused `connect` cannot void a
  live session's consent. Test 3 asserts this.
* It resets **only the consent pair**, never the arming block, because on the lobby-admitted path
  `AppDelegate.m:4878` applies the settings dict (and with it the arming block) *before*
  `connectWithToken` at `:4894`; resetting arming inside `connect(withToken:…)` would clobber the
  server's answer. The dict carries no consent, which is why the consent pair is the right thing to
  reset in the one shared place.

The arming block needs no shared reset because all four paths now assign it unconditionally from
the server's own answer — see §4.

---

## 3. Prescribed-fix item 3 — teardown clearing: DECIDED AGAINST, with the reason

**Decision: do not clear presence state in `-stopPresenceSurfaces` or `-destroySecureWindow`.** The
entry-point reset is the primary fix and is sufficient; adding teardown clearing would clobber a
live session and break the feature.

The evidence, read from the tree rather than assumed:

* `-stopPresenceSurfaces` has exactly one caller: `-teardownActiveWindows`
  (`AppDelegate.m:6747`). `-destroySecureWindow` likewise is called from `-teardownActiveWindows`
  (`AppDelegate.m:6887`).
* `-teardownActiveWindows` is **not** only an exit path. It is called at `AppDelegate.m:736`
  *inside* `-enterMode:` — i.e. during the transition **into** the new session, after the connect
  has succeeded and after the server's arming answer and the candidate's consent have been
  recorded. The comment already sitting at `:730` documents exactly this hazard for a neighbouring
  field: `pendingMeetingSettings` has to be saved into a local and restored immediately after the
  teardown call, because the rest of the same `-enterMode:` pass still needs it.
* The three sites that read the presence state (`AppDelegate.m:822` candidate POST + chip, `:839`
  interviewer surface, `SecureWindowController.m:612` the detector) all run **later in that same
  `-enterMode:` pass**. Clearing `granted` or `armed` at `:736` would therefore switch the feature
  off for every session: no consent POST, no chip, no detector, even for a properly armed room with
  a consenting candidate.

So teardown clearing is not defence in depth here; it is a self-inflicted regression. The invariant
is instead carried by the two mechanisms that cannot be reached mid-setup: a synchronous reset at
the connect entry points, and an unconditional per-path assignment of the arming block.

---

## 4. The design-note §2.2 correction

The sentence the reviewer falsified —

> "the property is assigned unconditionally on both paths, so a room armed earlier in the same app
> session cannot leak its state into the next room"

— is gone. §2.2 now ends with the two facts that are true (site 4 reads `granted`, site 3 reads the
same `armed` boolean as sites 1 and 2) and hands off to a new **§2.2.1 "Per-connection isolation —
there are FOUR connect paths, not two"**, which opens by stating plainly that the earlier claim was
wrong on two counts: there are four paths, not two, and the scheduled path assigned no presence
field at all, so arming *did* leak into it; consent leaked on every path because nothing cleared it
between sessions.

The four enumerated paths, as recorded in the new table:

| # | Connect path | Entry point | Who writes the presence block |
|---|---|---|---|
| 1 | `/room/create` — the interviewer who creates the room | `connect(configuration:completion:)`, `isHost == true`, empty `scheduledMeetingId` | Create branch (`:571`): `armed` from `response.presenceMonitoringArmed`, plus `RegionEU` / `Under18` from the host's local config |
| 2 | `/room/join` — anyone joining by code, including a rejoining host | `connect(configuration:completion:)`, `isHost == false` | Join branch (`:619`): all eight fields from the typed response; an omitted block means `armed == false` |
| 3 | `/meetings/:id/start` — a scheduled interview | `connect(configuration:completion:)`, non-empty `scheduledMeetingId` | **New:** `applyPresenceSettingsFromScheduledMeeting(_:)` called at `:518`, unconditionally, in the same main-queue block as the settings snapshot. That endpoint never arms a room and returns no key beginning `presence`, so this resolves to `armed == false` and the shipped defaults |
| 4 | Lobby-admitted — the candidate the host let in from the waiting room | `connect(withToken:serverURL:configuration:completion:)` | `applyMeetingSettingsFromDict(_:)`, called by `AppDelegate.m:4878` **before** `connectWithToken` at `:4894`, mirrors all eight fields with the same backward-compatible defaults |

§2.2.1 also records that the consent pair is reset at the top of both public entry points (the only
two ways in, so all four paths pass through one of them), the three ordering facts from §2 above,
and why only the consent pair — never the arming block — is reset there. It closes by naming
`interTests/InterPresenceSessionIsolationTests.swift` as the regression suite for the section.

---

## 5. The new tests

All five live in `/Users/aman_01/Documents/inter/interTests/InterPresenceSessionIsolationTests.swift`.

| Test | What it proves |
|---|---|
| `testGrantedConsent_doesNotSurviveIntoTheNextConnect_lobbyAdmittedPath` | Consent granted in interview 1 is already cleared **by the time the pre-connect consent gate runs** on the next connection — asserted from inside the gate, which is the exact observer whose ordering matters, and which is the one thing a main-queue-hop reset would get wrong. Also asserts the declined gate still produces the unchanged `consentDeclined` (1020) rejection and leaves the controller `.disconnected` |
| `testGrantedConsent_doesNotSurviveIntoTheNextConnect_tokenFetchPath` | Same property for `connect(configuration:completion:)`, asserted **synchronously** after the call returns, so it cannot be satisfied by any later main-queue hop; re-asserted after the failed completion |
| `testRejectedDoubleConnect_doesNotClearALiveSessionsConsent` | The reset sits after the connect guards: a second `connect` during a live session is refused **without** voiding the consent the running session is monitoring under. This is the regression that a naive "reset at line 1" would introduce |
| `testScheduledMeetingResponse_disarmsARoomArmedEarlierInTheSameAppSession` | The prescribed item-2 property. A room armed earlier in the app session (seeded through the real `applyMeetingSettingsFromDict`, `armed = true`, retention 30, `multipleFaces` on, a detector version) followed by a scheduled response carrying **no presence key** yields `armed == false` and all seven remaining fields back at their shipped defaults |
| `testScheduledMeetingResponse_carriesAnArmedServerAnswer` | The scheduled assignment is the **server's answer**, not a hardcoded `false` — so if that endpoint ever starts arming rooms the client follows it instead of silently ignoring it |

### Seam note, stated rather than skipped

Tests 4 and 5 call `applyPresenceSettingsFromScheduledMeeting(_:)` — the function the scheduled
branch calls — directly, rather than driving a whole `connect`. **The existing architecture makes a
connect-driven test of that branch impractical:** `InterRoomController.tokenService` is a `let`
(`:105`) with no injection point and `InterTokenService` is constructed inline, so the scheduled
branch's assignment block only executes when a real `/meetings/:id/start` answers; with no server
reachable the response is `nil`, `if let r = response` is false, and the branch body never runs. The
function under test is the shipping one and nothing else calls it, so this is the closest reachable
seam to the branch itself. The branch's *call* to it is covered by the live server-side probe in §7
(the endpoint provably returns no presence key at any depth) plus the build.

The scheduled branch is therefore one line — the call — rather than an inline block. That is the
only structural deviation from the prescribed wording, and §8 records it.

---

## 6. Commands run, and their results

### Client build

```bash
cd /Users/aman_01/Documents/inter && xcodebuild build -project inter.xcodeproj \
  -scheme inter -configuration Debug -destination 'platform=macOS'
```

`** BUILD SUCCEEDED **` (log line 806), exit 0, **`grep -c "error:"` = 0**.

`grep -c "warning:"` = 24. This is a full, cold compile, so every pre-existing warning in the
project is emitted; the pass-2 review's "1 warning" was an incremental build that recompiled almost
nothing. All 24 were read: pre-existing Swift 6 `Sendable` warnings, non-exhaustive `switch`
warnings, three `-Wnonnull`/unused-variable warnings in Objective-C, the
`appintentsmetadataprocessor` note and the project's `Info.plist in Copy Bundle Resources`
warning. **None is at any line this change added** — the `InterRoomController.swift` warnings are at
`:55`, `:60`, `:855`, `:1291`, `:1344`, and the new hunks are at `:319`–`:345`, `:482`–`:485`,
`:512`–`:518`, `:674`–`:678`.

### Client tests — targeted (the fix, the presence suites, the camera/recording regressions)

```bash
cd /Users/aman_01/Documents/inter && xcodebuild test -project inter.xcodeproj -scheme inter \
  -configuration Debug -destination 'platform=macOS' \
  -only-testing:interTests/InterPresenceSessionIsolationTests \
  -only-testing:interTests/InterPresenceDetectorTests \
  -only-testing:interTests/InterPresenceConsentViewModelTests \
  -only-testing:interTests/InterPresenceCaptureSourceTests \
  -only-testing:interTests/InterRoomControllerTests \
  -only-testing:interTests/InterTokenServiceTests \
  -only-testing:interTests/InterLiveKitCameraSourceTests \
  -only-testing:interTests/InterCameraWiringTests \
  -only-testing:interTests/InterRecordingCoordinatorTests \
  -only-testing:interTests/InterRecordingEngineTests \
  -only-testing:interTests/InterRecordingLayoutLogicTests \
  -only-testing:interTests/SecureCandidateChromeViewModelTests \
  -only-testing:interTests/InterCallControlBarBridgeTests
```

`** TEST SUCCEEDED **` — **198 cases passed, 0 failed**, including all five new tests
(`testGrantedConsent_doesNotSurviveIntoTheNextConnect_lobbyAdmittedPath` 0.004 s,
`…_tokenFetchPath` 0.040 s, `testRejectedDoubleConnect_doesNotClearALiveSessionsConsent` 0.008 s,
`testScheduledMeetingResponse_carriesAnArmedServerAnswer` 0.001 s,
`testScheduledMeetingResponse_disarmsARoomArmedEarlierInTheSameAppSession` 0.001 s).

### Client tests — full suite, against the recorded baseline

```bash
cd /Users/aman_01/Documents/inter && xcodebuild test -project inter.xcodeproj -scheme inter \
  -configuration Debug -destination 'platform=macOS'
```

`** TEST FAILED **` — **782 passed, 6 failed.** The baseline is 4, so the extra two were run down
rather than waved through:

1. **The 4 recorded baseline failures, confirmed present and unchanged** —
   `InterMultiParticipantIntegrationTests.testCreateRoom_includesMaxParticipants`,
   `…testRoomFull_rejectsExcessParticipants`, `…testRoomFull_sameIdentityDoesNotCountTwice`,
   `…testRoomInfo_returnsParticipantCount`. These need a token server on `localhost:3000`; none was
   started (deliberately — starting one would have changed this baseline).
2. **2 failures outside the baseline, proven environmental and not caused by this change** —
   `SecureToolsNetworkAuditTests.testSecureToolsSourcesImportNoNetworkingModules` and
   `SecureToolsWindowAuditTests.testSecureToolsSourcesContainNoWindowSpawningAPIs`. Re-run in
   isolation, they fail the same way. The failure message, read out of the `.xcresult` with
   `xcrun xcresulttool get test-results test-details`, is:

   > `XCTAssertFalse failed - expected to find SecureTools .swift sources under /Users/aman_01/Documents/inter/inter/UI/SwiftUI/SecureTools; found none`

   with a run time of **7 m 4 s** for a directory walk. Mechanism: both tests statically enumerate
   `inter/UI/SwiftUI/SecureTools` from `#filePath`, but `inter/inter.entitlements` sets
   `com.apple.security.app-sandbox = true` with only
   `com.apple.security.files.user-selected.read-write`, so the sandboxed test runner cannot
   enumerate `~/Documents`; `fileExists` succeeds (so the test does not take its `XCTSkip` branch)
   while `FileManager.enumerator` yields nothing after a multi-minute TCC stall. Not caused by this
   change, and structurally incapable of being: the two tests read **only**
   `inter/UI/SwiftUI/SecureTools`, which this change does not touch. Running their exact scan
   outside the sandbox finds **12** `.swift` files and **zero** forbidden tokens for all 16 patterns
   (`import Network`, `URLSession`, `URLRequest`, `URL(string:`, `NWConnection`, `CFSocket`,
   `getaddrinfo`, `Host(`, `NSURLConnection`, `import LiveKit`, `WebSocket`, `dataTask`,
   `downloadTask`, `uploadTask`, `import URLSession`, `import Socket`), so the property the tests
   exist to protect genuinely holds. **Recommend updating the recorded baseline to 6 on this
   machine**, or granting the test runner Documents access, so the next reviewer is not sent after
   the same two.

### Token-server suite

```bash
cd /Users/aman_01/Documents/inter/token-server && npm test
```

`tests 162 / suites 17 / pass 159 / fail 0 / cancelled 0 / skipped 3 / todo 0 /
duration_ms 22394`, exit 0. Exactly the recorded totals: 162 tests, 0 failures, 3 skips.

The 3 skips are the `presenceGate` arming subtests that need LiveKit, so they were run for real:

```bash
cd /Users/aman_01/Documents/inter/token-server && node --test \
  test/presenceGate.test.js test/presenceEvents.test.js test/presenceRetention.test.js
```

with `livekit-server --dev` up: `tests 82 / suites 12 / pass 82 / fail 0 / cancelled 0 /
**skipped 0** / todo 0 / duration_ms 3459`. The 3 subtests executed rather than skipping, and the
forbidden-key `400 PRESENCE_FORBIDDEN_FIELD` coverage in `presenceEvents.test.js` is part of that 82.

### Flag-off zero impact, and the NEW no-leak property

Live, against the dev Postgres (`inter_dev`), Redis and `livekit-server --dev`, via a throwaway
probe written to `/tmp/pass3-noleak-check.js` (nothing in the working tree):

| Group | What was exercised | Measured |
|---|---|---|
| **A — flag OFF** | ingest; `hiring` host `/room/create` with `roomType: 'interview', presenceMonitoring: true`; the room hash; `/room/join` | `404 {"code":"PRESENCE_DISABLED"}`; create **8 keys / 0 presence**; room hash **18 fields / 0 presence**; join **20 keys / 0 presence** |
| **B — flag ON, armed room then an UNARMED one** | an armed create, then the **next** room created with `presenceMonitoring: false`, then its join, then an `candidateRegionEU: true` create | armed create **9 keys** with `presenceMonitoringArmed: true`; next unarmed room: create **8 keys / 0 presence**, hash **18 fields / 0 presence**, join **20 keys / 0 presence**; EU-declared create **0 presence** |
| **C — flag ON, the scheduled path** | `POST /meetings/schedule` (hiring, `roomType: 'interview'`) then `POST /meetings/:id/start`, scanned **recursively** for any key matching `/presence/i` at any depth; then the scheduled room's hash; then an ingest attempt against it | start response **7 top-level keys + `roomSettings` 10 keys, 0 matching `/presence/i` at any depth**; scheduled room hash **17 fields / 0 presence**; ingest **403 `PRESENCE_UNAUTHORIZED`** (the leave-token check fires before the arming check, so it never reaches `409 PRESENCE_MONITORING_NOT_ARMED` — refused either way) |

Probe output ended `ALL CHECKS PASSED`.

Together with the client tests this is the new property end to end: the **server** never hands a
client a presence key for an unarmed or a scheduled room even with the flag on (B and C), and the
**client** no longer carries one over from the previous room (tests 1–5). Group A re-confirms the
flag-off guarantee is untouched, matching the pass-2 numbers field for field (8 / 18 / 20).

### Processes and data

* **`livekit-server --dev`: started, and stopped.** `pkill -f "livekit-server --dev"`; port 7880 has
  no listener afterwards and `pgrep livekit-server` is empty.
* **No token server was started** on port 3000 or anywhere else, deliberately, so the 4-failure
  client baseline stayed the recorded one.
* The probe created one `hiring` user, five rooms and one meeting, and removed all of them: 5 room
  key sets deleted from Redis, the `meetings` row deleted, the user deleted,
  `interview_presence_sessions` back to **0 rows**. No table was dropped, reset, truncated or
  altered; no migration was run.

---

## 7. Hard constraints — confirmed one by one, for this change

* **No aggregate score / index / percentage / rating / risk level, no candidate-to-candidate
  comparison.** The change adds two methods that assign booleans, one `Int` (`retentionDays = 90`,
  a retention window) and empty strings, plus tests and prose. A word-boundary grep over the new
  hunks and the new test file for `score|rating|risk|percentile|aggregate` returns nothing. Nothing
  reads a second candidate's state; the controller holds one room at a time, which is the point of
  the fix.
* **No emotion / affect / engagement / attention / confidence / honesty / personality inference** in
  code, column names, API fields, log strings, comments or UI copy. Grep over the new hunks and the
  new test file for `emotion|affect|engagement|attention|personality|cheat|proctor` returns nothing.
  No UI copy was changed at all. (A tree-wide grep hits `promotion/demotion` at
  `InterRoomController.swift:1396` — pre-existing, unrelated role vocabulary, and the substring of
  "demotion", not an inference.)
* **No gaze or iris tracking, no head pose (`yaw`/`pitch`/`roll`), no room scan, no blink or
  eye-aspect-ratio, no virtual-camera detection, no audio signals, no server-side frame analysis, no
  frame/crop/landmark retention.** None added: grep over the new hunks and the new test file for
  `gaze|iris|\byaw\b|\bpitch\b|\broll\b|blink|landmark|virtual.?camera|room.?scan` returns nothing.
  No detector, Vision or capture file was touched; `inter/Media/InterPresenceDetector.swift` is
  unchanged and is still the only `import Vision` in the client. The fix strictly *reduces* the
  number of sessions in which any frame is analysed.
* **No automated action of any kind.** No new call site, no new server request, no new UI affordance
  — the change clears two properties and assigns eight.
* **The ingest endpoint still rejects any payload containing a forbidden key with 400, still
  test-covered.** `token-server/presenceEvents.js` and `test/presenceEvents.test.js` are untouched
  and green: part of `npm test` (162 / 0 fail) and of the 82 / 82 LiveKit-up run.
* **`multiple_faces` stays default-OFF with the false-positive-study prerequisite documented.**
  `presenceConfig.js:61` (`=== 'true'`) and its `:63`–`:67` prerequisite comment are untouched, as is
  design note §7.1. The new scheduled assignment sets
  `activePresenceMultipleFacesEnabled = false`, which is the default-off direction.
* **The feature is still cleanly removable, and `REMOVAL.md` matches the files touched.** §2 now
  lists 22 files including the new test; §3.3's `InterRoomController.swift` row now reads 7 hunks
  with the real anchors (`:251` property block + the three methods, `:360` dict mirrors, `:482`
  entry-point reset, `:512` scheduled call, `:571` create branch, `:619` join branch, `:674`
  entry-point reset); §3.1's grep counts were **re-measured, not guessed** — `'PRESENCE MONITORING'`
  **38** files (was 37, the new test file carries the marker), `'PRESENCE MONITORING (provisional'`
  **37** (was 36), `'PRESENCE MONITORING (provisional)'` **15** (unchanged). Every hunk this change
  added opens with the `PRESENCE MONITORING` marker, so the removal grep finds all of them. No
  server file, migration or `.env` key was added, so §3.2, §4 and §6 need no change.

---

## 8. Deviations from the prescribed fix

1. **The scheduled-branch assignment is a named method call, not an inline block.** Item 2 said
   "assign the presence block on the scheduled branch … exactly as the join branch does"; the branch
   now calls `applyPresenceSettingsFromScheduledMeeting(r)`, which does the assignment.
   *Reason:* item 5 requires a regression test for this exact behaviour, and the branch itself is
   unreachable from a test — `tokenService` is a `let` with no injection point, so the branch body
   only runs when a live `/meetings/:id/start` answers. The named method is the closest reachable
   seam, and it is the shipping code path, not a test-only duplicate. The assignment is still
   unconditional and still in that branch, inside the same main-queue block as the settings
   snapshot.
2. **The resets are placed after the two connect guards rather than literally at line 1 of each
   entry point.** *Reason:* a `connect` refused because one is already in progress must not clear
   the consent of the session that is running. `testRejectedDoubleConnect_doesNotClearALiveSessionsConsent`
   locks this in.
3. **Item 3 was decided in the negative** (no teardown clearing), with the evidence in §3 above.
   The prescription allowed this ("add teardown clearing only if it does not risk clobbering a live
   session's state"); it does risk exactly that, because `-teardownActiveWindows` runs mid-`-enterMode:`.

Nothing else differs. Two things were deliberately **left alone** as outside this fix, and are
recorded here so they are not mistaken for oversights:

* The `/room/create` branch assigns three of the eight presence fields (`armed`, `RegionEU`,
  `Under18`) and leaves `retentionDays`, `multipleFacesEnabled`, `detectorVersion`, `thresholds` and
  `rightsContact` at whatever a previous room left. Those five are informational, they are shown
  only to a candidate, and the creating interviewer is not the candidate; `armed` — the only one any
  guard reads — is assigned. Changing it was not part of the prescribed fix.
* `AppDelegate.m:4878` calls `applyMeetingSettingsFromDict` under an `if (settings.count > 0)` guard
  at `:4877`. That guard is always true on this path (the caller at `:4829` passes the whole
  `/room/lobby-status` JSON as `settings:`, and it always carries `status` and `token`), so the
  arming block is always assigned on path 4. Making the call unconditional would have changed the
  behaviour of every other meeting setting, not just presence, for no reachable gain.
