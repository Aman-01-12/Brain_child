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
}
