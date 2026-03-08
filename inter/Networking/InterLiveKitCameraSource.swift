// ============================================================================
// InterLiveKitCameraSource.swift
// inter
//
// Phase 1.5 — Camera video capture → LiveKit network.
//
// ARCHITECTURE (Decision 2 — Add AVCaptureVideoDataOutput):
// An AVCaptureVideoDataOutput is added to the existing AVCaptureSession.
// Each frame's CVPixelBuffer is forwarded to BufferCapturer.capture() with
// zero-copy (only the reference is passed). The existing preview layer and
// any other outputs continue to work unaffected.
//
// ISOLATION INVARIANT [G8]:
// This class never modifies the capture session's input configuration.
// It only adds/removes its own output. All errors are caught and logged.
// If this class fails or is nil, local camera preview and recording are
// unaffected.
//
// THREADING:
// - start/stop must be called on sessionQueue (asserted)
// - captureOutput delegate fires on a dedicated serial queue
// - All LiveKit track operations are async and dispatched internally
// ============================================================================

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import os.log
import LiveKit

// MARK: - InterLiveKitCameraSource

@objc public class InterLiveKitCameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    // MARK: - Public Properties

    /// The local video track published to the LiveKit room. Nil when not started.
    public private(set) var videoTrack: LocalVideoTrack?

    /// The underlying BufferCapturer used to push frames into WebRTC.
    public private(set) var bufferCapturer: BufferCapturer?

    /// Whether this source is actively capturing and forwarding frames.
    @objc public private(set) dynamic var isCapturing: Bool = false

    // MARK: - Private Properties

    /// The AVCaptureVideoDataOutput added to the session. Retained for removal.
    private var videoDataOutput: AVCaptureVideoDataOutput?

    /// Dedicated serial queue for the capture output delegate.
    private let captureOutputQueue = DispatchQueue(
        label: "inter.camera.livekit.encode",
        qos: .userInteractive
    )

    /// [G2] Camera network state machine for two-phase mute/unmute.
    private var cameraState: InterCameraNetworkState = .active

    /// [G2] Callback invoked when the first real frame arrives after re-enable.
    private var pendingUnmuteCallback: (() -> Void)?

    /// Frame counter for diagnostics.
    private(set) var framesSent: UInt64 = 0
    private(set) var framesDropped: UInt64 = 0

    // MARK: - Start

    /// Add a video data output to the capture session and create the LiveKit video track.
    ///
    /// **Must be called on `sessionQueue`** inside a beginConfiguration/commitConfiguration block,
    /// or the caller should wrap it in one.
    ///
    /// - Parameters:
    ///   - captureSession: The existing AVCaptureSession (e.g. from InterLocalMediaController).
    ///   - sessionQueue: The serial dispatch queue protecting the capture session.
    @objc public func start(captureSession: AVCaptureSession, sessionQueue: DispatchQueue) {
        guard !isCapturing else {
            interLogInfo(InterLog.media, "CameraSource: already capturing, ignoring start")
            return
        }

        interLogInfo(InterLog.media, "CameraSource: starting")

        // Create AVCaptureVideoDataOutput
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true

        // Force BGRA pixel format to prevent session format renegotiation [1.5.3]
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        output.setSampleBufferDelegate(self, queue: captureOutputQueue)

        // Add output to session
        captureSession.beginConfiguration()
        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
            videoDataOutput = output
            interLogInfo(InterLog.media, "CameraSource: video data output added to session")
        } else {
            interLogError(InterLog.media, "CameraSource: cannot add video data output to session")
            captureSession.commitConfiguration()
            return
        }
        captureSession.commitConfiguration()

        // Create LiveKit LocalVideoTrack with BufferCapturer
        let track = LocalVideoTrack.createBufferTrack(
            name: "inter-camera",
            source: .camera,
            options: BufferCaptureOptions(),
            reportStatistics: false
        )
        self.videoTrack = track

        // Extract the BufferCapturer for direct frame injection
        if let capturer = track.capturer as? BufferCapturer {
            self.bufferCapturer = capturer
        } else {
            interLogError(InterLog.media, "CameraSource: track capturer is not BufferCapturer")
        }

        isCapturing = true
        cameraState = .active
        framesSent = 0
        framesDropped = 0

        interLogInfo(InterLog.media, "CameraSource: started, track created")
    }

    // MARK: - Stop

    /// Remove the video data output from the capture session and clean up.
    ///
    /// **Must be called on `sessionQueue`**.
    @objc public func stop(captureSession: AVCaptureSession, sessionQueue: DispatchQueue) {
        guard isCapturing else {
            interLogInfo(InterLog.media, "CameraSource: not capturing, ignoring stop")
            return
        }

        interLogInfo(InterLog.media, "CameraSource: stopping (sent=%{public}llu, dropped=%{public}llu)",
                     framesSent, framesDropped)

        isCapturing = false
        cameraState = .muted
        pendingUnmuteCallback = nil

        // Remove output from session
        if let output = videoDataOutput {
            captureSession.beginConfiguration()
            captureSession.removeOutput(output)
            captureSession.commitConfiguration()
            videoDataOutput = nil
        }

        // Clean up track
        videoTrack = nil
        bufferCapturer = nil

        interLogInfo(InterLog.media, "CameraSource: stopped")
    }

    // MARK: - G2: Mute/Unmute State Machine

    /// Begin muting: mute the LiveKit track first, then caller stops the capture device.
    @objc public func beginMute(completion: @escaping () -> Void) {
        guard let nextState = cameraState.nextState(for: .beginMute) else {
            interLogError(InterLog.media, "CameraSource: invalid mute transition from %{public}@",
                          String(describing: cameraState))
            return
        }
        cameraState = nextState

        if let track = videoTrack {
            Task {
                do {
                    try await track.mute()
                    interLogInfo(InterLog.media, "CameraSource: track muted")
                } catch {
                    interLogError(InterLog.media, "CameraSource: mute failed: %{public}@",
                                  error.localizedDescription)
                }
                self.cameraState = .muted
                DispatchQueue.main.async { completion() }
            }
        } else {
            cameraState = .muted
            completion()
        }
    }

    /// Begin enabling: caller starts the capture device first. We unmute on first real frame.
    @objc public func beginEnable() {
        guard let nextState = cameraState.nextState(for: .beginEnable) else {
            interLogError(InterLog.media, "CameraSource: invalid enable transition from %{public}@",
                          String(describing: cameraState))
            return
        }
        cameraState = nextState

        pendingUnmuteCallback = { [weak self] in
            guard let track = self?.videoTrack else { return }
            Task {
                do {
                    try await track.unmute()
                    interLogInfo(InterLog.media, "CameraSource: track unmuted after first frame")
                } catch {
                    interLogError(InterLog.media, "CameraSource: unmute failed: %{public}@",
                                  error.localizedDescription)
                }
            }
        }

        interLogInfo(InterLog.media, "CameraSource: enabling, waiting for first frame")
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard isCapturing, let capturer = bufferCapturer else { return }

        // [G2] If enabling, this is the first real frame — trigger unmute.
        if cameraState == .enabling, let callback = pendingUnmuteCallback {
            pendingUnmuteCallback = nil
            cameraState = .active
            callback()
        }

        // Zero-copy: BufferCapturer.capture() takes CMSampleBuffer directly.
        // The CVPixelBuffer inside is passed by reference to WebRTC.
        capturer.capture(sampleBuffer)
        framesSent += 1
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // [1.5.6] Log dropped frames. Do not panic.
        framesDropped += 1
        // Only log occasionally to avoid spamming
        if framesDropped % 100 == 1 {
            interLogInfo(InterLog.media, "CameraSource: frame dropped (total=%{public}llu)", framesDropped)
        }
    }
}
