# Design: Interviewer-Side Collaborative Tools, Interview Recording Layout, and Tool UX Improvements

Date: 2026-06-19
Status: **DESIGN — awaiting review**
Related: completes integration intent of `.kiro/specs/collaborative-code-editor` and
`.kiro/specs/collaborative-whiteboard` (their Requirement 2 — two-way collaboration).
Cloud-recording follow-up: `2026-06-19-cloud-recording-interview-layout-followup.md`

## 1. Problem

The collaborative code editor and whiteboard are CRDT-synced and were specced as **two-way**
("interviewer and candidate edit the same board... both render natively"). But the
collaborative tool surface is mounted **only** in the candidate's secure kiosk
(`AppDelegate.m`, gated by `isIntervieweeMode` → `SecureWindowController.createSecureWindow`).
The **interviewer runs in normal mode and never mounts the tool**, so:
- the interviewer has no native surface to view/edit the shared doc;
- the interviewer's client never registers `codeEditorController` / `whiteboardController`,
  so the candidate's CRDT ops have no receiver and are dropped;
- the interviewer only ever sees the candidate's tool as a **one-way screen-share video**.

This contradicts the spec and is why the manual two-client test (whiteboard task 13.3) was
never completed. This design wires the interviewer side and defines the shared-session UX,
the interview recording layout, and a set of tool UX fixes raised during testing.

## 2. Goals / Non-goals

**Goals**
- Mount the collaborative tool natively on the interviewer's normal-mode UI so both sides
  edit the same CRDT document and render crisply.
- Define a coherent, symmetric "tool session" UX with explicit per-side control.
- Make the **local** interview recording mirror the tool/camera layout (Speaker/Grid).
- Fix five tool UX issues found in testing.

**Non-goals (this feature)**
- Cloud-recording layout parity (deferred — see follow-up doc).
- WKWebView-hosted tools (rejected: out-of-process content can't be captured by the
  in-process `cacheDisplayInRect:` pipeline and conflicts with capture-exclusion).
- Candidate-side filmstrip-swap parity is a **flagged decision** (§9), not assumed.

## 3. Shared-session model (symmetric)

There is ONE CRDT document per tool (Code, Board) per interview, living for the whole call
(already true). Both sides edit it; edits always merge (RGA for code, LWW for board).
"Opening/closing" controls the **surface presence on each side**, not the content.

- **Trigger (Option A):** the candidate's explicit **Share** action publishes/surfaces the
  tool to the interviewer; the interviewer may also pre-author (e.g., write a question) by
  opening the tool first. Whoever opens sees the current doc (snapshot recovery). Edits
  merge — no special-casing for "already open" or "already has content".
- **No auto-open.** When one side has content the other hasn't opened, the other learns via
  a **badge/dot on the Code/Board control-bar button** (Option B for awareness). Opening is
  always a deliberate click.

## 4. Per-side tool lifecycle

Each side independently moves a tool through these states (the doc stays live throughout):

- **Inactive** — not on this screen. Control-bar button idle (may carry an activity badge).
- **Open (editable)** — native surface on the **main stage**; forces **Stage** layout
  (cameras → filmstrip). Reached ONLY via the control-bar Code/Board button.
- **Tile (read-only)** — collapsed into a **live, read-only tile** (native mini-render of the
  shared doc; updates as the peer edits). Sits in the filmstrip (Stage) or as a grid cell (Grid).
- **Dismissed** — from the tile's **⋯ → Close**, the tile is removed entirely. Session stays
  active for the other side.

**Transitions / rules**
- Editable ⇄ Tile happens **only via the control bar** (clicking a tile never opens the
  editable surface).
- Clicking a **camera** tile while the tool is Open **auto-collapses** the tool to a
  read-only Tile and spotlights the camera; re-open via the control bar.
- The tool **Tile is a first-class, swappable tile**: it can be spotlighted to the main
  stage as a **read-only** big view and reordered in the filmstrip, exactly like a camera
  tile. (Two independent dimensions: *Edit mode* = control-bar only; *Placement* = spotlight/
  filmstrip like any tile.)
- **Grid ⇄ Stage** stays user-toggleable (existing `gridLayoutEnabled`); the preference is
  remembered and **restored when the tool closes**. Opening a tool forces Stage.
- Tool switch (Code↔Board): each doc persists independently; reopening shows current state.

## 5. Architecture / components

Reuse the candidate's self-contained pieces on the interviewer's normal window.

- **Mount:** in `AppDelegate -launchNormalCallWindow`, when
  `currentCallMode == Interview && currentInterviewRole == Interviewer && roomController.isHost
  && localParticipantHasToolsEntitlement`, instantiate an `InterSecureToolHostView` as a
  subview of the call window content (framed to the main stage, hidden by default), and after
  connect call `configureCollaborationWithRoomController:self.roomController`. This registers
  the interviewer's `codeEditorController`/`whiteboardController` on the shared
  `InterRoomController` → the CRDT converges with the candidate. Teardown mirrors the
  candidate's (`invalidateHandlers` on mode exit / `teardownActiveWindows`).
- **Control bar:** add to `CallControlBarViewModel` (`selectedToolKind`, `onSelectTool`,
  `interviewToolsVisible`, badge state), `CallControlBarView` (a Code/Board segmented control,
  shown only when `interviewToolsVisible`), and `InterCallControlBarBridge`
  (`interviewToolChangedHandler`, `setInterviewToolsVisible:`, `setSelectedInterviewToolKind:`,
  `setToolBadge:` — the candidate chrome already has the first three). In
  `-attachNormalCallControlsInView:`, gate visibility on the interviewer condition and route
  the handler to a new `-handleInterviewerToolSelection:` (reusing the same server-`tools`-flag
  entitlement gate fixed earlier).
