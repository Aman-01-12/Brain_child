//
//  InterAuthHostView.swift
//  inter
//
//  Obj-C ⇆ SwiftUI bridge for the auth screen. An NSView that hosts `AuthView` and
//  re-exposes exactly the surface the legacy `InterLoginPanel` had: block callbacks for
//  the delegate actions, and `showError:/clearError:/setLoading:/setActionsEnabled:`
//  forwarders. This lets `InterLoginPanel` keep its public `.h` and delegate contract
//  unchanged (so `AppDelegate` is untouched) while its body is now SwiftUI.
//
//  It also bridges the in-screen light/dark toggle: when the view model's `appearance`
//  changes, the hosting view + window `NSAppearance` are updated so theme tokens re-resolve
//  (stage/fixed tokens are unaffected by design).
//

import AppKit
import SwiftUI
import Combine

@objc(InterAuthHostView)
public final class InterAuthHostView: NSView {

    private let viewModel = AuthViewModel()
    private var hosting: NSHostingView<AuthView>!
    private var cancellables = Set<AnyCancellable>()

    /// Fired when the user submits a valid login (email, password).
    @objc public var onLogin: ((String, String) -> Void)?
    /// Fired when the user submits a valid registration (email, password, displayName).
    @objc public var onRegister: ((String, String, String) -> Void)?
    /// Fired when the user taps an OAuth provider ("google" / "microsoft").
    @objc public var onOAuth: ((String) -> Void)?
    /// Fired when the user taps "Forgot password?" with an email entered. Carries the email
    /// so the delegate can request a reset link without re-prompting.
    @objc public var onForgotPassword: ((String) -> Void)?

    @objc public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure() {
        viewModel.onLogin = { [weak self] email, password in self?.onLogin?(email, password) }
        viewModel.onRegister = { [weak self] email, password, name in self?.onRegister?(email, password, name) }
        viewModel.onOAuth = { [weak self] provider in self?.onOAuth?(provider) }
        viewModel.onForgotPassword = { [weak self] email in self?.onForgotPassword?(email) }

        let host = NSHostingView(rootView: AuthView(viewModel: viewModel))
        host.translatesAutoresizingMaskIntoConstraints = false
        self.hosting = host
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Apply the manual appearance (default dark) and keep it in sync with the toggle.
        viewModel.$appearance
            .sink { [weak self] mode in self?.applyAppearance(mode) }
            .store(in: &cancellables)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Re-apply so the window titlebar matches once we're actually in a window.
        applyAppearance(viewModel.appearance)
    }

    private func applyAppearance(_ mode: InterAppearance.Mode) {
        let ns = InterAppearance.nsAppearance(mode)
        appearance = ns
        hosting?.appearance = ns
        window?.appearance = ns
    }

    // MARK: Legacy InterLoginPanel API (forwarded to the view model)

    /// Preset the screen to register (sign-up) or sign-in mode before showing.
    @objc public func setRegisterMode(_ isRegister: Bool) {
        viewModel.mode = isRegister ? .signUp : .signIn
    }

    @objc public func showError(_ message: String) {
        viewModel.isLoading = false
        // Route to the offending field (inline) when we can tell which one; otherwise the
        // form-level banner. This keeps server-side auth errors consistent with the new
        // inline-validation UX.
        viewModel.applyServerError(message)
    }

    @objc public func showInfo(_ message: String) {
        viewModel.isLoading = false
        viewModel.showInfo(message)
    }

    @objc public func clearError() {
        viewModel.clearErrors()
    }

    @objc public func setLoading(_ loading: Bool) {
        viewModel.isLoading = loading
    }

    @objc public func setActionsEnabled(_ enabled: Bool) {
        viewModel.controlsEnabled = enabled
    }
}
