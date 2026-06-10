# Design-System Foundation + AppKit Tile-Chrome Polish — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the per-tile video chrome (badges, menu glyph, hover) look industry-level in **pure AppKit**, and establish the shared design-token layer that every future SwiftUI panel will reuse — with zero capture/security risk and no change to the tile's frame-perfect rendering logic.

**Architecture:** Introduce one Swift `@objc` token class (`InterDesignTokens`) as the single source of truth for colors/metrics/SF-Symbol-names, read by today's ObjC tiles (via the generated `inter-Swift.h`) and by future SwiftUI panels (natively). Add one reusable Swift `@objc` badge view (`InterTileBadge`) that renders an SF Symbol from those tokens. Then **surgically** swap the four emoji-`NSTextField` badges and the `"···"` button glyph inside the private `InterRemoteVideoTileView` (in `InterRemoteVideoLayoutManager.m`) to use the new component/symbols — touching only chrome, never the `CATransaction` avatar↔video swap, `prepareForResume`/`shutdownRendering`, the recycle pool, or layout math. Optional motion + frosted-bar polish follow.

**Tech Stack:** Swift 5 + Objective-C (mixed target, module `inter`), AppKit, SF Symbols, Core Animation, XCTest. macOS 15.6 deployment target.

**Why this is safe (from spec §6.3):** The remote tiles are **local-display-only** — in interview mode the captured/streamed surface is `toolCaptureHostView`, added *below* `remoteLayoutManager` (`inter/UI/Views/InterSecureInterviewStageView.m:289`). The tile grid is **never** in the capture path, so this work cannot leak, cannot break the snapshot, and cannot appear in the interviewee's stream.

**Grounding facts (verified):**
- New files are auto-included in the target — the project uses `PBXFileSystemSynchronizedRootGroup` (no `project.pbxproj` edits required).
- ObjC consumes Swift via `#import "inter-Swift.h"`; `inter/UI/Views/InterRemoteVideoLayoutManager.m` already imports it (it uses the Swift class `InterRemoteSampleBufferView`).
- Swift tests use `@testable import inter` (see `interTests/InterRemoteVideoViewTests.swift`).
- Build: `xcodebuild -scheme inter -destination 'platform=macOS' build`
- Test: `xcodebuild test -scheme inter -destination 'platform=macOS' -only-testing:interTests/<Class>`

---

## File Structure

| File | Responsibility | New/Modify |
|---|---|---|
| `inter/UI/DesignSystem/InterDesignTokens.swift` | Single source of truth: colors, metrics, SF Symbol names. `@objc` so ObjC + SwiftUI both read it. | **Create** |
| `inter/UI/DesignSystem/InterTileBadge.swift` | Reusable rounded translucent badge rendering one SF Symbol from tokens. `@objc` NSView. | **Create** |
| `interTests/InterDesignTokensTests.swift` | Verifies every symbol token resolves to a real SF Symbol; metrics positive; colors distinct. | **Create** |
| `interTests/InterTileBadgeTests.swift` | Verifies the badge renders an image, uses the corner-radius token, and updates its symbol. | **Create** |
| `inter/UI/Views/InterRemoteVideoLayoutManager.m` | Swap the 4 emoji badges + `"···"` glyph to `InterTileBadge`/SF Symbol (chrome only). | **Modify** |

**Out of scope (DO NOT TOUCH in `InterRemoteVideoLayoutManager.m`):** `setCameraOff:` (the `CATransaction setDisableActions` avatar↔video atomic swap), `prepareForResume`/`shutdownRendering`, the tile-recycle pool (`recycledVideoViews`), `updateTrackingAreas`, and the video/avatar frame math in `layout`. Restyle badges/menu only.

---

### Task 1: `InterDesignTokens` — the single source of truth

**Files:**
- Create: `inter/UI/DesignSystem/InterDesignTokens.swift`
- Test: `interTests/InterDesignTokensTests.swift`

