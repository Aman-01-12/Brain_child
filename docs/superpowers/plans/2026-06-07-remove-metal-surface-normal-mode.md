# Remove MetalSurfaceView from Normal Call, Setup, and Interview Backgrounds

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the dead `MetalSurfaceView` background (and its 60fps CVDisplayLink GPU loop) from the normal call window, setup window, and interview mode window — replacing each with a plain `NSView` black background — without altering any working functionality.

**Architecture:** Three window-building sites create a `MetalSurfaceView` as the bottom-most background layer; it runs a 60fps CVDisplayLink that paints a solid grey (`float4(0.03, 0.03, 0.03, 1.0)`) using a placeholder shader. All real UI is `NSView` subviews on top. The `MetalSurfaceView` is never visible through those subviews and its only other role — "Share This App" pixel readback — is either broken (normal mode) or bypassed (interview mode). Each instance is replaced with a plain `NSView`. All `shutdownRenderingSynchronously` calls become simple `removeFromSuperview` + `nil`. The `MetalSurfaceView *renderView` property in `InterMediaWiringController` is dead (assigned but never read) and is removed. `MetalRenderEngine`, `MetalSurfaceView.h/.m`, `InterAppSurfaceVideoSource`, and all screen-share logic are untouched.

**Tech Stack:** Objective-C, AppKit (NSView), Xcode

---

## What Is NOT Touched (Verified Safe Boundaries)

