//
//  View+Cursor.swift
//  inter
//
//  Shared affordance helper: turn the pointer into the "link" pointing hand while hovering
//  a clickable control, so users get the standard click affordance (principles §6.1 — an
//  explicit Hover state). Uses the modern `pointerStyle(.link)` on macOS 15+, falling back
//  to NSCursor push/pop on older systems.
//

import SwiftUI
import AppKit

public extension View {
    @ViewBuilder
    func handCursor() -> some View {
        if #available(macOS 15.0, *) {
            self.pointerStyle(.link)
        } else {
            self.onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }
}
