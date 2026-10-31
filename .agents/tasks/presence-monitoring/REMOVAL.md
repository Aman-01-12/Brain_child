# REMOVAL.md — how to turn candidate presence monitoring off, and how to delete it

**Feature:** candidate presence monitoring for secure interview mode (provisional, default OFF).
**Design note:** `/Users/aman_01/Documents/inter/docs/superpowers/specs/2026-10-31-interview-presence-monitoring-design.md`
**Written:** 2026-10-31, after the build, against the tree as it actually stands.

Two paths. **Disabling is one step and needs no code change.** Deleting is a file list, a handful
of marked hunks, and one manual database step, because migrations here are forward-only.

---

## 1. Disable without deleting — one step

Unset `PRESENCE_MONITORING_ENABLED` in the token server's environment (or set it to anything other
than the exact string `true`) and restart the token server.

```bash
# token-server/.env
PRESENCE_MONITORING_ENABLED=false
```

```bash
cd /Users/aman_01/Documents/inter/token-server && node index.js   # or your usual restart
```

That is all. **No client release is needed.** With the flag off:

- every `/presence/*` route answers `404 {"error":"Not found","code":"PRESENCE_DISABLED"}` from the
  router's first middleware, before any authz, Postgres or Redis work;
- `resolvePresenceArming()` returns `{armed:false, reason:'feature_disabled'}`, so **no `presence*`
  field is written to the room hash** (the arming write is a second, separate conditional
  `pipeline.hset()` — the pre-existing one is byte-for-byte unchanged);
- `/room/join` therefore omits the whole presence block and `/room/create` omits its one
  `presenceMonitoringArmed` key, so the shipped client parses `activePresenceMonitoringArmed` as
  `false` from its backward-compatible default on **both** paths. The consent screen, the candidate
  chip, the interviewer chip and **the detector** are each one `if` that reads false, so the
  candidate join flow is the untouched `-showIntervieweeConfirmationWithCompletion:` path again;
- the retention sweeper timer does not start.

**One thing the flag does NOT switch off, stated plainly.** The interviewer's green-room checkbox
is gated on `role == .hostInterview`, not on the server, because the green room renders before the
room exists and probing for the flag's state would add a third reader of it. So with the flag off a
hiring interviewer can still tick "Record presence events" — but **ticking it does nothing**: the
server resolves the request to `armed: false`, `/room/create` echoes no presence key,
`activePresenceMonitoringArmed` stays false and no chip, popover or poll starts. The caption under
the checkbox is written for exactly this state and does not promise the candidate will be asked. If
you want the checkbox itself gone, delete the `presenceSection` in `GreenRoomView.swift` and the
`PRESENCE MONITORING` block in `GreenRoomViewModel.swift` — that is removal (§2/§3), not disabling.

**One edge, so nobody is surprised by it.** The `/room/join` presence block is gated on the **room
hash**, not on the flag. A room that was armed while the flag was on keeps emitting the block until
its 24 h Redis TTL expires. In that window the whole `/presence` surface is `404
PRESENCE_DISABLED`, so no consent can be granted and not one row can be written. If you want it
gone immediately, delete the room keys: `redis-cli --scan --pattern 'room:*'` then `HDEL` the
`presence*` fields, or just let the TTL expire.

---

## 2. Full removal — files to delete

Every path below is absolute and was verified to exist with `ls` on 2026-10-31, re-verified after
the per-connection isolation fix. Deleting these 22 files removes the entire feature's own code.

### Server (8)

```
/Users/aman_01/Documents/inter/token-server/presenceConfig.js
/Users/aman_01/Documents/inter/token-server/presenceEvents.js
/Users/aman_01/Documents/inter/token-server/presenceRetention.js
/Users/aman_01/Documents/inter/token-server/presence.js
/Users/aman_01/Documents/inter/token-server/migrations/023_interview_presence_events.sql
/Users/aman_01/Documents/inter/token-server/test/presenceEvents.test.js
/Users/aman_01/Documents/inter/token-server/test/presenceRetention.test.js
/Users/aman_01/Documents/inter/token-server/test/presenceGate.test.js
```

Read §4 before deleting the migration file.

### Client — UI (5)

```
/Users/aman_01/Documents/inter/inter/UI/SwiftUI/Screens/PresenceConsentViewModel.swift
/Users/aman_01/Documents/inter/inter/UI/SwiftUI/Screens/PresenceConsentView.swift
/Users/aman_01/Documents/inter/inter/UI/SwiftUI/Screens/InterPresenceConsentHostView.swift
/Users/aman_01/Documents/inter/inter/UI/SwiftUI/Screens/PresenceTimelineViewModel.swift
/Users/aman_01/Documents/inter/inter/UI/SwiftUI/Screens/PresenceTimelineView.swift
```