- [ ] **Step 1: Write the failing test**

Create `interTests/InterDesignTokensTests.swift`:

```swift
import XCTest
import AppKit
@testable import inter

final class InterDesignTokensTests: XCTestCase {

    func testAllSymbolTokensResolveToRealSFSymbols() {
        for name in InterDesignTokens.allSymbolNames {
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            XCTAssertNotNil(image, "SF Symbol token '\(name)' does not resolve to a real symbol")
        }
    }

    func testBadgeMetricsArePositive() {
        XCTAssertGreaterThan(InterDesignTokens.badgeSize, 0)
        XCTAssertGreaterThan(InterDesignTokens.badgeCornerRadius, 0)
        XCTAssertGreaterThan(InterDesignTokens.badgeSymbolPointSize, 0)
    }

    func testAccentColorsAreDistinct() {
        XCTAssertNotEqual(InterDesignTokens.accentDanger, InterDesignTokens.accentGold)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -scheme inter -destination 'platform=macOS' -only-testing:interTests/InterDesignTokensTests 2>&1 | tail -20`
Expected: **build/compile failure** — `cannot find 'InterDesignTokens' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `inter/UI/DesignSystem/InterDesignTokens.swift`:

```swift
import AppKit

/// Single source of truth for visual design tokens shared by AppKit (today) and
/// SwiftUI (later). ObjC reads these via the generated `inter-Swift.h`; Swift/SwiftUI
/// reads them natively. Defining tokens ONCE here is what guarantees the AppKit tile
/// chrome and future SwiftUI panels cannot visually drift (spec §6.3).
@objc public final class InterDesignTokens: NSObject {

    private override init() { super.init() }

    // MARK: Metrics
    @objc public static let badgeSize: CGFloat = 22.0
    @objc public static let badgeCornerRadius: CGFloat = 5.0
    @objc public static let badgeSymbolPointSize: CGFloat = 12.0

    // MARK: Colors (dark theme)
    @objc public static let badgeBackground = NSColor(white: 0.0, alpha: 0.55)
    @objc public static let badgeForeground = NSColor.white
    @objc public static let accentDanger = NSColor(srgbRed: 1.00, green: 0.32, blue: 0.32, alpha: 1.0)
    @objc public static let accentGold   = NSColor(srgbRed: 1.00, green: 0.84, blue: 0.30, alpha: 1.0)
    @objc public static let hoverBorder  = NSColor(white: 1.0, alpha: 0.5)

    // MARK: SF Symbol names
    @objc public static let symbolHandRaised     = "hand.raised.fill"
    @objc public static let symbolMicMuted       = "mic.slash.fill"
    @objc public static let symbolCoHost         = "crown.fill"
    @objc public static let symbolCameraLocked   = "lock.fill"
    @objc public static let symbolModerationMenu = "ellipsis.circle.fill"

    /// All symbol-name tokens — used by tests to verify each resolves to a real SF Symbol.
    @objc public static let allSymbolNames: [String] = [
        symbolHandRaised, symbolMicMuted, symbolCoHost, symbolCameraLocked, symbolModerationMenu
    ]
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test -scheme inter -destination 'platform=macOS' -only-testing:interTests/InterDesignTokensTests 2>&1 | tail -20`
Expected: **TEST SUCCEEDED** (3 tests pass).

- [ ] **Step 5: Commit**

```bash
git add inter/UI/DesignSystem/InterDesignTokens.swift interTests/InterDesignTokensTests.swift
git commit -m "feat(design-system): add InterDesignTokens single source of truth"
```

---

### Task 2: `InterTileBadge` — reusable SF-Symbol badge

**Files:**
- Create: `inter/UI/DesignSystem/InterTileBadge.swift`
- Test: `interTests/InterTileBadgeTests.swift`

- [ ] **Step 1: Write the failing test**

Create `interTests/InterTileBadgeTests.swift`:

```swift
import XCTest
import AppKit
@testable import inter

final class InterTileBadgeTests: XCTestCase {

