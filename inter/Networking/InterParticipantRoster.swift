// ============================================================================
// InterParticipantRoster.swift
// inter
//
// SINGLE SOURCE OF TRUTH for presence-driven tile management.
//
// The roster holds per-identity presence + media state. It is fed by
// InterLiveKitSubscriber (Room delegate callbacks + first-frame signals) and by
// the media wiring controller (local camera state + active speaker). On any
// change it rebuilds the COMPLETE ordered snapshot and invokes `onSnapshot` on
// the main thread. The UI reconciles to the snapshot; nothing mutates tiles
// directly. This removes all ordering races (including attach-before-wire).
//
// THREADING: all mutators are always called on the main thread or hop to it.
// Snapshot emission is synchronous for immediate consistency.
// The roster never touches local capture or recording [G8].
// ============================================================================

import Foundation
import os.log

@objc public final class InterParticipantRoster: NSObject {

    /// Invoked with the complete ordered snapshot whenever state changes.
    /// Always called on the main thread.
    @objc public var onSnapshot: (([InterParticipantSnapshotEntry]) -> Void)?

    private struct RemoteState {
        var displayName: String
        var subscribed: Bool = false
        var cameraMuted: Bool = true     // assume off until proven on
        var firstFrameSeen: Bool = false
        var micMuted: Bool = false
        var handRaised: Bool = false
        var isScreenSharing: Bool = false
    }

    private struct LocalState {
        var identity: String
        var displayName: String
        var cameraOn: Bool
        var micMuted: Bool
    }

    // Ordered remote identities (join order) + their state.
    private var remoteOrder: [String] = []
    private var remote: [String: RemoteState] = [:]
    private var local: LocalState?
    private var activeSpeaker: String = ""

    @objc public override init() { super.init() }

    // MARK: - Local

    @objc public func setLocal(identity: String, displayName: String, cameraOn: Bool, micMuted: Bool) {
        runOnMain {
            self.local = LocalState(identity: identity, displayName: displayName,
                                    cameraOn: cameraOn, micMuted: micMuted)
            self.emitNow()
        }
    }

    @objc public func setLocalCameraOn(_ on: Bool) {
        runOnMain {
            guard var l = self.local else { return }
            l.cameraOn = on
            self.local = l
            self.emitNow()
        }
    }

    @objc public func setLocalMicMuted(_ muted: Bool) {
        runOnMain {
            guard var l = self.local else { return }
            l.micMuted = muted
            self.local = l
            self.emitNow()
        }
    }

    // MARK: - Remote presence

    @objc public func participantJoined(_ identity: String, displayName: String) {
        runOnMain {
            guard !identity.isEmpty else { return }
            if self.remote[identity] == nil {
                self.remoteOrder.append(identity)
                self.remote[identity] = RemoteState(displayName: displayName)
            } else {
                self.remote[identity]?.displayName = displayName
            }
            self.emitNow()
        }
    }

    @objc public func participantLeft(_ identity: String) {
        runOnMain {
            self.remote[identity] = nil
            self.remoteOrder.removeAll { $0 == identity }
            if self.activeSpeaker == identity { self.activeSpeaker = "" }
            self.emitNow()
        }
    }

    // MARK: - Remote media

    @objc public func cameraSubscribed(_ identity: String) {
        mutateRemote(identity) {
            print("[CB] ROSTER-CAM-SUBSCRIBED …\(identity.suffix(5))")
            $0.subscribed = true
        }
    }

    @objc public func cameraEnded(_ identity: String) {
        mutateRemote(identity) {
            $0.subscribed = false
            $0.firstFrameSeen = false
            $0.cameraMuted = true
        }
    }

