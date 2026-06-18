//
//  PreMeetingViewModel.swift
//  inter
//
//  Drives the SwiftUI pre-meeting sheet in its three modes:
//    • fullSetup    — first-time host: every setting visible ("Save & Start").
//    • compact      — returning host: name + opt-in password + defaults summary,
//                     with an "Edit Settings" reveal of the full controls.
//    • defaultsEditor — Settings → Meeting Defaults: full controls minus the
//                     per-meeting rows (name/password); Save persists only.
//
//  The view model holds plain fields; the BRIDGE converts to/from the shared
//  @objc InterPreMeetingSettings model (also consumed by the schedule screen)
//  and performs the UserDefaults persistence, keeping this class hermetic for
//  unit tests.
//
//  Legacy semantics preserved: start is blocked while the password toggle is
//  on with an empty field; pro-gated toggles collect as OFF for free tier; the
//  password and meeting name are never part of the persisted defaults.
//

import Foundation
import Combine

/// Which presentation the sheet uses.
public enum PreMeetingMode: Equatable {
    /// First-time host — full settings, "Save & Start Meeting".
    case fullSetup
    /// Returning host — compact: name + password + summary + Edit Settings.
    case compact
    /// Defaults editor from Settings — full minus per-meeting rows, "Save".
    case defaultsEditor
}

@MainActor
public final class PreMeetingViewModel: ObservableObject {

    // MARK: - Mode

    @Published public private(set) var mode: PreMeetingMode
    /// Compact mode only: whether "Edit Settings" revealed the full controls.
    @Published public private(set) var advancedExpanded: Bool = false

    // MARK: - General (per-meeting; never persisted)

    @Published public var meetingName: String = ""
    @Published public var requirePassword: Bool = false {
        didSet { if !requirePassword { password = "" } }
    }
    @Published public var password: String = ""

    // MARK: - Participant controls

    @Published public var muteOnJoin: Bool = false
    @Published public var cameraOffOnJoin: Bool = false
    @Published public var allowUnmuting: Bool = true

    // MARK: - Security

    @Published public var lobbyEnabled: Bool = false
    @Published public var joinBeforeHost: Bool = false

    // MARK: - Chat & sharing (constant keys from InterPreMeetingPanel.h)

    @Published public var chatPermissions: String = InterChatPermissionsEveryone
    @Published public var sharingPermissions: String = InterSharingPermissionsHostOnly
    @Published public var shareConflictPolicy: String = InterSharingConflictOneAtATime

    // MARK: - Recording (pro-gated)

    @Published public var autoRecord: Bool = false
    @Published public var autoTranscript: Bool = false
    @Published public var allowCoHostLocalRecording: Bool = false
    @Published public private(set) var isPro: Bool = false

    /// Set when a submit was blocked by the empty-password rule; the view
    /// focuses the password field when this increments.
    @Published public private(set) var passwordErrorTick: Int = 0

    /// Action callbacks — wired by the bridge.
    public var onStart: (() -> Void)?
    public var onCancel: (() -> Void)?
    public var onSaveDefaults: (() -> Void)?
    public var onRequestExpand: (() -> Void)?

    public init(mode: PreMeetingMode) {
        self.mode = mode
    }

    // MARK: - Inputs from the bridge

    /// Pre-fill "{name}'s Meeting" (legacy setDisplayName:).
    public func setDisplayName(_ displayName: String) {
        guard !displayName.isEmpty else { return }
        meetingName = "\(displayName)'s Meeting"
    }

    /// Gate pro toggles. "pro" / "hiring" unlock (legacy setUserTier:).
    public func setUserTier(_ tier: String) {
        isPro = ["pro", "hiring"].contains(tier)
        if !isPro {
            autoRecord = false
            autoTranscript = false
            allowCoHostLocalRecording = false
        }
    }