### Client — detector (5)

```
/Users/aman_01/Documents/inter/inter/Media/InterPresenceEventEngine.swift
/Users/aman_01/Documents/inter/inter/Media/InterPresenceDetector.swift
/Users/aman_01/Documents/inter/inter/Media/InterPresenceCaptureSource.swift
/Users/aman_01/Documents/inter/inter/Media/InterPresenceReporter.swift
/Users/aman_01/Documents/inter/inter/Media/InterPresenceCoordinator.swift
```

`InterPresenceDetector.swift` is the only `import Vision` in the whole client. Deleting it removes
Vision from the app.

### Client — tests (4)

```
/Users/aman_01/Documents/inter/interTests/InterPresenceConsentViewModelTests.swift
/Users/aman_01/Documents/inter/interTests/InterPresenceDetectorTests.swift
/Users/aman_01/Documents/inter/interTests/InterPresenceCaptureSourceTests.swift
/Users/aman_01/Documents/inter/interTests/InterPresenceSessionIsolationTests.swift
```

### Docs (2, optional — delete only if you want no record)

```
/Users/aman_01/Documents/inter/docs/superpowers/specs/2026-10-31-interview-presence-monitoring-design.md
/Users/aman_01/Documents/inter/.agents/tasks/presence-monitoring/REMOVAL.md
```

### No Xcode project edit, in either direction

`inter.xcodeproj/project.pbxproj` was never touched and must not be. Both the `inter` and
`interTests` groups are `PBXFileSystemSynchronizedRootGroup` (`objectVersion = 77`), so adding and
removing files under `inter/` and `interTests/` needs no project change. **Never hand-edit
`project.pbxproj`.**

---

## 3. Existing files touched — the hunks to revert

### 3.1 Finding them: the marker grep

Every presence hunk opens with an upper-case `PRESENCE MONITORING` marker comment. **This is the
command that finds all of them:**

```bash
grep -rn 'PRESENCE MONITORING' \
  /Users/aman_01/Documents/inter/inter \
  /Users/aman_01/Documents/inter/token-server \
  /Users/aman_01/Documents/inter/interTests
```

It matches **38 files**: the 22 files in §2 that live under those three directories (20 of them —
the 2 docs are elsewhere) plus the 16 pre-existing files in §3.3 below, and nothing else.

Two pre-existing files carry presence changes with **no code marker**, because neither is code;
they are listed in §3.3 and the grep does not find them: `token-server/.env.example` and
`README.md`.

**A narrower grep finds only a subset — know which one you are running.** The exact string
`PRESENCE MONITORING (provisional)` (closing parenthesis immediately after the word) matches only
**15 files**, because most hunks write the marker as `PRESENCE MONITORING (provisional, server flag
default OFF)` and one writes `PRESENCE MONITORING, provisional`:

| Grep | Files matched |
|---|---|
| `'PRESENCE MONITORING'` | **38 — use this one.** All 20 new in-tree files + all 16 touched code files |
| `'PRESENCE MONITORING (provisional'` | 37 — the above minus `inter/UI/SwiftUI/Screens/CallControlBarView.swift` |
| `'PRESENCE MONITORING (provisional)'` | 15 — `token-server/{index.js, presence.js, presenceConfig.js, presenceEvents.js, presenceRetention.js, migrations/023_interview_presence_events.sql, test/presenceEvents.test.js, test/presenceGate.test.js, test/presenceRetention.test.js}`, `inter/App/AppDelegate.m`, `inter/Networking/{InterNetworkTypes.swift, InterRoomController.swift}`, `inter/UI/Controllers/SecureWindowController.m`, `inter/UI/SwiftUI/Screens/{InterCallControlBarBridge.swift, InterSecureChromeBridge.swift}` |

Line numbers below are from the tree on 2026-10-31. They will drift; the marker comment is the
stable anchor, so grep for the marker and use the line number only as a hint.

### 3.2 Server (3 files)

