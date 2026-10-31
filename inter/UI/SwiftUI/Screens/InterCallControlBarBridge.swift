//
//  InterCallControlBarBridge.swift
//  inter
//
//  AppKit↔SwiftUI bridge for the normal-mode in-call bottom bar. Hosts
//  `CallControlBarView`, conforms to `InterCallMediaControlSurface` so
//  InterMediaWiringController drives it exactly like the legacy AppKit panel
//  (which the secure/candidate window keeps using), and exposes block
//  callbacks + setters for everything AppDelegate wires.
//
//  The Requests panel consolidation observes the four queues' KVO `count`
//  directly — the existing per-queue `setEntries:` push sites in AppDelegate
//  keep working untouched; this bridge re-reads queue entries whenever any
//  count changes.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@objc(InterCallControlBarBridge)
public final class InterCallControlBarBridge: NSView, InterCallMediaControlSurface {

    private let viewModel = CallControlBarViewModel()
    private let requestsViewModel = RequestsPanelViewModel()
    private var hosting: NSHostingView<CallControlBarView>!
    private var requestsPopover: NSPopover?
    // PRESENCE MONITORING (provisional). Owned here so the popover and its view
    // model live exactly as long as the bar does.
    private let presenceTimelineViewModel = PresenceTimelineViewModel()
    private var presenceTimelinePopover: NSPopover?

    // Queue references for the requests consolidation (weak; owned by AppDelegate).
    private weak var speakerQueue: InterSpeakerQueue?
    private weak var screenShareQueue: InterScreenShareQueue?
    private weak var cameraUnlockQueue: InterCameraUnlockQueue?
    private weak var micUnlockQueue: InterMicUnlockQueue?
    private var observations: [NSKeyValueObservation] = []

    // MARK: - Action callbacks (AppDelegate assigns)

    @objc public var cameraToggleHandler: (() -> Void)?
    @objc public var microphoneToggleHandler: (() -> Void)?
    @objc public var speakerToggleHandler: (() -> Void)?
    @objc public var shareToggleHandler: (() -> Void)?
    @objc public var audioInputSelectionChangedHandler: ((String?) -> Void)?
    @objc public var chatToggleHandler: (() -> Void)?
    @objc public var pollToggleHandler: (() -> Void)?
    @objc public var qaToggleHandler: (() -> Void)?
    @objc public var raiseHandToggleHandler: (() -> Void)?
    @objc public var recordToggleHandler: (() -> Void)?
    @objc public var viewRecordingsHandler: (() -> Void)?
    @objc public var screenShareModeChangedHandler: ((String) -> Void)?
    @objc public var lobbyHandler: (() -> Void)?
    @objc public var renameHandler: (() -> Void)?
    // Moderation actions (the legacy NSMenu is gone — each row routes here).
    @objc public var moderationMenuWillOpenHandler: (() -> Void)?
    @objc public var toggleMuteAllHandler: (() -> Void)?
    @objc public var toggleAllCamerasHandler: (() -> Void)?
    @objc public var stopAllSharesHandler: (() -> Void)?
    @objc public var toggleChatDisabledHandler: (() -> Void)?
    @objc public var toggleCoHostRecordingHandler: (() -> Void)?
    @objc public var toggleLockHandler: (() -> Void)?
    @objc public var passwordViewHandler: (() -> Void)?
    @objc public var passwordChangeHandler: (() -> Void)?
    @objc public var passwordRemoveHandler: (() -> Void)?
    @objc public var shareConflictChangedHandler: ((String) -> Void)?
    // Participants panel.
    @objc public var participantsProvider: (() -> [[String: String]])?
    @objc public var participantMuteHandler: ((String) -> Void)?
    @objc public var participantUnmuteHandler: ((String) -> Void)?
    @objc public var leaveHandler: (() -> Void)?
    /// Approve a request (kindRawValue is CallRequestKind.rawValue).
    @objc public var requestApproveHandler: ((String, String) -> Void)?
    /// Deny a request.
    @objc public var requestDenyHandler: ((String, String) -> Void)?
    /// Interviewer Code/Board tool selection (carries the `InterInterviewToolKind` raw value).
    @objc public var interviewToolChangedHandler: ((Int) -> Void)?

    // MARK: - PRESENCE MONITORING handlers (provisional, server flag default OFF)

