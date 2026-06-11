//
//  InterLobbyWaitingBridgeView.swift
//  inter
//
//  Obj-C ⇆ SwiftUI bridge for the participant-side waiting room. Hosts `LobbyWaitingView`
//  and re-exposes the legacy `InterLobbyWaitingView` API (the five state transitions +
//  position + status message + cancel) so `AppDelegate`'s polling/admission flow is unchanged.
//

import AppKit
import SwiftUI

@objc(InterLobbyWaitingBridgeView)
public final class InterLobbyWaitingBridgeView: NSView {

    private let viewModel = LobbyWaitingViewModel()

    /// Cancel / Leave / OK tapped.
    @objc public var onCancel: (() -> Void)?

    @objc public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure() {
        appearance = NSAppearance(named: .darkAqua)
        viewModel.onCancel = { [weak self] in self?.onCancel?() }

        let host = NSHostingView(rootView: LobbyWaitingView(viewModel: viewModel))
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: Legacy InterLobbyWaitingView API (forwarded to the view model)

    @objc public func showJoining() {
        viewModel.customMessage = nil
        viewModel.state = .joining
    }

    @objc public func showWaiting() {
        viewModel.customMessage = nil
        viewModel.state = .waiting
    }

    @objc public func setPosition(_ position: Int) {
        viewModel.position = max(0, position)
    }

    @objc public func setStatusMessage(_ message: String) {
        viewModel.customMessage = message
    }

    @objc public func showDenied() {
        viewModel.customMessage = nil
        viewModel.state = .denied
    }

    @objc public func showAdmitted() {
        viewModel.customMessage = nil
        viewModel.state = .admitted
    }
}
