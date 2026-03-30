// ============================================================================
// InterChatController.swift
// inter
//
// Phase 8.1.2 — In-meeting chat + control signals via LiveKit DataChannel.
//
// Uses two DataChannel topics:
//   • "chat"    — public and direct messages (InterChatMessage)
//   • "control" — ephemeral signals like raise hand (InterControlSignal)
//
// OWNERSHIP:
//   Created by AppDelegate / SecureWindowController alongside the room.
//   Holds a weak reference to the Room (via InterRoomController).
//   Maintains the in-memory message array and speaker queue.
//
// THREADING:
//   All public methods must be called on the main queue.
//   DataChannel callbacks arrive on LiveKit's internal queue and are
//   dispatched to main before touching any state.
//
// ISOLATION INVARIANT [G8]:
//   If this controller is nil, the app works identically — just no chat.
//   No integration with media, recording, or network publishing.
// ============================================================================

import Foundation
import os.log
import LiveKit

// MARK: - Delegate Protocol

/// Delegate protocol for chat UI updates. Implemented by InterChatPanel (via bridging).
@objc public protocol InterChatControllerDelegate: AnyObject {

    /// A new message was added to the message list.
    /// The UI should reload / scroll to bottom.
    @objc func chatController(_ controller: InterChatController, didReceiveMessage message: InterChatMessageInfo)

    /// The unread count changed (messages received while chat panel is hidden).
    @objc optional func chatController(_ controller: InterChatController, didUpdateUnreadCount count: Int)
}

/// Delegate protocol for control signal events (raise hand, etc.).
@objc public protocol InterControlSignalDelegate: AnyObject {

    /// A participant raised their hand.
    @objc func chatController(_ controller: InterChatController,
                              participantDidRaiseHand identity: String,
                              displayName: String)

    /// A participant lowered their hand (or host dismissed it).
    @objc func chatController(_ controller: InterChatController,
                              participantDidLowerHand identity: String)
}

// MARK: - InterChatController

@objc public class InterChatController: NSObject {

    // MARK: - Public Properties

    /// Delegate for chat message UI updates.
    @objc public weak var chatDelegate: InterChatControllerDelegate?

    /// Delegate for control signal events (raise hand).
    @objc public weak var controlDelegate: InterControlSignalDelegate?

    /// All messages in chronological order. Thread-safe read from main queue.
    @objc public private(set) var messages: [InterChatMessageInfo] = []

    /// Number of unread messages (received while chat panel is not visible).
    @objc public private(set) dynamic var unreadCount: Int = 0

    /// Whether the chat panel is currently visible. Set by the UI layer.
    /// When true, new messages don't increment unreadCount.
    @objc public var isChatVisible: Bool = false {
        didSet {
            if isChatVisible {
                unreadCount = 0
            }
        }
    }

    /// Maximum messages to keep in memory (older ones are dropped). Prevents unbounded growth.
    @objc public var maxMessages: Int = 500

    // MARK: - Private Properties

    /// Weak reference to the room controller. Set via attach().
    private weak var roomController: InterRoomController?

    /// Local participant identity (for marking own messages + dedup).
    private var localIdentity: String = ""

    /// Local participant display name.
    private var localDisplayName: String = ""

    /// Set of received message IDs for deduplication.
    private var receivedMessageIds: Set<String> = []

    /// DataChannel topic for chat messages.
    private static let chatTopic = "chat"

    /// DataChannel topic for control signals.
    private static let controlTopic = "control"

    // MARK: - Lifecycle

    /// Attach to a room controller. Call after room is connected.
    ///
    /// - Parameters:
    ///   - roomController: The room controller that owns the LiveKit Room.
    ///   - identity: Local participant identity.
    ///   - displayName: Local participant display name.
    @objc public func attach(to roomController: InterRoomController,
                             identity: String,
                             displayName: String) {
        self.roomController = roomController
        self.localIdentity = identity
        self.localDisplayName = displayName

        interLogInfo(InterLog.room, "ChatController: attached (identity=%{public}@)", identity)

        // Add a system message for the local user joining
        let joinMessage = InterChatMessage(
            senderIdentity: "system",
            senderName: "System",
            text: "You joined the room.",
            type: .system
        )
        appendMessage(joinMessage, isLocal: false)
    }

