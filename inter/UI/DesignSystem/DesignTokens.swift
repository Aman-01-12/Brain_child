//
//  DesignTokens.swift
//  Inter — canonical design tokens for the native macOS app (SwiftUI + AppKit).
//
//  This is the Swift translation of `src/styles/theme.css` from the web catalogue.
//  It is the SINGLE SOURCE OF TRUTH for color, type, spacing, radius and elevation
//  in the native app. Where a reference mock (TSX) disagrees, these values win.
//
//  Architecture fit:
//   • SwiftUI app chrome  → use the THEME colors (appearance-aware: light/dark).
//   • AppKit call tiles   → use the STAGE colors (FIXED dark in both appearances).
//
//  Appearance model: manual toggle, default DARK, override allowed.
//   • Set `InterAppearance.apply(.dark)` (or `.light`) on your hosting window/view,
//     or `.system` to follow macOS. Theme colors below resolve from the view's
//     effectiveAppearance, so a manual override on the NSHostingView works.
//
//  Requires macOS 12+ (for `Color(nsColor:)`).
//

import SwiftUI
import AppKit
import CoreText

// MARK: - Hex helpers

extension NSColor {
    /// Create an sRGB NSColor from a 0xRRGGBB hex value.
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green:   CGFloat((hex >> 8) & 0xFF) / 255,
            blue:    CGFloat(hex & 0xFF) / 255,
            alpha:   alpha
        )
    }
}

private extension NSColor {
    /// A theme-aware color that picks `light` or `dark` from the active appearance.
    /// Honors a manual appearance override set on the hosting view/window.
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark : light
        }
    }
}

// MARK: - Color tokens

/// Inter brand palette. Use `.swiftUI` for SwiftUI, the NSColor directly for AppKit.
public enum InterColor {

    // ── Theme (appearance-aware) ───────────────────────────────────────────
    // Light = "Glitter" periwinkle · Dark = "Deep Obsidian Ink"
    public static let background        = NSColor.dynamic(light: .init(hex: 0xE2E5F8), dark: .init(hex: 0x0B0F19))
    public static let foreground        = NSColor.dynamic(light: .init(hex: 0x201C34), dark: .init(hex: 0xF1F5F9))
    public static let card              = NSColor.dynamic(light: .init(hex: 0xF5F6FD), dark: .init(hex: 0x11161F))
    public static let cardForeground    = NSColor.dynamic(light: .init(hex: 0x201C34), dark: .init(hex: 0xF1F5F9))
    public static let popover           = NSColor.dynamic(light: .init(hex: 0xF5F6FD), dark: .init(hex: 0x11161F))
    public static let popoverForeground = NSColor.dynamic(light: .init(hex: 0x201C34), dark: .init(hex: 0xF1F5F9))
    public static let secondary         = NSColor.dynamic(light: .init(hex: 0xCED2F3), dark: .init(hex: 0x1E293B))
    public static let secondaryForeground = NSColor.dynamic(light: .init(hex: 0x201C34), dark: .init(hex: 0xF1F5F9))
    public static let muted             = NSColor.dynamic(light: .init(hex: 0xD4D7F4), dark: .init(hex: 0x1E293B))
    public static let mutedForeground   = NSColor.dynamic(light: .init(hex: 0x635F89), dark: .init(hex: 0x94A3B8))
    public static let accent            = NSColor.dynamic(light: .init(hex: 0xC2C6F0), dark: .init(hex: 0x1E293B))
    public static let accentForeground  = NSColor.dynamic(light: .init(hex: 0x201C34), dark: .init(hex: 0xF1F5F9))
    public static let inputBackground   = NSColor.dynamic(light: .init(hex: 0xD4D7F4), dark: .init(hex: 0x1E293B))
    public static let switchBackground  = NSColor.dynamic(light: .init(hex: 0xB7BBE4), dark: .init(hex: 0x1E293B))

    /// Hairline border. Light/dark use translucent strokes (see opacity in alpha).
    public static let border = NSColor.dynamic(
        light: NSColor(hex: 0x2D286E, alpha: 0.108),
        dark:  NSColor(hex: 0x94A3B8, alpha: 0.14)
    )

    // ── Brand (violet) ─────────────────────────────────────────────────────
    public static let primary           = NSColor.dynamic(light: .init(hex: 0x7C3AED), dark: .init(hex: 0x8B5CF6))
    public static let primaryForeground = NSColor(hex: 0xFFFFFF)
    public static let ring              = NSColor.dynamic(light: .init(hex: 0x7C3AED), dark: .init(hex: 0x8B5CF6))

    // ── Destructive (red) ──────────────────────────────────────────────────
    public static let destructive           = NSColor.dynamic(light: .init(hex: 0xD4183D), dark: .init(hex: 0x82181A))
    public static let destructiveForeground = NSColor.dynamic(light: .init(hex: 0xFFFFFF), dark: .init(hex: 0xFB2C36))

