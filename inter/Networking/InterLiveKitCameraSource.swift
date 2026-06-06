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
        // Preserve a pre-muted state set by preMute() before start() was called.
        // If not pre-muted, set .active so captureOutput forwards frames normally.
        if cameraState != .muted {
            cameraState = .active
        }
        // NOTE: track.mute() for the startMuted path is handled by the publisher
        // (InterLiveKitPublisher.publishCamera) which calls it sequentially before
        // participant.publish(), guaranteeing the SFU sees isMuted=true from the start.
        // A racing Task here was removed because it had no ordering guarantee relative
        // to the publish Task and was called on an unpublished track.
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

    /// Pre-mute: put the source into .muted state before start() is called.
    /// Used when publishing a camera track that must be silenced from frame 0
    /// (e.g. cameraOffOnJoin) to prevent any frames escaping during the async
    /// publish → muteCameraTrack window. Safe to call before start().
    @objc public func preMute() {
        cameraState = .muted
    }

    /// Begin muting: mute the LiveKit track first, then caller stops the capture device.
    @objc public func beginMute(completion: @escaping () -> Void) {
        // Idempotent: already muted — just call completion so the caller can stop the device.
        if cameraState == .muted {
            DispatchQueue.main.async { completion() }
            return
        }

        // If a G2 enable is pending (waiting for first frame to auto-unmute), cancel it
        // and mute immediately. This handles the case where the user turns camera off
        // before the first frame arrives after an enable call.
        if cameraState == .enabling {
            pendingUnmuteCallback = nil
            cameraState = .muted
            if let track = videoTrack {
                Task {
                    try? await track.mute()
                    interLogInfo(InterLog.media, "CameraSource: track muted (cancelled enable)")
                    DispatchQueue.main.async { completion() }
                }
            } else {
                DispatchQueue.main.async { completion() }
            }
            return
        }

        guard let nextState = cameraState.nextState(for: .beginMute) else {
            // Unexpected state (e.g. .muting — another mute is already in flight).
            // Call completion so the caller's device-stop is not orphaned, preventing a
            // button freeze. The in-flight mute will still complete; the second
            // setCameraEnabled:NO call is idempotent.
            interLogError(InterLog.media,
                          "CameraSource: unexpected mute transition from %{public}@ — calling completion to prevent freeze",
                          String(describing: cameraState))
            DispatchQueue.main.async { completion() }
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
        // If already active, the track is already unmuted and publishing — no action needed.
        // This happens when twoPhaseToggleCamera is called while cameraSource.cameraState is
        // still .active (e.g. publishCameraWithCaptureSession: sets cameraSource synchronously
        // with the initial .active state before the async start() has a chance to run).
        if cameraState == .active { return }

        // If already enabling (waiting for first frame), a pendingUnmuteCallback is already
        // set. Don't override it — the existing callback fires on the first frame.
        if cameraState == .enabling { return }

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

        // [G2] Drop frames silently when muted — no data should reach the network.
        guard cameraState != .muted && cameraState != .muting else {
            framesDropped += 1
            return
        }

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
