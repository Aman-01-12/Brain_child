// ============================================================================
// InterPollController.swift
// inter
//
// Phase 8.5 — Live Polls via LiveKit DataChannel.
//
// Uses DataChannel topic "poll" for all poll-related messages:
//   • Host broadcasts: launchPoll, endPoll, pollResults
//   • Participants send: vote (targeted back to host)
//
// OWNERSHIP:
//   Created by AppDelegate alongside the room.
//   Holds a weak reference to the Room (via InterRoomController).
//   Maintains the active poll and aggregated results.
//
// THREADING:
//   All public methods must be called on the main queue.
//   DataChannel callbacks arrive on LiveKit's internal queue and are
//   dispatched to main by InterRoomController before reaching this class.
//
// ISOLATION INVARIANT [G8]:
//   If this controller is nil, the app works identically — just no polls.
//   No integration with media, recording, or network publishing.
// ============================================================================

import Foundation
import os.log
import LiveKit

// MARK: - Poll Data Types

/// Status of a poll throughout its lifecycle.
@objc public enum InterPollStatus: Int, Codable {
    /// Poll created but not yet launched.
    case draft = 0
    /// Poll is active and accepting votes.
    case active = 1
    /// Poll has ended; results are final.
    case ended = 2
}

/// A single option within a poll.
public struct InterPollOption: Codable, Equatable {
    /// Display label for this option (e.g. "Option A").
    public let label: String
    /// Number of votes received. Updated only on the host side during aggregation.
    public var voteCount: Int

    public init(label: String, voteCount: Int = 0) {
        self.label = label
        self.voteCount = voteCount
    }
}

/// A complete poll definition, transmitted over DataChannel.
///
/// The host creates and broadcasts this. Participants receive it and
/// display the voting UI. Vote counts are aggregated on the host side
/// and broadcast periodically as `pollResults`.
public struct InterPoll: Codable, Identifiable, Equatable {
    /// Unique poll identifier (UUID string).
    public let id: String
    /// The question text.
    public let question: String
    /// Ordered list of vote options (2–10).
    public var options: [InterPollOption]
    /// Identity of the poll creator (host).
    public let createdBy: String
    /// Whether individual votes are anonymous to other participants.
    public let isAnonymous: Bool
    /// Whether participants can select multiple options.
    public let allowMultiSelect: Bool
    /// Current lifecycle status.
    public var status: InterPollStatus
    /// Unix timestamp when the poll was created.
    public let createdAt: TimeInterval

    public init(
        id: String = UUID().uuidString,
        question: String,
        options: [InterPollOption],
        createdBy: String,
        isAnonymous: Bool = false,
        allowMultiSelect: Bool = false,
        status: InterPollStatus = .draft,
        createdAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.question = question
        self.options = options
        self.createdBy = createdBy
        self.isAnonymous = isAnonymous
        self.allowMultiSelect = allowMultiSelect
        self.status = status
        self.createdAt = createdAt
    }
}

// MARK: - DataChannel Message Types

/// The type of poll message sent over DataChannel.
private enum InterPollMessageType: String, Codable {
    /// Host → all: a new poll is started.
    case launchPoll
    /// Participant → host: a vote submission.
    case vote
    /// Host → all: updated vote counts (live results or final).
    case pollResults
    /// Host → all: the poll is ended; no more votes accepted.
    case endPoll
}

/// Envelope for all poll DataChannel messages.
private struct InterPollMessage: Codable {
    let type: InterPollMessageType
    /// Full poll data (for launchPoll, pollResults, endPoll).
    let poll: InterPoll?
    /// Poll ID (for vote messages).
    let pollId: String?
    /// Selected option indices (for vote messages).
    let optionIndices: [Int]?
    /// Voter identity (for vote tracking on host side).
    let voterIdentity: String?

    init(type: InterPollMessageType,
         poll: InterPoll? = nil,
         pollId: String? = nil,
         optionIndices: [Int]? = nil,
         voterIdentity: String? = nil) {
        self.type = type
        self.poll = poll
        self.pollId = pollId
        self.optionIndices = optionIndices
        self.voterIdentity = voterIdentity
    }

    func toJSONData() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func fromJSONData(_ data: Data) -> InterPollMessage? {
        try? JSONDecoder().decode(InterPollMessage.self, from: data)
    }
}

// MARK: - ObjC-Friendly Wrapper

