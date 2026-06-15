// ============================================================================
// InterRecordingCoordinator.swift
// inter
//
// Phase 10B — Central recording state machine and coordinator.
//
// ARCHITECTURE:
// All state transitions are serialized on `coordinatorQueue` (serial, QOS
// .userInitiated). External callers (UI thread, subscriber callbacks) always
// dispatch_async to this queue. The `state` property is readable from any
// thread via `os_unfair_lock` (read-only snapshot), but all mutations happen
// exclusively on `coordinatorQueue`.
//
// This is the most critical synchronization point in the recording system —
// it prevents double-start, stop-during-start, and pause/resume interleaving.
//
// THREADING:
// - coordinatorQueue: all state transitions, pipeline setup/teardown
// - main thread: delegate callbacks, UI state notifications
// - _renderTimer fires on coordinatorQueue → calls composedRenderer.render
//   → dispatches result to recordingEngine
//
// ISOLATION INVARIANT [G8]:
// If removed, the rest of the app functions without recording capability.
// ============================================================================

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import AppKit
import os.log
import LiveKit

// MARK: - Recording State

/// Recording state machine states.
/// See §13 of recording_architecture.md for the full transition matrix.
@objc public enum InterRecordingState: Int {
    case idle = 0
    case starting = 1
    case recording = 2
    case paused = 3
    case stopping = 4
    case finalized = 5
    case failed = 6
}

// MARK: - Delegate Protocol

/// Delegate protocol for recording coordinator lifecycle events.
/// All callbacks are delivered on the **main thread**.
@objc public protocol InterRecordingCoordinatorDelegate: AnyObject {
    /// State machine transition.
    @objc func recordingStateDidChange(_ state: InterRecordingState)

    /// Recording completed (or failed). `outputURL` is nil for cloud recordings or failures.
    @objc func recordingDidComplete(outputURL: URL?, error: Error?)

    /// Duration update — fires every 1 second during recording.
    @objc func recordingDurationDidUpdate(_ duration: TimeInterval)

    /// Layout changed during recording (e.g. screen share started/stopped).
    @objc optional func recordingLayoutDidChange(_ layout: InterComposedLayout)
}

// MARK: - Recording Layout Preference

/// Host-selectable layout for the local composed recording.
/// `auto` mirrors a gallery-style view (grid for 3+, side-by-side for 2, full for 1);
/// `speaker` keeps the active remote speaker prominent alongside the local self-view.
@objc public enum InterRecordingLayoutPreference: Int {
    case auto = 0
    case speaker = 1
}

// MARK: - Recording Layout Logic (pure, unit-testable)

/// Side-effect-free layout decisions for the recording composer. Extracted so the
/// freeze-prevention invariants can be unit-tested without standing up the Metal /
/// AVAssetWriter pipeline. Every function here is a pure function of its inputs.
enum InterRecordingLayoutLogic {
    /// Which 2-slot position the LOCAL participant occupies.
    enum Slot: Equatable { case primary, secondary }

    /// Grid (gallery) engages for 3+ participants in `auto`; never in `speaker`.
    static func useGrid(participantCount: Int, preference: InterRecordingLayoutPreference) -> Bool {
        if preference == .speaker { return false }
        return participantCount >= 3
    }

    /// The local participant is NEVER subject to active-speaker selection. It takes the
    /// secondary slot when a remote holds the primary, and the primary slot when it is
    /// the only camera. This guarantees the host is always rendered (the freeze fix) and
    /// avoids the renderer's "secondary-only ⇒ Idle/black" edge.
    static func localSlot(hasRemoteActiveSpeaker: Bool) -> Slot {
        return hasRemoteActiveSpeaker ? .secondary : .primary
    }

    /// A slot showing `identity` must use an avatar placeholder when no live camera
    /// frame has been delivered for it — preventing a stale frozen frame from persisting.
    static func needsPlaceholder(identity: String, identitiesWithLiveFrame: Set<String>) -> Bool {
        return !identitiesWithLiveFrame.contains(identity)
    }

    /// A remote participant "holds the primary slot" exactly when some non-local identity
    /// has delivered a live camera frame. Pure → unit-testable.
    static func hasRemoteActiveSpeaker(localId: String?, identitiesWithLiveFrame: Set<String>) -> Bool {
        return identitiesWithLiveFrame.contains { $0 != localId }
    }
}

// MARK: - InterRecordingCoordinator

@objc public class InterRecordingCoordinator: NSObject {

    // -----------------------------------------------------------------------
    // MARK: - Public Properties
    // -----------------------------------------------------------------------

    /// Thread-safe read of current state (snapshot under lock).
    @objc public var state: InterRecordingState {
        os_unfair_lock_lock(&_stateLock)
        let s = _state
        os_unfair_lock_unlock(&_stateLock)
        return s
    }

    /// Delegate for state, duration, and completion callbacks.
    @objc public weak var delegate: InterRecordingCoordinatorDelegate?

    /// Host-selectable recording layout. Set BEFORE `startLocalRecording`; snapshotted
    /// at recording start. Thread-safe via `_stateLock`. Defaults to `.auto`.
    @objc public var preferredLayout: InterRecordingLayoutPreference {
        get {
            os_unfair_lock_lock(&_stateLock)
            let v = _preferredLayoutStorage
            os_unfair_lock_unlock(&_stateLock)
            return v
        }
        set {
            os_unfair_lock_lock(&_stateLock)
            _preferredLayoutStorage = newValue
            os_unfair_lock_unlock(&_stateLock)
        }
    }

    /// Maximum recording duration before issuing a warning notification (seconds).
    private static let oneHourWarningThreshold: TimeInterval = 3600

    /// Whether recording is in a state that accepts user actions.
    @objc public var canPause: Bool { state == .recording }
    @objc public var canResume: Bool { state == .paused }
    @objc public var canStop: Bool {
        let s = state
        return s == .recording || s == .paused
    }

    /// Whether a local recording is active (used for edge-case auto-stop).
    /// Thread-safe: reads both `_state` and `_outputURL` under `_stateLock`.
    @objc public var isLocalRecordingActive: Bool {
        os_unfair_lock_lock(&_stateLock)
        let s = _state
        let hasOutput = _outputURL != nil
        os_unfair_lock_unlock(&_stateLock)
        return (s == .recording || s == .paused) && hasOutput
    }

    // -----------------------------------------------------------------------
    // MARK: - Private Properties
    // -----------------------------------------------------------------------

    /// Serial queue for all state transitions. Every mutation goes through here.
    private let coordinatorQueue = DispatchQueue(label: "inter.recording.coordinator",
                                                  qos: .userInitiated)

    /// Lock guarding read-only snapshots of `_state`.
    private var _stateLock = os_unfair_lock()
    private var _state: InterRecordingState = .idle

    /// T8: Tracked in-flight network sessions for lifecycle cleanup.
    private var inflightSessions = [URLSession]()
    private let inflightLock = NSLock()

    /// Pipeline components — created during start, torn down during stop.
    private var recordingEngine: InterRecordingEngine?
    private var composedRenderer: InterComposedRenderer?
    private var recordingSink: InterRecordingSink?

    /// 30fps render timer (dispatch_source on coordinatorQueue).
    private var renderTimer: DispatchSourceTimer?

    /// 1-second duration update timer.
    private var durationTimer: DispatchSourceTimer?

    /// Pending stop flag — when stop is requested during .starting state.
    private var _pendingStop = false

    /// Active speaker debounce state.
    private var _activeSpeakerId: String?
    private var _pendingSpeakerId: String?
    private var _activeSpeakerHoldUntil: CFAbsoluteTime = 0
    private var _speakerDebounceTimer: DispatchSourceTimer?

    /// Recent speakers list for secondary speaker selection (ordered by last-active).
    private var _recentSpeakers: [String] = []

    /// All participants currently in the call — ordered by join time.
    /// Used for grid layout when 3+ participants are present.
    private var _allParticipants: [String] = []

    /// Whether to use grid layout mode (3+ participants with cameras).
    /// When true, frames are routed to composedRenderer.updateParticipantFrame
    /// instead of the active/secondary speaker pair.
    private var _useGridLayout: Bool = false

    /// Identities that have delivered a live camera frame (and not since gone
    /// camera-off / left). Drives the frame-vs-placeholder slot decision so an
    /// audio-only or camera-off participant never strands a stale frozen frame.
    /// coordinatorQueue-confined.
    private var _identitiesWithLiveFrame: Set<String> = []

    /// Layout preference snapshot taken at recording start (coordinatorQueue-confined).
    private var _layoutPref: InterRecordingLayoutPreference = .auto

    /// Backing storage for `preferredLayout`, guarded by `_stateLock`.
    private var _preferredLayoutStorage: InterRecordingLayoutPreference = .auto
    /// Host participant identity for screen share priority.
    /// When multiple participants screen share, the host's share takes precedence.
    private var _hostIdentity: String?

    /// Identity of the participant currently screen sharing in the recording.
    /// Tracked for host-priority screen share switching.
    private var _activeScreenShareIdentity: String?

    /// Weak reference to the surface share controller for sink insertion/removal.
    private weak var surfaceShareController: InterSurfaceShareController?

    /// Weak references to subscriber and local media controller for frame observation.
    private weak var subscriber: InterLiveKitSubscriber?
    private weak var localMediaController: InterLocalMediaController?

    /// Local participant identity — captured at recording start for thread-safe access.
    private var _localParticipantIdentity: String?

    /// Identity → display name cache for camera-off placeholders. Populated even before
    /// the renderer exists (names may arrive before recording starts) and replayed onto
    /// the renderer when it is created. Guarded by coordinatorQueue.
    private var _participantDisplayNames: [String: String] = [:]

