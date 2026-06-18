//
//  HomeView.swift
//  inter
//
//  SwiftUI home / launch screen — the app's front door. Visual language follows
//  the design handoff (ref_connection_{dark,light}.png / ConnectionSetupMock.tsx):
//  greeting + identity strip, primary action tiles, join-by-code row, hosted
//  room-code banner, and the meeting list. Per the council-approved decisions:
//    • Tiles: New Meeting / Join / Schedule / Teams (Share had no backing
//      feature; Teams earns the slot).
//    • Search + "Personal Meeting ID" omitted (no backing features).
//    • Server/token URL fields REMOVED — endpoints come from InterAppConfig.
//    • Account/billing/sign-out live under the avatar menu (top-right).
//    • The meeting list is REAL history (GET /meetings/history), with an
//      engaging empty state for first-time users.
//    • Signed-out: join works for guests (inline name field); host/schedule/
//      teams render disabled with a sign-in hint. Offline-with-session keeps
//      identity + Sign Out, disables server actions, shows reconnecting copy.
//

import SwiftUI

struct HomeView: View {
    @ObservedObject var viewModel: HomeViewModel
    @Environment(\.colorScheme) private var colorScheme

    @FocusState private var codeFocused: Bool
    @State private var joinExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            // The avatar menu lives in the WINDOW TITLEBAR (NSTitlebarAccessory
            // via the host view) so it sits beside the traffic lights AND is
            // fully clickable — SwiftUI views under the titlebar band lose
            // part of their hit area to the window drag region.
            ScrollView {
                VStack(alignment: .leading, spacing: InterSpacing.x5) {
                    clockHero
                    tiles
                    if !viewModel.hostedRoomCode.isEmpty { hostedCodeBanner }
                    if joinExpanded { joinRow }
                    if !viewModel.statusText.isEmpty || !viewModel.billingStatusText.isEmpty {
                        statusLines
                    }
                    eventsSection
                    meetingsSection
                }
                .padding(.horizontal, InterSpacing.x6)
                .padding(.bottom, InterSpacing.x6)
                .padding(.top, InterSpacing.x2)
                .interTitlebarInset()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: InterColor.card))
        .ignoresSafeArea(.container, edges: .top)
        .interResignsFocusOnBackgroundTap()
    }

    // MARK: - Clock hero (big time + date, Zoom home pattern)

    private var clockHero: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: InterSpacing.x2) {
                Text(HomeView.clockFormatter.string(from: context.date))
                    .font(.system(size: 56, weight: .bold))
                    .foregroundColor(Color(nsColor: InterColor.foreground))
                Text(HomeView.dateFormatter.string(from: context.date))
                    .font(InterFont.swiftUI(16))
                    .foregroundColor(Color(nsColor: InterColor.mutedForeground))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, InterSpacing.x4)
        }
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM"
        return f
    }()

    // MARK: - Action tiles (icon squares, labels below — Zoom home pattern)

    private var tiles: some View {
        VStack(spacing: InterSpacing.x5) {
            HStack(alignment: .top, spacing: InterSpacing.x8) {
                HomeTile(icon: "video.fill", label: "New Meeting", style: .primary,
                         enabled: viewModel.canUseAuthenticatedActions,
                         hint: viewModel.isSignedIn ? nil : "Sign in to host",
                         action: { viewModel.onHostCall?() })
                HomeTile(icon: "plus", label: "Join", style: .secondary,
                         enabled: viewModel.actionsEnabled,
                         hint: nil,
                         action: {
                    joinExpanded.toggle()
                    if joinExpanded { codeFocused = true }
                })
                HomeTile(icon: "calendar", label: "Schedule", style: .secondary,
                         enabled: viewModel.canUseAuthenticatedActions,
                         hint: viewModel.isSignedIn ? nil : "Sign in to schedule",
                         action: { viewModel.onSchedule?() })
            }
            HStack(alignment: .top, spacing: InterSpacing.x8) {
                HomeTile(icon: "person.3.fill", label: "Teams", style: .secondary,
                         enabled: viewModel.canUseAuthenticatedActions,
                         hint: viewModel.isSignedIn ? nil : "Sign in to use Teams",
                         action: { viewModel.onTeams?() })
                HomeTile(icon: "briefcase.fill", label: "Host Interview", style: .amber,
                         badge: viewModel.interviewRequiresPro ? "HIRING" : nil,
                         enabled: viewModel.canUseAuthenticatedActions,
                         hint: viewModel.interviewRequiresPro
                             ? "Host Interview — Hiring plan required"
                             : (viewModel.isSignedIn ? nil : "Sign in to host interviews"),
                         action: { viewModel.onHostInterview?() })
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, InterSpacing.x3)
    }

    // MARK: - Hosted room code banner

    private var hostedCodeBanner: some View {
        HStack(spacing: InterSpacing.x2) {
            Text("Room:")
                .font(InterFont.swiftUI(12, .medium))
                .foregroundColor(Color(nsColor: InterStatus.success))
            Text(viewModel.hostedRoomCode)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(Color(nsColor: InterStatus.success))
                .tracking(2)
            Spacer()
            Button("Copy code") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(viewModel.hostedRoomCode, forType: .string)
            }
            .buttonStyle(.plain)
            .font(InterFont.swiftUI(11, .medium))
            .foregroundColor(Color(nsColor: InterStatus.success))
            .handCursor()
        }
        .padding(.horizontal, InterSpacing.x3)
        .padding(.vertical, InterSpacing.x2)
        .background(
            RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                .fill(Color(nsColor: InterStatus.success).opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                    .strokeBorder(Color(nsColor: InterStatus.success).opacity(0.3), lineWidth: 1))
        )
    }

    // MARK: - Join row (guest name when signed out + code + CTA; shown on demand)

    private var joinRow: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x2) {
            if viewModel.authState == .signedOut || viewModel.authState == .connecting {
                InterInputField(placeholder: "Your name (for joining as a guest)",
                                text: $viewModel.guestName)
            }
            HStack(spacing: InterSpacing.x2) {
                TextField("Enter room code — e.g. X7K29M", text: $viewModel.joinCode)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .focused($codeFocused)
                    .onSubmit { viewModel.submitJoin() }
                    .interFieldChrome(isFocused: codeFocused)
                InterButton("Join with Room Code", variant: .primary, size: .medium,
                            enabled: viewModel.canJoin,
                            action: { viewModel.submitJoin() })
            }
        }
    }

    // MARK: - Status lines (join errors get a loud banner; progress stays subtle)

    private var statusLines: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x1_5) {
            if !viewModel.statusText.isEmpty {
                if viewModel.indicator == 3 {
                    // Error — impossible to miss (the muted caption was overlooked).
                    InterBanner(viewModel.statusText, variant: .error)
                } else {
                    Text(viewModel.statusText)
                        .font(InterFont.swiftUI(11, .medium))
                        .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                }
            }
            if !viewModel.billingStatusText.isEmpty {
                Text(viewModel.billingStatusText)
                    .font(InterFont.swiftUI(11, .medium))
                    .foregroundColor(Color(nsColor: InterStatus.warning))
            }
        }
    }

    // MARK: - Today's events (above RECENT — Zoom calendar strip)

    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x2) {
            HStack {
                Text(HomeViewModel.todayHeaderLabel())
                    .font(InterFont.swiftUI(13, .semibold))
                    .foregroundColor(Color(nsColor: InterColor.foreground))
                Spacer()
                Button(action: { viewModel.onSchedule?() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .handCursor()
                .disabled(!viewModel.canUseAuthenticatedActions)
                .help("Schedule a meeting")
            }

            if viewModel.upcomingToday.isEmpty {
                // Flat empty state — one surface, no box-in-box.
                VStack(spacing: InterSpacing.x1_5) {
                    Text("No events scheduled.")
                        .font(InterFont.swiftUI(13))
                        .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                    Button(action: { viewModel.onSchedule?() }) {
                        HStack(spacing: InterSpacing.x1) {
                            Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                            Text("Schedule an event").font(InterFont.swiftUI(12, .medium))
                        }
                        .foregroundColor(Color(nsColor: InterColor.primary))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .handCursor()
                    .disabled(!viewModel.canUseAuthenticatedActions)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, InterSpacing.x4)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.upcomingToday.enumerated()), id: \.element.id) { index, event in
                        eventRow(event)
                        if index < viewModel.upcomingToday.count - 1 {
                            Divider().overlay(Color(nsColor: InterColor.border).opacity(0.6))
                                .padding(.leading, 44)
                        }
                    }
                }
            }
        }
    }

    private func eventRow(_ event: HomeUpcomingMeeting) -> some View {
        HomeHoverRow {
            HStack(spacing: InterSpacing.x3) {
                RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                    .fill(Color(nsColor: InterColor.primary).opacity(0.14))
                    .frame(width: 32, height: 32)
                    .overlay(Image(systemName: "calendar")
                        .font(.system(size: 13))
                        .foregroundColor(Color(nsColor: InterColor.primary)))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: InterSpacing.x1_5) {
                        Text(event.title)
                            .font(InterFont.swiftUI(13, .medium))
                            .foregroundColor(Color(nsColor: InterColor.foreground))
                            .lineLimit(1)
                        if event.isHosted {
                            Text("Hosting")
                                .font(InterFont.swiftUI(9, .semibold))
                                .foregroundColor(Color(nsColor: InterColor.primary))
                                .padding(.horizontal, InterSpacing.x1_5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color(nsColor: InterColor.primary).opacity(0.14)))
                        }
                    }
                    Text("\(HomeView.clockFormatter.string(from: event.scheduledAt)) · \(event.durationMinutes)m")
                        .font(InterFont.swiftUI(11))
                        .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                }
                Spacer(minLength: InterSpacing.x2)
                if event.roomCode?.isEmpty == false {
                    InterButton(event.isHosted ? "Start" : "Join",
                                variant: .primary, size: .small,
                                enabled: viewModel.actionsEnabled,
                                action: { viewModel.joinUpcoming(event) })
                }
            }
        }
    }

    // MARK: - Meetings (real history, capped at the last 4)

    private var meetingsSection: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x2) {
            Text("RECENT")
                .font(InterFont.swiftUI(11, .semibold))
                .tracking(0.8)
                .foregroundColor(Color(nsColor: InterColor.mutedForeground))

            if !viewModel.isSignedIn && viewModel.authState != .offlineWithSession {
                emptyMeetings("Sign in to see your meeting history here.")
            } else if viewModel.historyLoaded && viewModel.history.isEmpty {
                emptyMeetings("No meeting history yet! Create or join one from above.")
            } else if !viewModel.historyLoaded {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, InterSpacing.x4)
            } else {
                LazyVStack(spacing: InterSpacing.x1) {
                    ForEach(viewModel.history.prefix(4)) { item in
                        HomeHistoryRow(item: item)
                    }
                }
            }
        }
    }

    private func emptyMeetings(_ message: String) -> some View {
        // Flat empty state — same surface as the page (no box-in-box).
        VStack(spacing: InterSpacing.x2) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 22))
                .foregroundColor(Color(nsColor: InterColor.mutedForeground).opacity(0.6))
            Text(message)
                .font(InterFont.swiftUI(13))
                .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, InterSpacing.x6)
    }
}

