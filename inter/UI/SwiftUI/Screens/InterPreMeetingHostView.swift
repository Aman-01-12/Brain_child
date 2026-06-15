//
//  InterPreMeetingHostView.swift
//  inter
//
//  Obj-C ⇆ SwiftUI bridge for the pre-meeting sheet. An NSView that hosts
//  `PreMeetingView` and re-exposes exactly the surface the legacy
//  `InterPreMeetingPanel` shell needs: the mode (full / compact / defaults
//  editor), `setDisplayName:` / `setUserTier:` forwarders, and block callbacks
//  for the delegate actions.
//
//  This bridge — not the view model — owns the boundary with the shared
//  @objc `InterPreMeetingSettings` model (also consumed by the schedule
//  screen): it seeds the view model from the saved defaults, collects the
//  fields back into a settings object on submit, and performs the
//  `saveToUserDefaults` persistence on BOTH start and defaults-save, exactly
//  like the legacy `_startTapped:`.
//

import AppKit
import SwiftUI

@objc(InterPreMeetingHostView)
public final class InterPreMeetingHostView: NSView {

    private let viewModel: PreMeetingViewModel
    private var hosting: NSHostingView<PreMeetingView>!

    /// Fired when the user starts the meeting (full/compact modes). The
    /// settings have already been persisted as the new defaults.
    @objc public var onStart: ((InterPreMeetingSettings) -> Void)?
    /// Fired when the user cancels/closes.
    @objc public var onCancel: (() -> Void)?
    /// Fired when the defaults editor saves (settings already persisted).
    @objc public var onSaveDefaults: (() -> Void)?
    /// Fired when compact mode reveals the full controls ("Edit Settings").
    @objc public var onRequestExpand: (() -> Void)?

    @objc public init(frame frameRect: NSRect, compactMode: Bool, defaultsEditor: Bool) {
        let mode: PreMeetingMode = defaultsEditor ? .defaultsEditor
                                 : compactMode ? .compact : .fullSetup
        self.viewModel = PreMeetingViewModel(mode: mode)
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure() {
        seedFromSavedDefaults()

        viewModel.onStart = { [weak self] in
            guard let self else { return }
            let settings = self.collectSettings()
            settings.saveToUserDefaults()
            self.onStart?(settings)
        }
        viewModel.onSaveDefaults = { [weak self] in
            guard let self else { return }
            let settings = self.collectSettings()
            settings.saveToUserDefaults()
            self.onSaveDefaults?()
        }
        viewModel.onCancel = { [weak self] in self?.onCancel?() }
        viewModel.onRequestExpand = { [weak self] in self?.onRequestExpand?() }

        let host = NSHostingView(rootView: PreMeetingView(viewModel: viewModel))
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

    // MARK: - Legacy InterPreMeetingPanel API (forwarded)

    @objc public func setDisplayName(_ displayName: String) {
        viewModel.setDisplayName(displayName)
    }

    @objc public func setUserTier(_ tier: String) {
        viewModel.setUserTier(tier)
    }

    /// Seed the per-meeting name (green-room → Meeting Settings reopen path).
    @objc public func setMeetingName(_ name: String) {
        viewModel.meetingName = name
    }

    /// Seed the per-meeting password (empty = no password).
    @objc public func setMeetingPassword(_ password: String) {
        viewModel.requirePassword = !password.isEmpty
        viewModel.password = password
    }

    // MARK: - Settings boundary (shared @objc model)

    private func seedFromSavedDefaults() {
        let s = InterPreMeetingSettings.withDefaults()
        viewModel.loadDefaults(muteOnJoin: s.muteOnJoin,
                               cameraOffOnJoin: s.cameraOffOnJoin,
                               allowUnmuting: s.allowUnmuting,
                               lobbyEnabled: s.lobbyEnabled,
                               joinBeforeHost: s.joinBeforeHost,
                               chatPermissions: s.chatPermissions,
                               sharingPermissions: s.sharingPermissions,
                               shareConflictPolicy: s.shareConflictPolicy,
                               autoRecord: s.autoRecord,
                               autoTranscript: s.autoTranscript,
                               allowCoHostLocalRecording: s.allowCoHostLocalRecording)
    }

    private func collectSettings() -> InterPreMeetingSettings {
        let s = InterPreMeetingSettings()
        s.meetingDisplayName = viewModel.meetingName
        s.meetingPassword = PreMeetingViewModel.effectivePassword(
            requirePassword: viewModel.requirePassword, password: viewModel.password)
        s.muteOnJoin = viewModel.muteOnJoin
        s.cameraOffOnJoin = viewModel.cameraOffOnJoin
        s.allowUnmuting = viewModel.allowUnmuting
        s.lobbyEnabled = viewModel.lobbyEnabled
        s.joinBeforeHost = viewModel.joinBeforeHost
        s.chatPermissions = viewModel.chatPermissions
        s.sharingPermissions = viewModel.sharingPermissions
        s.shareConflictPolicy = viewModel.shareConflictPolicy
        // Pro toggles collect as OFF for free tier (legacy && _isPro guard).
        s.autoRecord = viewModel.autoRecord && viewModel.isPro
        s.autoTranscript = viewModel.autoTranscript && viewModel.isPro
        s.allowCoHostLocalRecording = viewModel.allowCoHostLocalRecording && viewModel.isPro
        return s
    }
}