/// Objective-C accessible wrapper for poll data.
/// Used by InterPollPanel to display poll state.
@objc public class InterPollInfo: NSObject {

    @objc public let pollId: String
    @objc public let question: String
    @objc public let optionLabels: [String]
    @objc public let optionVoteCounts: [Int]
    @objc public let createdBy: String
    @objc public let isAnonymous: Bool
    @objc public let allowMultiSelect: Bool
    @objc public let statusRawValue: Int
    @objc public let totalVotes: Int
    @objc public let createdAt: TimeInterval

    /// Whether the local user has already voted on this poll.
    @objc public var hasLocalUserVoted: Bool = false

    /// The option indices the local user selected (empty if not voted).
    @objc public var localVoteIndices: [Int] = []

    public init(from poll: InterPoll, hasVoted: Bool = false, localVotes: [Int] = []) {
        self.pollId = poll.id
        self.question = poll.question
        self.optionLabels = poll.options.map { $0.label }
        self.optionVoteCounts = poll.options.map { $0.voteCount }
        self.createdBy = poll.createdBy
        self.isAnonymous = poll.isAnonymous
        self.allowMultiSelect = poll.allowMultiSelect
        self.statusRawValue = poll.status.rawValue
        self.totalVotes = poll.options.reduce(0) { $0 + $1.voteCount }
        self.createdAt = poll.createdAt
        self.hasLocalUserVoted = hasVoted
        self.localVoteIndices = localVotes
        super.init()
    }

    /// Whether the poll is currently accepting votes.
    @objc public var isActive: Bool {
        return statusRawValue == InterPollStatus.active.rawValue
    }

    /// Whether the poll has ended.
    @objc public var isEnded: Bool {
        return statusRawValue == InterPollStatus.ended.rawValue
    }

    /// Get vote percentage for an option index (0.0–1.0). Returns 0 if no votes.
    @objc public func votePercentage(at index: Int) -> Double {
        guard index >= 0, index < optionVoteCounts.count, totalVotes > 0 else { return 0.0 }
        return Double(optionVoteCounts[index]) / Double(totalVotes)
    }
}

// MARK: - Delegate Protocol

/// Delegate protocol for poll UI updates. Implemented by InterPollPanel.
@objc public protocol InterPollControllerDelegate: AnyObject {

    /// A new poll was launched. Display the voting UI.
    @objc func pollController(_ controller: InterPollController, didLaunchPoll poll: InterPollInfo)

    /// Poll results were updated (live or final).
    @objc func pollController(_ controller: InterPollController, didUpdateResults poll: InterPollInfo)

    /// A poll was ended. Lock the voting UI and show final results.
    @objc func pollController(_ controller: InterPollController, didEndPoll poll: InterPollInfo)

    /// A vote was received (host-side only, for real-time vote count).
    @objc optional func pollController(_ controller: InterPollController,
                                       didReceiveVoteForPoll pollId: String,
                                       fromParticipant identity: String)
}

// MARK: - InterPollController

@objc public class InterPollController: NSObject {

    // MARK: - Public Properties

    /// Delegate for poll UI updates.
    @objc public weak var delegate: InterPollControllerDelegate?

    /// The currently active poll (nil if no poll is running).
    @objc public private(set) var activePollInfo: InterPollInfo?

    /// Poll history (most recent first). Capped at `maxPollHistory`.
    @objc public private(set) var pollHistory: [InterPollInfo] = []

    /// Maximum number of polls to keep in history.
    @objc public var maxPollHistory: Int = 20

    // MARK: - Private Properties

    /// Weak reference to the room controller.
    private weak var roomController: InterRoomController?

    /// Local participant identity.
    private var localIdentity: String = ""

    /// Whether the local participant is the host.
    private var isHost: Bool = false

    /// The active poll (mutable, host-side for vote aggregation).
    private var activePoll: InterPoll?

    /// Set of voter identities per poll ID to prevent double-voting.
    /// Key: pollId, Value: set of identities that have voted.
    private var voteRecords: [String: Set<String>] = [:]

    /// Local user's vote selections per poll ID.
    /// Key: pollId, Value: array of selected option indices.
    private var localVotes: [String: [Int]] = [:]

    /// DataChannel topic for poll messages.
    private static let pollTopic = "poll"

    // MARK: - Lifecycle

