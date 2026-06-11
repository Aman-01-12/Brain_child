//
//  InterButton.swift
//  inter
//
//  The canonical button for the whole app. Consolidates the per-screen button styles that
//  had started to duplicate (auth OAuth/submit, lobby admit/deny/admit-all, participant
//  leave/ok) into one component with design-system variants + sizes, so every screen stays
//  visually consistent and future screens get the styling for free.
//
//  Variants (DESIGN-SPEC §6 + screen-specific cases):
//    .primary       violet fill, white text          (confirm/admit actions)
//    .secondary     card fill + hairline border       (neutral actions, OAuth, "Leave")
//    .danger        red fill, white text              (destructive, filled)
//    .dangerOutline red text + red border, tint hover  (destructive, low-emphasis — "Deny")
//    .neutral       inverted near-black↔white CTA      (auth entry CTA, appearance-aware)
//
//  Sizes map to the canonical control heights (InterControl): regular 40 · medium 36 ·
//  compact 32 · small 28. Non-fullWidth buttons size to content and never wrap (the label
//  is single-line + fixed-size); fullWidth buttons fill and center.
//

import SwiftUI

public enum InterButtonVariant {
    case primary, secondary, danger, dangerOutline, neutral
}

public enum InterButtonSize {
    case regular, medium, compact, small

    var height: CGFloat {
        switch self {
        case .regular: return InterControl.primaryHeight    // 40
        case .medium:  return InterControl.secondaryHeight  // 36
        case .compact: return InterControl.compactHeight     // 32
        case .small:   return InterControl.toolbarHeight     // 28
        }
    }
    var radius: CGFloat {
        switch self {
        case .regular, .medium: return InterRadius.lg  // 10
        case .compact, .small:  return InterRadius.md  // 8
        }
    }
    var font: Font {
        switch self {
        case .regular, .medium: return InterFont.swiftUI(InterFont.Size.secondary, .semibold)
        case .compact, .small:  return InterFont.swiftUI(InterFont.Size.caption, .semibold)
        }
    }
    var iconPointSize: CGFloat {
        switch self {
        case .regular, .medium: return 13
        case .compact, .small:  return 12
        }
    }
    var horizontalPadding: CGFloat {
        switch self {
        case .regular, .medium: return InterSpacing.x4    // 16
        case .compact:          return InterSpacing.x2_5  // 10
        case .small:            return InterSpacing.x3    // 12
        }
    }
}

public struct InterButton<Leading: View>: View {

    private let title: String
    private let variant: InterButtonVariant
    private let size: InterButtonSize
    private let fullWidth: Bool
    private let isLoading: Bool
    private let loadingTitle: String?
    private let enabled: Bool
    private let action: () -> Void
    private let leading: () -> Leading

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    public init(_ title: String,
                variant: InterButtonVariant = .primary,
                size: InterButtonSize = .regular,
                fullWidth: Bool = false,
                isLoading: Bool = false,
                loadingTitle: String? = nil,
                enabled: Bool = true,
                action: @escaping () -> Void,
                @ViewBuilder leading: @escaping () -> Leading) {
        self.title = title
        self.variant = variant
        self.size = size
        self.fullWidth = fullWidth
        self.isLoading = isLoading
        self.loadingTitle = loadingTitle
        self.enabled = enabled
        self.action = action
        self.leading = leading
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
        Button(action: action) {
            HStack(spacing: InterSpacing.x2) {
                Group {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.8)
                            .tint(foreground)
                    } else {
                        leading()
                    }
                }
                // Sizes a leading SF-Symbol Image to the button; brand-icon leadings set
                // their own frame and Text re-specifies its font, so this is scoped safely.
                .font(.system(size: size.iconPointSize, weight: .semibold))
                Text(isLoading ? (loadingTitle ?? title) : title)
                    .font(size.font)
                    .lineLimit(1)
                    .fixedSize(horizontal: !fullWidth, vertical: false)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, size.horizontalPadding)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: size.height)
            .background(background)
            .overlay(shape.strokeBorder(borderColor, lineWidth: borderWidth))
            .clipShape(shape)
        }
        .buttonStyle(.plain)
        .handCursor()
        .onHover { hovering = $0 }
        .disabled(isLoading || !enabled)
        .opacity(enabled ? 1 : 0.55)
    }

    // MARK: Variant styling

    private var foreground: Color {
        switch variant {
        case .primary, .danger: return .white
        case .secondary:        return Color(nsColor: InterColor.foreground)
        case .dangerOutline:    return Color(nsColor: InterStatus.danger)
        case .neutral:          return invertedForeground
        }
    }

    private var background: Color {
        switch variant {
        case .primary:       return Color(nsColor: InterColor.primary).opacity(hovering ? 0.85 : 1)
        case .danger:        return Color(nsColor: InterStatus.danger).opacity(hovering ? 0.85 : 1)
        case .secondary:     return Color(nsColor: hovering ? InterColor.muted : InterColor.card)
        case .dangerOutline: return Color(nsColor: InterStatus.danger).opacity(hovering ? 0.12 : 0)
        case .neutral:       return invertedBackground
        }
    }

    private var borderColor: Color {
        switch variant {
        case .secondary:     return Color(nsColor: InterColor.border)
        case .dangerOutline: return Color(nsColor: InterStatus.danger).opacity(0.4)
        default:             return .clear
        }
    }
    private var borderWidth: CGFloat {
        (variant == .secondary || variant == .dangerOutline) ? 1 : 0
    }

    /// Inverted near-black↔white CTA (auth). Appearance-aware; lightens/darkens on hover.
    private var invertedBackground: Color {
        if colorScheme == .dark {
            return hovering ? Color(nsColor: NSColor(hex: 0xF5F5F5)) : .white
        } else {
            return hovering ? Color(nsColor: NSColor(hex: 0x262626)) : Color(nsColor: NSColor(hex: 0x0A0A0A))
        }
    }
    private var invertedForeground: Color {
        colorScheme == .dark ? Color(nsColor: NSColor(hex: 0x171717)) : .white
    }
}

// MARK: - Convenience inits

public extension InterButton where Leading == EmptyView {
    /// Text-only button.
    init(_ title: String,
         variant: InterButtonVariant = .primary,
         size: InterButtonSize = .regular,
         fullWidth: Bool = false,
         isLoading: Bool = false,
         loadingTitle: String? = nil,
         enabled: Bool = true,
         action: @escaping () -> Void) {
        self.init(title, variant: variant, size: size, fullWidth: fullWidth,
                  isLoading: isLoading, loadingTitle: loadingTitle, enabled: enabled,
                  action: action, leading: { EmptyView() })
    }
}

public extension InterButton where Leading == Image {
    /// Button with a leading SF Symbol, sized to the button.
    init(_ title: String,
         systemImage: String,
         variant: InterButtonVariant = .primary,
         size: InterButtonSize = .regular,
         fullWidth: Bool = false,
         enabled: Bool = true,
         action: @escaping () -> Void) {
        self.init(title, variant: variant, size: size, fullWidth: fullWidth,
                  isLoading: false, loadingTitle: nil, enabled: enabled,
                  action: action,
                  leading: { Image(systemName: systemImage) })
    }
}
