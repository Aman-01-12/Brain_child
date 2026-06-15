//
//  ScheduleViewModel.swift
//  inter
//
//  Drives the SwiftUI Schedule screen: the month calendar, the schedule form
//  (topic / date / time / duration / room type / invitees / password), the
//  inline Meeting-settings section, and the hosted/invited upcoming lists.
//
//  Meeting-settings flow (per product decision):
//    • The form always shows the schedule-specific fields first.
//    • Below them sits a "Meeting settings" section backed by the SAME saved
//      defaults the pre-meeting panel uses (InterPreMeetingSettings):
//        – No saved defaults yet (first time): the full settings list is shown
//          inline so scheduling also establishes the user's defaults.
//        – Defaults saved: only the high-traffic three (mic on join, camera on
//          join, waiting room) show, with the rest under "Advanced ▸".
//    • Scheduling persists the section back via saveToUserDefaults — the same
//      store the host's pre-meeting flow reads when the meeting actually starts.
//      (Recording auto-start options stay in the pre-meeting panel — they're
//      start-time, tier-gated concerns.)
//
//  Actions flow OUT through callbacks the bridge wires to the legacy
//  InterSchedulePanelDelegate, so AppDelegate's wiring is unchanged.
//

import Foundation
import Combine

@MainActor
public final class ScheduleViewModel: ObservableObject {

    // MARK: - Calendar state

    /// First day of the displayed month.
    @Published public private(set) var displayedMonth: Date
    /// The day selected in the calendar (the meeting's date).
    @Published public var selectedDate: Date

    // MARK: - Form state

    @Published public var title: String = ""
    @Published public var startTime: Date
    @Published public var durationMinutes: Int = 30
    @Published public var roomType: String = "call"          // "call" | "interview"
    @Published public var inviteesRaw: String = ""
    @Published public var password: String = ""

    // MARK: - Meeting-settings section (mirrors InterPreMeetingSettings)

    @Published public var muteOnJoin: Bool
    @Published public var cameraOffOnJoin: Bool
    @Published public var lobbyEnabled: Bool
    @Published public var joinBeforeHost: Bool
    @Published public var allowUnmuting: Bool
    @Published public var chatPermissions: String
    @Published public var sharingPermissions: String
    @Published public var shareConflictPolicy: String
    /// Whether the user had saved defaults when the screen opened (gates the
    /// quick vs full settings presentation).
    public let hasSavedDefaults: Bool
    /// Discloses the advanced settings when defaults exist.
    @Published public var advancedExpanded: Bool = false

    // MARK: - Upcoming lists

    public enum ListSegment: String, CaseIterable { case hosted = "Hosted", invited = "Invited" }
    @Published public var segment: ListSegment = .hosted
    @Published public private(set) var hostedMeetings: [InterScheduledMeeting] = []
    @Published public private(set) var invitedMeetings: [InterScheduledMeeting] = []

    // MARK: - Status

    @Published public var statusText: String = ""
    @Published public var isSubmitting: Bool = false

    // MARK: - Callbacks (wired by the bridge to the legacy delegate)

    public var onSchedule: ((_ title: String, _ scheduledAt: Date, _ durationMinutes: Int,
                             _ roomType: String, _ timezone: String, _ password: String?,
                             _ lobbyEnabled: Bool, _ inviteeEmails: [String]) -> Void)?
    public var onCancelMeeting: ((String) -> Void)?
    public var onJoin: ((_ roomCode: String, _ meetingId: String) -> Void)?

    private let calendar: Calendar

    public init(now: Date = Date(), calendar: Calendar = .current) {
        self.calendar = calendar
        let startOfToday = calendar.startOfDay(for: now)
        self.selectedDate = startOfToday
        self.displayedMonth = ScheduleViewModel.monthAnchor(for: now, calendar: calendar)
        // Default start time: the next full hour.
        self.startTime = calendar.date(
            bySettingHour: min(23, calendar.component(.hour, from: now) + 1),
            minute: 0, second: 0, of: now) ?? now

        // Seed the settings section from the SAME store the pre-meeting flow uses.
        let defaults = InterPreMeetingSettings.withDefaults()
        self.muteOnJoin = defaults.muteOnJoin
        self.cameraOffOnJoin = defaults.cameraOffOnJoin
        self.lobbyEnabled = defaults.lobbyEnabled
        self.joinBeforeHost = defaults.joinBeforeHost
        self.allowUnmuting = defaults.allowUnmuting
        self.chatPermissions = defaults.chatPermissions
        self.sharingPermissions = defaults.sharingPermissions
        self.shareConflictPolicy = defaults.shareConflictPolicy
        self.hasSavedDefaults = InterPreMeetingSettings.hasConfiguredDefaults()
    }

    // MARK: - Calendar navigation

