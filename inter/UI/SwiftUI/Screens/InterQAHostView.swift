//
//  InterQAHostView.swift
//  inter
//
//  Obj-C ⇆ SwiftUI bridge for the Q&A panel. An NSView that hosts `QAView` and
//  re-exposes exactly the surface the legacy `InterQAPanel` needs: block
//  callbacks for the delegate actions plus `setQuestions:` / `isHost`
//  forwarders. The thin Obj-C `InterQAPanel` shell keeps its public `.h` and
//  delegate contract, so `AppDelegate`'s Q&A wiring is unchanged.
//

import AppKit
import SwiftUI

@objc(InterQAHostView)
public final class InterQAHostView: NSView {

    private let viewModel = QAViewModel()
    private var hosting: NSHostingView<QAView>!

    /// Fired when the user submits a question (text, isAnonymous).
    @objc public var onSubmit: ((String, Bool) -> Void)?
    /// Fired when the user upvotes a question.
    @objc public var onUpvote: ((String) -> Void)?
    /// Fired when the host highlights a question.
    @objc public var onHighlight: ((String) -> Void)?
    /// Fired when the host marks a question answered.
    @objc public var onMarkAnswered: ((String) -> Void)?
    /// Fired when the host dismisses a question.
    @objc public var onDismissQuestion: ((String) -> Void)?

    @objc public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure() {
        viewModel.onSubmit = { [weak self] text, anon in self?.onSubmit?(text, anon) }
        viewModel.onUpvote = { [weak self] id in self?.onUpvote?(id) }
        viewModel.onHighlight = { [weak self] id in self?.onHighlight?(id) }
        viewModel.onMarkAnswered = { [weak self] id in self?.onMarkAnswered?(id) }
        viewModel.onDismiss = { [weak self] id in self?.onDismissQuestion?(id) }

        let host = NSHostingView(rootView: QAView(viewModel: viewModel))
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

    // MARK: - Legacy InterQAPanel API (forwarded to the view model)

    @objc public func setQuestions(_ questions: [InterQuestionInfo]) {
        viewModel.setQuestions(questions)
    }

    @objc public var isHost: Bool {
        get { viewModel.isHost }
        set { viewModel.isHost = newValue }
    }
}
