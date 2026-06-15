//
//  ScheduleView.swift
//  inter
//
//  SwiftUI Schedule screen. Visual language follows the design handoff
//  (ref_schedule_{dark,light}.png / ScheduleMock.tsx): a muted left rail with
//  the month calendar (selected day = violet circle, today = violet ring,
//  meeting-day dots) and the Hosted/Invited upcoming list; a card right pane
//  with the schedule form. Below the schedule-specific fields sits the inline
//  "Meeting settings" section (full list on first use, quick three + Advanced ▸
//  once defaults exist) — see ScheduleViewModel for the flow contract.
//
//  Omitted from the mock (no-dead-controls): "Recurring meeting" (no backend
//  recurrence support) and the "New Meeting" header button (the form is always
//  visible in this layout).
//

import SwiftUI

struct ScheduleView: View {
    @ObservedObject var viewModel: ScheduleViewModel

    var body: some View {
        HStack(spacing: 0) {
            leftRail
            Divider().overlay(Color(nsColor: InterColor.border))
            formPane
        }
        .background(Color(nsColor: InterColor.card))
        .ignoresSafeArea(.container, edges: .top) // seamless chrome
        .interResignsFocusOnBackgroundTap()
    }

    // MARK: - Left rail (calendar + upcoming)

    private var leftRail: some View {
        VStack(spacing: 0) {
            calendarSection
                .interTitlebarInset() // clear the floating traffic lights
            upcomingSection
        }
        .frame(width: 320)
        .background(Color(nsColor: InterColor.muted))
    }

