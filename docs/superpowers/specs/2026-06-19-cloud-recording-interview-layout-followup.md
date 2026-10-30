# Follow-up: Cloud Recording Layout for Interview Mode (deferred)

Status: **DEFERRED** — to be resumed after the local-recording interview layout ships.
Parent design: `2026-06-19-interviewer-collaborative-tools-design.md`

## Why this is parked
We are completing the **local** recording layout for interview mode first (the composited
Speaker/Grid mirror with the tool as a first-class source). Cloud recording will be
revisited afterward. This note captures the full discussion so we can resume without
re-deriving it.

## Facts established (current code)
- Cloud recording is **already implemented** as server-side **LiveKit Egress**
  (`token-server/index.js`, `POST /room/record/start`), with quota enforcement
  (`recordingQuota.js`, overdue sweeper) and an egress webhook.
- Two modes today:
  - `cloud_composed` → `egressClient.startRoomCompositeEgress(room, { file, layout: 'speaker', preset: H264_1080P_30 })`. **`layout` is hardcoded to `'speaker'`.**
  - `multi_track` → `startParticipantEgress(..., { screenShare: true })` (per-participant tracks).
- Request body: `{ roomCode, callerIdentity, mode, estimatedDurationMinutes }` — **no layout field**, so the recorder cannot currently choose Grid vs Speaker for cloud.
- Egress composes **published tracks** server-side (headless browser). It **cannot** run our local Metal compositor (`InterComposedRenderer`) and **cannot** `cacheDisplayInRect` a local view.

## Key conclusion
- The **source** is shareable across local + cloud: if the candidate publishes the tool
  snapshot as a **screen-share track while a tool session is active**, then local
  recording composites it our way AND cloud egress records/composes it.
- The **composition (layout) is NOT automatically the same**: local = our Metal compositor
  (full Speaker/Grid + tool-tile mirror); cloud = LiveKit's template layout. So by default
  cloud will look related but not identical (tool appears as the main screen-share feed).

## Three ambition tiers for cloud layout (decide later)
1. **As-is:** fixed `'speaker'` template (no recorder choice). Smallest.
2. **Grid/Speaker selector (small add):** thread a validated `layout` field
   (`'grid'` | `'speaker'` | `'single-speaker'`) through `/room/record/start` →
   `startRoomCompositeEgress`. Gives the recorder a real choice using LiveKit's built-in
   templates (still not our custom tool-tile composition).
3. **Full match (large):** a **custom egress web layout template** that reproduces our exact
   interview composition (Speaker = tool main; Grid = participants + a tool tile). Server-side
   web layout to build/host/version. OR publish our local composed output as a single track
   and `startTrackEgress` of it (pixel-identical, but a client must continuously publish the
   composed 1080p track and stay online).

## Open question to resume on
- Do we want the **Grid/Speaker selector for cloud** (tier 2) and/or the **full custom-layout
  match** (tier 3)? Local recording keeps the auto Speaker/Grid mirror regardless.

## Pointers
- Server: `token-server/index.js` `/room/record/start` (~line 3918+), `recordingQuota.js`.
- Local compositor: `inter/Media/Recording/InterComposedRenderer.{h,m}` (already has
  `InterComposedLayoutGrid`, `ScreenShareFilmstrip`, `ScreenSharePiP`, participant-tile APIs).
- Tool snapshot source: `inter/Media/Sharing/Sources/InterViewSnapshotVideoSource.m`
  (`cacheDisplayInRect:` of an NSView — reusable for the interviewer's tool host).
