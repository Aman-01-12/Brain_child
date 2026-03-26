// ============================================================================
// InterSpeakerQueue.swift
// inter
//
// Phase 8.2.2 — Speaker queue model for raise-hand feature.
//
// Maintains a chronologically-ordered list of participants who have
// raised their hand. KVO-observable count for badge updates.
//
// THREADING: All access on main queue.
//
// ISOLATION INVARIANT [G8]:
// Pure model — no room, media, or UI references.
// ============================================================================

import Foundation
import os.log

// MARK: - Raised Hand Entry

/// A single raised-hand entry in the speaker queue.
@objc public class InterRaisedHandEntry: NSObject {

    /// LiveKit participant identity.
    @objc public let participantIdentity: String

    /// Human-readable display name.
    @objc public let displayName: String

    /// Timestamp when the hand was raised (seconds since epoch).
    @objc public let timestamp: TimeInterval

    @objc public init(participantIdentity: String, displayName: String, timestamp: TimeInterval = Date().timeIntervalSince1970) {
        self.participantIdentity = participantIdentity
        self.displayName = displayName
        self.timestamp = timestamp
        super.init()
    }
}

// MARK: - InterSpeakerQueue

/// Manages the ordered list of raised hands.
///
/// Entries are ordered chronologically (oldest first = spoke first).
/// The host can dismiss entries via `removeHand(for:)`.
@objc public class InterSpeakerQueue: NSObject {

    // MARK: - KVO-Observable Properties

    /// Number of raised hands. KVO-observable for badge count binding.
    @objc public private(set) dynamic var count: Int = 0

    // MARK: - Public Properties

    /// Ordered list of raised hands (oldest first).
    @objc public private(set) var entries: [InterRaisedHandEntry] = []

    /// Identities of all participants with raised hands.
    @objc public var raisedIdentities: Set<String> {
        Set(entries.map { $0.participantIdentity })
    }

    // MARK: - Mutating

    /// Add a raised hand. No-op if the participant already has a hand raised.
    ///
    /// - Parameters:
    ///   - identity: The participant's LiveKit identity.
    ///   - displayName: The participant's display name.
    @objc public func addHand(identity: String, displayName: String) {
        guard !entries.contains(where: { $0.participantIdentity == identity }) else {
            interLogDebug(InterLog.room, "SpeakerQueue: %{public}@ already has hand raised, skipping", identity)
            return
        }

        let entry = InterRaisedHandEntry(participantIdentity: identity, displayName: displayName)
        entries.append(entry)
        count = entries.count

        interLogInfo(InterLog.room, "SpeakerQueue: %{public}@ raised hand (queue size=%d)",
                     displayName, entries.count)
    }

    /// Remove a raised hand for a specific participant.
    /// Called when the participant lowers their hand or the host dismisses it.
    ///
    /// - Parameter identity: The participant's LiveKit identity.
    @objc public func removeHand(for identity: String) {
        let beforeCount = entries.count
        entries.removeAll { $0.participantIdentity == identity }

        if entries.count != beforeCount {
            count = entries.count
            interLogInfo(InterLog.room, "SpeakerQueue: %{public}@ lowered hand (queue size=%d)",
                         identity, entries.count)
        }
    }

    /// Remove all hands when a participant disconnects.
    @objc public func removeDisconnectedParticipant(_ identity: String) {
        removeHand(for: identity)
    }

    /// Clear the entire queue. Called on disconnect / mode transition.
    @objc public func reset() {
        entries.removeAll()
        count = 0
        interLogInfo(InterLog.room, "SpeakerQueue: reset")
    }

    /// Check if a participant currently has a raised hand.
    @objc public func isHandRaised(for identity: String) -> Bool {
        entries.contains { $0.participantIdentity == identity }
    }

    /// Get the queue position (1-based) for a participant, or 0 if not in queue.
    @objc public func queuePosition(for identity: String) -> Int {
        guard let index = entries.firstIndex(where: { $0.participantIdentity == identity }) else {
            return 0
        }
        return index + 1
    }
}
