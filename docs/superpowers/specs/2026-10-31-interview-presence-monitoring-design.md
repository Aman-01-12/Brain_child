# Candidate Presence Monitoring for Secure Interview Mode — Design Spec

**Date:** 2026-10-31
**Project:** inter / KioMeet (macOS, Obj-C + Swift + LiveKit; Node/Express token server, Postgres + Redis)
**Feature:** During a secure interview, the candidate's own Mac records two facts about their
camera — when no face is visible to it, and when more than one face is visible — as timestamped
events with durations. The interviewer reads that timeline and decides what it means. Nothing is
scored, nothing is ranked, and nothing happens automatically.
**Status:** Built and verified behind a master flag that is OFF by default. **Provisional,
evaluation-first, and designed to be deleted.** Not approved for production use: three gates in
§10 and the legal review in §3.4 are still open.
**Builds on:** `2026-06-10-consent-first-moderation-design.md` (consent-first default, the
persistent-indicator-never-a-toast rule, the one pure derivation function as the anti-drift
device) and `2026-10-27-interview-face-verification-design.md` (human override, mandatory written
reason, additive append-only records) — **patterns only; that feature is on hold and none of its
code is touched or implemented here.**
**Grounded in:** `.agents/tasks/proctoring-research/gaze-facial-analysis-research.md` Part 7 (the
design spec this implements), `.agents/tasks/presence-monitoring/plan.md` (the implementation
plan), and the `findings` fields of `.agents/tasks/presence-monitoring/features/FEAT-001.json`
through `FEAT-003.json` (what was actually built, which is what this document describes).
**Removal recipe:** `.agents/tasks/presence-monitoring/REMOVAL.md`.

> **Format note.** Tables and fenced pseudo-code only. There is deliberately **no Mermaid** block
> in this document: no reference doc in `docs/superpowers/specs/` other than the face-verification
> spec contains one, and that spec flagged its own use as a departure. Nothing here needs it.

---

## 1. Summary

A candidate joining a secure interview room on a `hiring`-tier host's interview sees a consent
screen with two equal-weight choices: join with presence monitoring, or join with monitoring off.
Both join. If they accept, their own Mac samples its camera at 2 Hz, runs one Apple Vision
`VNDetectFaceRectanglesRequest` per sample, and derives five event types with hysteresis. Closed
events are batched over HTTPS every 15 s as `{eventType, startedAt, endedAt, durationMs}` —
strings and integers, never a pixel. The server validates them against a strict allowlist with an
explicit forbidden-key list, stores them with the thresholds that produced them, and purges them
after 90 days. A persistent chip in the candidate's window states whether monitoring is on, off,
or paused because their camera is off, for the whole session. The interviewer sees per-type counts
and durations, a timeline, a note field with a mandatory ten-character reason, and a JSON/CSV
export.

Five decisions carry the design.

1. **One master flag, OFF by default** (§2). Two server conditions read it; with it off the
   feature is not merely inert, it is invisible on the wire.
2. **No score, ever** (§4). Per-type counts and durations, and nothing above them.
3. **A detection failure is a fact about the video, never about the candidate** (§6.2). It is
   recorded as `image_quality_insufficient` and is structurally unable to become `face_absent`.
4. **Nothing is automatic** (§9). The feature offers the interviewer no action against the
   candidate at all.
5. **The false-positive study is not a formality, it is the decision** (§7). It is the measurement
   that tells the user whether to keep this feature or delete it.

---

## 2. The master flag, and exactly what OFF guarantees

### 2.1 The two server conditions

`PRESENCE_MONITORING_ENABLED` (default `false`, read from `process.env` **at call time** so a
test can flip it) is consulted in exactly two places, both inside new files:

| # | Condition | File | Effect when the flag is off |
|---|---|---|---|
| 1 | `requirePresenceFeature`, the `/presence` router's first middleware | `token-server/presence.js` | Every `/presence/*` path answers `404 { error: 'Not found', code: 'PRESENCE_DISABLED' }` before any authz, DB or Redis work |
| 2 | `resolvePresenceArming({featureEnabled, …})`, a pure predicate called from `/room/create` | `token-server/presenceConfig.js` | Returns `{armed: false, reason: 'feature_disabled'}`, so **no `presence*` field is written to the room hash** |

Because no `presenceMonitoringArmed` field reaches the room hash, `/room/join` omits its whole
presence block, so the client's `activePresenceMonitoringArmed` parses `false` from its
backward-compatible default — identical to talking to a pre-feature server.

`/room/create` **echoes the same resolved answer** — one key, `presenceMonitoringArmed: true`,
emitted only when `presenceArming.armed` is true, via the same conditional-object-then-spread
shape `/room/join` uses. This is not a third reader of the flag: it re-serialises the single
`resolvePresenceArming()` result already computed a few lines above for the room hash. It exists so
the creating interviewer's client holds the **server's** answer rather than inferring one from its
own request; see §2.2 site 3.

The arming write is a **second, separate conditional `pipeline.hset()`** placed immediately after
the existing one rather than inside it. The pre-existing `hset` call is therefore byte-for-byte
unchanged, which is what makes a flag-off room hash provably identical to a pre-feature room hash.

**Measured, not asserted** (flag unset, live `node index.js`, re-measured at convergence):
`GET localhost:3000/presence/events` → `404 {"error":"Not found","code":"PRESENCE_DISABLED"}`; a
`hiring` host's interview room created with `presenceMonitoring: true` produced a
**`/room/create` response of 8 keys** (`leaveToken, maxParticipants, participantCount, roomCode,
roomName, roomType, serverURL, token`) with **zero** keys matching `presence`, a **room hash of 18
fields** with zero keys matching `presence`, and a `/room/join` response with **zero** keys
starting with `presence`; the startup log printed no presence line and the sweeper timer did not
start. With `PRESENCE_MONITORING_ENABLED=true` the same create call returned **9** keys, the ninth
being `presenceMonitoringArmed: true`; and with the flag on, `candidateRegionEU: true`,
`candidateUnder18: true` and `presenceMonitoring: false` each returned **8** keys again — the echo
is the server's resolved answer, never the request.

