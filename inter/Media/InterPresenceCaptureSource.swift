// ============================================================================
// InterPresenceCaptureSource.swift
// inter
//
// PRESENCE MONITORING (provisional, server flag default OFF).
//
// A fourth, read-only owner of an output on the ONE AVCaptureSession, modelled
// on inter/Networking/InterLiveKitCameraSource.swift. Delete it with the rest of
// the feature. See .agents/tasks/presence-monitoring/REMOVAL.md.
//
// ISOLATION INVARIANT — non-negotiable, and asserted in
// interTests/InterPresenceCaptureSourceTests.swift:
//  1. adds exactly ONE AVCaptureVideoDataOutput of its own and removes exactly
//     that one;
//  2. pins `videoSettings` to kCVPixelFormatType_32BGRA so it cannot
//     renegotiate the session format and disturb the preview layer, the LiveKit
//     publisher or the optional recording output;
//  3. NEVER calls startRunning / stopRunning (InterLocalMediaController.h:
//     "Callers MUST NOT call startRunning/stopRunning");
//  4. NEVER calls addInput / removeInput, and never calls
//     beginConfiguration/commitConfiguration for anything but its own output;
//  5. NEVER touches any LiveKit track and never calls mute() / unmute();
//  6. skips all work while the camera state is .muted or .muting, which is also
//     what makes §7.1's "camera unmuted" precondition for face_absent true by
//     construction;
//  7. does NOT co-opt InterLocalMediaController.recordingFrameObserver — that
//     is a single-slot atomic property owned by InterRecordingCoordinator and
//     taking it would break local recording's camera PiP.
//
// Its delegate queue is .utility, deliberately below the publisher's
// .userInteractive, so contention costs the detector and never the call. Frames
// are sampled at 2 Hz; every other frame is dropped before any work happens.
// No frame, crop, thumbnail or buffer is retained, stored or transmitted —
// the pixel buffer is handed to the frame handler synchronously and released.
// ============================================================================

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore
import os.log