    func testBadgeRendersSymbolImage() {
        let badge = InterTileBadge(symbolName: InterDesignTokens.symbolMicMuted, tint: .white)
        XCTAssertNotNil(badge.currentImage, "Badge should render an image for a valid SF Symbol")
    }

    func testBadgeUsesCornerRadiusToken() {
        let badge = InterTileBadge(symbolName: InterDesignTokens.symbolCoHost, tint: .white)
        XCTAssertEqual(badge.layer?.cornerRadius, InterDesignTokens.badgeCornerRadius)
    }

    func testBadgeSymbolCanBeUpdated() {
        let badge = InterTileBadge(symbolName: InterDesignTokens.symbolHandRaised, tint: .white)
        let first = badge.currentImage
        badge.setSymbolName(InterDesignTokens.symbolCameraLocked)
        XCTAssertNotNil(badge.currentImage)
        XCTAssertFalse(first === badge.currentImage, "Updating the symbol should swap the image")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -scheme inter -destination 'platform=macOS' -only-testing:interTests/InterTileBadgeTests 2>&1 | tail -20`
Expected: **build/compile failure** — `cannot find 'InterTileBadge' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `inter/UI/DesignSystem/InterTileBadge.swift`:

```swift
import AppKit

/// Reusable, design-token-driven badge for a video tile: a rounded translucent chip
/// containing a single SF Symbol. Replaces the ad-hoc per-badge emoji `NSTextField`s
/// used previously (spec §6.3). ObjC instantiates this via the generated `inter-Swift.h`.
@objc public final class InterTileBadge: NSView {

    private let imageView = NSImageView()

    @objc public init(symbolName: String, tint: NSColor) {
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: InterDesignTokens.badgeSize,
                                 height: InterDesignTokens.badgeSize))
        wantsLayer = true
        layer?.backgroundColor = InterDesignTokens.badgeBackground.cgColor
        layer?.cornerRadius = InterDesignTokens.badgeCornerRadius
        layer?.masksToBounds = true

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentTintColor = tint
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setSymbolName(symbolName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Update the displayed SF Symbol. Safe to call repeatedly.
    @objc public func setSymbolName(_ symbolName: String) {
        let config = NSImage.SymbolConfiguration(
            pointSize: InterDesignTokens.badgeSymbolPointSize, weight: .semibold)
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    /// The symbol image currently shown (nil if the symbol failed to resolve). Test hook.
    @objc public var currentImage: NSImage? { imageView.image }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test -scheme inter -destination 'platform=macOS' -only-testing:interTests/InterTileBadgeTests 2>&1 | tail -20`
Expected: **TEST SUCCEEDED** (3 tests pass).

- [ ] **Step 5: Commit**

```bash
git add inter/UI/DesignSystem/InterTileBadge.swift interTests/InterTileBadgeTests.swift
git commit -m "feat(design-system): add InterTileBadge reusable SF-Symbol badge"
```

---

### Task 3: Restyle tile badges + menu glyph to SF Symbols (surgical)

**Files:**
- Modify: `inter/UI/Views/InterRemoteVideoLayoutManager.m` (private `InterRemoteVideoTileView`: the four badge property declarations ~L30–58, their creation in `initWithVideoView:tileKey:displayName:` ~L135–200, and the moderation-menu button glyph ~L158–170)

> **Surgical rule:** change ONLY badge property types, badge creation, and the menu-button glyph. Do **not** touch `setCameraOff:`, `prepareForResume`/`shutdownRendering`, the recycle pool, `updateTrackingAreas`, or the video/avatar math in `layout`.

- [ ] **Step 1: Ensure the Swift bridge import is present**

Confirm the top of `inter/UI/Views/InterRemoteVideoLayoutManager.m` imports the generated Swift header (it should already, because the file uses the Swift class `InterRemoteSampleBufferView`).

Run: `grep -n 'inter-Swift.h' inter/UI/Views/InterRemoteVideoLayoutManager.m`
Expected: at least one match (e.g. `#import "inter-Swift.h"`, typically guarded by `#if __has_include("inter-Swift.h")`).

If **no** match, add this block after the existing `#import` lines near the top of the file:

```objc
#if __has_include("inter-Swift.h")
#import "inter-Swift.h"
#endif
```

- [ ] **Step 2: Change the four badge property types to `InterTileBadge *`**

In the private `@interface InterRemoteVideoTileView` block, change the declared type of the four emoji badges from `NSTextField *` to `InterTileBadge *`. Leave `moderationMenuButton` as `NSButton *`, and leave `nameLabel`, `avatarInitial` as `NSTextField *`.

Replace these four declarations:

```objc
@property (nonatomic, strong) NSTextField *handRaiseBadge;
```
→
```objc
@property (nonatomic, strong) InterTileBadge *handRaiseBadge;
```

```objc
@property (nonatomic, strong) NSTextField *micMutedBadge;
```
→
```objc
@property (nonatomic, strong) InterTileBadge *micMutedBadge;
```

```objc
@property (nonatomic, strong) NSTextField *coHostBadge;
```
→
```objc
@property (nonatomic, strong) InterTileBadge *coHostBadge;
```

```objc
@property (nonatomic, strong) NSTextField *cameraLockedBadge;
```
→
```objc
@property (nonatomic, strong) InterTileBadge *cameraLockedBadge;
```

- [ ] **Step 3: Replace the four badge creations in the initializer**

In `initWithVideoView:tileKey:displayName:`, replace each emoji-`NSTextField` creation block with an `InterTileBadge`. The `hidden` default and `addSubview:` stay; the per-badge frame is still applied later in `layout` (unchanged).

Replace the hand-raise badge block:

```objc
    // [Phase 8.2.3] Hand raise badge — top-left corner
    self.handRaiseBadge = [NSTextField labelWithString:@"✋"];
    self.handRaiseBadge.font = [NSFont systemFontOfSize:16];
    self.handRaiseBadge.frame = NSMakeRect(4, 0, 24, 24);
    [self.handRaiseBadge setWantsLayer:YES];
    self.handRaiseBadge.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.6].CGColor;
    self.handRaiseBadge.layer.cornerRadius = 4.0;
    self.handRaiseBadge.alignment = NSTextAlignmentCenter;
    self.handRaiseBadge.hidden = YES;
    [self addSubview:self.handRaiseBadge];
```
→
```objc
    // Hand-raise badge — SF Symbol via shared design tokens (spec §6.3)
    self.handRaiseBadge = [[InterTileBadge alloc] initWithSymbolName:[InterDesignTokens symbolHandRaised]
                                                                tint:[InterDesignTokens accentGold]];
    self.handRaiseBadge.hidden = YES;
    [self addSubview:self.handRaiseBadge];
```

Replace the mic-muted badge block:

```objc
    self.micMutedBadge = [NSTextField labelWithString:@"🔇"];
    self.micMutedBadge.font = [NSFont systemFontOfSize:14];
    self.micMutedBadge.frame = NSMakeRect(0, 0, 22, 22);
    [self.micMutedBadge setWantsLayer:YES];
    self.micMutedBadge.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.55].CGColor;
    self.micMutedBadge.layer.cornerRadius = 4.0;
    self.micMutedBadge.alignment = NSTextAlignmentCenter;
    self.micMutedBadge.hidden = YES;
    [self addSubview:self.micMutedBadge];
```
→
```objc
    // Mic-muted badge — SF Symbol via shared design tokens (spec §6.3)
    self.micMutedBadge = [[InterTileBadge alloc] initWithSymbolName:[InterDesignTokens symbolMicMuted]
                                                               tint:[InterDesignTokens accentDanger]];
    self.micMutedBadge.hidden = YES;
    [self addSubview:self.micMutedBadge];
```

Replace the co-host badge block:

```objc
    self.coHostBadge = [NSTextField labelWithString:@"👑"];
    self.coHostBadge.font = [NSFont systemFontOfSize:14];
    self.coHostBadge.frame = NSMakeRect(0, 0, 22, 22);
    [self.coHostBadge setWantsLayer:YES];
    self.coHostBadge.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.55].CGColor;
    self.coHostBadge.layer.cornerRadius = 4.0;
    self.coHostBadge.alignment = NSTextAlignmentCenter;
    self.coHostBadge.hidden = YES;
    [self addSubview:self.coHostBadge];
```
→
```objc
    // Co-host crown badge — SF Symbol via shared design tokens (spec §6.3)
    self.coHostBadge = [[InterTileBadge alloc] initWithSymbolName:[InterDesignTokens symbolCoHost]
                                                             tint:[InterDesignTokens accentGold]];
    self.coHostBadge.hidden = YES;
    [self addSubview:self.coHostBadge];
```

Replace the camera-locked badge block:

```objc
    self.cameraLockedBadge = [NSTextField labelWithString:@"🔒"];
    self.cameraLockedBadge.font = [NSFont systemFontOfSize:12];
    self.cameraLockedBadge.frame = NSMakeRect(0, 0, 22, 22);
    [self.cameraLockedBadge setWantsLayer:YES];
    self.cameraLockedBadge.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.55].CGColor;
    self.cameraLockedBadge.layer.cornerRadius = 4.0;
    self.cameraLockedBadge.alignment = NSTextAlignmentCenter;
    self.cameraLockedBadge.hidden = YES;
    [self addSubview:self.cameraLockedBadge];
```
→
```objc
    // Host-camera-locked badge — SF Symbol via shared design tokens (spec §6.3)
    self.cameraLockedBadge = [[InterTileBadge alloc] initWithSymbolName:[InterDesignTokens symbolCameraLocked]
                                                                   tint:[InterDesignTokens badgeForeground]];
    self.cameraLockedBadge.hidden = YES;
    [self addSubview:self.cameraLockedBadge];
```

- [ ] **Step 4: Replace the `"···"` menu-button glyph with an SF Symbol**

In the moderation-menu-button creation block, replace the textual title with an SF Symbol image. Keep the button's target/action, frame, background, corner radius, and `hidden = YES` exactly as they are. Replace only the glyph-defining lines:

```objc
    self.moderationMenuButton.title = @"···";
    self.moderationMenuButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightBold];
```
→
```objc
    self.moderationMenuButton.title = @"";
    NSImageSymbolConfiguration *menuCfg =
        [NSImageSymbolConfiguration configurationWithPointSize:[InterDesignTokens badgeSymbolPointSize]
                                                        weight:NSFontWeightSemibold];
    NSImage *menuIcon =
        [[NSImage imageWithSystemSymbolName:[InterDesignTokens symbolModerationMenu]
                  accessibilityDescription:@"Moderation menu"]
            imageWithSymbolConfiguration:menuCfg];
    self.moderationMenuButton.image = menuIcon;
    self.moderationMenuButton.imagePosition = NSImageOnly;
    self.moderationMenuButton.contentTintColor = [InterDesignTokens badgeForeground];
```

- [ ] **Step 5: Build and verify it compiles**

Run: `xcodebuild -scheme inter -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Visual parity check (manual — the view is private to the `.m`, so verify by running)**

Launch the built app, host a call, and join from a second client (or use the existing local multi-participant test path). Confirm on a remote tile:
- Hand-raise, mic-muted, co-host, camera-locked indicators now render as crisp **SF Symbols** (not emoji), correctly tinted (gold crown/hand, red mic-slash, white lock), vertically centered in their chips.
- Hovering a tile (host mode) shows the **ellipsis-circle** menu glyph (not `···` text); clicking it still opens the moderation menu.
- Badges still appear/disappear correctly on mute/unmute, hand-raise, co-host assign, camera-lock (the `hidden` toggles are unchanged).
- Camera-off still swaps cleanly to the avatar with no frozen-frame fl... (i.e. `setCameraOff:` behavior is unchanged).

- [ ] **Step 7: Commit**

```bash
git add inter/UI/Views/InterRemoteVideoLayoutManager.m
git commit -m "feat(tiles): replace emoji badges + menu glyph with SF Symbols via design tokens"
```

---

### Task 4: Subtle fade motion for badge show/hide (surgical)

**Files:**
- Modify: `inter/UI/Views/InterRemoteVideoLayoutManager.m` (the four badge custom setters: `setHandRaised:`, `setIsMicMuted:`, `setIsCoHost:`, `setIsHostCameraLocked:`)

> Replaces instant `hidden` flips with a 150 ms opacity fade. Touches only the four badge setters — not video/avatar/recycle logic.

- [ ] **Step 1: Add a private fade helper**

In the `@implementation InterRemoteVideoTileView`, add this helper method (place it directly above `- (void)setHandRaised:`):

```objc
/// Fade a badge in/out instead of flipping `hidden` instantly (spec §6.3 motion).
- (void)setBadge:(NSView *)badge visible:(BOOL)visible {
    if (visible) {
        badge.hidden = NO;
        badge.alphaValue = 0.0;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.15;
            badge.animator.alphaValue = 1.0;
        } completionHandler:nil];
    } else {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.15;
            badge.animator.alphaValue = 0.0;
        } completionHandler:^{
            // Guard against a re-show that started during this fade-out.
            if (badge.alphaValue == 0.0) { badge.hidden = YES; }
        }];
    }
}
```

- [ ] **Step 2: Route the four badge setters through the helper**

Replace the body of each badge setter's visibility line.

`setHandRaised:` — replace:
```objc
- (void)setHandRaised:(BOOL)handRaised {
    _handRaised = handRaised;
    self.handRaiseBadge.hidden = !handRaised;
}
```
→
```objc
- (void)setHandRaised:(BOOL)handRaised {
    _handRaised = handRaised;
    [self setBadge:self.handRaiseBadge visible:handRaised];
}
```

`setIsMicMuted:` — replace:
```objc
- (void)setIsMicMuted:(BOOL)isMicMuted {
    if (_isMicMuted == isMicMuted) return;
    _isMicMuted = isMicMuted;
    self.micMutedBadge.hidden = !isMicMuted;
}
```
→
```objc
- (void)setIsMicMuted:(BOOL)isMicMuted {
    if (_isMicMuted == isMicMuted) return;
    _isMicMuted = isMicMuted;
    [self setBadge:self.micMutedBadge visible:isMicMuted];
}
```

`setIsCoHost:` — replace:
```objc
- (void)setIsCoHost:(BOOL)isCoHost {
    if (_isCoHost == isCoHost) return;
    _isCoHost = isCoHost;
    self.coHostBadge.hidden = !isCoHost;
}
```
→
```objc
- (void)setIsCoHost:(BOOL)isCoHost {
    if (_isCoHost == isCoHost) return;
    _isCoHost = isCoHost;
    [self setBadge:self.coHostBadge visible:isCoHost];
}
```

`setIsHostCameraLocked:` — replace:
```objc
- (void)setIsHostCameraLocked:(BOOL)isHostCameraLocked {
    if (_isHostCameraLocked == isHostCameraLocked) return;
    _isHostCameraLocked = isHostCameraLocked;
    self.cameraLockedBadge.hidden = !isHostCameraLocked;
}
```
→
```objc
- (void)setIsHostCameraLocked:(BOOL)isHostCameraLocked {
    if (_isHostCameraLocked == isHostCameraLocked) return;
    _isHostCameraLocked = isHostCameraLocked;
    [self setBadge:self.cameraLockedBadge visible:isHostCameraLocked];
}
```

- [ ] **Step 3: Build and verify it compiles**

Run: `xcodebuild -scheme inter -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Visual check (manual)**