    /// Asked to re-read `GET /presence/timeline` (panel opened, or Refresh).
    @objc public var presenceTimelineRefreshHandler: (() -> Void)?
    /// Jump to an offset (seconds) from session start in the existing recording surface.
    @objc public var presenceJumpToHandler: ((Double) -> Void)?
    /// (eventId as a string, note text). The server enforces the >= 10-char rule.
    @objc public var presenceNoteHandler: ((String, String) -> Void)?
    /// Copy the JSON export to the pasteboard.
    @objc public var presenceCopyJSONHandler: (() -> Void)?
    /// Write the CSV export to a user-chosen file. The bridge runs the NSSavePanel
    /// and hands back the destination path.
    @objc public var presenceSaveCSVHandler: ((NSString) -> Void)?

    @objc public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure() {
        viewModel.onToggleCamera = { [weak self] in self?.cameraToggleHandler?() }
        viewModel.onToggleMic = { [weak self] in self?.microphoneToggleHandler?() }
        viewModel.onToggleSpeaker = { [weak self] in self?.speakerToggleHandler?() }
        viewModel.onSelectAudioInput = { [weak self] id in self?.audioInputSelectionChangedHandler?(id) }
        viewModel.onShare = { [weak self] in self?.shareToggleHandler?() }
        viewModel.onSelectTool = { [weak self] kind in self?.interviewToolChangedHandler?(kind) }
        viewModel.onToggleChat = { [weak self] in self?.chatToggleHandler?() }
        viewModel.onTogglePoll = { [weak self] in self?.pollToggleHandler?() }
        viewModel.onToggleQA = { [weak self] in self?.qaToggleHandler?() }
        viewModel.onToggleRaiseHand = { [weak self] in self?.raiseHandToggleHandler?() }
        viewModel.onToggleRecording = { [weak self] in self?.recordToggleHandler?() }
        viewModel.onViewRecordings = { [weak self] in self?.viewRecordingsHandler?() }
        viewModel.onSharePermissionChange = { [weak self] mode in self?.screenShareModeChangedHandler?(mode) }
        viewModel.onOpenRequests = { [weak self] in self?.presentRequestsPanel() }
        viewModel.onOpenLobby = { [weak self] in self?.lobbyHandler?() }
        viewModel.onRename = { [weak self] in self?.renameHandler?() }
        viewModel.onLeave = { [weak self] in self?.leaveHandler?() }

        // Moderation menu (state pulled fresh on open).
        viewModel.onModerationWillOpen = { [weak self] in self?.moderationMenuWillOpenHandler?() }
        viewModel.onToggleMuteAll = { [weak self] in self?.toggleMuteAllHandler?() }
        viewModel.onToggleAllCameras = { [weak self] in self?.toggleAllCamerasHandler?() }
        viewModel.onStopAllShares = { [weak self] in self?.stopAllSharesHandler?() }
        viewModel.onToggleChatDisabled = { [weak self] in self?.toggleChatDisabledHandler?() }
        viewModel.onToggleCoHostRecording = { [weak self] in self?.toggleCoHostRecordingHandler?() }
        viewModel.onToggleLock = { [weak self] in self?.toggleLockHandler?() }
        viewModel.onPasswordView = { [weak self] in self?.passwordViewHandler?() }
        viewModel.onPasswordChange = { [weak self] in self?.passwordChangeHandler?() }
        viewModel.onPasswordRemove = { [weak self] in self?.passwordRemoveHandler?() }
        viewModel.onShareConflictChange = { [weak self] policy in self?.shareConflictChangedHandler?(policy) }

        // Participants panel: pull a fresh list each open; mute routes to the
        // same per-participant host-mute the tile menu uses.
        viewModel.onParticipantsWillOpen = { [weak self] in self?.refreshParticipants() }
        viewModel.onMuteParticipant = { [weak self] identity in
            self?.participantMuteHandler?(identity)
            // Optimistic: flip the row to host-muted immediately.
            if let self = self {
                MainActor.assumeIsolated {
                    self.viewModel.participants = self.viewModel.participants.map {
                        $0.id == identity
                            ? CallParticipant(id: $0.id, name: $0.name, isHostMuted: true) : $0
                    }
                }
            }
        }
        viewModel.onUnmuteParticipant = { [weak self] identity in
            self?.participantUnmuteHandler?(identity)
            // Optimistic: flip the row back to un-muted immediately.
            if let self = self {
                MainActor.assumeIsolated {
                    self.viewModel.participants = self.viewModel.participants.map {
                        $0.id == identity
                            ? CallParticipant(id: $0.id, name: $0.name, isHostMuted: false) : $0
                    }
                }
            }
        }

        // PRESENCE MONITORING (provisional). Nothing here runs unless the server
        // armed the room: `presenceAvailable` defaults false, so the chip that
        // opens this panel does not render.
        viewModel.onOpenPresenceTimeline = { [weak self] in self?.presentPresenceTimeline() }
        presenceTimelineViewModel.onRefresh = { [weak self] in
            self?.presenceTimelineRefreshHandler?()
        }
        presenceTimelineViewModel.onJumpToOffset = { [weak self] seconds in
            self?.presenceJumpToHandler?(seconds)
        }
        presenceTimelineViewModel.onAddNote = { [weak self] eventId, text in
            self?.presenceNoteHandler?(String(eventId), text)
        }
        presenceTimelineViewModel.onCopyJSON = { [weak self] in
            self?.presenceCopyJSONHandler?()
        }
        presenceTimelineViewModel.onSaveCSV = { [weak self] in
            self?.runPresenceSavePanel()
        }

        requestsViewModel.onApprove = { [weak self] kind, identity in
            self?.requestApproveHandler?(kind.rawValue, identity)
        }
        requestsViewModel.onDeny = { [weak self] kind, identity in
            self?.requestDenyHandler?(kind.rawValue, identity)
        }

        let host = NSHostingView(rootView: CallControlBarView(viewModel: viewModel))
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

    // MARK: - Requests consolidation (KVO on the four queues)

    /// Attach the queues; the bridge re-reads entries whenever any count changes.
    @objc public func attachQueues(speakerQueue: InterSpeakerQueue?,
                                   screenShareQueue: InterScreenShareQueue?,
                                   cameraUnlockQueue: InterCameraUnlockQueue?,
                                   micUnlockQueue: InterMicUnlockQueue?) {
        self.speakerQueue = speakerQueue
        self.screenShareQueue = screenShareQueue
        self.cameraUnlockQueue = cameraUnlockQueue
        self.micUnlockQueue = micUnlockQueue
        observations.removeAll()

        if let q = speakerQueue {
            observations.append(q.observe(\.count) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refreshRequests() }
            })
        }
        if let q = screenShareQueue {
            observations.append(q.observe(\.count) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refreshRequests() }
            })
        }
        if let q = cameraUnlockQueue {
            observations.append(q.observe(\.count) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refreshRequests() }
            })
        }
        if let q = micUnlockQueue {
            observations.append(q.observe(\.count) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refreshRequests() }
            })
        }
        refreshRequests()
    }

    @objc public func refreshRequests() {
        MainActor.assumeIsolated {
            let hands = (speakerQueue?.entries ?? []).map {
                CallRequest(kind: .raisedHand, identity: $0.participantIdentity,
                            displayName: $0.displayName,
                            timestamp: Date(timeIntervalSince1970: $0.timestamp))
            }
            requestsViewModel.setRequests(hands, for: .raisedHand)
            let shares = (screenShareQueue?.entries ?? []).map {
                CallRequest(kind: .screenShare, identity: $0.participantIdentity,
                            displayName: $0.displayName,
                            timestamp: Date(timeIntervalSince1970: $0.timestamp))
            }
            requestsViewModel.setRequests(shares, for: .screenShare)
            let cams = (cameraUnlockQueue?.entries ?? []).map {
                CallRequest(kind: .cameraUnlock, identity: $0.participantIdentity,
                            displayName: $0.displayName,
                            timestamp: Date(timeIntervalSince1970: $0.timestamp))
            }
            requestsViewModel.setRequests(cams, for: .cameraUnlock)
            let mics = (micUnlockQueue?.entries ?? []).map {
                CallRequest(kind: .micUnlock, identity: $0.participantIdentity,
                            displayName: $0.displayName,
                            timestamp: Date(timeIntervalSince1970: $0.timestamp))
            }
            requestsViewModel.setRequests(mics, for: .micUnlock)
            viewModel.pendingRequestCount = requestsViewModel.totalCount
        }
    }

    private func presentRequestsPanel() {
        if let popover = requestsPopover, popover.isShown {
            popover.close()
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 380)
        popover.contentViewController = NSHostingController(
            rootView: RequestsPanelView(viewModel: requestsViewModel))
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        requestsPopover = popover
    }

    /// Open the consolidated Requests panel programmatically (e.g. from the
    /// in-call request toast's "Open" action).
    @objc public func showRequestsPanel() {
        presentRequestsPanel()
    }

    // MARK: - PRESENCE MONITORING panel (provisional, server flag default OFF)

    /// Same NSPopover + NSHostingController shape as `presentRequestsPanel()`.
    private func presentPresenceTimeline() {
        if let popover = presenceTimelinePopover, popover.isShown {
            popover.close()
            MainActor.assumeIsolated { viewModel.presenceTimelineVisible = false }
            return
        }
        // Read fresh on every open — a stale timeline is worse than a slow one.
        presenceTimelineRefreshHandler?()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: 480)
        popover.contentViewController = NSHostingController(
            rootView: PresenceTimelineView(viewModel: presenceTimelineViewModel))
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        presenceTimelinePopover = popover
        MainActor.assumeIsolated { viewModel.presenceTimelineVisible = true }
    }

    /// Asks for a destination, then hands the path to AppDelegate, which owns the
    /// network call and the write. The entitlement
    /// (`files.user-selected.read-write`) is already granted.
    private func runPresenceSavePanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "presence-timeline.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.presenceSaveCSVHandler?(url.path as NSString)
        }
    }

    @objc public func setPresenceAvailable(_ available: Bool) {
        MainActor.assumeIsolated { viewModel.presenceAvailable = available }
    }

    @objc public func setPresenceMonitoringEnabled(_ enabled: Bool) {
        MainActor.assumeIsolated { viewModel.presenceMonitoringEnabled = enabled }
    }

    /// Accepts only "multiple_faces" or "face_absent"; nil/"" clears the chip.
    /// Anything else is ignored by the view model, not clamped.
    @objc public func setPresenceLiveEventType(_ eventType: String?) {
        MainActor.assumeIsolated { viewModel.setPresenceLiveEvent(eventType) }
    }

    /// Whether a recording exists for this session (drives the Jump control's
    /// disabled state and its honest caption).
    @objc public func setPresenceRecordingAvailable(_ available: Bool) {
        MainActor.assumeIsolated { presenceTimelineViewModel.recordingAvailable = available }
    }

    /// Applies a `GET /presence/timeline` response to the panel.
    @objc public func applyPresenceTimeline(_ timeline: [AnyHashable: Any]) {
        MainActor.assumeIsolated { presenceTimelineViewModel.apply(timeline: timeline) }
    }

    /// Surfaces a read/write failure in the panel instead of showing an empty list.
    @objc public func setPresenceStatusText(_ text: String) {
        MainActor.assumeIsolated { presenceTimelineViewModel.statusText = text }
    }

    /// Drops the presence handler blocks and closes the panel (session teardown).
    @objc public func invalidatePresenceHandlers() {
        presenceTimelineRefreshHandler = nil
        presenceJumpToHandler = nil
        presenceNoteHandler = nil
        presenceCopyJSONHandler = nil
        presenceSaveCSVHandler = nil
        presenceTimelinePopover?.close()
        presenceTimelinePopover = nil
        MainActor.assumeIsolated {
            viewModel.presenceTimelineVisible = false
            viewModel.presenceAvailable = false
            viewModel.presenceMonitoringEnabled = false
            viewModel.setPresenceLiveEvent(nil)
        }
    }

    // MARK: - InterCallMediaControlSurface (wiring controller drives these)

    @objc public func setCameraEnabled(_ enabled: Bool) {
        MainActor.assumeIsolated { viewModel.cameraEnabled = enabled }
    }

    @objc public func setCameraInteractive(_ interactive: Bool) {
        MainActor.assumeIsolated { viewModel.cameraInteractive = interactive }
    }

    @objc public func setCameraButtonTitle(_ title: String?) {
        MainActor.assumeIsolated { viewModel.cameraTitleOverride = title }
    }

    @objc public func setMicrophoneEnabled(_ enabled: Bool) {
        MainActor.assumeIsolated { viewModel.micEnabled = enabled }
    }

    @objc public func setSpeakerMuted(_ muted: Bool) {
        MainActor.assumeIsolated { viewModel.speakerMuted = muted }
    }

    @objc public func setMicrophoneButtonTitle(_ title: String?) {
        MainActor.assumeIsolated { viewModel.micTitleOverride = title }
    }

    @objc public func setMediaStatusText(_ text: String) {
        MainActor.assumeIsolated { viewModel.mediaStatusText = text }
    }

    @objc public func setConnectionStatusText(_ text: String) {
        MainActor.assumeIsolated { viewModel.connectionStatusText = text }
    }

    @objc public func setNetworkQualityLevel(_ level: Int) {
        MainActor.assumeIsolated { viewModel.networkQuality = level }
    }

    // MARK: - Legacy panel surface (AppDelegate drives these)

    @objc public func setRoomCodeText(_ code: String?) {
        MainActor.assumeIsolated { viewModel.roomCode = code ?? "" }
    }

    @objc public func setSharingEnabled(_ active: Bool) {
        MainActor.assumeIsolated { viewModel.sharingActive = active }
    }

    @objc public func setShareStartPending(_ pending: Bool) {
        MainActor.assumeIsolated { viewModel.sharePending = pending }
    }

    @objc public func setShareStatusText(_ text: String) {
        MainActor.assumeIsolated { viewModel.shareStatusText = text }
    }

    @objc public func setShareButtonEnabled(_ enabled: Bool) {
        MainActor.assumeIsolated { viewModel.shareEnabled = enabled }
    }

    @objc public func setAudioInputOptions(_ options: [[String: String]], selectedDeviceID: String?) {
        MainActor.assumeIsolated {
            viewModel.audioInputs = options.compactMap { dict in
                guard let id = dict["id"], let name = dict["name"] else { return nil }
                return AudioInputOption(id: id, name: name)
            }
            viewModel.selectedAudioInputID = selectedDeviceID
        }
    }

    @objc public func setRecordingActive(_ active: Bool) {
        MainActor.assumeIsolated { viewModel.recordingActive = active }
    }

    @objc public func setRecordingButtonHidden(_ hidden: Bool) {
        MainActor.assumeIsolated { viewModel.recordingVisible = !hidden }
    }

    @objc public func setViewRecordingsButtonHidden(_ hidden: Bool) {
        MainActor.assumeIsolated { viewModel.viewRecordingsVisible = !hidden }
    }

    @objc public func setScreenSharePermissionMode(_ mode: String?) {
        MainActor.assumeIsolated { viewModel.sharePermissionMode = mode }
    }

    @objc public func setScreenSharePermissionEnabled(_ enabled: Bool) {
        MainActor.assumeIsolated { viewModel.sharePermissionEnabled = enabled }
    }

    @objc public func setModerationVisible(_ visible: Bool) {
        MainActor.assumeIsolated {
            viewModel.moderationVisible = visible
            viewModel.requestsVisible = visible   // host/co-host only, same gate
            viewModel.lobbyVisible = visible
        }
    }

    @objc public func setLobbyWaitingCount(_ count: Int) {
        MainActor.assumeIsolated { viewModel.lobbyWaitingCount = count }
    }

    @objc public func setRenameVisible(_ visible: Bool) {
        MainActor.assumeIsolated { viewModel.renameVisible = visible }
    }

    @objc public func setChatUnread(_ count: Int) {
        MainActor.assumeIsolated { viewModel.chatUnread = count }
    }

    @objc public func setQAUnread(_ count: Int) {
        MainActor.assumeIsolated { viewModel.qaUnread = count }
    }

    @objc public func setHandRaised(_ raised: Bool) {
        MainActor.assumeIsolated { viewModel.handRaised = raised }
    }

    // MARK: - Interview tools (Code/Board) state (AppDelegate drives these)

    @objc public func setInterviewToolsVisible(_ visible: Bool) {
        MainActor.assumeIsolated { viewModel.interviewToolsVisible = visible }
    }

    @objc public func setSelectedInterviewToolKind(_ kind: Int) {
        MainActor.assumeIsolated { viewModel.selectedToolKind = kind }
    }

    @objc public func setToolBadge(_ hasActivity: Bool) {
        MainActor.assumeIsolated { viewModel.toolBadgeActive = hasActivity }
    }

    // MARK: - Moderation menu state (pushed by the host before the menu opens)

    @objc public func setModerationState(allMuted: Bool,
                                         allCamerasOff: Bool,
                                         chatDisabled: Bool,
                                         coHostRecordingAllowed: Bool,
                                         meetingLocked: Bool,
                                         hasPassword: Bool,
                                         hasPlaintextPassword: Bool,
                                         shareConflictPolicy: String,
                                         isHostRole: Bool) {
        MainActor.assumeIsolated {
            viewModel.allMuted = allMuted
            viewModel.allCamerasOff = allCamerasOff
            viewModel.chatDisabled = chatDisabled
            viewModel.coHostRecordingAllowed = coHostRecordingAllowed
            viewModel.meetingLocked = meetingLocked
            viewModel.hasMeetingPassword = hasPassword
            viewModel.hasPlaintextPassword = hasPlaintextPassword
            viewModel.shareConflictPolicy = shareConflictPolicy
            viewModel.isHostRole = isHostRole
        }
    }

    // MARK: - Participants panel

    @objc public func refreshParticipants() {
        guard let rows = participantsProvider?() else { return }
        MainActor.assumeIsolated {
            viewModel.participants = rows.compactMap { dict in
                guard let id = dict["identity"], !id.isEmpty else { return nil }
                return CallParticipant(id: id,
                                       name: dict["name"] ?? id,
                                       isHostMuted: dict["hostMuted"] == "1")
            }
        }
    }
}