**One honest edge, recorded rather than smoothed over.** The `/room/join` block is gated on the
**room hash**, exactly as planned, not on the master flag. A room armed while the flag was on
therefore keeps emitting the block until its 24 h Redis TTL expires, even after the flag is turned
off. In that window the whole `/presence` surface answers `404 PRESENCE_DISABLED`, so consent
cannot be granted and not one row can be written. Asserted in `presenceGate.test.js` Group A.

### 2.2 The client call sites

The plan called for four guarded call sites; the build has **four `if` guards plus three
unconditional blocks**, and the fourth guard is the detector start that Phase 1 added. Each guard is
a single `if` on one boolean. Each is listed in `REMOVAL.md`.

The cited line is the first line of the marked hunk (the `PRESENCE MONITORING (provisional…`
comment); the `if` itself is a few lines below, and its line number is given separately so the
table can be checked against the file.

| # | Site | Guard | What it gates |
|---|---|---|---|
| 1 | `AppDelegate.m:365`, inside the existing `preConnectConsentGate` block (`if` at `:369`) | `roomController.activePresenceMonitoringArmed` | The consent screen. The ONLY route to it |
| 2 | `AppDelegate.m:814`, in `-enterMode:`'s interviewee branch (`if` at `:822`) | `activePresenceMonitoringArmed` | The `POST /presence/consent` and the candidate chip |
| 3 | `AppDelegate.m:833`, in `-enterMode:`'s interviewer branch (`if` at `:839`) | `activePresenceMonitoringArmed` | The interviewer chip, the timeline popover and the 15 s poll |
| 4 | `SecureWindowController.m:607`, inside `-startLocalMediaFlow`'s prepare completion (`if` at `:612`) | `roomController.activePresenceMonitoringGranted` | **The detector.** Nothing samples a frame unless the candidate granted consent |
| 5 | `AppDelegate.m:2114`, in `-connectAndEnterMode:` | *(unconditional)* | Copies the interviewer's three green-room toggles into `InterRoomConfiguration`, which `/room/create` carries. Nothing is authorised by it — the server ignores all three unless the flag is on |
| 6 | `AppDelegate.m:6745`, `-teardownActiveWindows` | *(unconditional)* | `[self stopPresenceSurfaces]` — invalidates the poll timer, drops handlers, closes the consent window |
| 7 | `SecureWindowController.m:399`, `-destroySecureWindow` | *(unconditional)* | `[self.presenceCoordinator stop]` before the media shutdown, so the detector removes its own output while the session still exists |

