# converge-review-3.md — pass 3: verifying the per-connection isolation fix

**Verdict: APPROVED** (judged against "safe to merge and evaluate behind a default-off flag").

**Scope.** Pass 3 verifies one thing: that the single pass-2 blocker — per-connection presence state
on an app-lifetime `InterRoomController`, plus a scheduled connect path that assigned none of it —
is actually fixed, that the fix introduced nothing new, and that the hard constraints and
removability still hold. The parts of the feature approved in passes 1 and 2 were not re-litigated.

**No `git` command was run** — not `status`, not `diff`, nothing. I modified no production code. All
my scratch output went to `/tmp`.

---

## 1. What I read

| File | Why |
|---|---|
| `.agents/tasks/presence-monitoring/fix-notes-pass3.md` | The coder's note: files touched, decisions, commands, results |
| `.agents/tasks/presence-monitoring/review.json` | The pass-2 blocker and its prescribed fix (overwritten at the end of this pass) |
| `.agents/tasks/presence-monitoring/converge-review-2.md` | The pass-2 narrative, including its "coverage gaps noted, not filed" paragraph |
| `.agents/tasks/presence-monitoring/plan.md` | D0.1, the invariant that was violated |
| `inter/Networking/InterRoomController.swift` | The fix itself: `:251`–`:345` property block and the three methods, `:360` dict mirrors, `:485` / `:678` the two entry-point resets, `:518` the scheduled call, `:577` create branch, `:625` join branch, `:696`–`:772` `handleTokenResponse` |
| `interTests/InterPresenceSessionIsolationTests.swift` | All 252 lines of the new regression suite |
| `docs/.../2026-10-31-interview-presence-monitoring-design.md` §2.2 + §2.2.1 | The corrected claim |
| `.agents/tasks/presence-monitoring/REMOVAL.md` §1–§4 | Whether it still matches the files touched |
| `inter/App/AppDelegate.m` `:369`, `:730`–`:742`, `:822`, `:841`, `:2466`–`:2572`, `:4825`–`:4900`, `:6744`–`:6750` | The unchanged readers and guards, and the teardown-call-site claim |
| `inter/UI/Controllers/SecureWindowController.m` `:607`–`:612` | The detector start site, the consumer consequence (A) runs through |
| `inter/Networking/InterTokenService.swift` `:27`–`:65`, `:982`, `:1077`, `:2564` | Which parser populates `presenceMonitoringArmed`, and which does not |
| `token-server/scheduling.js` `:638`–`:860` | What `/meetings/:id/start` actually returns |
| `token-server/presenceConfig.js` `:55`–`:70`, `test/presenceEvents.test.js`, `test/presenceGate.test.js` | `multiple_faces` default and forbidden-key coverage |
| `interTests/InterRoomControllerTests.swift` `:1`–`:104`, `interTests/SecureTools/SecureToolsNetworkAuditTests.swift` | Diagnosing the two client-test failures I observed |

---

## 2. What I ran, and what I observed

| Gate | Command | What I observed |
|---|---|---|
| Client build (independent) | `xcodebuild build -project inter.xcodeproj -scheme inter -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/pass3-dd` | `** BUILD SUCCEEDED **`, exit 0, **`grep -c "error:"` = 0**, 693 Swift compile actions, 72 `warning:` lines |
| Client tests — targeted (13 classes, 198 cases) | the 13 `-only-testing:` classes from fix-notes §6, run **four times** | Runs 2, 3, 4: `** TEST SUCCEEDED **`. Run 1: **196 passed / 2 failed** — diagnosed below as a pre-existing load-dependent flake. **All five new tests passed in all four runs** |
| Client tests — isolation controls | `-only-testing:interTests/InterRoomControllerTests` alone; then the same 12 classes **without** the new test file | `** TEST SUCCEEDED **` both |
| Token server | `cd token-server && npm test` | `tests 162 / suites 17 / pass 159 / fail 0 / cancelled 0 / skipped 3 / todo 0 / duration_ms 15088`, exit 0 — the recorded totals exactly |
| The three presence files, LiveKit up | `node --test test/presenceGate.test.js test/presenceEvents.test.js test/presenceRetention.test.js` with `livekit-server --dev` running | `tests 82 / suites 12 / pass 82 / fail 0 / cancelled 0 / **skipped 0** / todo 0` — the 3 arming subtests that skip without LiveKit ran for real |
| Removability greps (re-measured, not read) | `grep -rl 'PRESENCE MONITORING' inter token-server interTests` and the two narrower forms | **38 / 37 / 15** — exactly the counts REMOVAL.md §3.1 documents. All 22 files in §2 exist |

