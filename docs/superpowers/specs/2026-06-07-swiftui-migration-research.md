# SwiftUI Migration — Deep Research & Architecture Impact Analysis

**Date:** 2026-06-07
**App:** `inter` (macOS video-calling / secure-interview platform)
**Author:** Research conducted with skills: `brainstorming`, `paranoid-implementation` (Implement-mode Phase 1+2), `decision-council`
**Status:** Research / decision document — **no code changed.** Implementation gated on approval.

---

## 0. How to read this document

This is an analysis, not a plan. It answers one question the user asked:

> *"How will shifting our UI/UX from Objective-C to SwiftUI affect the app's architecture and functionality — without sacrificing core logic, security policies (e.g. `NSWindowSharingNone`), or flow?"*

It ends with a **committed verdict** (decision-council) and a list of **spikes that must pass before any migration code is written.** The actual implementation plan is a separate document (`writing-plans`).

---

## 1. Executive summary

1. **The migration is feasible and low-risk *if and only if* it is done as a hybrid:** AppKit keeps owning every `NSWindow` (and therefore every security property), while SwiftUI is hosted *inside* those windows via `NSHostingController`. This is the user's chosen **Scope B**, and the research backs it.

2. **Your core is already migration-ready.** `Networking/` and `Media/` are isolated behind an explicit `[G8]` invariant and never call UI. The UI talks to them through KVO, delegates, and completion blocks. None of that has to change.

3. **The `NSWindowSharingNone` control already does exactly what your threat model needs — and the migration preserves it.** Despite Apple's "legacy constant" doc-string, the flag's *relied-upon* behavior is correct and sufficient: it excludes the window's content from **third-party** capture/record/stream/overlay tools (OBS, Zoom, Meet, Bandicam, screenshot utilities) — the tools an interviewee would use to exfiltrate questions or cheat. It deliberately does **not** block macOS's own privileged recorder (Cmd-Shift-5 / `screencapture`), which is **explicitly out of scope and accepted**. Under Scope B the flag stays on the same AppKit `NSWindow`, so this is byte-for-byte preserved. The genuinely migration-specific concern is sharper: **SwiftUI auxiliary windows (popovers, menus, sheets) are *new* `NSWindow`s that do not inherit the sharing type** and must be audited in secure mode (Finding S-A6). Reclassified as **Finding S-0 (Low / accepted)** below.

4. **Your two stated goals are the cheapest, highest-value slice.** The code editor and whiteboard are leaf views captured through an `NSView`-hierarchy snapshot. Because `NSHostingView` *is* an `NSView`, SwiftUI replacements drop into the existing capture pipeline — **subject to one capture-fidelity spike** (`cacheDisplayInRect:` vs GPU-backed SwiftUI).

5. **The expensive part is the monolith, and Scope B lets us avoid it for now.** `AppDelegate.m` (~6000 LOC, 20+ delegate protocols) and `InterMediaWiringController` (couples UI+media+networking) are the real cost of a *full* rewrite. Scope B keeps them as the AppKit "shell" and migrates *content*, so we never have to detonate the monolith to ship value.

6. **Code-editor library verdict:** build a **thin custom `NSViewRepresentable` over TextKit 2** with a permissively-licensed Tree-sitter highlighter for the *secure* editor; do **not** adopt a JavaScriptCore-based highlighter or a GPL-3.0 component in the closed-source kiosk path. Details in §9.

---

## 2. Locked scope & constraints (from brainstorming)

| Decision | Outcome |
|---|---|
| **Scope** | **B — Hybrid incremental.** AppKit windows + shell + video-tile grid stay **(deferred, not forbidden — see §6.1)**; content panels + interview tools migrate to SwiftUI behind `NSHostingController`, screen-by-screen, reversibly. |
| **Canvas** | **A now** — richer *single-user* tools (shapes, colors, eraser, undo/redo, text), still rendered locally and streamed as video. Real-time collaborative whiteboard = **separate future spec**, explicitly out of scope. |
| **Code editor** | Research threat-models candidates and recommends (see §9). Must preserve the *literal-code-integrity* invariant (smart quotes / autocorrect / autocomplete disabled). |
| **Deployment** | macOS **15.6**, Swift 5.0, **zero existing SwiftUI** (greenfield). Favorable: full modern SwiftUI stack available. |
| **Hard constraints** | Do not sacrifice: core call/media logic; `NSWindowSharingNone` + secure-window guarantees; kiosk restrictions; external-display policy; screen-share permission policy; app flow/teardown. |

---

## 3. Current architecture (condensed)

### 3.1 Layering and isolation
- **`Networking/` (Swift)** — `InterRoomController`, `InterLiveKitPublisher/Subscriber`, moderation/chat/poll/Q&A controllers. Governed by **`[G8]` isolation invariant**: side-effect-free, never imports AppKit, never calls UI/media/recording directly. State flows *outward* only.
- **`Media/` (ObjC+Swift)** — `InterLocalMediaController`, `InterSurfaceShareController`, recording engine, share sources. Near-pure device/frame control. One AppKit leak: `attachPreviewToView:(NSView *)`.
- **`UI/` (ObjC, ~54 files)** — panels, layout managers, indicators, the secure window. NSView/NSWindow throughout.
- **`App/`** — `AppDelegate` (mega-orchestrator), `InterMediaWiringController` (the UI⇄media⇄network bridge), `InterCallSessionCoordinator` (pure state machine, fully decoupled).

### 3.2 How UI talks to core (the seam we must preserve)
| Mechanism | Direction | Example |
|---|---|---|
| **KVO** on `@objc dynamic` Swift props | Swift → ObjC UI | `connectionState`, `participantPresenceState`, `activeSpeakerIdentity`, `remoteParticipantCount` |
| **Delegates** (protocols) | bidirectional | `InterMediaWiringDelegate`, `InterModerationDelegate`, panel delegates |
| **Completion blocks** | async results | `setCameraEnabled:completion:` |
| **Weak property wiring** | init-time | `AppDelegate` wires media/room/UI together |
| **NSNotification** | ObjC ↔ ObjC only | app activation, fullscreen exit |