| File | Hunks | Anchors |
|---|---|---|
| `/Users/aman_01/Documents/inter/token-server/index.js` | 8 marked hunks | `:84` the four `require`s; `:2302` the router build + `app.use('/presence', …)` + the sweeper build; `:2520` the `/room/create` arming block (a **second** conditional `pipeline.hset`, delete the whole call); `:2604` the `/room/create` response `presenceBlock` and `:2627` its one-line `...presenceBlock` spread; `:2880` the `/room/join` presence block and `:2924` its one-line `...presenceBlock` spread; `:5888` the `presenceSweepTimer` inside `if (require.main === module)` |
| `/Users/aman_01/Documents/inter/token-server/.env.example` | 1 block, **no code marker** | The section headed `# Presence monitoring (PROVISIONAL — default OFF, and it must stay off)` at `:137`, through `PRESENCE_RIGHTS_CONTACT` at `:174`. **Keep** the `ENCRYPTION_ACTIVE_VERSION` / `ENCRYPTION_SECRET_V1` placeholders added at `:122`–`:125` — calendar OAuth refresh tokens need them too, and removing them breaks a fresh clone |
| `/Users/aman_01/Documents/inter/README.md` | 1 table row, **no code marker** | The `023_interview_presence_events.sql` row in the migration table at `:404`. Leave it if you keep the migration file (§4) |

### 3.3 Client (13 files)

| File | Hunks | Anchors |
|---|---|---|
| `/Users/aman_01/Documents/inter/inter/Networking/InterNetworkTypes.swift` | 2 | `:214` the three `InterRoomConfiguration` properties (`presenceMonitoring`, `candidateRegionEU`, `candidateUnder18`) with their `init` and `copy(with:)` lines; `:315` the three `meetingSettingsDict` keys |
| `/Users/aman_01/Documents/inter/inter/Networking/InterTokenService.swift` | 5 | `:45` the one `InterCreateRoomResponse.presenceMonitoringArmed` field and its defaulted `init` parameter; `:99` the eight `InterJoinRoomResponse` `presence*` fields and their defaulted `init` parameters; `:1046` the `/room/create` parsing line and the argument it passes; `:1181` the `/room/join` parsing block; `:1446` the five methods (`submitPresenceConsent`, `uploadPresenceEvents`, `fetchPresenceTimeline`, `submitPresenceNote`, `fetchPresenceExport`) and their three private helpers |
| `/Users/aman_01/Documents/inter/inter/Networking/InterRoomController.swift` | 7 | `:251` the `activePresence*` property block plus `recordPresenceConsent(granted:state:)`, `resetPresenceConsentForNewConnection()` (`:319`) and `applyPresenceSettingsFromScheduledMeeting(_:)` (`:331`); `:360` the `applyMeetingSettingsFromDict` mirrors (lobby-admitted path); `:482` the one-line `resetPresenceConsentForNewConnection()` call at the top of `connect(configuration:completion:)`; `:512` the scheduled branch's one-line `applyPresenceSettingsFromScheduledMeeting(r)` call; `:571` the `/room/create` branch's `activePresenceMonitoringArmed` / `RegionEU` / `Under18` assignments; `:619` the join-branch assignments; `:674` the one-line `resetPresenceConsentForNewConnection()` call at the top of `connect(withToken:serverURL:configuration:completion:)`. **Do not touch `preConnectConsentGate`'s signature** — it was never changed |
| `/Users/aman_01/Documents/inter/inter/App/AppDelegate.m` | 10 | `:206` the forward declarations; `:365` **the one `if` in the consent gate** (delete it and the legacy `NSAlert` path is the only path again); `:814` the post-join consent POST and the candidate chip in `-enterMode:`; `:833` the interviewer surface + 15 s poll start, also in `-enterMode:`; `:1961` and `:2028` the green-room toggle read and the back-out clear; `:2114` the three green-room toggles copied into `InterRoomConfiguration` in `-connectAndEnterMode:` (unconditional); `:2450` `-showPresenceConsentWithCompletion:` and `:2525` the surface start/stop methods; `:6745` the unconditional `[self stopPresenceSurfaces]` in `-teardownActiveWindows`. **`-showIntervieweeConfirmationWithCompletion:` is byte-for-byte unchanged — leave it alone** |
| `/Users/aman_01/Documents/inter/inter/UI/Controllers/SecureWindowController.h` | 1 | `:36` the `- (void)setPresenceMonitoringState:(NSInteger)state;` declaration and its doc comment |
| `/Users/aman_01/Documents/inter/inter/UI/Controllers/SecureWindowController.m` | 8 | `:56` `pendingPresenceState` + the `presenceCoordinator` property; `:166` the state setter; `:227` the details-panel presenter; `:399` `[self.presenceCoordinator stop]` in `-destroySecureWindow` (it must stay **before** the media shutdown while it exists); `:441` the details-panel teardown; `:535` the chrome wiring in `-attachControlPanelInView:`; `:607` **the one detector guard** in `-startLocalMediaFlow`; `:688` `-startPresenceMonitoringWithSession:queue:media:` |
| `/Users/aman_01/Documents/inter/inter/UI/SwiftUI/Screens/SecureCandidateChromeViewModel.swift` | 1 | `:45` `presenceMonitoringState` + `onOpenPresenceDetails` |
| `/Users/aman_01/Documents/inter/inter/UI/SwiftUI/Screens/SecureCandidateChromeViews.swift` | 1 | `:83` the `presenceBadge` chip and its reference in the top-bar `HStack` |
| `/Users/aman_01/Documents/inter/inter/UI/SwiftUI/Screens/InterSecureChromeBridge.swift` | 2 | `:54` `presenceDetailsHandler` (and its line in `invalidateHandlers()`); `:172` `setPresenceMonitoringState(_:)` |
| `/Users/aman_01/Documents/inter/inter/UI/SwiftUI/Screens/CallControlBarViewModel.swift` | 1 | `:144` the presence block: `presenceAvailable`, `presenceMonitoringEnabled`, `presenceLiveEventType`, `presenceTimelineVisible`, `setPresenceLiveEvent`, `presenceChipLabel`, `onOpenPresenceTimeline` |
| `/Users/aman_01/Documents/inter/inter/UI/SwiftUI/Screens/CallControlBarView.swift` | 1 — **marker spelled `PRESENCE MONITORING, provisional`** | `:190` `presenceChip`, `presenceChipIcon`, `presenceChipTint`, plus the `presenceChip` reference at `:138` and the `|| viewModel.presenceAvailable` clause at `:123` |
| `/Users/aman_01/Documents/inter/inter/UI/SwiftUI/Screens/InterCallControlBarBridge.swift` | 4 | `:28` the owned timeline view model; `:80` the handler block; `:162` the `invalidatePresenceHandlers()` line; `:287` the `NSPopover` timeline panel and the `NSSavePanel` CSV path |
| `/Users/aman_01/Documents/inter/inter/UI/SwiftUI/Screens/GreenRoomViewModel.swift` | 1 | `:92` the three interviewer toggles |
| `/Users/aman_01/Documents/inter/inter/UI/SwiftUI/Screens/GreenRoomView.swift` | 1 | `:417` the interviewer-only toggle rows |
| `/Users/aman_01/Documents/inter/inter/UI/SwiftUI/Screens/InterGreenRoomHostView.swift` | 1 | `:62` the `@objc` pass-through for the three toggles |

