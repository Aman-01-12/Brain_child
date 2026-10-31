# Re-review — candidate presence monitoring, pass 2 (fixes to the two pass-1 blockers)

**Reviewer:** converge gate, iteration 2. The record of pass 1 is `converge-review.md`; it is not
modified by this file.
**Scope:** the two blockers recorded in `review.json` (now superseded), the files the fixes touched,
the flag-off guarantee, and the still-binding hard constraints. Settled areas from pass 1 were not
re-litigated except where the fix could have disturbed them.
**No git command was run.** Nothing in the working tree was modified by this review; the one
throwaway probe script was written to `/tmp`.

**Verdict: CHANGES_REQUESTED — 1 blocker.** Both pass-1 blockers are genuinely fixed. A third
defect, of the same family as pass-1 blocker 1 and not introduced by the fix, is reachable once the
master flag is enabled: per-room presence state lives on the app-lifetime `InterRoomController` and
is never reset per connection, and one of the four client connect paths assigns none of it.

---

## 1. Pass-1 blocker 1 — interviewer surface gated on a client-held flag. FIXED.

**The deleted properties are gone from the code.** `activePresenceSurfaceVisible` and
`activePresenceMonitoringRequested` appear in zero `.swift`, `.m`, `.h`, `.js`, `.sql` or
`.pbxproj` file. The only surviving mentions are the task artifacts that record pass 1
(`features/FEAT-001..004.json`, `review.json`), which are history, not code.

**Every consumer of the interviewer surface now reads the server-derived flag, and there is still
exactly one call site.** `AppDelegate.m:839-843`:

```objc
if (mode == InterCallModeInterview
    && role == InterInterviewRoleInterviewer
    && self.roomController.activePresenceMonitoringArmed) {
    [self startInterviewerPresenceSurface];
}
```

`-startInterviewerPresenceSurface` (`:2567-2604`) is the sole owner of all three things the prior
review named: the control-bar chip (`setPresenceAvailable:YES` at `:2571`), the timeline panel
handlers (`:2578-2600`), and the 15 s poll (`[NSTimer scheduledTimerWithTimeInterval:15.0 …]` at
`:2596`, plus one immediate `pollPresenceTimeline` at `:2603`). Nothing else calls it, so with
`activePresenceMonitoringArmed` false none of the three can start. The candidate-side guard
(`:822`) and the consent-gate guard (`:369`) read the same property, and the detector guard
(`SecureWindowController.m:612`) reads `activePresenceMonitoringGranted`, as before.

**The server echo is real, and byte-clean when it is not armed.** `token-server/index.js:2613-2615`
builds `const presenceBlock = presenceArming.armed ? { presenceMonitoringArmed: true } : {}` from
the single `resolvePresenceArming()` result computed at `:2529-2536`, and spreads it once at
`:2627`. Client side, `InterTokenService.swift:1049` parses
`json["presenceMonitoringArmed"] as? Bool ?? false`, and `InterRoomController.swift:520-523`
assigns it unconditionally on the create path.

Measured live rather than assumed (hiring host, `roomType: 'interview'`,
`presenceMonitoring: true`, dev Postgres + Redis + `livekit-server --dev`):

| Configuration | `/room/create` response | presence keys |
|---|---|---|
| flag unset | 8 keys: `leaveToken, maxParticipants, participantCount, roomCode, roomName, roomType, serverURL, token` | `[]` |
| flag unset, room hash | 18 fields | `[]` |
| flag unset, `/room/join` | 20 keys | `[]` |
| `PRESENCE_MONITORING_ENABLED=true`, requested | 9 keys | `["presenceMonitoringArmed"]`, value `true` |
| flag on, `presenceMonitoring: false` | — | `[]` |
| flag on, requested, `candidateRegionEU: true` | — | `[]` |

So the echo carries the server's resolved answer and never the host's request, and a flag-off
response is byte-identical to a pre-feature one.

**The specific leak the prior review named is closed.** `activePresenceMonitoringRequested` no
longer exists, and on the two paths the fix covers the arming flag is assigned unconditionally from
the server (`InterRoomController.swift:522` create, `:570` join, `:319` lobby-admitted). It is *not*
structurally impossible on the fourth path — see §4.

## 2. Pass-1 blocker 2 — the green-room caption asserted a consent prompt. FIXED.

`GreenRoomViewModel.swift:130-143` is now a pure static function with three branches, all three of
which I read against the shipped default:

* **monitoring off** — "Nothing about what the candidate's camera sees will be recorded." True of
  the presence feature in every configuration.
