//
//  InterSettingsHostView.swift
//  inter
//
//  Obj-C ⇆ SwiftUI bridge for the unified Settings window. Self-contained
//  (Teams-style): builds its own data layer from the injected InterTokenService
//  + InterLocalMediaController + AVFoundation, hosts `SettingsView`, and
//  exposes `selectTab` deep links so AppDelegate's existing
//  `openSettingsWindow` / `openAccountSettingsWindow` selectors land on the
//  right tab. Sign-out and account-deleted flow back through blocks.
//

import AppKit
import SwiftUI
import AVFoundation

// MARK: - Concrete account transport (InterTokenService)

private final class TokenServiceAccountTransport: InterAccountSettingsTransport {
    private weak var tokenService: InterTokenService?

    init(tokenService: InterTokenService?) {
        self.tokenService = tokenService
    }

    func fetchProfile(completion: @escaping ([String: Any]?, Error?) -> Void) {
        guard let ts = tokenService else { completion(nil, nil); return }
        ts.fetchProfile { json, error in completion(json, error) }
    }
    func updateProfile(displayName: String?, timezone: String?, language: String?,
                       completion: @escaping ([String: Any]?, Error?) -> Void) {
        guard let ts = tokenService else { completion(nil, nil); return }
        ts.updateProfile(displayName: displayName, timezone: timezone, language: language) { json, error in
            completion(json, error)
        }
    }
    func changePassword(current: String, new: String, completion: @escaping (Error?) -> Void) {
        guard let ts = tokenService else { completion(nil); return }
        ts.changePassword(currentPassword: current, newPassword: new) { completion($0) }
    }
    func changeEmail(password: String, newEmail: String, completion: @escaping (Error?) -> Void) {
        guard let ts = tokenService else { completion(nil); return }
        ts.changeEmail(password: password, newEmail: newEmail) { completion($0) }
    }
    func listSessions(completion: @escaping ([[String: Any]]?, Error?) -> Void) {
        guard let ts = tokenService else { completion([], nil); return }
        ts.listSessions { rows, error in completion(rows, error) }
    }
    func revokeSession(id: String, completion: @escaping (Error?) -> Void) {
        guard let ts = tokenService else { completion(nil); return }
        ts.revokeSession(sessionId: id) { completion($0) }
    }
    func deleteAccount(password: String, completion: @escaping (Error?) -> Void) {
        guard let ts = tokenService else { completion(nil); return }
        ts.deleteAccount(password: password) { completion($0) }
    }
    func fetchCalendarStatus(completion: @escaping ([String: Any]?, Error?) -> Void) {
        guard let ts = tokenService else { completion(nil, nil); return }
        ts.fetchCalendarStatus { status, error in completion(status, error) }
    }
    func connectCalendar(provider: String, completion: @escaping (String?, Error?) -> Void) {
        guard let ts = tokenService else { completion(nil, nil); return }
        ts.requestCalendarConnectURL(provider: provider) { url, error in completion(url, error) }
    }
    func disconnectCalendar(provider: String, completion: @escaping (Bool, Error?) -> Void) {
        guard let ts = tokenService else { completion(false, nil); return }
        ts.disconnectCalendar(provider: provider) { ok, error in completion(ok, error) }
    }
}

// MARK: - Concrete device provider (AVFoundation + media controller prefs)

private final class AVDevicePreferencesProvider: InterDevicePreferencesProviding {
    // Mirrors the keys InterLocalMediaController persists/reads.
    private let audioKey = "InterPreferredAudioDeviceID"
    private let videoKey = "InterPreferredVideoDeviceID"
    private weak var mediaController: InterLocalMediaController?

    init(mediaController: InterLocalMediaController?) {
        self.mediaController = mediaController
    }

    func audioInputDevices() -> [MediaDeviceOption] {
        // Prefer the media controller's filtered list (skips problematic devices).
        if let options = mediaController?.availableAudioInputOptions() {
            return options.compactMap { dict in
                guard let id = dict["id"], let name = dict["name"] else { return nil }
                return MediaDeviceOption(id: id, name: name)
            }
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified)
        return discovery.devices.map { MediaDeviceOption(id: $0.uniqueID, name: $0.localizedName) }
    }