Nothing else in the client was modified. `InterLiveKitCameraSource.swift`,
`InterLocalMediaController.h/.m` (including `recordingFrameObserver`), `InterFeatureGate`,
`InterNetworkErrorCode`, `isExpectedJoinRejection`, `tiers.js` `FEATURES`, Socket.IO and the
LiveKit DataChannel are all untouched, so there is nothing to revert in them.

---

## 4. The migration — a manual operator step, because migrations are forward-only

**`/Users/aman_01/Documents/inter/token-server/migrate.js` is forward-only and has no
down-migration mechanism.** There is no `node migrate.js down`, no rollback file convention and no
reverse SQL anywhere in the repo. Each migration runs in its own transaction and is recorded by
filename in `schema_migrations`. Dropping the tables is therefore a **deliberate manual operator
action**, done in this order:

```sql
-- 1. Drop the three tables. CASCADE because notes reference events reference sessions.
DROP TABLE IF EXISTS interview_presence_notes,
                     interview_presence_events,
                     interview_presence_sessions CASCADE;
```

```sql
-- 2. ONLY if you also deleted migrations/023_interview_presence_events.sql.
DELETE FROM schema_migrations WHERE filename = '023_interview_presence_events.sql';
```

If you **keep** the `.sql` file, leave the `schema_migrations` row alone: the DDL is `IF NOT
EXISTS` throughout, so a re-run is harmless, and deleting the row while keeping the file would make
the next `node migrate.js` recreate the tables.

Nothing else in the schema is involved. Migration 023 is purely additive: it created exactly those
three tables plus their indexes and one `updated_at` trigger on the sessions table, and altered no
pre-existing table, column, constraint or row. After the drop, `SELECT count(*) FROM
schema_migrations` is 23 if you kept the file and 22 if you deleted the row, and `\dt` shows the 23
tables that existed before this feature.

---

## 5. `audit_events` presence rows CANNOT be deleted — and that is intentional

Migration `011_audit_events.sql` installs the trigger `audit_events_no_delete` backed by
`prevent_audit_modification()`, which blocks `UPDATE` **and** `DELETE` on `audit_events` at the
database. The eight presence event types —

`presence_consent_granted`, `presence_consent_declined`, `presence_monitoring_enabled`,
`presence_monitoring_disabled`, `presence_timeline_read`, `presence_note_added`,
`presence_export`, `presence_events_purged`

