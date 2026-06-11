//
//  InterLobbyPanelBridgeView.swift
//  inter
//
//  Obj-C ⇆ SwiftUI bridge for the host-side waiting room. An NSView that hosts
//  `LobbyHostView` and re-exposes exactly the surface the legacy `InterLobbyPanel` had —
//  the mutation API (add/remove/clear/count, lobby on-off, co-host toggle-enable) and the
//  admit/deny/admit-all/toggle callbacks — so `InterLobbyPanel` keeps its `.h` + delegate
//  contract and `AppDelegate` is unchanged.
//

import AppKit
import SwiftUI

@objc(InterLobbyPanelBridgeView)
public final class InterLobbyPanelBridgeView: NSView {

    private let viewModel = LobbyHostViewModel()

    @objc public var onAdmit: ((String, String) -> Void)?
    @objc public var onDeny: ((String) -> Void)?
    @objc public var onAdmitAll: (() -> Void)?
    @objc public var onToggleLobby: ((Bool) -> Void)?

    @objc public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure() {
        appearance = NSAppearance(named: .darkAqua) // floats over the dark call stage

        viewModel.onAdmit = { [weak self] id, name in self?.onAdmit?(id, name) }
        viewModel.onDeny = { [weak self] id in self?.onDeny?(id) }
        viewModel.onAdmitAll = { [weak self] in self?.onAdmitAll?() }
        viewModel.onToggleLobby = { [weak self] on in self?.onToggleLobby?(on) }

        let host = NSHostingView(rootView: LobbyHostView(viewModel: viewModel))
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: Legacy InterLobbyPanel API (forwarded to the view model)

    @objc public func addWaitingParticipant(_ identity: String, displayName: String) {
        viewModel.add(identity: identity, displayName: displayName)
    }

    @objc public func removeWaitingParticipant(_ identity: String) {
        viewModel.remove(identity: identity)
    }

    @objc public func clearWaitingList() {
        viewModel.clear()
    }

    @objc public var waitingCount: Int { viewModel.count }

    @objc public var lobbyEnabled: Bool {
        get { viewModel.lobbyEnabled }
        set { viewModel.lobbyEnabled = newValue } // programmatic set: no callback (matches legacy setter)
    }

    @objc public func setLobbyToggleEnabled(_ enabled: Bool) {
        viewModel.lobbyToggleEnabled = enabled
    }
}