**Key fact:** the networking layer exposes everything SwiftUI needs as `@objc dynamic` KVO properties. SwiftUI can observe these through a thin adapter (see §5.2) without the core knowing SwiftUI exists.

### 3.3 The hardest knots (why *not* full rewrite now)
- `AppDelegate.m` ~6000 LOC, implements 20+ delegate protocols, owns ~90 properties, drives all window lifecycle and mode transitions.
- `InterMediaWiringController` couples `InterLocalMediaController` (media) + `InterLocalCallControlPanel` (UI) + `InterRoomController` (network) and hosts the **two-phase camera/mic state machine** (`[G2]` mute-track-first ordering).
- `InterRemoteVideoLayoutManager.m` ~1100 LOC — imperative tile layout engine (grid/filmstrip/spotlight/pagination/badges).

---

## 4. Finding S-0 (LOW / accepted): `NSWindowSharingNone` scope is understood and sufficient

**Correction (owner threat-model input, 2026-06-07).** The original draft over-alarmed on Apple's "legacy constant" doc-string. The *observed, relied-upon* behavior — confirmed by the project owner — is precise and adequate for this product:

| Capture source | Blocked by `NSWindowSharingNone`? | In threat model? |
|---|---|---|
| Third-party recorders / streamers (OBS, Zoom, Meet, Bandicam, …) | **Yes** — content excluded / black | ✅ **Primary threat** (interview exfiltration / cheating) |
| Third-party screenshot & overlay-capture utilities | **Yes** | ✅ Primary threat |
| macOS native recorder (Cmd-Shift-5 / `screencapture`, screen-recording TCC) | **No** | ❌ **Out of scope — accepted** |

**Why this is acceptable for `inter`.** The anti-cheating goal is to stop **third-party tools** from reading the secure interview surface. Against that adversary the flag does its job. macOS's own privileged recorder is *not* part of the threat model, so its ability to capture is an **accepted residual**, not a defect.

**Where the app sets it (all via `setSharingType:NSWindowSharingNone`):**
- `setupWindow` — `AppDelegate.m:655`
- `normalCallWindow` — `AppDelegate.m:2013`
- `settingsWindow` — `AppDelegate.m:5385`
- `teamsWindow` — `AppDelegate.m:5582`
- `accountWindow` — `AppDelegate.m:5628`
- **`secureWindow`** — `inter/UI/Controllers/SecureWindowController.m:75` *(interviewer surface not readable by third-party tools)*

**Migration impact: none, with one sharpened caveat.** Under Scope B the flag stays on the same AppKit `NSWindow`, so the protected behavior is preserved byte-for-byte; rendering SwiftUI content *inside* that window via `NSHostingView` does **not** change window-level capture exclusion (SwiftUI draws into the same window backing store, in-process). **The real migration-specific risk is auxiliary windows** — see **S-A6**.

> **S-A6 (Finding, Medium) — SwiftUI auxiliary windows do not inherit `sharingType`.** SwiftUI readily spawns *separate* `NSWindow`s for `.popover`, `.sheet`, `Menu`, `.contextMenu`, alerts, and detached panels. Each is a brand-new window that defaults to shareable. If any such surface appears in secure/interview mode with sensitive content, it becomes a **third-party-capture leak the main window's flag does not cover.** *Mitigation:* in secure mode prefer in-window SwiftUI presentation (custom overlays inside the hosting view) over framework popovers/sheets; if a separate window is unavoidable, set `NSWindowSharingNone` on it at creation; add a test/audit that enumerates live `NSWindow`s during an interview and asserts every one has `sharingType == .none`.

**Distinguish two different "overlay" threats (honest scope note).** `NSWindowSharingNone` stops a third-party app from **reading** `inter`'s content. It does **not** stop a third-party app from **drawing its own overlay on top of** `inter` (e.g. a translucent notes/teleprompter window). That injection vector is mitigated separately — and only partially — by the secure window's `NSScreenSaverWindowLevel`, kiosk restrictions, and the single-display policy, not by `sharingType`. No migration change here; noted for completeness.

**Optional one-time confirmation (non-blocking).** A cheap sanity check on macOS 15.6 — capture the secure window with a third-party ScreenCaptureKit tool and confirm it is still excluded — is worth doing once, but is **not a blocker** and **not migration work**.

---

## 5. Target architecture — Hybrid (Scope B)

### 5.1 The shape
```
NSApplication / AppDelegate (AppKit) ─ owns lifecycle, mode transitions
  └─ NSWindow (AppKit)  ← ALL security props live here: sharingType, level,
        │                  styleMask, movable, kiosk behavior, occlusion
        └─ contentViewController = NSHostingController<SomeSwiftUIScreen>
              └─ SwiftUI view tree (content only)
                    └─ observes core via @Observable adapter over KVO
                    └─ calls core via existing ObjC methods / completion blocks
```
**Rule:** SwiftUI never owns a window. Every `NSWindowSharingNone`, `NSScreenSaverWindowLevel`, `NSWindowStyleMaskBorderless`, `setMovable:NO`, and kiosk call stays byte-for-byte where it is. SwiftUI is strictly *content*.

### 5.2 The bridge pattern (greenfield — this is the pattern the first screen sets)
A thin, testable adapter republishes existing `@objc dynamic` KVO as SwiftUI-observable state, on the main actor:

```swift
@Observable @MainActor
final class RoomViewModel {
    private(set) var connectionState: InterRoomConnectionState = .disconnected
    private(set) var presence: InterParticipantPresenceState = .alone
    private(set) var activeSpeaker: String = ""
    private var observers: [NSKeyValueObservation] = []

    init(room: InterRoomController) {
        observers = [
            room.observe(\.connectionState, options: [.initial]) { [weak self] r,_ in
                Task { @MainActor in self?.connectionState = r.connectionState } },
            // …presence, activeSpeaker, remoteParticipantCount
        ]
    }
}
```
- **Source of truth stays in the core.** The view model is a *projection*, never an authority. This is the antidote to the duplicate-toggle race (§10, F-C1).
- **Actions call existing methods**, they do not re-implement logic: a SwiftUI mic button calls `mediaWiring.twoPhaseToggleMicrophone()`; it does **not** drive a SwiftUI `Bool` binding that flips the track.

