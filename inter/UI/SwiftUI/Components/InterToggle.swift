//
//  InterToggle.swift
//  inter
//
//  Canonical pill switch + inline text link, extracted from the per-screen copies
//  (lobby's switch, auth's text links) so every screen shares one implementation.
//

import SwiftUI

/// A compact pill toggle (violet when on). Use for boolean settings like "Enable Waiting
/// Room". When `enabled` is false it dims and ignores taps (e.g. host-only controls shown
/// to co-hosts).
public struct InterToggle: View {
    @Binding var isOn: Bool
    var enabled: Bool

    public init(isOn: Binding<Bool>, enabled: Bool = true) {
        self._isOn = isOn
        self.enabled = enabled
    }

    public var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Color(nsColor: InterColor.primary) : Color(nsColor: InterColor.secondary))
                .frame(width: 32, height: 20)
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                .frame(width: 16, height: 16)
                .padding(.horizontal, 2)
        }
        .animation(.easeInOut(duration: 0.15), value: isOn)
        .contentShape(Capsule())
        .onTapGesture { if enabled { isOn.toggle() } }
        .handCursor()
        .opacity(enabled ? 1 : 0.6)
        .allowsHitTesting(enabled)
    }
}

/// Inline violet text link with a hover underline + hand cursor. For secondary/tertiary
/// actions rendered as text (e.g. "Forgot password?", "Create Account").
public struct InterTextLink: View {
    let title: String
    var size: CGFloat
    let action: () -> Void
    @State private var hovering = false

    public init(_ title: String, size: CGFloat = InterFont.Size.caption, action: @escaping () -> Void) {
        self.title = title
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(InterFont.swiftUI(size, .medium))
                .foregroundStyle(Color(nsColor: InterColor.primary))
                .underline(hovering)
        }
        .buttonStyle(.plain)
        .handCursor()
        .onHover { hovering = $0 }
    }
}
