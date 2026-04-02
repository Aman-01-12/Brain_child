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
import Atomics
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

    /// Weak reference to the surface share controller for sink insertion/removal.
    private weak var surfaceShareController: InterSurfaceShareController?

    /// Weak references to subscriber and local media controller for frame observation.
    private weak var subscriber: InterLiveKitSubscriber?
    private weak var localMediaController: InterLocalMediaController?

    /// Local participant identity — captured at recording start for thread-safe access.
    private var _localParticipantIdentity: String?

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
    @objc public func startLocalRecording(
        screenShareSource: InterSurfaceShareController,
        subscriber: InterLiveKitSubscriber,
        localMediaController: InterLocalMediaController,
        userTier: String
    ) {
        coordinatorQueue.async { [weak self] in
            self?._startLocalRecording(
                screenShareSource: screenShareSource,
                subscriber: subscriber,
                localMediaController: localMediaController,
                userTier: userTier
            )
        }
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
                if self._activeSpeakerId == participantId {
                    renderer.updateActiveSpeakerFrame(placeholder, identity: participantId)
                }
            }
            // When camera unmutes, the next frame delivery will naturally update the renderer.
        }
    }

    /// Called when a participant leaves — clears stale frame references.
    @objc public func participantDidLeave(_ participantId: String) {
        coordinatorQueue.async { [weak self] in
            guard let self = self, self._state == .recording || self._state == .paused else { return }

            // Remove from recent speakers
            self._recentSpeakers.removeAll { $0 == participantId }

            // If they were the active speaker, clear the frame
            if self._activeSpeakerId == participantId {
                self._activeSpeakerId = nil
                self.composedRenderer?.updateActiveSpeakerFrame(nil, identity: nil)

                // Promote next recent speaker if available
                if let next = self._recentSpeakers.first {
                    self._handleActiveSpeakerChange(next)
                }
            }
        }
    }

    /// Called when screen share starts/stops mid-recording.
    @objc public func screenShareDidChange(isActive: Bool) {
        coordinatorQueue.async { [weak self] in
            guard let self = self, self._state == .recording || self._state == .paused else { return }

            if isActive {
                // Recording sink will be added when sinks dispatch frames.
                // If sharing is already in progress, addLiveSink handles it.
                if let sink = self.recordingSink {
                    self.surfaceShareController?.addLive(sink)
                }
            } else {
                // Screen share stopped — remove recording sink and clear source
                if let sink = self.recordingSink {
                    self.surfaceShareController?.removeLive(sink)
                }
                self.composedRenderer?.updateScreenShareFrame(nil)
            }
        }
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
        let snapshot: (renderer: InterComposedRenderer, activeId: String?, secondaryId: String?)?
        snapshot = coordinatorQueue.sync {
            guard _state == .recording || _state == .paused,
                  let renderer = composedRenderer else { return nil }
            let activeId = _activeSpeakerId
            let secondaryId: String? = _recentSpeakers.count >= 2
                ? _recentSpeakers.first(where: { $0 != activeId })
                : nil
            return (renderer, activeId, secondaryId)
        }
        guard let (renderer, activeId, secondaryId) = snapshot else { return }

        if participantId == activeId {
            renderer.updateActiveSpeakerFrame(pixelBuffer, identity: participantId)
        }
        if let secId = secondaryId, participantId == secId {
            renderer.updateSecondarySpeakerFrame(pixelBuffer, identity: participantId)
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
        userTier: String
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
        }

        // 7. Wire subscriber's recording frame delegate for remote camera frames
        subscriber.recordingFrameDelegate = self

        // 8. Install local camera frame observer (for when local user is active speaker)
        _installLocalCameraObserver()

        // 9. Install audio capture (extracted subsystem — Gap #14)
        audioCapture.onSampleBuffer = { [weak self] sampleBuffer in
            self?.recordingEngine?.appendAudioSampleBuffer(sampleBuffer)
        }
        audioCapture.start()

        // 10. Start 30fps render timer
        _startRenderTimer()

        // 11. Start 1-second duration timer
        _startDurationTimer()

        // 12. Start disk space monitor (30-second interval)
        _startDiskSpaceMonitor()

        // 11. Check pending stop
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
    }

    /// Remove the recording frame observer from the local media controller.
    private func _removeLocalCameraObserver() {
        localMediaController?.recordingFrameObserver = nil
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

        // Previous speaker becomes secondary (if we have > 1 participant)
        if let prev = previousSpeaker, prev != participantId {
            // The secondary speaker frame will be updated on next frame delivery
            // via didReceiveRemoteCameraFrame
        }

        interLogDebug(InterRecordingCoordinator.log,
                      "Recording: active speaker → %{private}@", participantId)
    }

    // -----------------------------------------------------------------------
    // MARK: - Output URL Generation
    // -----------------------------------------------------------------------

    private static func generateOutputURL() -> URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let recordingsDir = documentsURL.appendingPathComponent("Inter Recordings", isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: recordingsDir,
                                                  withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let timestamp = formatter.string(from: Date())
        let filename = "Inter Recording \(timestamp).mp4"

        return recordingsDir.appendingPathComponent(filename)
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

        let task = session.dataTask(with: request) { data, response, error in
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

        let task = session.dataTask(with: request) { data, response, error in
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
        // Screen share frames come through InterRecordingSink via InterSurfaceShareController,
        // not through the subscriber. This method is intentionally a no-op.
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
            participantDidLeave(participantId)
        }
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

    // MARK: - AudioEngineObserver (only the lifecycle callbacks that need engine capture)

    func engineWillStart(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        _engine = engine
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