    /// Attach to a room controller. Call after room is connected.
    ///
    /// - Parameters:
    ///   - roomController: The room controller that owns the LiveKit Room.
    ///   - identity: Local participant identity.
    ///   - isHost: Whether the local participant is the room host.
    @objc public func attach(to roomController: InterRoomController,
                             identity: String,
                             isHost: Bool) {
        self.roomController = roomController
        self.localIdentity = identity
        self.isHost = isHost

        interLogInfo(InterLog.room, "PollController: attached (identity=%{public}@, isHost=%d)",
                     identity, isHost ? 1 : 0)
    }

    /// Detach from the room controller. Call before disconnect.
    @objc public func detach() {
        interLogInfo(InterLog.room, "PollController: detached")
        roomController = nil
    }

    /// Clear all state. Call on mode transition or disconnect.
    @objc public func reset() {
        activePoll = nil
        activePollInfo = nil
        pollHistory.removeAll()
        voteRecords.removeAll()
        localVotes.removeAll()
        interLogInfo(InterLog.room, "PollController: reset")
    }

    // MARK: - Host Actions

    /// Create and launch a new poll. Host-only.
    ///
    /// - Parameters:
    ///   - question: The poll question text.
    ///   - options: Array of option labels (2–10 required).
    ///   - isAnonymous: Whether votes are anonymous.
    ///   - allowMultiSelect: Whether multiple option selection is allowed.
    /// - Returns: true if the poll was launched successfully.
    @objc @discardableResult
    public func launchPoll(question: String,
                           options: [String],
                           isAnonymous: Bool,
                           allowMultiSelect: Bool) -> Bool {
        guard isHost else {
            interLogError(InterLog.room, "PollController: only the host can launch polls")
            return false
        }

        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else {
            interLogError(InterLog.room, "PollController: question cannot be empty")
            return false
        }

        // Trim and reject blank option labels before any side-effects.
        let trimmedLabels = options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard trimmedLabels.count >= 2, trimmedLabels.count <= 10 else {
            interLogError(InterLog.room,
                          "PollController: need 2–10 non-blank options, got %d after trimming",
                          trimmedLabels.count)
            return false
        }

        // End any existing active poll
        if activePoll?.status == .active {
            endCurrentPoll()
        }

        let pollOptions = trimmedLabels.map { InterPollOption(label: $0) }
        let poll = InterPoll(
            question: trimmedQuestion,
            options: pollOptions,
            createdBy: localIdentity,
            isAnonymous: isAnonymous,
            allowMultiSelect: allowMultiSelect,
            status: .active
        )

        activePoll = poll
        voteRecords[poll.id] = Set<String>()

        let info = InterPollInfo(from: poll)
        activePollInfo = info

        // Broadcast to all participants
        let message = InterPollMessage(type: .launchPoll, poll: poll)
        publishPollMessage(message)

        delegate?.pollController(self, didLaunchPoll: info)

        interLogInfo(InterLog.room, "PollController: launched poll '%{public}@' with %d options",
                     trimmedQuestion, trimmedLabels.count)
        return true
    }

    /// End the currently active poll. Host-only.
    /// Broadcasts final results to all participants.
    @objc public func endCurrentPoll() {
        guard isHost else {
            interLogError(InterLog.room, "PollController: only the host can end polls")
            return
        }

        guard var poll = activePoll, poll.status == .active else {
            interLogDebug(InterLog.room, "PollController: no active poll to end")
            return
        }

        poll.status = .ended
        activePoll = poll

        let hasVoted = localVotes[poll.id] != nil
        let votes = localVotes[poll.id] ?? []
        let info = InterPollInfo(from: poll, hasVoted: hasVoted, localVotes: votes)
        activePollInfo = info

        // Archive to history
        addToHistory(info)

        // Broadcast endPoll with final results
        let message = InterPollMessage(type: .endPoll, poll: poll)
        publishPollMessage(message)

        delegate?.pollController(self, didEndPoll: info)

        interLogInfo(InterLog.room, "PollController: ended poll '%{public}@'", poll.question)
    }

    /// Broadcast current results to all participants. Host-only.
    /// Call this to share live results before the poll ends.
    @objc public func shareResults() {
        guard isHost, let poll = activePoll else { return }

        let message = InterPollMessage(type: .pollResults, poll: poll)
        publishPollMessage(message)

        interLogDebug(InterLog.room, "PollController: shared live results for poll '%{public}@'",
                      poll.question)
    }

    // MARK: - Participant Actions