Launch the app, join a call. Toggle mic mute, hand-raise, co-host, camera-lock and confirm each badge now **fades** in/out over ~0.15 s rather than snapping. Rapidly toggle mic mute several times and confirm the badge settles in the correct final state (no stuck half-faded badge) — this exercises the re-show guard.

- [ ] **Step 5: Commit**

```bash
git add inter/UI/Views/InterRemoteVideoLayoutManager.m
git commit -m "feat(tiles): fade badges in/out instead of instant show/hide"
```

---

### Task 5 (OPTIONAL, spike-gated): frosted hover-control affordance

> **Optional and gated.** `NSVisualEffectView` blurring a **live** `AVSampleBufferDisplayLayer` is the one genuinely uncertain item (spec §6.3). If the spike looks wrong (incorrect sampling, jank, or a visible seam over moving video), use the `CAGradientLayer` scrim fallback, which achieves ~90 % of the look at zero risk. Skip this task entirely if time-boxed out — Tasks 1–4 already deliver the core win.

**Files:**
- Modify: `inter/UI/Views/InterRemoteVideoLayoutManager.m` (add a name-label backing affordance; keep within chrome — do not touch video/avatar/recycle)

- [ ] **Step 1: Spike `NSVisualEffectView` behind the name label**

In `initWithVideoView:tileKey:displayName:`, immediately **before** the `nameLabel` is added, insert a visual-effect backing the width of the tile bottom strip, then add the existing `nameLabel` on top of it. Add a property `@property (nonatomic, strong) NSVisualEffectView *nameBackdrop;` to the private interface, then:

