//
//  CallControlBarViewModel.swift
//  inter
//
//  State container for the SwiftUI in-call control bar (normal mode; the
//  interviewer also runs in normal mode — only the candidate is secure/kiosk).
//  Mirrors the legacy InterLocalCallControlPanel setter surface so the thin
//  shell + InterMediaWiringController keep working unchanged, and adds the
//  approved bar design:
//
//    Mic(^ audio-input flyout) · Camera (no ^ — live camera switch deferred) ·
//    Share (picker decides what; no mode selector) · Chat · Poll · Q&A ·
//    Raise Hand · Record · More · Leave
//
//  More menu: share-permission selector (host), Moderation (host), Requests
//  (host/co-host), React ("not available yet"), View Recordings.
//  Participants get button-state feedback only (lit hand, "Requested…" mic
//  title override pushed by the wiring controller).
//

import Foundation
import Combine

public struct AudioInputOption: Equatable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// One row of the in-call Participants panel.
public struct CallParticipant: Equatable, Identifiable {
    public let id: String        // identity
    public let name: String
    public let isHostMuted: Bool

    public init(id: String, name: String, isHostMuted: Bool = false) {
        self.id = id
        self.name = name
        self.isHostMuted = isHostMuted
    }
}

@MainActor
public final class CallControlBarViewModel: ObservableObject {

    // MARK: - Media state (pushed by the wiring controller via the shell)

    @Published public var cameraEnabled = false
    @Published public var cameraInteractive = true
    @Published public var cameraTitleOverride: String?
    @Published public var micEnabled = false
    @Published public var micTitleOverride: String?     // "Ask to Unmute" / "Request Sent…"
    /// Local "mute speaker" — silences incoming meeting audio without muting the
    /// mic or changing system volume. Pushed back by the bridge after the engine
    /// output mute is applied.
    @Published public var speakerMuted = false
    @Published public var sharingActive = false
    @Published public var sharePending = false
    @Published public var shareEnabled = true

    // MARK: - Status strips

    @Published public var connectionStatusText = ""
    @Published public var roomCode = ""
    @Published public var mediaStatusText = ""
    @Published public var shareStatusText = ""
    /// Network quality level (InterNetworkQualityLevel raw value): 0 unknown,
    /// 1 lost, 2 poor, 3 good, 4 excellent. Rendered as signal bars beside the
    /// room code (re-homed here when the floating self-preview PiP was removed).
    @Published public var networkQuality = 0

    // MARK: - Audio inputs (mic ^ flyout)

    @Published public var audioInputs: [AudioInputOption] = []
    @Published public var selectedAudioInputID: String?

    // MARK: - Recording

    @Published public var recordingActive = false
    @Published public var recordingVisible = false
    @Published public var viewRecordingsVisible = false

    // MARK: - Role-gated chrome

    /// "everyone" | "request" | "hostOnly"; nil hides the selector (non-hosts).
    @Published public var sharePermissionMode: String?
    @Published public var sharePermissionEnabled = true
    @Published public var moderationVisible = false
    @Published public var requestsVisible = false
    /// Total pending requests across all four queues (badge on More).
    @Published public var pendingRequestCount = 0
    /// Waiting-room (lobby) entry — host/co-host only.
    @Published public var lobbyVisible = false
    @Published public var lobbyWaitingCount = 0
    /// Self-rename — shown when the participant may rename themselves.
    @Published public var renameVisible = false

    // MARK: - Moderation menu state (pulled fresh when the menu opens)

    @Published public var allMuted = false
    @Published public var allCamerasOff = false
    @Published public var chatDisabled = false
    @Published public var coHostRecordingAllowed = false
    @Published public var meetingLocked = false
    @Published public var hasMeetingPassword = false
    /// Plaintext known locally (the session that set it) → View/Copy offered.
    @Published public var hasPlaintextPassword = false
    @Published public var shareConflictPolicy = "oneattime"
    /// Host-only rows (co-host local recording toggle).
    @Published public var isHostRole = false

    // MARK: - Participants panel

    @Published public var participants: [CallParticipant] = []

    // MARK: - Panels + self state

    @Published public var chatUnread = 0
    @Published public var qaUnread = 0
    @Published public var handRaised = false
    /// Ephemeral "not available yet" feedback for the React menu item.
    @Published public var showReactComingSoon = false

