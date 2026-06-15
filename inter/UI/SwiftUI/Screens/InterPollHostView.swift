//
//  InterPollHostView.swift
//  inter
//
//  Obj-C ⇆ SwiftUI bridge for the poll panel. An NSView that hosts `PollView`
//  and re-exposes exactly the surface the legacy `InterPollPanel` needs: block
//  callbacks for the delegate actions plus the `showActivePoll:` /
//  `updateResults:` / `showEndedPoll:` / `resetToCreateForm` / `isHost`
//  forwarders. The thin Obj-C `InterPollPanel` shell keeps its public `.h` and
//  delegate contract, so `AppDelegate`'s poll wiring is unchanged.
//

import AppKit
import SwiftUI

@objc(InterPollHostView)
public final class InterPollHostView: NSView {

    private let viewModel = PollViewModel()
    private var hosting: NSHostingView<PollView>!

    /// Fired when the host launches a poll (question, options, isAnonymous, allowMultiSelect).
    @objc public var onLaunch: ((String, [String], Bool, Bool) -> Void)?
    /// Fired when the host ends the active poll.
    @objc public var onEndPoll: (() -> Void)?
    /// Fired when the host shares live results.
    @objc public var onShareResults: (() -> Void)?
    /// Fired when the participant submits a vote (selected option indices).
    @objc public var onSubmitVote: (([NSNumber]) -> Void)?

    @objc public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure() {
        viewModel.onLaunch = { [weak self] question, options, anon, multi in
            self?.onLaunch?(question, options, anon, multi)
        }
        viewModel.onEndPoll = { [weak self] in self?.onEndPoll?() }
        viewModel.onShareResults = { [weak self] in self?.onShareResults?() }
        viewModel.onSubmitVote = { [weak self] indices in
            self?.onSubmitVote?(indices.map { NSNumber(value: $0) })
        }

        let host = NSHostingView(rootView: PollView(viewModel: viewModel))
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

    // MARK: - Legacy InterPollPanel API (forwarded to the view model)

    @objc public func showActivePoll(_ poll: InterPollInfo) {
        viewModel.showActivePoll(poll)
    }

    @objc public func updateResults(_ poll: InterPollInfo) {
        viewModel.updateResults(poll)
    }

    @objc public func showEndedPoll(_ poll: InterPollInfo) {
        viewModel.showEndedPoll(poll)
    }

    @objc public func resetToCreateForm() {
        viewModel.resetToCreateForm()
    }

    @objc public var isHost: Bool {
        get { viewModel.isHost }
        set { viewModel.isHost = newValue }
    }
}