// MARK: - Hover row (flat list row with a hover highlight)

private struct HomeHoverRow<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        content()
            .padding(.horizontal, InterSpacing.x2_5)
            .padding(.vertical, InterSpacing.x2)
            .background(
                RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                    .fill(hovering ? Color(nsColor: InterColor.muted) : .clear)
            )
            .onHover { hovering = $0 }
    }
}

// MARK: - Avatar menu (hosted in the window titlebar accessory)

struct HomeAvatarMenuView: View {
    @ObservedObject var viewModel: HomeViewModel
    @State private var menuOpen = false

    var body: some View {
        Button(action: { menuOpen.toggle() }) {
            avatarChip(size: 30)
                .padding(.horizontal, InterSpacing.x1)
                .frame(height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .help(viewModel.isSignedIn ? viewModel.displayName : "Account")
        // Inset the chip's trailing edge by the WINDOW corner radius so its rounded
        // corner is concentric with the window's top-right corner (both radii on the
        // same diagonal). Window-sized surfaces use InterRadius.xxl (10) in the re-tuned
        // scale — InterRadius.lg is only 6, which sat too far from the corner.
        .padding(.trailing, InterRadius.xxl)
        .interDropdown(isPresented: $menuOpen, alignment: .trailing) {
            InterMenuContainer(minWidth: 200) {
                switch viewModel.authState {
                case .signedIn, .offlineWithSession:
                    InterMenuRow(title: "Settings…", icon: "gearshape") {
                        menuOpen = false
                        viewModel.onSettings?()
                    }
                    InterMenuRow(title: "Manage Subscription…", icon: "creditcard") {
                        menuOpen = false
                        // Free tier lands on the plans page; paid tiers open the portal.
                        if viewModel.isPaidTier { viewModel.onManageSubscription?() }
                        else { viewModel.onViewPlans?() }
                    }
                    InterMenuSeparator()
                    InterMenuRow(title: "Sign Out", icon: "rectangle.portrait.and.arrow.right",
                                 destructive: true) {
                        menuOpen = false
                        viewModel.onSignOut?()
                    }
                case .signedOut, .connecting:
                    InterMenuRow(title: "Sign In / Sign Up…", icon: "person.crop.circle.badge.plus") {
                        menuOpen = false
                        viewModel.onSignIn?()
                    }
                    InterMenuSeparator()
                    InterMenuRow(title: "Settings…", icon: "gearshape") {
                        menuOpen = false
                        viewModel.onSettings?()
                    }
                }
            }
        }
    }

    /// Zoom-style avatar: continuous-corner rounded square; presence dot
    /// straddles the top-right corner (half outside) with a chrome-colored ring.
    private func avatarChip(size: CGFloat) -> some View {
        let signedIsh = viewModel.authState == .signedIn || viewModel.authState == .offlineWithSession
        let dotColor: NSColor = {
            switch viewModel.authState {
            case .signedIn:           return InterStatus.success
            case .offlineWithSession,
                 .connecting:         return InterStatus.warning
            case .signedOut:          return InterColor.mutedForeground
            }
        }()
        return RoundedRectangle(cornerRadius: InterRadius.bubble, style: .continuous)
            .fill(signedIsh ? Color(nsColor: InterColor.primary) : Color(nsColor: InterColor.secondary))
            .frame(width: size, height: size)
            .overlay(
                Group {
                    if signedIsh {
                        Text(HomeViewModel.initials(from: viewModel.displayName))
                            .font(InterFont.swiftUI(size * 0.4, .bold))
                            .foregroundColor(.white)
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: size * 0.45))
                            .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                    }
                }
            )
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(Color(nsColor: dotColor))
                    .frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(Color(nsColor: InterColor.card), lineWidth: 2))
                    .offset(x: 4, y: -4)
            }
            .padding(.top, 4)      // room for the overhanging dot
            .padding(.trailing, 4)
            .accessibilityLabel("Account status")
    }
}

