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

    // MARK: - Interview tools (Code/Board) — interviewer-side control

    // Interviewer tool control is added per the interviewer-collaborative-tools
    // spec. The interviewer now mounts the native tool host and edits the same
    // CRDT document as the candidate, so the normal-mode bar exposes a Code/Board
    // segmented control. Visibility is gated (interview mode + interviewer role +
    // server-signed tools entitlement) and defaults FAIL-CLOSED.

    /// Gated visibility of the Code/Board control (interview mode + interviewer
    /// role + `localParticipantHasToolsEntitlement`). Fail-closed default.
    @Published public var interviewToolsVisible = false
    /// Selected tool kind (`InterInterviewToolKind` raw): 0 None / 1 Code / 2 Board.
    @Published public var selectedToolKind = 0
    /// Peer-activity awareness dot on the Code/Board button (never auto-opens).
    @Published public var toolBadgeActive = false

    // MARK: - PRESENCE MONITORING (provisional, server flag default OFF)
    //
    // The interviewer's quiet chip plus the entry point to the evaluation
    // timeline. `presenceAvailable` defaults FALSE, so with the server flag off
    // the chip is simply absent — no guard needed at the render site. Delete this
    // block, the chip in CallControlBarView and the bridge setters to remove the
    // interviewer surface. See .agents/tasks/presence-monitoring/REMOVAL.md.

    /// Whether this room has a presence surface at all.
    @Published public var presenceAvailable = false
    /// Server-authoritative: whether the candidate's session is actually monitored
    /// (a declining candidate joins with this false, and the interviewer is told).
    @Published public var presenceMonitoringEnabled = false
    /// The one live event type currently surfaced, or nil. Settable ONLY through
    /// `setPresenceLiveEvent(_:)`, which refuses anything outside
    /// `liveSurfaceableEventTypes` — the live surface cannot be widened from here
    /// (research memo §7.9 item 4; the server computes the same restriction).
    @Published public private(set) var presenceLiveEventType: String?
    /// Whether the timeline popover is open.
    @Published public var presenceTimelineVisible = false

    /// Opens the evaluation timeline popover.
    public var onOpenPresenceTimeline: (() -> Void)?

    /// The ONLY two event types a live interviewer is shown mid-interview: both
    /// are non-inferential and both are things a reasonable host would act on in
    /// the moment. Everything else waits for the post-session timeline.
    public nonisolated static let liveSurfaceableEventTypes: Set<String> = ["multiple_faces", "face_absent"]

    /// Sets (or clears) the live event type. A type outside the allowlist is
    /// ignored outright rather than clamped, so a future caller cannot smuggle
    /// `image_quality_insufficient` — a fact about the video — onto the live
    /// surface as if it were candidate behaviour.
    public func setPresenceLiveEvent(_ eventType: String?) {
        guard let eventType = eventType, !eventType.isEmpty else {
            presenceLiveEventType = nil
            return
        }
        guard Self.liveSurfaceableEventTypes.contains(eventType) else { return }
        presenceLiveEventType = eventType
    }

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

    /// Routes a Code/Board tool selection to the bridge handler (interviewer
    /// tool control, interviewer-collaborative-tools spec). Carries the
    /// `InterInterviewToolKind` raw value.
    public var onSelectTool: ((Int) -> Void)?

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

    /// Selects a Code/Board interview tool: records the chosen
    /// `InterInterviewToolKind` raw value and routes it to the bridge handler.
    public func selectTool(_ kind: Int) {
        selectedToolKind = kind
        onSelectTool?(kind)
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

    /// The interviewer's presence chip label, or nil when there is no chip.
    /// Deliberately plain and non-accusatory: it names what the camera saw, and
    /// nothing about what it might mean. No count, no severity, no score.
    public nonisolated static func presenceChipLabel(available: Bool,
                                                     monitoringEnabled: Bool,
                                                     liveEventType: String?) -> String? {
        guard available else { return nil }
        guard monitoringEnabled else { return "Presence monitoring off" }
        switch liveEventType {
        case "multiple_faces": return "Second face visible"
        case "face_absent":    return "Face not visible"
        default:               return "Presence monitoring on"
        }
    }
}