```objc
    self.nameBackdrop = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    self.nameBackdrop.material = NSVisualEffectMaterialHUDWindow;   // standard material (NOT Liquid Glass; macOS 26)
    self.nameBackdrop.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    self.nameBackdrop.state = NSVisualEffectStateActive;
    [self addSubview:self.nameBackdrop];
```

Make the existing `nameLabel` transparent so the material shows through — change its background:

```objc
    self.nameLabel.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.55];
    self.nameLabel.drawsBackground = YES;
```
→
```objc
    self.nameLabel.backgroundColor = [NSColor clearColor];
    self.nameLabel.drawsBackground = NO;
```

In `layout`, set the backdrop to the same rect as the name label (add directly above the `self.nameLabel.frame = ...` line):

```objc
    self.nameBackdrop.frame = NSMakeRect(0, 0, b.size.width, 22.0);
```

- [ ] **Step 2: Build, run, and judge the spike**

Run: `xcodebuild -scheme inter -destination 'platform=macOS' build 2>&1 | tail -20` → `** BUILD SUCCEEDED **`.
Launch, join a call with live video. Judge over **moving** video:
- **PASS** → the name strip reads as a clean frosted bar with the name legible; no flicker/seam as the video moves. Keep it; commit; **skip Step 3**.
- **FAIL** (wrong sampling, jank, seam, or illegible) → proceed to Step 3 (fallback).

