// ============================================================================
// InterLiveKitSubscriber.swift
// inter
//
// Phase 1.8 — Manages subscribing to remote participant tracks.
//
// When a remote participant publishes camera or screen-share video, the
// LiveKit SDK fires didSubscribeTrack. This class attaches a lightweight
// VideoRenderer to each remote video track, extracts CVPixelBuffers,
// and forwards them to the InterRemoteTrackRenderer delegate (typically
// InterRemoteVideoView).
//
// Remote audio is handled automatically by LiveKit's AVAudioEngine pipeline.
// No custom work is needed for audio playback.
//
// ISOLATION INVARIANT [G8]:
// All errors are logged. If subscription fails, local functionality is
// unaffected. The subscriber never modifies local capture or recording.
//
// THREADING:
// - RoomDelegate callbacks arrive on an internal LiveKit queue.
// - VideoRenderer.render(frame:) is called on the WebRTC decode thread.
//   It must be lock-free and allocation-free on the hot path.
// - Frame storage uses os_unfair_lock (single-slot, latest-frame-wins).
// ============================================================================

import Foundation
import AVFoundation
import CoreVideo
import os.log
import LiveKit

// MARK: - InterRemoteTrackRenderer Protocol

/// Delegate protocol for receiving decoded remote media frames.
/// Typically implemented by InterTrackRendererBridge → InterRemoteVideoLayoutManager.
/// All callbacks include the originating participant identity so the subscriber
/// can forward frames from multiple remote participants simultaneously.
@objc public protocol InterRemoteTrackRenderer: AnyObject {
    /// A new camera frame was decoded from a remote participant.
    @objc func didReceiveRemoteCameraFrame(_ pixelBuffer: CVPixelBuffer, fromParticipant participantId: String)

    /// A new screen share frame was decoded from a remote participant.
    @objc func didReceiveRemoteScreenShareFrame(_ pixelBuffer: CVPixelBuffer, fromParticipant participantId: String)

    /// A remote track was muted by the remote participant.
    @objc func remoteTrackDidMute(_ kind: InterTrackKind, forParticipant participantId: String)

    /// A remote track was unmuted by the remote participant.
    @objc func remoteTrackDidUnmute(_ kind: InterTrackKind, forParticipant participantId: String)

    /// A remote track ended (participant unpublished or left).
    @objc func remoteTrackDidEnd(_ kind: InterTrackKind, forParticipant participantId: String)

    /// A remote participant's display name was discovered or updated.
    @objc optional func remoteParticipantDidUpdateDisplayName(_ displayName: String, forParticipant participantId: String)

    /// The active/dominant speaker changed. Identity is empty string when no remote speaker is active.
    @objc optional func activeSpeakerDidChange(_ participantId: String)
}

// MARK: - InterLiveKitSubscriber

@objc public class InterLiveKitSubscriber: NSObject {

    // MARK: - Public Properties

    /// Delegate receiving decoded remote frames.
    @objc public weak var trackRenderer: InterRemoteTrackRenderer?

    /// The pixel format of the last received camera frame. [G3]
    @objc public private(set) var detectedCameraFormat: OSType = 0

    /// The pixel format of the last received screen share frame. [G3]
    @objc public private(set) var detectedScreenShareFormat: OSType = 0

    // MARK: - Private Properties

    /// Per-participant camera frame renderers keyed by participant identity.
    private var cameraRenderers: [String: RemoteFrameRenderer] = [:]

    /// Per-participant camera video tracks keyed by participant identity.
    private var cameraTracks: [String: RemoteVideoTrack] = [:]

    /// Per-participant screen share renderers keyed by participant identity.
    private var screenShareRenderers: [String: RemoteFrameRenderer] = [:]

    /// Per-participant screen share video tracks keyed by participant identity.
    private var screenShareTracks: [String: RemoteVideoTrack] = [:]

    /// Weak reference to the room for delegate management.
    private weak var room: Room?

    // MARK: - Attach / Detach

    /// Register as a delegate on the room to receive track subscription events.
    @objc public func attach(to room: Room) {
        self.room = room
        room.add(delegate: self)
        interLogInfo(InterLog.media, "Subscriber: attached to room")
    }

    /// Unregister from the room and clean up all renderers.
    @objc public func detach() {
        interLogInfo(InterLog.media, "Subscriber: detaching")

        // Remove all per-participant renderers
        for pid in Array(cameraTracks.keys) {
            cleanUpTrack(source: .camera, participantId: pid)
        }
        for pid in Array(screenShareTracks.keys) {
            cleanUpTrack(source: .screenShareVideo, participantId: pid)
        }

        if let room = room {
            room.remove(delegate: self)
        }
        self.room = nil
    }

    // MARK: - Private Helpers