    /// Seed the toggle/dropdown fields from the saved defaults (bridge reads
    /// the shared @objc model and pushes plain values here).
    public func loadDefaults(muteOnJoin: Bool, cameraOffOnJoin: Bool, allowUnmuting: Bool,
                             lobbyEnabled: Bool, joinBeforeHost: Bool,
                             chatPermissions: String, sharingPermissions: String,
                             shareConflictPolicy: String,
                             autoRecord: Bool, autoTranscript: Bool,
                             allowCoHostLocalRecording: Bool) {
        self.muteOnJoin = muteOnJoin
        self.cameraOffOnJoin = cameraOffOnJoin
        self.allowUnmuting = allowUnmuting
        self.lobbyEnabled = lobbyEnabled
        self.joinBeforeHost = joinBeforeHost
        self.chatPermissions = chatPermissions
        self.sharingPermissions = sharingPermissions
        self.shareConflictPolicy = shareConflictPolicy
        self.autoRecord = autoRecord
        self.autoTranscript = autoTranscript
        self.allowCoHostLocalRecording = allowCoHostLocalRecording
    }

    // MARK: - Derived state

    public var isDefaultsEditor: Bool { mode == .defaultsEditor }

    /// Per-meeting rows (name/password) are hidden in the defaults editor.
    public var showsPerMeetingFields: Bool { mode != .defaultsEditor }

    /// Whether the compact summary (not the full controls) is showing.
    public var showsCompactSummary: Bool { mode == .compact && !advancedExpanded }

    public var titleText: String {
        switch mode {
        case .fullSetup:      return "Meeting Settings"
        case .compact:        return "Starting your meeting…"
        case .defaultsEditor: return "Default Meeting Settings"
        }
    }

    public var submitTitle: String {
        switch mode {
        // The green room follows the sheet in the host flow, so the CTA is
        // "Next", not "Start" — the meeting starts from the green room.
        case .fullSetup:      return "Save & Next"
        case .compact:        return "Start Meeting"
        case .defaultsEditor: return "Save"
        }
    }

    public var cancelTitle: String {
        mode == .defaultsEditor ? "Close" : "Cancel"
    }

    /// The blocked state the legacy panel beeped on.
    public var passwordInvalid: Bool {
        showsPerMeetingFields && requirePassword
            && password.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Summary rows for the compact card (label, value, emphasized-green flag).
    public var summaryRows: [(label: String, value: String, positive: Bool)] {
        [("Waiting room", lobbyEnabled ? "Enabled" : "Off", lobbyEnabled),
         ("Mic on join", muteOnJoin ? "Muted" : "On", false),
         ("Camera on join", cameraOffOnJoin ? "Off" : "On", false),
         ("Chat", PreMeetingViewModel.chatTitle(chatPermissions), false),
         ("Screen sharing", PreMeetingViewModel.sharingTitle(sharingPermissions), false)]
    }

    // MARK: - Actions

    /// Compact "Edit Settings" — reveal full controls + ask the window to grow.
    public func expandAdvanced() {
        guard mode == .compact, !advancedExpanded else { return }
        advancedExpanded = true
        onRequestExpand?()
    }

    /// Submit: Start (full/compact) or Save (defaults editor).
    public func submit() {
        if passwordInvalid {
            passwordErrorTick += 1
            return
        }
        if mode == .defaultsEditor {
            onSaveDefaults?()
        } else {
            onStart?()
        }
    }

    public func cancel() {
        onCancel?()
    }

    // MARK: - Pure helpers (unit-tested; titles match the legacy popups)

    public nonisolated static func chatTitle(_ key: String) -> String {
        switch key {
        case InterChatPermissionsHostOnly: return "Host Only"
        case InterChatPermissionsDisabled: return "Disabled"
        default:                           return "Everyone"
        }
    }

    public nonisolated static func sharingTitle(_ key: String) -> String {
        switch key {
        case InterSharingPermissionsEveryone: return "Everyone"
        case InterSharingPermissionsRequest:  return "Request to Share"
        default:                              return "Host Only"
        }
    }

    public nonisolated static func conflictTitle(_ key: String) -> String {
        switch key {
        case InterSharingConflictHostCanPreempt: return "Host Can Take Over"
        case InterSharingConflictAnyCanPreempt:  return "Anyone Can Take Over"
        default:                                 return "One at a Time"
        }
    }

    /// The password that ships with the meeting: only when the toggle is on
    /// and the field is non-empty (legacy collect rule).
    public nonisolated static func effectivePassword(requirePassword: Bool, password: String) -> String {
        guard requirePassword else { return "" }
        let trimmed = password.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "" : password
    }
}