    func videoInputDevices() -> [MediaDeviceOption] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external]
        if #available(macOS 14.0, *) { types.append(.continuityCamera) }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified)
        return discovery.devices.map { MediaDeviceOption(id: $0.uniqueID, name: $0.localizedName) }
    }

    func preferredAudioDeviceID() -> String? {
        UserDefaults.standard.string(forKey: audioKey)
    }
    func preferredVideoDeviceID() -> String? {
        UserDefaults.standard.string(forKey: videoKey)
    }
    func setPreferredAudioDeviceID(_ id: String?) {
        // Route through the media controller when available so its in-memory
        // preference stays in sync (it persists to the same key).
        if let controller = mediaController {
            controller.storePreferredAudioDeviceID(id)
        } else if let id = id {
            UserDefaults.standard.set(id, forKey: audioKey)
        } else {
            UserDefaults.standard.removeObject(forKey: audioKey)
        }
    }
    func setPreferredVideoDeviceID(_ id: String?) {
        if let id = id {
            UserDefaults.standard.set(id, forKey: videoKey)
        } else {
            UserDefaults.standard.removeObject(forKey: videoKey)
        }
    }
}

// MARK: - Host view

/// Obj-C-visible tab anchors for deep links into the settings window.
@objc public enum InterSettingsTabAnchor: Int {
    case profile = 0
    case meetingDefaults = 1
}

@objc(InterSettingsHostView)
public final class InterSettingsHostView: NSView {

    private let accountVM: AccountSettingsViewModel
    private let defaultsVM = MeetingDefaultsViewModel()
    private let devicesVM: DevicePreferencesViewModel
    private let tabModel = SettingsTabModel()
    private var hosting: NSHostingView<AnyView>!
    private weak var tokenService: InterTokenService?

    /// Fired when the user taps Sign Out on the Profile tab.
    @objc public var onSignOut: (() -> Void)?
    /// Fired after the server confirms account deletion.
    @objc public var onAccountDeleted: (() -> Void)?
    /// Fired from the signed-out gate — the host opens the login window.
    @objc public var onSignIn: (() -> Void)?
    /// Fired from the signed-out gate — login window in register mode.
    @objc public var onSignUp: (() -> Void)?

    @objc public init(frame frameRect: NSRect,
                      tokenService: InterTokenService?,
                      mediaController: InterLocalMediaController?) {
        let transport = TokenServiceAccountTransport(tokenService: tokenService)
        self.accountVM = AccountSettingsViewModel(transport: transport)
        self.devicesVM = DevicePreferencesViewModel(provider: AVDevicePreferencesProvider(mediaController: mediaController))
        super.init(frame: frameRect)

        self.tokenService = tokenService
        accountVM.isAuthenticated = tokenService?.isAuthenticated ?? false
        defaultsVM.tier = tokenService?.currentTier ?? "free"
        accountVM.onAccountDeleted = { [weak self] in self?.onAccountDeleted?() }

        let root = SettingsRootView(
            account: accountVM, defaults: defaultsVM, devices: devicesVM, tabModel: tabModel,
            onSignOut: { [weak self] in self?.onSignOut?() },
            onSignIn: { [weak self] in self?.onSignIn?() },
            onSignUp: { [weak self] in self?.onSignUp?() }
        )
        let host = NSHostingView(rootView: AnyView(root))
        host.translatesAutoresizingMaskIntoConstraints = false
        self.hosting = host
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Deep-link to a tab (Obj-C callers use the anchor enum).
    @objc public func selectAnchor(_ anchor: InterSettingsTabAnchor) {
        switch anchor {
        case .profile: tabModel.tab = .profile
        case .meetingDefaults: tabModel.tab = .meetingDefaults
        }
    }

    /// Refresh server-backed state (call when the window is re-shown).
    @objc public func reload() {
        // Re-read the auth state first — the gate flips live on sign-in/out.
        accountVM.isAuthenticated = tokenService?.isAuthenticated ?? false
        accountVM.load()
        devicesVM.load()
        defaultsVM.reload()
    }

    /// Update the tier gate (call when auth/tier changes while open).
    @objc public func setTier(_ tier: String) {
        defaultsVM.tier = tier
    }
}

// MARK: - Tab selection model + root wrapper

@MainActor
final class SettingsTabModel: ObservableObject {
    @Published var tab: SettingsTab = .profile
}

private struct SettingsRootView: View {
    @ObservedObject var account: AccountSettingsViewModel
    @ObservedObject var defaults: MeetingDefaultsViewModel
    @ObservedObject var devices: DevicePreferencesViewModel
    @ObservedObject var tabModel: SettingsTabModel
    var onSignOut: () -> Void
    var onSignIn: () -> Void
    var onSignUp: () -> Void

    var body: some View {
        SettingsView(account: account, defaults: defaults, devices: devices,
                     tab: $tabModel.tab, onSignOut: onSignOut,
                     onSignIn: onSignIn, onSignUp: onSignUp)
    }
}