    // ── Sidebar ────────────────────────────────────────────────────────────
    public static let sidebar                  = NSColor.dynamic(light: .init(hex: 0xDADDF6), dark: .init(hex: 0x0B0F19))
    public static let sidebarForeground        = NSColor.dynamic(light: .init(hex: 0x201C34), dark: .init(hex: 0xF1F5F9))
    public static let sidebarAccent            = NSColor.dynamic(light: .init(hex: 0xCACEF2), dark: .init(hex: 0x1E293B))
    public static let sidebarBorder            = NSColor.dynamic(
        light: NSColor(hex: 0x2D286E, alpha: 0.087),
        dark:  NSColor(hex: 0x94A3B8, alpha: 0.12)
    )

    // ── STAGE — FIXED DARK in BOTH appearances (AppKit call tiles live here) ─
    // Never make these appearance-aware: a live call reads dark even in light mode.
    public static let stage         = NSColor(hex: 0x101012) // deepest chrome / rails / footers
    public static let stageSurface  = NSColor(hex: 0x18181B) // main video canvas / panels
    public static let stageElevated = NSColor(hex: 0x27272A) // menus / popovers on the stage
}

// Convenience: SwiftUI Color for every token.
public extension Color {
    static let interBackground        = Color(nsColor: InterColor.background)
    static let interForeground        = Color(nsColor: InterColor.foreground)
    static let interCard              = Color(nsColor: InterColor.card)
    static let interCardForeground    = Color(nsColor: InterColor.cardForeground)
    static let interPopover           = Color(nsColor: InterColor.popover)
    static let interSecondary         = Color(nsColor: InterColor.secondary)
    static let interMuted             = Color(nsColor: InterColor.muted)
    static let interMutedForeground   = Color(nsColor: InterColor.mutedForeground)
    static let interAccent            = Color(nsColor: InterColor.accent)
    static let interInputBackground   = Color(nsColor: InterColor.inputBackground)
    static let interBorder            = Color(nsColor: InterColor.border)
    static let interPrimary           = Color(nsColor: InterColor.primary)
    static let interPrimaryForeground = Color(nsColor: InterColor.primaryForeground)
    static let interRing              = Color(nsColor: InterColor.ring)
    static let interDestructive       = Color(nsColor: InterColor.destructive)
    static let interSidebar           = Color(nsColor: InterColor.sidebar)
    // Stage (fixed dark)
    static let interStage             = Color(nsColor: InterColor.stage)
    static let interStageSurface      = Color(nsColor: InterColor.stageSurface)
    static let interStageElevated     = Color(nsColor: InterColor.stageElevated)
}

// MARK: - Status hues (semantic, same in both appearances)
// Match Tailwind's emerald / amber / red / purple / violet families.
public enum InterStatus {
    public static let success = NSColor(hex: 0x10B981) // emerald-500
    public static let warning = NSColor(hex: 0xF59E0B) // amber-500
    public static let danger  = NSColor(hex: 0xEF4444) // red-500
    public static let dm      = NSColor(hex: 0x9333EA) // purple-600
    public static let brand   = NSColor(hex: 0x7C3AED) // violet-600
}

// MARK: - Typography

/// General Sans type system. Register the bundled fonts once at launch via
/// `InterFont.registerBundledFonts()` (see DesignTokens.md for Info.plist option).
public enum InterFont {

    /// PostScript family name. If `Font.custom("General Sans", …)` fails to apply a
    /// weight, use the explicit face names below (verify in Font Book after bundling).
    public static let family = "General Sans"

    /// Standard UI scale (points == CSS px on macOS @1x baseline).
    public enum Size {
        public static let display: CGFloat = 24 // text-2xl — page title
        public static let title:   CGFloat = 20 // text-xl  — section heading
        public static let heading: CGFloat = 18 // text-lg  — subheading
        public static let body:    CGFloat = 16 // text-base
        public static let secondary: CGFloat = 14 // text-sm
        public static let caption: CGFloat = 12 // text-xs — labels
        // Dense scale — call HUD / participant rails / status bars (keep exact):
        public static let dense11: CGFloat = 11 // text-[11px]
        public static let dense10: CGFloat = 10 // text-[10px]
        public static let dense9:  CGFloat = 9  // text-[9px]
        public static let menu13:  CGFloat = 13 // text-[13px] stage menu items
    }

    public static func swiftUI(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font.custom(family, size: size).weight(weight)
    }