    /// Submit a vote for the active poll. Participant (non-host) action.
    ///
    /// - Parameter optionIndices: Array of selected option indices (0-based).
    /// - Returns: true if the vote was submitted.
    @objc @discardableResult
    public func submitVote(optionIndices: [Int]) -> Bool {
        guard let poll = activePoll, poll.status == .active else {
            interLogError(InterLog.room, "PollController: no active poll to vote on")
            return false
        }

        guard localVotes[poll.id] == nil else {
            interLogInfo(InterLog.room, "PollController: already voted on this poll")
            return false
        }

        // Validate indices
        let validIndices = optionIndices.filter { $0 >= 0 && $0 < poll.options.count }
        guard !validIndices.isEmpty else {
            interLogError(InterLog.room, "PollController: no valid option indices")
            return false
        }

        // For single-select, take only the first
        let finalIndices: [Int]
        if !poll.allowMultiSelect {
            finalIndices = [validIndices[0]]
        } else {
            // Deduplicate
            finalIndices = Array(Set(validIndices)).sorted()
        }

        // Record local vote
        localVotes[poll.id] = finalIndices

        // If host, aggregate locally
        if isHost {
            aggregateVote(pollId: poll.id, voterIdentity: localIdentity, optionIndices: finalIndices)
        } else {
            // Send vote to host (targeted publish)
            let message = InterPollMessage(
                type: .vote,
                pollId: poll.id,
                optionIndices: finalIndices,
                voterIdentity: localIdentity
            )
            publishPollMessage(message, targetIdentity: poll.createdBy)
        }

        // Update local display (host path already handled by aggregateVote)
        if !isHost, let currentPoll = activePoll {
            let info = InterPollInfo(from: currentPoll, hasVoted: true, localVotes: finalIndices)
            activePollInfo = info
            delegate?.pollController(self, didUpdateResults: info)
        }

        interLogInfo(InterLog.room, "PollController: submitted vote indices=%{public}@",
                     finalIndices.description)
        return true
    }

    // MARK: - Receive Data

    /// Handle incoming data from DataChannel (topic "poll").
    /// Called from InterRoomController's delegate on the main queue.
    ///
    /// - Parameters:
    ///   - data: The raw JSON payload.
    ///   - senderIdentity: The identity of the sender (nil for server-sent).
    @objc public func handleReceivedData(_ data: Data, senderIdentity: String?) {
        guard let message = InterPollMessage.fromJSONData(data) else {
            interLogError(InterLog.room, "PollController: failed to decode poll message (%d bytes)",
                          data.count)
            return
        }

        switch message.type {
        case .launchPoll:
            handleLaunchPoll(message)
        case .vote:
            handleVote(message, senderIdentity: senderIdentity)
        case .pollResults:
            handlePollResults(message)
        case .endPoll:
            handleEndPoll(message)
        }
    }

    // MARK: - Private — Message Handlers

    private func handleLaunchPoll(_ message: InterPollMessage) {
        guard let poll = message.poll else {
            interLogError(InterLog.room, "PollController: launchPoll message missing poll data")
            return
        }

        // Don't process our own broadcast
        guard poll.createdBy != localIdentity else { return }

        activePoll = poll
        let info = InterPollInfo(from: poll)
        activePollInfo = info

        delegate?.pollController(self, didLaunchPoll: info)

        interLogInfo(InterLog.room, "PollController: received poll '%{public}@' from %{public}@",
                     poll.question, poll.createdBy)
    }

    private func handleVote(_ message: InterPollMessage, senderIdentity: String?) {
        // Only the host should process votes
        guard isHost else { return }

        // Use the authoritative senderIdentity from LiveKit, never the
        // client-supplied message.voterIdentity (which can be forged).
        guard let voterIdentity = senderIdentity else {
            interLogError(InterLog.room, "PollController: vote rejected — senderIdentity is nil")
            return
        }

        guard let pollId = message.pollId,
              let optionIndices = message.optionIndices else {
            interLogError(InterLog.room, "PollController: invalid vote message from %{public}@",
                          voterIdentity)
            return
        }

        aggregateVote(pollId: pollId, voterIdentity: voterIdentity, optionIndices: optionIndices)
    }

