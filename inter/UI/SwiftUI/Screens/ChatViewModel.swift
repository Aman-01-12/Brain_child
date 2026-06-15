//
//  ChatViewModel.swift
//  inter
//
//  Drives the SwiftUI in-call chat panel content. Holds the message feed that
//  AppDelegate / SecureWindowController push via the bridge, the composer
//  state (draft + DM recipient), and the moderation/upload flags. Actions flow
//  OUT through callbacks the bridge wires to the legacy InterChatPanelDelegate,
//  so both consumers' wiring is unchanged.
//
//  Domain notes (kept faithful to the controllers, not the mock):
//    • Recipient state is mirrored to the delegate on EVERY change —
//      AppDelegate keeps its own selected-recipient copy and routes
//      sendDirectMessage/sendPublicMessage from it.
//    • If the selected DM partner leaves the roster, the selection resets to
//      Everyone AND notifies the delegate (the legacy NSPopUpButton silently
//      showed "Everyone" while both sides kept the stale identity — fixed).
//    • Secure mode never sets a participant list and never reveals export;
//      attach/download restrictions are enforced by SecureWindowController.
//

import Foundation
import Combine

/// One DM-able participant in the recipient dropdown.
public struct ChatRecipient: Equatable {
    public let identity: String
    public let name: String

    public init(identity: String, name: String) {
        self.identity = identity
        self.name = name
    }
}

@MainActor
public final class ChatViewModel: ObservableObject {

    // MARK: - State from the controllers (via the bridge)

    @Published public private(set) var messages: [InterChatMessageInfo] = []
    @Published public private(set) var participants: [ChatRecipient] = []
    @Published public private(set) var isInputEnabled: Bool = true
    @Published public private(set) var isExportVisible: Bool = false
    @Published public private(set) var isUploading: Bool = false

    // MARK: - Composer state

    @Published public var draft: String = ""
    /// Selected DM recipient identity; nil = Everyone (public).
    @Published public private(set) var selectedRecipientIdentity: String?

    /// Incremented when the shell wants the input focused (panel expanded).
    @Published public private(set) var focusTick: Int = 0

    /// Action callbacks — wired by the bridge to the legacy delegate.
    public var onSend: ((String) -> Void)?
    public var onSelectRecipient: ((String?) -> Void)?
    public var onAttach: (() -> Void)?
    public var onExport: (() -> Void)?
    public var onDownload: ((InterChatMessageInfo) -> Void)?
    public var onClose: (() -> Void)?

    public init() {}

    // MARK: - Inputs from the bridge

    public func append(_ message: InterChatMessageInfo) {
        messages.append(message)
    }

    public func setParticipants(_ list: [ChatRecipient]) {
        participants = list
        // Selected DM partner left → reset to Everyone and keep the delegate in sync.
        if let selected = selectedRecipientIdentity,
           !list.contains(where: { $0.identity == selected }) {
            selectedRecipientIdentity = nil
            onSelectRecipient?(nil)
        }
    }

    public func setInputEnabled(_ enabled: Bool) {
        isInputEnabled = enabled
    }

    public func setExportVisible(_ visible: Bool) {
        isExportVisible = visible
    }

    public func setUploading(_ uploading: Bool) {
        isUploading = uploading
    }

    public func requestInputFocus() {
        focusTick += 1
    }

    // MARK: - Derived state

    /// Whether the Send control is enabled.
    public var canSend: Bool {
        isInputEnabled && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Attach is blocked while uploading AND while chat is disabled — upload
    /// completion must not re-enable a moderation-disabled composer (legacy guard).
    public var canAttach: Bool {
        isInputEnabled && !isUploading
    }

    /// Composer placeholder, mirroring the legacy priority: disabled > DM > public.
    public var placeholder: String {
        if !isInputEnabled { return "Chat is disabled" }
        if let name = selectedRecipientName { return "DM to \(name)…" }
        return "Type a message…"
    }

    /// Display name of the selected DM recipient (nil = Everyone).
    public var selectedRecipientName: String? {
        guard let identity = selectedRecipientIdentity else { return nil }
        return displayName(for: identity)
    }

    /// Resolve an identity to a roster display name (falls back to the identity).
    public func displayName(for identity: String) -> String {
        participants.first(where: { $0.identity == identity })?.name ?? identity
    }

    // MARK: - Actions

    public func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isInputEnabled, !text.isEmpty else { return }
        draft = ""
        onSend?(text)
    }

    public func selectRecipient(_ identity: String?) {
        selectedRecipientIdentity = identity
        onSelectRecipient?(identity)
    }

    public func attach() {
        guard canAttach else { return }
        onAttach?()
    }

    public func export() {
        onExport?()
    }

    public func download(_ message: InterChatMessageInfo) {
        onDownload?(message)
    }

    public func close() {
        onClose?()
    }

    // MARK: - Pure helpers (unit-tested)

    /// Avatar initial: first grapheme of the display name, uppercased.
    public nonisolated static func initial(for name: String) -> String {
        guard let first = name.trimmingCharacters(in: .whitespaces).first else { return "?" }
        return String(first).uppercased()
    }

    /// Caption above a bubble. Own public/file messages have no caption (time
    /// shows below); own DMs caption the recipient ("To Bob"); received rows
    /// caption the sender.
    public nonisolated static func captionName(for message: InterChatMessageInfo,
                                               recipientName: String?) -> String? {
        if message.isFromLocalUser {
            guard message.messageType == .directMessage else { return nil }
            return "To \(recipientName ?? message.recipientIdentity)"
        }
        return message.senderName
    }
}