My first build run, against the user's existing derived data, was up to date and compiled nothing
(`grep -cE "SwiftCompile|CompileSwiftSources|Ld "` = 0), so the `BUILD SUCCEEDED` it printed was
vacuous. I re-ran into a scratch derived-data path to get a real compile; that is the row above.

**None of the 72 warnings is at a line this change added.** The seven in
`InterRoomController.swift` are at `:55`, `:60`, `:855`, `:1291`, `:1344` (pre-existing Swift 6
`Sendable`, non-exhaustive `switch`, always-succeeding cast); the new hunks are at `:251`–`:345`,
`:482`–`:485`, `:512`–`:518`, `:674`–`:678`. The new test file emits none. My count differs from
the coder's 24 because a cold build into fresh derived data also emits the LiveKit / SwiftProtobuf
package warnings.

### The flag-off and no-leak measurements

The `82 / 82 / 0 skipped` run is the live proof, because the three subtests that normally skip are
exactly the ones that matter here:

* **Flag OFF** — a `hiring` host's `POST /room/create` with `roomType:'interview',
  presenceMonitoring:true` succeeds and `redis.hgetall(room:{CODE})` carries **no key starting
  `presence`**, and the subsequent `/room/join` response carries none either
  (`presenceGate.test.js:197`–`:230`). Every `/presence/*` path answers `404 PRESENCE_DISABLED`.
* **Flag ON, unarmed room** — a `pro`-hosted room and a `call`-type room each leave
  `presenceMonitoringArmed` undefined in the hash; a `hiring` interview room arms, and
  `candidateRegionEU` / `candidateUnder18` each force it off (`:290`–`:325`).
* **Flag ON, scheduled room** — read directly out of `token-server/scheduling.js`: the
  `/meetings/:id/start` response literal at `:839` has **seven named top-level keys** (`roomCode`,
  `roomName`, `token`, `serverURL`, `roomType`, `isHost`, `roomSettings`) and a `roomSettings`
  object with **ten named keys**, with no spread anywhere, and `grep -ci presence scheduling.js` is
  **1** — a comment at `:898` about LiveKit *participant* presence. That endpoint also never calls
  `resolvePresenceArming`, so the scheduled room's hash carries no presence field. It is
  structurally incapable of emitting a presence key.

The client half of the new property is the new test suite (§5 below).

### The two client-test failures I observed, and why they are not this change

Run 1 of the targeted set failed. The messages, read out of the `.xcresult` with
`xcrun xcresulttool get test-results summary`:

* `InterRoomControllerTests/testDisconnect_clearsRoomCode()` —
  `Asynchronous wait failed: Exceeded timeout of 2 seconds, with unfulfilled expectations: "wait".`
* `InterRoomControllerTests/testDoubleConnect_whenAlreadyConnecting_returnsError()` —
  `Crash: inter at Swift runtime failure: Unexpectedly found nil while implicitly unwrapping an
  Optional value.`

**Mechanism, pre-existing.** `testDisconnect_clearsRoomCode`
(`InterRoomControllerTests.swift:90`–`:104`) schedules a `DispatchQueue.main.asyncAfter(+0.5 s)`
block that dereferences `self.controller`, and waits only 2 s. `controller` is declared
`var controller: InterRoomController!` (`:8`) and `tearDown` sets it to `nil` (`:15`). When the 0.5 s
deadline is missed under parallel-worker CPU contention, the test fails on the 2 s wait, `tearDown`
nils the implicitly-unwrapped optional, and the still-pending block then dereferences nil and
crashes the runner process — so the crash is attributed to whichever case was executing at that
moment, here `testDoubleConnect`. The 3.402 s runtime on a test whose own ceiling is 2 s is the
fingerprint.

**Evidence it is not caused by the fix**, in increasing strength: `InterRoomControllerTests` alone
passes; the same 12 classes **without** the new test file pass; the full 13-class set passed **3 of
3** re-runs; and all five new tests passed in all four runs. One failure in four runs of a set whose
only new member is a passing test class is flakiness in a fragile pre-existing test, not a
regression. The fragility (hard 2 s ceiling on a timing-sensitive block, plus IUO dereference from a
block that outlives `tearDown`) is pre-existing and out of scope for this pass.

### The full-suite baseline delta

I did not re-run the full client suite; the coder recorded `782 passed / 6 failed`. The recorded
baseline is 4, so I spot-checked the delta rather than accept it. The two extra failures are
`SecureToolsNetworkAuditTests.testSecureToolsSourcesImportNoNetworkingModules` and
`SecureToolsWindowAuditTests.testSecureToolsSourcesContainNoWindowSpawningAPIs`, both in
`interTests/SecureTools/`. They resolve `<repo>/inter/UI/SwiftUI/SecureTools` from `#filePath` and
`FileManager.enumerator` it. That directory holds **12** `.swift` files on disk (I counted), and a
grep over them for 13 of the 16 forbidden networking tokens (`import Network`, `URLSession`,
`URLRequest`, `URL(string:`, `NWConnection`, `CFSocket`, `getaddrinfo`, `NSURLConnection`,
`import LiveKit`, `WebSocket`, `dataTask`, `downloadTask`, `uploadTask`) returns **no file**, so the
property the tests exist to protect genuinely holds and the failure is the sandboxed test runner
being unable to enumerate `~/Documents` (the app sandbox grants only
`files.user-selected.read-write`). Neither test reads any file this change touched, so they are
structurally incapable of being affected by it.

Recommend correcting the recorded baseline to **6 on this machine** (or granting the test runner
Documents access) so the next reviewer is not sent after the same two. That is records hygiene, not
a merge blocker, and not a finding.

---

## 3. The five prescribed-fix items, judged one by one

### Item 1 — reset at the top of both public entry points, not in `handleTokenResponse`: **DONE**

`resetPresenceConsentForNewConnection()` (`InterRoomController.swift:319`) sets
`activePresenceMonitoringGranted = false` and `activePresenceConsentState = "pending"`, and is
called at `:485` in `connect(configuration:completion:)` and `:678` in
`connect(withToken:serverURL:configuration:completion:)`.

**The ordering constraint is respected, read from the code rather than taken on trust.**
`handleTokenResponse` spans `:696`–`:772`. Every occurrence of `activePresence`,
`resetPresenceConsentForNewConnection` or `applyPresenceSettingsFromScheduledMeeting` in the file is
at one of lines 256–370, 485, 518, 577–580, 625–632, 678 — **none between 679 and 772**. So nothing
presence-related is inside `handleTokenResponse`, and the main-queue hop that would have landed
after the join branch's assignment and clobbered the server's answer does not exist.

Both resets are synchronous on the caller's queue, in the same place `isConnecting = true` and
`self.configuration = …` are already assigned, and both sit **after** the state and double-connect
guards — so a refused `connect` cannot void a live session's consent. That placement is the right
call and is pinned by test 3.

### Item 2 — the scheduled branch assigns the presence block: **DONE**

`applyPresenceSettingsFromScheduledMeeting(_:)` (`:331`) assigns all eight fields — `armed` from
`response.presenceMonitoringArmed`, the other seven to the shipped defaults — and the scheduled
branch calls it at `:518`, unconditionally, inside the same `DispatchQueue.main.async` block as the
settings snapshot, under the same `if let self = self, let r = response, error == nil` the branch
already had. With a response that carries no presence key this reduces to `armed == false`, which is
the correct answer for a path the server never arms.

The deviation (a named method rather than an inline block) is **accepted**. The stated reason holds:
`tokenService` is a `let` at `:105` with no injection point, so the branch body only runs when a
live `/meetings/:id/start` answers, and item 5 required a test for this exact behaviour. The method
is shipping code called from that branch, not a test-only duplicate, and the assignment is still
unconditional and still in the branch.

One accuracy note, **not a blocker**. Both the test's doc comment and fix-notes §5 say the scheduled
assignment "is the server's answer … so if that endpoint ever starts arming rooms the client follows
it". `applyPresenceSettingsFromScheduledMeeting` does read `response.presenceMonitoringArmed`, but
`startScheduledMeeting` (`InterTokenService.swift:2564`) never parses that key from JSON — only
`createRoom` (`:1049`) and `joinRoom` (`:1184`) do — so a future server that armed on that endpoint
would still arrive as `false` until the parser is extended. The behaviour is in the safe direction
and the design note's own §2.2.1 row states it correctly ("returns no key beginning `presence`, so
this resolves to `armed == false`"); only the two prose claims overstate.

### Item 3 — teardown clearing: **DECIDED AGAINST, and the decision is sound**

The coder declined, and the load-bearing fact checks out. `-stopPresenceSurfaces` is called from
`-teardownActiveWindows` (`AppDelegate.m:6747`, the first statement in it), and
`-teardownActiveWindows` is called at `:736` **inside `-enterMode:`** — not only on exit paths. The
pre-existing comment at `:730`–`:735` documents exactly that hazard for a neighbouring field:
`pendingMeetingSettings` has to be saved into a local before the teardown call and restored at
`:737` because the rest of the same `-enterMode:` pass still needs it. The three sites that read
presence state (`:822` candidate POST + chip, `:841` interviewer surface + poll,
`SecureWindowController.m:612` the detector) all run later in that same pass. Clearing `granted` or
`armed` at `:736` would therefore switch the feature off for every session, including a properly
armed room with a consenting candidate.

So teardown clearing is not defence in depth here, it is a regression, and declining it is correct.
The invariant is carried instead by the two mechanisms that cannot be reached mid-setup: a
synchronous reset at the connect entry points, and an unconditional per-path assignment of the
arming block. The decision was stated with its reason, which is what item 3 asked for.

### Item 4 — §2.2 of the design note: **DONE, and the four paths are correct**

The false sentence is gone. New §2.2.1 opens by stating plainly that the earlier claim was wrong on
two counts (four paths not two; the scheduled path assigned no presence field, so arming did leak),
and adds that consent leaked on every path because nothing cleared it between sessions.

I checked each row of its four-path table against the code:

1. `/room/create` — create branch at `:577`, `armed` from `response?.presenceMonitoringArmed ?? false`
   (the server's answer, never the host's request), `RegionEU` / `Under18` from local config. ✓
2. `/room/join` — join branch at `:625`, all eight fields from the typed response, omitted block ⇒
   `armed == false`. ✓
3. `/meetings/:id/start` — `applyPresenceSettingsFromScheduledMeeting(_:)` at `:518`. ✓
4. Lobby-admitted — `applyMeetingSettingsFromDict(_:)` (`:347`), called from `AppDelegate.m:4878`
   **before** `connectWithToken` at `:4894`. ✓

And there is no fifth path: `connectWithConfiguration` has exactly three call sites
(`AppDelegate.m:1303`, `:2127`, `:2211`), `connectWithToken` exactly one (`:4894`), and nothing
inside `InterRoomController` calls `connect` again for a reconnect. §2.2's guard table was also
updated correctly — site 4's note now says `granted` is cleared by
`resetPresenceConsentForNewConnection()` on every new connection.

The `settings.count > 0` guard at `AppDelegate.m:4877` that path 4 depends on is always true: the
caller passes the whole `/room/lobby-status` JSON as `settings:`, and the admitted branch is only
reached when that JSON carries `status` and `token`.

### Item 5 — regression tests: **DONE, with the seam limitation stated rather than skipped**

Five tests in `interTests/InterPresenceSessionIsolationTests.swift`, all passing in every run of mine
that included them (four runs):

| Test | Required property it pins |
|---|---|
| `…_lobbyAdmittedPath` | Consent does not survive into the next connect, asserted **from inside the pre-connect consent gate** — the exact observer whose ordering matters, and the one a main-queue-hop reset would get wrong |
| `…_tokenFetchPath` | Same for the other entry point, asserted **synchronously** after `connect` returns, so no later hop can satisfy it |
| `testRejectedDoubleConnect_doesNotClearALiveSessionsConsent` | The guard placement — the regression a naive "reset at line 1" would introduce |
| `testScheduledMeetingResponse_disarmsARoomArmedEarlierInTheSameAppSession` | The item-2 property: armed earlier in the app session, then a scheduled response with **no** presence key ⇒ `armed == false` and all seven other fields back at shipped defaults |
| `testScheduledMeetingResponse_carriesAnArmedServerAnswer` | The assignment is the response value, not a hardcoded constant |

Item 5's escape clause is satisfied properly: the seam limitation is stated **twice** (file header
and fix-notes §5/§8) with the mechanism — `tokenService` is a `let` with no injection point, so the
scheduled branch body only executes when a live `/meetings/:id/start` answers — and the closest
reachable seam (the shipping function the branch calls, which nothing else calls) is tested rather
than the branch silently skipped.

---

## 4. Hard constraints — all intact

* **No aggregate score / index / percentage / rating / risk level, no candidate-to-candidate
  comparison.** `grep -niE "\bscore\b|\brating\b|\brisk\b|percentile|aggregate|\bindex\b"` over
  `InterRoomController.swift` and the new test file returns **nothing**. The change assigns booleans,
  one `Int` retention window and empty strings. Nothing reads a second candidate's state — the
  controller holds one room at a time, which is the point of the fix.
* **No emotion / affect / engagement / attention / confidence / honesty / personality inference** in
  code, column names, API fields, log strings, comments or UI copy.
  `grep -niE "emotion|affect|engagement|attention|personality|honest|confidence|cheat|proctor"` over
  both changed client files returns nothing. No UI copy was changed at all.
* **No gaze or iris tracking, no head pose, no room scan, no blink / eye-aspect-ratio, no
  virtual-camera detection, no audio signals, no server-side frame analysis, no frame / crop /
  landmark retention.** `grep -niE "gaze|iris|\byaw\b|\bpitch\b|\broll\b|blink|landmark|virtual.?camera|room.?scan|aspect.?ratio"`
  over both files returns one hit: `promotion/demotion` at `InterRoomController.swift:1396`,
  pre-existing role vocabulary matched as a substring of "demotion", not an inference. No detector,
  Vision or capture file was touched. The fix strictly **reduces** the number of sessions in which
  any frame is analysed.
* **No automated action of any kind.** No new call site, no new server request, no new UI affordance;
  the change clears two properties and assigns eight.
* **The ingest endpoint still rejects any forbidden key with 400, still test-covered.**
  `presenceEvents.js` and its tests are untouched: 16 assertion sites naming
  `PRESENCE_FORBIDDEN_FIELD` in `test/presenceEvents.test.js` (per key, at the top level, nested,
  inside an array element, across spellings) plus the live assertion at `presenceGate.test.js:576`.
  Green in both my runs (162 / 0 fail and 82 / 82).
* **`multiple_faces` stays default-OFF with the false-positive-study prerequisite documented.**
  `presenceConfig.js:60` is still a strict `=== 'true'` and the prerequisite comment at `:55`–`:59`
  (≥ 20 sessions, varied lighting / rooms / webcams / skin tones, per-session FP rate under 5 %) is
  intact. The new scheduled assignment sets `activePresenceMultipleFacesEnabled = false`, the
  default-off direction.
* **Still cleanly removable, and REMOVAL.md matches the files touched.** I re-measured the three
  marker greps myself: **38 / 37 / 15**, exactly as §3.1 documents, and all 22 files in §2 exist. The
  new test file is listed under §2 "Client — tests (4)". The §3.3 `InterRoomController.swift` row now
  reads 7 hunks, and every anchor it names matches the tree I read (`:251`, `:319`, `:331`, `:360`,
  `:482`, `:512`, `:571`, `:619`, `:674`). Every hunk this change added opens with the
  `PRESENCE MONITORING` marker, so the removal grep finds all of them. No server file, migration or
  `.env` key was added, so §3.2, §4 and §6 needed no change.

---

## 5. Are consequences (A) and (B) now unreachable?

**(A) stale consent starting the detector in a session nobody was asked about — unreachable.**
The detector's single start site, `SecureWindowController.m:612`, reads
`activePresenceMonitoringGranted`. That property has exactly three writers:
`recordPresenceConsent(granted:state:)` (`:290`), called only from `AppDelegate.m:2509` — the
consent screen's decision handler — and `:2562` — the server's authoritative confirmation inside
`-startCandidatePresenceSurface`; and the new reset. Every session is preceded by a connect through
one of the two public entry points (four call sites, no internal reconnect), and both now reset the
pair synchronously before the pre-connect consent gate runs. So `granted` can only be true in a
session where **this** candidate answered **this** session's consent screen, and that screen renders
only when `armed` is true (`AppDelegate.m:369`). A grant from interview 1 can no longer start Vision
analysis or push indicator 1 "Presence monitoring on" in an unarmed interview 2, and the flag-off
variant of (A) — sampling continuing for a whole interview against a 404 server while the chip
claims "on" — goes with it, because the detector never starts.

**(B) stale arming leaking into a scheduled interview — unreachable, on both sides.** Server side,
`/meetings/:id/start` cannot emit a presence key (§2 above) and never arms the room, so the scheduled
room's hash carries no presence field either. Client side, the scheduled branch now assigns the block
unconditionally at `:518`, and
`testScheduledMeetingResponse_disarmsARoomArmedEarlierInTheSameAppSession` proves a room armed
earlier in the same app session is disarmed by a scheduled response that carries no presence key. So
the candidate no longer gets the consent screen and the interviewer no longer gets the chip plus the
15 s poll for a room the server never armed. Plan **D0.1** now holds on all four paths.

**Nothing the fix newly broke, as far as I can establish.** Flag-off zero impact is preserved: the
reset writes two properties to the values they already hold when the flag is off, and **no KVO
observer is registered on any `activePresence*` key** — the only `addObserver:forKeyPath:`
registrations on the room controller are `connectionState`, `participantPresenceState`,
`activeSpeakerIdentity` and `remoteParticipantCount` (`InterMediaWiringController.m:1042`–`:1051`) —
so the reset is observationally inert. With the flag off `armed` is false and `granted` was already
false, so no consumer changes behaviour.

**Residual, non-blocking, already noted in pass 2 §7.** The create branch's assignment sits inside
`if … error == nil`, so a *failed* `/room/create` leaves the previous room's `armed` value in place.
This is not reachable harm: on the error path `handleTokenResponse` returns before the consent gate,
no session is entered, and every path that does enter a session (create success, join, scheduled,
lobby-admitted) assigns `armed` first. Likewise the create branch still leaves five of the eight
informational fields (`retentionDays`, `multipleFacesEnabled`, `detectorVersion`, `thresholds`,
`rightsContact`) at whatever a previous room left; those are rendered only to a candidate, the
creating interviewer is not the candidate, and any path that makes this client a candidate assigns
all eight. Recorded, not filed.

**Previously recorded, unchanged by this diff, and not reopened:** REMOVAL.md §1's documented edge
that a room armed while the flag was on keeps emitting the presence block until its 24 h Redis TTL
expires. In that window a candidate who consents gets the detector while `POST /presence/consent`
answers 404 and the chip falls back to "off". That candidate *was* asked and *did* consent, so it is
not consequence (A); it is the operator-created TTL window that passes 1 and 2 reviewed and
documented.

---

## 6. Processes and data

* `livekit-server --dev` — **started, and stopped**: `pkill -f "livekit-server --dev"`,
  `pgrep livekit-server` empty afterwards, no listener on port 7880.
* **No token server was started** on port 3000 or anywhere else, so the client suite's recorded
  4-failure baseline was not perturbed. My token-server runs bind ephemeral ports via
  `app.listen(0)` through the existing test harness.
* I created no database row, ran no migration, and dropped, reset, truncated or altered nothing in
  `inter_dev`. Postgres and Redis were left as found.
* My own build output went to `/tmp/pass3-dd`, so the user's derived data was not disturbed. All logs
  are under `/tmp/pass3-*`.
* No `git` command was run. I modified no production code. The only files I wrote in the repo are
  this narrative and `review.json`.

---

## 7. Blockers before production — carried forward

These were deliberately deferred by the user and are **not** merge blockers. They remain recorded
here and in design note §10 / §3.4 / §7.1 / §13, and they block enabling
`PRESENCE_MONITORING_ENABLED` for real candidates:

1. **Published candidate-facing transparency page** — the consent copy points at a page that does
   not exist yet.
2. **Candidate copy / delete (DSAR) endpoint** — `PRESENCE_RIGHTS_CONTACT` is an email address, not
   a mechanism. Retention and purge are built; subject access is not.
3. **The `multiple_faces` false-positive study** — ≥ 20 sessions, varied lighting, rooms, webcams
   and skin tones, per-session FP rate under 5 % for that event type. This is also the keep-or-delete
   decision for the whole feature, which is why it is default-OFF.
4. **Resource and battery measurement** of the on-device detector under a real interview load.
5. **Legal review of the four named §3.4 questions**, including the EU AI Act Art. 5(1)(f) posture
   this product carries as provider, before any non-EU rollout. EU-resident and under-18 candidates
   are already forced off server-side.
6. **Threshold ownership** — design note §13 still has no named owner for the §6.1 values.

---

## 8. Conclusion

The pass-2 blocker is fixed, by the prescribed mechanism, with the ordering constraint respected and
verified in the code rather than assumed. Both of its consequences are unreachable. The four connect
paths are now enumerated correctly and each assigns the arming block from the server's own answer;
the consent pair is cleared once, synchronously, at the only two entry points. Item 3 was declined
with a reason that checks out against the tree. The regression suite covers both required properties
and states its one seam limitation instead of hiding it. REMOVAL.md and the design note match the
tree as it now stands, down to grep counts I re-measured. The hard constraints are untouched, and the
one client-test failure I observed is a pre-existing flake I reproduced zero times in three further
runs of the same set.

No merge blockers remain. **APPROVED** for merge and evaluation behind the default-off flag, with the
seven production prerequisites above still outstanding.