Site 4 reads `activePresenceMonitoringGranted`, **not** `armed`. `granted` is written only by
`InterRoomController.recordPresenceConsent(granted:state:)` (the candidate's consent screen) and
cleared by `resetPresenceConsentForNewConnection()` (every new connection, see §2.2.1). An armed
room whose candidate declined samples nothing.

Site 3 reads the **same** `activePresenceMonitoringArmed` boolean as sites 1 and 2, on both
interviewer paths: `/room/create` echoes the server's arming answer for the host who creates the
room, `/room/join` for one who rejoins. The client never infers arming from its own request.

#### 2.2.1 Per-connection isolation — there are FOUR connect paths, not two

**An earlier version of this section claimed the arming property "is assigned unconditionally on
both paths, so a room armed earlier in the same app session cannot leak its state into the next
room". That was wrong on two counts and is corrected here.** There are four client connect paths,
not two; and the scheduled path assigned no presence field at all, so arming *did* leak into it.
Consent was worse: `InterRoomController` is created once (`AppDelegate.m:289`) and released only in
`-applicationWillTerminate`, and nothing cleared the consent pair between sessions, so a candidate
who granted monitoring in one interview kept `granted == true` into the next one and site 4 started
the detector for a session nobody had been asked about. Both are now fixed, and the table below is
the list of every path that writes the block.

| # | Connect path | Entry point | Who writes the presence block |
|---|---|---|---|
| 1 | `/room/create` — the interviewer who creates the room | `connect(configuration:completion:)`, `isHost == true`, empty `scheduledMeetingId` | The create branch assigns `activePresenceMonitoringArmed` from `response.presenceMonitoringArmed` (the server's own answer, absent and therefore false unless the server really armed the room), plus `RegionEU` / `Under18` from the host's local config |
| 2 | `/room/join` — anyone joining by room code, including a rejoining host | `connect(configuration:completion:)`, `isHost == false` | The join branch assigns all eight fields from the typed `/room/join` response. An omitted block means `armed == false` |
| 3 | `/meetings/:id/start` — a scheduled interview | `connect(configuration:completion:)`, non-empty `scheduledMeetingId` | `applyPresenceSettingsFromScheduledMeeting(_:)`, called unconditionally in the same main-queue block as the settings snapshot. That endpoint never arms a room and returns no key beginning `presence`, so this resolves to `armed == false` and the shipped defaults — the correct answer for a path the server never arms |
| 4 | Lobby-admitted — the candidate the host let in from the waiting room | `connect(withToken:serverURL:configuration:completion:)` | `applyMeetingSettingsFromDict(_:)`, called by `AppDelegate.m:4878` **before** `connectWithToken` at `:4894`, mirrors all eight fields from the `/room/lobby-status` dict with the same backward-compatible defaults |

**The consent pair is reset at the top of both public entry points.**
`resetPresenceConsentForNewConnection()` sets `activePresenceMonitoringGranted = false` and
`activePresenceConsentState = "pending"`, and is called from `connect(configuration:completion:)`
and `connect(withToken:serverURL:configuration:completion:)` — the only two public ways in, so all
four paths above pass through one of them. Three ordering facts make that safe, and each is
load-bearing:

* It runs **synchronously** on the caller's (main) queue, so it is ordered strictly before the
  server's answer, which lands later in a `DispatchQueue.main.async` block from the token
  completion, and before the pre-connect consent gate at site 1.
* It is **not** called from `handleTokenResponse`. That runs on the token completion's thread and
  its main-queue hop would land *after* the join branch's assignment, clobbering the server's
  answer.
* It is placed **after** the state and double-connect guards, so a connect that is refused cannot
  void the consent of the session already running.

**Only the consent pair is reset, never the arming block.** On path 4 the arming block has already
been assigned from the settings dict by the time `connect(withToken:…)` is called, so resetting it
there would clobber the server's answer; the dict carries no consent, which is why the consent pair
is the right thing — and the only thing — to reset in one shared place.

`interTests/InterPresenceSessionIsolationTests.swift` holds the five regression tests for this
section.

### 2.3 What the flag does NOT do

It does not uninstall the code, and it does not remove the three tables. Disabling is one step
(§`REMOVAL.md`); deleting is a file list and one manual `DROP TABLE`.

**It also does not hide the interviewer's green-room checkbox.** `GreenRoomViewModel.showsPresenceControls`
is `role == .hostInterview` and does not consult the server, because the green room renders before
the room exists and there is no server answer to read yet; probing for one would add a third reader
of the flag. So with the flag off a hiring interviewer still sees the "Record presence events"
checkbox.

**Ticking it with the flag off does nothing at all.** The box is a request, the server resolves it
to `armed: false`, `/room/create` echoes no presence key, `activePresenceMonitoringArmed` stays
false, and site 3 does not fire: no chip, no timeline popover, no poll. The caption under the
checkbox says exactly this — "This is a request for this room, not a guarantee. Nothing is recorded
unless the candidate agrees, and they can join with monitoring off. No decision is automated." It
deliberately does **not** promise that the candidate will be asked, because with the flag off they
are not: the candidate sees the untouched `-showIntervieweeConfirmationWithCompletion:` alert, no
consent, session or event row is created, and the detector never starts because
`activePresenceMonitoringGranted` is only ever written by the consent screen the candidate never
reaches. The zero-impact guarantee is therefore exact for the candidate, the interviewer, Redis, the
server and the database; the only residue is a checkbox whose caption tells the truth about what it
is.

---

## 3. Legal posture — read this section before enabling anything

### 3.1 WARNING: do not enable this for EU-resident candidates

**This is a warning, not a footnote.** The EU AI Act classification of this feature is
**unresolved**, and the adjacent prohibition is the most expensive one in the Act.

- **Art. 6(3) is uncertain.** Presence events used in a hiring decision may or may not fall inside
  the not-high-risk derogation. A per-person behavioural **score** would almost certainly destroy
  the derogation as profiling — which is one of the seven reasons there is no score (§4).
- **Art. 5(1)(f) is adjacent and absolute.** Inferring emotion in a workplace or hiring context is
  a **prohibited practice**, applicable since 2 Feb 2025, with a ceiling of **EUR 35 million or
  7 % of worldwide turnover**. This feature infers none of it (§4, §9), and that is a structural
  property of the schema and the wire format, not a promise. The exposure is what makes
  mislabelled copy, a stray log string or a casual code comment expensive — hence §8.

**The control.** A per-room `candidateRegionEU` flag forces `armed = false` **server-side** inside
`resolvePresenceArming`, before any room field is written. The reason code is `'eu_region'`. The
same warning is duplicated as a code comment on `resolvePresenceArming` in
`token-server/presenceConfig.js`, because that is where someone would otherwise remove it.

The interviewer declares `candidateRegionEU` as a green-room toggle. No `users` column records
region or date of birth, and collecting it from the candidate would make them self-declare a
protected characteristic to the system about to monitor them. The declaration is a host input the
server treats as a one-way veto: it can only turn monitoring **off**.

### 3.2 Under-18 candidates are never offered the monitored path

`candidateUnder18` forces `armed = false` with reason code `'under_18'`, by the same mechanism and
in the same predicate. On the client the pure function
`PresenceConsentViewModel.mode(armed:regionEU:under18:)` returns `.monitoringOffNotice` whenever
`regionEU || under18`, so the monitored offer is unreachable for those candidates by derivation
rather than by a UI check. All four combinations are enumerated in
`InterPresenceConsentViewModelTests.swift`.

### 3.3 Declining is real, and never blocking

There is **no blocking consent variant**, not even as an opt-in room setting. Declining joins the
interview with monitoring off, no reason requested. Both buttons are the same width, the same
`InterControl.primaryHeight` (40), the same `.primary` variant; neither is greyed and the decline
is not a link. This is also the disability accommodation path: a candidate who needs it does not
have to explain why.

### 3.4 Legal review, still outstanding — four named questions

Unchanged, and required before any production use:

1. BIPA / Md. §3-717 characterisation of on-device face **detection** that stores no template.
2. AI Act Art. 6(3) derogation versus profiling.
3. Whether AIVIA reaches a live two-way interview at all.
4. Whether DPDP §7(i) reaches candidates.

---

## 4. The no-score rule

**There SHALL be no aggregate score, index, percentage, rating, colour-coded risk level, total,
weighting, normalisation, or candidate-to-candidate or session-to-session comparison. Ever.**
Per-type counts and durations, and nothing above them.

The seven reasons, condensed:

1. **The base-rate arithmetic makes any score's implied precision wrong, and a number hides that.**
   An event list wears its own uncertainty: "no face visible, 00:14:02–00:14:19" invites the
   question *why*. A composite number out of 100 suppresses it.
2. **A score is probably what crosses three regulatory lines at once** — AI Act Art. 6(3)
   (profiling removes the derogation unconditionally), NYC LL144 (a score a hiring team weighs is
   a strong candidate for "substantially assisting" a discretionary decision, triggering an annual
   independent bias audit), AIVIA §5(2) (explaining "general types of characteristics" is trivial
   for five enumerated event types and not honestly satisfiable for an opaque aggregate).
3. **Retroactive recomputation is the cautionary example.** Where severity weights are
   administrator-configurable, re-weighting recomputes every past candidate's number. A value that
   depends on a setting someone changed last week is an opinion with a decimal point.
4. **Comparative scoring is the specific mechanism by which environmental inequality becomes a
   hiring outcome.** Ranking a session against other sessions ranks the candidate with the quiet
   private room above the candidate with the shared one.
5. **A score invites the automation this design forbids.** Once a number exists, someone sorts by
   it, then filters on it, then sets a threshold. Not building it is the only durable control.
6. **Every vendor who ships a score disclaims it, and the disclaimer does not work.** The artefact
   is read as a verdict anyway. Do not ship the misreadable artefact.
7. **If a credible signal is ever wanted, build it from code-editor interaction telemetry** — paste
   events, similarity diffs, language switches — where the signal is strong, the false-positive
   story is defensible and no biometric question arises. That is a different feature, and a better
   one. It is explicitly out of scope here (§9).

### 4.1 The concrete consequence, as built

The timeline response's `summary` is an array whose rows have **exactly four keys** —
`eventType`, `count`, `totalDurationMs`, `liveSurfaceable` — asserted by a test that fails if a
fifth appears. There is no total row, no weighting, no percentage, no rating, no risk level and no
cross-candidate or cross-session field anywhere in the payload, the CSV export, the view models,
the labels or the database. The prohibition is carried as a code comment on the summary builder
and on the Swift summary struct, so it travels with the type rather than living only here.

The interviewer's UI renders rows like "Face not visible — 3 events, 41 s total", plus a footer
stating the detector version and the thresholds in force, because an event means nothing without
its operating point.

---

## 5. What is recorded

### 5.1 Event types

Six in the database `CHECK`, five a client may send. `head_off_axis` does not exist in this build —
not in the `CHECK`, not in the allowlist, not in the detector.

| Event type | Who produces it | Meaning |
|---|---|---|
| `face_absent` | client | No face visible to the candidate's camera, camera on, quality above floor |
| `multiple_faces` | client, **only when the server gate is on** | Two or more faces visible |
| `image_quality_insufficient` | client | The detector could not see usefully: it failed, or confidence/box area below floor |
| `camera_disabled` | client | The candidate turned their camera off (instantaneous, `durationMs: 0`) |
| `camera_enabled` | client | Their camera came back (instantaneous) |
| `monitoring_gap` | **server only** | No report arrived for longer than `PRESENCE_GAP_SECONDS` (60). A client payload carrying it is rejected |

### 5.2 The wire contract

```
POST /presence/events          Leave-Token: <the leaveToken from /room/join>
{ "roomCode": "ABCDEF", "identity": "<ephemeral participant identity>",
  "events": [ { "eventType": "face_absent",
                "startedAt": "2026-10-31T10:00:00.000Z",
                "endedAt":   "2026-10-31T10:00:12.000Z",
                "durationMs": 12000,
                "detectorVersion": "presence-1.0.0" } ] }
```

- Top-level keys allowed: `roomCode`, `identity`, `events`. Per-event keys allowed: the five above.
  Anything else is `400`. A client-supplied `thresholds` is refused — **the server stamps them.**
- `startedAt`/`endedAt` are ISO-8601 **strings**. A number is refused `400
  PRESENCE_PAYLOAD_INVALID`: an epoch integer is ambiguous between seconds and milliseconds and
  the server will not guess.
- An **empty** `events` array is valid and **is the heartbeat**. The client posts on its 15 s
  cadence even with an empty buffer; silence longer than 60 s makes the *server* record a
  `monitoring_gap`.
- Batch limit 100 (`101` → `413`); the Express default 100 KB body cap also applies.
- `PresenceEvent` is a struct of `String`/`Int`/`Double` only and `asPayload()` is the single
  serialisation path in the client, so **no pixel, frame, crop, thumbnail, `Data` or numeric series
  can reach the wire.** This is structural, not a policy.

### 5.3 The forbidden-key list is a documentation control; the allowlist is the real one

`FORBIDDEN_KEYS` holds 82 entries (counted from the shipped module; FEAT-001's findings say 90,
which is wrong — `require('./presenceEvents').FORBIDDEN_KEYS.length` is 82) — among them `landmarks`, `score`, `emotion`, `confidence`, `attention`,
`engagement`, `yaw`, `pitch`, `roll`, `frame`, `image`, …). Keys are normalised by lowercasing and
stripping `_` and `-`, then compared **exactly**, recursively through objects and arrays to depth
16. A forbidden key beats an unknown key so the error names the prohibited concept
(`PRESENCE_FORBIDDEN_FIELD`, with the offending key as written in `field`).

**Known matching limit, recorded on purpose:** the list contains `score` but not `facescore`, so
`faceScore` / `face_score` / `FACE-SCORE` are refused as `PRESENCE_UNKNOWN_FIELD` rather than
`PRESENCE_FORBIDDEN_FIELD`. All three are still **rejected, never stripped**. A future contributor
who wants compound spellings named by concept SHALL add the compound to `FORBIDDEN_KEYS` and SHALL
NOT switch to substring matching, which would false-positive on legitimate keys.

### 5.4 Storage, retention and audit

Three tables in migration `023_interview_presence_events.sql`: `interview_presence_sessions` (the
mutable state), `interview_presence_events` (the facts), `interview_presence_notes` (the
interviewer's judgement, additive). Every row carries the `thresholds` JSONB and `detector_version`
that produced it. Notes are stored as `note_text_enc` TEXT plus `note_key_version` SMALLINT via
the versioned `crypto.js` convention; the note path fails closed with `500
ENCRYPTION_UNAVAILABLE` when encryption is unavailable. No email and no display name on the
session row — the ephemeral participant identity only.

`purge_after` is stamped at write time from `PRESENCE_EVENT_RETENTION_DAYS` (default 90). A sweeper
runs every hour, deletes due rows, and closes sessions that have been silent for
`PRESENCE_STALE_SESSION_MINUTES` with one terminal `monitoring_gap`.

Eight audit event types go through the existing `auth.auditLog` and nothing else:
`presence_consent_granted`, `presence_consent_declined`, `presence_monitoring_enabled`,
`presence_monitoring_disabled`, `presence_timeline_read`, `presence_note_added`,
`presence_export`, `presence_events_purged`. Metadata never carries note text, email,
thresholds-as-free-text or any forbidden key.

### 5.5 Error codes, exact strings

| Code | Status | When |
|---|---|---|
| `PRESENCE_DISABLED` | 404 | Master flag off |
| `INSUFFICIENT_TIER` | 403 | Host tier below `hiring` (the real existing string; `TIER_INSUFFICIENT` does not exist) |
| `PRESENCE_MONITORING_NOT_ARMED` | 409 | Room exists, never armed |
| `PRESENCE_CONSENT_REQUIRED` | 409 | Ingest while consent is not `granted` |
| `PRESENCE_EVENT_TYPE_NOT_ALLOWED` | 400 | Type outside the five client types (covers `monitoring_gap` and `head_off_axis`) |
| `PRESENCE_EVENT_TYPE_DISABLED` | 409 | `multiple_faces` while the room gate is off |
| `PRESENCE_FORBIDDEN_FIELD` | 400 | A `FORBIDDEN_KEYS` key is present |
| `PRESENCE_UNKNOWN_FIELD` | 400 | A key outside the allowlist |
| `PRESENCE_PAYLOAD_INVALID` | 400 | Shape, type or ordering violation |
| `PRESENCE_BATCH_TOO_LARGE` | 413 | More than 100 events |
| `PRESENCE_SESSION_NOT_FOUND` | 404 | No room hash, no session row, or a note aimed outside the session |
| `PRESENCE_UNAUTHORIZED` | 403 | Missing or mismatched `Leave-Token` |
| `PRESENCE_FORBIDDEN` | 403 | `validateModerator` rejected the caller |
| `PRESENCE_NOTE_REASON_REQUIRED` | 400 | Note under 10 characters after trimming |
| `ENCRYPTION_UNAVAILABLE` | 500 | Note path, fails closed, writes nothing |
| `PRESENCE_UNAVAILABLE` | 503 | Redis or Postgres unreachable, including inside the rate limiter |
| `RATE_LIMITED` | 429 | New string, always with a `Retry-After` header |

**Deliberate divergence, commented in code:** a Redis error inside the presence rate limiter
returns `503 PRESENCE_UNAVAILABLE` rather than failing open. Every one of these handlers needs
Redis anyway, and an unmetered flood of behavioural-record writes is the worse failure.

---

## 6. Thresholds, hysteresis and the precedence lock

### 6.1 The table, with the rationale per value

Sampling is one frame per **500 ms** (2 Hz) on a `.utility` queue, deliberately below the LiveKit
publisher's `.userInteractive`, so contention costs the detector and never the call. Events here
are measured in seconds, so a 3 s threshold still gets ~6 samples of evidence at roughly 15× less
work than a 30 fps pipeline.

| Threshold | Value | Rationale |
|---|---|---|
| `sampleIntervalMs` | 500 | 2 Hz: enough samples for a 3 s threshold, cheap enough not to compete with the encoder |
| `faceAbsentOpenMs` | 10 000 | Long enough that reaching for a glass of water, a dropped pen or a stretch never opens an event. Deliberately much longer than a human glance |
| `multipleFacesOpenMs` | 3 000 | Shorter because a second person who is actually there stays there; a transient pass-through behind the candidate should not qualify |
| `imageQualityOpenMs` | 15 000 | Longest of the three: the honest reading is "this video has been unusable for a quarter of a minute", and backlighting flickers |
| `closeMs` | 1 000 | One second of the condition clearing closes the event, so a single-frame blip cannot split one event into two |
| `detectorConfidenceFloor` | 0.35 | Below this the Vision detector's own bounding-box confidence is not worth interpreting. Feeds `image_quality_insufficient` **only** |
| `minBoxAreaFraction` | 0.01 | A face occupying under 1 % of the frame is too far away to read; a quality fact, not a behaviour |
| `gapSeconds` | 60 | Four missed 15 s heartbeats before the server records a gap, so one lost request is not an event |

An event opens only after its condition holds continuously for the open threshold; any candidate
event that never reached its open threshold is **discarded entirely**, so transient detector noise
never reaches the store. The same eight values are the server's `thresholdSnapshot()`, the raw JSON
string delivered on `/room/join`, and the client's `PresenceThresholds.defaults` **and** its
per-key parse fallbacks — so a malformed field can never silently widen a threshold. A test
compares the parsed server snapshot against the client defaults key for key.

**Threshold owner: `<unassigned — must be filled before the flag is enabled>`.** **[OPEN
QUESTION]** A named person with a written rationale is required. No name is invented here. These
values are a judgement about where a human-reviewed record starts, not a measurement; whoever owns
them owns the decision in §7.

**Naming deviation from the plan:** the plan calls the confidence floor `minConfidence`. The server
key is `detectorConfidenceFloor` so it cannot be misread as an inference about the candidate — it
is the Vision detector's own bounding-box confidence. The client's internal `PresenceSample`
field keeps the short name; the threshold it compares against carries the long one.

### 6.2 The precedence lock — the ethics of the feature, in code

```
cameraMuted                        -> emit the camera transition only; close and DISCARD every
                                      other open candidate; face_absent cannot open
detectorFailed || quality < floor  -> feeds image_quality_insufficient ONLY.
                                      It MUST NOT feed face_absent.
faceCount == 0 && quality >= floor -> feeds face_absent
faceCount >= 2                     -> feeds multiple_faces, independently of the quality branch
                                      (a frame can be both, and the honest record is both)
```

**[DECISION — RESOLVED] A detection failure is a data-quality fact about the video, recorded as
`image_quality_insufficient`, and never as `face_absent`.** Detection failure rates are not
uniform across skin tones, lighting or webcam quality. Mislabelling a failure as absence converts
an equipment inequality into an accusation. Three tests assert that `face_absent` is absent from
the emitted events for a detector failure, for confidence below the floor and for box area below
the floor. The rule is restated as a named comment in both the engine and the detector.

### 6.3 [DECISION — RESOLVED] The empty-result sentinel

The quality rule is implemented literally (`detectorFailed || minConfidence < 0.35 ||
maxBoxAreaFraction < 0.01`), which forces the detector to say what those two numbers mean for a
successful request that found **nobody**. It returns the neutral sentinels `maxBoxAreaFraction 1.0`
/ `minConfidence 1.0` — "the request ran; there is no quality objection against this frame" — so a
genuine absence is recorded as `face_absent`. Zeroes there would have turned every real absence
into `image_quality_insufficient` and made `face_absent` unreachable. A thrown error or `nil`
results sets `detectorFailed = true` instead. Both branches are asserted.

### 6.4 How the camera state reaches the engine

Not in the plan; read this before changing it. The frame path cannot observe a camera switch-off,
because the frames simply stop. The coordinator therefore runs its own 500 ms timer reading a
`cameraEnabledProvider` block built over `InterLocalMediaController.isCameraEnabled` (an `atomic`
property, so the read is thread-safe). On a transition it pushes the state into the capture source
and feeds the engine a `cameraOff` sample, which emits `camera_disabled` and discards the other
open candidates. `camera_enabled` lands on the first real frame back. No new observer slot is
taken and no extra call site is added — the block is created inside the single guarded `if`.

### 6.5 Indicator ownership

The chip encoding is identical in every layer: `0` absent, `1` monitoring on, `2` monitoring off,
`3` paused because the camera is off. **The coordinator owns `1` and `3`; `AppDelegate` owns the
initial and declined `2`.** `AppDelegate` has to, because on a decline the coordinator never
starts and the chip must still read "off". Ordering makes a conflict practically impossible: the
consent POST completes within milliseconds of entering the mode, the coordinator only starts after
the camera-permission and prepare round trip, and a human camera toggle is seconds later. This is
the one place where two writers exist, and it is recorded rather than hidden.

The chip is **persistent and non-dismissible — never a toast.** A toast conflates "declined" with
"never saw it". Icon and word are always paired; state is never signalled by colour alone.

### 6.6 What the interviewer sees live

Only `multiple_faces` and `face_absent` are live-surfaceable, and the server computes that — the
client cannot widen the set. `image_quality_insufficient` is deliberately **not** live-surfaceable:
a data-quality fact about the video is never surfaced live as if it were candidate behaviour. The
view model's setter **refuses** anything outside the two types rather than clamping it.

Transport is a 15 s poll of `GET /presence/timeline/:code/:identity` — **not** Socket.IO and
**not** the LiveKit DataChannel. No behavioural data crosses the SFU, the client batches every
15 s anyway so a push channel could not make the chip fresher, and polling reuses the one
server-authorised read path (`requireAuth` + `validateModerator` + `hiring` tier) instead of
adding a second, weaker one.

---

## 7. `multiple_faces` is OFF by default, and the study that gates it is the keep-or-delete decision

`PRESENCE_MULTIPLE_FACES_ENABLED` defaults to **false**. When it is false the room hash says so,
the join response says so, and the client **engine never constructs the event at all** —
suppression at the engine, not a filter at upload, so a suppressed event never exists as an
uploadable object. The server independently refuses it with `409
PRESENCE_EVENT_TYPE_DISABLED`.

### 7.1 The prerequisite, stated plainly

**The flag MUST NOT be enabled in production until a measured false-positive study passes:**

- **at least 20 sessions** with no second person present and no deliberate absence;
- across **varied lighting, rooms, webcams and skin tones**;
- reporting the **per-session false-positive rate per event type**;
- with **`multiple_faces` under 5 % per session**.

**This study needs real humans in real rooms. An agent cannot do it. It MUST NOT be faked,
simulated, approximated or hand-waved.** It was not done, and nothing in this build pretends
otherwise. The same applies to the resource measurement in §10.

### 7.2 What it is actually for

**[DECISION — RESOLVED]** After the 2026-10-31 scope adjustment, the study is not a release
checkbox. **It is the measurement that tells the user whether to keep this feature or delete it.**
That is why the whole build is behind one flag, why every hunk carries a greppable marker, and why
`REMOVAL.md` exists and is as detailed as this document.

Read it that way: if a varied population of honest candidates trips `multiple_faces` or
`face_absent` at a rate an interviewer would find noisy, the correct outcome is not a threshold
tweak. It is deletion. A detector that passes CI and has never been measured against real honest
candidates is precisely the artefact this feature was designed to avoid becoming.

---

## 8. The claim checklist, applied to UI copy, log strings and code comments

Every item below is either legally exposed, scientifically false, or both. The checklist applies to
candidate-facing copy, interviewer-facing copy, marketing, **log strings and code comments** —
because a comment is what the next contributor reads before writing the next string.

**This product SHALL NOT be described as:** detecting or preventing cheating; detecting dishonesty
or deception; measuring attention, focus, engagement or distraction; measuring emotion, mood,
affect, sentiment, stress, nervousness or confidence; inferring personality, cultural fit or
"soft skills" from video; performing eye tracking or gaze tracking (in this build that is simply
false — there is no gaze code); verifying identity (a separate, on-hold feature; conflating them
is how a presence recorder gets sold as identity assurance); AI-powered proctoring, or proctoring
at all; guaranteeing or ensuring interview integrity or fairness; unbiased, bias-free or
demographically validated (not without publishing the measurement, and the measurement will show
differentials); achieving any accuracy percentage (not without publishing the false-positive rate,
the base rate and the methodology); or tamper-proof, unbypassable or undefeatable.

**Say instead, and mean it:**

> "KioMeet records when a candidate's face is not visible to their camera, and when more than one
> face is visible, with timestamps. Your interviewer reviews those moments and decides what they
> mean. KioMeet does not analyse expression, emotion or attention, and makes no decision about any
> candidate."

Every clause there is true, checkable and differentiating.

### 8.1 How the checklist is enforced, and the one deviation

`InterPresenceConsentViewModelTests.swift` asserts, one assertion per word so a failure names the
offender, that the concatenated candidate-facing disclosure copy contains none of the forbidden
terms, case-insensitively. A copy scan over the new and changed UI files found no violation in any
candidate- or interviewer-facing string.

**Deviation, with its reason.** The plan asked for the consent screen's negative list **verbatim**
and, separately, for a blanket forbidden-word check over the copy. The verbatim sentence contains
four forbidden words, so the two requirements are mutually exclusive. The negative list is
reproduced in plain language with the same substance and the same prominence — its own visually
distinct block with six explicit "we do not" lines — and the deviation is recorded as a doc comment
on the disclosure struct. Choosing the other way round would have made the copy guard untestable
as specified.

---

## 9. Out of scope — and why

| Not doing | Why |
|---|---|
| Head pose / `head_off_axis`; `yaw`, `pitch`, `roll` collected nowhere | Dropped after a feasibility review. Absent from the DB `CHECK`, the allowlist and the detector; the three field names are in `FORBIDDEN_KEYS`. Verified: no read of `.yaw`/`.pitch`/`.roll` exists in the client |
| Gaze or iris tracking | No commercially licensed model with published accuracy; it covers almost nothing head pose does not; disability false positives. ARKit does not exist on macOS |
| Blink / eye-aspect-ratio / eyes-closed duration | No defensible interpretation, reads as medical surveillance, pure false-positive surface |
| Emotion, affect, sentiment, mood, engagement, attention, focus, confidence, stress, honesty, deception or personality inference | EU AI Act Art. 5(1)(f) **prohibited practice** in hiring, up to EUR 35 M / 7 % of turnover. No field, column, API key, log string, comment or UI string may imply any of them |
| Any score, index, percentage, rating, risk level or cross-candidate / cross-session comparison | §4, seven reasons |
| Room scan | Worse intrusion than every implemented signal combined |
| Virtual-camera detection | Cannot be made reliable on macOS; the heuristics falsely reject desktop-Mac users. A virtual camera therefore makes every signal here meaningless, and that is stated as residual risk, not defended against |
| Audio signals (second voice, whispering) | Separate consent scope, separate legal analysis, far worse false-positive story in shared rooms |
| Server-side frame analysis | ~108 MB per candidate per interview, bandwidth the candidate pays for, and it manufactures the centralised biometric pipeline the data-minimisation design exists to avoid |
| Frame / crop / thumbnail / video retention | A `CVPixelBuffer` lives for exactly one Vision request and is released. Nothing is encoded, written or transmitted |
| Face identity verification | A different feature, explicitly on hold. This build reuses its *patterns* and touches none of its code. No reference photo, no matching, no identity claim in any string |
| Code-editor interaction telemetry | Out of scope here and deferred as the next piece of work — and per §4 reason 7, the better place for a signal if one is ever wanted |
| Any blocking consent variant, even as an opt-in room setting | Proctoring consent has been struck down precisely where there was no real alternative. Declining always joins with monitoring off (§3.3) |
| Any automated action — auto-reject, auto-warn, auto-interrupt, auto-end, auto-rank, ATS propagation | Ending an interview stays the interviewer's existing explicit action: one capability, one place. The presence surface offers no action against the candidate at all |
| Telling the candidate a specific event fired | Mid-answer notification is prejudicial and useless, since the interviewer adjudicates. The candidate is told at consent what is recorded, and the chip shows whether monitoring is active — nothing more |
| A second `AVCaptureSession`, or any change to the existing session lifecycle | The camera device is single-owner (§11) |
| An in-timeline video player | Jump-to-timestamp routes to the existing recordings surface with an offset, and is **disabled with the caption "No recording for this session"** rather than hidden, so the control never implies a clip exists. A player is new scope |
| New `InterNetworkErrorCode` values, `isExpectedJoinRejection` changes, `InterFeatureGate` changes, `tiers.js` `FEATURES` changes, `project.pbxproj` edits, Socket.IO signals, LiveKit DataChannel topics | None needed; each would be surface to remove later |

---

## 10. Deferred — these are prerequisites, not nice-to-haves

Both were dropped from this build because they only bite once real candidates' data is processed,
which the default-off flag prevents. **Neither is optional. Both block enabling the flag for real
candidates.**

1. **The published customer-facing "what is and is not measured" transparency page.** A short
   plain-language page KioMeet publishes and the customer hands to candidates. It is what makes
   AIVIA §5(2) and Illinois HB 3773 notice duties satisfiable by the buyer rather than a problem
   they discover after signing.
2. **The candidate copy/delete (DSAR) endpoint.** Satisfies AIVIA §15's 30-day obligation and the
   DPDP erasure right. Cheap to build — the artefact is event rows and erasure is one `DELETE FROM
   interview_presence_sessions` with events and notes cascading — but it needs candidate-email
   columns and a verified-request path, both deliberately absent from migration 023. **Until it
   exists, the consent screen states the `PRESENCE_RIGHTS_CONTACT` address and requests are handled
   manually by the operator.** The workflow brief listed this endpoint; it was deliberately not
   built, and this is the record of that decision.

Alongside them, three more gates before the flag may be enabled:

3. **The §7 false-positive study.** Not done; cannot be done by an agent; must not be simulated.
4. **The resource measurement.** Process CPU, package power, and the LiveKit publisher's sent-frame
   rate and encode-time percentiles, monitoring off versus on, on the lowest-spec supported Mac,
   over a 45-minute two-client call with screen share active. Not done, same reason.
5. **The legal review on the four questions in §3.4**, and a named threshold owner (§6.1).

---

## 11. What stays untouched

The following were **not** modified, and SHALL stay that way for this feature's sake:

| Untouched | Why it matters |
|---|---|
| `InterRoomController.preConnectConsentGate`'s signature | The gate block reads the new properties; the signature is load-bearing for every existing caller |
| `AppDelegate.m -showIntervieweeConfirmationWithCompletion:` | Byte-for-byte unchanged, and it remains the live candidate join path whenever the flag is off. Verified by printing the method body back |
| `InterLocalMediaController.recordingFrameObserver` and `recordingCameraStateObserver` | Single-slot properties owned by `InterRecordingCoordinator`. Co-opting either would break local recording's camera PiP. Neither symbol appears in any new file |
| `InterLiveKitCameraSource` and `InterLocalMediaController`'s session lifecycle | The presence source adds and removes only its own output, pins `kCVPixelFormatType_32BGRA`, and never calls `startRunning`/`stopRunning`/`addInput`/`removeInput`. Asserted by an `AVCaptureSession` subclass that flags those calls; never flagged |
| Socket.IO | Stays for moderation and mic-state signalling. No behavioural data rides it |
| The LiveKit DataChannel | No presence topic exists |
| `InterNetworkErrorCode` | Still 21 cases (1000–1020); `isExpectedJoinRejection` byte-for-byte unchanged. Cancelling consent reuses the existing `.consentDeclined` (1020) path |
| `InterFeatureGate` | No change |
| `tiers.js` `FEATURES` / `FEATURE_MIN_TIER` | Monitoring rides the existing `hostInterview` → `hiring` entitlement, read from the room's snapshotted `hostTier`. No new feature key |
| `inter.xcodeproj/project.pbxproj` | Never hand-edited. New files compile via `PBXFileSystemSynchronizedRootGroup`. mtime verified unchanged |
| Every pre-existing table and row | Migration 023 is additive and `IF NOT EXISTS` throughout. `\dt` lists the 23 pre-existing tables plus exactly three new ones; `schema_migrations` count 23; no existing table altered, no row destroyed |
| The six pre-existing rate limiters | A new, separately named limiter set was added for the presence routes |

---

## 12. Verification that was actually run

| Gate | Observed |
|---|---|
| Migration | `node migrate.js` printed `✓ 023_interview_presence_events.sql`; a second run printed `No pending migrations.`; `schema_migrations` has exactly one `023%` row and 23 rows total; `\dt` shows 26 tables (23 pre-existing + 3 new) |
| Server tests | `npm test` → `tests 162 / pass 162 / fail 0 / skipped 0`, of which 82 are the three new files (`presenceEvents` 43, `presenceRetention` 22, `presenceGate` 17) |
| Flag-off zero impact | 404 `PRESENCE_DISABLED`; room hash 36 fields, zero `presence` keys; join response 20 keys, none `presence*`; no sweeper line in the startup log |
| Client build | `** BUILD SUCCEEDED **`, zero `error:` lines, no new warning naming a presence file |
| New client suites | `InterPresenceConsentViewModelTests` 39 passed / 0 failed; `InterPresenceDetectorTests` + `InterPresenceCaptureSourceTests` 45 passed / 0 failed. This Xcode's reporter prints per-case lines rather than an `Executed N tests` summary, so the per-case count is the evidence |
| Camera path undisturbed | `InterLiveKitCameraSourceTests` + `InterCameraWiringTests` + `InterRecordingCoordinatorTests` 38 passed / 0 failed |
| Full client suite | 777 passed / 4 failed / 13 skipped. The 4 are a **pre-existing environmental** failure: `InterMultiParticipantIntegrationTests`' `setUp` does `try? XCTSkipUnless(isServerRunning, …)` and the `try?` swallows the skip, so the cases fail instead of skipping when no token server is listening. A pre-change baseline failed the same four |
| Vision surface | `grep -rln 'import Vision'` over the client returns exactly one file, `inter/Media/InterPresenceDetector.swift`. No landmarks, no capture-quality request, no feature print, no `.yaw`/`.pitch`/`.roll` read anywhere |

**Harness limit, measured and reported rather than worked around:** two source-scanning audit tests
(`SecureToolsWindowAuditTests.testSecureToolsSourcesContainNoWindowSpawningAPIs`,
`SecureToolsNetworkAuditTests.testSecureToolsSourcesImportNoNetworkingModules`) each run for
~1793 s on this machine and are cancelled by Xcode's per-test time allowance. They enumerate only
`inter/UI/SwiftUI/SecureTools/*.swift`, where nothing was modified, so full-suite runs skip those
two methods so the rest of the suite is not cancelled with them.

---

## 13. Open questions

1. **Threshold owner** (§6.1) — `<unassigned>`. Must be filled before the flag is enabled.
2. **Who declares EU residency and age** (§3.1) — currently the interviewer, per room, as two
   green-room toggles, because no `users` column records either and asking the candidate would make
   them self-declare a protected characteristic to the system about to monitor them. Server-side
   both force `armed = false`.
3. **Jump-to-timestamp target** (§9) — assumed to be the existing recording surface with an offset,
   honestly disabled when no recording exists. An in-timeline player is new scope.
4. **Keep or delete** (§7.2) — unanswerable until the false-positive study is run with real people.