- [ ] **Step 3: Fallback to a `CAGradientLayer` scrim (only if Step 2 FAILED)**

Remove the `nameBackdrop` `NSVisualEffectView` you added (delete the property, its creation in init, and its frame line in `layout`). Replace it with a bottom-up dark gradient on a backing layer-view. Add `@property (nonatomic, strong) NSView *nameScrim;` and in init (before `nameLabel`):

```objc
    self.nameScrim = [[NSView alloc] initWithFrame:NSZeroRect];
    self.nameScrim.wantsLayer = YES;
    CAGradientLayer *scrim = [CAGradientLayer layer];
    scrim.colors = @[ (__bridge id)[NSColor colorWithWhite:0.0 alpha:0.0].CGColor,
                      (__bridge id)[NSColor colorWithWhite:0.0 alpha:0.75].CGColor ];
    scrim.startPoint = CGPointMake(0.5, 1.0);   // top
    scrim.endPoint   = CGPointMake(0.5, 0.0);   // bottom
    self.nameScrim.layer = scrim;
    self.nameScrim.wantsLayer = YES;
    [self addSubview:self.nameScrim];
```

In `layout`, give the scrim a short bottom band (above the `nameLabel.frame` line):

```objc
    self.nameScrim.frame = NSMakeRect(0, 0, b.size.width, 40.0);
    self.nameScrim.layer.frame = self.nameScrim.bounds;
```