    /// [Gap #14] Extracted audio capture subsystem — owns the tap, ring buffer, and drain.
    private lazy var audioCapture = InterRecordingAudioCapture(coordinatorQueue: coordinatorQueue)

    /// Output file URL for the current recording.
    /// Guarded by `_stateLock` for cross-thread reads (e.g. `isLocalRecordingActive`).
    /// All mutations happen on `coordinatorQueue` *and* acquire `_stateLock`.
    private var _outputURL: URL?

    /// The user's tier string (for watermark decision).
    private var userTier: String = "free"

    /// Disk space monitor timer — fires every 30s during local recording.
    private var diskSpaceTimer: DispatchSourceTimer?

    /// Whether the 1-hour warning has already been posted for the current session.
    private var _hasPostedOneHourWarning = false

    /// Disk space thresholds (bytes).
    private static let diskSpaceWarningThreshold: UInt64  = 2_000_000_000  // 2 GB — warn user
    private static let diskSpaceCriticalThreshold: UInt64 =   500_000_000  //  500 MB — auto-stop

    /// [Phase 10] Chat controller used to broadcast recording state changes
    /// over the control DataChannel for consent notification.
    @objc public weak var chatController: InterChatController?

    /// [Phase 10] The local participant's identity string. Set by AppDelegate
    /// after room connect so the coordinator knows which active speaker is local.
    @objc public var localParticipantIdentity: String? {
        get {
            os_unfair_lock_lock(&_stateLock)
            let id = _localParticipantIdentity
            os_unfair_lock_unlock(&_stateLock)
            return id
        }
        set {
            os_unfair_lock_lock(&_stateLock)
            _localParticipantIdentity = newValue
            os_unfair_lock_unlock(&_stateLock)
        }
    }

    /// The host participant identity — set at room creation.
    /// Used for host-priority screen share selection.
    @objc public var hostIdentity: String? {
        get {
            os_unfair_lock_lock(&_stateLock)
            let id = _hostIdentity
            os_unfair_lock_unlock(&_stateLock)
            return id
        }
        set {
            os_unfair_lock_lock(&_stateLock)
            _hostIdentity = newValue
            os_unfair_lock_unlock(&_stateLock)
        }
    }

    /// Log category for recording.
    private static let log = OSLog(subsystem: "com.secure.inter.network", category: "recording")

    // -----------------------------------------------------------------------
    // MARK: - Init
    // -----------------------------------------------------------------------

    @objc public override init() {
        super.init()
    }

    deinit {
        // [Gap #14] Audio capture is now self-contained; stop() tears down the tap,
        // ring buffer, and drain timer safely.
        audioCapture.stop()

        renderTimer?.cancel()
        durationTimer?.cancel()
        diskSpaceTimer?.cancel()
        _speakerDebounceTimer?.cancel()

        // T8: Cancel all in-flight network requests.
        inflightLock.lock()
        let sessions = inflightSessions
        inflightSessions.removeAll()
        inflightLock.unlock()
        sessions.forEach { $0.invalidateAndCancel() }
    }

    // -----------------------------------------------------------------------
    // MARK: - Permission Check
    // -----------------------------------------------------------------------

    /// Whether the given role has permission to start recording.
    /// Can be called from any thread — reads immutable permission data.
    @objc public func canRecord(role: InterParticipantRole) -> Bool {
        return InterPermissionMatrix.role(role, hasPermission: .canStartRecording)
    }

    // -----------------------------------------------------------------------
    // MARK: - Start Local Recording
    // -----------------------------------------------------------------------

    /// Begin a local composed recording.
    ///
    /// Dispatches all setup work to `coordinatorQueue`. State changes are reported
    /// via the delegate on the main thread.
    ///
    /// - Parameters:
    ///   - screenShareSource: The surface share controller (for live sink insertion).
    ///   - subscriber: The LiveKit subscriber (for remote frame observation).
    ///   - localMediaController: The local media controller (for local camera frames).
    ///   - userTier: The user's subscription tier ("free", "pro", "hiring").
    ///   - existingParticipants: Identities of participants already in the call at
    ///     recording start time. Pass an empty array if none are present.
    @objc public func startLocalRecording(
        screenShareSource: InterSurfaceShareController,
        subscriber: InterLiveKitSubscriber,
        localMediaController: InterLocalMediaController,
        userTier: String,
        existingParticipants: [String]
    ) {
        coordinatorQueue.async { [weak self] in
            self?._startLocalRecording(
                screenShareSource: screenShareSource,
                subscriber: subscriber,
                localMediaController: localMediaController,
                userTier: userTier,
                existingParticipants: existingParticipants
            )
        }
    }

    /// Convenience overload — starts recording without pre-existing participants.
    @objc public func startLocalRecording(
        screenShareSource: InterSurfaceShareController,
        subscriber: InterLiveKitSubscriber,
        localMediaController: InterLocalMediaController,
        userTier: String
    ) {
        startLocalRecording(
            screenShareSource: screenShareSource,
            subscriber: subscriber,
            localMediaController: localMediaController,
            userTier: userTier,
            existingParticipants: []
        )
    }

    // -----------------------------------------------------------------------
    // MARK: - Pause / Resume / Stop
    // -----------------------------------------------------------------------

    /// Pause the current recording. Frames received while paused are silently dropped.
    @objc public func pauseRecording() {
        coordinatorQueue.async { [weak self] in
            self?._pauseRecording()
        }
    }

    /// Resume a paused recording.
    @objc public func resumeRecording() {
        coordinatorQueue.async { [weak self] in
            self?._resumeRecording()
        }
    }