    public static func appKit(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont(name: family, size: size).map { base in
            NSFontManager.shared.convert(base, toHaveTrait: weight >= .semibold ? .boldFontMask : [])
        } ?? NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// CSS letter-spacing is in `em`; SwiftUI `.tracking()` wants POINTS.
    ///   tracking(points) = em * fontSize
    /// Headings use -0.018em, body -0.006em.
    public static func tracking(em: CGFloat, size: CGFloat) -> CGFloat { em * size }

    /// CSS `line-height` is a multiple of the TOTAL line box. SwiftUI `.lineSpacing()`
    /// only ADDS space between lines on top of the font's natural leading (~1.2x).
    ///   lineSpacing ≈ (cssLineHeight - naturalLeading) * fontSize
    /// Body uses 1.6, everything else 1.5. For pixel-accuracy in AppKit, prefer
    /// NSParagraphStyle.lineHeightMultiple = cssLineHeight instead.
    public static func lineSpacing(cssLineHeight: CGFloat, size: CGFloat, naturalLeading: CGFloat = 1.2) -> CGFloat {
        max(0, (cssLineHeight - naturalLeading) * size)
    }

    /// Register every General Sans face shipped in the app bundle's `Fonts/` folder.
    /// Alternatively add the `ATSApplicationFontsPath` key to Info.plist (see md).
    public static func registerBundledFonts() {
        // Be robust to bundle layout: file-system-synchronized targets flatten the
        // `Fonts/` group straight into Resources/, so try the subdirectory first and
        // then fall back to the Resources root. Registration is idempotent.
        var urls: [URL] = []
        for ext in ["otf", "ttf"] {
            if let u = Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: "Fonts") { urls += u }
            if let u = Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) { urls += u }
        }
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

// MARK: - Spacing (4 / 8 pt grid)

public enum InterSpacing {
    public static let x0_5: CGFloat = 2   // gap-0.5  (dense only)
    public static let x1:   CGFloat = 4   // gap-1
    public static let x1_5: CGFloat = 6   // gap-1.5  (dense controls)
    public static let x2:   CGFloat = 8   // gap-2    ← preferred rhythm
    public static let x2_5: CGFloat = 10  // gap-2.5  (dense controls)
    public static let x3:   CGFloat = 12  // gap-3 / p-3
    public static let x4:   CGFloat = 16  // gap-4 / p-4 ← default card padding
    public static let x5:   CGFloat = 20
    public static let x6:   CGFloat = 24
    public static let x8:   CGFloat = 32
}

// MARK: - Corner radius (base --radius = 10pt)

public enum InterRadius {
    public static let sm:  CGFloat = 6   // rounded-sm
    public static let md:  CGFloat = 8   // rounded-md  — micro buttons, icon tiles
    public static let lg:  CGFloat = 10  // rounded-lg  — buttons, inputs, rows
    public static let xl:  CGFloat = 14  // rounded-xl  — cards, input groups
    public static let xxl: CGFloat = 16  // rounded-2xl — modals, call window
    // rounded-full → use Capsule() or Circle()
}

// MARK: - Control sizing (canonical — don't invent intermediate heights)

public enum InterControl {
    public static let primaryHeight:   CGFloat = 40 // h-10
    public static let secondaryHeight: CGFloat = 36 // h-9
    public static let inputHeight:     CGFloat = 36 // h-9
    public static let compactHeight:   CGFloat = 32 // h-8
    public static let toolbarHeight:   CGFloat = 28 // h-7
}

// MARK: - Elevation (approximations of Tailwind shadow-*; tune visually)

public struct InterShadow {
    public let color: Color
    public let radius: CGFloat
    public let x: CGFloat
    public let y: CGFloat

    public static let sm   = InterShadow(color: .black.opacity(0.10), radius: 2,  x: 0, y: 1)
    public static let lg   = InterShadow(color: .black.opacity(0.18), radius: 8,  x: 0, y: 4)
    public static let xl   = InterShadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 8)
    public static let xxl  = InterShadow(color: .black.opacity(0.28), radius: 24, x: 0, y: 12)

    /// Colored emphasis shadows are ALWAYS the fill color at 20% (no other opacity).
    public static func cta(_ fill: Color) -> InterShadow {
        InterShadow(color: fill.opacity(0.20), radius: 10, x: 0, y: 4)
    }
}

public extension View {
    func interShadow(_ s: InterShadow) -> some View {
        shadow(color: s.color, radius: s.radius, x: s.x, y: s.y)
    }
}

// MARK: - Appearance control (manual toggle, default dark, override allowed)

public enum InterAppearance {
    public enum Mode { case dark, light, system }

    /// Apply to the whole app (call once at launch) or to a specific NSWindow.
    public static func apply(_ mode: Mode, to window: NSWindow? = nil) {
        let appearance: NSAppearance? = {
            switch mode {
            case .dark:   return NSAppearance(named: .darkAqua)
            case .light:  return NSAppearance(named: .aqua)
            case .system: return nil
            }
        }()
        if let window { window.appearance = appearance }
        else { NSApp.appearance = appearance }
    }
}
