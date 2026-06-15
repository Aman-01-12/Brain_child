//
//  InterChatHostView.swift
//  inter
//
//  Obj-C ⇆ SwiftUI bridge for the in-call chat panel content. An NSView that
//  hosts `ChatView` and re-exposes exactly the surface the legacy
//  `InterChatPanel` shell needs: block callbacks for the delegate actions plus
//  the append/participants/moderation/upload forwarders. The shell keeps the
//  slide-in container, hit-testing, and the AppKit unread badge — this view is
//  only the panel's CONTENT.
//
//  The in-call window is not appearance-pinned (the legacy panel hardcoded its
//  dark palette), so this bridge pins `darkAqua` on itself: the theme tokens
//  inside resolve to the dark palette in both app appearances, matching
//  ref_chat_dark and the §7.5 fixed-dark call surface. Un-pin here if in-call
//  panels should ever follow the app theme.
//

import AppKit
import SwiftUI

@objc(InterChatHostView)
public final class InterChatHostView: NSView {

    private let viewModel = ChatViewModel()
    private var hosting: NSHostingView<ChatView>!

    /// Fired when the user submits a message.
    @objc public var onSend: ((String) -> Void)?
    /// Fired when the user picks a DM recipient (nil = Everyone).
    @objc public var onSelectRecipient: ((String?) -> Void)?
    /// Fired when the user clicks the attach button.
    @objc public var onAttach: (() -> Void)?
    /// Fired when the user requests a transcript export.
    @objc public var onExport: (() -> Void)?
    /// Fired when the user clicks Save… on a file message.
    @objc public var onDownload: ((InterChatMessageInfo) -> Void)?
    /// Fired when the user clicks the header close button.
    @objc public var onClose: (() -> Void)?

    @objc public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure() {
        // Fixed-dark in-call surface (see header comment).
        appearance = NSAppearance(named: .darkAqua)

        viewModel.onSend = { [weak self] text in self?.onSend?(text) }
        viewModel.onSelectRecipient = { [weak self] identity in self?.onSelectRecipient?(identity) }
        viewModel.onAttach = { [weak self] in self?.onAttach?() }
        viewModel.onExport = { [weak self] in self?.onExport?() }
        viewModel.onDownload = { [weak self] message in self?.onDownload?(message) }
        viewModel.onClose = { [weak self] in self?.onClose?() }

        let host = NSHostingView(rootView: ChatView(viewModel: viewModel))
        host.translatesAutoresizingMaskIntoConstraints = false
        self.hosting = host
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Legacy InterChatPanel API (forwarded to the view model)

    @objc public func appendMessage(_ message: InterChatMessageInfo) {
        viewModel.append(message)
    }

    /// Participants as [{"identity": …, "name": …}] — the legacy list shape.
    @objc public func setParticipantList(_ participants: [[String: String]]) {
        let recipients = participants.compactMap { dict -> ChatRecipient? in
            guard let identity = dict["identity"], !identity.isEmpty else { return nil }
            return ChatRecipient(identity: identity, name: dict["name"] ?? "Unknown")
        }
        viewModel.setParticipants(recipients)
    }

    @objc public func setChatInputEnabled(_ enabled: Bool) {
        viewModel.setInputEnabled(enabled)
    }

    @objc public func setExportButtonHidden(_ hidden: Bool) {
        viewModel.setExportVisible(!hidden)
    }

    @objc public func setUploadInProgress(_ inProgress: Bool) {
        viewModel.setUploading(inProgress)
    }

    /// Focus the composer input (called by the shell when the panel expands).
    @objc public func focusInput() {
        viewModel.requestInputFocus()
    }
}