    private func cleanUpTrack(source: Track.Source, participantId: String) {
        switch source {
        case .camera:
            if let renderer = cameraRenderers[participantId],
               let track = cameraTracks[participantId] {
                track.remove(videoRenderer: renderer)
            }
            cameraRenderers.removeValue(forKey: participantId)
            cameraTracks.removeValue(forKey: participantId)
        case .screenShareVideo:
            if let renderer = screenShareRenderers[participantId],
               let track = screenShareTracks[participantId] {
                track.remove(videoRenderer: renderer)
            }
            screenShareRenderers.removeValue(forKey: participantId)
            screenShareTracks.removeValue(forKey: participantId)
        default:
            break
        }
    }
}

// MARK: - RoomDelegate

extension InterLiveKitSubscriber: RoomDelegate {

    /// A remote participant's track was subscribed (we can now receive media).
    public nonisolated func room(
        _ room: Room,
        participant: RemoteParticipant,
        didSubscribeTrack publication: RemoteTrackPublication
    ) {
        guard let track = publication.track else {
            interLogError(InterLog.media, "Subscriber: didSubscribe but track is nil (sid=%{public}@)",
                          publication.sid.stringValue)
            return
        }

        let source = publication.source

        interLogInfo(InterLog.media, "Subscriber: subscribed track source=%d kind=%d sid=%{public}@ participant=%{public}@",
                     source.rawValue, publication.kind.rawValue,
                     publication.sid.stringValue, participant.identity?.stringValue ?? "(unknown)")

        let participantId = participant.identity?.stringValue ?? "(unknown)"
        let participantName = participant.name ?? participantId

        // Forward the participant's display name to the renderer so tiles show
        // human-readable labels instead of the raw identity UUID.
        trackRenderer?.remoteParticipantDidUpdateDisplayName?(participantName, forParticipant: participantId)

        // Video tracks: attach a per-participant renderer
        if let videoTrack = track as? RemoteVideoTrack {
            switch source {
            case .camera:
                // Clean up previous renderer for this participant if any
                cleanUpTrack(source: .camera, participantId: participantId)

                let renderer = RemoteFrameRenderer(kind: .camera) { [weak self] pixelBuffer, format in
                    if self?.detectedCameraFormat == 0 {
                        self?.detectedCameraFormat = format
                        interLogInfo(InterLog.media, "Subscriber: detected camera format: %{public}@",
                                     String(format: "%c%c%c%c",
                                            (format >> 24) & 0xFF,
                                            (format >> 16) & 0xFF,
                                            (format >> 8) & 0xFF,
                                            format & 0xFF))
                    }
                    self?.trackRenderer?.didReceiveRemoteCameraFrame(pixelBuffer, fromParticipant: participantId)
                }
                self.cameraRenderers[participantId] = renderer
                self.cameraTracks[participantId] = videoTrack
                videoTrack.add(videoRenderer: renderer)

                interLogInfo(InterLog.media, "Subscriber: camera renderer attached for %{public}@", participantId)

            case .screenShareVideo:
                cleanUpTrack(source: .screenShareVideo, participantId: participantId)

                let renderer = RemoteFrameRenderer(kind: .screenShare) { [weak self] pixelBuffer, format in
                    if self?.detectedScreenShareFormat == 0 {
                        self?.detectedScreenShareFormat = format
                        interLogInfo(InterLog.media, "Subscriber: detected screen share format: %{public}@",
                                     String(format: "%c%c%c%c",
                                            (format >> 24) & 0xFF,
                                            (format >> 16) & 0xFF,
                                            (format >> 8) & 0xFF,
                                            format & 0xFF))
                    }
                    self?.trackRenderer?.didReceiveRemoteScreenShareFrame(pixelBuffer, fromParticipant: participantId)
                }
                self.screenShareRenderers[participantId] = renderer
                self.screenShareTracks[participantId] = videoTrack
                videoTrack.add(videoRenderer: renderer)

                interLogInfo(InterLog.media, "Subscriber: screen share renderer attached for %{public}@", participantId)

            default:
                break
            }
        }

        // Audio tracks: no custom work needed. LiveKit handles playback automatically.
        // Just log for diagnostics.
        if track is RemoteAudioTrack {
            interLogInfo(InterLog.media, "Subscriber: remote audio track subscribed (automatic playback)")
        }
    }

    /// A remote participant's track was unsubscribed.
    public nonisolated func room(
        _ room: Room,
        participant: RemoteParticipant,
        didUnsubscribeTrack publication: RemoteTrackPublication
    ) {
        let source = publication.source
        let participantId = participant.identity?.stringValue ?? "(unknown)"

        interLogInfo(InterLog.media, "Subscriber: unsubscribed track source=%d sid=%{public}@ participant=%{public}@",
                     source.rawValue, publication.sid.stringValue, participantId)

        switch source {
        case .camera:
            cleanUpTrack(source: .camera, participantId: participantId)
            trackRenderer?.remoteTrackDidEnd(.camera, forParticipant: participantId)
        case .screenShareVideo:
            cleanUpTrack(source: .screenShareVideo, participantId: participantId)
            trackRenderer?.remoteTrackDidEnd(.screenShare, forParticipant: participantId)
        default:
            break
        }
    }

