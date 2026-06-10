//
//  InterInputField.swift
//  inter
//
//  The canonical text-input treatment for the WHOLE app. Built from the catalogue's
//  shadcn input recipe (inter-design-handoff/react-reference/ui/input.tsx + DESIGN-SPEC §6):
//
//    • Quiet at REST — cohesive with the form surface, defined by a 1px border + a very
//      subtle resting shadow (no clashing fill tint).
//    • Loud on FOCUS — the border turns violet (`--ring`) and a 3px violet halo at ~50%
//      appears around the field (`focus-visible:border-ring ring-ring/50 ring-[3px]`).
//      This is the real affordance + the WCAG 2.4.7 focus-visible requirement — NOT a
//      heavier resting border.
//    • ERROR — the border + halo turn danger-coloured (`aria-invalid:border-destructive
//      ring-destructive/…`).
//
//  Use `InterInputField` / `InterSecureInputField` for fields, or apply `.interFieldChrome`
//  to any custom field-shaped control so it matches. Every screen's inputs should use these.
//

import SwiftUI

// MARK: - Chrome (reusable on any field-shaped control)

/// Applies the canonical input chrome (fill + border + focus/error ring) to its content.
/// Pass the live focus + error state; the modifier handles all visual transitions.
public struct InterFieldChrome: ViewModifier {
    public var isFocused: Bool
    public var hasError: Bool
    @Environment(\.colorScheme) private var colorScheme

    public init(isFocused: Bool, hasError: Bool) {
        self.isFocused = isFocused
        self.hasError = hasError
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: InterRadius.lg, style: .continuous)
        return content
            .padding(.horizontal, InterSpacing.x4)
            .frame(height: InterControl.inputHeight)
            // Dark mode keeps the recessed `--input-background` well; light mode is OUTLINED
            // (no fill) to avoid colour noise — affordance carries on the border instead.
            .background(fillColor)
            // Focus / error are conveyed by the BORDER colour + weight only (no outer glow),
            // matching the simpler input treatment used across the other catalogue screens.
            .overlay(shape.strokeBorder(borderColor, lineWidth: borderWidth))
            .clipShape(shape)
            .animation(.easeInOut(duration: 0.12), value: isFocused)
            .animation(.easeInOut(duration: 0.12), value: hasError)
    }

    private var fillColor: Color {
        colorScheme == .dark ? Color(nsColor: InterColor.inputBackground) : .clear
    }

    private var borderColor: Color {
        if hasError { return Color(nsColor: InterStatus.danger) }
        if isFocused { return Color(nsColor: InterColor.ring) }
        return Color(nsColor: InterColor.border)
    }
    private var borderWidth: CGFloat { (hasError || isFocused) ? 1.5 : 1 }
}

public extension View {
    /// Apply the canonical input chrome to any field-shaped control.
    func interFieldChrome(isFocused: Bool, hasError: Bool = false) -> some View {
        modifier(InterFieldChrome(isFocused: isFocused, hasError: hasError))
    }

    /// macOS does NOT resign a text field's focus when the user clicks empty space (unlike
    /// iOS), so a focused field keeps its focus border indefinitely. Apply this to a screen's
    /// content container: tapping any non-interactive area dismisses the active field's focus.
    /// Interactive children (fields, buttons) keep their own taps.
    func interResignsFocusOnBackgroundTap() -> some View {
        contentShape(Rectangle())
            .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
    }
}

// MARK: - Plain text field

public struct InterInputField: View {
    let placeholder: String
    @Binding var text: String
    var hasError: Bool
    /// Optional submit handler (⏎). Lets screens chain fields or trigger their primary action.
    var onSubmit: (() -> Void)?
    @FocusState private var focused: Bool

    public init(placeholder: String,
                text: Binding<String>,
                hasError: Bool = false,
                onSubmit: (() -> Void)? = nil) {
        self.placeholder = placeholder
        self._text = text
        self.hasError = hasError
        self.onSubmit = onSubmit
    }

    public var body: some View {
        HStack(spacing: InterSpacing.x2) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .font(InterFont.swiftUI(InterFont.Size.secondary))
                .foregroundStyle(Color(nsColor: InterColor.foreground))
                .onSubmit { onSubmit?() }
            if hasError {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(nsColor: InterStatus.danger))
            }
        }
        .interFieldChrome(isFocused: focused, hasError: hasError)
        .contentShape(RoundedRectangle(cornerRadius: InterRadius.lg, style: .continuous))
        .onTapGesture { focused = true }
    }
}

// MARK: - Secure field with reveal toggle

public struct InterSecureInputField: View {
    let placeholder: String
    @Binding var text: String
    let isRevealed: Bool
    var hasError: Bool
    let onToggleReveal: () -> Void
    var onSubmit: (() -> Void)?
    @FocusState private var focused: Bool
    @State private var hoveringToggle = false

    public init(placeholder: String,
                text: Binding<String>,
                isRevealed: Bool,
                hasError: Bool = false,
                onToggleReveal: @escaping () -> Void,
                onSubmit: (() -> Void)? = nil) {
        self.placeholder = placeholder
        self._text = text
        self.isRevealed = isRevealed
        self.hasError = hasError
        self.onToggleReveal = onToggleReveal
        self.onSubmit = onSubmit
    }

    public var body: some View {
        HStack(spacing: InterSpacing.x2) {
            Group {
                if isRevealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .focused($focused)
            .font(InterFont.swiftUI(InterFont.Size.secondary))
            .foregroundStyle(Color(nsColor: InterColor.foreground))
            .onSubmit { onSubmit?() }

            if hasError {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(nsColor: InterStatus.danger))
            }

            Button(action: onToggleReveal) {
                HStack(spacing: 4) {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                    Text(isRevealed ? "Hide" : "Show")
                        .font(InterFont.swiftUI(InterFont.Size.caption, .medium))
                        .underline(hoveringToggle)
                }
                .foregroundStyle(Color(nsColor: InterColor.primary))
            }
            .buttonStyle(.plain)
            .handCursor()
            .onHover { hoveringToggle = $0 }
        }
        .interFieldChrome(isFocused: focused, hasError: hasError)
        .contentShape(RoundedRectangle(cornerRadius: InterRadius.lg, style: .continuous))
        .onTapGesture { focused = true }
    }
}