- `MetalSurfaceView.h` / `MetalSurfaceView.m` — kept (still needed by `InterRemoteVideoView` indirectly via `MetalRenderEngine.sharedEngine`)
- `MetalRenderEngine.h` / `MetalRenderEngine.m` — kept (used by `InterRemoteVideoView` + `InterComposedRenderer`)
- `InterAppSurfaceVideoSource` — kept (the class stays; it's just never instantiated in normal mode or interview mode after this change)
- `InterSurfaceShareController.startSharingFromSurfaceView:` / `stopSharingFromSurfaceView:` — signature stays `MetalSurfaceView *`; we pass `nil` to stop (parameter is `#pragma unused`) and never call start with `InterShareModeThisApp` from normal mode after removing the option from the picker
- `InterShareModeThisApp` enum value — kept (still needed for interview-mode code path)
- All screen-share logic (Window, Entire Screen) — completely untouched
- All tile rendering, roster, recording — untouched
- `NSWindowSharingNone` — set on the `NSWindow`, not on the view; completely unaffected

---

## Files Modified

| File | Change |
|---|---|
| `inter/App/AppDelegate.m` | Remove `setupRenderView` and `normalRenderView` properties + creation + teardown; remove "This App" from share picker default; replace `shutdownRenderingSynchronously` with `removeFromSuperview`; remove `renderView` assignment to `normalMediaWiring` |
| `inter/App/InterMediaWiringController.h` | Remove `MetalSurfaceView *renderView` property + `#import "MetalSurfaceView.h"` if it exists |
| `inter/App/InterMediaWiringController.m` | Remove any `#import "MetalSurfaceView.h"` if it's here |
| `inter/UI/Controllers/SecureWindowController.m` | Replace `MetalSurfaceView *renderView` property with plain `NSView *`; remove Metal creation; replace `shutdownRenderingSynchronously` with `removeFromSuperview`; remove `renderView` from `mediaWiring.renderView` assignment |
| `inter/UI/Views/InterLocalCallControlPanel.m` | Remove "This App" option from share mode popup (index 0, tag `InterShareModeThisApp`) |

## Files NOT Modified

`MetalSurfaceView.h`, `MetalSurfaceView.m`, `MetalRenderEngine.h`, `MetalRenderEngine.m`, `InterAppSurfaceVideoSource.h/.m`, `InterSurfaceShareController.h/.m`, `InterShareTypes.h`, `InterRemoteVideoView.swift`, `InterComposedRenderer.h/.m`, all test files.

---

## Task 1: Remove `setupRenderView` from AppDelegate

**Files:**
- Modify: `inter/App/AppDelegate.m`

The setup window shows the pre-call screen. `setupRenderView` is a `MetalSurfaceView` used only as a grey background. It is referenced in:
- L48 (property declaration)
- L667–669 (creation)
- L336, L558, L643 (passed to `InterTeardownSetupWindow`)
- L5911–5914 (shutdown in `teardownActiveWindows`)
- The `InterTeardownSetupWindow` static function (L206–224) which takes `MetalSurfaceView *__strong *`

- [ ] **Step 1: Change `InterTeardownSetupWindow` to accept a plain `NSView *`**

In `AppDelegate.m`, find:

```objc
static void InterTeardownSetupWindow(NSWindow *__strong *windowRef,
                                     MetalSurfaceView *__strong *renderViewRef,
                                     InterConnectionSetupPanel *__strong *connectionPanelRef) {
    MetalSurfaceView *renderView = *renderViewRef;
    if (renderView != nil) {
        [renderView shutdownRenderingSynchronously];
        [renderView removeFromSuperview];
        *renderViewRef = nil;
    }
```

Replace with:

```objc
static void InterTeardownSetupWindow(NSWindow *__strong *windowRef,
                                     NSView *__strong *renderViewRef,
                                     InterConnectionSetupPanel *__strong *connectionPanelRef) {
    NSView *renderView = *renderViewRef;
    if (renderView != nil) {
        [renderView removeFromSuperview];
        *renderViewRef = nil;
    }
```

- [ ] **Step 2: Change the `setupRenderView` property from `MetalSurfaceView *` to `NSView *`**

Find:
```objc
@property (nonatomic, strong) MetalSurfaceView *setupRenderView;
```

Replace with:
```objc
@property (nonatomic, strong) NSView *setupRenderView;
```

- [ ] **Step 3: Replace MetalSurfaceView creation with a plain NSView in `launchSetupUI`**

Find:
```objc
    self.setupRenderView = [[MetalSurfaceView alloc] initWithFrame:view.bounds];
    self.setupRenderView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [view addSubview:self.setupRenderView];
```

Replace with:
```objc
    self.setupRenderView = [[NSView alloc] initWithFrame:view.bounds];
    self.setupRenderView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [view addSubview:self.setupRenderView];
```

- [ ] **Step 4: Replace `shutdownRenderingSynchronously` in `teardownActiveWindows`**

Find:
```objc
    if (self.setupRenderView != nil) {
        [self.setupRenderView shutdownRenderingSynchronously];
        [self.setupRenderView removeFromSuperview];
        self.setupRenderView = nil;
    }
```

Replace with:
```objc
    if (self.setupRenderView != nil) {
        [self.setupRenderView removeFromSuperview];
        self.setupRenderView = nil;
    }
```

- [ ] **Step 5: Build and verify no errors**

Run `xcodebuild -scheme inter -destination 'platform=macOS' build 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`

- [ ] **Step 6: Commit**

```bash
git add inter/App/AppDelegate.m
git commit -m "refactor: replace MetalSurfaceView with plain NSView for setup window background"
```

---

## Task 2: Remove `normalRenderView` from AppDelegate (normal call window)

**Files:**
- Modify: `inter/App/AppDelegate.m`

`normalRenderView` is referenced at:
- L51 (property declaration)
- L2031–2033 (creation)
- L2069 (`self.normalMediaWiring.renderView = self.normalRenderView`)
- L2712, L2729, L2846 (passed to `startSharingFromSurfaceView:` / `stopSharingFromSurfaceView:`)
- L4719, L5805 (more `stopSharingFromSurfaceView:` calls)
- L5916–5919 (shutdown in `teardownActiveWindows`)

Note: `stopSharingFromSurfaceView:` has `#pragma unused(surfaceView)` — passing `nil` is safe. `startSharingFromSurfaceView:` is only called in `startNormalShareWithMode:windowIdentifier:` which we'll update to never pass `InterShareModeThisApp` (handled in Task 4). For Window and EntireScreen modes the surfaceView is also unused — the method only uses it to build `InterAppSurfaceVideoSource` which is only for `InterShareModeThisApp`.

- [ ] **Step 1: Change the `normalRenderView` property from `MetalSurfaceView *` to `NSView *`**

Find:
```objc
@property (nonatomic, strong) MetalSurfaceView *normalRenderView;
```

Replace with:
```objc
@property (nonatomic, strong) NSView *normalRenderView;
```

- [ ] **Step 2: Replace MetalSurfaceView creation with a plain NSView in `wireNormalCallUI`**

Find:
```objc
    self.normalRenderView = [[MetalSurfaceView alloc] initWithFrame:view.bounds];
    self.normalRenderView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [view addSubview:self.normalRenderView];
```

Replace with:
```objc
    self.normalRenderView = [[NSView alloc] initWithFrame:view.bounds];
    self.normalRenderView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [view addSubview:self.normalRenderView];
```

- [ ] **Step 3: Remove `renderView` assignment to `normalMediaWiring`**

Find:
```objc
    self.normalMediaWiring.renderView = self.normalRenderView;
```

Replace with (delete the line entirely — property is dead, never read in the wiring controller):
```objc
```

- [ ] **Step 4: Replace `shutdownRenderingSynchronously` in `teardownActiveWindows`**

Find:
```objc
    if (self.normalRenderView != nil) {
        [self.normalRenderView shutdownRenderingSynchronously];
        [self.normalRenderView removeFromSuperview];
        self.normalRenderView = nil;
    }
```

Replace with:
```objc
    if (self.normalRenderView != nil) {
        [self.normalRenderView removeFromSuperview];
        self.normalRenderView = nil;
    }
```

- [ ] **Step 5: Remove the nil-guard in `toggleNormalSurfaceShare` that depends on `normalRenderView`**

Find:
```objc
- (void)toggleNormalSurfaceShare {
    if (!self.normalRenderView) {
        return;
    }
```

Replace with (the guard purpose was: "no render view = no surface share"; after this change, surface share still works for Window/EntireScreen without the view):
```objc
- (void)toggleNormalSurfaceShare {
```

- [ ] **Step 6: Build and verify no errors**

Run `xcodebuild -scheme inter -destination 'platform=macOS' build 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`

- [ ] **Step 7: Commit**

```bash
git add inter/App/AppDelegate.m
git commit -m "refactor: replace MetalSurfaceView with plain NSView for normal call window background"
```

---

## Task 3: Remove dead `renderView` property from `InterMediaWiringController`

**Files:**
- Modify: `inter/App/InterMediaWiringController.h`
- Modify: `inter/App/InterMediaWiringController.m` (if it imports MetalSurfaceView.h)

The `renderView` property is assigned in two places but **never read** anywhere in `InterMediaWiringController.m`. Confirmed by full file search. It is dead code.

- [ ] **Step 1: Remove the `renderView` property from `InterMediaWiringController.h`**

Find:
```objc
@property (nonatomic, weak, nullable) MetalSurfaceView *renderView;
```

Remove that line entirely. Also remove `#import "MetalSurfaceView.h"` from the header **only if** it is only imported for this property. Check by searching the header for any other MetalSurfaceView reference.

Check:
```bash
grep -n "MetalSurfaceView" inter/App/InterMediaWiringController.h
```

If the only hit is the property line (which we just removed), also remove the import line:
```objc
#import "MetalSurfaceView.h"
```

- [ ] **Step 2: Check InterMediaWiringController.m for MetalSurfaceView imports**

```bash
grep -n "MetalSurfaceView\|renderView" inter/App/InterMediaWiringController.m
```

If `#import "MetalSurfaceView.h"` appears, remove it. If any usage of `self.renderView` or `renderView` appears (should be zero per audit), investigate before removing.

- [ ] **Step 3: Build and verify no errors**

Run `xcodebuild -scheme inter -destination 'platform=macOS' build 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add inter/App/InterMediaWiringController.h inter/App/InterMediaWiringController.m
git commit -m "refactor: remove dead renderView property from InterMediaWiringController"
```

---

## Task 4: Remove "This App" from the normal-mode share picker

**Files:**
- Modify: `inter/UI/Views/InterLocalCallControlPanel.m`

The share mode popup has three items. Item index 0 has tag `InterShareModeThisApp`. In normal mode this option should be removed since the Metal readback that powered it is gone (and was broken anyway — it only captured the grey drawable).

Interview mode sets the picker to `InterShareModeThisApp` via `setShareMode:` but **hides the picker entirely** (`setShareModeSelectorHidden:YES`), so removing it from the normal-mode popup does not affect interview mode.

- [ ] **Step 1: Verify the popup item structure**

```bash
grep -n "shareModePopUpButton\|InterShareMode\|itemArray\|addItem\|insertItem" inter/UI/Views/InterLocalCallControlPanel.m | head -30
```

Note the exact item labels and tags. Confirm item 0 is "This App" / `InterShareModeThisApp`.

- [ ] **Step 2: Remove the "This App" item from the popup initialisation**

Find the code that adds/inserts items into `shareModePopUpButton`. It will look like:

```objc
[self.shareModePopUpButton.itemArray[0] setTag:InterShareModeThisApp];
```

or items being added with titles like `@"This App"`, `@"A Window"`, `@"Entire Screen"`.

Remove the item that sets up `InterShareModeThisApp`. If the items are built via `addItemWithTitle:` calls, remove the `@"This App"` / `InterShareModeThisApp` call. If they're set via tags on an existing `itemArray`, remove the item at index 0 and renumber/retag as needed.

Also update the `setShareMode:InterShareModeThisApp` default call on line 233 (sets default selection) to `InterShareModeWindow`:

Find:
```objc
    [self setShareMode:InterShareModeThisApp];
```

Replace with:
```objc
    [self setShareMode:InterShareModeWindow];
```

Also check `AppDelegate.m` line 2332 where `setShareMode:InterShareModeThisApp` is called for normal mode:

Find:
```objc
    [self.normalControlPanel setShareMode:InterShareModeThisApp];
```

Replace with:
```objc
    [self.normalControlPanel setShareMode:InterShareModeWindow];
```

- [ ] **Step 3: Build and verify no errors**

Run `xcodebuild -scheme inter -destination 'platform=macOS' build 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add inter/UI/Views/InterLocalCallControlPanel.m inter/App/AppDelegate.m
git commit -m "refactor: remove broken 'This App' screen share option from normal call mode"
```

---

## Task 5: Replace MetalSurfaceView with plain NSView in interview mode (SecureWindowController)

**Files:**
- Modify: `inter/UI/Controllers/SecureWindowController.m`

Interview mode has `MetalSurfaceView *renderView` at:
- L31 (property declaration)
- L87–89 (creation)
- L230 (`shutdownRenderingSynchronously` in `hideSecureWindow`)
- L246 (`shutdownRenderingSynchronously` in `destroySecureWindow`)
- L247 (`stopSharingFromSurfaceView:self.renderView` — parameter is `#pragma unused`)
- L584 (`stopSharingFromSurfaceView:self.renderView` in `toggleSurfaceShare`)
- L601 (`startSharingFromSurfaceView:self.renderView` in `toggleSurfaceShare`)
- L417 (`self.mediaWiring.renderView = self.renderView` — dead assignment, removed in Task 3)

For `startSharingFromSurfaceView:` in interview mode: `customVideoSource` is always set (to `InterViewSnapshotVideoSource`) in `startLocalMediaFlow` before `start` is called. `videoSourceForConfiguration:surfaceView:` returns `customVideoSource` first when `shareMode == InterShareModeThisApp` — so the `surfaceView` argument is never used. Confirmed in `InterSurfaceShareController.m:L225–232`.

- [ ] **Step 1: Change the property declaration from `MetalSurfaceView *` to `NSView *`**

Find:
```objc
@property (nonatomic, strong) MetalSurfaceView *renderView;
```

Replace with:
```objc
@property (nonatomic, strong) NSView *renderView;
```

- [ ] **Step 2: Replace MetalSurfaceView creation with plain NSView**

Find:
```objc
    self.renderView = [[MetalSurfaceView alloc] initWithFrame:view.bounds];
    self.renderView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [view addSubview:self.renderView];
```

Replace with:
```objc
    self.renderView = [[NSView alloc] initWithFrame:view.bounds];
    self.renderView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [view addSubview:self.renderView];
```

- [ ] **Step 3: Replace `shutdownRenderingSynchronously` in `hideSecureWindow`**

Find:
```objc
        // Ordering the borderless secure window out before the Metal view is
        // quiesced leaves a window where the CAMetalLayer can lose its drawable
        // while the display-link thread is still issuing work. Stop rendering
        // first so exit never races layer teardown.
        [self.renderView shutdownRenderingSynchronously];
        [self.secureWindow orderOut:nil];
```

Replace with:
```objc
        [self.secureWindow orderOut:nil];
```

- [ ] **Step 4: Replace `shutdownRenderingSynchronously` in `destroySecureWindow`**

Find:
```objc
    [self.renderView shutdownRenderingSynchronously];
    [self.surfaceShareController stopSharingFromSurfaceView:self.renderView];
```

Replace with:
```objc
    [self.surfaceShareController stopSharingFromSurfaceView:nil];
```

(The `renderView` no longer needs to be passed since `stopSharingFromSurfaceView:` ignores its parameter. Passing `nil` is clean and correct since the stop method is `nullable`-safe.)

- [ ] **Step 5: Remove unused `#import "MetalSurfaceView.h"` if SecureWindowController no longer needs it**

```bash
grep -n "MetalSurfaceView\|shutdownRenderingSynchronously" inter/UI/Controllers/SecureWindowController.m
```

If the only remaining reference is the `#import`, remove it.

- [ ] **Step 6: Build and verify no errors**

Run `xcodebuild -scheme inter -destination 'platform=macOS' build 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`

- [ ] **Step 7: Commit**

```bash
git add inter/UI/Controllers/SecureWindowController.m
git commit -m "refactor: replace MetalSurfaceView with plain NSView for interview mode background"
```

---

## Task 6: Verify `stopSharingFromSurfaceView` call sites in AppDelegate accept nil

**Files:**
- Modify: `inter/App/AppDelegate.m` (call sites that pass `self.normalRenderView`)

Since `normalRenderView` is now a plain `NSView *` (not a `MetalSurfaceView *`), passing it to `stopSharingFromSurfaceView:(MetalSurfaceView *)` generates a type mismatch warning. The cleanest fix is to pass `nil` (the parameter is unused; header is `nullable`).

Call sites in `AppDelegate.m`:
- `toggleNormalSurfaceShare` (L2729)
- `moderationController:forcedToStopScreenShare:` (L4719)
- `teardownNormalCallUI` (L5805)
- `startNormalShareWithMode:windowIdentifier:` (L2846) — this is `startSharingFromSurfaceView:`, not stop

For `startSharingFromSurfaceView:` at L2846: after Task 4, `InterShareModeThisApp` is no longer selectable in normal mode. For Window/EntireScreen modes, `videoSourceForConfiguration:surfaceView:` returns an `InterScreenCaptureVideoSource` regardless of the `surfaceView` argument. So passing `nil` here is also safe.

- [ ] **Step 1: Replace all `stopSharingFromSurfaceView:self.normalRenderView` with `stopSharingFromSurfaceView:nil`**

There are 3 occurrences in AppDelegate.m. Do all three:

Occurrence 1 (in `toggleNormalSurfaceShare`):
Find: `[self.normalSurfaceShareController stopSharingFromSurfaceView:self.normalRenderView];`
Replace: `[self.normalSurfaceShareController stopSharingFromSurfaceView:nil];`

Occurrence 2 (in the forced-stop handler):
Find: `[self.normalSurfaceShareController stopSharingFromSurfaceView:self.normalRenderView];`
Replace: `[self.normalSurfaceShareController stopSharingFromSurfaceView:nil];`

Occurrence 3 (in `teardownNormalCallUI`):
Find: `[self.normalSurfaceShareController stopSharingFromSurfaceView:self.normalRenderView];`
Replace: `[self.normalSurfaceShareController stopSharingFromSurfaceView:nil];`

- [ ] **Step 2: Replace `startSharingFromSurfaceView:self.normalRenderView` with `startSharingFromSurfaceView:nil`**

Find: `[self.normalSurfaceShareController startSharingFromSurfaceView:self.normalRenderView];`
Replace: `[self.normalSurfaceShareController startSharingFromSurfaceView:nil];`

- [ ] **Step 3: Build and verify clean — zero warnings on these lines**

Run `xcodebuild -scheme inter -destination 'platform=macOS' build 2>&1 | grep -i "warning\|error" | grep -v "^$" | head -30`

Expected: No new type-mismatch warnings on the replaced lines.

- [ ] **Step 4: Commit**

```bash
git add inter/App/AppDelegate.m
git commit -m "refactor: pass nil to start/stopSharingFromSurfaceView in normal call mode"
```

---

## Task 7: Final clean build + smoke check

- [ ] **Step 1: Full clean build**

```bash
xcodebuild clean -scheme inter -destination 'platform=macOS' 2>&1 | tail -5
xcodebuild -scheme inter -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 2: Verify MetalSurfaceView is no longer instantiated in normal/setup/interview paths**

```bash
grep -n "MetalSurfaceView alloc\]\|MetalSurfaceView *normalRender\|MetalSurfaceView *setupRender\|MetalSurfaceView *renderView" \
  inter/App/AppDelegate.m inter/UI/Controllers/SecureWindowController.m inter/App/InterMediaWiringController.h
```

Expected: zero matches.

- [ ] **Step 3: Verify `shutdownRenderingSynchronously` is no longer called from any non-Metal path**

```bash
grep -rn "shutdownRenderingSynchronously" inter/App/ inter/UI/Controllers/
```

Expected: zero matches (the method still exists on `MetalSurfaceView` for potential future use, but is not called from any window teardown path).

- [ ] **Step 4: Verify `CVDisplayLink` is no longer started on call entry**

The only remaining `CVDisplayLinkCreateWithActiveCGDisplays` callers should be `MetalSurfaceView.m` and `InterRemoteVideoView.swift` (screen-share viewer). Confirm:

```bash
grep -rn "CVDisplayLink\|CVDisplayLinkCreate" inter/ --include="*.m" --include="*.swift" | grep -v "MetalSurfaceView\|InterRemoteVideoView\|InterComposedRenderer"
```

Expected: zero matches outside those files.

- [ ] **Step 5: Verify `InterLocalCallControlPanel` no longer has "This App" as the default**

```bash
grep -n "InterShareModeThisApp\|This App" inter/UI/Views/InterLocalCallControlPanel.m
```

Expected: zero matches (or only in comments/dead code). The enum value itself still exists in `InterShareTypes.h` for interview mode.

- [ ] **Step 6: Final commit**

```bash
git add -A
git commit -m "chore: verify dead MetalSurfaceView removal complete — build clean"
```

---

## Self-Review Against Requirements

**"App should continue working as it is"**
- Setup screen: ✅ Background is now plain NSView (black, same visual result since Metal painted grey *behind* all UI which was on top)
- Normal call: ✅ All tiles, roster, recording, screen share (Window + EntireScreen), moderation unchanged
- Interview mode: ✅ `customVideoSource = InterViewSnapshotVideoSource` path unchanged; share feature works identically
- `NSWindowSharingNone`: ✅ Set on `NSWindow`, not on view, unchanged
- Remote screen-share viewing (`InterRemoteVideoView`): ✅ untouched
- Recording (`InterComposedRenderer`): ✅ untouched
- `MetalRenderEngine` singleton: ✅ untouched

**"Only dead code should be removed"**
- `MetalSurfaceView` as a background: ✅ its shader output is solid grey, painted behind all real UI
- `normalRenderView` / `setupRenderView`: ✅ never render real content, never visible
- `renderView` property on `InterMediaWiringController`: ✅ assigned but provably never read (full file searched)
- "This App" share option in normal mode: ✅ broken (reads grey drawable, not call UI)

**Type safety**
- All `stopSharingFromSurfaceView:` calls now pass `nil` (parameter is `#pragma unused`, nullable)
- All `startSharingFromSurfaceView:` calls now pass `nil` (only `InterShareModeThisApp` reads the view; that mode is removed from normal-mode picker; interview mode uses `customVideoSource`)

**No placeholder steps:** Every step shows exact old and new code.