* **EU or under-18** — "Monitoring stays off for this candidate by policy, and they are not offered
  it. You can still run the interview normally." Matches the server, which vetoes both before any
  room field is written (`presenceConfig.js:169-170`, reasons `eu_region` / `under_18`), and matches
  the client's pure `PresenceConsentViewModel.mode(armed:regionEU:under18:)`.
* **monitoring on, neither policy flag** — "This is a request for this room, not a guarantee.
  Nothing is recorded unless the candidate agrees, and they can join with monitoring off. No
  decision is automated."

The third branch no longer states that the candidate will be asked. With the flag off every clause
still holds: the request is not granted, nothing is recorded, the candidate joins under the
untouched `-showIntervieweeConfirmationWithCompletion:` alert, and no decision is automated.

`showsPresenceControls` is still `role == .hostInterview` (`:117`). That is an accepted trade-off,
recorded in the design note §2.3 and `REMOVAL.md` §1 with its reason (the green room renders before
the room exists), and the first caption clause now tells the interviewer exactly that. The checkbox
with the flag off is therefore honest rather than misleading, which is what this blocker asked for.

## 3. Did the fixes break or weaken anything? No.

* No orphan left by the deletion: no file references the removed properties, no comment still
  describes a "surface visible" or "requested" flag, and the build produces no new warning. The one
  `warning:` line is the pre-existing `Info.plist in Copy Bundle Resources` project warning.
* The candidate path is unchanged from what pass 1 approved: the consent gate at `:369`, the legacy
  alert fallback inside `-showPresenceConsentWithCompletion:` when `presentableMode == 0`, the
  single detector guard, and the coordinator as sole chip writer while monitoring runs.
* Docs match the code. The design note's §2.2 guard table checks out line by line: site 1 marker
  `AppDelegate.m:365` / `if` at `:369`; site 2 `:814` / `:822`; site 3 `:833` / `:839`-`:841`;
  site 4 `SecureWindowController.m:607` / `:612`; unconditional sites `AppDelegate.m:2114`,
  `:6745`, `SecureWindowController.m:399`. Four `if` guards plus three unconditional blocks, as
  claimed. `REMOVAL.md`'s marker-grep counts are exact: `'PRESENCE MONITORING'` 37 files,
  `'PRESENCE MONITORING (provisional'` 36, `'PRESENCE MONITORING (provisional)'` 15. §2.3 and
  `REMOVAL.md` §1 describe what the flag does *not* switch off correctly, including the
  create-path echo.
* One doc claim is now wrong in the opposite direction, and it is the subject of §4: design note
  §2.2 says "the property is assigned unconditionally on both paths, so a room armed earlier in the
  same app session cannot leak its state into the next room". There are four client connect paths,
  not two.

## 4. Blocker — per-session presence state is never reset, and the scheduled path assigns none of it

**Files:** `inter/Networking/InterRoomController.swift` (writers at `:291-292`, `:319`, `:522`,
`:570`; scheduled branch `:445-492` writes none), consumed at
`inter/UI/Controllers/SecureWindowController.m:612` and `inter/App/AppDelegate.m:369`, `:841`.

`InterRoomController` is created once (`AppDelegate.m:289`) and released only in
`applicationWillTerminate` (`:426`, nil at `:475`). Nothing on session exit clears the presence
block: `-stopPresenceSurfaces` (`:2607-2613`) invalidates the timer and handlers,
`-destroySecureWindow` stops and nils the coordinator (`SecureWindowController.m:403-404`), and
neither touches `activePresenceMonitoringGranted`, `activePresenceConsentState` or
`activePresenceMonitoringArmed`. `recordPresenceConsent` (`:289-296`) is the only writer of the
consent pair, and it is called only from the candidate's consent screen (`AppDelegate.m:2509`) and
that screen's POST completion (`:2562`).

**Path A — the detector runs in a later interview nobody consented to.** Flag on. The candidate's
app grants consent in interview 1, so `activePresenceMonitoringGranted` is true. The interview
ends; the app stays open. The candidate joins interview 2, which is *not* armed (the interviewer did
not tick the box, or declared the candidate EU-resident, or the operator turned the flag off). Then:
`AppDelegate.m:369` is false, so the candidate sees the untouched legacy alert and is **never
asked**; `:822` is false, so no consent POST and no chip from the AppDelegate; but
`createSecureWindow` → `-startLocalMediaFlow` (`SecureWindowController.m:142`, `:552`) runs again
for the new session, and `:612` reads the stale `granted == true` and starts
`InterPresenceCoordinator`. The coordinator adds its capture output, Vision analyses frames, and
`start` pushes indicator `1` ("Presence monitoring on", `InterPresenceCoordinator.swift:163-166`)
for a session with no server-side consent, session row or audit row. The first upload is one flush
interval later (`InterPresenceReporter.swift:43`, 15 s). Only HTTP 403 and 409 stop reporting
(`:139`), so an unarmed room on a flag-on server self-stops after ~15 s, while a **flag-off** server
answers `404 PRESENCE_DISABLED` and sampling continues, with the chip claiming "on", for the whole
interview.

