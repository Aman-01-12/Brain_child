// ============================================================================
// InterPresenceCoordinator.swift
// inter
//
// PRESENCE MONITORING (provisional, server flag default OFF).
//
// The single owner of the capture source, the Vision detector, the hysteresis
// engine and the reporter — and the SINGLE WRITER of the candidate's indicator
// state while monitoring runs. Reached from exactly ONE guarded call site
// (SecureWindowController -startLocalMediaFlow, behind
// `roomController.activePresenceMonitoringGranted`) and torn down from exactly
// one (-destroySecureWindow). Delete it with the rest of the feature.
// See .agents/tasks/presence-monitoring/REMOVAL.md.
//
// INDICATOR ENCODING, identical in every layer:
//   0 absent / no chip · 1 monitoring on · 2 monitoring off ·
//   3 paused because the camera is off.
// A stale "on" must be impossible, so the coordinator pushes 2 on teardown and
// on an ingest 403/409, and 3 for as long as the camera is muted.
//
// NO automated action of any kind is taken here, and nothing is shown to the
// candidate beyond that chip: §7.3 — the candidate is told at consent what is
// recorded and the indicator shows whether monitoring is active, nothing more.
// ============================================================================

import Foundation
import AVFoundation
import CoreVideo
import os.log

@objc public final class InterPresenceCoordinator: NSObject {

    // MARK: - Indicator states (the 0/1/2/3 encoding)

    @objc public static let indicatorAbsent: Int = 0
    @objc public static let indicatorOn: Int = 1
    @objc public static let indicatorOff: Int = 2
    @objc public static let indicatorPaused: Int = 3

    /// Pushed to `SecureWindowController -setPresenceMonitoringState:`. Always
    /// invoked on the main queue — the chrome bridge is a @MainActor object.
    @objc public var monitoringStateHandler: ((Int) -> Void)?

    /// Reads the live camera-enabled state (the owner hands over a block that
    /// reads `InterLocalMediaController.isCameraEnabled`, which is atomic).
    /// The coordinator never mutes, unmutes or reconfigures anything — it only
    /// asks.
    @objc public var cameraEnabledProvider: (() -> Bool)?

    @objc public private(set) dynamic var isRunning: Bool = false

    // MARK: - Owned parts

    private let captureSource: InterPresenceCaptureSource
    private let detector = InterPresenceDetector()
    private var engine: InterPresenceEventEngine?
    private var reporter: InterPresenceReporter?

    private let thresholds: PresenceThresholds
    private var detectorVersion: String = ""

    /// Serialises every engine access: samples arrive on the capture source's
    /// detect queue and the camera watchdog fires on its own queue.
    private let engineLock = NSLock()

    private var watchdog: DispatchSourceTimer?
    private let watchdogQueue = DispatchQueue(label: "inter.presence.camera", qos: .utility)
    /// Guards the two pieces of state the watchdog and the lifecycle calls share.
    private let stateLock = NSLock()
    private var lastCameraEnabled: Bool = true
    private var lastPushedState: Int = -1

    private weak var captureSession: AVCaptureSession?
    private var sessionQueue: DispatchQueue?

    @objc public init(thresholdsJSON: String) {
        self.thresholds = PresenceThresholds.parse(json: thresholdsJSON)
        self.captureSource = InterPresenceCaptureSource(sampleIntervalMs: thresholds.sampleIntervalMs)
        super.init()
    }

    // MARK: - Start

    /// Begin monitoring. **Must be called on `sessionQueue`** (the queue that
    /// guards the capture session), which is what the one guarded call site in
    /// SecureWindowController does.
    ///
    /// Nothing here authorises anything: the caller has already checked the
    /// server's armed flag and the candidate's recorded consent.
    @objc public func start(captureSession: AVCaptureSession,
                            sessionQueue: DispatchQueue,
                            tokenService: InterTokenService,
                            serverURL: String,
                            roomCode: String,
                            identity: String,
                            multipleFacesEnabled: Bool,
                            detectorVersion: String) {
        guard !isRunning else { return }
        guard !roomCode.isEmpty, !identity.isEmpty, !serverURL.isEmpty else {
            interLogError(InterLog.media, "Presence: missing room context — monitoring not started")
            pushState(InterPresenceCoordinator.indicatorOff)
            return
        }

        self.captureSession = captureSession
        self.sessionQueue = sessionQueue
        self.detectorVersion = detectorVersion

        // multiple_faces suppression happens HERE, at construction: with the
        // server gate off the engine never builds the event, so a suppressed
        // event never exists as an uploadable object.
        engineLock.lock()
        engine = InterPresenceEventEngine(thresholds: thresholds,
                                          multipleFacesEnabled: multipleFacesEnabled)
        engineLock.unlock()

        let reporter = InterPresenceReporter(detectorVersion: detectorVersion) { events, completion in
            tokenService.uploadPresenceEvents(serverURL: serverURL,
                                              roomCode: roomCode,
                                              identity: identity,
                                              events: events) { accepted, status, error in
                completion(accepted, status, error)
            }
        }
        reporter.monitoringOffHandler = { [weak self] in
            // The server withdrew permission. Stop everything and say "off".
            self?.stop(reportingState: InterPresenceCoordinator.indicatorOff)
        }
        engineLock.lock()
        self.reporter = reporter
        engineLock.unlock()

        captureSource.frameHandler = { [weak self] pixelBuffer, timestamp in
            self?.handleFrame(pixelBuffer, at: timestamp)
        }

        // Seed the camera state before the first frame so a candidate who
        // joined with the camera already off is paused, not "on".
        let enabled = cameraEnabledProvider?() ?? true
        stateLock.lock()
        lastCameraEnabled = enabled
        stateLock.unlock()
        captureSource.setCameraState(enabled
            ? InterPresenceCaptureSource.CameraState.active.rawValue
            : InterPresenceCaptureSource.CameraState.muted.rawValue)

        captureSource.start(captureSession: captureSession, sessionQueue: sessionQueue)
        guard captureSource.isCapturing else {
            // The session refused the output. Report monitoring off rather than
            // leave a chip claiming something that is not happening.
            interLogError(InterLog.media, "Presence: capture source did not start — monitoring off")
            engineLock.lock()
            self.engine = nil
            self.reporter = nil
            engineLock.unlock()
            captureSource.frameHandler = nil
            pushState(InterPresenceCoordinator.indicatorOff)
            return
        }

        reporter.start()
        startCameraWatchdog()
        isRunning = true
        pushState(enabled
            ? InterPresenceCoordinator.indicatorOn
            : InterPresenceCoordinator.indicatorPaused)

        interLogInfo(InterLog.media,
                     "Presence: monitoring started (detector %{public}@, multipleFaces=%{public}d)",
                     detectorVersion, multipleFacesEnabled ? 1 : 0)
    }