    // NOTE: No interview-tools control here. Tools are candidate-driven: the
    // secure window selects and captures them (InterShareModeThisApp); the
    // interviewer just receives the share track. Re-add only if interviewer
    // remote tool control ships (DataChannel signal + candidate consent).

    // MARK: - Action callbacks (shell → AppDelegate handlers)

    public var onToggleCamera: (() -> Void)?
    public var onToggleMic: (() -> Void)?
    public var onToggleSpeaker: (() -> Void)?
    public var onSelectAudioInput: ((String?) -> Void)?
    public var onShare: (() -> Void)?
    public var onToggleChat: (() -> Void)?
    public var onTogglePoll: (() -> Void)?
    public var onToggleQA: (() -> Void)?
    public var onToggleRaiseHand: (() -> Void)?
    public var onToggleRecording: (() -> Void)?
    public var onViewRecordings: (() -> Void)?
    public var onSharePermissionChange: ((String) -> Void)?
    public var onOpenModeration: (() -> Void)?
    public var onOpenRequests: (() -> Void)?
    public var onOpenLobby: (() -> Void)?
    public var onRename: (() -> Void)?
    public var onLeave: (() -> Void)?

    // Moderation actions (route to the existing AppDelegate selectors).
    public var onModerationWillOpen: (() -> Void)?     // pull fresh state
    public var onToggleMuteAll: (() -> Void)?
    public var onToggleAllCameras: (() -> Void)?
    public var onStopAllShares: (() -> Void)?
    public var onToggleChatDisabled: (() -> Void)?
    public var onToggleCoHostRecording: (() -> Void)?
    public var onToggleLock: (() -> Void)?
    public var onPasswordView: (() -> Void)?
    public var onPasswordChange: (() -> Void)?
    public var onPasswordRemove: (() -> Void)?
    public var onShareConflictChange: ((String) -> Void)?

    // Participants panel.
    public var onParticipantsWillOpen: (() -> Void)?   // pull fresh list
    public var onMuteParticipant: ((String) -> Void)?
    public var onUnmuteParticipant: ((String) -> Void)?

    public init() {}

    // MARK: - Derived state

    /// Mic button label: override (request-to-unmute flow) wins; else state-based.
    public var micLabel: String {
        micTitleOverride ?? (micEnabled ? "Mute" : "Unmute")
    }

    public var cameraLabel: String {
        cameraTitleOverride ?? (cameraEnabled ? "Stop Video" : "Start Video")
    }

    public var speakerLabel: String {
        speakerMuted ? "Unmute Audio" : "Mute Audio"
    }

    public var shareLabel: String {
        if sharingActive { return "Stop Share" }
        if sharePending { return "Requested…" }
        return "Share"
    }

    public var canShare: Bool { shareEnabled && !sharePending }

    /// Combined badge count on the More button: pending requests plus lobby
    /// waiters. Lobby waiters only count when the local participant can actually
    /// see/admit them (host/co-host), so non-moderators never get a phantom badge.
    public var moreBadgeCount: Int {
        pendingRequestCount + (lobbyVisible ? lobbyWaitingCount : 0)
    }

    public func selectAudioInput(_ id: String?) {
        selectedAudioInputID = id
        onSelectAudioInput?(id)
    }

    public func react() {
        // No backing feature yet — graceful message per product decision.
        showReactComingSoon = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            self?.showReactComingSoon = false
        }
    }

    // MARK: - Pure helpers (unit-tested)

    /// Display label for a share-permission mode value.
    public nonisolated static func sharePermissionLabel(_ mode: String) -> String {
        switch mode {
        case "everyone": return "Everyone"
        case "request": return "Request to Share"
        default: return "Host Only"
        }
    }

    public nonisolated static let sharePermissionModes: [String] = ["hostOnly", "request", "everyone"]

    /// Badge text for unread/pending counts (nil = no badge, caps at 9+).
    public nonisolated static func badgeText(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > 9 ? "9+" : String(count)
    }

    /// Share-takeover policy values + labels (mirrors the legacy menu).
    public nonisolated static let shareConflictModes: [String] = ["oneattime", "hostCanPreempt", "anyCanPreempt"]

    public nonisolated static func shareConflictLabel(_ policy: String) -> String {
        switch policy {
        case "hostCanPreempt": return "Host Can Take Over"
        case "anyCanPreempt":  return "Anyone Can Take Over"
        default:                return "One at a Time"
        }
    }
}