- [ ] **Step 4: Build and visual-check the chosen affordance**

Run: `xcodebuild -scheme inter -destination 'platform=macOS' build 2>&1 | tail -20` → `** BUILD SUCCEEDED **`.
Confirm the name label is legible over both bright and dark video, with no seam during motion.

- [ ] **Step 5: Commit**

```bash
git add inter/UI/Views/InterRemoteVideoLayoutManager.m
git commit -m "feat(tiles): frosted/scrim backing for tile name label"
```

---

## Self-Review

**1. Spec coverage (§6.3 items):**
- Emoji → SF Symbols ✔ (Task 3). `"···"` → `ellipsis.circle.fill` ✔ (Task 3).
- `InterTileBadge` component ✔ (Task 2). One design-token source ✔ (Task 1).
- Core Animation motion ✔ (Task 4). `NSVisualEffectView` standard material + `CAGradientLayer` fallback ✔ (Task 5, spike-gated).
- "Liquid Glass is macOS 26, not 15.6 — use standard materials" ✔ (Task 5 uses `NSVisualEffectMaterialHUDWindow`, explicitly noted).
- Surgical-edits-only caveat ✔ (out-of-scope list + per-task rules; `setCameraOff:`/recycle/lifecycle untouched).
- Consistency guarantee (tokens read by both ObjC now and SwiftUI later) ✔ (Task 1 `@objc` Swift class; future SwiftUI reads natively, ObjC via `inter-Swift.h`).
- `NSStackView`/Auto-Layout for spacing was listed in §6.3 as an option; this plan keeps the existing `layout` frame math **intentionally untouched** to honor the surgical rule (lower risk than re-flowing layout). Recorded as a deliberate scope choice, not a gap.