    private var calendarSection: some View {
        VStack(spacing: InterSpacing.x3) {
            HStack {
                monthNavButton("chevron.left") { viewModel.stepMonth(-1) }
                Spacer()
                Text(viewModel.monthTitle)
                    .font(InterFont.swiftUI(15, .semibold))
                    .foregroundColor(Color(nsColor: InterColor.foreground))
                Spacer()
                monthNavButton("chevron.right") { viewModel.stepMonth(1) }
            }

            let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], id: \.self) { d in
                    Text(d)
                        .font(InterFont.swiftUI(11, .semibold))
                        .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                        .frame(height: 22)
                }
                let grid = viewModel.monthGrid
                ForEach(0..<grid.leadingBlanks, id: \.self) { _ in
                    Color.clear.frame(height: 34)
                }
                ForEach(1...grid.dayCount, id: \.self) { day in
                    dayCell(day)
                }
            }
        }
        .padding(.horizontal, InterSpacing.x4)
        .padding(.top, InterSpacing.x4)
        .padding(.bottom, InterSpacing.x2)
    }

    private func monthNavButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
    }

    private func dayCell(_ day: Int) -> some View {
        let isSelected = viewModel.isSelected(day: day)
        let isToday = viewModel.isToday(day: day)
        let hasMeeting = viewModel.meetingDays.contains(day)
        return Button(action: { viewModel.selectDay(day) }) {
            ZStack {
                if isSelected {
                    Circle().fill(Color(nsColor: InterColor.primary))
                } else if isToday {
                    Circle().strokeBorder(Color(nsColor: InterColor.primary).opacity(0.7), lineWidth: 2)
                }
                Text("\(day)")
                    .font(InterFont.swiftUI(13, (isSelected || isToday) ? .semibold : .regular))
                    .foregroundColor(isSelected
                        ? .white
                        : isToday ? Color(nsColor: InterColor.primary)
                                  : Color(nsColor: InterColor.foreground))
                if hasMeeting {
                    Circle()
                        .fill(isSelected ? Color.white : Color(nsColor: InterColor.primary))
                        .frame(width: 4, height: 4)
                        .offset(y: 11)
                }
            }
            .frame(width: 34, height: 34)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .handCursor()
    }

    // MARK: - Upcoming list

    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x2) {
            // Hosted | Invited segmented control
            HStack(spacing: 2) {
                ForEach(ScheduleViewModel.ListSegment.allCases, id: \.self) { seg in
                    let active = viewModel.segment == seg
                    Button(action: { viewModel.segment = seg }) {
                        Text(seg.rawValue)
                            .font(InterFont.swiftUI(12, .semibold))
                            .foregroundColor(active
                                ? Color(nsColor: InterColor.foreground)
                                : Color(nsColor: InterColor.mutedForeground))
                            .padding(.horizontal, InterSpacing.x3)
                            .padding(.vertical, InterSpacing.x1_5)
                            .background(
                                RoundedRectangle(cornerRadius: InterRadius.sm, style: .continuous)
                                    .fill(active ? Color(nsColor: InterColor.card) : .clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .handCursor()
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                .fill(Color(nsColor: InterColor.secondary)))

            ScrollView {
                LazyVStack(spacing: InterSpacing.x2) {
                    if viewModel.activeMeetings.isEmpty {
                        Text(viewModel.segment == .hosted
                             ? "No upcoming meetings."
                             : "No invitations yet.")
                            .font(InterFont.swiftUI(11))
                            .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, InterSpacing.x6)
                    } else {
                        ForEach(viewModel.activeMeetings, id: \.meetingId) { meeting in
                            ScheduleMeetingRow(
                                meeting: meeting,
                                isHosted: viewModel.segment == .hosted,
                                onJoin: { code in viewModel.onJoin?(code, meeting.meetingId) },
                                onCancel: { viewModel.onCancelMeeting?(meeting.meetingId) }
                            )
                        }
                    }
                }
            }
        }
        .padding(InterSpacing.x3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Right pane (form)

    private var formPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Schedule a Meeting")
                    .font(InterFont.swiftUI(14, .semibold))
                    .foregroundColor(Color(nsColor: InterColor.cardForeground))
                Spacer()
            }
            .padding(.horizontal, InterSpacing.x5)
            .frame(height: 48)

            ScrollView {
                VStack(alignment: .leading, spacing: InterSpacing.x4) {
                    field("Topic") {
                        InterInputField(placeholder: "e.g. Product Review", text: $viewModel.title)
                    }

                    HStack(alignment: .top, spacing: InterSpacing.x3) {
                        field("Date") {
                            Text(viewModel.selectedDateLabel)
                                .font(InterFont.swiftUI(InterFont.Size.secondary))
                                .foregroundColor(Color(nsColor: InterColor.foreground))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .interFieldChrome(isFocused: false)
                                .help("Pick the date on the calendar")
                        }
                        field("Start time") {
                            InterTimeSelect(selection: $viewModel.startTime)
                        }
                        field("Duration") {
                            InterSelect(selection: $viewModel.durationMinutes,
                                        options: ScheduleViewModel.durationOptions.map {
                                            ($0, ScheduleViewModel.durationLabel($0))
                                        })
                        }
                    }

                    HStack(alignment: .top, spacing: InterSpacing.x3) {
                        field("Room type") {
                            InterSelect(selection: $viewModel.roomType,
                                        options: [("call", "Call"), ("interview", "Interview")])
                        }
                        field("Password (optional)") {
                            InterInputField(placeholder: "Leave blank for none", text: $viewModel.password)
                        }
                    }
                    if viewModel.roomType == "interview" {
                        Text("Includes code editor & whiteboard tools.")
                            .font(InterFont.swiftUI(11))
                            .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                            .padding(.top, -InterSpacing.x2)
                    }

                    field("Invite attendees") {
                        InterInputField(placeholder: "alice@example.com, bob@example.com",
                                        text: $viewModel.inviteesRaw)
                    }

                    settingsSection
                }
                .padding(InterSpacing.x5)
            }

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: InterSpacing.x1_5) {
            Text(label)
                .font(InterFont.swiftUI(12, .semibold))
                .foregroundColor(Color(nsColor: InterColor.foreground))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Meeting settings (inline; full on first use, quick + Advanced after)

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x3) {
            Text("Meeting settings")
                .font(InterFont.swiftUI(12, .semibold))
                .foregroundColor(Color(nsColor: InterColor.foreground))

            VStack(spacing: 0) {
                settingToggle("Mute participants on join", subtitle: "Everyone joins with their mic off.",
                              isOn: $viewModel.muteOnJoin)
                settingToggle("Camera off on join", subtitle: "Everyone joins with their camera off.",
                              isOn: $viewModel.cameraOffOnJoin)
                settingToggle("Waiting Room", subtitle: "Only users admitted by the host can join.",
                              isOn: $viewModel.lobbyEnabled)

                if viewModel.hasSavedDefaults {
                    // Returning host: the rest lives under Advanced ▸
                    Button(action: { withAnimation(.easeInOut(duration: 0.15)) {
                        viewModel.advancedExpanded.toggle()
                    } }) {
                        HStack(spacing: InterSpacing.x1) {
                            Text("Advanced")
                                .font(InterFont.swiftUI(12, .semibold))
                            Image(systemName: viewModel.advancedExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundColor(Color(nsColor: InterColor.primary))
                        .padding(.vertical, InterSpacing.x2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .handCursor()
                }

                if !viewModel.hasSavedDefaults || viewModel.advancedExpanded {
                    advancedSettings
                }
            }

            Text(viewModel.hasSavedDefaults
                 ? "Changes here update your saved meeting defaults."
                 : "These become your saved meeting defaults — next time you'll only see the quick options.")
                .font(InterFont.swiftUI(11))
                .foregroundColor(Color(nsColor: InterColor.mutedForeground))
        }
    }

    @ViewBuilder private var advancedSettings: some View {
        settingToggle("Join before host", subtitle: "Participants can enter before you arrive.",
                      isOn: $viewModel.joinBeforeHost)
        settingToggle("Allow participants to unmute", subtitle: "Participants can unmute themselves.",
                      isOn: $viewModel.allowUnmuting)
        settingPicker("Chat", selection: $viewModel.chatPermissions, options: [
            (InterChatPermissionsEveryone, "Everyone"),
            (InterChatPermissionsHostOnly, "Host Only"),
            (InterChatPermissionsDisabled, "Disabled"),
        ])
        settingPicker("Screen sharing", selection: $viewModel.sharingPermissions, options: [
            (InterSharingPermissionsHostOnly, "Host Only"),
            (InterSharingPermissionsEveryone, "Everyone"),
            (InterSharingPermissionsRequest, "Request to Share"),
        ])
        settingPicker("While someone is sharing", selection: $viewModel.shareConflictPolicy, options: [
            (InterSharingConflictOneAtATime, "One at a time"),
            (InterSharingConflictHostCanPreempt, "Host can take over"),
            (InterSharingConflictAnyCanPreempt, "Anyone can take over"),
        ])
        Text("Recording auto-start options are configured when you start the meeting.")
            .font(InterFont.swiftUI(10))
            .foregroundColor(Color(nsColor: InterColor.mutedForeground).opacity(0.8))
            .padding(.vertical, InterSpacing.x2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingToggle(_ title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: InterSpacing.x3) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(InterFont.swiftUI(13))
                    .foregroundColor(Color(nsColor: InterColor.foreground))
                Text(subtitle)
                    .font(InterFont.swiftUI(10))
                    .foregroundColor(Color(nsColor: InterColor.mutedForeground))
            }
            Spacer(minLength: InterSpacing.x2)
            InterToggle(isOn: isOn)
        }
        .padding(.vertical, InterSpacing.x2)
    }

    private func settingPicker(_ title: String, selection: Binding<String>,
                               options: [(value: String, label: String)]) -> some View {
        HStack(spacing: InterSpacing.x3) {
            Text(title)
                .font(InterFont.swiftUI(13))
                .foregroundColor(Color(nsColor: InterColor.foreground))
            Spacer(minLength: InterSpacing.x2)
            InterSelect(selection: selection, options: options, fillWidth: false)
        }
        .padding(.vertical, InterSpacing.x2)
    }

    // MARK: - Footer (status + CTA — same surface as the form, no band)

    private var footer: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x2) {
            if !viewModel.statusText.isEmpty {
                Text(viewModel.statusText)
                    .font(InterFont.swiftUI(11, .medium))
                    .foregroundColor(statusColor)
            }
            HStack(spacing: InterSpacing.x2) {
                Spacer()
                InterButton("Schedule Meeting", variant: .primary, size: .medium,
                            isLoading: viewModel.isSubmitting,
                            loadingTitle: "Scheduling…",
                            enabled: viewModel.canSchedule,
                            action: { viewModel.submit() })
            }
        }
        .padding(.horizontal, InterSpacing.x5)
        .padding(.vertical, InterSpacing.x3)
    }

    private var statusColor: Color {
        let s = viewModel.statusText.lowercased()
        if s.contains("could not") || s.contains("must be") || s.contains("failed") {
            return Color(nsColor: InterStatus.danger)
        }
        if s.contains("scheduled!") || s.contains("sent") {
            return Color(nsColor: InterStatus.success)
        }
        return Color(nsColor: InterColor.mutedForeground)
    }
}

// MARK: - One upcoming-meeting row

private struct ScheduleMeetingRow: View {
    let meeting: InterScheduledMeeting
    let isHosted: Bool
    var onJoin: (String) -> Void
    var onCancel: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x1) {
            Text(meeting.title)
                .font(InterFont.swiftUI(12, .semibold))
                .foregroundColor(Color(nsColor: InterColor.foreground))
                .lineLimit(1)
            HStack(spacing: InterSpacing.x1) {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                Text(ScheduleViewModel.meetingTimeLabel(meeting))
                    .font(InterFont.swiftUI(10))
            }
            .foregroundColor(Color(nsColor: InterColor.mutedForeground))

            HStack(spacing: InterSpacing.x1) {
                if let code = meeting.roomCode, !code.isEmpty {
                    rowButton("Join", filled: true) { onJoin(code) }
                }
                if isHosted {
                    rowButton("Cancel", filled: false, destructive: true, action: onCancel)
                }
                Spacer(minLength: 0)
                if let code = meeting.roomCode, !code.isEmpty {
                    Text(code)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9))
                            .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .handCursor()
                    .help("Copy room code")
                }
            }
            .padding(.top, InterSpacing.x1)
        }
        .padding(.horizontal, InterSpacing.x2_5)
        .padding(.vertical, InterSpacing.x2)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Flat row on the muted rail — hover highlight instead of a boxed card.
        .background(
            RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                .fill(hovering ? Color(nsColor: InterColor.card).opacity(0.7) : .clear)
        )
        .onHover { hovering = $0 }
    }

    private func rowButton(_ title: String, filled: Bool, destructive: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(InterFont.swiftUI(10, .semibold))
                .foregroundColor(filled ? .white : Color(nsColor: InterStatus.danger))
                .padding(.horizontal, InterSpacing.x2)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                        .fill(filled ? Color(nsColor: InterColor.primary) : .clear)
                        .overlay(RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                            .strokeBorder(destructive
                                ? Color(nsColor: InterStatus.danger).opacity(0.4)
                                : .clear, lineWidth: 1))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
    }
}