— therefore **stay in `audit_events` forever**, and no removal step can take them out. Attempting it
raises an exception rather than silently doing nothing.

**This is correct and nobody should discover it mid-removal.** Those rows are the record that
consent was asked for and given or refused, that a timeline was read, that an export happened. They
contain no note text, no email, no frame, no threshold free-text and no forbidden key — only the
room code, the ephemeral participant identity, counts and lengths. If the audit record of this
feature is genuinely unacceptable to keep, that is a conversation about `audit_events` as a whole
and its no-delete trigger, not a step in this recipe. Do not attempt to drop the trigger to get
around it.

---

## 6. Environment variables to unset

All seven are read at call time and all seven have safe defaults, so removing them is cosmetic once
the master flag is off — but leave none behind to confuse the next reader. In
`token-server/.env`, the deployment environment, and `token-server/.env.example`:

```
PRESENCE_MONITORING_ENABLED
PRESENCE_EVENT_RETENTION_DAYS
PRESENCE_MULTIPLE_FACES_ENABLED
PRESENCE_GAP_SECONDS
PRESENCE_SWEEP_INTERVAL_MS
PRESENCE_STALE_SESSION_MINUTES
PRESENCE_RIGHTS_CONTACT
```

`PRESENCE_NOTE_HMAC_KEY` was considered in the plan and **never used** — interviewer notes are
encrypted with the existing versioned `crypto.js` secrets (`ENCRYPTION_ACTIVE_VERSION`,
`ENCRYPTION_SECRET_V1`). If you find `PRESENCE_NOTE_HMAC_KEY` set anywhere, it is stale: unset it.
**Do not unset `ENCRYPTION_ACTIVE_VERSION` or `ENCRYPTION_SECRET_V1`** — calendar OAuth refresh
tokens and team chat depend on them.

---

## 7. Post-removal verification

Run from `/Users/aman_01/Documents/inter`. A zero exit code is not evidence; read the output.

```bash
# 1. Server tests green with the three presence test files deleted.
cd /Users/aman_01/Documents/inter/token-server && npm test
#    Expect: fail 0, and a total 80 tests lower than the 162 recorded on 2026-10-31
#    (presenceEvents 43 + presenceRetention 22 + presenceGate 17 = 82 removed).

# 2. Server still loads.
cd /Users/aman_01/Documents/inter/token-server && node -e "require('./index.js')" && curl -s localhost:3000/health

# 3. Client build.
cd /Users/aman_01/Documents/inter && xcodebuild build -project inter.xcodeproj -scheme inter \
  -configuration Debug -destination 'platform=macOS'
#    Expect the literal line "** BUILD SUCCEEDED **" and zero lines matching "error:".

# 4. Client tests.
cd /Users/aman_01/Documents/inter && xcodebuild test -project inter.xcodeproj -scheme inter \
  -configuration Debug -destination 'platform=macOS'
#    Expect no new failures. Four InterMultiParticipantIntegrationTests cases fail whenever no
#    token server is listening on localhost:3000 — that is pre-existing and unrelated.

# 5. No marker left anywhere.
grep -rn 'PRESENCE MONITORING' /Users/aman_01/Documents/inter/inter \
  /Users/aman_01/Documents/inter/token-server /Users/aman_01/Documents/inter/interTests
#    Expect: no output.

# 6. No presence symbol left. Read every hit; expect only unrelated words.
grep -rn 'resence' /Users/aman_01/Documents/inter/inter /Users/aman_01/Documents/inter/token-server \
  /Users/aman_01/Documents/inter/interTests \
  --include=*.swift --include=*.m --include=*.h --include=*.js
#    Known legitimate survivors, none related to this feature:
#      inter/UI/.../InterParticipantOverlayView  "Waiting/presence overlay" comment
#      the presence-driven tiles work (docs/superpowers/specs/2026-06-05-presence-driven-tiles-design.md)
#      any LiveKit participant-presence wording

# 7. Vision is gone from the client.
grep -rn 'import Vision' /Users/aman_01/Documents/inter/inter
#    Expect: no output.

# 8. Database.
psql "$DATABASE_URL" -c "\dt"
psql "$DATABASE_URL" -c "SELECT count(*) FROM schema_migrations;"
psql "$DATABASE_URL" -c "SELECT count(*) FROM audit_events WHERE event_type LIKE 'presence_%';"
#    Expect: no interview_presence_* table; 23 (file kept) or 22 (row deleted); and a non-zero
#    audit count that CANNOT be reduced — see §5.
```

No `git` command appears anywhere in this recipe, by design. Removal is a working-tree edit; the
commit is yours.