**2. Placeholder scan:** No TBD/TODO; every code step shows complete code; every command has expected output. ✔

**3. Type consistency:** `InterDesignTokens` token names (`symbolHandRaised`, `accentGold`, `badgeSymbolPointSize`, `badgeForeground`, …) defined in Task 1 are used verbatim in Tasks 2–3. `InterTileBadge(symbolName:tint:)` / `setSymbolName(_:)` / `currentImage` defined in Task 2 are used consistently in Task 2 tests and Task 3 ObjC call sites (ObjC selectors: `initWithSymbolName:tint:`, `setSymbolName:`, `currentImage`). ✔

**4. Ambiguity:** ObjC access to Swift `@objc static` tokens uses bracket/dot message form (`[InterDesignTokens symbolHandRaised]`), which works whether exposed as a class method or class property. ✔

---

## Notes for the executor

- **Visual verification is manual by necessity:** `InterRemoteVideoTileView` is a private `@interface` inside `InterRemoteVideoLayoutManager.m`, so the badge/menu restyle (Tasks 3–5) cannot be unit-tested directly without adding production test hooks (which would over-engineer a cosmetic change). The automated TDD coverage lives in Tasks 1–2 (tokens + badge component); Tasks 3–5 are verified by clean build + the explicit visual checklists.
- **Do not** "improve" the `layout` video/avatar math, the `setCameraOff:` `CATransaction` swap, `prepareForResume`/`shutdownRendering`, or the recycle pool while you're in this file. They are battle-tested and out of scope.
- This plan is **independent and non-gating**: it neither blocks nor is blocked by the capture-fidelity spike. The token layer it creates is reused by every later SwiftUI panel.
