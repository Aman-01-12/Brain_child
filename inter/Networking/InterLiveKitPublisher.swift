// ============================================================================
// InterLiveKitPublisher.swift
// inter
//
// Phase 1.7 — Orchestrates publishing local media tracks to the LiveKit room.
//
// Owns and manages:
//   • InterLiveKitCameraSource (camera video → network)
//   • InterLiveKitAudioBridge (mic audio → network)
//   • InterLiveKitScreenShareSource (screen share → network)
//
// ISOLATION INVARIANT [G8]:
// Publishing failures are caught and logged. If any publish fails, the
// local media pipeline continues unaffected. The caller receives an error
// via completion block but the app never crashes.
//
// THREADING:
// All public methods must be called on the main queue unless otherwise noted.
// Track publish/unpublish operations use async/await internally.
// ============================================================================

import Foundation
import AVFoundation
import os.log
import LiveKit

// MARK: - InterLiveKitPublisher

@objc public class InterLiveKitPublisher: NSObject {

    // MARK: - Public Properties

    /// Reference to the room's local participant (set externally by InterRoomController).
    public weak var localParticipant: LocalParticipant?

    // MARK: - Track Publications

    /// Published camera track publication.
    public private(set) var cameraPublication: LocalTrackPublication?

    /// Published microphone track publication.
    public private(set) var microphonePublication: LocalTrackPublication?

    /// Published screen share track publication.
    public private(set) var screenSharePublication: LocalTrackPublication?

    // MARK: - Sources

    /// Camera video source. Non-nil while camera is published.
    public private(set) var cameraSource: InterLiveKitCameraSource?

    /// Audio bridge (mic). Non-nil while mic is published.
    public private(set) var audioBridge: InterLiveKitAudioBridge?

    /// Screen share source. Created on demand via factory.
    public private(set) var screenShareSource: InterLiveKitScreenShareSource?

    // MARK: - G2 State Machines

    /// Camera two-phase mute/unmute state.
    private var cameraNetworkState: InterCameraNetworkState = .active

    /// Microphone two-phase mute/unmute state.
    private var micNetworkState: InterMicrophoneNetworkState = .active

    // MARK: - Camera Publishing

    /// Publish the camera video track.
    ///
    /// Creates an `InterLiveKitCameraSource`, attaches it to the capture session,
    /// and publishes to the room.
    ///
    /// - Parameters:
    ///   - captureSession: The existing AVCaptureSession from InterLocalMediaController.
    ///   - sessionQueue: The serial queue protecting the capture session.
    ///   - completion: Called on main queue with optional error.
    @objc public func publishCamera(
        captureSession: AVCaptureSession,
        sessionQueue: DispatchQueue,
        completion: ((NSError?) -> Void)? = nil
    ) {
        guard let participant = localParticipant else {
            let error = InterNetworkErrorCode.publishFailed.error(message: "No local participant")
            interLogError(InterLog.media, "Publisher: cannot publish camera — no participant")
            completion?(error)
            return
        }

        interLogInfo(InterLog.media, "Publisher: publishing camera")

        // Create and start camera source on the session queue
        let source = InterLiveKitCameraSource()
        self.cameraSource = source

        sessionQueue.async {
            source.start(captureSession: captureSession, sessionQueue: sessionQueue)

            guard let track = source.videoTrack else {
                let error = InterNetworkErrorCode.publishFailed.error(message: "Camera track creation failed")
                interLogError(InterLog.media, "Publisher: camera track is nil after start")
                DispatchQueue.main.async { completion?(error) }
                return
            }

            // Publish with H.264, 720p simulcast
            let options = VideoPublishOptions(
                encoding: VideoEncoding(maxBitrate: 1_500_000, maxFps: 30),
                simulcast: true,
                preferredCodec: .h264
            )

            Task {
                do {
                    let pub = try await participant.publish(videoTrack: track, options: options)
                    self.cameraPublication = pub
                    self.cameraNetworkState = .active
                    interLogInfo(InterLog.media, "Publisher: camera published")
                    DispatchQueue.main.async { completion?(nil) }
                } catch {
                    interLogError(InterLog.media, "Publisher: camera publish failed: %{public}@",
                                  error.localizedDescription)
                    let nsError = InterNetworkErrorCode.publishFailed.error(
                        message: "Camera publish failed",
                        underlyingError: error
                    )
                    DispatchQueue.main.async { completion?(nsError) }
                }
            }
        }
    }