- **Layout integration:** `InterRemoteVideoLayoutManager` already supports Grid/Stage,
  spotlight/swap, filmstrip, and a `supplementalFilmstripView` seam. The tool host participates
  as the spotlightable main-stage surface (Open) and as a tile (read-only) via that system.
- **No interviewer publish:** the interviewer renders natively; it does NOT publish a tool
  video. (Publishing stays the candidate's job — §7.)

## 6. Local recording layout (this feature)

The local recorder is the interviewer/host (`InterRecordingCoordinator` →
`InterComposedRenderer` (Metal) → `InterRecordingEngine`). The compositor **already** has
`Grid`, `ScreenSharePiP`, `ScreenShareFilmstrip`, side-by-side, and participant-tile APIs —
so **no new Metal layout** is needed.

- The **tool is one more snapshot source**: `cacheDisplayInRect:` on the interviewer's native
  tool host (same mechanism as the candidate's `InterViewSnapshotVideoSource`, proven safe for
  SwiftUI surfaces by `CaptureFidelitySpikeTests`).
- **Speaker mode:** tool → `updateScreenShareFrame:` → existing `ScreenSharePiP`/`Filmstrip`
  layout (tool main, participant PiP/filmstrip).
- **Grid mode:** tool → `updateParticipantFrame:identity:"__tool__"` + `setParticipantOrder`
  (+ `setDisplayName:` "Code"/"Whiteboard") → existing `Grid` layout (tool as a tile).
- **Driven by** the recorder's (interviewer's) own live layout — no cross-side state sync.
- **Trigger:** include the tool while a **tool session is active** (stable; not the volatile
  "editable focus on any side", which would flap and drop the tool during read-only
  discussion). A small **debounce** smooths rapid focus/collapse toggles. No session →
  today's camera-only behavior.

## 7. Unified tool source (local now, cloud later)

The candidate publishes the tool snapshot as a **screen-share track while a session is active**
(the existing `InterViewSnapshotVideoSource`, triggered by "session active" instead of the old
Share button). This single source feeds local recording today and is what cloud egress will
consume later (see follow-up doc). It also serves any non-collaborating viewer.

## 8. Tool UX improvements (raised in testing)

Native fixes, grounded in how the OSS tools behave:
1. **Editor: highlight functions + subscripts** (`CodeSyntaxHighlighter.swift`). Add token
   categories: identifier immediately followed by `(` → **function call**; `()[]{}` and
   operators → **punctuation**. Add two theme colors. (highlight.js/CodeMirror heuristic.)
2. **Editor: auto-closing brackets** (`CodeEditorTextView.swift`). CodeMirror `closeBrackets`
   semantics: pairs `() [] {} "" ''`; type opener → insert closer, caret between; type closer
   when next char is the just-inserted closer → skip; backspace in empty pair → delete both.
   Hook `textView(_:shouldChangeTextIn:replacementString:)`; auto-inserted chars flow through
   the same local-edit path so they sync over the CRDT.
3. **Whiteboard: commit text on click-outside** (`SecureWhiteboardTextField.swift` /
   `WhiteboardRootView.swift`). Today only Escape commits. Add first-responder-resign /
   `windowDidResignKey` (and/or commit-on-new-pointer-gesture) → `onCommit()`. (Excalidraw
   commits on blur.)
4. **Whiteboard: colored text edits show in white** (`SecureWhiteboardTextField.makeNSView`).
   The edit field hardcodes white and never reads `existing.strokeColor`. Add a color param,
   set `textView.textColor` from the element's color, seed it on re-open. Model already
   preserves color on commit — this is purely the overlay.
5. **Whiteboard: toolbar size inconsistency** (`WhiteboardRootView.swift` `chrome(_:active:)`).
   Buttons size to label with no min width → "Ellipse"/"Eraser" wrap. Add `.fixedSize()` +
   a uniform `.frame(minWidth:)`.

## 9. Entitlement / security / open decisions

- **Entitlement:** in-room tool availability is gated solely on the server-signed `tools` JWT
  flag (keyed on the room creator's tier) — already fixed. The interviewer (hiring host) is
  entitled.
- **Capture protection:** the normal window already sets `sharingType = InterWindowSharingType()`.
  Tools are native (no WKWebView), so the in-process capture/exclusion model is unchanged.
- **Open decisions to confirm during planning:**
  - **Candidate-side filmstrip-swap parity** — should the candidate's secure stage gain the same
    spotlight/swap behavior, or keep its current tool-owns-center layout? (Default: bring parity.)
  - **Badge specifics** — dot vs count; clear-on-open.
  - **Cloud-recording layout** — deferred (follow-up doc): as-is `'speaker'`, a Grid/Speaker
    selector, or full custom-layout match.

## 10. Testing

- **Unit:** control-bar VM tool-state + entitlement gating; tool lifecycle transitions
  (open/tile/dismiss/auto-collapse); highlighter (function/subscript tokens); auto-bracket
  pair/skip/delete; whiteboard commit-on-blur and color seeding; toolbar sizing snapshot.
- **Integration:** interviewer mounts controllers → CRDT round-trips with candidate; recording
  composer includes the tool as main (Speaker) and as a `__tool__` tile (Grid); session-active
  trigger + debounce.
- **Manual two-client:** the long-outstanding whiteboard 13.3 / editor 11.3 — interviewer and
  candidate edit live, both render natively, recording reflects the layout.
- Build clean (`xcodebuild build`), run the SecureTools + recording suites, `npm test` for the
  shared tier gate.