### 5.3 Migration seam map (what moves, what stays)
| Component | Scope-B disposition |
|---|---|
| `NSWindow` creation + all security props (`AppDelegate`, `SecureWindowController`) | **STAYS AppKit** |
| Kiosk restrictions, external-display monitor | **STAYS AppKit** |
| `InterMediaWiringController` (`[G2]` state machine) | **STAYS** (source of truth); SwiftUI reflects it |
| `InterRemoteVideoLayoutManager` (tile grid) | **STAYS** for now — hot path, imperative, ~1100 LOC; the video *surface* can never be pure SwiftUI (see §6.1); revisit post-B |
| Capture pipeline (`InterViewSnapshotVideoSource`, `InterSurfaceShareController`) | **STAYS**; capture source becomes an `NSHostingView` (spike-gated) |
| Content panels: login, account, schedule, chat, polls, Q&A, lobby, recording list, control panel | **MIGRATE** to SwiftUI behind `NSHostingController`, lowest-risk first |
| Interview **code editor** + **whiteboard** | **MIGRATE** (user's goals) — see §9 |

---

## 6. Impact on architecture (by layer)

| Layer | Impact | Net |
|---|---|---|
| `Networking/` (Swift) | **None.** Already SwiftUI-friendly via KVO. `[G8]` untouched. | ✅ Zero risk |
| `Media/` (ObjC) | **Minimal.** `attachPreviewToView:(NSView *)` still works — `NSHostingView` is an `NSView`. Optional later: a `PreviewAttachable` protocol. | ✅ Low |
| Capture pipeline | **Contained.** Same source/sink; capture *target* becomes a hosting view. One fidelity spike. | ⚠️ Spike-gated |
| `App/` orchestration | **Additive.** New `NSHostingController`s slot into existing window content. The monolith shrinks opportunistically as panels move out, but is **not** required to be decomposed. | ✅ Controlled |
| `UI/` panels | **Replaced incrementally.** Each migrated panel deletes an ObjC file and its delegate plumbing once parity is verified. | ✅ Reversible |
| Build/deps | New SwiftUI code + possibly one SPM dependency. Supply-chain review required (§9, §10 S-A2). | ⚠️ Governed |

**Architectural verdict:** Scope B is **additive and reversible**. At no checkpoint is the app in a non-working state, and at no checkpoint is a security invariant relocated off its `NSWindow`.

### 6.1 Why the video grid stays AppKit — and what "SwiftUI video" actually means

*(Answering a natural question: "why not make the video SwiftUI too?")*

**Three things get conflated under "make the video SwiftUI":**

| Axis | Today | Verdict |
|---|---|---|
| **Language** | The video *surfaces* are **already Swift** — `InterRemoteSampleBufferView`, `InterRemoteVideoView`. Only the *layout manager* (`InterRemoteVideoLayoutManager`, ~1100 LOC) is ObjC. | already Swift ✅ |
| **Framework** | Both surfaces are **AppKit** `NSView`s (layer-backed). | the part in question |
| **Pixel path** | `AVSampleBufferDisplayLayer` (camera) + `CAMetalLayer` (screen share). | Core Animation / Metal |

**The decisive fact: there is no pure-SwiftUI video surface.** SwiftUI has no primitive that renders decoded `CMSampleBuffer`/`CVPixelBuffer` frames. To show live video in SwiftUI you wrap an `AVSampleBufferDisplayLayer`/Metal-backed `NSView` in `NSViewRepresentable`. So "SwiftUI video" = **SwiftUI laying out the same AppKit layer views you already have** — the pixels never leave Core Animation/Metal. You don't gain a renderer; you gain a declarative *container*.

**So the real question is narrower — should the tile *layout* be SwiftUI?** Technically yes; it is **deferred, not forbidden**, for four concrete reasons:

1. **It's the hot path.** Frames arrive at 30–60 fps × N participants and are enqueued **straight into the layer** (`enqueue(_:)`), deliberately bypassing any declarative cycle. Today there is zero SwiftUI overhead between "frame decoded" and "pixel on screen." A SwiftUI version would still enqueue into the same layer — wrapped in a representable — gaining nothing on the pixel path while inserting diffing risk.
2. **`NSViewRepresentable` lifecycle is hostile to these layers.** SwiftUI freely tears down/recreates representables on state/identity changes, but `AVSampleBufferDisplayLayer` and `CAMetalLayer` are sensitive to detach/reattach — the code already guards against `.failed` status on rapid mute/unmute and against the `CAMetalLayer` being released during teardown. With a dynamic participant count, keeping `.id()` identity stable enough to avoid black-flashes/frame-drops is finicky and regression-prone.
3. **~1100 LOC of working, subtle behavior.** Active-speaker borders, co-host/muted/locked badges, pagination, spotlight/pin swapping, presence states, and tile-recycling pools all live in the layout manager — a lot of battle-tested logic to re-derive declaratively, in the most-watched surface of the app.
4. **Lowest aesthetic ROI.** The "professional look" comes from the *panels* and the *interview tools* (rich declarative content where SwiftUI shines). A video grid is dark rounded rectangles with overlays; SwiftUI barely moves the needle there while carrying the most risk.

**It is reversible later.** If a concrete need appears (e.g. fluid animated tile transitions, reaction overlays easier to express declaratively), the path is clean: keep `InterRemoteSampleBufferView`/`InterRemoteVideoView` *exactly as-is*, wrap each in an `NSViewRepresentable`, and rebuild **only** the layout in SwiftUI. The pixel path — and the recording compositor, which reads frames from the *sources*, not these views — is unaffected. That is why the rollout (§12) parks it dead-last.

### 6.2 Adding interactivity (hover, menus, controls) to tiles — "stays AppKit" ≠ "frozen"

*(Answering: "how do we add hover-based interaction or other tile functionality in Swift?")*

A tile is **two stacked layers**, and only the bottom one is pinned to AppKit:

```
CHROME  (interactive)  → name, badges, hover menu, tap-to-spotlight, reactions  → CAN be SwiftUI today
PIXEL SURFACE (passive) → AVSampleBufferDisplayLayer / CAMetalLayer            → stays AppKit
```

The grid already does rich hover today in ObjC — `InterRemoteVideoTileView` uses an `NSTrackingArea` for hover, a three-dot moderation menu shown on hover (host mode), click-to-spotlight, and hand-raise / mic-muted / co-host / camera-locked badges. Keeping the grid in AppKit therefore costs **zero** interactivity. Three ways to add Swift interaction, no layout-manager migration required:

1. **Swift, still AppKit (1:1 port).** Keep `NSTrackingArea` + `mouseEntered:`/`mouseExited:`, written in Swift. No new concepts; use it to merely translate existing behavior.
2. **SwiftUI overlay per tile (recommended for new rich chrome).** Add an `NSHostingView` **above** the video layer that owns **all** interaction; the video layer below becomes passive pixels. You get `.onHover`, `Menu`, SF Symbols, animated transitions, reaction overlays — while frames keep flowing into the `AVSampleBufferDisplayLayer` untouched.

   ```swift
   struct TileOverlay: View {
       let model: TileModel; var onSpotlight: () -> Void; var onPin: () -> Void
       @State private var hovering = false
       var body: some View {
           ZStack(alignment: .topTrailing) {
               Color.clear.contentShape(Rectangle()).onTapGesture(perform: onSpotlight)
               if hovering && model.isHostControls {
                   Menu { Button("Pin for All", action: onPin) }
                       label: { Image(systemName: "ellipsis.circle.fill") }.padding(8)
               }
               TileBadges(model: model); TileNameLabel(model: model)
           }
           .onHover { hovering = $0 }
           .animation(.easeInOut(duration: 0.15), value: hovering)
       }
   }
   // AppKit tile: overlay sits on top of the video layer
   let overlay = NSHostingView(rootView: TileOverlay(model: m, onSpotlight: …, onPin: …))
   overlay.frame = bounds; overlay.autoresizingMask = [.width, .height]; addSubview(overlay)
   ```

   **Caveat — hit-testing:** a frame-filling `NSHostingView` intercepts mouse events, so let the **SwiftUI overlay own *all* interaction** (including the spotlight tap); never split interaction between the overlay and the layer below, or you get click-through ambiguity.
3. **Full SwiftUI tile (later).** When the layout itself migrates (§6.1, deferred), the surface is wrapped in `NSViewRepresentable` and the same overlay code becomes a native subview.

**Takeaway:** the AppKit constraint applies only to raw video *pixels*. Every interactive affordance on a tile — hover, menus, buttons, reactions, labels — is available in Swift/SwiftUI now via a per-tile hosting overlay, independent of the deferred layout migration.

### 6.3 Making the existing AppKit tile chrome industry-level — *without* SwiftUI

*(Answering: "can we make the per-tile controls professional and SwiftUI-consistent while staying in AppKit? The current ones look AI-vibe-coded.")*

**Decision-council verdict: ENDORSED — polish now, in pure AppKit; do not defer.** The current per-tile controls look amateur because of **design execution, not the framework** — SwiftUI would not have prevented any of it. This is **low-risk and independent of the migration** because the remote tiles are **local-display-only**: in interview mode the captured/streamed surface is `toolCaptureHostView`, added *below* `remoteLayoutManager` (`InterSecureInterviewStageView.m:289`); the tile grid is **never** in the capture path. So tile-chrome polish carries **zero capture / security / streaming risk**.

**Why it's safe *and* durable.** Local-only → nothing leaks, nothing can break the snapshot. And the expensive, durable part — SF Symbol choices, color palette, radii/spacing tokens (the actual *design language*) — transfers **1:1** to SwiftUI later; only the AppKit plumbing (`NSStackView`/`CABasicAnimation` glue) is discarded if the tile ever goes full-SwiftUI (§6.1, deferred). So "throwaway" is limited to trivial wiring.

**What reads as "vibe-coded" today → the industry-level fix (all native, macOS 15.6):**

| Tell in the current code | Why it looks amateur | Pure-AppKit fix |
|---|---|---|
| **Emoji as icons** — `✋ 🔇 👑 🔒` as `NSTextField` strings | Render differently per OS, can't be tinted/weighted, never align optically (**the #1 giveaway**) | **SF Symbols** (`hand.raised.fill`, `mic.slash.fill`, `crown.fill`, `lock.fill`) via `NSImage(systemSymbolName:)` + a symbol configuration (size/weight/palette) |
| **`"···"`** as a literal button title | Typography pretending to be an icon | `ellipsis.circle` SF Symbol |
| Per-badge **ad-hoc** alpha (`0.55`/`0.6`/`0.65`), font (`11`/`12`/`14`/`16`), radius set inline | No shared system → subtle inconsistency the eye reads as "off" | **One `InterTileBadge` component** + **one design-token source** |
| **Magic-number** frame math in `layout` | Spacing drifts, never quite aligned | `NSStackView` / Auto Layout with token spacing |
| State flips `hidden` instantly; hover border snaps | No motion → feels static and cheap | **Core Animation** fade/scale; **SF Symbol effects** (`.pulse`/`.bounce`, macOS 14+) |
| Flat semi-transparent black control backing | Dated; not the current macOS look | **`NSVisualEffectView` standard material** *(spike-gated — see caveats; `CAGradientLayer` scrim fallback)* |

> Note: **Liquid Glass is macOS 26**, not this target (15.6). Use **standard `NSVisualEffectView` materials**, not Liquid Glass.

**Consistency guarantee (the strategic point).** AppKit tiles and SwiftUI panels become visually indistinguishable **iff** the design tokens are defined **once**, in a form *both* frameworks read:
- **Colors** → Asset-Catalog color sets, consumed by `NSColor(named:)` **and** SwiftUI `Color(_:)` — zero hex drift.
- **Symbols** → identical SF Symbol names on both sides.
- **Radii / spacing / fonts** → one Swift constants file referenced by both.

Skip this and you get **two drifting design systems** — the real risk, and worse than today because polished SwiftUI panels beside amateur tiles amplify the inconsistency.

**Paranoid caveats (mitigations):**
- **Surgical edits only.** `InterRemoteVideoLayoutManager.m` (~1100 LOC) holds frame-perfect, battle-tested logic — the `CATransaction`-disabled avatar↔video atomic swap, `prepareForResume`/`shutdownRendering`, the tile-recycle pool. Restyle **only** badge/label/menu chrome; **do not touch** the layout/recycle/lifecycle code. Extract badges into a standalone `InterTileBadge` to keep the diff out of those methods.
- **`NSVisualEffectView` over *live* video** (within-window blending sampling an `AVSampleBufferDisplayLayer`/`CAMetalLayer`) is the one genuine unknown — can be expensive or sample incorrectly. **Spike it; fall back to a `CAGradientLayer` scrim** (≈90% of the look, zero risk).
- **Time-box it.** Tiles are not the product differentiator (the editor/canvas are). Polish to "clean and consistent," don't gold-plate.

**Rollout:** an **independent, optional polish task** — ships before/during/after the migration, **does not gate and is not gated by** the capture spike. Best sequenced **alongside building the shared design-token foundation** (the SwiftUI panels need it anyway), so tokens are authored once and reused everywhere.

---

## 7. Impact on functionality (by feature)

| Feature | Risk | Notes |
|---|---|---|
| Join/host flow, mode transitions | Low | Driven by `AppDelegate` (stays). SwiftUI screens are leaves. |
| Camera/mic two-phase toggles | **Medium** | Must remain core-authoritative; SwiftUI reflects, never drives. See F-C1. |
| Remote video tiles | Low (deferred) | Tile grid stays AppKit under B. **Local-display-only (never captured/streamed)** → chrome can be made industry-level in pure AppKit at zero capture risk (§6.3). |
| Screen share (normal) | Low | Policy is signaling-driven, not UI-driven (§8). |
| **Interview tool share (capture)** | **Medium** | Hosting-view capture fidelity spike required. ImageRenderer fallback exists. |
| **Code editor** | Medium | New component in the *artifact-bearing* path; invariant + supply chain. |
| **Whiteboard/canvas** | Medium | New tools; must capture correctly; undo/redo state lifecycle. |
| Chat / polls / Q&A / lobby | Low | Pure content panels; ideal first migrations. |
| Recording consent/list | Low–Med | Consent is legally important; parity tests mandatory. |
| Kiosk / external-display policy | Low | Stays AppKit; SwiftUI must not introduce escape affordances (S-A3). |

---

## 8. Security-preservation matrix

| Invariant | Today | Under Scope B |
|---|---|---|
| Window not readable by third-party capture tools | `setSharingType:NSWindowSharingNone` on `NSWindow` (blocks OBS/Zoom/Meet/Bandicam/etc.; native recorder out of scope — Finding S-0) | **Identical** — set on the same AppKit `NSWindow`; SwiftUI content renders into the same backing store, so exclusion is unchanged |
| Auxiliary windows also non-shareable | (today: few/no extra windows in secure mode) | **New obligation** — SwiftUI popovers/sheets/menus are separate `NSWindow`s; set `NSWindowSharingNone` on them or avoid them in secure mode (S-A6) |
| Secure window floats above all | `NSScreenSaverWindowLevel` on `NSWindow` | **Identical** |
| Borderless / non-movable / opaque | `NSWindow` props | **Identical** |
| Kiosk (dock/menu/⌘-Tab/force-quit disabled) | `applyKioskRestrictions` (AppKit/Carbon) | **Identical**; verify SwiftUI `.keyboardShortcut`/commands don't re-register disabled actions (S-A3) |
| External-display policy (interviewee ≤1 screen) | `NSScreen` monitor in `AppDelegate` | **Identical** |
| Screen-share permission (`everyone`/`ask`/`none`) | Redis + DataChannel signaling; enforced in moderation/surface controller | **Identical** — not UI-coupled |
| Capture limited to tool host (never desktop) | `InterViewSnapshotVideoSource(capturedView: toolCaptureHostView)` | **Preserved** — capture an `NSHostingView` that contains *only* the tool; ImageRenderer renders only the tool view |
| Literal-code integrity (no smart quotes/autocorrect) | NSTextView flags disabled | **Preserved** — custom editor disables them explicitly (S-A4) |
| Pasteboard restrictions | NSTextView-level | **Must port** — SwiftUI editor must not enable Services/drag-out that leak code (S-A5) |

---

## 9. Interview tools — recommendation

### 9.1 Code editor
**Threat-modeled candidates (Phase 1 web research):**

| Library | License | Highlighter | Maintenance | Verdict (secure path) |
|---|---|---|---|---|
| Runestone | MIT | Tree-sitter | active | ❌ **iOS/UIKit only**; Catalyst incomplete |
| ZeeZide/CodeEditor | MIT | Highlight.js via **JavaScriptCore** | stale (~2yr) | ❌ **JS runtime in kiosk** + auto-pairs brackets/smart-indent (**violates literal-code invariant**) |
| STTextView | **GPL-3.0** / paid commercial | Neon/Tree-sitter plugin, native TextKit 2 | very active | ⚠️ Excellent tech, **but GPL-3.0 is a dealbreaker for a closed-source product** unless the commercial license is purchased |
| CodeEditorView (mchakravarty) | Apache-2.0 | native TextKit 2 | author: *"pre-release quality"*, 54 open issues, solo | ⚠️ Clean license, no JS, rich; but maturity/maintenance risk in the artifact path |

**Recommendation:** For the *secure interview* editor, build a **thin `NSViewRepresentable` over `NSTextView` (TextKit 2)** plus a **permissively-licensed Tree-sitter highlighter** (ChimeHQ **Neon** + **SwiftTreeSitter**, MIT). Rationale:
- **No JavaScriptCore** in the kiosk path (smallest attack surface).
- **License-clean** (MIT/Apache), no copyleft exposure.
- The literal-code invariant is preserved by construction (`isAutomaticQuoteSubstitutionEnabled = false`, etc.).
- You already understand `NSTextView`; this is an incremental enhancement, not a black box.
- Captures identically to today (it *is* an `NSTextView`), de-risking the capture spike.

**Acceptable fallback:** `CodeEditorView` (Apache-2.0) if you accept its pre-release maturity and want syntax highlighting + minimap "for free." **Reject** ZeeZide (JS + invariant conflict) and STTextView-under-GPL (unless commercial license bought).

### 9.2 Canvas (Scope A — single-user, richer)
- Reimplement as a SwiftUI **`Canvas`** + a small stroke model (`[Stroke]` with tool/color/width), giving shapes, colors, eraser, **undo/redo** (command stack), and text — all rendered locally.
- **Still streamed as video** through the existing pipeline. **No networking.** Collaborative sync is a separate future spec.

### 9.3 Capture-path spike (BLOCKER before tool migration)
`InterViewSnapshotVideoSource` captures `toolCaptureHostView` via `cacheDisplayInRect:toBitmapImageRep:`. That API can yield **blank/partial** frames for GPU-backed content (`.drawingGroup()`, certain `Canvas` backings).
- **Spike:** host the SwiftUI editor + canvas in an `NSHostingView`, run the *existing* snapshot source, confirm frames are pixel-correct at 10fps / ≤1600×900.
- **Fallback if it fails:** switch the snapshot source to SwiftUI **`ImageRenderer`** (macOS 13+) → renders the SwiftUI view straight to `CGImage`/`CVPixelBuffer`, bypassing `cacheDisplayInRect:`. Keep the same sink/timer/generation guard.

---

## 10. Paranoid Phase 2 — failure-vector analysis (with mitigations)

> Severity legend: **C**ritical / **H**igh / **M**edium / **L**ow. IDs referenced elsewhere in this doc.

### 2A — Security & attack surface
- **S-0 (L, accepted)** `NSWindowSharingNone` scope — see §4. Blocks third-party capture/record/stream/overlay tools (the threat model); native macOS recorder out of scope by design. *Mitigation:* preserve verbatim on the AppKit `NSWindow`; optional one-time confirmation on 15.6 (non-blocking).
- **S-A6 (M)** SwiftUI auxiliary windows (popover/sheet/menu/alert) are new `NSWindow`s that default to shareable, bypassing the main window's exclusion — see §4. *Mitigation:* avoid framework popovers/sheets in secure mode (use in-window overlays); else set `NSWindowSharingNone` at creation; audit/test that every live `NSWindow` during an interview has `sharingType == .none`.
- **S-A2 (H)** Third-party editor dependency = supply chain; JS highlighter = code-exec surface in kiosk. *Mitigation:* prefer custom/native (§9.1); if any SPM dep, pin + checksum + license + maintenance review; produce an SBOM line item.
- **S-A3 (M)** SwiftUI `.keyboardShortcut`/`commands`/focus could re-enable actions kiosk disables (⌘-Tab, menu). *Mitigation:* no global SwiftUI commands in secure mode; audit responder chain; keep kiosk enforcement in AppKit; add a test that disabled shortcuts stay disabled with a hosting view present.
- **S-A4 (M)** SwiftUI editor re-enabling smart quotes/autocorrect/autocomplete corrupts literal code. *Mitigation:* explicitly disable on the underlying `NSTextView`; unit-test that typing `"`/`'`/`{` is not transformed/auto-paired.
- **S-A5 (M)** SwiftUI editor enabling Services / drag-export / copy beyond current policy leaks interview code. *Mitigation:* port the existing pasteboard/services restrictions; test drag-out and Services menu are inert.

### 2B — Reliability & crash vectors
- **R-B1 (H)** A crash inside a hosted SwiftUI view (e.g. force-unwrap in a pre-release library) takes down the call/secure window mid-session. *Mitigation:* ban force-unwraps in hosted views; prefer custom editor over pre-release lib in the artifact path; wrap risky views defensively.
- **R-B2 (H)** Background-thread state mutation → SwiftUI requires main actor → crash. *Mitigation:* `@MainActor` view models; the KVO adapter hops to main (existing KVO already posts on main).
- **R-B3 (M)** Window reuse (`releasedWhenClosed:NO`) leaves stale SwiftUI state across mode switches. *Mitigation:* recreate/`prepareForReuse()` hosting controllers per session; reset view-model state on entry.

### 2C — Memory & resource leaks
- **M-C1 (M)** Retain cycles: hosting controller ↔ view model ↔ AppKit coordinator; closures capturing `self`. *Mitigation:* `[weak self]`; store `NSKeyValueObservation`/`AnyCancellable` and invalidate on teardown.
- **M-C2 (M)** 10fps capture churns images. *Mitigation:* reuse buffers / pixel-buffer pool (existing pattern); measure under Instruments.
- **M-C3 (M)** Hosting views not removed during teardown. *Mitigation:* extend the existing teardown (orderOut → disconnect → cleanup) to explicitly drop hosting controllers + cancel observers.

### 2D — Performance & efficiency
- **P-D1 (M)** `cacheDisplayInRect:` on a hosting view = Metal→bitmap recomposite each tick. *Mitigation:* measure; prefer `ImageRenderer`; cap to existing 10fps/1600×900.
- **P-D2 (L)** AppKit+SwiftUI double layout passes on panels. *Mitigation:* acceptable for non-hot-path panels; keep the video-tile grid in AppKit (Scope B already does).
- **P-D3 (L)** Over-invalidation. *Mitigation:* `@Observable` (macOS 15) scopes invalidation tightly; keep view models small.

### 2E — Concurrency & races
- **F-C1 (H)** SwiftUI two-way `Binding` on mic/camera double-toggles the `[G2]` state machine. *Mitigation:* **one-way** reflection — SwiftUI shows core state; button taps call existing methods; the in-flight/desired flags in `InterMediaWiringController` remain sole authority. Add a test asserting one tap = one transition.
- **F-C2 (M)** KVO→SwiftUI updates off main. *Mitigation:* adapter hops to `@MainActor`.
- **F-C3 (L)** Capture generation race. *Mitigation:* existing generation counter preserved.

### 2F — Edge cases & boundaries
- **E-F1 (M)** Mid-call mode switch / reconnect / external-display-connect during interview. *Mitigation:* these stay in AppKit flow; parity-test each with a hosted SwiftUI screen active.
- **E-F2 (M)** Zero/one/many participants; window reused for next call. *Mitigation:* reset SwiftUI state on session entry (R-B3).
- **E-F3 (M)** Greenfield pattern risk: the **first** migrated screen sets the bridge/adapter pattern for all others. *Mitigation:* migrate a *trivial, non-critical* panel first (e.g. Q&A or recording-list), review the seam hard, codify it, then proceed.

**No Critical or High finding is unmitigated.** S-0 is reclassified **Low / accepted** (§4): the control matches the threat model. The migration-relevant residue is **S-A6 (Medium)**, fully mitigated by auditing auxiliary windows.

---

## 11. Decision-council — should the strategy be A, B, or C?

**Context confirmed:** Choice = {A tools-only, B hybrid-incremental, C full rewrite}. Hard constraints = preserve core logic, security invariants, flow; macOS 15.6; closed-source commercial. Success = professional UI + better code editor + richer canvas, *zero* regression in security/flow, reversible. Ruled out: pure-SwiftUI lifecycle (breaks `NSWindow` security control).

### Adviser 1 — THE CONTRARIAN
- **Most likely failure point:** not the panels — the **capture pipeline**. `cacheDisplayInRect:` on a hosted SwiftUI canvas silently returns blank/garbled frames; the interviewer sees a black tool share and nobody notices until a live interview. Surfaces at the *tool-migration* stage, not before.
- **False assumption the team is attached to:** that `NSWindowSharingNone` still protects anything. If S-0 is real, you may "successfully migrate" a security guarantee that already doesn't exist — polishing a broken lock.
- **12 months if B goes wrong:** a half-migrated app — some SwiftUI panels, some ObjC — with two state-management idioms, where every new feature costs double and nobody will fund "finish the migration."
- **Unsaid thing:** "professional-looking UI" is a *design* problem, not a *framework* problem. SwiftUI does not make UI good; it makes it *different*. You can ship a beautiful AppKit UI and an ugly SwiftUI one.
> *Blind spot: I am constitutionally unable to assign weight to upsides. I may be overcounting tail risks and underweighting the cost of inaction.*

### Adviser 2 — THE FIRST-PRINCIPLES THINKER
- **What this is actually about:** replacing the *rendering* of leaf views while keeping the *system* (windows, media, network) intact. That is a content-substitution problem, not an architecture problem.
- **What a domain-naive smart person does:** put one SwiftUI view in one existing window, prove the data binding and the capture, then repeat. They would *not* rewrite `AppDelegate`.
- **A "fixed" constraint that's actually a choice:** "we must migrate the whole UI." No — the unit of migration is *one window's content view*. There is no rule forcing all-or-nothing.
- **Remove the most comfortable assumption** ("SwiftUI = modern = better"): what's left is a cost/benefit per screen. Chat/polls/Q&A benefit a lot (list UIs, animations cheap in SwiftUI); the tile grid benefits little and risks much.
> *Blind spot: First principles can produce elegant theories that ignore execution friction. I may underweight implementation complexity and switching costs.*

### Adviser 3 — THE EXPANSIONIST
- **If it works better than expected:** the `@Observable`-over-KVO adapter becomes a reusable spine; new features (reactions, live captions, richer moderation) ship in days, cross-platform (visionOS/iPad companion) becomes reachable because the view layer is finally declarative.
- **Where you're undershooting:** the canvas. "Richer single-user tools" is a stepping stone to a *collaborative* whiteboard that is a genuine product differentiator for interviews. Build the SwiftUI canvas now with a clean stroke model and the collaborative future is mostly networking, not UI.
- **Asymmetric bet:** a great SwiftUI **code editor** is the visible artifact of the entire product — candidates and interviewers stare at it for an hour. Disproportionate brand value per engineering dollar.
> *Blind spot: I underweight execution difficulty and resource constraints; my scenarios need several things to go right in sequence.*

### Adviser 4 — THE OUTSIDER
- **Strange-to-an-outsider:** the app forbids the interviewer's screen from being captured by relying on a constant Apple calls "legacy." An outsider asks immediately: *has anyone tested that it still works?*
- **Too-basic-to-question:** why migrate the *whole* UI to chase "professional"? The user named exactly two things they care about (editor, canvas). Those are 2 of ~54 files.
- **What a first-time user notices:** they don't see the framework. They see whether the editor highlights syntax and whether the whiteboard has an eraser. Neither requires touching login, billing, or the tile grid.
> *Blind spot: I may flag genuinely necessary things as "strange"; outsider naivety can mistake hard-won wisdom for convention.*

### Adviser 5 — THE EXECUTOR
1. **Run S-0 verification** — *who:* one engineer — *by:* this week. Record the secure window with ScreenCaptureKit on 15.6; document pass/fail. Gate everything security-related on the result.
2. **Capture-fidelity spike** — *who:* same — *by:* this week. `NSHostingView` containing a SwiftUI `Canvas` → existing snapshot source → confirm pixels. If fail, swap to `ImageRenderer`.
3. **Migrate ONE throwaway-risk panel** (Q&A or recording-list) to SwiftUI behind `NSHostingController`; codify the `@Observable`-over-KVO adapter as the reference pattern. *By:* next week.
4. **Defer** the tile grid and `AppDelegate` decomposition indefinitely. No cost to deferring.
5. **Stop** treating "migrate to SwiftUI" as the goal. The goal is "better editor + canvas + nicer panels." Re-scope tickets to features, not frameworks.
> *Blind spot: I optimize for momentum; I may push action before the strategic question is fully resolved.*

### Step 2 — anonymous peer review (digest)
- The **capture-pipeline** risk (Contrarian) and the **S-0 verification** action (Executor/Outsider) were ranked most valuable across reviewers: they are the only items that can cause a *silent* production failure. The **first-principles "unit = one window's content"** reframing was judged the single most decision-relevant insight — it dissolves the A-vs-B-vs-C tension by making B a *superset path* that can stop anywhere. The Expansionist's collaborative-canvas upside was ranked lower for *this* decision (correctly out of scope now) but flagged as the reason to build the canvas model cleanly. Contradiction surfaced and resolved: Contrarian's "half-migrated trap" vs First-Principles' "incremental is natural" — resolved in favor of incremental **with an explicit per-screen value test**, so partial migration is a stable resting state, not a trap.

### Step 3 — CHAIRMAN'S VERDICT

> **Post-council clarification (owner threat-model input):** S-0 is reclassified **Low / accepted** — `NSWindowSharingNone` blocks the third-party capture/overlay tools that constitute the actual cheating threat; the native macOS recorder is explicitly out of scope. This removes S-0 as a blocker. The **sole remaining blocker spike is capture fidelity**; the new migration-specific security task is the **S-A6 auxiliary-window audit**.

**DECISION:** Proceed with **Scope B (hybrid incremental)**, **gated behind one blocker spike (capture fidelity)**, and **re-scope the work as features, not "a migration."** Migrate content panels and the interview tools behind `NSHostingController`; keep every `NSWindow`, the security props, the kiosk logic, the media/network core, and the video-tile grid in AppKit.

**STRONGEST REASON:** The unit of migration is one window's *content view*, so B is a superset that delivers A's value first and can stop at any screen with the app fully working and every security invariant still on its AppKit window.

**BIGGEST RISK:** A **silent capture-pipeline failure** — a hosted SwiftUI tool that screen-shares as blank/garbled frames. *Trigger:* migrating the editor/canvas before the capture spike. *Early warning:* the spike shows non-pixel-correct frames at 10fps; if you skipped the spike, the warning is an interviewer reporting a black tool share.

**NEXT STEP — within 7 days:** One engineer runs the **single blocker spike** — capture fidelity: `NSHostingView`(SwiftUI `Canvas`) through the existing snapshot source, pixel-verified at 10fps / ≤1600×900, with `ImageRenderer` as the documented fallback. Alongside (non-blocking): a one-time confirmation that third-party ScreenCaptureKit capture of the secure window is still excluded on 15.6, and a quick `NSWindow` audit harness for S-A6. Done = a one-page memo that unblocks the editor/canvas work.

**CONFIDENCE: High.** Would drop only if the capture-fidelity spike fails *and* `ImageRenderer` also cannot reproduce pixel-correct frames — which would reshape the tool-migration approach, not the overall verdict.

---

## 12. Recommended rollout order (lowest-risk first)
1. **Capture-fidelity spike** — sole blocker; plus the non-blocking S-0 confirmation and the S-A6 auxiliary-window audit harness; one week.
2. **Reference panel** — migrate Q&A *or* recording-list; codify the adapter pattern; parity test.
3. **Content panels** — chat, polls, lobby, schedule, account, login (each: build → parity-test → delete ObjC file + delegate plumbing).
4. **Control panel** — careful: it drives the `[G2]` state machine (one-way reflection only).
5. **Interview code editor** (custom `NSViewRepresentable` + Tree-sitter) — capture-verified.
6. **Interview canvas** (SwiftUI `Canvas` + stroke model + undo) — capture-verified.
7. **(Deferred, post-B)** tile grid + `AppDelegate`/`MediaWiring` decomposition — only if a concrete need appears.

**Independent, non-gating track (any time):** **shared design-token foundation** (asset-catalog colors + Swift constants + SF Symbol names) → **AppKit tile-chrome polish** (§6.3): emoji→SF Symbols, `InterTileBadge` component, Core Animation motion, optional spike-gated frosted bars. Local-display-only, zero capture risk; build tokens first so they're reused by the SwiftUI panels too.

## 13. Spikes / open questions that gate implementation
- **[BLOCKER] Capture fidelity:** Does the existing snapshot source capture a hosted SwiftUI `Canvas`/editor pixel-correctly? If not, adopt `ImageRenderer`.
- **[non-blocking] S-0 confirmation:** Confirm a third-party ScreenCaptureKit tool still sees the secure window as excluded on 15.6 (native recorder out of scope by design).
- **[migration task] S-A6 auxiliary-window audit:** Ensure every `NSWindow` SwiftUI may spawn in secure mode (popover/sheet/menu/alert) has `sharingType == .none`, or is avoided in favor of in-window overlays.
- **Editor build-vs-buy:** confirm custom `NSViewRepresentable` + Neon/SwiftTreeSitter vs `CodeEditorView` (Apache-2.0) once a 1-day editor prototype exists.
- **Pasteboard/Services parity:** enumerate exactly which clipboard/Services behaviors the current `NSTextView` editor restricts, to reproduce them.
- **Kiosk shortcut audit:** confirm no SwiftUI command re-enables a kiosk-disabled action.

## 14. Appendix — key references
- Isolation invariant `[G8]`: `inter/Networking/InterNetworkTypes.swift`
- Two-phase toggle `[G2]`: `inter/App/InterMediaWiringController.h/.m`
- Secure window security props: `inter/UI/Controllers/SecureWindowController.m:67-82`
- `NSWindowSharingNone` sites: `AppDelegate.m:655, 2013, 5385, 5582, 5628`; `SecureWindowController.m:75`
- Tool capture: `inter/Media/Sharing/Sources/InterViewSnapshotVideoSource.m` (`cacheDisplayInRect:`), `SecureWindowController.m` (`initWithCapturedView:` on `toolCaptureHostView`)
- Code editor today: `inter/UI/Views/InterSecureCodeEditorView.m` (NSTextView)
- Whiteboard today: `inter/UI/Views/InterSecureWhiteboardView.m` (NSBezierPath/`drawRect:`)
- Apple docs: `NSWindow.SharingType` (`.none` doc-string says "legacy constant macOS no longer uses"; in practice still excludes third-party capture — see §4 / Finding S-0), `NSHostingController`/`NSHostingView` (NSView/NSViewController subclasses, macOS 10.15+)