    private func handlePollResults(_ message: InterPollMessage) {
        guard let poll = message.poll else {
            interLogError(InterLog.room, "PollController: pollResults message missing poll data")
            return
        }

        // Don't process our own broadcast (host already has local state)
        guard poll.createdBy != localIdentity else { return }

        activePoll = poll
        let hasVoted = localVotes[poll.id] != nil
        let votes = localVotes[poll.id] ?? []
        let info = InterPollInfo(from: poll, hasVoted: hasVoted, localVotes: votes)
        activePollInfo = info

        delegate?.pollController(self, didUpdateResults: info)

        interLogDebug(InterLog.room, "PollController: received updated results for '%{public}@'",
                      poll.question)
    }

    private func handleEndPoll(_ message: InterPollMessage) {
        guard let poll = message.poll else {
            interLogError(InterLog.room, "PollController: endPoll message missing poll data")
            return
        }

        // Don't process our own broadcast
        guard poll.createdBy != localIdentity else { return }

        activePoll = poll
        let hasVoted = localVotes[poll.id] != nil
        let votes = localVotes[poll.id] ?? []
        let info = InterPollInfo(from: poll, hasVoted: hasVoted, localVotes: votes)
        activePollInfo = info

        addToHistory(info)

        delegate?.pollController(self, didEndPoll: info)

        interLogInfo(InterLog.room, "PollController: poll '%{public}@' ended", poll.question)
    }

    // MARK: - Private — Vote Aggregation (Host-Only)

    private func aggregateVote(pollId: String, voterIdentity: String, optionIndices: [Int]) {
        guard var poll = activePoll, poll.id == pollId, poll.status == .active else {
            interLogDebug(InterLog.room, "PollController: vote for inactive/unknown poll '%{public}@'",
                          pollId)
            return
        }

        // Prevent double-voting
        if voteRecords[pollId] == nil {
            voteRecords[pollId] = Set<String>()
        }
        guard !(voteRecords[pollId]?.contains(voterIdentity) ?? false) else {
            interLogInfo(InterLog.room, "PollController: duplicate vote from %{public}@ rejected",
                         voterIdentity)
            return
        }
        voteRecords[pollId]?.insert(voterIdentity)

        // Validate and apply
        let validIndices: [Int]
        if poll.allowMultiSelect {
            validIndices = Array(Set(optionIndices)).filter { $0 >= 0 && $0 < poll.options.count }
        } else {
            if let first = optionIndices.first, first >= 0, first < poll.options.count {
                validIndices = [first]
            } else {
                validIndices = []
            }
        }

        for index in validIndices {
            poll.options[index].voteCount += 1
        }

        activePoll = poll
        let hasVoted = localVotes[poll.id] != nil
        let votes = localVotes[poll.id] ?? []
        let info = InterPollInfo(from: poll, hasVoted: hasVoted, localVotes: votes)
        activePollInfo = info

        delegate?.pollController?(self, didReceiveVoteForPoll: pollId, fromParticipant: voterIdentity)
        delegate?.pollController(self, didUpdateResults: info)

        interLogDebug(InterLog.room, "PollController: aggregated vote from %{public}@ (total voters=%d)",
                      voterIdentity, voteRecords[pollId]?.count ?? 0)
    }

    // MARK: - Private — Publishing

    private func publishPollMessage(_ message: InterPollMessage, targetIdentity: String? = nil) {
        guard let rc = roomController, rc.connectionState == .connected else {
            interLogError(InterLog.room, "PollController: cannot publish — not connected")
            return
        }

        guard let data = message.toJSONData() else {
            interLogError(InterLog.room, "PollController: failed to encode poll message")
            return
        }

        Task {
            do {
                let localParticipant = rc.publisher.localParticipant
                var options = DataPublishOptions(
                    topic: Self.pollTopic,
                    reliable: true
                )
                if let target = targetIdentity {
                    options = DataPublishOptions(
                        destinationIdentities: [Participant.Identity(from: target)],
                        topic: Self.pollTopic,
                        reliable: true
                    )
                }
                try await localParticipant?.publish(data: data, options: options)
                interLogDebug(InterLog.room, "PollController: published %{public}@ (%d bytes)",
                              message.type.rawValue, data.count)
            } catch {
                interLogError(InterLog.room, "PollController: publish failed: %{public}@",
                              error.localizedDescription)
            }
        }
    }

    // MARK: - Private — History

    private func addToHistory(_ info: InterPollInfo) {
        // Avoid duplicates
        if !pollHistory.contains(where: { $0.pollId == info.pollId }) {
            pollHistory.insert(info, at: 0)
            if pollHistory.count > maxPollHistory {
                pollHistory.removeLast()
            }
        }
    }
}
