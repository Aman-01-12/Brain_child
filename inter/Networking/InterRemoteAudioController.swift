// ============================================================================
// InterRemoteAudioController.swift
// inter
//
// Single source of truth for remote-audio *playout* policy on the
// `.platformDefault` (WebRTC HAL) ADM:
//   • Speaker-mute: sets `RemoteAudioTrack.volume = 0/1` on every remote audio
//     track (current + future). LiveKit's documented playout mute; applied at the
//     playout mixer, so it silences what the local user hears WITHOUT changing the
//     mic, OS volume, or transmission.
//   • Recording-safe by construction: the local recording taps each remote track
//     PRE-volume (per-track sinks in InterRecordingAudioCapture), so muting playout
//     never reduces the recorded remote audio. (Verified: the post-volume combined
//     tap went silent on mute; per-track sinks do not.)
//
// Coverage is structural via reconcile(), not call-ordering: the desired per-track
// recording-sink set is `recordingActive ? tracks : {}`, diffed idempotently against
// the current set on every relevant event (track sub/unsub, recording start/stop).
// This makes "recording started before/after a join" and "join during recording"
// correct regardless of event order.
//
// THREADING: main-thread confined. RoomDelegate callbacks (subscribe/unsubscribe)
// hop to main before calling here (the subscriber already does). The recording
// coordinator bridge hops to its own coordinatorQueue internally.
//
// ISOLATION [G8]: coordinator ref is weak; a nil at any point degrades to
// "no per-track recording" without crashing; mute state is still tracked.
// ============================================================================

import Foundation
import LiveKit
import os.log

// MARK: - Pure policy (unit-testable without a live room)

/// Side-effect-free decisions for remote-audio playout + recording-sink reconciliation.
enum InterRemoteAudioPolicy {
    /// Playout volume for the speaker-mute state. 0.0 = silent, 1.0 = full.
    static func volume(muted: Bool) -> Double { muted ? 0.0 : 1.0 }

    /// The set of track sids that should have a recording sink right now.
    static func desiredSinks(recordingActive: Bool, trackSids: Set<String>) -> Set<String> {
        recordingActive ? trackSids : []
    }

    /// Idempotent, order-independent diff: which sinks to add / remove to reach `desired`.
    static func sinkDiff(current: Set<String>, desired: Set<String>)
        -> (toAdd: Set<String>, toRemove: Set<String>) {
        (desired.subtracting(current), current.subtracting(desired))
    }
}

// MARK: - Controller

@objc public final class InterRemoteAudioController: NSObject {

    /// Recording bridge: per-track sink add/remove. Weak to honor isolation [G8].
    @objc public weak var recordingCoordinator: InterRecordingCoordinator?

    private var muted = false
    private var recordingActive = false
    /// Live remote audio tracks, keyed by track sid (stable key).
    private var tracks: [String: RemoteAudioTrack] = [:]
    /// Sids that currently have a recording sink installed (mirror of coordinator state).
    private var currentSinks: Set<String> = []

    @objc public override init() { super.init() }

    /// Current effective speaker-mute state.
    @objc public var isSpeakerMuted: Bool { muted }

    // MARK: - Speaker mute (R1, R3)

    @objc public func setSpeakerMuted(_ newMuted: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        muted = newMuted
        let v = InterRemoteAudioPolicy.volume(muted: muted)
        for track in tracks.values { track.volume = v }
        interLogInfo(InterLog.media,
                     "RemoteAudio: speaker mute=%d applied to %d track(s)",
                     muted ? 1 : 0, tracks.count)
    }

    // MARK: - Track lifecycle (R3) — idempotent, sid-keyed

    func registerRemoteAudioTrack(_ track: RemoteAudioTrack, sid: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !sid.isEmpty else { return }
        tracks[sid] = track
        // New/rejoined track honors the current mute state immediately (R3.1/3.2, P3).
        track.volume = InterRemoteAudioPolicy.volume(muted: muted)
        reconcile()
    }

    func unregisterRemoteAudioTrack(sid: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !sid.isEmpty else { return }
        tracks[sid] = nil
        reconcile()
    }

    // MARK: - Recording lifecycle (driven by the coordinator)

    /// Called by the recording coordinator on start (true) / stop (false). Triggers a
    /// reconcile so sinks are added for ALL current tracks on start, removed on stop.
    @objc public func setRecordingActive(_ active: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        recordingActive = active
        reconcile()
    }

    // MARK: - Reconciliation (R2, edge-case coverage)

    /// Bring the recording-sink set in line with desired = recordingActive ? tracks : {}.
    /// Idempotent and order-independent, so any sequence of track/recording events converges.
    private func reconcile() {
        dispatchPrecondition(condition: .onQueue(.main))
        let trackSids = Set(tracks.keys)
        let desired = InterRemoteAudioPolicy.desiredSinks(recordingActive: recordingActive,
                                                          trackSids: trackSids)
        let (toAdd, toRemove) = InterRemoteAudioPolicy.sinkDiff(current: currentSinks, desired: desired)
        guard !toAdd.isEmpty || !toRemove.isEmpty else { return }

        for sid in toRemove {
            recordingCoordinator?.removeRemoteAudioTrack(sid: sid)
            currentSinks.remove(sid)
        }
        for sid in toAdd {
            guard let track = tracks[sid] else { continue }
            recordingCoordinator?.addRemoteAudioTrack(track, sid: sid)
            currentSinks.insert(sid)
        }
        interLogInfo(InterLog.media,
                     "RemoteAudio: reconciled recording sinks (+%d/-%d, active=%d)",
                     toAdd.count, toRemove.count, recordingActive ? 1 : 0)
    }

    // MARK: - Teardown

    @objc public func reset() {
        dispatchPrecondition(condition: .onQueue(.main))
        muted = false
        recordingActive = false
        for sid in currentSinks { recordingCoordinator?.removeRemoteAudioTrack(sid: sid) }
        currentSinks.removeAll()
        tracks.removeAll()
    }
}