@objc public final class InterPresenceCaptureSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    // MARK: - Camera state (mirrors InterCameraNetworkState)

    /// Mirror of `InterCameraNetworkState`
    /// (inter/Networking/InterNetworkTypes.swift:69). Only `.muted` / `.muting`
    /// matter here: both stop all sampling. The ObjC-facing API is
    /// `setCameraState(_: Int)` with these raw values.
    enum CameraState: Int {
        case active = 0
        case muting = 1
        case muted = 2
        case enabling = 3
    }

    // MARK: - Public state

    /// Whether this source currently holds an output on the session.
    @objc public private(set) dynamic var isCapturing: Bool = false

    /// Called on the detector queue with the frame's pixel buffer and the
    /// frame's own timestamp, synchronously, exactly once per sampled frame.
    /// The buffer is valid for the duration of the call and no longer.
    public var frameHandler: ((CVPixelBuffer, TimeInterval) -> Void)?

    // MARK: - Counters (read by the tests)

    private(set) var framesSampled: UInt64 = 0
    private(set) var framesSkippedMuted: UInt64 = 0
    private(set) var framesSkippedThrottle: UInt64 = 0
    private(set) var outputsAdded: Int = 0
    private(set) var outputsRemoved: Int = 0
    /// Always 0. This class never starts or stops the session; the counter
    /// exists so a test can assert the absence rather than trust the comment.
    private(set) var sessionRunCalls: Int = 0

    /// The one output this source owns. `internal` so the test can read back the
    /// pinned `videoSettings`; nothing outside the module can reach it.
    private(set) var videoDataOutput: AVCaptureVideoDataOutput?

    // MARK: - Private

    /// Deliberately BELOW the publisher's `.userInteractive`: if the machine is
    /// short of CPU the detector is what slows down, never the call.
    private let detectQueue = DispatchQueue(label: "inter.presence.detect", qos: .utility)

    private let stateLock = NSLock()
    private var cameraState: CameraState = .active
    private var lastSampleTime: TimeInterval = -.infinity

    /// 2 Hz. Kept as a stored property so the threshold the server handed down
    /// is the one actually enforced.
    private let sampleInterval: TimeInterval

    @objc public init(sampleIntervalMs: Int) {
        self.sampleInterval = sampleIntervalMs > 0 ? TimeInterval(sampleIntervalMs) / 1000.0 : 0.5
        super.init()
    }

    @objc public override convenience init() {
        self.init(sampleIntervalMs: 500)
    }

    // MARK: - The one output

    /// Build this source's output. Factored out so a test can inspect the
    /// pinned format on the real thing: once an output is attached to a session
    /// that has no video connection, AVFoundation reports `videoSettings` back
    /// as nil, so the pin can only be asserted before attachment.
    ///
    /// [invariant 2] Pinning the format is what stops this output renegotiating
    /// the shared session and disturbing the preview layer, the LiveKit
    /// publisher or the optional recording output.
    ///
    /// NOTE: AVFoundation reports `videoSettings` back as nil until the output
    /// has a live video connection, so this dictionary is the only thing a unit
    /// test can assert against. It is the one applied in `makeDetectorOutput()`.
    static let pinnedVideoSettings: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]

    static func makeDetectorOutput() -> AVCaptureVideoDataOutput {
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = InterPresenceCaptureSource.pinnedVideoSettings
        return output
    }

    // MARK: - Start

    /// Add this source's own output to the existing capture session.
    /// **Must be called on `sessionQueue`.**
    @objc public func start(captureSession: AVCaptureSession, sessionQueue: DispatchQueue) {
        guard !isCapturing else {
            interLogInfo(InterLog.media, "Presence: already capturing, ignoring start")
            return
        }

        let output = InterPresenceCaptureSource.makeDetectorOutput()
        output.setSampleBufferDelegate(self, queue: detectQueue)

        // [invariant 1 + 4] Our own output, inside our own configuration block,
        // and nothing else. No addInput, no removeInput, no startRunning.
        captureSession.beginConfiguration()
        guard captureSession.canAddOutput(output) else {
            captureSession.commitConfiguration()
            interLogError(InterLog.media, "Presence: cannot add detector output — monitoring stays off")
            return
        }
        captureSession.addOutput(output)
        captureSession.commitConfiguration()

        videoDataOutput = output
        outputsAdded += 1
        stateLock.lock()
        lastSampleTime = -.infinity
        stateLock.unlock()
        framesSampled = 0
        framesSkippedMuted = 0
        framesSkippedThrottle = 0
        isCapturing = true

        interLogInfo(InterLog.media, "Presence: detector output added (2 Hz, .utility)")
    }

    // MARK: - Stop

    /// Remove this source's own output and nothing else.
    /// **Must be called on `sessionQueue`.**
    @objc public func stop(captureSession: AVCaptureSession, sessionQueue: DispatchQueue) {
        guard isCapturing else { return }

        isCapturing = false
        // Drop the delegate before removing, so no in-flight frame reaches a
        // handler the owner has already torn down (paranoid #8).
        videoDataOutput?.setSampleBufferDelegate(nil, queue: nil)

        if let output = videoDataOutput {
            captureSession.beginConfiguration()
            captureSession.removeOutput(output)
            captureSession.commitConfiguration()
            outputsRemoved += 1
        }
        videoDataOutput = nil
        frameHandler = nil

        interLogInfo(InterLog.media,
                     "Presence: detector output removed (sampled=%{public}llu, muted=%{public}llu, throttled=%{public}llu)",
                     framesSampled, framesSkippedMuted, framesSkippedThrottle)
    }

    // MARK: - Camera discipline

    /// [invariant 6] Mirror of the camera network state. `.muted` / `.muting`
    /// stop all sampling immediately: a muted camera produces no evidence, so
    /// the detector must produce no observations.
    @objc public func setCameraState(_ state: Int) {
        stateLock.lock()
        cameraState = CameraState(rawValue: state) ?? .active
        stateLock.unlock()
    }

    @objc public var isCameraMuted: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cameraState == .muted || cameraState == .muting
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        ingest(sampleBuffer: sampleBuffer)
    }

    /// The frame-ingest core. The delegate callback above is a one-line forward
    /// to this; the tests drive it directly because an `AVCaptureConnection`
    /// cannot be constructed without a live device.
    func ingest(sampleBuffer: CMSampleBuffer) {
        guard isCapturing else { return }

        // [invariant 6] Muted or muting: no work at all, not even a timestamp.
        if isCameraMuted {
            framesSkippedMuted += 1
            return
        }

        // 2 Hz throttle. The frame's own presentation timestamp is the clock
        // when it is usable, so the cadence is the camera's and not the main
        // thread's.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let now = (pts.isValid && pts.isNumeric) ? pts.seconds : CACurrentMediaTime()

        stateLock.lock()
        let elapsed = now - lastSampleTime
        let admit = elapsed >= sampleInterval
        if admit { lastSampleTime = now }
        stateLock.unlock()

        guard admit else {
            framesSkippedThrottle += 1
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            framesSkippedThrottle += 1
            return
        }

        framesSampled += 1
        // Synchronous, by design: the buffer must not outlive this callback.
        // Nothing here retains it, copies it, encodes it or writes it anywhere.
        frameHandler?(pixelBuffer, Date().timeIntervalSince1970)
    }

    public func captureOutput(_ output: AVCaptureOutput,
                              didDrop sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        // A dropped frame costs the detector one sample and nothing else. At
        // 2 Hz against a 30 fps camera this is expected, not an error.
        framesSkippedThrottle += 1
    }
}
