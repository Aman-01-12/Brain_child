//
//  InterScheduleHostView.swift
//  inter
//
//  Obj-C ⇆ SwiftUI bridge for the Schedule screen. An NSView that hosts
//  `ScheduleView` and re-exposes exactly the surface the legacy
//  `InterSchedulePanel` had: block callbacks for the delegate actions plus
//  `setUpcomingMeetings:` / `setInvitedMeetings:` / `resetForm` /
//  `setStatusText:` / `setSubmitting:` forwarders. The thin Obj-C shell keeps
//  its public `.h` and delegate contract, so AppDelegate's wiring is unchanged.
//

import AppKit
import SwiftUI

@objc(InterScheduleHostView)
public final class InterScheduleHostView: NSView {

    private let viewModel = ScheduleViewModel()
    private var hosting: NSHostingView<ScheduleView>!

    /// Fired when the user submits the schedule form.
    @objc public var onSchedule: ((_ title: String, _ scheduledAt: Date, _ durationMinutes: Int,
                                   _ roomType: String, _ timezone: String, _ password: String?,
                                   _ lobbyEnabled: Bool, _ inviteeEmails: [String]) -> Void)?
    /// Fired when the user cancels a hosted meeting.
    @objc public var onCancelMeeting: ((String) -> Void)?
    /// Fired when the user joins a meeting (roomCode, meetingId).
    @objc public var onJoin: ((String, String) -> Void)?

    @objc public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure() {
        viewModel.onSchedule = { [weak self] title, when, duration, roomType, tz, pw, lobby, emails in
            self?.onSchedule?(title, when, duration, roomType, tz, pw, lobby, emails)
        }
        viewModel.onCancelMeeting = { [weak self] meetingId in self?.onCancelMeeting?(meetingId) }
        viewModel.onJoin = { [weak self] code, meetingId in self?.onJoin?(code, meetingId) }

        let host = NSHostingView(rootView: ScheduleView(viewModel: viewModel))
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

    // MARK: - Legacy InterSchedulePanel API (forwarded to the view model)

    @objc public func setUpcomingMeetings(_ meetings: [InterScheduledMeeting]) {
        viewModel.setUpcomingMeetings(meetings)
    }

    @objc public func setInvitedMeetings(_ meetings: [InterScheduledMeeting]) {
        viewModel.setInvitedMeetings(meetings)
    }

    @objc public func resetForm() {
        viewModel.resetForm()
    }

    @objc public func setStatusText(_ text: String) {
        viewModel.statusText = text
        if !text.isEmpty { viewModel.isSubmitting = false }
    }

    @objc public func setSubmitting(_ submitting: Bool) {
        viewModel.isSubmitting = submitting
    }
}
