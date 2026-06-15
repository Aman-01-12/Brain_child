//
//  ScheduleViewModelTests.swift
//  interTests
//
//  Tests the schedule view model's pure helpers (month grid, date combining,
//  email parsing, meeting-day dots) and the form gating rules.
//

import XCTest
@testable import inter

private let utcCal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func utcDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0) -> Date {
    utcCal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

private func meeting(_ id: String, at: Date, duration: Int = 45, code: String? = nil) -> InterScheduledMeeting {
    let m = InterScheduledMeeting()
    m.meetingId = id
    m.title = "M-\(id)"
    m.scheduledAt = at
    m.durationMinutes = duration
    m.roomType = "call"
    m.roomCode = code
    m.hostTimezone = "UTC"
    m.status = "scheduled"
    return m
}

@MainActor
final class ScheduleViewModelTests: XCTestCase {

    // MARK: - Month grid

    func testMonthGridJune2026() {
        // June 1, 2026 is a Monday → Sun-first grid has 1 leading blank, 30 days.
        let grid = ScheduleViewModel.monthGrid(for: utcDate(2026, 6, 15), calendar: utcCal)
        XCTAssertEqual(grid.leadingBlanks, 1)
        XCTAssertEqual(grid.dayCount, 30)
    }

    func testMonthGridFebLeapYear() {
        // Feb 2028 (leap): Feb 1 is a Tuesday → 2 blanks, 29 days.
        let grid = ScheduleViewModel.monthGrid(for: utcDate(2028, 2, 1), calendar: utcCal)
        XCTAssertEqual(grid.leadingBlanks, 2)
        XCTAssertEqual(grid.dayCount, 29)
    }

    func testMonthAnchorIsFirstOfMonth() {
        let anchor = ScheduleViewModel.monthAnchor(for: utcDate(2026, 6, 15), calendar: utcCal)
        XCTAssertEqual(utcCal.component(.day, from: anchor), 1)
        XCTAssertEqual(utcCal.component(.month, from: anchor), 6)
    }

    // MARK: - Combine day + time

    func testCombineDayAndTime() {
        let combined = ScheduleViewModel.combine(day: utcDate(2026, 6, 15, 0, 0),
                                                 time: utcDate(2000, 1, 1, 14, 30),
                                                 calendar: utcCal)
        XCTAssertEqual(combined, utcDate(2026, 6, 15, 14, 30))
    }

    // MARK: - Email parsing

    func testParseEmailsTrimsDedupsPreservesOrder() {
        let parsed = ScheduleViewModel.parseEmails(" a@x.co , B@y.co,, a@X.co ,c@z.co ")
        XCTAssertEqual(parsed, ["a@x.co", "B@y.co", "c@z.co"], "trimmed, case-insensitive dedup, order kept")
        XCTAssertEqual(ScheduleViewModel.parseEmails("   "), [])
    }

    // MARK: - Meeting-day dots

    func testMeetingDaysOnlyCountDisplayedMonth() {
        let meetings = [
            meeting("1", at: utcDate(2026, 6, 12)),
            meeting("2", at: utcDate(2026, 6, 15)),
            meeting("3", at: utcDate(2026, 7, 2)),   // next month — excluded
        ]
        let days = ScheduleViewModel.meetingDays(in: utcDate(2026, 6, 1), meetings: meetings, calendar: utcCal)
        XCTAssertEqual(days, [12, 15])
    }

    // MARK: - Form gating

    func testCanScheduleRequiresTitleAndFutureDate() {
        let vm = ScheduleViewModel()
        // Future date, no title.
        vm.selectedDate = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        XCTAssertFalse(vm.canSchedule, "blank title blocks")
        vm.title = "Sprint Planning"
        XCTAssertTrue(vm.canSchedule)
        // Past date blocks.
        vm.selectedDate = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
        XCTAssertFalse(vm.canSchedule)
    }

    func testSubmitPastDateSetsStatusAndDoesNotFire() {
        let vm = ScheduleViewModel()
        var fired = false
        vm.onSchedule = { _, _, _, _, _, _, _, _ in fired = true }
        vm.title = "Old"
        vm.selectedDate = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
        vm.submit()
        XCTAssertFalse(fired)
        XCTAssertEqual(vm.statusText, "Scheduled time must be in the future.")
    }

    func testSubmitFiresWithParsedFieldsAndSubmittingState() {
        let vm = ScheduleViewModel()
        var got: (title: String, duration: Int, room: String, pw: String?, lobby: Bool, emails: [String])?
        vm.onSchedule = { title, _, duration, room, _, pw, lobby, emails in
            got = (title, duration, room, pw, lobby, emails)
        }
        vm.title = "  Demo  "
        vm.selectedDate = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        vm.durationMinutes = 60
        vm.roomType = "interview"
        vm.password = ""
        vm.lobbyEnabled = true
        vm.inviteesRaw = "a@x.co, b@y.co"

        vm.submit()

        XCTAssertEqual(got?.title, "Demo", "title is trimmed")
        XCTAssertEqual(got?.duration, 60)
        XCTAssertEqual(got?.room, "interview")
        XCTAssertNil(got?.pw, "empty password sends nil")
        XCTAssertEqual(got?.lobby, true)
        XCTAssertEqual(got?.emails ?? [], ["a@x.co", "b@y.co"])
        XCTAssertTrue(vm.isSubmitting)

        vm.resetForm()
        XCTAssertFalse(vm.isSubmitting)
        XCTAssertTrue(vm.title.isEmpty)
    }

    // MARK: - Labels

    func testDurationOptionsMatchInventory() {
        XCTAssertEqual(ScheduleViewModel.durationOptions, [15, 20, 30, 45, 60, 90, 120])
    }

    func testMeetingTimeLabel() {
        let m = meeting("1", at: utcDate(2026, 6, 15, 14, 0), duration: 45)
        XCTAssertEqual(ScheduleViewModel.meetingTimeLabel(m, calendar: utcCal), "2:00 PM · 45m")
    }
}