**Path B — the stale arming flag reaches a scheduled interview.** `/meetings/:id/start`
(`token-server/scheduling.js:638-860`) never arms a room and returns no key beginning `presence`,
and the client's scheduled branch (`InterRoomController.swift:445-492`) assigns no presence field at
all, so a true `activePresenceMonitoringArmed` from an earlier room in the same app session
survives into it. Scheduled interviews are a shipped flow (`room_type` CHECK allows `interview` in
migrations 001 and 015; `ScheduleViewModel.roomType`; `scheduling.js:833-834` issues the
`interviewee` / `interviewer` roles), and the gate runs on this path like every other
(`handleTokenResponse` → `:690`). The candidate therefore gets the presence consent screen, and the
interviewer gets the chip and the 15 s poll, for a room the server never armed — the exact symptom
pass-1 blocker 1 described, reached through the path the fix did not cover.

**What this does not break.** The flag-off guarantee for a server that never had the flag on is
intact: `granted` and `armed` can only become true if some room was armed, which requires the flag.
Nothing is written to Postgres or Redis in either path (`loadArmedRoom` answers
`409 PRESENCE_MONITORING_NOT_ARMED`, `presence.js:192-196`; `requirePresenceFeature` answers
`404 PRESENCE_DISABLED`). The failure is local analysis of the candidate's camera without a consent
for that session, plus an indicator that misreports it, which is the one property this feature is
built around.

**Correction.** Treat consent and arming as per-connection facts:

1. Reset `activePresenceMonitoringGranted = false` and `activePresenceConsentState = "pending"` at
   the top of both public entry points, `connect(configuration:completion:)` (`:437`) and
   `connect(withToken:serverURL:configuration:completion:)` (`:600`). Not inside
   `handleTokenResponse`: its main-queue hop would land *after* the join branch's assignment and
   clobber the server's answer. The lobby-admitted path applies its settings dict before
   `connectWithToken` (`AppDelegate.m:4878` then `:4894`), so only the consent pair may be reset
   there, which is correct because that dict carries no consent.
2. Assign the presence block on the scheduled branch (`:445-492`) the same way the join branch does.
   `/meetings/:id/start` carries no presence keys, so this reduces to the backward-compatible
   defaults (`armed = false`), which is the right answer for a path the server never arms.

Then the design note §2.2 claim becomes true as written, and plan D0.1's "one condition" holds on
every path.

## 5. Flag-off zero impact — re-verified

Read, and exercised live against the dev stack with the flag unset:

* **No detector, no frame, no Vision request.** One `import Vision` in the client
  (`inter/Media/InterPresenceDetector.swift`), reached only through
  `SecureWindowController.m:612`, which requires `activePresenceMonitoringGranted`, which only the
  consent screen writes, which only `:369` reaches, which requires `armed`. With the flag off the
  server emits no arming key, so the chain is dead at its root. (Once the flag has been on in the
  same app session, see §4 path A.)
* **Candidate join flow is the legacy path.** `:369` false → `-showIntervieweeConfirmationWithCompletion:`,
  which pass 1 verified byte-for-byte unchanged and which I re-read at `:2404-2448`: the original
  `NSAlert`, the three secure-mode bullets, the external-display branch, Continue/Cancel.
* **No interviewer chip, panel or timer.** `:841` false; `-startInterviewerPresenceSurface` is its
  only caller.
* **No presence key in any server response, no DB row, no Redis field.** Measured: create 8 keys /
  0 presence, room hash 18 fields / 0 presence, join 20 keys / 0 presence,
  `interview_presence_sessions` count 0.
* **Ingest 404s.** `POST /presence/events` → `404 {"error":"Not found","code":"PRESENCE_DISABLED"}`.

## 6. Hard constraints — intact

* **No score, index, percentage, rating, risk level, cross-candidate comparison.** The timeline
  summary is still four keys per event type (`presence.js:596-601`); migration 023 has no numeric
  column that could hold one; the forbidden-key list refuses `score`, `index`, `percentile`, `rank`,
  `rating`, `risklevel`, `aggregate`, `total`.