// MARK: - One action tile (icon square + label below)

private struct HomeTile: View {
    enum Style { case primary, secondary, amber }

    let icon: String
    let label: String
    let style: Style
    var badge: String? = nil
    let enabled: Bool
    let hint: String?
    var action: () -> Void

    @State private var hovering = false

    private var fill: Color {
        switch style {
        case .primary:   return Color(nsColor: InterColor.primary).opacity(hovering && enabled ? 0.85 : 1)
        case .amber:     return Color(nsColor: InterStatus.warning).opacity(hovering && enabled ? 0.85 : 1)
        case .secondary: return Color(nsColor: hovering && enabled ? InterColor.muted : InterColor.secondary)
        }
    }

    private var iconColor: Color {
        switch style {
        case .primary, .amber: return .white
        case .secondary:       return Color(nsColor: InterColor.foreground)
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: InterSpacing.x2) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(fill)
                    .frame(width: 56, height: 56)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(iconColor)
                    )
                    .overlay(alignment: .topTrailing) {
                        if let badge = badge {
                            Text(badge)
                                .font(InterFont.swiftUI(8, .bold))
                                .tracking(0.5)
                                .foregroundColor(.white)
                                .padding(.horizontal, InterSpacing.x1_5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color(nsColor: InterColor.secondary)))
                                .overlay(Capsule().strokeBorder(Color(nsColor: InterColor.card), lineWidth: 1.5))
                                .offset(x: 10, y: -7)
                        }
                    }
                Text(label)
                    .font(InterFont.swiftUI(12, .medium))
                    .foregroundColor(Color(nsColor: InterColor.foreground))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .onHover { hovering = $0 }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .help(hint ?? label)
        .accessibilityLabel(hint.map { "\(label) — \($0)" } ?? label)
    }
}

