//
//  InterHomeHostView.swift
//  inter
//
//  Obj-C ⇆ SwiftUI bridge for the home / launch screen. Hosts `HomeView` and
//  re-exposes the legacy `InterConnectionSetupPanel` surface (readonly
//  serverURL/tokenServerURL/displayName/roomCode + the indicator/status/
//  hosted-code/actions setters) so AppDelegate's ~40 call sites keep working
//  unchanged, plus the consolidated chrome (auth/billing/schedule/teams) that
//  used to be loose AppKit buttons around the panel.
//
//  Server endpoints come from InterAppConfig (global rule: config never lives
//  in UI). The guest display name persists across launches via the same
//  UserDefaults key the legacy panel used.
//

import AppKit
import SwiftUI
import Combine

@objc(InterHomeHostView)
public final class InterHomeHostView: NSView {

    private let viewModel = HomeViewModel()
    private var hosting: NSHostingView<HomeView>!
    private weak var tokenService: InterTokenService?
    private var cancellables = Set<AnyCancellable>()

    private static let guestNameDefaultsKey = "InterDefaultDisplayName"

    // MARK: - Action callbacks (assigned by the thin shell / AppDelegate)

    @objc public var onHostCall: (() -> Void)?
    @objc public var onHostInterview: (() -> Void)?
    @objc public var onJoin: (() -> Void)?
    @objc public var onOpenSchedule: (() -> Void)?
    @objc public var onOpenTeams: (() -> Void)?
    @objc public var onSignIn: (() -> Void)?
    @objc public var onSignOut: (() -> Void)?
    @objc public var onOpenSettings: (() -> Void)?
    @objc public var onOpenAccountSettings: (() -> Void)?
    @objc public var onViewPlans: (() -> Void)?
    @objc public var onManageSubscription: (() -> Void)?
    /// Join a scheduled meeting from the Today strip (roomCode, meetingId, isHosted).
    @objc public var onJoinScheduledMeeting: ((String, String, Bool) -> Void)?

