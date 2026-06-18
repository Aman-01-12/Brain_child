//
//  InterBanner.swift
//  inter
//
//  Canonical inline status banner (icon + centered message) for form-level / panel-level
//  messages, extracted from auth's error/info banners. Per-variant status colour; the icon
//  flows inline with the text so the whole banner centers as one unit. `tinted` adds a
//  subtle background fill — but per the design-handoff principle, ERROR banners are never
//  filled (outline + coloured text only, matching the auth treatment), regardless of the
//  `tinted` argument. success/info/warning still honour `tinted` (default on).
//

import SwiftUI

public enum InterBannerVariant {
    case error, success, info, warning

    var color: NSColor {
        switch self {
        case .error:   return InterStatus.danger
        case .success: return InterStatus.success
        case .info:    return InterColor.primary
        case .warning: return InterStatus.warning
        }
    }
    var defaultSymbol: String {
        switch self {
        case .error:   return "exclamationmark.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .info:    return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }
}

public struct InterBanner: View {
    let message: String
    var variant: InterBannerVariant
    var systemImage: String?
    var tinted: Bool
    var centered: Bool

    public init(_ message: String,
                variant: InterBannerVariant = .info,
                systemImage: String? = nil,
                tinted: Bool = true,
                centered: Bool = true) {
        self.message = message
        self.variant = variant
        self.systemImage = systemImage
        self.tinted = tinted
        self.centered = centered
    }

    public var body: some View {
        let color = Color(nsColor: variant.color)
        let symbol = systemImage ?? variant.defaultSymbol
        let shape = RoundedRectangle(cornerRadius: InterRadius.lg, style: .continuous)
        // Design principle: error messages carry no fill — only an outline + coloured text,
        // matching auth. success/info/warning keep their subtle tint when requested.
        let effectiveTinted = tinted && variant != .error

        (Text(Image(systemName: symbol)) + Text("  ") + Text(message))
            .font(InterFont.swiftUI(InterFont.Size.secondary))
            .multilineTextAlignment(centered ? .center : .leading)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
            .padding(.horizontal, InterSpacing.x3)
            .padding(.vertical, InterSpacing.x2)
            .background(effectiveTinted ? color.opacity(0.12) : Color.clear)
            .overlay(shape.strokeBorder(color.opacity(0.3), lineWidth: 1))
            .clipShape(shape)
    }
}
