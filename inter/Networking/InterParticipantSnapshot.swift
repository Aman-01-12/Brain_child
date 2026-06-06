// ============================================================================
// InterParticipantSnapshot.swift
// inter
//
// Immutable value type describing one participant's presence + media state at a
// single instant. The roster emits a complete ordered array of these on every
// change; the ObjC layout manager reconciles tiles to match. @objc so it crosses
// the Swift→ObjC bridge into InterRemoteVideoLayoutManager.
// ============================================================================

import Foundation

@objc public final class InterParticipantSnapshotEntry: NSObject {
    @objc public let identity: String
    @objc public let displayName: String
    @objc public let isLocal: Bool
    /// Remote: subscribed && track present && !muted && first frame seen.
    /// Local:  local capture is active.
    @objc public let cameraOn: Bool
    @objc public let micMuted: Bool
    @objc public let handRaised: Bool
    @objc public let isSpeaking: Bool
    @objc public let isScreenSharing: Bool

    @objc public init(identity: String,
                      displayName: String,
                      isLocal: Bool,
                      cameraOn: Bool,
                      micMuted: Bool,
                      handRaised: Bool,
                      isSpeaking: Bool,
                      isScreenSharing: Bool) {
        self.identity = identity
        self.displayName = displayName
        self.isLocal = isLocal
        self.cameraOn = cameraOn
        self.micMuted = micMuted
        self.handRaised = handRaised
        self.isSpeaking = isSpeaking
        self.isScreenSharing = isScreenSharing
        super.init()
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? InterParticipantSnapshotEntry else { return false }
        return identity == o.identity &&
            displayName == o.displayName &&
            isLocal == o.isLocal &&
            cameraOn == o.cameraOn &&
            micMuted == o.micMuted &&
            handRaised == o.handRaised &&
            isSpeaking == o.isSpeaking &&
            isScreenSharing == o.isScreenSharing
    }

    public override var hash: Int {
        var h = Hasher()
        h.combine(identity)
        h.combine(displayName)
        h.combine(isLocal)
        h.combine(cameraOn)
        h.combine(micMuted)
        h.combine(handRaised)
        h.combine(isSpeaking)
        h.combine(isScreenSharing)
        return h.finalize()
    }

    public override var description: String {
        return "<Entry \(identity) local=\(isLocal) cam=\(cameraOn) mic!=\(micMuted) speak=\(isSpeaking) share=\(isScreenSharing)>"
    }
}
