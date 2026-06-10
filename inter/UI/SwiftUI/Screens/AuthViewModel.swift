//
//  AuthViewModel.swift
//  inter
//
//  State + logic for the auth (login/register) screen. Pure Swift + ObservableObject so
//  it is unit-testable in isolation. The password-strength scoring is ported verbatim from
//  the previous AppKit panel (`InterLoginPanel.scoreForPassword:`) — which already matched
//  the catalogue's `getStrength()` — and locked by `AuthViewModelTests`. Validation mirrors
//  the old panel's `handleAction:` exactly so the delegate contract is unchanged.
//

import Foundation
import Combine

public enum AuthMode {
    case signIn
    case signUp
}

/// Password strength on a 0–4 scale (0 = empty, 1 = weak … 4 = very strong).
public enum PasswordStrength {

    /// Verbatim port of the live algorithm (do not "improve" without updating the parity test).
    public static func score(for password: String) -> Int {
        if password.isEmpty { return 0 }
        if password.count < 8 { return 1 }
        var hasLower = false, hasUpper = false, hasDigit = false, hasSymbol = false
        for c in password.unicodeScalars {
            switch c {
            case "a"..."z": hasLower = true
            case "A"..."Z": hasUpper = true
            case "0"..."9": hasDigit = true
            default:        hasSymbol = true
            }
        }
        let variety = (hasLower ? 1 : 0) + (hasUpper ? 1 : 0) + (hasDigit ? 1 : 0) + (hasSymbol ? 1 : 0)
        if password.count >= 12 && variety >= 3 { return 4 }
        if password.count >= 10 && variety >= 3 { return 3 }
        if variety >= 2 { return 2 }
        return 1
    }

    /// Label per score, matching the catalogue's STRENGTH_META.
    public static func label(for score: Int) -> String {
        ["", "Weak", "Fair", "Strong", "Very strong"][max(0, min(4, score))]
    }
}

public final class AuthViewModel: ObservableObject {

    @Published public var mode: AuthMode = .signIn
    @Published public var email = ""
    @Published public var password = ""
    @Published public var displayName = ""
    @Published public var showPassword = false
    /// Per-field validation errors (inline, shown under the offending field with a red
    /// border + icon). `nil` = no error. Industry-standard inline validation.
    @Published public var emailError: String?
    @Published public var passwordError: String?
    @Published public var displayNameError: String?
    /// Form-level error for problems not tied to a single field (e.g. "Server unreachable",
    /// or an ambiguous "Invalid email or password" that must not reveal which field failed).
    @Published public var formError: String?
    /// Non-error confirmation (e.g. "If that email is registered, you'll receive a reset
    /// link shortly."). Shown in a neutral/success banner, mutually exclusive with errors.
    @Published public var infoMessage: String?
    @Published public var isLoading = false
    /// Driven by the host's `setActionsEnabled:` — disables the submit + toggle while busy.
    @Published public var controlsEnabled = true
    /// Manual light/dark override for the auth surface (default dark). The host applies this
    /// to its hosting view + window so theme tokens re-resolve and stage tokens stay fixed.
    @Published public var appearance: InterAppearance.Mode = .dark

    // Callbacks bridged to the existing Obj-C delegate by `InterAuthHostView`.
    public var onLogin: ((_ email: String, _ password: String) -> Void)?
    public var onRegister: ((_ email: String, _ password: String, _ displayName: String) -> Void)?
    public var onOAuth: ((_ provider: String) -> Void)?
    public var onForgotPassword: ((_ email: String) -> Void)?

    public init() {}

    public var strengthScore: Int { PasswordStrength.score(for: password) }
    public var strengthLabel: String { PasswordStrength.label(for: strengthScore) }
    /// Strength row shows only in register mode and only once the user starts typing.
    public var showsStrength: Bool { mode == .signUp && !password.isEmpty }

    /// Clear every error (all fields + form) and any info message. Called before a submit
    /// and on mode switch.
    public func clearErrors() {
        emailError = nil
        passwordError = nil
        displayNameError = nil
        formError = nil
        infoMessage = nil
    }

    /// Validate ALL fields (so every problem is highlighted at once, not one at a time) and
    /// fire the matching delegate callback only when everything passes. Validation rules
    /// mirror the legacy panel exactly.
    public func submit() {
        clearErrors()
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        var valid = true

        if trimmedEmail.isEmpty {
            emailError = "Email is required."
            valid = false
        }
        if password.count < 8 {
            passwordError = "Password must be at least 8 characters."
            valid = false
        }
        if mode == .signUp && trimmedName.isEmpty {
            displayNameError = "Display name is required."
            valid = false
        }
        guard valid else { return }

        if mode == .signUp {
            onRegister?(trimmedEmail, password, trimmedName)
        } else {
            onLogin?(trimmedEmail, password)
        }
    }

    /// Route a server/auth error string to the most relevant field, or to the form-level
    /// banner when it isn't field-specific. An error mentioning BOTH email and password
    /// (e.g. "Invalid email or password") stays form-level so we don't reveal which failed.
    public func applyServerError(_ message: String) {
        infoMessage = nil
        let lower = message.lowercased()
        let mentionsEmail = lower.contains("email")
        let mentionsPassword = lower.contains("password")
        if mentionsEmail && mentionsPassword {
            formError = message
        } else if mentionsEmail {
            emailError = message
        } else if mentionsPassword {
            passwordError = message
        } else if lower.contains("display name") {
            displayNameError = message
        } else {
            formError = message
        }
    }

    public func toggleMode() {
        mode = (mode == .signIn) ? .signUp : .signIn
        clearErrors()
        password = ""
    }

    public func tapOAuth(_ provider: String) {
        onOAuth?(provider)
    }

    /// Request a password-reset link for the entered email. Requires an email (reuses the
    /// field the user already filled); if empty, flags the email field instead of prompting.
    public func tapForgotPassword() {
        clearErrors()
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else {
            emailError = "Enter your email above, then tap “Forgot password?”."
            return
        }
        onForgotPassword?(trimmedEmail)
    }

    /// Show a non-error confirmation (clears any errors first so they aren't shown together).
    public func showInfo(_ message: String) {
        clearErrors()
        infoMessage = message
    }

    public func toggleAppearance() {
        appearance = (appearance == .dark) ? .light : .dark
    }
}