    @objc public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure() {
        viewModel.onHostCall = { [weak self] in self?.onHostCall?() }
        viewModel.onHostInterview = { [weak self] in self?.onHostInterview?() }
        viewModel.onJoin = { [weak self] in self?.onJoin?() }
        viewModel.onSchedule = { [weak self] in self?.onOpenSchedule?() }
        viewModel.onTeams = { [weak self] in self?.onOpenTeams?() }
        viewModel.onSignIn = { [weak self] in self?.onSignIn?() }
        viewModel.onSignOut = { [weak self] in self?.onSignOut?() }
        viewModel.onSettings = { [weak self] in self?.onOpenSettings?() }
        viewModel.onAccountSettings = { [weak self] in self?.onOpenAccountSettings?() }
        viewModel.onViewPlans = { [weak self] in self?.onViewPlans?() }
        viewModel.onManageSubscription = { [weak self] in self?.onManageSubscription?() }
        viewModel.onLoadHistory = { [weak self] in self?.loadHistory() }
        viewModel.onJoinScheduledMeeting = { [weak self] code, meetingId, isHosted in
            self?.onJoinScheduledMeeting?(code, meetingId, isHosted)
        }

        // Guest-name continuity with the legacy panel's persisted display name.
        let saved = UserDefaults.standard.string(forKey: InterHomeHostView.guestNameDefaultsKey) ?? ""
        viewModel.guestName = saved
        viewModel.$guestName
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { name in
                UserDefaults.standard.set(name, forKey: InterHomeHostView.guestNameDefaultsKey)
            }
            .store(in: &cancellables)

        let host = NSHostingView(rootView: HomeView(viewModel: viewModel))
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

    // MARK: - Configuration + auth chrome

    /// The avatar account menu as a titlebar accessory — keeps it beside the
    /// traffic lights AND fully clickable (content under the titlebar band
    /// loses hit-testing to the window drag region).
    @objc public func makeTitlebarAccessory() -> NSTitlebarAccessoryViewController {
        let controller = NSTitlebarAccessoryViewController()
        let hosting = NSHostingView(rootView: HomeAvatarMenuView(viewModel: viewModel))
        // Size to fit exactly so the chip's own trailing inset (the window corner
        // radius, applied in HomeAvatarMenuView) is the only gap to the edge —
        // no ambiguous extra width that would drift the alignment.
        hosting.frame = NSRect(x: 0, y: 0, width: hosting.fittingSize.width, height: 38)
        controller.view = hosting
        controller.layoutAttribute = .trailing
        return controller
    }

    @objc public func configure(tokenService: InterTokenService?) {
        self.tokenService = tokenService
        refreshAuthChrome()
    }

    /// Re-read the token service and push the auth state into the screen.
    /// Replaces the legacy buildSetupChromeInOverlay re-render: unauthenticated,
    /// authenticated, and offline-with-persisted-session are all first-class.
    @objc public func refreshAuthChrome() {
        guard let ts = tokenService else {
            viewModel.authState = .signedOut
            return
        }
        if ts.isAuthenticated {
            viewModel.authState = .signedIn
            viewModel.displayName = ts.currentDisplayName ?? ""
            viewModel.tier = ts.currentTier ?? "free"
            loadHistory()
            loadUpcoming()
        } else if ts.hasPersistedSession {
            viewModel.authState = .offlineWithSession
            viewModel.displayName = ts.currentDisplayName ?? ""
            viewModel.tier = ts.currentTier ?? "free"
        } else {
            viewModel.authState = .signedOut
            viewModel.tier = "free"
            viewModel.clearHistory()
        }
    }

    // MARK: - Meeting history (GET /meetings/history)

    /// Re-fetch the meeting history + today's events. Called by the host when
    /// they may have changed (window regained key, meeting scheduled/cancelled,
    /// call ended).
    @objc public func reloadMeetings() {
        guard tokenService?.isAuthenticated == true else { return }
        loadHistory()
        loadUpcoming()
    }

    private func loadHistory(retriedAfterAuth: Bool = false) {
        guard let ts = tokenService,
              let token = ts.currentAccessToken, !token.isEmpty,
              let url = URL(string: InterAppConfig.tokenServerURL + "/meetings/history") else {
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self = self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status == 401, !retriedAfterAuth, let ts = self.tokenService {
                ts.refreshAccessToken { ok in
                    if ok { self.loadHistory(retriedAfterAuth: true) }
                }
                return
            }
            guard status == 200, let data = data else { return }
            let items = HomeViewModel.parseHistory(data)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.viewModel.setHistory(items) }
            }
        }.resume()
    }

    // MARK: - Today's events (GET /meetings/upcoming)

    private func loadUpcoming(retriedAfterAuth: Bool = false) {
        guard let ts = tokenService,
              let token = ts.currentAccessToken, !token.isEmpty,
              let url = URL(string: InterAppConfig.tokenServerURL + "/meetings/upcoming") else {
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self = self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status == 401, !retriedAfterAuth, let ts = self.tokenService {
                ts.refreshAccessToken { ok in
                    if ok { self.loadUpcoming(retriedAfterAuth: true) }
                }
                return
            }
            guard status == 200, let data = data else { return }
            let items = HomeViewModel.parseUpcoming(data)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.viewModel.setUpcomingMeetings(items) }
            }
        }.resume()
    }

    // MARK: - Legacy InterConnectionSetupPanel API (forwarded)

    @objc public var serverURL: String { InterAppConfig.liveKitServerURL }
    @objc public var tokenServerURL: String { InterAppConfig.tokenServerURL }
    @objc public var displayName: String { viewModel.effectiveDisplayName }
    @objc public var roomCode: String { viewModel.joinCode }

    @objc public func setIndicatorState(_ state: Int) {
        viewModel.indicator = state
    }

    @objc public func setStatusText(_ text: String) {
        viewModel.statusText = text
    }

    @objc public func showHostedRoomCode(_ code: String?) {
        viewModel.hostedRoomCode = code ?? ""
    }

    @objc public func setActionsEnabled(_ enabled: Bool) {
        viewModel.actionsEnabled = enabled
    }

    @objc public func setRoomCodeText(_ code: String) {
        viewModel.joinCode = code
    }

    @objc public func setHostInterviewButtonRequiresPro(_ requiresPro: Bool) {
        viewModel.interviewRequiresPro = requiresPro
    }

    // MARK: - Billing status (replaces the loose billingStatusLabel / buttons)

    @objc public var billingStatusText: String { viewModel.billingStatusText }

    @objc public func setBillingStatusText(_ text: String) {
        viewModel.billingStatusText = text
    }

    @objc public func setBillingActionEnabled(_ enabled: Bool) {
        viewModel.billingActionEnabled = enabled
    }
}