    /// Stop the current recording and finalize the output file.
    @objc public func stopRecording() {
        coordinatorQueue.async { [weak self] in
            self?._stopRecording()
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - Active Speaker Events
    // -----------------------------------------------------------------------

    /// Called when the active speaker changes. Applies a 2-second debounce hold.
    @objc public func activeSpeakerDidChange(_ participantId: String) {
        // Guard: ignore empty identity strings. InterRoomController sends ""
        // when no remote participant is speaking (e.g. 1-person call or brief
        // silence). Accepting an empty string as the active speaker would
        // orphan the active speaker slot — no one sends frames for identity
        // "", so the active buffer freezes while real frames are diverted
        // to the secondary slot, producing a frozen duplicate in the recording.
        guard !participantId.isEmpty else { return }
        coordinatorQueue.async { [weak self] in
            self?._handleActiveSpeakerChange(participantId)
        }
    }

    /// Called when a participant's camera mutes/unmutes — updates placeholder logic.
    @objc public func participantCameraDidChange(_ participantId: String, isMuted: Bool) {
        coordinatorQueue.async { [weak self] in
            guard let self = self, self._state == .recording || self._state == .paused else { return }
            guard let renderer = self.composedRenderer else { return }

            if isMuted {
                // Generate placeholder for camera-muted participant
                let placeholder = renderer.placeholderFrame(forIdentity: participantId).takeUnretainedValue()
                if self._useGridLayout {
                    renderer.updateParticipantFrame(placeholder, identity: participantId)
                } else if self._activeSpeakerId == participantId {
                    renderer.updateActiveSpeakerFrame(placeholder, identity: participantId)
                } else {
                    // Check if this participant is the current secondary speaker.
                    // If so, show their placeholder instead of a frozen last frame.
                    let secondaryId = self._recentSpeakers.count >= 2
                        ? self._recentSpeakers.first(where: { $0 != self._activeSpeakerId })
                        : nil
                    if secondaryId == participantId {
                        renderer.updateSecondarySpeakerFrame(placeholder, identity: participantId)
                    }
                }
            }
            // When camera unmutes, the next frame delivery will naturally update the renderer.
        }
    }

    /// Provide a participant's display name for camera-off placeholders (avatar + name)
    /// in the recording. Safe to call at any time; ignored if not currently recording.
    @objc public func setParticipantDisplayName(_ name: String, forIdentity identity: String) {
        guard !identity.isEmpty else { return }
        coordinatorQueue.async { [weak self] in
            guard let self = self else { return }
            self._participantDisplayNames[identity] = name
            self.composedRenderer?.setDisplayName(name, forIdentity: identity)
        }
    }

    /// Called when the LOCAL participant turns their camera on/off during recording.
    /// When the local camera goes off, AVCaptureVideoDataOutput is removed and frame
    /// delivery stops — without this hook the composed recording would FREEZE on the
    /// last local frame. Routing through `participantCameraDidChange` swaps in the
    /// avatar/name placeholder; the next real frame restores video on un-mute.
    @objc public func localCameraDidChange(_ isOff: Bool) {
        os_unfair_lock_lock(&_stateLock)
        let localId = _localParticipantIdentity ?? ""
        os_unfair_lock_unlock(&_stateLock)
        guard !localId.isEmpty else { return }
        participantCameraDidChange(localId, isMuted: isOff)
    }

    /// Called when a new participant joins mid-recording — adds to grid tracking.
    @objc public func participantDidJoin(_ participantId: String) {
        coordinatorQueue.async { [weak self] in
            guard let self = self, self._state == .recording || self._state == .paused else { return }
            guard !participantId.isEmpty else { return }

            // Add to all-participants list if not already present.
            if !self._allParticipants.contains(participantId) {
                self._allParticipants.append(participantId)
            }

            // Also register in _recentSpeakers immediately so their camera
            // frames are routable as the secondary speaker in non-grid mode.
            // Without this, frames from newly-joined participants are silently
            // dropped until activeSpeakerDidChange fires for them.
            if !self._recentSpeakers.contains(participantId) {
                self._recentSpeakers.append(participantId)
            }

            // Re-evaluate grid vs. active/secondary layout.
            self._updateLayoutMode()
        }
    }

    /// Called when a participant leaves — clears stale frame references.
    @objc public func participantDidLeave(_ participantId: String) {
        coordinatorQueue.async { [weak self] in
            guard let self = self, self._state == .recording || self._state == .paused else { return }

            // Remove from all tracking lists.
            self._recentSpeakers.removeAll { $0 == participantId }
            self._allParticipants.removeAll { $0 == participantId }

            if self._useGridLayout {
                // Remove from grid renderer.
                self.composedRenderer?.removeParticipant(participantId)
                // Re-evaluate layout mode (may drop back to side-by-side or full).
                self._updateLayoutMode()
            } else {
                // Active/secondary speaker path.
                if self._activeSpeakerId == participantId {
                    self._activeSpeakerId = nil
                    self.composedRenderer?.updateActiveSpeakerFrame(nil, identity: nil)

                    // Promote next recent speaker if available
                    if let next = self._recentSpeakers.first {
                        self._handleActiveSpeakerChange(next)
                    }
                }

                // Clear the secondary buffer if no valid secondary remains
                // after this participant left. Prevents a frozen stale frame.
                let remainingSecondary = self._recentSpeakers.first(where: { $0 != self._activeSpeakerId })
                if remainingSecondary == nil {
                    self.composedRenderer?.updateSecondarySpeakerFrame(nil, identity: nil)
                }
            }

            // If the leaving participant was screen sharing, clear it.
            if self._activeScreenShareIdentity == participantId {
                self._activeScreenShareIdentity = nil
                if let sink = self.recordingSink {
                    self.surfaceShareController?.removeLive(sink)
                }
                self.composedRenderer?.updateScreenShareFrame(nil)
            }
        }
    }

    /// Called when screen share starts/stops mid-recording.
    /// @param isActive Whether screen sharing is currently active.
    /// @param participantId Identity of the participant who started/stopped sharing.
    ///        Pass nil for backward compatibility (defaults to accepting any share).
    @objc public func screenShareDidChange(isActive: Bool, participantId: String?) {
        coordinatorQueue.async { [weak self] in
            guard let self = self, self._state == .recording || self._state == .paused else { return }

            if isActive {
                // Host-priority: if a non-host starts sharing while a host is already sharing, ignore it.
                if let hostId = self._hostIdentity,
                   let activeShareId = self._activeScreenShareIdentity,
                   activeShareId == hostId,
                   participantId != hostId {
                    interLogInfo(InterRecordingCoordinator.log,
                                 "Recording: ignoring non-host screen share (host has priority)")
                    return
                }

                // Host-priority: if host starts sharing while a non-host is sharing, switch to host's.
                if let hostId = self._hostIdentity,
                   participantId == hostId,
                   let currentShareId = self._activeScreenShareIdentity,
                   currentShareId != hostId {
                    interLogInfo(InterRecordingCoordinator.log,
                                 "Recording: switching to host screen share (host priority)")
                    // Remove the current non-host share sink; it will be replaced.
                    if let sink = self.recordingSink {
                        self.surfaceShareController?.removeLive(sink)
                    }
                    self.composedRenderer?.updateScreenShareFrame(nil)
                }

                self._activeScreenShareIdentity = participantId

                // Recording sink will be added when sinks dispatch frames.
                if let sink = self.recordingSink {
                    self.surfaceShareController?.addLive(sink)
                }
            } else {
                // Only clear if the stopping participant is the one currently sharing.
                if participantId == nil || participantId == self._activeScreenShareIdentity {
                    self._activeScreenShareIdentity = nil
                    // Screen share stopped — remove recording sink and clear source
                    if let sink = self.recordingSink {
                        self.surfaceShareController?.removeLive(sink)
                    }
                    self.composedRenderer?.updateScreenShareFrame(nil)
                }
            }
        }
    }

    /// Convenience overload — screen share change without a specific participant ID.
    @objc public func screenShareDidChange(isActive: Bool) {
        screenShareDidChange(isActive: isActive, participantId: nil)
    }

    // -----------------------------------------------------------------------
    // MARK: - Remote Frame Forwarding
    // -----------------------------------------------------------------------

    /// Called by external frame routing to deliver a remote camera frame for the
    /// active speaker. This is how InterRemoteTrackRenderer frames reach the
    /// composed renderer during recording.
    @objc public func didReceiveRemoteCameraFrame(_ pixelBuffer: CVPixelBuffer,
                                                   fromParticipant participantId: String) {
        // Snapshot all coordinatorQueue-guarded state in one sync hop before
        // calling any renderer methods. The sync block does only value copies —
        // no I/O, no locks — so it completes in microseconds. Renderer calls
        // happen outside the sync so the queue is never held during rendering.
        let snapshot: (renderer: InterComposedRenderer, hasRemoteLiveFrame: Bool, localId: String?, useGrid: Bool)?
        snapshot = coordinatorQueue.sync {
            guard _state == .recording || _state == .paused,
                  let renderer = composedRenderer else { return nil }
            // [B3] Insert the just-arrived sender INSIDE the snapshot so the
            // "remote has a live frame" predicate sees it immediately (covers both
            // the remote-already-present and remote-joins-after-start timings).
            _identitiesWithLiveFrame.insert(participantId)
            os_unfair_lock_lock(&_stateLock)
            let localId = _localParticipantIdentity
            os_unfair_lock_unlock(&_stateLock)
            let hasRemoteLiveFrame = InterRecordingLayoutLogic.hasRemoteActiveSpeaker(
                localId: localId, identitiesWithLiveFrame: _identitiesWithLiveFrame)
            return (renderer, hasRemoteLiveFrame, localId, _useGridLayout)
        }
        guard let (renderer, hasRemoteLiveFrame, localId, useGrid) = snapshot else { return }

        if useGrid {
            // Grid mode: route all frames to grid participant storage (keyed by identity).
            // The local participant is part of the grid order, so the host always renders.
            renderer.updateParticipantFrame(pixelBuffer, identity: participantId)
        } else {
            // Non-grid (≤2 participants). The LOCAL participant is never an active
            // speaker: it renders in the secondary slot when a remote holds the primary,
            // and in the primary slot when it is the only camera. This guarantees the
            // host is always rendered (the freeze fix). The single remote (if any)
            // always renders in the primary slot.
            let isLocal = (localId != nil && participantId == localId)
            if isLocal {
                switch InterRecordingLayoutLogic.localSlot(hasRemoteActiveSpeaker: hasRemoteLiveFrame) {
                case .primary:
                    renderer.updateActiveSpeakerFrame(pixelBuffer, identity: participantId)
                case .secondary:
                    renderer.updateSecondarySpeakerFrame(pixelBuffer, identity: participantId)
                }
            } else {
                // Remote camera frame → primary (active) slot.
                renderer.updateActiveSpeakerFrame(pixelBuffer, identity: participantId)
            }
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - Layout Mode Management (coordinatorQueue)
    // -----------------------------------------------------------------------

    /// Re-evaluate whether to use grid layout vs. active/secondary speaker layout.
    /// Called when participants join/leave. Must run on coordinatorQueue.
    private func _updateLayoutMode() {
        dispatchPrecondition(condition: .onQueue(coordinatorQueue))
        guard let renderer = composedRenderer else { return }

        let previousGridMode = _useGridLayout
        // Switch to grid when 3+ participants are in the call (auto), honoring the
        // host's layout preference (speaker view never grids).
        _useGridLayout = InterRecordingLayoutLogic.useGrid(participantCount: _allParticipants.count,
                                                           preference: _layoutPref)

        if _useGridLayout != previousGridMode {
            if _useGridLayout {
                // Transitioning TO grid mode.
                interLogInfo(InterRecordingCoordinator.log,
                             "Recording: switching to grid layout (%lu participants)",
                             UInt(truncating: _allParticipants.count as NSNumber))

                // Clear legacy active/secondary speaker frames from renderer.
                renderer.updateActiveSpeakerFrame(nil, identity: nil)
                renderer.updateSecondarySpeakerFrame(nil, identity: nil)

                // Set participant order and seed placeholders for all participants.
                renderer.setParticipantOrder(_allParticipants)
                for participantId in _allParticipants {
                    let placeholder = renderer.placeholderFrame(forIdentity: participantId).takeUnretainedValue()
                    renderer.updateParticipantFrame(placeholder, identity: participantId)
                }
            } else {
                // Transitioning FROM grid mode back to active/secondary speaker.
                interLogInfo(InterRecordingCoordinator.log,
                             "Recording: switching from grid to active speaker layout (%lu participants)",
                             UInt(truncating: _allParticipants.count as NSNumber))

                // Clear all grid participant frames.
                for participantId in _allParticipants {
                    renderer.removeParticipant(participantId)
                }

                // Re-seed active speaker from recent speakers.
                if let active = _activeSpeakerId {
                    let placeholder = renderer.placeholderFrame(forIdentity: active).takeUnretainedValue()
                    renderer.updateActiveSpeakerFrame(placeholder, identity: active)
                }
            }
        } else if _useGridLayout {
            // Grid mode still active — just update the participant order.
            renderer.setParticipantOrder(_allParticipants)
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - State Machine (Private — coordinatorQueue only)
    // -----------------------------------------------------------------------

    /// Transition to a new state. MUST only be called on coordinatorQueue.
    private func transitionTo(_ newState: InterRecordingState) {
        dispatchPrecondition(condition: .onQueue(coordinatorQueue))

        let oldState = _state
        guard isValidTransition(from: oldState, to: newState) else {
            interLogError(InterRecordingCoordinator.log,
                          "Recording: invalid transition %d → %d",
                          oldState.rawValue, newState.rawValue)
            return
        }

        os_unfair_lock_lock(&_stateLock)
        _state = newState
        os_unfair_lock_unlock(&_stateLock)

        interLogInfo(InterRecordingCoordinator.log,
                     "Recording state: %d → %d", oldState.rawValue, newState.rawValue)

        // Notify delegate on main thread
        let delegateRef = delegate
        DispatchQueue.main.async {
            delegateRef?.recordingStateDidChange(newState)
        }
    }

    /// Valid state transitions per §13 of the architecture document.
    private func isValidTransition(from: InterRecordingState, to: InterRecordingState) -> Bool {
        switch (from, to) {
        case (.idle, .starting),
             (.starting, .recording), (.starting, .failed),
             (.recording, .paused), (.recording, .stopping), (.recording, .failed),
             (.paused, .recording), (.paused, .stopping), (.paused, .failed),
             (.stopping, .finalized), (.stopping, .failed),
             (.finalized, .idle), (.failed, .idle):
            return true
        default:
            return false
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - Start Implementation (coordinatorQueue)
    // -----------------------------------------------------------------------

    private func _startLocalRecording(
        screenShareSource: InterSurfaceShareController,
        subscriber: InterLiveKitSubscriber,
        localMediaController: InterLocalMediaController,
        userTier: String,
        existingParticipants: [String]
    ) {
        dispatchPrecondition(condition: .onQueue(coordinatorQueue))

        guard _state == .idle else {
            interLogError(InterRecordingCoordinator.log,
                          "Recording: cannot start — state is %d", _state.rawValue)
            return
        }

        transitionTo(.starting)
        _pendingStop = false

        // Pre-check: verify sufficient disk space before starting
        let availableSpace = Self.availableDiskSpaceBytes()
        if availableSpace < Self.diskSpaceCriticalThreshold {
            interLogError(InterRecordingCoordinator.log,
                          "Recording: insufficient disk space (%llu MB free)", availableSpace / 1_000_000)
            transitionTo(.failed)
            let delegateRef = delegate
            DispatchQueue.main.async {
                let error = NSError(domain: "inter.recording", code: -10,
                                    userInfo: [NSLocalizedDescriptionKey:
                                        "Not enough disk space to start recording. At least 500 MB is required."])
                delegateRef?.recordingDidComplete(outputURL: nil, error: error)
            }
            return
        }
        if availableSpace < Self.diskSpaceWarningThreshold {
            interLogWarning(InterRecordingCoordinator.log,
                            "Recording: low disk space warning (%llu MB free)", availableSpace / 1_000_000)
        }

        self.surfaceShareController = screenShareSource
        self.subscriber = subscriber
        self.localMediaController = localMediaController
        self.userTier = userTier

        // 1. Generate output URL in ~/Documents/Inter Recordings/
        let outputURL = Self.generateOutputURL()
        os_unfair_lock_lock(&_stateLock)
        self._outputURL = outputURL
        os_unfair_lock_unlock(&_stateLock)

        // 2. Create recording engine
        let engine = InterRecordingEngine(
            outputURL: outputURL,
            videoSize: CGSize(width: 1920, height: 1080),
            frameRate: 30,
            audioChannels: 2,
            audioSampleRate: 48000.0
        )
        engine.delegate = self
        self.recordingEngine = engine

        // 3. Create composed renderer
        let metalEngine = MetalRenderEngine.shared()
        let renderer = InterComposedRenderer(
            device: metalEngine.device,
            commandQueue: metalEngine.commandQueue,
            outputSize: CGSize(width: 1920, height: 1080)
        )
        renderer.watermarkEnabled = (userTier.lowercased() == "free")
        renderer.delegate = self
        renderer.designatedRenderQueue = coordinatorQueue
        self.composedRenderer = renderer
        // Replay any display names captured before the renderer existed so the very
        // first camera-off placeholders show names/avatars rather than raw identities.
        for (identity, name) in _participantDisplayNames {
            renderer.setDisplayName(name, forIdentity: identity)
        }

        // 4. Create recording sink (for screen share frames + audio from surface share)
        let sink = InterRecordingSink()
        sink.composedRenderer = renderer
        sink.recordingEngine = engine
        self.recordingSink = sink

        // 5. Start the AVAssetWriter
        let started = engine.startRecording()
        guard started else {
            interLogError(InterRecordingCoordinator.log,
                          "Recording: AVAssetWriter failed to start")
            self._teardownPipeline()
            transitionTo(.failed)
            let delegateRef = delegate
            DispatchQueue.main.async {
                let error = NSError(domain: "inter.recording", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Failed to start recording engine."])
                delegateRef?.recordingDidComplete(outputURL: nil, error: error)
            }
            return
        }

        // 6. If screen share is active, insert the recording sink into the live pipeline
        if screenShareSource.isSharing {
            screenShareSource.addLive(sink)
            _activeScreenShareIdentity = nil  // Will be set by screenShareDidChange if needed
        }

        // 7. Populate with existing participants already in the call.
        _allParticipants = []
        if let localId = _localParticipantIdentity, !localId.isEmpty {
            _allParticipants.append(localId)
        }
        for pid in existingParticipants {
            if !_allParticipants.contains(pid) {
                _allParticipants.append(pid)
            }
        }
        // Evaluate whether grid mode is needed from the start.
        os_unfair_lock_lock(&_stateLock)
        _layoutPref = _preferredLayoutStorage
        os_unfair_lock_unlock(&_stateLock)
        _useGridLayout = InterRecordingLayoutLogic.useGrid(participantCount: _allParticipants.count,
                                                           preference: _layoutPref)
        if _useGridLayout {
            renderer.setParticipantOrder(_allParticipants)
            for participantId in _allParticipants {
                let placeholder = renderer.placeholderFrame(forIdentity: participantId).takeUnretainedValue()
                renderer.updateParticipantFrame(placeholder, identity: participantId)
            }
        } else {
            // Bootstrap active speaker so the first camera frames are immediately
            // routed. Without this, _activeSpeakerId stays nil until
            // activeSpeakerDidChange fires — which may fire late or never in a
            // 1-person call — causing every frame to be silently dropped and
            // leaving the recording with an entirely black video track.
            // [B3] Prefer the first NON-LOCAL participant so _activeSpeakerId is
            // semantically accurate for placeholder logic; fall back to first/local
            // when there is no remote (preserves the 1-person black-video bootstrap).
            // Slot routing no longer depends on _activeSpeakerId — see
            // didReceiveRemoteCameraFrame's hasRemoteActiveSpeaker predicate.
            let localId = _localParticipantIdentity
            let bootstrapId = _allParticipants.first(where: { $0 != localId }) ?? _allParticipants.first
            if let active = bootstrapId {
                _activeSpeakerId = active
                _recentSpeakers = _allParticipants   // seeds secondary speaker too
                _activeSpeakerHoldUntil = CFAbsoluteTimeGetCurrent() + 2.0
            }
        }

        // 8. Set subscriber recording frame delegate
        subscriber.recordingFrameDelegate = self

        // Note: remote participants are added via participantDidJoin() calls
        // from the subscriber during the recording lifecycle. The coordinator
        // will receive participantDidJoin for all existing participants
        // shortly after subscriber.recordingFrameDelegate is set.

        // 9. Install local camera frame observer (for when local user is active speaker)
        _installLocalCameraObserver()

        // 10. Install audio capture (extracted subsystem — Gap #14)
        audioCapture.onSampleBuffer = { [weak self] sampleBuffer in
            self?.recordingEngine?.appendAudioSampleBuffer(sampleBuffer)
        }
        audioCapture.start()

        // 11. Start 30fps render timer
        _startRenderTimer()

        // 12. Start 1-second duration timer
        _startDurationTimer()

        // 13. Start disk space monitor (30-second interval)
        _startDiskSpaceMonitor()

        // 14. Check pending stop
        if _pendingStop {
            _pendingStop = false
            transitionTo(.recording)
            _stopRecording()
            return
        }

        transitionTo(.recording)

        // Persist state for crash recovery
        _persistRecordingState()

        let cc = chatController
        DispatchQueue.main.async {
            cc?.broadcastRecordingSignal(type: .recordingStarted)
            // [Gap #8] Play a system chime so the user has audible confirmation.
            NSSound.beep()
        }

        interLogInfo(InterRecordingCoordinator.log,
                     "Recording: started at %{public}@", outputURL.lastPathComponent)
        // Note: `outputURL` here is the local constant from generateOutputURL(), not the ivar.
    }

    // -----------------------------------------------------------------------
    // MARK: - Pause / Resume / Stop (coordinatorQueue)
    // -----------------------------------------------------------------------

    private func _pauseRecording() {
        dispatchPrecondition(condition: .onQueue(coordinatorQueue))
        guard _state == .recording else { return }

        recordingEngine?.pauseRecording()
        transitionTo(.paused)
        let cc = chatController
        DispatchQueue.main.async { cc?.broadcastRecordingSignal(type: .recordingPaused) }
    }

    private func _resumeRecording() {
        dispatchPrecondition(condition: .onQueue(coordinatorQueue))
        guard _state == .paused else { return }

        recordingEngine?.resumeRecording()
        transitionTo(.recording)
        let cc = chatController
        DispatchQueue.main.async { cc?.broadcastRecordingSignal(type: .recordingResumed) }
    }

    private func _stopRecording() {
        dispatchPrecondition(condition: .onQueue(coordinatorQueue))

        // Handle stop-during-start
        if _state == .starting {
            _pendingStop = true
            interLogInfo(InterRecordingCoordinator.log,
                         "Recording: stop queued (state is .starting)")
            return
        }

        guard _state == .recording || _state == .paused else { return }

        transitionTo(.stopping)
        _hasPostedOneHourWarning = false
        let cc = chatController
        DispatchQueue.main.async {
            cc?.broadcastRecordingSignal(type: .recordingStopped)
            // [Gap #8] Play a system chime on recording stop.
            NSSound.beep()
        }

        // 1. Stop timers
        renderTimer?.cancel()
        renderTimer = nil
        durationTimer?.cancel()
        durationTimer = nil
        diskSpaceTimer?.cancel()
        diskSpaceTimer = nil

        // 2. Remove audio capture (extracted subsystem — Gap #14)
        audioCapture.stop()

        // 3. Remove local camera observer
        _removeLocalCameraObserver()

        // 4. Remove subscriber recording delegate
        subscriber?.recordingFrameDelegate = nil

        // 5. Remove recording sink from surface share controller
        if let sink = recordingSink {
            surfaceShareController?.removeLive(sink)
        }

        // 4. Finalize the recording engine
        let capturedURL = _outputURL
        let delegateRef = delegate
        recordingEngine?.stopRecording { [weak self] (url, error) in
            guard let self = self else { return }
            self.coordinatorQueue.async {
                self._teardownPipeline()
                self._clearRecordingState()

                if let error = error {
                    interLogError(InterRecordingCoordinator.log,
                                  "Recording: finalize failed — %{public}@", error.localizedDescription)
                    self.transitionTo(.failed)
                    DispatchQueue.main.async {
                        delegateRef?.recordingDidComplete(outputURL: nil, error: error)
                    }
                } else {
                    let finalURL = url ?? capturedURL
                    interLogInfo(InterRecordingCoordinator.log,
                                 "Recording: finalized at %{public}@",
                                 finalURL?.lastPathComponent ?? "nil")
                    self.transitionTo(.finalized)
                    DispatchQueue.main.async {
                        delegateRef?.recordingDidComplete(outputURL: finalURL, error: nil)
                    }
                    // Auto-reset to idle after finalized (ready for next recording)
                    self.transitionTo(.idle)
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - Teardown (coordinatorQueue)
    // -----------------------------------------------------------------------

    private func _teardownPipeline() {
        dispatchPrecondition(condition: .onQueue(coordinatorQueue))

        renderTimer?.cancel()
        renderTimer = nil
        diskSpaceTimer?.cancel()
        diskSpaceTimer = nil
        durationTimer?.cancel()
        durationTimer = nil
        // [Gap #14] audioDrainTimer is owned by InterRecordingAudioCapture; stop() handles it.
        _speakerDebounceTimer?.cancel()
        _speakerDebounceTimer = nil

        composedRenderer?.invalidate()
        composedRenderer = nil
        recordingEngine = nil
        recordingSink = nil
        // [Gap #14] audioRingBuffer is owned by InterRecordingAudioCapture.
        os_unfair_lock_lock(&_stateLock)
        _outputURL = nil
        os_unfair_lock_unlock(&_stateLock)

        _activeSpeakerId = nil
        _pendingSpeakerId = nil
        _recentSpeakers.removeAll()
        _activeSpeakerHoldUntil = 0
        _allParticipants.removeAll()
        _identitiesWithLiveFrame.removeAll()
        _useGridLayout = false
        _activeScreenShareIdentity = nil

        surfaceShareController = nil
        subscriber = nil
        localMediaController = nil
    }

    // -----------------------------------------------------------------------
    // MARK: - Render Timer (30fps)
    // -----------------------------------------------------------------------

    private func _startRenderTimer() {
        dispatchPrecondition(condition: .onQueue(coordinatorQueue))

        let timer = DispatchSource.makeTimerSource(queue: coordinatorQueue)
        // 30fps = ~33.33ms interval
        timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?._renderTick()
        }
        renderTimer = timer
        timer.resume()
    }

    private func _renderTick() {
        dispatchPrecondition(condition: .onQueue(coordinatorQueue))
        guard _state == .recording || _state == .paused else { return }
        guard let renderer = composedRenderer, let engine = recordingEngine else { return }

        guard let unmanaged = renderer.renderComposedFrame() else { return }
        let pixelBuffer = unmanaged.takeUnretainedValue()

        let time = CMTimeMakeWithSeconds(CACurrentMediaTime(), preferredTimescale: 600)
        engine.appendVideoPixelBuffer(pixelBuffer, presentationTime: time)
    }

    // -----------------------------------------------------------------------
    // MARK: - Duration Timer (1-second)
    // -----------------------------------------------------------------------

    private func _startDurationTimer() {
        dispatchPrecondition(condition: .onQueue(coordinatorQueue))

        let timer = DispatchSource.makeTimerSource(queue: coordinatorQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard self._state == .recording else { return }
            guard let engine = self.recordingEngine else { return }

            let duration = CMTimeGetSeconds(engine.recordedDuration)
            let delegateRef = self.delegate
            DispatchQueue.main.async {
                delegateRef?.recordingDurationDidUpdate(duration)
            }

            // [Gap #5] Warn user once when recording exceeds 1 hour
            if !self._hasPostedOneHourWarning && duration >= Self.oneHourWarningThreshold {
                self._hasPostedOneHourWarning = true
                interLogInfo(InterRecordingCoordinator.log,
                             "Recording: duration exceeded 1 hour — posting warning")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("InterRecordingOneHourWarning"),
                        object: nil,
                        userInfo: ["duration": duration]
                    )
                }
            }
        }
        durationTimer = timer
        timer.resume()
    }

    // --------Disk Space Monitor (30-second interval, coordinatorQueue)
    // -----------------------------------------------------------------------

    /// Start a periodic disk space check on coordinatorQueue.
    /// Per §6 of recording_architecture.md:
    ///  - Warn at < 2 GB free
    ///  - Auto-stop with error at < 500 MB free
    private func _startDiskSpaceMonitor() {
        dispatchPrecondition(condition: .onQueue(coordinatorQueue))

        let timer = DispatchSource.makeTimerSource(queue: coordinatorQueue)
        timer.schedule(deadline: .now() + 30.0, repeating: 30.0, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard self._state == .recording || self._state == .paused else { return }

            let available = Self.availableDiskSpaceBytes()

            if available < Self.diskSpaceCriticalThreshold {
                // Critical — auto-stop recording immediately
                interLogError(InterRecordingCoordinator.log,
                              "Recording: auto-stopping — disk space critical (%llu MB free)",
                              available / 1_000_000)
                // Transition through stop so the file is finalized properly
                self._stopRecording()

                let delegateRef = self.delegate
                DispatchQueue.main.async {
                    // Post a notification so the UI can show an alert
                    NotificationCenter.default.post(
                        name: NSNotification.Name("InterRecordingDiskSpaceCritical"),
                        object: nil,
                        userInfo: ["availableMB": available / 1_000_000]
                    )
                    let _ = delegateRef // suppress unused warning
                }
            } else if available < Self.diskSpaceWarningThreshold {
                interLogWarning(InterRecordingCoordinator.log,
                                "Recording: low disk space warning (%llu MB free)", available / 1_000_000)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("InterRecordingDiskSpaceLow"),
                        object: nil,
                        userInfo: ["availableMB": available / 1_000_000]
                    )
                }
            }
        }
        diskSpaceTimer = timer
        timer.resume()
    }

    /// Returns the available disk space in bytes on the volume containing the documents directory.
    @objc public static func availableDiskSpaceBytes() -> UInt64 {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        do {
            let values = try documentsURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let available = values.volumeAvailableCapacityForImportantUsage {
                return UInt64(max(0, available))
            }
        } catch {
            // Fallback: try the older key
        }
        do {
            let values = try documentsURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            if let available = values.volumeAvailableCapacity {
                return UInt64(max(0, available))
            }
        } catch {
            interLogError(log, "Recording: failed to check disk space — %{public}@", error.localizedDescription)
        }
        return UInt64.max // If we can't determine, don't block recording
    }

    // -----------------------------------------------------------------------
    // MARK: - Room Disconnect Auto-Stop (Phase 10D)
    // -----------------------------------------------------------------------

    /// Called when the LiveKit room disconnects or is destroyed.
    /// Automatically stops any active local or cloud recording.
    ///
    /// This should be called by `InterRoomController` or `InterCallSessionCoordinator`
    /// when a room disconnect event is received.
    @objc public func handleRoomDisconnect(serverURL: String?, roomCode: String?, callerIdentity: String?) {
        coordinatorQueue.async { [weak self] in
            guard let self = self else { return }

            // Auto-stop local recording if active
            if self._state == .recording || self._state == .paused {
                interLogInfo(InterRecordingCoordinator.log,
                             "Recording: auto-stopping local recording due to room disconnect")
                self._stopRecording()
            }

            // Auto-stop cloud recording if active
            if let egressId = self._cloudEgressId, !egressId.isEmpty,
               let serverURL = serverURL, let roomCode = roomCode, let callerIdentity = callerIdentity {
                interLogInfo(InterRecordingCoordinator.log,
                             "Recording: auto-stopping cloud recording due to room disconnect")
                // Fire-and-forget cloud stop — the session will be cleaned up server-side
                // even if this request fails (via Egress webhooks or timeout)
                self.stopCloudRecording(serverURL: serverURL,
                                        roomCode: roomCode,
                                        callerIdentity: callerIdentity,
                                        egressId: egressId) { _, _ in
                    // Best-effort — ignore result
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - Orphaned File Cleanup (Phase 10D)
    // -----------------------------------------------------------------------

    /// Scan for orphaned recording files on app launch and clean them up.
    /// Per §6 of recording_architecture.md:
    ///  - Detect orphaned .tmp files (from interrupted AVAssetWriter)
    ///  - Detect incomplete .mp4 files that might be corrupt
    ///
    /// Should be called once from AppDelegate at startup.
    @objc public static func cleanOrphanedRecordingFiles() {
        let fm = FileManager.default
        guard let documentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let recordingsDir = documentsURL.appendingPathComponent("Inter Recordings", isDirectory: true)

        guard fm.fileExists(atPath: recordingsDir.path) else { return }

        do {
            let contents = try fm.contentsOfDirectory(at: recordingsDir,
                                                       includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
                                                       options: [.skipsHiddenFiles])

            for fileURL in contents {
                let ext = fileURL.pathExtension.lowercased()

                // Remove .tmp files — these are from interrupted AVAssetWriter sessions
                if ext == "tmp" {
                    interLogInfo(log, "Recording: removing orphaned temp file: %{public}@",
                                 fileURL.lastPathComponent)
                    try? fm.removeItem(at: fileURL)
                    continue
                }

                // Check for very small .mp4 files (< 1 KB) — likely corrupt/incomplete
                if ext == "mp4" {
                    let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                    if let size = resourceValues.fileSize, size < 1024 {
                        interLogInfo(log, "Recording: removing corrupt recording (< 1 KB): %{public}@",
                                     fileURL.lastPathComponent)
                        try? fm.removeItem(at: fileURL)
                    }
                }
            }
        } catch {
            interLogError(log, "Recording: failed to scan for orphaned files — %{public}@",
                          error.localizedDescription)
        }

        // Also check for orphaned state file
        let stateURL = Self.recordingStateFileURL()
        if fm.fileExists(atPath: stateURL.path) {
            interLogInfo(log, "Recording: removing orphaned recording state file (app crashed during recording)")
            try? fm.removeItem(at: stateURL)
        }
    }

    /// URL for the recording state persistence file.
    /// Per §18 of recording_architecture.md — persist state before starting,
    /// remove after clean stop. Presence on launch = crash during recording.
    private static func recordingStateFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let interDir = appSupport.appendingPathComponent("inter", isDirectory: true)
        try? FileManager.default.createDirectory(at: interDir, withIntermediateDirectories: true)
        return interDir.appendingPathComponent("recording_state.json")
    }

    /// Persist minimal recording state (output path, start timestamp) so crash
    /// recovery can detect orphaned files. Called at recording start, removed at stop.
    private func _persistRecordingState() {
        guard let url = _outputURL else { return }
        let state: [String: String] = [
            "outputPath": url.path,
            "startedAt": ISO8601DateFormatter().string(from: Date())
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state) {
            try? data.write(to: Self.recordingStateFileURL())
        }
    }

    /// Remove the recording state file after a clean stop/finalize.
    private func _clearRecordingState() {
        try? FileManager.default.removeItem(at: Self.recordingStateFileURL())
    }

    // -----------------------------------------------------------------------
    // MARK: - ---------------------------------------------------------------
    // MARK: - Local Camera Frame Observer (Phase 10)
    // -----------------------------------------------------------------------

    /// Install a recording frame observer on the local media controller.
    /// When the local user is the active speaker, their camera frames are
    /// forwarded to the composed renderer as the active speaker PiP source.
    private func _installLocalCameraObserver() {
        guard let lmc = localMediaController else { return }

        // Snapshot _localParticipantIdentity once under _stateLock at install time.
        // The closure captures this immutable constant so it never races with
        // concurrent writes to _localParticipantIdentity on other threads.
        os_unfair_lock_lock(&_stateLock)
        let capturedIdentity = _localParticipantIdentity ?? ""
        os_unfair_lock_unlock(&_stateLock)

        guard !capturedIdentity.isEmpty else { return }

        lmc.recordingFrameObserver = { [weak self] pixelBuffer in
            guard let self = self else { return }
            // Forward to didReceiveRemoteCameraFrame which handles active/secondary
            // speaker routing. Identity was snapshotted under _stateLock at install time.
            self.didReceiveRemoteCameraFrame(pixelBuffer, fromParticipant: capturedIdentity)
        }

        // Observe local camera on/off so the recording shows a placeholder (not a frozen
        // frame) when the local camera is turned off, and restores video when turned on.
        lmc.recordingCameraStateObserver = { [weak self] enabled in
            self?.localCameraDidChange(!enabled)
        }
    }

    /// Remove the recording frame observer from the local media controller.
    private func _removeLocalCameraObserver() {
        localMediaController?.recordingFrameObserver = nil
        localMediaController?.recordingCameraStateObserver = nil
    }

    // -----------------------------------------------------------------------
    // MARK: - Active Speaker Debounce (coordinatorQueue)
    // -----------------------------------------------------------------------

    /// Debounced active speaker change — 2-second hold time per §3.2 of the architecture.
    private func _handleActiveSpeakerChange(_ participantId: String) {
        dispatchPrecondition(condition: .onQueue(coordinatorQueue))
        guard _state == .recording || _state == .paused else { return }

        // Update recent speakers list
        _recentSpeakers.removeAll { $0 == participantId }
        _recentSpeakers.insert(participantId, at: 0)
        // Keep list capped at 5
        if _recentSpeakers.count > 5 {
            _recentSpeakers.removeLast()
        }

        // If no current active speaker, accept immediately
        if _activeSpeakerId == nil {
            _acceptSpeakerSwitch(participantId)
            return
        }

        // If same speaker, no-op
        if _activeSpeakerId == participantId { return }

        let now = CFAbsoluteTimeGetCurrent()

        // If hold time has elapsed, accept immediately
        if now >= _activeSpeakerHoldUntil {
            _acceptSpeakerSwitch(participantId)
            return
        }

        // Otherwise queue as pending and start debounce timer
        _pendingSpeakerId = participantId

        if _speakerDebounceTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: coordinatorQueue)
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in
                self?._checkPendingSpeaker()
            }
            _speakerDebounceTimer = timer
            timer.resume()
        }
    }

    private func _checkPendingSpeaker() {
        dispatchPrecondition(condition: .onQueue(coordinatorQueue))

        guard let pending = _pendingSpeakerId else {
            _speakerDebounceTimer?.cancel()
            _speakerDebounceTimer = nil
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        if now >= _activeSpeakerHoldUntil {
            _acceptSpeakerSwitch(pending)
            _pendingSpeakerId = nil
            _speakerDebounceTimer?.cancel()
            _speakerDebounceTimer = nil
        }
    }

    private func _acceptSpeakerSwitch(_ participantId: String) {
        dispatchPrecondition(condition: .onQueue(coordinatorQueue))

        let previousSpeaker = _activeSpeakerId
        _activeSpeakerId = participantId
        _activeSpeakerHoldUntil = CFAbsoluteTimeGetCurrent() + 2.0

        // The new active speaker is a remote (the local participant is never selected
        // as active speaker). If it has not delivered a live camera frame, show its
        // avatar placeholder in the primary slot so the previous speaker's frame does
        // not freeze there. (Skipped in grid mode, which renders by identity.)
        os_unfair_lock_lock(&_stateLock)
        let localId = _localParticipantIdentity
        os_unfair_lock_unlock(&_stateLock)
        if !_useGridLayout, participantId != localId,
           InterRecordingLayoutLogic.needsPlaceholder(identity: participantId,
                                                      identitiesWithLiveFrame: _identitiesWithLiveFrame),
           let renderer = composedRenderer {
            let placeholder = renderer.placeholderFrame(forIdentity: participantId).takeUnretainedValue()
            renderer.updateActiveSpeakerFrame(placeholder, identity: participantId)
        }

        // After switching, check whether a valid secondary speaker still exists.
        // _recentSpeakers was already updated by _handleActiveSpeakerChange before
        // this method is called, so the new secondary is deterministic.
        let newSecondaryId = _recentSpeakers.first(where: { $0 != participantId })
        if newSecondaryId == nil {
            // No valid secondary — clear the renderer's buffer so a stale frame
            // from a prior secondary doesn't persist as a frozen duplicate.
            composedRenderer?.updateSecondarySpeakerFrame(nil, identity: nil)
        }

        interLogDebug(InterRecordingCoordinator.log,
                      "Recording: active speaker → %{private}@", participantId)
    }

    // -----------------------------------------------------------------------
    // MARK: - Output URL Generation
    // -----------------------------------------------------------------------

    private static func generateOutputURL() -> URL {
        let recordingsDir = Self.recordingsDirectory()

        // Create directory if needed
        try? FileManager.default.createDirectory(at: recordingsDir,
                                                  withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let timestamp = formatter.string(from: Date())
        let filename = "Inter Recording \(timestamp).mp4"

        return recordingsDir.appendingPathComponent(filename)
    }

    /// UserDefaults key for the user-chosen recordings folder (Settings →
    /// Recording). Unset/invalid → ~/Documents/Inter Recordings.
    @objc public static let recordingsDirectoryDefaultsKey = "InterRecordingDirectoryPath"

    /// The folder local recordings are written to — the user's choice when it
    /// exists (or can be created), else the default.
    @objc public static func recordingsDirectory() -> URL {
        if let custom = UserDefaults.standard.string(forKey: recordingsDirectoryDefaultsKey),
           !custom.isEmpty {
            let url = URL(fileURLWithPath: custom, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url
            }
            if (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil {
                return url
            }
            // Fall through to the default when the stored path is unusable.
        }
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsURL.appendingPathComponent("Inter Recordings", isDirectory: true)
    }

    // -----------------------------------------------------------------------
    // MARK: - Cloud Recording (Phase 10C)
    // -----------------------------------------------------------------------

    /// Track the active cloud egress ID so we can poll/stop/display status.
    private var _cloudEgressId: String?
    private var _cloudRecordingSessionId: String?

    /// Thread-safe accessor for the active cloud egress ID.
    @objc public var cloudEgressId: String? {
        os_unfair_lock_lock(&_stateLock)
        let id = _cloudEgressId
        os_unfair_lock_unlock(&_stateLock)
        return id
    }

    /// Thread-safe accessor for the active cloud recording session ID.
    @objc public var cloudRecordingSessionId: String? {
        os_unfair_lock_lock(&_stateLock)
        let id = _cloudRecordingSessionId
        os_unfair_lock_unlock(&_stateLock)
        return id
    }

    /// Start a cloud (Egress-based) recording via the token server.
    ///
    /// Calls `POST /room/record/start` on the token server.
    /// The actual recording is handled server-side by LiveKit Egress —
    /// this client only tracks its state.
    ///
    /// - Parameters:
    ///   - serverURL: Base URL of the token server (e.g. "http://localhost:3000").
    ///   - roomCode: The 6-character room code.
    ///   - callerIdentity: The identity of the user initiating the recording.
    ///   - estimatedDurationMinutes: Expected recording duration for quota checks.
    ///   - mode: Recording mode — "cloud_composed" (default) or "multi_track".
    ///   - completion: Called on the main queue with (egressId, sessionId, error).
    @objc public func startCloudRecording(
        serverURL: String,
        roomCode: String,
        callerIdentity: String,
        estimatedDurationMinutes: Int = 60,
        mode: String = "cloud_composed",
        completion: @escaping (String?, String?, NSError?) -> Void
    ) {
        let body: [String: Any] = [
            "roomCode": roomCode,
            "callerIdentity": callerIdentity,
            "mode": mode,
            "estimatedDurationMinutes": estimatedDurationMinutes
        ]

        interLogInfo(InterRecordingCoordinator.log, "Cloud recording: starting (code=***, mode=%{public}@)", mode)

        _performTokenServerRequest(
            url: "\(serverURL)/room/record/start",
            body: body
        ) { [weak self] result in
            switch result {
            case .success(let json):
                guard let egressId = json["egressId"] as? String,
                      let sessionId = json["recordingSessionId"] as? String else {
                    let error = NSError(domain: "InterRecording", code: -1,
                                        userInfo: [NSLocalizedDescriptionKey: "Malformed response from /room/record/start"])
                    interLogError(InterRecordingCoordinator.log, "Cloud recording: malformed start response")
                    DispatchQueue.main.async { completion(nil, nil, error) }
                    return
                }

                // Track egress state
                if let self = self {
                    os_unfair_lock_lock(&self._stateLock)
                    self._cloudEgressId = egressId
                    self._cloudRecordingSessionId = sessionId
                    os_unfair_lock_unlock(&self._stateLock)
                }

                // Notify consent via DataChannel
                self?.chatController?.broadcastRecordingSignal(type: .recordingStarted)

                interLogInfo(InterRecordingCoordinator.log, "Cloud recording: started (egress=%{public}@)", egressId)
                DispatchQueue.main.async { completion(egressId, sessionId, nil) }

            case .failure(let error):
                interLogError(InterRecordingCoordinator.log, "Cloud recording: start failed — %{public}@", error.localizedDescription)
                DispatchQueue.main.async { completion(nil, nil, error) }
            }
        }
    }

    /// Stop a cloud (Egress-based) recording via the token server.
    ///
    /// Calls `POST /room/record/stop` on the token server.
    ///
    /// - Parameters:
    ///   - serverURL: Base URL of the token server.
    ///   - roomCode: The 6-character room code.
    ///   - callerIdentity: The identity of the user stopping the recording.
    ///   - egressId: The egress ID returned from `startCloudRecording`.
    ///   - completion: Called on the main queue with (success, error).
    @objc public func stopCloudRecording(
        serverURL: String,
        roomCode: String,
        callerIdentity: String,
        egressId: String,
        completion: @escaping (Bool, NSError?) -> Void
    ) {
        let body: [String: Any] = [
            "roomCode": roomCode,
            "callerIdentity": callerIdentity,
            "egressId": egressId
        ]

        interLogInfo(InterRecordingCoordinator.log, "Cloud recording: stopping (egress=%{public}@)", egressId)

        _performTokenServerRequest(
            url: "\(serverURL)/room/record/stop",
            body: body
        ) { [weak self] result in
            switch result {
            case .success:
                // Clear egress state
                if let self = self {
                    os_unfair_lock_lock(&self._stateLock)
                    self._cloudEgressId = nil
                    self._cloudRecordingSessionId = nil
                    os_unfair_lock_unlock(&self._stateLock)
                }

                // Notify consent via DataChannel
                self?.chatController?.broadcastRecordingSignal(type: .recordingStopped)

                interLogInfo(InterRecordingCoordinator.log, "Cloud recording: stop initiated")
                DispatchQueue.main.async { completion(true, nil) }

            case .failure(let error):
                interLogError(InterRecordingCoordinator.log, "Cloud recording: stop failed — %{public}@", error.localizedDescription)
                DispatchQueue.main.async { completion(false, error) }
            }
        }
    }

    /// Query the recording status for a room.
    ///
    /// Calls `GET /room/record/status/:code` on the token server.
    ///
    /// - Parameters:
    ///   - serverURL: Base URL of the token server.
    ///   - roomCode: The 6-character room code.
    ///   - completion: Called on the main queue with (isRecording, egressId, mode, error).
    @objc public func queryCloudRecordingStatus(
        serverURL: String,
        roomCode: String,
        completion: @escaping (Bool, String?, String?, NSError?) -> Void
    ) {
        guard let url = URL(string: "\(serverURL)/room/record/status/\(roomCode)") else {
            let error = NSError(domain: "InterRecording", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "Invalid server URL"])
            DispatchQueue.main.async { completion(false, nil, nil, error) }
            return
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        let session = URLSession(configuration: config)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            self?.inflightLock.lock()
            self?.inflightSessions.removeAll { $0 === session }
            self?.inflightLock.unlock()

            if let error = error {
                let nsError = error as NSError
                DispatchQueue.main.async { completion(false, nil, nil, nsError) }
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { completion(false, nil, nil, nil) }
                return
            }

            let isRecording = json["recording"] as? Bool ?? false
            let egressId = json["egressId"] as? String
            let mode = json["mode"] as? String

            DispatchQueue.main.async { completion(isRecording, egressId, mode, nil) }
        }

        inflightLock.lock()
        inflightSessions.append(session)
        inflightLock.unlock()
        task.resume()
    }

    // MARK: - Private: Token Server HTTP (Cloud Recording)

    /// Perform a POST request to the token server for cloud recording operations.
    /// Parses the JSON response and returns it via the completion handler.
    private func _performTokenServerRequest(
        url urlString: String,
        body: [String: Any],
        completion: @escaping (Result<[String: Any], NSError>) -> Void
    ) {
        guard let url = URL(string: urlString) else {
            let error = NSError(domain: "InterRecording", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "Invalid URL: \(urlString)"])
            completion(.failure(error))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            let nsError = NSError(domain: "InterRecording", code: -2,
                                  userInfo: [NSLocalizedDescriptionKey: "Failed to serialize request body",
                                             NSUnderlyingErrorKey: error])
            completion(.failure(nsError))
            return
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 15.0
        let session = URLSession(configuration: config)

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            self?.inflightLock.lock()
            self?.inflightSessions.removeAll { $0 === session }
            self?.inflightLock.unlock()

            if let error = error {
                let nsError = NSError(domain: "InterRecording", code: -3,
                                      userInfo: [NSLocalizedDescriptionKey: "Network error: \(error.localizedDescription)",
                                                 NSUnderlyingErrorKey: error])
                completion(.failure(nsError))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  let data = data else {
                let nsError = NSError(domain: "InterRecording", code: -4,
                                      userInfo: [NSLocalizedDescriptionKey: "No response from server"])
                completion(.failure(nsError))
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let nsError = NSError(domain: "InterRecording", code: -5,
                                      userInfo: [NSLocalizedDescriptionKey: "Malformed JSON response"])
                completion(.failure(nsError))
                return
            }

            if (200..<300).contains(httpResponse.statusCode) {
                completion(.success(json))
            } else {
                let serverMessage = json["error"] as? String ?? "Server error \(httpResponse.statusCode)"
                let nsError = NSError(domain: "InterRecording", code: httpResponse.statusCode,
                                      userInfo: [NSLocalizedDescriptionKey: serverMessage])
                completion(.failure(nsError))
            }
        }

        inflightLock.lock()
        inflightSessions.append(session)
        inflightLock.unlock()
        task.resume()
    }
}

// MARK: - InterRecordingEngineDelegate

extension InterRecordingCoordinator: InterRecordingEngineDelegate {

    public func recordingEngineDidDropVideoFrame(_ totalDropCount: UInt) {
        interLogDebug(InterRecordingCoordinator.log,
                      "Recording: dropped video frame (total: %lu)", totalDropCount)
    }

    public func recordingEngineDidDropAudioSample(_ totalDropCount: UInt) {
        interLogDebug(InterRecordingCoordinator.log,
                      "Recording: dropped audio sample (total: %lu)", totalDropCount)
    }

    public func recordingEngineDidFailWithError(_ error: any Error) {
        coordinatorQueue.async { [weak self] in
            guard let self = self else { return }
            guard self._state == .recording || self._state == .paused else { return }

            interLogError(InterRecordingCoordinator.log,
                          "Recording: engine failed — %{public}@", error.localizedDescription)

            self.renderTimer?.cancel()
            self.renderTimer = nil
            self.durationTimer?.cancel()
            self.durationTimer = nil
            self.audioCapture.stop()

            if let sink = self.recordingSink {
                self.surfaceShareController?.removeLive(sink)
            }

            self._teardownPipeline()
            self.transitionTo(.failed)

            let delegateRef = self.delegate
            DispatchQueue.main.async {
                delegateRef?.recordingDidComplete(outputURL: nil, error: error)
            }
        }
    }
}

// MARK: - InterComposedRendererDelegate

extension InterRecordingCoordinator: InterComposedRendererDelegate {

    public func composedRenderer(_ renderer: Any, didChange newLayout: InterComposedLayout) {
        let delegateRef = delegate
        DispatchQueue.main.async {
            delegateRef?.recordingLayoutDidChange?(newLayout)
        }
    }
}

// MARK: - InterRemoteTrackRenderer (Phase 10 — recording frame observation)

extension InterRecordingCoordinator: InterRemoteTrackRenderer {

    public func didReceiveRemoteScreenShareFrame(_ pixelBuffer: CVPixelBuffer, fromParticipant participantId: String) {
        // Remote participant's screen share frames arrive here via the subscriber.
        // Forward them to the composed renderer so they appear in the recording.
        // (Local screen share frames come through InterRecordingSink via
        // InterSurfaceShareController instead.)
        guard !participantId.isEmpty else { return }
        let snapshot: (renderer: InterComposedRenderer, shouldAccept: Bool)?
        snapshot = coordinatorQueue.sync {
            guard _state == .recording || _state == .paused,
                  let renderer = composedRenderer else { return nil }
            // Only accept if no active screen share is set (first come) or if
            // this is the currently tracked screen sharer.
            let accept = (_activeScreenShareIdentity == nil ||
                          _activeScreenShareIdentity == participantId)
            return (renderer, accept)
        }
        guard let (renderer, shouldAccept) = snapshot, shouldAccept else { return }
        renderer.updateScreenShareFrame(pixelBuffer)
        // Track the active screen share identity if not yet set.
        if _activeScreenShareIdentity == nil {
            coordinatorQueue.async { [weak self] in
                guard let self = self, self._activeScreenShareIdentity == nil else { return }
                self._activeScreenShareIdentity = participantId
            }
        }
    }

    public func remoteTrackDidMute(_ kind: InterTrackKind, forParticipant participantId: String) {
        if kind == .camera {
            participantCameraDidChange(participantId, isMuted: true)
        }
    }

    public func remoteTrackDidUnmute(_ kind: InterTrackKind, forParticipant participantId: String) {
        if kind == .camera {
            participantCameraDidChange(participantId, isMuted: false)
        }
    }

    public func remoteTrackDidEnd(_ kind: InterTrackKind, forParticipant participantId: String) {
        if kind == .camera {
            // A camera track ending (unpublish / mute) is NOT a participant leaving.
            // Forget the live-frame marker and show the avatar placeholder so the slot
            // or grid tile reverts to a placeholder instead of freezing on the last
            // frame. Real removal happens only via remoteParticipantDidLeave.
            coordinatorQueue.async { [weak self] in
                self?._identitiesWithLiveFrame.remove(participantId)
            }
            participantCameraDidChange(participantId, isMuted: true)
        }
    }

    public func remoteParticipantDidJoin(_ participantId: String, displayName: String) {
        // Feed presence into the coordinator so grid/gallery mode engages for 3+
        // participants and audio-only participants get placeholder tiles.
        participantDidJoin(participantId)
    }

    public func remoteParticipantDidLeave(_ participantId: String) {
        coordinatorQueue.async { [weak self] in
            self?._identitiesWithLiveFrame.remove(participantId)
        }
        participantDidLeave(participantId)
    }
}

// Note: InterleaveBuffer, AudioRecordingRingBuffer, and the audio tap/_convertFloatsToCMSampleBuffer
// have been extracted to InterRecordingAudioCapture.swift as part of Gap #14 refactoring.

// MARK: - Audio Engine Access Helper

/// Singleton AudioEngineObserver that captures the live AVAudioEngine via LiveKit callbacks.
///
/// LiveKit's AudioManager does not expose the AVAudioEngine directly. Instead, it drives an
/// AudioEngineObserver chain whose callbacks each receive the real engine instance. This class
/// inserts itself as the first link of that chain (forwarding every call to the default mixer
/// observer) so it can stash a weak reference to the engine for tap installation.
///
/// IMPORTANT: `InterAudioEngineAccess.register()` must be called once at app startup —
/// before any room connects — so that `engineWillStart` fires and the engine ref is captured.
final class InterAudioEngineAccess: NSObject, AudioEngineObserver {

    // MARK: - Singleton

    static let shared = InterAudioEngineAccess()
    private override init() { super.init() }

    // MARK: - AudioEngineObserver chain

    /// Next observer in the chain; set to AudioManager.shared.mixer by register().
    var next: (any AudioEngineObserver)?

    // Weakly stored engine — non-nil while LiveKit's AVAudioEngine is running.
    // AudioEngineObserver docs say "Do not retain the engine object", hence weak.
    private weak var _engine: AVAudioEngine?

    // MARK: - Public API

    /// Register as head of the AudioManager engine-observer chain.
    /// Must be called once at app startup before any room connection.
    @objc static func register() {
        shared.next = AudioManager.shared.mixer
        AudioManager.shared.set(engineObservers: [shared])
    }

    /// Returns the main mixer node of LiveKit's running AVAudioEngine, or nil if unavailable.
    ///
    /// `AVAudioEngine.mainMixerNode` (an `AVAudioMixerNode`) is the correct tapping point:
    /// it combines all connected sources (local mic, remote participants routed through
    /// LiveKit's graph) and feeds into the hardware output node.  `installTap(onBus:)` is
    /// only supported on mixer/input nodes — calling it on `engine.outputNode`
    /// (`AVAudioOutputNode`) throws "required condition is false: _isInput".
    @objc static func outputNode() -> AVAudioMixerNode? {
        guard AudioManager.shared.isEngineRunning, let engine = shared._engine else { return nil }
        return engine.mainMixerNode
    }

    /// [Gap #6] Optional closure invoked when the AVAudioEngine restarts
    /// (engineDidStop followed by engineWillStart). The recording coordinator
    /// sets this during recording so it can re-install the audio tap.
    var onEngineRestart: (() -> Void)?

    /// Whether we saw an engine stop without a subsequent start yet.
    private var _awaitingRestart = false

    // MARK: - Speaker mute (local remote-audio playout)

    /// When true, the engine's output mixer is muted so the local user hears no
    /// remote audio — WITHOUT muting the mic, changing OS volume, or affecting the
    /// recording (which taps remote audio PRE-mix via renderPreProcessing). Mirrors
    /// the Android SDK's `setSpeakerMute` semantics (data is still received).
    private var _speakerMuted = false

    @objc static var isSpeakerMuted: Bool { shared._speakerMuted }

    /// Toggle local remote-audio playout. Routes through LiveKit's MixerEngineObserver
    /// (`AudioManager.shared.mixer.outputVolume`) — the SUPPORTED, thread-safe way to
    /// set the engine output level: it is lock-guarded, nil-safe, and LiveKit stores the
    /// value and RE-APPLIES it on every engine (re)start internally (so it survives
    /// device-route changes and reconnects with no work from us).
    ///
    /// Do NOT poke `engine.mainMixerNode.outputVolume` directly: LiveKit's mixer owns
    /// that node and overwrites it, and racing it from the audio thread during a
    /// device-route change (e.g. unplugging earphones) caused an EXC_BAD_ACCESS crash.
    /// Recording-safe (recording taps remote audio pre-mix) and covers all current +
    /// future participants (single output node).
    @objc static func setSpeakerMuted(_ muted: Bool) {
        shared._speakerMuted = muted
        AudioManager.shared.mixer.outputVolume = muted ? 0.0 : 1.0
    }

    // MARK: - AudioEngineObserver (only the lifecycle callbacks that need engine capture)

    func engineWillStart(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        _engine = engine

        // [Audio quality] Voice-Processing AGC stays DISABLED. A/B test (build "sdtzv5",
        // AGC ON) was worse on BOTH axes: AGC drove speech to ~-15 dBFS with peaks at
        // full scale (harsh / over-amplified, and it re-loudens the room AC between
        // words), and it did NOT fix the "ruk-ruk" choppiness (~15% speech holes vs ~13%
        // with AGC off). Conclusion: the choppiness is noise-suppression / VAD gating of
        // low-level mic input — a separate lever from AGC — so AGC stays off (constant
        // gain, quieter but natural level). Applied here because the audio device module
        // is guaranteed ready once the engine is starting.
        AudioManager.shared.isVoiceProcessingAGCEnabled = false

        // [Gap #6] If this start follows a stop, notify the coordinator to re-install the tap.
        if _awaitingRestart {
            _awaitingRestart = false
            onEngineRestart?()
        }
        return next?.engineWillStart(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
    }

    func engineDidStop(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        _engine = nil
        // [Gap #6] Mark that a restart is needed if onEngineRestart is set.
        if onEngineRestart != nil {
            _awaitingRestart = true
        }
        return next?.engineDidStop(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
    }

    func engineWillRelease(_ engine: AVAudioEngine) -> Int {
        _engine = nil
        return next?.engineWillRelease(engine) ?? 0
    }
}

// Opt-out of strict Sendable checking: _engine is only written on the LiveKit audio thread
// via the observer callbacks, which LiveKit serialises internally.
extension InterAudioEngineAccess: @unchecked Sendable {}
