//
//  ChatViewModelTests.swift
//  interTests
//
//  Tests the in-call chat panel view model: composer rules (send/trim/disable),
//  recipient selection + delegate mirroring + stale-recipient reset, the
//  moderation/upload attach guard, placeholder derivation, and the pure
//  caption/initial helpers.
//

import XCTest
@testable import inter

private func msg(_ id: String, text: String = "hi", type: InterChatMessageType = .publicMessage,
                 sender: String = "Alice", senderIdentity: String = "u-alice",
                 recipient: String = "", isLocal: Bool = false) -> InterChatMessageInfo {
    let m = InterChatMessage(id: id, senderIdentity: senderIdentity, senderName: sender,
                             text: text, timestamp: 1_000_000, type: type,
                             recipientIdentity: recipient)
    return InterChatMessageInfo(from: m, isLocal: isLocal)
}

@MainActor
final class ChatViewModelTests: XCTestCase {

    // MARK: - Feed

    func testAppendAccumulatesInOrder() {
        let vm = ChatViewModel()
        vm.append(msg("1"))
        vm.append(msg("2"))
        XCTAssertEqual(vm.messages.map { $0.messageId }, ["1", "2"])
    }

    // MARK: - Composer

    func testCanSendRequiresNonBlankAndEnabled() {
        let vm = ChatViewModel()
        XCTAssertFalse(vm.canSend)
        vm.draft = "   "
        XCTAssertFalse(vm.canSend)
        vm.draft = "hello"
        XCTAssertTrue(vm.canSend)
        vm.setInputEnabled(false)
        XCTAssertFalse(vm.canSend, "moderation disable blocks send")
    }

    func testSendTrimsRoutesAndClears() {
        let vm = ChatViewModel()
        var sent: [String] = []
        vm.onSend = { sent.append($0) }
        vm.draft = "  hello there  "

        vm.send()

        XCTAssertEqual(sent, ["hello there"])
        XCTAssertTrue(vm.draft.isEmpty)
    }

    func testSendBlankOrDisabledIsNoOp() {
        let vm = ChatViewModel()
        var called = false
        vm.onSend = { _ in called = true }

        vm.draft = "   "
        vm.send()
        XCTAssertFalse(called)

        vm.draft = "hello"
        vm.setInputEnabled(false)
        vm.send()
        XCTAssertFalse(called)
        XCTAssertEqual(vm.draft, "hello", "draft preserved when send is blocked")
    }

    // MARK: - Recipient selection

    func testSelectRecipientMirrorsToDelegate() {
        let vm = ChatViewModel()
        var routed: [String?] = []
        vm.onSelectRecipient = { routed.append($0) }
        vm.setParticipants([ChatRecipient(identity: "u-bob", name: "Bob")])

        vm.selectRecipient("u-bob")
        XCTAssertEqual(vm.selectedRecipientName, "Bob")

        vm.selectRecipient(nil)
        XCTAssertNil(vm.selectedRecipientName)

        XCTAssertEqual(routed.count, 2)
        XCTAssertEqual(routed[0], "u-bob")
        XCTAssertNil(routed[1])
    }

    func testStaleRecipientResetsToEveryoneAndNotifies() {
        let vm = ChatViewModel()
        var routed: [String?] = []
        vm.onSelectRecipient = { routed.append($0) }
        vm.setParticipants([ChatRecipient(identity: "u-bob", name: "Bob")])
        vm.selectRecipient("u-bob")

        vm.setParticipants([]) // Bob left

        XCTAssertNil(vm.selectedRecipientIdentity)
        XCTAssertEqual(routed.count, 2)
        XCTAssertNil(routed[1], "delegate told to route public again")
    }

    func testSurvivingRecipientIsKept() {
        let vm = ChatViewModel()
        vm.setParticipants([ChatRecipient(identity: "u-bob", name: "Bob"),
                            ChatRecipient(identity: "u-carol", name: "Carol")])
        vm.selectRecipient("u-carol")

        vm.setParticipants([ChatRecipient(identity: "u-carol", name: "Carol")])

        XCTAssertEqual(vm.selectedRecipientIdentity, "u-carol")
    }

    // MARK: - Placeholder

    func testPlaceholderPriorityDisabledThenDMThenPublic() {
        let vm = ChatViewModel()
        XCTAssertEqual(vm.placeholder, "Type a message…")

        vm.setParticipants([ChatRecipient(identity: "u-bob", name: "Bob")])
        vm.selectRecipient("u-bob")
        XCTAssertEqual(vm.placeholder, "DM to Bob…")

        vm.setInputEnabled(false)
        XCTAssertEqual(vm.placeholder, "Chat is disabled", "disabled wins over DM")
    }

    // MARK: - Attach guard (legacy upload/moderation interplay)

    func testAttachBlockedWhileUploadingOrDisabled() {
        let vm = ChatViewModel()
        var attaches = 0
        vm.onAttach = { attaches += 1 }

        vm.attach()
        XCTAssertEqual(attaches, 1)

        vm.setUploading(true)
        vm.attach()
        XCTAssertEqual(attaches, 1, "no attach while uploading")

        // Upload finishes AFTER moderation disabled chat — must stay blocked.
        vm.setInputEnabled(false)
        vm.setUploading(false)
        XCTAssertFalse(vm.canAttach)
        vm.attach()
        XCTAssertEqual(attaches, 1)

        vm.setInputEnabled(true)
        XCTAssertTrue(vm.canAttach)
    }

    // MARK: - Action routing

    func testExportDownloadCloseRoute() {
        let vm = ChatViewModel()
        var exports = 0, closes = 0
        var downloaded: [String] = []
        vm.onExport = { exports += 1 }
        vm.onClose = { closes += 1 }
        vm.onDownload = { downloaded.append($0.messageId) }

        vm.export()
        vm.close()
        vm.download(msg("f1", type: .fileMessage))

        XCTAssertEqual(exports, 1)
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(downloaded, ["f1"])
    }

    // MARK: - Pure helpers

    func testInitialUppercasesFirstGrapheme() {
        XCTAssertEqual(ChatViewModel.initial(for: "bob smith"), "B")
        XCTAssertEqual(ChatViewModel.initial(for: "  alice"), "A")
        XCTAssertEqual(ChatViewModel.initial(for: ""), "?")
    }

    func testCaptionNames() {
        // Received public → sender name.
        XCTAssertEqual(ChatViewModel.captionName(for: msg("1"), recipientName: nil), "Alice")
        // Own public → no caption (time renders below the bubble).
        XCTAssertNil(ChatViewModel.captionName(for: msg("2", isLocal: true), recipientName: nil))
        // Own DM → "To <name>".
        XCTAssertEqual(ChatViewModel.captionName(
            for: msg("3", type: .directMessage, recipient: "u-bob", isLocal: true),
            recipientName: "Bob"), "To Bob")
        // Own DM with unresolvable name falls back to the identity.
        XCTAssertEqual(ChatViewModel.captionName(
            for: msg("4", type: .directMessage, recipient: "u-gone", isLocal: true),
            recipientName: nil), "To u-gone")
        // Received DM → sender name (DM pill conveys the channel).
        XCTAssertEqual(ChatViewModel.captionName(
            for: msg("5", type: .directMessage, recipient: "u-me"),
            recipientName: nil), "Alice")
    }

    func testFocusTickIncrements() {
        let vm = ChatViewModel()
        let before = vm.focusTick
        vm.requestInputFocus()
        XCTAssertEqual(vm.focusTick, before + 1)
    }
}
