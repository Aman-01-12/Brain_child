//
//  AuthView.swift
//  inter
//
//  SwiftUI port of the login / register screen (`auth`). Visual source of truth:
//  inter-design-handoff/react-reference/mocks/LoginRegisterMock.tsx +
//  reference-screens/ref_auth_{dark,light}.png. Behavior source of truth: the previous
//  AppKit `InterLoginPanel` (delegate contract preserved via `InterAuthHostView`).
//
//  Deviations from the mock (deliberate, per user feedback + principles §4 alignment):
//   • OAuth buttons are STACKED full-width (not a 2-col grid) so the long "Continue with…"
//     labels get proper internal padding and align edge-to-edge with the fields below.
//   • Real multi-colour brand marks (GoogleIcon / MicrosoftIcon) instead of approximations.
//   • Every clickable control shows the pointing-hand cursor + an explicit hover state.
//   • A light/dark appearance toggle (top-trailing) drives the host's NSAppearance.
//
//  GAP (flagged): "Forgot password?" has no backend yet → routes to a no-op pending a
//  product decision; it is NOT silently wired to auth.
//

import SwiftUI

public struct AuthView: View {

    @ObservedObject var viewModel: AuthViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var ctaHovering = false

    public init(viewModel: AuthViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(nsColor: InterColor.card).ignoresSafeArea()

            GeometryReader { geo in
                ScrollView {
                    card
                        .frame(width: 420)
                        .padding(.vertical, InterSpacing.x6)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .center)
                        // Clicking empty space (margins or gaps between fields) dismisses
                        // the focused field — macOS won't do this on its own.
                        .interResignsFocusOnBackgroundTap()
                }
            }