    /// Detach from the room controller. Call before disconnect.
    @objc public func detach() {
        interLogInfo(InterLog.room, "ChatController: detached")
        roomController = nil
    }

    /// Clear all messages and reset state. Call on mode transition or disconnect.
    @objc public func reset() {
        messages.removeAll()
        receivedMessageIds.removeAll()
        unreadCount = 0
        interLogInfo(InterLog.room, "ChatController: reset")
    }

    // MARK: - Send Public Message

    /// Send a public chat message to all participants.
    ///
    /// - Parameter text: The message text. Empty/whitespace-only messages are ignored.
    /// - Returns: true if the message was sent, false if sending failed.
    @objc @discardableResult
    public func sendPublicMessage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        guard let rc = roomController, rc.connectionState == .connected else {
            interLogError(InterLog.room, "ChatController: cannot send — not connected")
            return false
        }

        let message = InterChatMessage(
            senderIdentity: localIdentity,
            senderName: localDisplayName,
            text: trimmed,
            type: .publicMessage
        )

        guard let data = message.toJSONData() else {
            interLogError(InterLog.room, "ChatController: failed to encode message")
            return false
        }

        // Publish to all participants via DataChannel
        Task {
            do {
                let localParticipant = rc.publisher.localParticipant
                try await localParticipant?.publish(data: data, options: DataPublishOptions(
                    topic: Self.chatTopic,
                    reliable: true
                ))
                interLogDebug(InterLog.room, "ChatController: sent public message (%d bytes)", data.count)
            } catch {
                interLogError(InterLog.room, "ChatController: publish failed: %{public}@",
                              error.localizedDescription)
            }
        }