    // MARK: - Stop

    /// Tear down and report monitoring off. Safe to call from any thread and
    /// safe to call twice.
    @objc public func stop() {
        stop(reportingState: InterPresenceCoordinator.indicatorOff)
    }

    private func stop(reportingState state: Int) {
        guard isRunning else {
            pushState(state)
            return
        }
        isRunning = false

        watchdog?.cancel()
        watchdog = nil

        // Close whatever is still open BEFORE the reporter's final flush, so a
        // long event that was in progress at hang-up is not lost. `engineLock`
        // guards both the engine and the reporter reference, because the frame
        // path and the watchdog reach them from two other queues.
        engineLock.lock()
        let tail = engine?.flush(at: Date().timeIntervalSince1970) ?? []
        let doomedReporter = reporter
        engine = nil
        reporter = nil
        engineLock.unlock()
        if !tail.isEmpty { doomedReporter?.enqueue(tail) }

        captureSource.frameHandler = nil
        if let session = captureSession, let queue = sessionQueue {
            // Removing our own output must happen on the session queue, like
            // every other session mutation in this app.
            queue.async { [captureSource] in
                captureSource.stop(captureSession: session, sessionQueue: queue)
            }
        }
        captureSession = nil
        sessionQueue = nil

        doomedReporter?.stop()

        pushState(state)
        interLogInfo(InterLog.media, "Presence: monitoring stopped")
    }

    // MARK: - Frame path

    /// Runs on the capture source's `.utility` detect queue, synchronously with
    /// the frame. The pixel buffer dies with this call.
    private func handleFrame(_ pixelBuffer: CVPixelBuffer, at timestamp: TimeInterval) {
        let sample = detector.analyse(pixelBuffer: pixelBuffer)
        engineLock.lock()
        let events = engine?.ingest(sample, at: timestamp) ?? []
        let reporter = self.reporter
        engineLock.unlock()
        if !events.isEmpty { reporter?.enqueue(events) }
    }

    // MARK: - Camera watchdog

    /// The camera's on/off state is the one thing the frame path cannot observe:
    /// when the candidate turns the camera off the frames simply stop, and an
    /// open candidate event would hang there unevaluated. A 500 ms tick feeds
    /// the engine an explicit muted sample instead, which is what emits
    /// `camera_disabled` / `camera_enabled` and what discards the other open
    /// candidates — the camera being off is not evidence of anything.
    private func startCameraWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + thresholds.sampleInterval,
                       repeating: thresholds.sampleInterval,
                       leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.tickCamera() }
        watchdog = timer
        timer.resume()
    }

    private func tickCamera() {
        guard isRunning else { return }
        let enabled = cameraEnabledProvider?() ?? true

        stateLock.lock()
        let changed = (enabled != lastCameraEnabled)
        lastCameraEnabled = enabled
        stateLock.unlock()

        if changed {
            captureSource.setCameraState(enabled
                ? InterPresenceCaptureSource.CameraState.active.rawValue
                : InterPresenceCaptureSource.CameraState.muted.rawValue)
        }

        if !enabled {
            // Feed the muted sample so the transition is recorded once and the
            // other candidates are discarded. The frame path feeds the unmuted
            // samples, so `camera_enabled` lands on the first frame back.
            engineLock.lock()
            let events = engine?.ingest(.cameraOff, at: Date().timeIntervalSince1970) ?? []
            let reporter = self.reporter
            engineLock.unlock()
            if !events.isEmpty { reporter?.enqueue(events) }
        }

        pushState(enabled
            ? InterPresenceCoordinator.indicatorOn
            : InterPresenceCoordinator.indicatorPaused)
    }

    // MARK: - Indicator

    /// The ONE place the indicator state is written. Deduplicated so a 2 Hz
    /// watchdog does not re-render the chip, and always hopped to main.
    private func pushState(_ state: Int) {
        stateLock.lock()
        let changed = (state != lastPushedState)
        if changed { lastPushedState = state }
        stateLock.unlock()
        guard changed, let handler = monitoringStateHandler else { return }
        DispatchQueue.main.async { handler(state) }
    }
}