    /// Unpublish and tear down the camera track.
    @objc public func unpublishCamera(
        captureSession: AVCaptureSession,
        sessionQueue: DispatchQueue,
        completion: (() -> Void)? = nil
    ) {
        interLogInfo(InterLog.media, "Publisher: unpublishing camera")

        // Unpublish from LiveKit
        if let pub = cameraPublication, let participant = localParticipant {
            Task {
                do {
                    try await participant.unpublish(publication: pub)
                } catch {
                    interLogError(InterLog.media, "Publisher: camera unpublish error: %{public}@",
                                  error.localizedDescription)
                }
            }
        }
        cameraPublication = nil

        // Stop and remove the video output
        if let source = cameraSource {
            sessionQueue.async {
                source.stop(captureSession: captureSession, sessionQueue: sessionQueue)
                DispatchQueue.main.async {
                    self.cameraSource = nil
                    completion?()
                }
            }
        } else {
            completion?()
        }
    }

    // MARK: - Microphone Publishing

    /// Publish the microphone audio track.
    ///
    /// Creates an `InterLiveKitAudioBridge` and publishes to the room.
    @objc public func publishMicrophone(completion: ((NSError?) -> Void)? = nil) {
        guard let participant = localParticipant else {
            let error = InterNetworkErrorCode.publishFailed.error(message: "No local participant")
            interLogError(InterLog.media, "Publisher: cannot publish mic — no participant")
            completion?(error)
            return
        }

        interLogInfo(InterLog.media, "Publisher: publishing microphone")

        let bridge = InterLiveKitAudioBridge()
        self.audioBridge = bridge

        let config = InterShareSessionConfiguration.default()
        bridge.start(with: config) { [weak self] active, statusText in
            guard active, let track = bridge.audioTrack else {
                let error = InterNetworkErrorCode.publishFailed.error(
                    message: "Audio bridge start failed: \(statusText ?? "unknown")"
                )
                interLogError(InterLog.media, "Publisher: mic bridge start failed")
                completion?(error)
                return
            }

            let options = AudioPublishOptions(
                encoding: .presetSpeech,
                dtx: true,
                red: true
            )

            Task {
                do {
                    let pub = try await participant.publish(audioTrack: track, options: options)
                    self?.microphonePublication = pub
                    self?.micNetworkState = .active
                    interLogInfo(InterLog.media, "Publisher: microphone published")
                    DispatchQueue.main.async { completion?(nil) }
                } catch {
                    interLogError(InterLog.media, "Publisher: mic publish failed: %{public}@",
                                  error.localizedDescription)
                    let nsError = InterNetworkErrorCode.publishFailed.error(
                        message: "Microphone publish failed",
                        underlyingError: error
                    )
                    DispatchQueue.main.async { completion?(nsError) }
                }
            }
        }
    }

    /// Unpublish and tear down the microphone track.
    @objc public func unpublishMicrophone(completion: (() -> Void)? = nil) {
        interLogInfo(InterLog.media, "Publisher: unpublishing microphone")

        if let pub = microphonePublication, let participant = localParticipant {
            Task {
                do {
                    try await participant.unpublish(publication: pub)
                } catch {
                    interLogError(InterLog.media, "Publisher: mic unpublish error: %{public}@",
                                  error.localizedDescription)
                }
            }
        }
        microphonePublication = nil

        audioBridge?.stop(completion: { [weak self] in
            self?.audioBridge = nil
            completion?()
        })
    }

    // MARK: - Screen Share

    /// Factory: create and return a screen share sink for the router pipeline.
    /// The caller adds it to InterSurfaceShareController.networkPublishSink.
    @objc public func createScreenShareSink() -> InterLiveKitScreenShareSource {
        let source = InterLiveKitScreenShareSource()
        self.screenShareSource = source
        interLogInfo(InterLog.media, "Publisher: screen share sink created")
        return source
    }

