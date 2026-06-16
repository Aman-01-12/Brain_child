//
//  InterDesignTokens.swift
//  inter
//
//  @objc facade over the canonical Swift token layer (`DesignTokens.swift`) for the
//  Objective-C call-tile chrome. The handoff `InterColor`/`InterStatus`/`InterRadius`
//  enums are the single source of truth, but they are Swift-only (enums with static
//  lets) and therefore invisible to Objective-C. This thin class re-exports exactly
//  the tokens the ObjC tile chrome needs (in `InterRemoteVideoLayoutManager.m`),
//  REFERENCING the SSOT so values cannot drift.
//
//  Design alignment (DESIGN-SPEC §7.5 "Full-stage / call surface"):
//    • raise-hand badge = amber (InterStatus.warning) top-left
//    • mic-muted badge  = danger (InterStatus.danger) bottom-right
//    • small badges use rounded-sm (InterRadius.sm = 4pt)
//    • stage menu/hover border = white/10
//

import AppKit

@objc public final class InterDesignTokens: NSObject {

    private override init() { super.init() }

    // MARK: Metrics
    @objc public static let badgeSize: CGFloat = 22.0
    /// Small badges use the catalogue's `rounded-sm`.
    @objc public static let badgeCornerRadius: CGFloat = InterRadius.sm
    @objc public static let badgeSymbolPointSize: CGFloat = 12.0

    // MARK: Colors (sourced from the SSOT — no drift)
    /// Translucent scrim behind glyphs/name on the fixed-dark stage.
    @objc public static let badgeBackground = NSColor(hex: 0x000000, alpha: 0.55)
    @objc public static let badgeForeground = NSColor.white
    /// mic-muted / destructive accent — Tailwind red-500.
    @objc public static let accentDanger = InterStatus.danger
    /// raise-hand / co-host accent — Tailwind amber-500 (the catalogue's "amber").
    @objc public static let accentGold = InterStatus.warning
    /// success / "allow" / live — Tailwind emerald-500.
    @objc public static let accentSuccess = InterStatus.success
    /// Hover / stage-menu hairline — `border-white/10`.
    @objc public static let hoverBorder = NSColor(white: 1.0, alpha: 0.10)

    // MARK: Stage surfaces (DESIGN-SPEC §7.5 — fixed dark in BOTH appearances; from InterColor SSOT)
    /// Deepest chrome — rails / footers / window backdrop. `--stage` #101012.
    @objc public static let stageBackground = InterColor.stage
    /// Main video canvas / panel surface that tiles sit on. `--stage-surface` #18181B.
    @objc public static let stageSurface = InterColor.stageSurface
    /// Menus / popovers floating on the stage. `--stage-elevated` #27272A.
    @objc public static let stageElevated = InterColor.stageElevated

    // MARK: Stage text + chrome (white-on-dark; for ALL call-surface AppKit panels)
    /// Primary stage text — titles / emphasis (white).
    @objc public static let stageForeground          = InterColor.stageText
    /// Secondary stage text — body / participant names (neutral-200).
    @objc public static let stageForegroundSecondary = InterColor.stageTextSecondary
    /// Muted stage text — captions / empty state / disabled (neutral-400).
    @objc public static let stageForegroundMuted     = InterColor.stageTextMuted
    /// Stage hairline divider/border — white at 10% (spec: stage dividers 5–10%).
    @objc public static let stageBorder = NSColor(white: 1.0, alpha: 0.10)
    /// Floating stage panel / popover corner radius (queue / recording / picker panels).
    /// Preserves the shipped 8pt; bump to InterRadius.xl (10) if panels should match cards.
    @objc public static let stagePanelCornerRadius: CGFloat = InterRadius.bubble

    // MARK: Video tile (camera-off look) — Tailwind neutrals per react-reference/InCallMock.tsx
    /// Tile gradient start (top-left) — Tailwind `neutral-800`.
    @objc public static let tileGradientTop = NSColor(hex: 0x262626)
    /// Tile gradient end (bottom-right) / tile base `bg-neutral-900` — Tailwind `neutral-900`.
    @objc public static let tileGradientBottom = NSColor(hex: 0x171717)
    /// Camera-off avatar circle fill — Tailwind `neutral-700`.
    @objc public static let avatarFill = NSColor(hex: 0x404040)
    /// Tile corner radius — `rounded-lg`.
    @objc public static let tileCornerRadius: CGFloat = InterRadius.xl
    /// Solid (bottom) end of the tile name scrim — `bg-gradient-to-t from-black/80`.
    @objc public static let nameScrim = NSColor(hex: 0x000000, alpha: 0.80)
    /// Height of the bottom name scrim band — `h-10`.
    @objc public static let nameScrimHeight: CGFloat = 40.0

    // MARK: Call layout metrics
    /// In-call bottom control-bar height — SSOT for the bar's frame AND the bottom
    /// inset the normal-call video layout reserves so tiles are never occluded by
    /// the bar. Sourced from InterControl.callBarHeight (DesignTokens SSOT).
    @objc public static let callControlBarHeight: CGFloat = InterControl.callBarHeight

    /// In-call video-tile geometry — the single source of truth for the AppKit
    /// grid / stage+filmstrip layout (InterRemoteVideoLayoutManager). Backed by
    /// InterCallLayout so a change in DesignTokens.swift reflects in the call UI.
    @objc public static let callTileGap: CGFloat               = InterCallLayout.tileGap
    @objc public static let callTilePinGap: CGFloat            = InterCallLayout.tilePinGap
    @objc public static let callTileCornerRadius: CGFloat      = InterCallLayout.tileCornerRadius
    @objc public static let callFilmstripWidthFraction: CGFloat = InterCallLayout.filmstripWidthFraction
    @objc public static let callFilmstripMinWidth: CGFloat     = InterCallLayout.filmstripMinWidth
    @objc public static let callFilmstripMaxWidth: CGFloat     = InterCallLayout.filmstripMaxWidth
    @objc public static let callFilmstripTileGap: CGFloat      = InterCallLayout.filmstripTileGap
    @objc public static let callFilmstripPadding: CGFloat      = InterCallLayout.filmstripPadding
    @objc public static let callChromeCornerRadius: CGFloat    = InterCallLayout.chromeCornerRadius
    @objc public static let callCountBadgeCornerRadius: CGFloat = InterCallLayout.countBadgeCornerRadius
    @objc public static let callPageIndicatorCornerRadius: CGFloat = InterCallLayout.pageIndicatorCornerRadius

    // MARK: SF Symbol names (app-specific; not part of the visual token CSS)
    @objc public static let symbolHandRaised     = "hand.raised.fill"
    @objc public static let symbolMicMuted       = "mic.slash.fill"
    @objc public static let symbolCoHost         = "crown.fill"
    @objc public static let symbolCameraLocked   = "lock.fill"
    @objc public static let symbolModerationMenu = "ellipsis.circle.fill"

    /// All symbol-name tokens — used by tests to verify each resolves to a real SF Symbol.
    @objc public static let allSymbolNames: [String] = [
        symbolHandRaised, symbolMicMuted, symbolCoHost, symbolCameraLocked, symbolModerationMenu
    ]

    /// Register the bundled General Sans faces so `NSFont(name:"General Sans",…)` resolves.
    /// ObjC entry point (call once at launch from `AppDelegate`); forwards to the canonical
    /// `InterFont.registerBundledFonts()`. Idempotent.
    @objc public static func registerFonts() {
        InterFont.registerBundledFonts()
    }
}
