// ============================================================================
// InterQAController.swift
// inter
//
// Phase 8.6 — Q&A Board via LiveKit DataChannel.
//
// Uses DataChannel topic "qa" for all Q&A messages:
//   • Participants send:  askQuestion, upvote
//   • Host broadcasts:    markAnswered, highlight, dismiss, syncState
//
// OWNERSHIP:
//   Created by AppDelegate alongside the room.
//   Holds a weak reference to the Room (via InterRoomController).
//   Maintains the question list, sorted by upvote count.
//
// THREADING:
//   All public methods must be called on the main queue.
//   DataChannel callbacks arrive on LiveKit's internal queue and are
//   dispatched to main by InterRoomController before reaching this class.
//
// ISOLATION INVARIANT [G8]:
//   If this controller is nil, the app works identically — just no Q&A.
//   No integration with media, recording, or network publishing.
// ============================================================================

import Foundation
import os.log
import LiveKit

// MARK: - Question Data Model

/// A single question in the Q&A board.
public struct InterQuestion: Codable, Identifiable, Equatable {
    /// Unique question ID (UUID).
    public let id: String
    /// Identity of the participant who asked the question.
    public let askerIdentity: String
    /// Display name of the asker (empty string if anonymous).
    public let askerName: String
    /// The question text.
    public let text: String
    /// Unix timestamp when the question was submitted.
    public let timestamp: TimeInterval
    /// Number of upvotes from other participants.
    public var upvoteCount: Int
    /// Whether the host has marked this as answered.
    public var isAnswered: Bool
    /// Whether the host has highlighted (pinned to top) this question.
    public var isHighlighted: Bool
    /// Whether submitted anonymously (askerName hidden from participants, visible to host).
    public let isAnonymous: Bool

    public init(
        id: String = UUID().uuidString,
        askerIdentity: String,
        askerName: String,
        text: String,
        timestamp: TimeInterval = Date().timeIntervalSince1970,
        upvoteCount: Int = 0,
        isAnswered: Bool = false,
        isHighlighted: Bool = false,
        isAnonymous: Bool = false
    ) {
        self.id = id
        self.askerIdentity = askerIdentity
        self.askerName = askerName
        self.text = text
        self.timestamp = timestamp
        self.upvoteCount = upvoteCount
        self.isAnswered = isAnswered
        self.isHighlighted = isHighlighted
        self.isAnonymous = isAnonymous
    }
}

// MARK: - DataChannel Message Types

/// The type of Q&A message sent over DataChannel.
private enum InterQAMessageType: String, Codable {
    /// Participant → all: a new question.
    case askQuestion
    /// Participant → all: upvote a question.
    case upvote
    /// Host → all: mark a question as answered.
    case markAnswered
    /// Host → all: highlight (pin) a question.
    case highlight
    /// Host → all: dismiss (remove) a question.
    case dismiss
    /// Host → new participant: full state sync.
    case syncState
}

/// Envelope for all Q&A DataChannel messages.
private struct InterQAMessage: Codable {
    let type: InterQAMessageType
    /// Full question data (for askQuestion, syncState).
    let question: InterQuestion?
    /// Question ID (for upvote, markAnswered, highlight, dismiss).
    let questionId: String?
    /// Voter identity (for deduplication of upvotes).
    let voterIdentity: String?
    /// Full question list (for syncState).
    let questions: [InterQuestion]?

    init(type: InterQAMessageType,
         question: InterQuestion? = nil,
         questionId: String? = nil,
         voterIdentity: String? = nil,
         questions: [InterQuestion]? = nil) {
        self.type = type
        self.question = question
        self.questionId = questionId
        self.voterIdentity = voterIdentity
        self.questions = questions
    }

    func toJSONData() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func fromJSONData(_ data: Data) -> InterQAMessage? {
        try? JSONDecoder().decode(InterQAMessage.self, from: data)
    }
}

// MARK: - ObjC-Friendly Wrapper

/// Objective-C accessible wrapper for Q&A question data.
/// Used by InterQAPanel to display questions.
@objc public class InterQuestionInfo: NSObject {