            appearanceToggle
                .padding(InterSpacing.x4)
        }
    }

    // MARK: Card

    // Single flat surface (no separate card fill/border/shadow): the form sits directly on
    // the one window background. Hierarchy comes from type + spacing + the header divider,
    // not stacked surfaces.
    private var card: some View {
        VStack(spacing: 0) {
            header
            body_
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 0) {
            logo
                .padding(.bottom, InterSpacing.x4)
            Text(viewModel.mode == .signIn ? "Sign In to Inter" : "Create an Account")
                .font(InterFont.swiftUI(InterFont.Size.title, .semibold))
                .foregroundStyle(Color(nsColor: InterColor.foreground))
            Text(viewModel.mode == .signIn
                 ? "Welcome back to your workspace."
                 : "Get started — it only takes a minute.")
                .font(InterFont.swiftUI(InterFont.Size.secondary))
                .foregroundStyle(Color(nsColor: InterColor.mutedForeground))
                .padding(.top, InterSpacing.x1)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, InterSpacing.x8)
        .padding(.top, InterSpacing.x8)
        .padding(.bottom, InterSpacing.x6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: InterColor.border)).frame(height: 1)
        }
    }

    private var logo: some View {
        RoundedRectangle(cornerRadius: InterRadius.xxl, style: .continuous)
            .fill(invertedBackground(hovering: false))
            .frame(width: 48, height: 48)
            .overlay(
                Text("In")
                    .font(InterFont.swiftUI(InterFont.Size.title, .bold))
                    .tracking(-1)
                    .foregroundStyle(invertedForeground)
            )
            .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
    }

    // MARK: Body

    private var body_: some View {
        VStack(spacing: InterSpacing.x4) {
            oauthColumn
            emailDivider
            if let info = viewModel.infoMessage, !info.isEmpty {
                infoBanner(info)
            }
            if let error = viewModel.formError, !error.isEmpty {
                errorBanner(error)
            }
            form
            submitButton
            footer
        }
        .padding(.horizontal, InterSpacing.x8)
        .padding(.vertical, InterSpacing.x6)
        .animation(.easeInOut(duration: 0.15), value: viewModel.formError)
        .animation(.easeInOut(duration: 0.15), value: viewModel.infoMessage)
    }

    private var oauthColumn: some View {
        VStack(spacing: InterSpacing.x3) {
            OAuthButton(label: "Continue with Google",
                        enabled: viewModel.controlsEnabled,
                        action: { viewModel.tapOAuth("google") }) { GoogleIcon() }
            OAuthButton(label: "Continue with Microsoft",
                        enabled: viewModel.controlsEnabled,
                        action: { viewModel.tapOAuth("microsoft") }) { MicrosoftIcon() }
        }
    }

    private var emailDivider: some View {
        HStack(spacing: InterSpacing.x3) {
            Rectangle().fill(Color(nsColor: InterColor.muted)).frame(height: 1)
            Text("or continue with email")
                .font(InterFont.swiftUI(InterFont.Size.caption))
                .foregroundStyle(Color(nsColor: InterColor.mutedForeground))
                .fixedSize()
            Rectangle().fill(Color(nsColor: InterColor.muted)).frame(height: 1)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        (Text(Image(systemName: "exclamationmark.circle.fill")) + Text("  ") + Text(message))
            .font(InterFont.swiftUI(InterFont.Size.secondary))
            .multilineTextAlignment(.center)
            .foregroundStyle(Color(nsColor: InterStatus.danger))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, InterSpacing.x3)
            .padding(.vertical, InterSpacing.x2)
            .overlay(
                RoundedRectangle(cornerRadius: InterRadius.lg, style: .continuous)
                    .stroke(Color(nsColor: InterStatus.danger).opacity(0.3), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: InterRadius.lg, style: .continuous))
    }

    private func infoBanner(_ message: String) -> some View {
        (Text(Image(systemName: "envelope.badge.fill")) + Text("  ") + Text(message))
            .font(InterFont.swiftUI(InterFont.Size.secondary))
            .multilineTextAlignment(.center)
            .foregroundStyle(Color(nsColor: InterStatus.success))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, InterSpacing.x3)
            .padding(.vertical, InterSpacing.x2)
            .background(Color(nsColor: InterStatus.success).opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: InterRadius.lg, style: .continuous)
                    .stroke(Color(nsColor: InterStatus.success).opacity(0.3), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: InterRadius.lg, style: .continuous))
    }

    // MARK: Form

    private var form: some View {
        VStack(spacing: InterSpacing.x3) {
            if viewModel.mode == .signUp {
                fieldGroup(label: "Display name", error: viewModel.displayNameError) {
                    InterInputField(placeholder: "Your name",
                                    text: $viewModel.displayName,
                                    hasError: viewModel.displayNameError != nil)
                }
                .onChange(of: viewModel.displayName) { viewModel.displayNameError = nil }
            }
            fieldGroup(label: "Email address", error: viewModel.emailError) {
                InterInputField(placeholder: "you@example.com",
                                text: $viewModel.email,
                                hasError: viewModel.emailError != nil)
            }
            .onChange(of: viewModel.email) {
                viewModel.emailError = nil
                viewModel.formError = nil
                viewModel.infoMessage = nil
            }
            passwordField
        }
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x1_5) {
            HStack {
                Text("Password")
                    .font(InterFont.swiftUI(InterFont.Size.caption, .medium))
                    .foregroundStyle(Color(nsColor: InterColor.foreground))
                Spacer()
                if viewModel.mode == .signIn {
                    TextLink(title: "Forgot password?") { viewModel.tapForgotPassword() }
                }
            }
            InterSecureInputField(placeholder: "Minimum 8 characters",
                                  text: $viewModel.password,
                                  isRevealed: viewModel.showPassword,
                                  hasError: viewModel.passwordError != nil,
                                  onToggleReveal: { viewModel.showPassword.toggle() })
            if let error = viewModel.passwordError {
                FieldError(message: error)
            }
            if viewModel.showsStrength {
                strengthMeter
            }
        }
        .onChange(of: viewModel.password) {
            viewModel.passwordError = nil
            viewModel.formError = nil
        }
        .animation(.easeInOut(duration: 0.15), value: viewModel.passwordError)
    }

    private var strengthMeter: some View {
        VStack(spacing: InterSpacing.x1_5) {
            HStack(spacing: InterSpacing.x1) {
                ForEach(1...4, id: \.self) { i in
                    Capsule()
                        .fill(i <= viewModel.strengthScore
                              ? strengthColor(viewModel.strengthScore)
                              : Color(nsColor: InterColor.muted))
                        .frame(height: 4)
                        .animation(.easeInOut(duration: 0.3), value: viewModel.strengthScore)
                }
            }
            HStack {
                Text("Password strength")
                    .font(InterFont.swiftUI(InterFont.Size.dense11))
                    .foregroundStyle(Color(nsColor: InterColor.mutedForeground))
                Spacer()
                Text(viewModel.strengthLabel)
                    .font(InterFont.swiftUI(InterFont.Size.dense11, .semibold))
                    .foregroundStyle(strengthLabelColor(viewModel.strengthScore))
            }
        }
        .padding(.top, InterSpacing.x1)
    }

    private var submitButton: some View {
        Button(action: { viewModel.submit() }) {
            HStack(spacing: InterSpacing.x2) {
                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(invertedForeground)
                    Text("Signing in…")
                } else {
                    Text(viewModel.mode == .signIn ? "Log In" : "Create Account")
                }
            }
            .font(InterFont.swiftUI(InterFont.Size.secondary, .medium))
            .foregroundStyle(invertedForeground)
            .frame(maxWidth: .infinity)
            .frame(height: InterControl.primaryHeight)
            .background(invertedBackground(hovering: ctaHovering))
            .clipShape(RoundedRectangle(cornerRadius: InterRadius.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        .handCursor()
        .onHover { ctaHovering = $0 }
        .disabled(viewModel.isLoading || !viewModel.controlsEnabled)
    }

    private var footer: some View {
        HStack(spacing: InterSpacing.x1) {
            Text(viewModel.mode == .signIn ? "No account yet?" : "Already have an account?")
                .font(InterFont.swiftUI(InterFont.Size.caption))
                .foregroundStyle(Color(nsColor: InterColor.mutedForeground))
            TextLink(title: viewModel.mode == .signIn ? "Create Account" : "Back to Login") {
                viewModel.toggleMode()
            }
            .disabled(!viewModel.controlsEnabled)
        }
        .padding(.top, InterSpacing.x1)
    }

    private var appearanceToggle: some View {
        Button(action: { viewModel.toggleAppearance() }) {
            Image(systemName: viewModel.appearance == .dark ? "sun.max.fill" : "moon.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(nsColor: InterColor.mutedForeground))
                .frame(width: 32, height: 32)
                .background(Color(nsColor: InterColor.secondary))
                .clipShape(Circle())
                .overlay(Circle().stroke(Color(nsColor: InterColor.border), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .handCursor()
        .help(viewModel.appearance == .dark ? "Switch to light mode" : "Switch to dark mode")
    }

    // MARK: Helpers

    @ViewBuilder
    private func fieldGroup<Content: View>(label: String,
                                           error: String? = nil,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: InterSpacing.x1_5) {
            Text(label)
                .font(InterFont.swiftUI(InterFont.Size.caption, .medium))
                .foregroundStyle(Color(nsColor: InterColor.foreground))
            content()
            if let error {
                FieldError(message: error)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: error)
    }

    private func strengthColor(_ score: Int) -> Color {
        switch score {
        case 1:  return Color(nsColor: InterStatus.danger)
        case 2:  return Color(nsColor: InterStatus.warning)
        case 3:  return Color(nsColor: InterStatus.success)
        default: return Color(nsColor: NSColor(hex: 0x059669)) // emerald-600
        }
    }

    private func strengthLabelColor(_ score: Int) -> Color {
        if score >= 3 { return Color(nsColor: NSColor(hex: 0x059669)) }
        if score == 2 { return Color(nsColor: NSColor(hex: 0xD97706)) }
        return Color(nsColor: InterStatus.danger)
    }

    /// CTA / logo use a near-black↔white inversion of the surface (not the theme foreground).
    private func invertedBackground(hovering: Bool) -> Color {
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

// MARK: - OAuth button (full-width, hover state + hand cursor)

private struct OAuthButton<Icon: View>: View {
    let label: String
    let enabled: Bool
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: InterSpacing.x2) {
                icon().frame(width: 18, height: 18)
                Text(label)
                    .font(InterFont.swiftUI(InterFont.Size.secondary, .medium))
                    .foregroundStyle(Color(nsColor: InterColor.foreground))
            }
            .frame(maxWidth: .infinity)
            .frame(height: InterControl.primaryHeight)
            .background(Color(nsColor: hovering ? InterColor.muted : InterColor.card))
            .overlay(
                RoundedRectangle(cornerRadius: InterRadius.lg, style: .continuous)
                    .stroke(Color(nsColor: InterColor.border), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: InterRadius.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        .handCursor()
        .onHover { hovering = $0 }
        .disabled(!enabled)
    }
}

// MARK: - Text link (hover underline + hand cursor)

private struct TextLink: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(InterFont.swiftUI(InterFont.Size.caption, .medium))
                .foregroundStyle(Color(nsColor: InterColor.primary))
                .underline(hovering)
        }
        .buttonStyle(.plain)
        .handCursor()
        .onHover { hovering = $0 }
    }
}

// MARK: - Inputs

/// Inline field-error message shown directly under an input (small, red, exclamation).
private struct FieldError: View {
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11))
            Text(message)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(InterFont.swiftUI(InterFont.Size.dense11))
        .foregroundStyle(Color(nsColor: InterStatus.danger))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
