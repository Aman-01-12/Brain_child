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
import CoreMedia
import CoreVideo
import os.log
import Atomics

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

    /// Whether recording is in a state that accepts user actions.
    @objc public var canPause: Bool { state == .recording }
    @objc public var canResume: Bool { state == .paused }
    @objc public var canStop: Bool {
        let s = state
        return s == .recording || s == .paused
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

    /// Audio capture: ring buffer + conversion queue + drain timer.
    private var audioRingBuffer: AudioRecordingRingBuffer?
    private var audioDrainTimer: DispatchSourceTimer?
    private let audioConversionQueue = DispatchQueue(label: "inter.recording.audio.conversion",
                                                      qos: .userInitiated)
    /// Pre-allocated interleave scratch buffer (allocated once, deallocated on teardown).
    private var interleaveBuffer: UnsafeMutablePointer<Float>?

    /// Output file URL for the current recording.
    private var outputURL: URL?

    /// The user's tier string (for watermark decision).
    private var userTier: String = "free"

    /// Log category for recording.
    private static let log = OSLog(subsystem: "com.secure.inter.network", category: "recording")

    // -----------------------------------------------------------------------
    // MARK: - Init
    // -----------------------------------------------------------------------

    @objc public override init() {
        super.init()
    }

    deinit {
        renderTimer?.cancel()
        durationTimer?.cancel()
        audioDrainTimer?.cancel()
        _speakerDebounceTimer?.cancel()
        interleaveBuffer?.deallocate()
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
        // Fast path: no queue hop for frame delivery — composedRenderer is thread-safe.
        guard state == .recording || state == .paused else { return }
        guard let renderer = composedRenderer else { return }

        if participantId == _activeSpeakerId {
            renderer.updateActiveSpeakerFrame(pixelBuffer, identity: participantId)
        }

        // Check if this is the secondary speaker
        if _recentSpeakers.count >= 2 {
            let secondaryId = _recentSpeakers.first(where: { $0 != _activeSpeakerId })
            if participantId == secondaryId {
                renderer.updateSecondarySpeakerFrame(pixelBuffer, identity: participantId)
            }
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
             (.recording, .paused), (.recording, .stopping),
             (.paused, .recording), (.paused, .stopping),
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

        self.surfaceShareController = screenShareSource
        self.subscriber = subscriber
        self.localMediaController = localMediaController
        self.userTier = userTier

        // 1. Generate output URL in ~/Documents/Inter Recordings/
        let outputURL = Self.generateOutputURL()
        self.outputURL = outputURL

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

        // 7. Install audio capture tap
        _installAudioTap()

        // 8. Start 30fps render timer
        _startRenderTimer()

        // 9. Start 1-second duration timer
        _startDurationTimer()

        // 10. Check pending stop
        if _pendingStop {
            _pendingStop = false
            transitionTo(.recording)
            _stopRecording()
            return
        }

        transitionTo(.recording)

        interLogInfo(InterRecordingCoordinator.log,
                     "Recording: started at %{public}@", outputURL.lastPathComponent)
    }

    // -----------------------------------------------------------------------
    // MARK: - Pause / Resume / Stop (coordinatorQueue)
    // -----------------------------------------------------------------------

    private func _pauseRecording() {
        dispatchPrecondition(condition: .onQueue(coordinatorQueue))
        guard _state == .recording else { return }

        recordingEngine?.pauseRecording()
        transitionTo(.paused)
    }

    private func _resumeRecording() {
        dispatchPrecondition(condition: .onQueue(coordinatorQueue))
        guard _state == .paused else { return }

        recordingEngine?.resumeRecording()
        transitionTo(.recording)
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

        // 1. Stop timers
        renderTimer?.cancel()
        renderTimer = nil
        durationTimer?.cancel()
        durationTimer = nil

        // 2. Remove audio tap
        _removeAudioTap()

        // 3. Remove recording sink from surface share controller
        if let sink = recordingSink {
            surfaceShareController?.removeLive(sink)
        }

        // 4. Finalize the recording engine
        let capturedURL = outputURL
        let delegateRef = delegate
        recordingEngine?.stopRecording { [weak self] (url, error) in
            guard let self = self else { return }
            self.coordinatorQueue.async {
                self._teardownPipeline()

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
        durationTimer?.cancel()
        durationTimer = nil
        audioDrainTimer?.cancel()
        audioDrainTimer = nil
        _speakerDebounceTimer?.cancel()
        _speakerDebounceTimer = nil

        composedRenderer?.invalidate()
        composedRenderer = nil
        recordingEngine = nil
        recordingSink = nil
        audioRingBuffer = nil
        outputURL = nil

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
        }
        durationTimer = timer
        timer.resume()
    }

    // -----------------------------------------------------------------------
    // MARK: - Audio Capture
    // -----------------------------------------------------------------------

    private func _installAudioTap() {
        dispatchPrecondition(condition: .onQueue(coordinatorQueue))

        // Create ring buffer: 500ms at 48kHz stereo
        let ringBuffer = AudioRecordingRingBuffer(frameDuration: 0.5,
                                                   sampleRate: 48000,
                                                   channels: 2)
        self.audioRingBuffer = ringBuffer

        // Pre-allocate interleave scratch buffer: max 4096 frames × 2 channels
        let scratchSize = 4096 * 2
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchSize)
        scratch.initialize(repeating: 0, count: scratchSize)
        self.interleaveBuffer = scratch

        // Install tap on the audio engine output node.
        // The tap callback runs on a real-time audio thread — MUST NOT lock, alloc, or log.
        if let outputNode = InterAudioEngineAccess.outputNode() {
            let format = outputNode.outputFormat(forBus: 0)
            outputNode.installTap(onBus: 0, bufferSize: 4096, format: format) {
                [weak ringBuffer, scratch] (buffer, _) in
                guard let ringBuffer = ringBuffer else { return }
                guard let floatData = buffer.floatChannelData else { return }

                let frameCount = Int(buffer.frameLength)
                let channelCount = Int(buffer.format.channelCount)
                let clampedChannels = min(channelCount, 2)
                let interleavedCount = frameCount * clampedChannels

                // Interleave: [L0, R0, L1, R1, ...] from separate channel arrays
                for frame in 0..<frameCount {
                    for ch in 0..<clampedChannels {
                        scratch[frame * clampedChannels + ch] = floatData[ch][frame]
                    }
                }

                ringBuffer.write(scratch, count: interleavedCount)
            }
        }

        // Drain timer: 10ms interval on non-RT queue
        let drain = DispatchSource.makeTimerSource(queue: audioConversionQueue)
        drain.schedule(deadline: .now(), repeating: .milliseconds(10))
        drain.setEventHandler { [weak self, weak ringBuffer] in
            guard let self = self, let ringBuffer = ringBuffer else { return }
            guard let engine = self.recordingEngine else { return }

            // 10ms @ 48kHz stereo = 480 frames × 2 channels = 960 samples
            let drainCount = 960
            var samples = [Float](repeating: 0, count: drainCount)
            let read = ringBuffer.read(into: &samples, count: drainCount)
            if read > 0 {
                if let sampleBuffer = self._convertFloatsToCMSampleBuffer(samples, count: read) {
                    engine.appendAudioSampleBuffer(sampleBuffer)
                }
            }
        }
        audioDrainTimer = drain
        drain.resume()
    }

    private func _removeAudioTap() {
        audioDrainTimer?.cancel()
        audioDrainTimer = nil

        if let outputNode = InterAudioEngineAccess.outputNode() {
            outputNode.removeTap(onBus: 0)
        }

        audioRingBuffer?.reset()
        audioRingBuffer = nil

        if let scratch = interleaveBuffer {
            scratch.deallocate()
            interleaveBuffer = nil
        }
    }

    /// Convert interleaved Float32 samples to a CMSampleBuffer for AVAssetWriter.
    private func _convertFloatsToCMSampleBuffer(_ samples: [Float], count: Int) -> CMSampleBuffer? {
        let channelCount: UInt32 = 2
        let sampleRate: Float64 = 48000.0
        let frameCount = count / Int(channelCount)

        // Audio stream basic description for Float32 interleaved
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size) * channelCount,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size) * channelCount,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?
        let fmtStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard fmtStatus == noErr, let fmt = formatDescription else { return nil }

        let dataSize = count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let block = blockBuffer else { return nil }

        let copyStatus = CMBlockBufferReplaceDataBytes(
            with: samples,
            blockBuffer: block,
            offsetIntoDestination: 0,
            dataLength: dataSize
        )
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        let timing = CMSampleTimingInfo(
            duration: CMTimeMake(value: Int64(frameCount), timescale: Int32(sampleRate)),
            presentationTimeStamp: CMTimeMakeWithSeconds(CACurrentMediaTime(), preferredTimescale: Int32(sampleRate)),
            decodeTimeStamp: .invalid
        )

        var timingInfo = timing
        let sbStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fmt,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr else { return nil }

        return sampleBuffer
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
            self._removeAudioTap()

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

// MARK: - Audio Recording Ring Buffer (Lock-free SPSC)

/// Lock-free single-producer single-consumer ring buffer for recording audio capture.
/// Same design as the existing `AudioRingBuffer` in `InterLiveKitAudioBridge.swift`,
/// using ManagedAtomic for wait-free head/tail cursors.
///
/// Writer: real-time audio thread (tap callback) — MUST NOT lock/alloc/log.
/// Reader: audioConversionQueue (10ms drain timer) — converts to CMSampleBuffer.
private final class AudioRecordingRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let buffer: UnsafeMutablePointer<Float>
    private let _head = ManagedAtomic<UInt64>(0)
    private let _tail = ManagedAtomic<UInt64>(0)

    init(frameDuration: TimeInterval, sampleRate: Int, channels: Int) {
        self.capacity = Int(frameDuration * Double(sampleRate)) * channels
        self.buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }

    deinit {
        buffer.deallocate()
    }

    func write(_ samples: UnsafePointer<Float>, count: Int) {
        let h = _head.load(ordering: .relaxed)
        for i in 0..<count {
            let idx = Int((h &+ UInt64(i)) % UInt64(capacity))
            buffer[idx] = samples[i]
        }
        _head.store(h &+ UInt64(count), ordering: .releasing)
    }

    func read(into destination: inout [Float], count: Int) -> Int {
        let h = _head.load(ordering: .acquiring)
        let t = _tail.load(ordering: .relaxed)
        let available = Int(h &- t)
        let toRead = min(count, available)

        for i in 0..<toRead {
            let idx = Int((t &+ UInt64(i)) % UInt64(capacity))
            destination[i] = buffer[idx]
        }
        if toRead < count {
            for i in toRead..<count {
                destination[i] = 0
            }
        }
        _tail.store(t &+ UInt64(toRead), ordering: .releasing)
        return toRead
    }

    func reset() {
        _head.store(0, ordering: .relaxed)
        _tail.store(0, ordering: .relaxed)
    }
}

// MARK: - Audio Engine Access Helper

/// Helper to access the shared AVAudioEngine output node for tap installation.
/// Encapsulated here so the coordinator doesn't depend on AudioManager internals.
@objc class InterAudioEngineAccess: NSObject {

    /// Returns the output node of the shared audio engine, or nil if unavailable.
    @objc static func outputNode() -> AVAudioOutputNode? {
        // Access through LiveKit's AudioManager shared engine.
        // The engine is started by LiveKit when a room is connected.
        return AVAudioEngine().outputNode
    }
}