    @objc public let questionId: String
    @objc public let askerIdentity: String
    @objc public let askerName: String
    @objc public let text: String
    @objc public let timestamp: TimeInterval
    @objc public let upvoteCount: Int
    @objc public let isAnswered: Bool
    @objc public let isHighlighted: Bool
    @objc public let isAnonymous: Bool

    /// Whether the local user has upvoted this question.
    @objc public var hasLocalUserUpvoted: Bool = false

    public init(from question: InterQuestion, hasUpvoted: Bool = false) {
        self.questionId = question.id
        self.askerIdentity = question.askerIdentity
        self.askerName = question.askerName
        self.text = question.text
        self.timestamp = question.timestamp
        self.upvoteCount = question.upvoteCount
        self.isAnswered = question.isAnswered
        self.isHighlighted = question.isHighlighted
        self.isAnonymous = question.isAnonymous
        self.hasLocalUserUpvoted = hasUpvoted
        super.init()
    }

    /// Display name for the asker. Returns "Anonymous" if anonymous & viewer is not host.
    @objc public func displayName(isViewerHost: Bool) -> String {
        if isAnonymous && !isViewerHost {
            return "Anonymous"
        }
        return askerName
    }

    /// Formatted timestamp (HH:mm).
    @objc public var formattedTime: String {
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Delegate Protocol

/// Delegate protocol for Q&A UI updates.
@objc public protocol InterQAControllerDelegate: AnyObject {

    /// The question list was updated (new question, upvote, answered, highlight, dismiss).
    /// The UI should reload.
    @objc func qaController(_ controller: InterQAController,
                            didUpdateQuestions questions: [InterQuestionInfo])

    /// The unread question count changed (questions received while panel is hidden).
    @objc optional func qaController(_ controller: InterQAController,
                                     didUpdateUnreadCount count: Int)

    /// A question submission failed after the optimistic local add.
    /// The controller has already rolled back the question from the list.
    /// Use this to surface an error in the UI (e.g., a toast or alert).
    @objc optional func qaController(_ controller: InterQAController,
                                     didFailToSubmitQuestion questionId: String)
}

// MARK: - InterQAController

@objc public class InterQAController: NSObject {

    // MARK: - Public Properties

    /// Delegate for Q&A UI updates.
    @objc public weak var delegate: InterQAControllerDelegate?

    /// All questions, sorted: highlighted first, then by upvote count desc, then by timestamp.
    @objc public private(set) var sortedQuestions: [InterQuestionInfo] = []

    /// Number of unread questions (received while Q&A panel is hidden).
    @objc public private(set) dynamic var unreadCount: Int = 0

    /// Whether the Q&A panel is currently visible.
    @objc public var isQAVisible: Bool = false {
        didSet {
            if isQAVisible {
                unreadCount = 0
            }
        }
    }

    /// Maximum questions to keep in memory.
    @objc public var maxQuestions: Int = 200

    // MARK: - Private Properties

    /// Weak reference to the room controller.
    private weak var roomController: InterRoomController?

    /// Local participant identity.
    private var localIdentity: String = ""

    /// Local participant display name.
    private var localDisplayName: String = ""

    /// Whether the local participant is the host.
    private var isHost: Bool = false

    /// Master question list (mutable).
    private var questions: [InterQuestion] = []

    /// Set of question IDs the local user has upvoted (prevents double-upvote).
    private var localUpvotes: Set<String> = []

    /// Per-question upvote tracking (prevents double-upvote per participant).
    /// Key: questionId, Value: set of voter identities.
    private var upvoteRecords: [String: Set<String>] = [:]
    /// IDs of questions that have been optimistically added but not yet confirmed published.
    private var pendingQuestionIds: Set<String> = []
    /// DataChannel topic for Q&A messages.
    private static let qaTopic = "qa"

    // MARK: - Lifecycle

    /// Attach to a room controller. Call after room is connected.
    @objc public func attach(to roomController: InterRoomController,
                             identity: String,
                             displayName: String,
                             isHost: Bool) {
        self.roomController = roomController
        self.localIdentity = identity
        self.localDisplayName = displayName
        self.isHost = isHost

        interLogInfo(InterLog.room, "QAController: attached (identity=%{public}@, isHost=%d)",
                     identity, isHost ? 1 : 0)
    }

    /// Detach from the room controller.
    @objc public func detach() {
        interLogInfo(InterLog.room, "QAController: detached")
        roomController = nil
    }

    /// Clear all state.
    @objc public func reset() {
        questions.removeAll()
        sortedQuestions.removeAll()
        localUpvotes.removeAll()
        upvoteRecords.removeAll()
        pendingQuestionIds.removeAll()
        unreadCount = 0
        interLogInfo(InterLog.room, "QAController: reset")
    }

    // MARK: - Participant Actions

    /// Submit a new question.
    ///
    /// - Parameters:
    ///   - text: The question text.
    ///   - isAnonymous: Whether to hide the asker's name from non-host participants.
    /// - Returns: true if the question was submitted.
    @objc @discardableResult
    public func submitQuestion(_ text: String, isAnonymous: Bool = false) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        guard let rc = roomController, rc.connectionState == .connected else {
            interLogError(InterLog.room, "QAController: cannot submit — not connected")
            return false
        }

        let question = InterQuestion(
            askerIdentity: localIdentity,
            askerName: localDisplayName,
            text: trimmed,
            isAnonymous: isAnonymous
        )

        // Add locally immediately (optimistic)
        addQuestion(question)
        pendingQuestionIds.insert(question.id)

        // Broadcast to all — roll back optimistic add on failure
        let message = InterQAMessage(type: .askQuestion, question: question)
        publishQAMessage(message) { [weak self] success in
            guard let self = self else { return }
            self.pendingQuestionIds.remove(question.id)
            if !success {
                self.questions.removeAll { $0.id == question.id }
                self.upvoteRecords.removeValue(forKey: question.id)
                self.rebuildSortedQuestions()
                self.delegate?.qaController?(self, didFailToSubmitQuestion: question.id)
                interLogError(InterLog.room,
                              "QAController: rolled back question '%{public}@' after publish failure",
                              question.id)
            }
        }

        interLogInfo(InterLog.room, "QAController: submitted question '%{public}@'", trimmed)
        return true
    }

    /// Upvote a question.
    ///
    /// - Parameter questionId: The ID of the question to upvote.
    /// - Returns: true if the upvote was applied.
    @objc @discardableResult
    public func upvoteQuestion(_ questionId: String) -> Bool {
        // Prevent double-upvote
        guard !localUpvotes.contains(questionId) else {
            interLogDebug(InterLog.room, "QAController: already upvoted question %{public}@", questionId)
            return false
        }

        guard questions.contains(where: { $0.id == questionId }) else {
            interLogError(InterLog.room, "QAController: question %{public}@ not found", questionId)
            return false
        }

        // Apply locally
        localUpvotes.insert(questionId)
        applyUpvote(questionId: questionId, voterIdentity: localIdentity)

        // Broadcast
        let message = InterQAMessage(type: .upvote, questionId: questionId, voterIdentity: localIdentity)
        publishQAMessage(message)

        interLogDebug(InterLog.room, "QAController: upvoted question %{public}@", questionId)
        return true
    }

    // MARK: - Host Actions

    /// Mark a question as answered. Host-only.
    @objc public func markAnswered(_ questionId: String) {
        guard isHost else { return }

        guard let index = questions.firstIndex(where: { $0.id == questionId }) else { return }
        questions[index].isAnswered = true
        rebuildSortedQuestions()

        let message = InterQAMessage(type: .markAnswered, questionId: questionId)
        publishQAMessage(message)

        interLogInfo(InterLog.room, "QAController: marked question %{public}@ as answered", questionId)
    }

    /// Highlight (pin to top) a question. Host-only.
    @objc public func highlightQuestion(_ questionId: String) {
        guard isHost else { return }

        guard let index = questions.firstIndex(where: { $0.id == questionId }) else { return }
        questions[index].isHighlighted = true
        rebuildSortedQuestions()

        let message = InterQAMessage(type: .highlight, questionId: questionId)
        publishQAMessage(message)

        interLogInfo(InterLog.room, "QAController: highlighted question %{public}@", questionId)
    }

    /// Dismiss (remove) a question. Host-only.
    @objc public func dismissQuestion(_ questionId: String) {
        guard isHost else { return }

        questions.removeAll { $0.id == questionId }
        upvoteRecords.removeValue(forKey: questionId)
        rebuildSortedQuestions()

        let message = InterQAMessage(type: .dismiss, questionId: questionId)
        publishQAMessage(message)

        interLogInfo(InterLog.room, "QAController: dismissed question %{public}@", questionId)
    }

    // MARK: - Receive Data

    /// Handle incoming data from DataChannel (topic "qa").
    @objc public func handleReceivedData(_ data: Data, senderIdentity: String?) {
        guard let message = InterQAMessage.fromJSONData(data) else {
            interLogError(InterLog.room, "QAController: failed to decode Q&A message (%d bytes)",
                          data.count)
            return
        }

        switch message.type {
        case .askQuestion:
            handleAskQuestion(message, senderIdentity: senderIdentity)
        case .upvote:
            handleUpvote(message, senderIdentity: senderIdentity)
        case .markAnswered:
            handleMarkAnswered(message)
        case .highlight:
            handleHighlight(message)
        case .dismiss:
            handleDismiss(message)
        case .syncState:
            handleSyncState(message)
        }
    }

    // MARK: - Private — Message Handlers

    private func handleAskQuestion(_ message: InterQAMessage, senderIdentity: String?) {
        guard let question = message.question else {
            interLogError(InterLog.room, "QAController: askQuestion missing question data")
            return
        }

        // Skip own messages (already added optimistically)
        guard question.askerIdentity != localIdentity else { return }

        addQuestion(question)

        if !isQAVisible {
            unreadCount += 1
            delegate?.qaController?(self, didUpdateUnreadCount: unreadCount)
        }

        interLogInfo(InterLog.room, "QAController: received question from %{public}@",
                     question.askerIdentity)
    }

    private func handleUpvote(_ message: InterQAMessage, senderIdentity: String?) {
        guard let questionId = message.questionId,
              let voterIdentity = message.voterIdentity ?? senderIdentity else { return }

        // Skip own upvotes (already applied locally)
        guard voterIdentity != localIdentity else { return }

        applyUpvote(questionId: questionId, voterIdentity: voterIdentity)
    }

    private func handleMarkAnswered(_ message: InterQAMessage) {
        guard let questionId = message.questionId else { return }

        // Don't reprocess if we're the host who sent it
        guard let index = questions.firstIndex(where: { $0.id == questionId }),
              !questions[index].isAnswered else { return }

        questions[index].isAnswered = true
        rebuildSortedQuestions()
    }

    private func handleHighlight(_ message: InterQAMessage) {
        guard let questionId = message.questionId else { return }

        guard let index = questions.firstIndex(where: { $0.id == questionId }),
              !questions[index].isHighlighted else { return }

        questions[index].isHighlighted = true
        rebuildSortedQuestions()
    }

    private func handleDismiss(_ message: InterQAMessage) {
        guard let questionId = message.questionId else { return }

        let beforeCount = questions.count
        questions.removeAll { $0.id == questionId }
        upvoteRecords.removeValue(forKey: questionId)

        if questions.count != beforeCount {
            rebuildSortedQuestions()
        }
    }

    private func handleSyncState(_ message: InterQAMessage) {
        guard let syncedQuestions = message.questions else { return }

        questions = syncedQuestions

        // Reconcile local state against the canonical synced set.
        let validIds = Set(questions.map { $0.id })
        localUpvotes.formIntersection(validIds)
        pendingQuestionIds.formIntersection(validIds)

        // Re-initialise upvoteRecords, dropping stale keys.
        let staleKeys = Set(upvoteRecords.keys).subtracting(validIds)
        for key in staleKeys {
            upvoteRecords.removeValue(forKey: key)
        }
        for q in questions where upvoteRecords[q.id] == nil {
            upvoteRecords[q.id] = Set<String>()
        }

        rebuildSortedQuestions()

        interLogInfo(InterLog.room, "QAController: synced %d questions from host", questions.count)
    }

    // MARK: - Private — Question Management

    private func addQuestion(_ question: InterQuestion) {
        // Deduplication
        guard !questions.contains(where: { $0.id == question.id }) else { return }

        questions.append(question)
        upvoteRecords[question.id] = Set<String>()

        // Cap at max
        if questions.count > maxQuestions {
            // Remove oldest non-highlighted, non-upvoted questions
            if let removeIndex = questions.firstIndex(where: { !$0.isHighlighted && $0.upvoteCount == 0 }) {
                let removedId = questions[removeIndex].id
                questions.remove(at: removeIndex)
                upvoteRecords.removeValue(forKey: removedId)
            }
        }

        rebuildSortedQuestions()
    }

    private func applyUpvote(questionId: String, voterIdentity: String) {
        // Prevent double-upvote per participant
        if upvoteRecords[questionId] == nil {
            upvoteRecords[questionId] = Set<String>()
        }
        guard !(upvoteRecords[questionId]?.contains(voterIdentity) ?? false) else { return }
        upvoteRecords[questionId]?.insert(voterIdentity)

        guard let index = questions.firstIndex(where: { $0.id == questionId }) else { return }
        questions[index].upvoteCount += 1
        rebuildSortedQuestions()
    }

    private func rebuildSortedQuestions() {
        // Sort: highlighted first, then by upvote count desc, then by timestamp desc
        let sorted = questions.sorted { a, b in
            if a.isHighlighted != b.isHighlighted {
                return a.isHighlighted
            }
            if a.upvoteCount != b.upvoteCount {
                return a.upvoteCount > b.upvoteCount
            }
            return a.timestamp > b.timestamp
        }

        sortedQuestions = sorted.map { q in
            let hasUpvoted = localUpvotes.contains(q.id)
            return InterQuestionInfo(from: q, hasUpvoted: hasUpvoted)
        }

        delegate?.qaController(self, didUpdateQuestions: sortedQuestions)
    }

    // MARK: - Private — Publishing

    /// Publish a Q&A message over DataChannel.
    ///
    /// - Parameters:
    ///   - message: The Q&A message envelope.
    ///   - targetIdentity: Optional single-participant destination (nil = broadcast).
    ///   - completion: Optional callback invoked on the **main queue** with `true`
    ///     on success or `false` on failure. Omit for fire-and-forget (upvotes, host actions).
    private func publishQAMessage(_ message: InterQAMessage,
                                  targetIdentity: String? = nil,
                                  completion: ((Bool) -> Void)? = nil) {
        guard let rc = roomController, rc.connectionState == .connected else {
            interLogError(InterLog.room, "QAController: cannot publish — not connected")
            completion?(false)
            return
        }

        guard let data = message.toJSONData() else {
            interLogError(InterLog.room, "QAController: failed to encode Q&A message")
            completion?(false)
            return
        }

        Task {
            do {
                let localParticipant = rc.publisher.localParticipant
                var options = DataPublishOptions(
                    topic: Self.qaTopic,
                    reliable: true
                )
                if let target = targetIdentity {
                    options = DataPublishOptions(
                        destinationIdentities: [Participant.Identity(from: target)],
                        topic: Self.qaTopic,
                        reliable: true
                    )
                }
                try await localParticipant?.publish(data: data, options: options)
                interLogDebug(InterLog.room, "QAController: published %{public}@ (%d bytes)",
                              message.type.rawValue, data.count)
                if let completion = completion {
                    DispatchQueue.main.async { completion(true) }
                }
            } catch {
                interLogError(InterLog.room, "QAController: publish failed: %{public}@",
                              error.localizedDescription)
                if let completion = completion {
                    DispatchQueue.main.async { completion(false) }
                }
            }
        }
    }
}
