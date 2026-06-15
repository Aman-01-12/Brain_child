//
//  InterWindowChrome.swift
//  inter
//
//  Reusable NSWindow chrome helpers so panel windows match the app theme instead of the
//  default system title bar. Used during the SwiftUI migration as windows are restyled.
//
//  Titlebar theming recipe (Apple docs): `titlebarAppearsTransparent = true` makes the
//  title bar not draw its background, so the window's `backgroundColor` shows through it —
//  giving a title bar coloured to our surface, with the traffic lights still on top.
//

import AppKit
import SwiftUI

@objc public final class InterWindowChrome: NSObject {

    private override init() { super.init() }

    /// Theme a panel window's title bar to the app surface: transparent bar (so the surface
    /// shows through), hidden redundant title text, and the surface fill as `backgroundColor`.
    /// This default uses the card/panel colour so the bar and content read as one piece.
    @objc public static func applyPanelChrome(to window: NSWindow) {
        applyPanelChrome(to: window, surface: InterColor.card)
    }

    /// As above, with an explicit surface colour (e.g. a stage colour for call-surface panels).
    @objc public static func applyPanelChrome(to window: NSWindow, surface: NSColor) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = surface
        window.isMovableByWindowBackground = true
    }

    /// Theme ONLY the title bar to the app surface (transparent bar + surface fill) while
    /// KEEPING the window's visible title text and standard buttons, and NOT making it
    /// movable-by-background. For full app windows (e.g. the auth window) whose title bar
    /// must match the SwiftUI surface in both appearances. `surface` is a dynamic token, so
    /// it re-resolves automatically when the window's appearance is toggled (light/dark).
    @objc public static func applyWindowTitlebarTheme(to window: NSWindow) {
        applyWindowTitlebarTheme(to: window, surface: InterColor.card)
    }

    /// As above, with an explicit surface colour.
    @objc public static func applyWindowTitlebarTheme(to window: NSWindow, surface: NSColor) {
        window.titlebarAppearsTransparent = true
        window.backgroundColor = surface
    }

    /// Hide the standard window buttons (close / minimise / zoom). For blocking overlays
    /// where the only sanctioned exit is an explicit in-content action — e.g. the lobby
    /// waiting room, which must be left via its "Leave" button (so the server is told), not
    /// by closing the window out from under the flow.
    @objc public static func hideStandardButtons(_ window: NSWindow) {
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }

    // MARK: - Seamless chrome (no title-bar band at all)

    /// Seamless full-bleed chrome: the content extends into the title-bar area
    /// (`fullSizeContentView`) and the traffic lights float over the screen's own
    /// surface — there is no separate title-bar band at all. This is the canonical
    /// treatment for migrated SwiftUI app windows (Teams, and every screen after it).
    ///
    /// Recipe for the hosted SwiftUI root:
    ///   1. Apply this to the window (inserts `.fullSizeContentView`, transparent bar,
    ///      hidden title text — keep a real `window.title` for Mission Control/⌘-Tab).
    ///   2. `.ignoresSafeArea(.container, edges: .top)` on the root so surfaces paint
    ///      to the very top.
    ///   3. Add `.interTitlebarInset()` to whatever content sits top-LEFT so it clears
    ///      the floating traffic lights (content elsewhere can use the full height).
    @objc public static func applySeamlessChrome(to window: NSWindow) {
        applySeamlessChrome(to: window, surface: InterColor.card)
    }

    /// As above, with an explicit surface colour (shows through during live resize).
    @objc public static func applySeamlessChrome(to window: NSWindow, surface: NSColor) {
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = surface
        window.isMovableByWindowBackground = true
    }

    /// Height of the strip the floating traffic lights occupy in a seamless window.
    /// Content in the window's top-left corner pads down by this much.
    @objc public static let titlebarContentInset: CGFloat = 28
}

public extension View {
    /// Pad the top by the seamless window's traffic-light strip so content placed in
    /// the top-left corner clears the floating window buttons. Pairs with
    /// `InterWindowChrome.applySeamlessChrome(to:)`.
    func interTitlebarInset() -> some View {
        padding(.top, InterWindowChrome.titlebarContentInset)
    }
}