// MARK: - One history row

private struct HomeHistoryRow: View {
    let item: HomeMeetingHistoryItem

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: InterSpacing.x3) {
            RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                .fill(Color(nsColor: InterColor.primary).opacity(0.14))
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: item.roomType == "interview" ? "briefcase.fill" : "video.fill")
                        .font(.system(size: 13))
                        .foregroundColor(Color(nsColor: InterColor.primary))
                )
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: InterSpacing.x1_5) {
                    Text(item.roomName)
                        .font(InterFont.swiftUI(13, .medium))
                        .foregroundColor(Color(nsColor: InterColor.foreground))
                        .lineLimit(1)
                    if item.status == "active" {
                        Text("Live")
                            .font(InterFont.swiftUI(9, .bold))
                            .foregroundColor(Color(nsColor: InterStatus.success))
                            .padding(.horizontal, InterSpacing.x1_5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color(nsColor: InterStatus.success).opacity(0.14)))
                    }
                    if item.role == "host" {
                        Text("Hosted")
                            .font(InterFont.swiftUI(9, .semibold))
                            .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                            .padding(.horizontal, InterSpacing.x1_5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color(nsColor: InterColor.secondary)))
                    }
                }
                HStack(spacing: InterSpacing.x1) {
                    Image(systemName: "clock").font(.system(size: 9))
                    Text(HomeViewModel.historyTimeLabel(item.startedAt))
                    if let mins = item.durationMinutes {
                        Text("· \(mins)m")
                    }
                    Text("·")
                    Image(systemName: "person.2").font(.system(size: 9))
                    Text("\(item.participantCount)")
                }
                .font(InterFont.swiftUI(11))
                .foregroundColor(Color(nsColor: InterColor.mutedForeground))
            }
            Spacer(minLength: InterSpacing.x2)
            if hovering {
                HStack(spacing: InterSpacing.x1) {
                    Text(item.roomCode)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.roomCode, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundColor(copied
                                ? Color(nsColor: InterStatus.success)
                                : Color(nsColor: InterColor.mutedForeground))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .handCursor()
                    .help("Copy room code")
                }
            }
        }
        .padding(.horizontal, InterSpacing.x2_5)
        .padding(.vertical, InterSpacing.x2)
        .background(
            RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                .fill(hovering ? Color(nsColor: InterColor.muted) : .clear)
        )
        .onHover { hovering = $0 }
    }
}