    @objc public func cameraMuted(_ identity: String, muted: Bool) {
        mutateRemote(identity) {
            let suffix = String(identity.suffix(5))
            print("[CB] CAM-MUTED …\(suffix) muted=\(muted ? 1 : 0) prev(cameraMuted=\($0.cameraMuted ? 1 : 0) firstFrameSeen=\($0.firstFrameSeen ? 1 : 0))")
            $0.cameraMuted = muted
            // Reset firstFrameSeen on BOTH mute and unmute. On mute it keeps camOn=false.
            // On unmute it forces us to wait for a genuinely fresh post-unmute frame before
            // revealing video — so a stale in-flight frame from before the mute can never
            // flash a frozen image. camOn = subscribed && !cameraMuted && firstFrameSeen.
            $0.firstFrameSeen = false
        }
    }

    @objc public func cameraFirstFrame(_ identity: String) {
        // Hot-path guarded: only emit when this actually flips firstFrameSeen.
        runOnMain {
            guard var s = self.remote[identity], !s.firstFrameSeen else { return }
            // Record only that a frame has been seen. We deliberately do NOT clear
            // cameraMuted here: the LiveKit mute/unmute signals are the single authority
            // for mute state. camOn = subscribed && !cameraMuted && firstFrameSeen, so a
            // frame that arrives while muted sets firstFrameSeen but leaves camOn false —
            // the avatar stays up, no frozen frame is revealed. When the genuine unmute
            // arrives it resets firstFrameSeen, and the next real frame flips camOn true.
            s.firstFrameSeen = true
            self.remote[identity] = s
            let suffix = String(identity.suffix(5))
            print("[CB] FIRST-FRAME …\(suffix) muted=\(s.cameraMuted ? 1 : 0)")
            self.emitNow()
        }
    }

    @objc public func micMuted(_ identity: String, muted: Bool) {
        mutateRemote(identity) { $0.micMuted = muted }
    }

    @objc public func handRaised(_ identity: String, raised: Bool) {
        mutateRemote(identity) { $0.handRaised = raised }
    }

    @objc public func screenSharing(_ identity: String, sharing: Bool) {
        mutateRemote(identity) { $0.isScreenSharing = sharing }
    }

    @objc public func updateDisplayName(_ name: String, for identity: String) {
        mutateRemote(identity) { $0.displayName = name }
    }

    @objc public func setActiveSpeaker(_ identity: String) {
        runOnMain {
            self.activeSpeaker = identity
            self.emitNow()
        }
    }

    /// Re-emit the current snapshot. Call when the downstream delegate is (re)wired
    /// so late wiring or reconnect self-heals — this is the race fix.
    @objc public func resync() {
        runOnMain { self.emitNow() }
    }

    /// Drop all remote participants (e.g. on disconnect). Keeps local.
    @objc public func reset() {
        runOnMain {
            self.remote.removeAll()
            self.remoteOrder.removeAll()
            self.activeSpeaker = ""
            self.emitNow()
        }
    }

    // MARK: - Internals

    private func mutateRemote(_ identity: String, _ apply: @escaping (inout RemoteState) -> Void) {
        runOnMain {
            guard var s = self.remote[identity] else { return }
            apply(&s)
            self.remote[identity] = s
            self.emitNow()
        }
    }

    private func runOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    private func emitNow() {
        var entries: [InterParticipantSnapshotEntry] = []
        if let l = local {
            entries.append(InterParticipantSnapshotEntry(
                identity: l.identity, displayName: l.displayName, isLocal: true,
                cameraOn: l.cameraOn, micMuted: l.micMuted, handRaised: false,
                isSpeaking: activeSpeaker == l.identity, isScreenSharing: false))
        }
        for id in remoteOrder {
            guard let s = remote[id] else { continue }
            let camOn = s.subscribed && !s.cameraMuted && s.firstFrameSeen
            entries.append(InterParticipantSnapshotEntry(
                identity: id, displayName: s.displayName, isLocal: false,
                cameraOn: camOn, micMuted: s.micMuted, handRaised: s.handRaised,
                isSpeaking: activeSpeaker == id, isScreenSharing: s.isScreenSharing))
        }
        onSnapshot?(entries)
    }
}
