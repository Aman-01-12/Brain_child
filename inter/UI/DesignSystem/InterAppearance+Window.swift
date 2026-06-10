//
//  InterAppearance+Window.swift
//  inter
//
//  Convenience layer over the handoff `InterAppearance` (DesignTokens.swift). The base
//  type already exposes `apply(_:to:)`; this adds the project default (dark) and a
//  reusable `Mode → NSAppearance` mapping that the SwiftUI hosting seam consumes.
//

import AppKit

public extension InterAppearance {

    /// The project-wide default surface appearance. SwiftUI chrome defaults to dark;
    /// stage/call surfaces are fixed dark regardless (their tokens never branch).
    static let defaultMode: Mode = .dark

    /// Concrete `NSAppearance` for a mode (`.system` → `nil`, i.e. follow macOS).
    static func nsAppearance(_ mode: Mode) -> NSAppearance? {
        switch mode {
        case .dark:   return NSAppearance(named: .darkAqua)
        case .light:  return NSAppearance(named: .aqua)
        case .system: return nil
        }
    }

    /// Apply the project default (dark) to a hosting window.
    static func applyDefault(to window: NSWindow) {
        apply(defaultMode, to: window)
    }
}