    public func stepMonth(_ delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: displayedMonth) {
            displayedMonth = ScheduleViewModel.monthAnchor(for: next, calendar: calendar)
        }
    }

    public func selectDay(_ day: Int) {
        var comps = calendar.dateComponents([.year, .month], from: displayedMonth)
        comps.day = day
        if let date = calendar.date(from: comps) {
            selectedDate = calendar.startOfDay(for: date)
        }
    }

    public var monthTitle: String {
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.dateFormat = "MMMM yyyy"
        return fmt.string(from: displayedMonth)
    }

    /// Day-grid for the displayed month: number of leading blanks + day count.
    public var monthGrid: (leadingBlanks: Int, dayCount: Int) {
        ScheduleViewModel.monthGrid(for: displayedMonth, calendar: calendar)
    }

    /// Day numbers in the displayed month that have at least one meeting (dots).
    public var meetingDays: Set<Int> {
        ScheduleViewModel.meetingDays(in: displayedMonth,
                                      meetings: hostedMeetings + invitedMeetings,
                                      calendar: calendar)
    }

    public func isSelected(day: Int) -> Bool {
        calendar.component(.day, from: selectedDate) == day
            && calendar.isDate(selectedDate, equalTo: displayedMonth, toGranularity: .month)
    }

    public func isToday(day: Int) -> Bool {
        let today = Date()
        return calendar.component(.day, from: today) == day
            && calendar.isDate(today, equalTo: displayedMonth, toGranularity: .month)
    }

    public var selectedDateLabel: String {
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.dateFormat = "MMMM d, yyyy"
        return fmt.string(from: selectedDate)
    }

    // MARK: - Lists

    public func setUpcomingMeetings(_ meetings: [InterScheduledMeeting]) {
        hostedMeetings = meetings
    }

    public func setInvitedMeetings(_ meetings: [InterScheduledMeeting]) {
        invitedMeetings = meetings
    }

    public var activeMeetings: [InterScheduledMeeting] {
        segment == .hosted ? hostedMeetings : invitedMeetings
    }

    // MARK: - Form

    public static let durationOptions = [15, 20, 30, 45, 60, 90, 120]

    public var canSchedule: Bool {
        !isSubmitting
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && scheduledAt > Date()
    }

    /// Selected calendar day + start-time-of-day combined into the meeting Date.
    public var scheduledAt: Date {
        ScheduleViewModel.combine(day: selectedDate, time: startTime, calendar: calendar)
    }

    public func submit() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            statusText = "Enter a meeting topic."
            return
        }
        let when = scheduledAt
        guard when > Date() else {
            statusText = "Scheduled time must be in the future."
            return
        }

        // Persist the settings section as the user's meeting defaults — the same
        // store the pre-meeting flow reads when this meeting is started.
        let settings = InterPreMeetingSettings.withDefaults()
        settings.muteOnJoin = muteOnJoin
        settings.cameraOffOnJoin = cameraOffOnJoin
        settings.lobbyEnabled = lobbyEnabled
        settings.joinBeforeHost = joinBeforeHost
        settings.allowUnmuting = allowUnmuting
        settings.chatPermissions = chatPermissions
        settings.sharingPermissions = sharingPermissions
        settings.shareConflictPolicy = shareConflictPolicy
        settings.saveToUserDefaults()

        isSubmitting = true
        statusText = "Scheduling…"
        // Host timezone: the stored profile preference (Settings → Profile) when
        // set, else the system timezone — the wire that keeps the picker honest.
        let hostTimezone = UserDefaults.standard.string(forKey: AccountSettingsViewModel.timezoneDefaultsKey)
            ?? TimeZone.current.identifier
        onSchedule?(trimmedTitle, when, durationMinutes, roomType,
                    hostTimezone,
                    password.isEmpty ? nil : password,
                    lobbyEnabled,
                    ScheduleViewModel.parseEmails(inviteesRaw))
    }

    /// Reset the form after a successful schedule (mirrors the legacy resetForm).
    public func resetForm() {
        title = ""
        inviteesRaw = ""
        password = ""
        isSubmitting = false
    }

    // MARK: - Pure helpers (unit-tested)

    /// First instant of the month containing `date`.
    public nonisolated static func monthAnchor(for date: Date, calendar: Calendar) -> Date {
        let comps = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: comps) ?? date
    }

    /// Leading blanks (Sun-first) + number of days for the month containing `month`.
    public nonisolated static func monthGrid(for month: Date, calendar: Calendar) -> (leadingBlanks: Int, dayCount: Int) {
        var cal = calendar
        cal.firstWeekday = 1 // Sun-first, matching the reference design
        let anchor = monthAnchor(for: month, calendar: cal)
        let weekday = cal.component(.weekday, from: anchor)        // 1 = Sunday
        let days = cal.range(of: .day, in: .month, for: anchor)?.count ?? 30
        return (leadingBlanks: weekday - 1, dayCount: days)
    }

    /// Day numbers (in `month`) on which any of `meetings` are scheduled.
    public nonisolated static func meetingDays(in month: Date, meetings: [InterScheduledMeeting],
                                               calendar: Calendar) -> Set<Int> {
        var days = Set<Int>()
        for meeting in meetings {
            guard let when = meeting.scheduledAt as Date? else { continue }
            if calendar.isDate(when, equalTo: month, toGranularity: .month) {
                days.insert(calendar.component(.day, from: when))
            }
        }
        return days
    }

    /// `day`'s date + `time`'s hour/minute → one Date.
    public nonisolated static func combine(day: Date, time: Date, calendar: Calendar) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: day)
        let t = calendar.dateComponents([.hour, .minute], from: time)
        comps.hour = t.hour
        comps.minute = t.minute
        comps.second = 0
        return calendar.date(from: comps) ?? day
    }

    /// Comma-separated emails → trimmed, de-duplicated (case-insensitive), order-preserving.
    public nonisolated static func parseEmails(_ raw: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for part in raw.split(separator: ",") {
            let email = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !email.isEmpty else { continue }
            let key = email.lowercased()
            if seen.insert(key).inserted { out.append(email) }
        }
        return out
    }

    /// "45 min" / "1h 30m"-style label for a duration row.
    public nonisolated static func durationLabel(_ minutes: Int) -> String {
        "\(minutes) min"
    }

    /// "10:00 AM · 45m" label for an upcoming-meeting row.
    public nonisolated static func meetingTimeLabel(_ meeting: InterScheduledMeeting,
                                                    calendar: Calendar = .current) -> String {
        guard let when = meeting.scheduledAt as Date? else { return "" }
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.dateFormat = "h:mm a"
        return "\(fmt.string(from: when)) · \(meeting.durationMinutes)m"
    }
}
