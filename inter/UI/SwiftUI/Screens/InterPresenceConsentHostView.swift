//
//  InterPresenceConsentHostView.swift
//  inter
//
//  PRESENCE MONITORING (provisional, server flag default OFF).
//
//  Obj-C ⇆ SwiftUI bridge for the candidate consent screen, built on the
//  InterGreenRoomHostView shape: an NSView that owns one NSHostingView, forces
//  darkAqua (the stage is fixed-dark in both app appearances) and vends a single
//  block callback. AppDelegate puts it in an NSWindow; SecureWindowController
//  puts the details variant in an NSPanel above the secure window.
//
//  UNLIKE InterGreenRoomHostView this host owns NO infrastructure at all — no
//  InterLocalMediaController, no capture session, no preview, no timers. The
//  consent screen is text and three buttons. That is deliberate: a screen whose
//  job is to ask permission for a camera-derived check must not be able to start
//  one (research memo §7.8).
//
//  Delete this file with the rest of the triad to remove the screen.
//  See .agents/tasks/presence-monitoring/REMOVAL.md.
//

import AppKit
import SwiftUI

@objc(InterPresenceConsentHostView)
public final class InterPresenceConsentHostView: NSView {

    private let viewModel: PresenceConsentViewModel
    private var hosting: NSHostingView<PresenceConsentView>!

    /// Fires once with the raw `PresenceConsentDecision`:
    /// 0 = cancel and leave, 1 = join with monitoring, 2 = join with monitoring off.
    @objc public var onDecision: ((Int) -> Void)?

    /// Fires when a details-only presentation asks to close.
    @objc public var onCloseDetails: (() -> Void)?

    /// Pre-join consent screen.
    /// - Parameter mode: raw `PresenceConsentMode` — 1 monitored offer,
    ///   2 monitoring-off notice. 0 (`legacyAlert`) must never reach here; it is
    ///   treated as the monitoring-off notice so a programming error cannot
    ///   accidentally present the monitored offer.
    @objc public init(frame frameRect: NSRect,
                      mode: Int,
                      retentionDays: Int,
                      rightsContact: String,
                      externalDisplayPolicy: Bool) {
        let resolved: PresenceConsentMode = (mode == PresenceConsentMode.monitoredOffer.rawValue)
            ? .monitoredOffer
            : .monitoringOffNotice
        self.viewModel = PresenceConsentViewModel(mode: resolved,
                                                  retentionDays: retentionDays,
                                                  rightsContact: rightsContact,
                                                  externalDisplayPolicy: externalDisplayPolicy)
        super.init(frame: frameRect)
        appearance = NSAppearance(named: .darkAqua) // fixed-dark stage surface
        configure()
    }

    /// Mid-session details sheet — the SAME copy, read-only, no decision.
    /// `monitoringState` is the chrome chip's state (0 absent / 1 on / 2 off /
    /// 3 paused because the camera is off).
    @objc public init(detailsWithFrame frameRect: NSRect,
                      monitoringState: Int,
                      retentionDays: Int,
                      rightsContact: String,
                      externalDisplayPolicy: Bool) {
        self.viewModel = PresenceConsentViewModel(mode: .monitoredOffer,
                                                  retentionDays: retentionDays,
                                                  rightsContact: rightsContact,
                                                  externalDisplayPolicy: externalDisplayPolicy,
                                                  detailsOnly: true,
                                                  monitoringState: monitoringState)
        super.init(frame: frameRect)
        appearance = NSAppearance(named: .darkAqua)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure() {
        viewModel.onDecision = { [weak self] decision in
            self?.onDecision?(decision.rawValue)
        }
        viewModel.onDismissDetails = { [weak self] in
            self?.onCloseDetails?()
        }

        let host = NSHostingView(rootView: PresenceConsentView(viewModel: viewModel))
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

    /// Keeps an open details sheet in step with the chrome chip.
    @objc public func setMonitoringState(_ state: Int) {
        viewModel.setMonitoringState(state)
    }

    /// Drops the decision blocks so none outlives the window (paranoid #8).
    @objc public func invalidateHandlers() {
        onDecision = nil
        onCloseDetails = nil
        viewModel.onDecision = nil
        viewModel.onDismissDetails = nil
    }

    /// Whether the given arming flags should produce this screen at all. Exposed
    /// to Obj-C so the one guarded call site in AppDelegate reads the same pure
    /// function the tests enumerate.
    @objc public static func presentableMode(armed: Bool, regionEU: Bool, under18: Bool) -> Int {
        PresenceConsentViewModel.mode(armed: armed, regionEU: regionEU, under18: under18).rawValue
    }
}
