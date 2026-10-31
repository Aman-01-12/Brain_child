//
//  SecureCandidateChromeViewModel.swift
//  inter
//
//  State container for the secure interviewee (candidate) window chrome:
//  the top status bar (Secure Interview · room code · REC · CANDIDATE · Chat)
//  and the bottom control bar (mic ^ / camera / tool selection / share /
//  Leave Interview). The kiosk window, stage view, tool host (the capture
//  surface), and chat overlay stay AppKit — this VM only drives chrome.
//
//  Security-relevant semantics (paranoid findings, all approved):
//   • #6 REC badge: `recordingActive` is only ever set from the recording
//     signal path through the bridge setter — no local timers, no inference.
//   • #7 Two-step share contract: selecting a tool NEVER starts capture.
//     `selectTool` only fires `onSelectTool`; publishing starts exclusively
//     via `onToggleShare` (the explicit Share button). This mirrors the
//     legacy panel and keeps capture consent unambiguous.
//   • #3 No E2EE claim is rendered anywhere (transport encryption only).
//

import Foundation
import Combine

@MainActor
public final class SecureCandidateChromeViewModel: ObservableObject {

    // MARK: - Media state (InterMediaWiringController via the bridge)

    @Published public var cameraEnabled = false
    @Published public var cameraInteractive = true
    @Published public var cameraTitleOverride: String?
    @Published public var micEnabled = false
    @Published public var micTitleOverride: String?
    @Published public var mediaStatusText = ""
    @Published public var connectionStatusText = ""

    // MARK: - Status bar state

    @Published public var roomCode = ""
    /// Driven exclusively by the recording-signal path (finding #6).
    @Published public var recordingActive = false
    @Published public var chatUnread = 0
    @Published public var chatVisible = false

    // MARK: - PRESENCE MONITORING (provisional, server flag default OFF)
    //
    // A PERSISTENT, NON-DISMISSIBLE chip for the whole session — never a toast.
    // The consent-first moderation spec rejects toasts for exactly this: a toast
    // conflates "declined" with "never saw it", and a monitoring indicator that
    // can be missed or dismissed is not an indicator. If monitoring stops for any
    // reason the chip must change state: a stale "on" is a lie and a stale "off"
    // is worse. 0 absent / 1 on / 2 off / 3 paused because the camera is off.
    // Default 0 means nothing renders unless something sets it, so a flag-off
    // session needs no guard here. Delete this pair and the chip in
    // SecureCandidateChromeViews to remove the indicator.
    // See .agents/tasks/presence-monitoring/REMOVAL.md.
    @Published public var presenceMonitoringState: Int = 0

    /// Reopens the full "what is and isn't measured" list at any time.
    public var onOpenPresenceDetails: (() -> Void)?

    // MARK: - Tool + share state

    /// InterInterviewToolKind raw value (0 none / 1 code / 2 whiteboard).
    /// Selection only — publishing is a separate explicit action (finding #7).
    @Published public var selectedTool: Int = 0
    @Published public var sharingActive = false
    @Published public var sharePending = false
    @Published public var shareStatusText = ""

    // MARK: - Audio inputs (mic ^ flyout)

    @Published public var audioInputs: [AudioInputOption] = []
    @Published public var selectedAudioInputID: String?

    // MARK: - Action callbacks (bridge → SecureWindowController)

    public var onToggleCamera: (() -> Void)?
    public var onToggleMic: (() -> Void)?
    public var onSelectAudioInput: ((String?) -> Void)?
    /// Tool SELECTION only — never starts capture (finding #7).
    public var onSelectTool: ((Int) -> Void)?
    /// The only path that starts/stops publishing.
    public var onToggleShare: (() -> Void)?
    public var onToggleChat: (() -> Void)?
    public var onLeave: (() -> Void)?

    public init() {}

    // MARK: - Derived state

    public var micLabel: String {
        micTitleOverride ?? (micEnabled ? "Mute" : "Unmute")
    }

    public var cameraLabel: String {
        cameraTitleOverride ?? (cameraEnabled ? "Stop Video" : "Start Video")
    }

    public var shareButtonLabel: String {
        if sharingActive { return "Stop Share" }
        if sharePending { return "Starting…" }
        return "Share"
    }

    /// Share requires a selected tool (server/controller enforce too — this is
    /// just honest button state, not the security boundary).
    public var canToggleShare: Bool {
        sharingActive || sharePending || selectedTool != 0
    }

    public func selectAudioInput(_ id: String?) {
        selectedAudioInputID = id
        onSelectAudioInput?(id)
    }

    /// Finding #7: selection routes to the controller, which swaps the staged
    /// tool view. It must never call onToggleShare.
    public func selectTool(_ kind: Int) {
        guard kind != selectedTool else { return }
        selectedTool = kind
        onSelectTool?(kind)
    }

    // MARK: - Pure helpers (unit-tested)

    /// Segments for the share strip — raw InterInterviewToolKind values.
    public nonisolated static let toolSegments: [(kind: Int, label: String)] = [
        (0, "Off"), (1, "Code"), (2, "Board"),
    ]

    public nonisolated static func toolName(_ kind: Int) -> String {
        switch kind {
        case 1: return "Code editor"
        case 2: return "Whiteboard"
        default: return "No tool"
        }
    }

    /// The status line under/beside the share strip. Always states exactly
    /// what is or isn't visible to the other side (consent clarity, #7).
    public nonisolated static func shareStatus(toolKind: Int, sharing: Bool, pending: Bool) -> String {
        if sharing {
            return "\(toolName(toolKind)) is visible to the interviewer."
        }
        if pending {
            return "Starting secure tool share…"
        }
        if toolKind == 0 {
            return "Nothing is shared. Select Code or Board, then press Share."
        }
        return "\(toolName(toolKind)) selected — not shared yet. Press Share to publish it."
    }
}