        // Add to local message list immediately (optimistic)
        appendMessage(message, isLocal: true)
        return true
    }

    // MARK: - Send Direct Message (8.3)

    /// Send a direct message to a specific participant (Pro tier).
    ///
    /// - Parameters:
    ///   - text: The message text.
    ///   - recipientIdentity: The LiveKit identity of the recipient.
    /// - Returns: true if the message was sent, false on failure.
    @objc @discardableResult
    public func sendDirectMessage(_ text: String, to recipientIdentity: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        guard let rc = roomController, rc.connectionState == .connected else {
            interLogError(InterLog.room, "ChatController: cannot send DM — not connected")
            return false
        }

        let message = InterChatMessage(
            senderIdentity: localIdentity,
            senderName: localDisplayName,
            text: trimmed,
            type: .directMessage,
            recipientIdentity: recipientIdentity
        )

        guard let data = message.toJSONData() else {
            interLogError(InterLog.room, "ChatController: failed to encode DM")
            return false
        }

        // Publish to specific participant only
        Task {
            do {
                let localParticipant = rc.publisher.localParticipant
                try await localParticipant?.publish(data: data, options: DataPublishOptions(
                    destinationIdentities: [Participant.Identity(from: recipientIdentity)],
                    topic: Self.chatTopic,
                    reliable: true
                ))
                interLogDebug(InterLog.room, "ChatController: sent DM to %{private}@ (%d bytes)",
                              recipientIdentity, data.count)
            } catch {
                interLogError(InterLog.room, "ChatController: DM publish failed: %{public}@",
                              error.localizedDescription)
            }
        }

        // Add to local message list immediately
        appendMessage(message, isLocal: true)
        return true
    }

    // MARK: - Raise Hand (8.2.1)

    /// Raise the local participant's hand.
    @objc public func raiseHand() {
        sendControlSignal(type: .raiseHand)
    }

    /// Lower the local participant's hand.
    @objc public func lowerHand() {
        sendControlSignal(type: .lowerHand)
    }

    /// Lower another participant's hand (host action).
    @objc public func lowerHand(forParticipant identity: String) {
        // Send with the HOST's identity as sender and the dismissed participant as target
        let signal = InterControlSignal(
            type: .lowerHand,
            senderIdentity: localIdentity,
            senderName: localDisplayName,
            targetIdentity: identity
        )

        guard let data = signal.toJSONData() else { return }

        guard let rc = roomController, rc.connectionState == .connected else { return }

        Task {
            do {
                let localParticipant = rc.publisher.localParticipant
                try await localParticipant?.publish(data: data, options: DataPublishOptions(
                    topic: Self.controlTopic,
                    reliable: true
                ))
            } catch {
                interLogError(InterLog.room, "ChatController: control signal publish failed: %{public}@",
                              error.localizedDescription)
            }
        }

        // Process locally on the host side
        controlDelegate?.chatController(self, participantDidLowerHand: identity)
    }

    // MARK: - Receive Data (called by InterRoomController delegate)

    /// Handle incoming data from LiveKit DataChannel.
    /// Called from InterRoomController's RoomDelegate on the main queue.
    ///
    /// - Parameters:
    ///   - data: The raw data payload.
    ///   - topic: The DataChannel topic ("chat" or "control").
    ///   - participant: The remote participant who sent the data (nil for server-sent).
    @objc public func handleReceivedData(_ data: Data, topic: String?, participant: String?) {
        guard let topic = topic else {
            interLogDebug(InterLog.room, "ChatController: received data with no topic, ignoring")
            return
        }

        switch topic {
        case Self.chatTopic:
            handleChatData(data, senderIdentity: participant)
        case Self.controlTopic:
            handleControlData(data, senderIdentity: participant)
        default:
            interLogDebug(InterLog.room, "ChatController: unknown topic '%{public}@', ignoring", topic)
        }
    }

    // MARK: - Transcript Export (8.4)

    /// Export the chat transcript to a JSON file.
    /// Returns the file URL on success, nil on failure.
    @objc public func exportTranscriptJSON() -> URL? {
        guard !messages.isEmpty else {
            interLogInfo(InterLog.room, "ChatController: no messages to export")
            return nil
        }

        // Convert back to InterChatMessage array for clean Codable export
        let exportMessages = messages.map { info in
            InterChatMessage(
                id: info.messageId,
                senderIdentity: info.senderIdentity,
                senderName: info.senderName,
                text: info.text,
                timestamp: info.timestamp,
                type: info.messageType,
                recipientIdentity: info.recipientIdentity
            )
        }

        guard let jsonData = try? JSONEncoder().encode(exportMessages) else {
            interLogError(InterLog.room, "ChatController: transcript JSON encoding failed")
            return nil
        }

        guard let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "inter_chat_transcript_\(formatter.string(from: Date())).json"
        let fileURL = cachesDir.appendingPathComponent(filename)

        do {
            try jsonData.write(to: fileURL)
            interLogInfo(InterLog.room, "ChatController: transcript exported to %{public}@", fileURL.path)
            return fileURL
        } catch {
            interLogError(InterLog.room, "ChatController: transcript export failed: %{public}@",
                          error.localizedDescription)
            return nil
        }
    }

    /// Export the chat transcript to a plain text file.
    @objc public func exportTranscriptText() -> URL? {
        guard !messages.isEmpty else { return nil }

        var lines: [String] = []
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss"

        for msg in messages {
            let time = dateFormatter.string(from: Date(timeIntervalSince1970: msg.timestamp))
            let prefix: String
            switch msg.messageType {
            case .publicMessage:
                prefix = "[\(time)] \(msg.senderName)"
            case .directMessage:
                prefix = "[\(time)] \(msg.senderName) → \(msg.recipientIdentity) (DM)"
            case .system:
                prefix = "[\(time)] [SYSTEM]"
            @unknown default:
                prefix = "[\(time)] \(msg.senderName)"
            }
            lines.append("\(prefix): \(msg.text)")
        }

        let text = lines.joined(separator: "\n")

        guard let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "inter_chat_transcript_\(formatter.string(from: Date())).txt"
        let fileURL = cachesDir.appendingPathComponent(filename)

        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            interLogInfo(InterLog.room, "ChatController: text transcript exported to %{public}@", fileURL.path)
            return fileURL
        } catch {
            interLogError(InterLog.room, "ChatController: text transcript export failed: %{public}@",
                          error.localizedDescription)
            return nil
        }
    }

    // MARK: - Private Helpers

    private func sendControlSignal(type: InterControlSignalType) {
        guard let rc = roomController, rc.connectionState == .connected else {
            interLogError(InterLog.room, "ChatController: cannot send control signal — not connected")
            return
        }

        let signal = InterControlSignal(
            type: type,
            senderIdentity: localIdentity,
            senderName: localDisplayName
        )

        guard let data = signal.toJSONData() else {
            interLogError(InterLog.room, "ChatController: failed to encode control signal")
            return
        }

        Task {
            do {
                let localParticipant = rc.publisher.localParticipant
                try await localParticipant?.publish(data: data, options: DataPublishOptions(
                    topic: Self.controlTopic,
                    reliable: true
                ))
                interLogDebug(InterLog.room, "ChatController: sent control signal type=%d", type.rawValue)
            } catch {
                interLogError(InterLog.room, "ChatController: control signal publish failed: %{public}@",
                              error.localizedDescription)
            }
        }

        // Process locally for raise/lower hand
        switch type {
        case .raiseHand:
            controlDelegate?.chatController(self, participantDidRaiseHand: localIdentity,
                                            displayName: localDisplayName)
        case .lowerHand:
            controlDelegate?.chatController(self, participantDidLowerHand: localIdentity)
        @unknown default:
            break
        }
    }

    private func handleChatData(_ data: Data, senderIdentity: String?) {
        guard let message = InterChatMessage.fromJSONData(data) else {
            interLogError(InterLog.room, "ChatController: failed to decode chat message (%d bytes)", data.count)
            return
        }

        // Deduplication: skip if we already have this message ID
        guard !receivedMessageIds.contains(message.id) else {
            interLogDebug(InterLog.room, "ChatController: duplicate message %{public}@ ignored", message.id)
            return
        }

        // Skip own messages (we already added them optimistically)
        guard message.senderIdentity != localIdentity else { return }

        appendMessage(message, isLocal: false)
    }

    private func handleControlData(_ data: Data, senderIdentity: String?) {
        guard let signal = InterControlSignal.fromJSONData(data) else {
            interLogError(InterLog.room, "ChatController: failed to decode control signal (%d bytes)", data.count)
            return
        }

        switch signal.type {
        case .raiseHand:
            // Skip own raise signals (already processed locally)
            guard signal.senderIdentity != localIdentity else { return }
            interLogInfo(InterLog.room, "ChatController: %{public}@ raised hand", signal.senderName)
            controlDelegate?.chatController(self, participantDidRaiseHand: signal.senderIdentity,
                                            displayName: signal.senderName)
        case .lowerHand:
            let targetId = signal.targetIdentity ?? signal.senderIdentity
            if targetId == localIdentity && signal.senderIdentity != localIdentity {
                // Host dismissed OUR hand — notify delegate so local button resets
                interLogInfo(InterLog.room, "ChatController: host dismissed our raised hand")
                controlDelegate?.chatController(self, participantDidLowerHand: localIdentity)
            } else if signal.senderIdentity == localIdentity {
                // Our own lower signal echoed back — skip
                return
            } else {
                // Another participant lowered their own hand
                interLogInfo(InterLog.room, "ChatController: %{public}@ lowered hand", targetId)
                controlDelegate?.chatController(self, participantDidLowerHand: targetId)
            }
        @unknown default:
            interLogDebug(InterLog.room, "ChatController: unknown control signal type %d", signal.type.rawValue)
        }
    }

    private func appendMessage(_ message: InterChatMessage, isLocal: Bool) {
        receivedMessageIds.insert(message.id)

        let info = InterChatMessageInfo(from: message, isLocal: isLocal)
        messages.append(info)

        // Trim if over max
        if messages.count > maxMessages {
            let overflow = messages.count - maxMessages
            messages.removeFirst(overflow)
        }

        // Update unread count
        if !isChatVisible && !isLocal {
            unreadCount += 1
        }

        chatDelegate?.chatController(self, didReceiveMessage: info)
    }
}