    /// Publish the screen share track (after the source has received at least one frame).
    @objc public func publishScreenShare(completion: ((NSError?) -> Void)? = nil) {
        guard let participant = localParticipant else {
            let error = InterNetworkErrorCode.publishFailed.error(message: "No local participant")
            completion?(error)
            return
        }

        guard let source = screenShareSource, let track = source.videoTrack else {
            let error = InterNetworkErrorCode.publishFailed.error(message: "Screen share source not ready")
            completion?(error)
            return
        }

        interLogInfo(InterLog.media, "Publisher: publishing screen share")

        let options = VideoPublishOptions(
            screenShareEncoding: VideoEncoding(maxBitrate: 2_500_000, maxFps: 15),
            simulcast: false,
            preferredCodec: .h264
        )

        Task {
            do {
                let pub = try await participant.publish(videoTrack: track, options: options)
                self.screenSharePublication = pub
                interLogInfo(InterLog.media, "Publisher: screen share published")
                DispatchQueue.main.async { completion?(nil) }
            } catch {
                interLogError(InterLog.media, "Publisher: screen share publish failed: %{public}@",
                              error.localizedDescription)
                let nsError = InterNetworkErrorCode.publishFailed.error(
                    message: "Screen share publish failed",
                    underlyingError: error
                )
                DispatchQueue.main.async { completion?(nsError) }
            }
        }
    }

    /// Unpublish screen share.
    @objc public func unpublishScreenShare(completion: (() -> Void)? = nil) {
        interLogInfo(InterLog.media, "Publisher: unpublishing screen share")

        if let pub = screenSharePublication, let participant = localParticipant {
            Task {
                do {
                    try await participant.unpublish(publication: pub)
                } catch {
                    interLogError(InterLog.media, "Publisher: screen share unpublish error: %{public}@",
                                  error.localizedDescription)
                }
            }
        }
        screenSharePublication = nil

        screenShareSource?.stop(completion: { [weak self] in
            self?.screenShareSource = nil
            completion?()
        })
    }

    // MARK: - G2: Camera Mute/Unmute

    /// Two-phase camera mute. [G2]
    /// 1. Mute LiveKit track first
    /// 2. Then caller stops the capture device
    @objc public func muteCameraTrack(completion: @escaping () -> Void) {
        cameraSource?.beginMute(completion: completion)
    }

    /// Two-phase camera unmute. [G2]
    /// 1. Caller starts capture device first
    /// 2. First real frame → unmute LiveKit track
    @objc public func unmuteCameraTrack() {
        cameraSource?.beginEnable()
    }

    // MARK: - G2: Microphone Mute/Unmute

    /// Two-phase mic mute. [G2]
    @objc public func muteMicrophoneTrack(completion: @escaping () -> Void) {
        audioBridge?.beginMute(completion: completion)
    }

    /// Two-phase mic unmute. [G2]
    @objc public func unmuteMicrophoneTrack() {
        audioBridge?.beginEnable()
    }

    // MARK: - Bulk Operations

    /// Unpublish all tracks. Called on disconnect or mode transition.
    @objc public func unpublishAll(
        captureSession: AVCaptureSession?,
        sessionQueue: DispatchQueue?,
        completion: (() -> Void)? = nil
    ) {
        interLogInfo(InterLog.media, "Publisher: unpublishing all tracks")

        let group = DispatchGroup()

        // Camera
        if cameraPublication != nil, let session = captureSession, let queue = sessionQueue {
            group.enter()
            unpublishCamera(captureSession: session, sessionQueue: queue) {
                group.leave()
            }
        }

        // Microphone
        if microphonePublication != nil {
            group.enter()
            unpublishMicrophone {
                group.leave()
            }
        }

        // Screen share
        if screenSharePublication != nil {
            group.enter()
            unpublishScreenShare {
                group.leave()
            }
        }

        group.notify(queue: .main) {
            interLogInfo(InterLog.media, "Publisher: all tracks unpublished")
            completion?()
        }
    }

    /// [G4] Detach all source references without unpublishing.
    /// Used during mode transition — tracks remain published in the room
    /// but sources will be rebuilt after transition.
    @objc public func detachAllSources() {
        interLogInfo(InterLog.media, "Publisher: detaching all sources (mode transition)")
        cameraSource = nil
        audioBridge = nil
        screenShareSource = nil
    }
}