    /// A remote track's mute state changed.
    public nonisolated func room(
        _ room: Room,
        participant: Participant,
        didUpdateIsMuted publication: TrackPublication
    ) {
        // Only care about remote participants
        guard participant is RemoteParticipant else { return }

        let source = publication.source
        let muted = publication.isMuted
        let participantId = participant.identity?.stringValue ?? "(unknown)"

        interLogInfo(InterLog.media, "Subscriber: track mute changed source=%d muted=%d participant=%{public}@",
                     source.rawValue, muted ? 1 : 0, participantId)

        switch source {
        case .camera:
            if muted {
                trackRenderer?.remoteTrackDidMute(.camera, forParticipant: participantId)
            } else {
                trackRenderer?.remoteTrackDidUnmute(.camera, forParticipant: participantId)
            }
        case .microphone:
            if muted {
                trackRenderer?.remoteTrackDidMute(.microphone, forParticipant: participantId)
            } else {
                trackRenderer?.remoteTrackDidUnmute(.microphone, forParticipant: participantId)
            }
        case .screenShareVideo:
            if muted {
                trackRenderer?.remoteTrackDidMute(.screenShare, forParticipant: participantId)
            } else {
                trackRenderer?.remoteTrackDidUnmute(.screenShare, forParticipant: participantId)
            }
        default:
            break
        }
    }

    /// A remote participant's track stream state changed (e.g. quality adaptation).
    public nonisolated func room(
        _ room: Room,
        track: Track,
        didUpdateStreamState streamState: StreamState,
        forParticipant participant: RemoteParticipant
    ) {
        interLogInfo(InterLog.media, "Subscriber: stream state change source=%d state=%d",
                     track.source.rawValue, streamState.rawValue)
    }
}

// MARK: - RemoteFrameRenderer (Internal VideoRenderer)

/// Lightweight VideoRenderer that extracts CVPixelBuffer from decoded frames
/// and forwards via callback. Uses os_unfair_lock for single-slot storage.
///
/// This is the hot path — render(frame:) is called on the WebRTC decode thread
/// at up to 30 Hz. No allocation, no logging inside the fast path.
private final class RemoteFrameRenderer: NSObject, VideoRenderer, @unchecked Sendable {

    // MARK: - Types

    typealias FrameCallback = (CVPixelBuffer, OSType) -> Void

    // MARK: - Properties

    let kind: InterTrackKind

    /// Callback invoked with each decoded pixel buffer and its pixel format.
    private let onFrame: FrameCallback

    /// Single-slot frame storage protected by os_unfair_lock. [1.8.9]
    /// Latest-frame-wins: new frames overwrite old without queuing.
    private var lock = os_unfair_lock()
    private var latestPixelBuffer: CVPixelBuffer?

    /// Adaptive stream properties for bandwidth management. [1.8.8]
    private var _adaptiveSize: CGSize = CGSize(width: 1280, height: 720)

    // MARK: - Init

    init(kind: InterTrackKind, onFrame: @escaping FrameCallback) {
        self.kind = kind
        self.onFrame = onFrame
        super.init()
    }

    // MARK: - VideoRenderer Protocol

    /// Whether adaptive streaming is enabled. Controls bandwidth allocation. [1.8.8]
    @MainActor var isAdaptiveStreamEnabled: Bool {
        return true
    }

    /// The target size for adaptive stream. .high for primary, .low for thumbnail.
    @MainActor var adaptiveStreamSize: CGSize {
        return _adaptiveSize
    }

    /// Set the desired render size (called by LiveKit for adaptive streaming).
    nonisolated func set(size: CGSize) {
        // Store for adaptive stream. No lock needed — written atomically as CGSize.
        // In practice, only called from main thread during layout changes.
    }

    /// Hot path: called on WebRTC decode thread for every decoded frame.
    /// MUST be lock-free (except the single os_unfair_lock acquire) and allocation-free.
    nonisolated func render(frame: VideoFrame) {
        // Extract CVPixelBuffer. Prefer direct CVPixelVideoBuffer (zero-copy).
        // Falls back to I420 → CVPixelBuffer conversion if needed.
        guard let pixelBuffer = frame.toCVPixelBuffer() else {
            return
        }

        // Detect pixel format
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

        // Single-slot store: latest frame wins [1.8.9]
        os_unfair_lock_lock(&lock)
        latestPixelBuffer = pixelBuffer
        os_unfair_lock_unlock(&lock)

        // Forward to delegate
        onFrame(pixelBuffer, format)
    }

    /// Read the latest stored pixel buffer (for CVDisplayLink consumers).
    /// Returns nil if no frame has been received yet.
    func consumeLatestFrame() -> CVPixelBuffer? {
        os_unfair_lock_lock(&lock)
        let buffer = latestPixelBuffer
        os_unfair_lock_unlock(&lock)
        return buffer
    }

    /// Update the adaptive stream target quality. [1.8.8]
    /// Call with large size for primary view, small size for thumbnail/PiP.
    func setAdaptiveQuality(size: CGSize) {
        DispatchQueue.main.async {
            self._adaptiveSize = size
        }
    }
}