* **No emotion / affect / engagement / attention / confidence / honesty / personality inference.**
  Every occurrence of those words in the tree is a refusal, a forbidden-key entry or a comment
  explaining the prohibition (`presenceEvents.js:48-63`, `InterPresenceDetector.swift:26`,
  `InterPresenceEventEngine.swift:18`). The new caption introduces none of them.
* **No gaze, iris, head pose, blink, room scan, virtual-camera detection, audio, server-side frame
  analysis, frame retention.** `grep` for `.yaw` / `.pitch` / `.roll`,
  `VNDetectFaceLandmarks`, `VNGenerateFaceCaptureQuality`, `VNGenerateImageFeaturePrint` over
  `inter/` and `interTests/` returns nothing.
* **No automated action.** Unchanged; the interviewer surface offers refresh, note, jump-to-offset
  and export only.
* **Ingest rejects forbidden keys with 400, and the tests still cover it.** `findForbiddenKey` runs
  before the allowlist and returns `400 PRESENCE_FORBIDDEN_FIELD` with the offending key;
  `test/presenceEvents.test.js` asserts it per key, at the top level, two levels deep, inside an
  array element, across spellings, and that forbidden beats unknown (11 assertion sites naming the
  code).
* **`multiple_faces` defaults OFF** — `presenceConfig.js:61` is a strict `=== 'true'`, and the
  false-positive prerequisite is stated at `:63-67` and in design note §7.1.
* **Timeline read is server-authorised** — `presence.js:653-657`: `requireAuth`, rate limiter,
  `requireModerator`, which re-reads the room, re-checks the hiring tier and calls
  `validateModerator(code, callerIdentity, req.user.userId)`, failing closed.
* **Production prerequisites are durably recorded as blockers-before-production**: design note §10
  lists the transparency page, the DSAR copy/delete endpoint, the §7 false-positive study, the
  resource measurement and the §3.4 legal review, with "Neither is optional. Both block enabling the
  flag for real candidates"; §13 keeps the threshold owner open. That satisfies the recording
  requirement.
* **Migration 023** is recorded directly after `022_rename_pro_plus_to_hiring.sql`
  (applied 2026-10-30T19:37:19Z), `schema_migrations` total 23, three `interview_presence_*` tables.

## 7. Verification I ran (actual output)

| Gate | Command | Result |
|---|---|---|
| Server suite | `cd token-server && npm test` (no LiveKit) | `tests 162 / suites 17 / pass 159 / fail 0 / cancelled 0 / skipped 3 / todo 0 / duration_ms 14138`, exit 0 |
| The three presence files, LiveKit up | `node --test test/presenceGate.test.js test/presenceEvents.test.js test/presenceRetention.test.js` with `livekit-server --dev` running | `tests 82 / pass 82 / fail 0 / skipped 0 / duration_ms 6668`, exit 0 — the 3 arming subtests that skip without LiveKit actually ran |
| Client build | `xcodebuild build -project inter.xcodeproj -scheme inter -configuration Debug -destination 'platform=macOS'` | `** BUILD SUCCEEDED **`, exit 0, `grep -c "error:"` = 0, `grep -c "warning:"` = 1 (pre-existing `Info.plist` in Copy Bundle Resources, not presence-related) |
| Flag-off / flag-on response shape | throwaway `/tmp/review2-flagoff-check.js` against the real `app`, dev Postgres, Redis and LiveKit | the table in §1, plus `404 PRESENCE_DISABLED` on ingest; "ALL CHECKS PASSED" |
| Schema | `schema_migrations` + `information_schema.tables` read | 023 after 022, total 23, 3 presence tables |

**Processes and data.** I started `livekit-server --dev` and stopped it (`pkill -f "livekit-server
--dev"`; port 7880 free afterwards). No token server was left running. The probe script created one
`hiring` test user and four rooms and removed them: 0 `meetings` rows remain for those four codes,
`interview_presence_sessions` is 0 rows, and the user was deleted. The five
`teamtest-*@test.invalid` users still in `inter_dev` all date from June 2026 and were left
untouched. No table was dropped, reset or altered. No `git` command was run.

**Coverage gaps noted, not filed as blockers.** No automated test asserts the new `/room/create`
echo in either direction (`presenceGate.test.js` asserts the join response and the room hash, not
the create response), and nothing asserts the three caption branches; I verified the echo live in
both directions instead. Design note §12's "room hash 36 fields" disagrees with §2.1 and with my
measurement of 18. The monitoring-off caption's "Nothing about what the candidate's camera sees will
be recorded" is absolute enough to be read as covering session recording, which a recording
interviewer would find untrue of the video; "No presence events are recorded for this candidate"
would be exact. The create-path assignment sits inside `if error == nil`, so a failed create leaves
the previous value — subsumed by the §4 correction.
