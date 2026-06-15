//
//  TeamAvatar.swift
//  inter
//
//  Shared team avatar tile + deterministic colour palette, matching the design
//  handoff `ref_teams` screen (rounded colour tiles with two-letter initials,
//  cycling through violet / purple / emerald / blue / amber / rose). The colour
//  is derived deterministically from a stable seed (the team id) so a team keeps
//  the same tile everywhere it appears (sidebar row, chat header, members view).
//

import SwiftUI

public enum InterTeamPalette {
    /// Brand-consistent 500-level hues that read well with white initials in both
    /// appearances. Order matters — it's the cycle the seed indexes into.
    public static let colors: [NSColor] = [
        NSColor(hex: 0x8B5CF6), // violet
        NSColor(hex: 0xA855F7), // purple
        NSColor(hex: 0x10B981), // emerald
        NSColor(hex: 0x3B82F6), // blue
        NSColor(hex: 0xF59E0B), // amber
        NSColor(hex: 0xF43F5E), // rose
    ]

    /// Stable index into `colors` for a seed (team id). Pure + testable.
    public nonisolated static func colorIndex(forSeed seed: String) -> Int {
        guard !colors.isEmpty else { return 0 }
        // Sum of unicode scalar values → stable across launches (no Hashable salt).
        let sum = seed.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return sum % colors.count
    }

    public nonisolated static func color(forSeed seed: String) -> NSColor {
        colors[colorIndex(forSeed: seed)]
    }
}

/// A rounded-square team avatar with two-letter initials, sized to taste.
public struct TeamAvatarTile: View {
    let name: String
    let seed: String
    var size: CGFloat = 32
    var cornerRadius: CGFloat = InterRadius.md

    public init(name: String, seed: String, size: CGFloat = 32, cornerRadius: CGFloat = InterRadius.md) {
        self.name = name
        self.seed = seed
        self.size = size
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(nsColor: InterTeamPalette.color(forSeed: seed)))
            .frame(width: size, height: size)
            .overlay(
                Text(TeamsListViewModel.avatarInitials(for: name))
                    .font(InterFont.swiftUI(size * 0.38, .bold))
                    .foregroundColor(.white)
            )
            .accessibilityHidden(true)
    }
}
