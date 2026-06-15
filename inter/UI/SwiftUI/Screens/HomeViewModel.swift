//
//  HomeViewModel.swift
//  inter
//
//  Drives the SwiftUI home / launch screen (the app's front door). One state
//  struct → one render: greeting + identity, action tiles, join-by-code,
//  hosted-room code, status line, and the meeting-history list.
//
//  AUTH STATE is modeled as a first-class enum with FOUR cases — the
//  offline-with-persisted-session case is the one with no mock and the
//  historical source of regressions (Sign Out must stay visible there):
//    • signedOut             – no session. Join works (guest); host/schedule gated.
//    • signedIn              – full feature surface.
//    • offlineWithSession    – authenticated user, server unreachable. Identity
//                              shown, server-dependent actions disabled,
//                              "reconnecting…" status.
//    • connecting            – transient in-flight (session restore at launch).
//
//  All chrome actions flow OUT through callbacks the bridge wires to the
//  existing AppDelegate selectors. Server endpoints come from InterAppConfig
//  (never UI). The display name belongs to the account when signed in; guests
//  type one inline before joining.
//

import Foundation
import Combine

public enum HomeAuthState: Equatable {
    case signedOut
    case signedIn
    case offlineWithSession
    case connecting
}

/// One row of the home screen's meeting-history list (decoded from
/// GET /meetings/history).
public struct HomeMeetingHistoryItem: Equatable, Identifiable {
    public let id: String
    public let roomCode: String
    public let roomName: String
    public let roomType: String        // "call" | "interview"
    public let status: String          // "active" | "ended"
    public let startedAt: Date
    public let durationMinutes: Int?
    public let participantCount: Int
    public let role: String            // "host" | "participant" | …

    public init(id: String, roomCode: String, roomName: String, roomType: String,
                status: String, startedAt: Date, durationMinutes: Int?,
                participantCount: Int, role: String) {
        self.id = id
        self.roomCode = roomCode
        self.roomName = roomName
        self.roomType = roomType
        self.status = status
        self.startedAt = startedAt
        self.durationMinutes = durationMinutes
        self.participantCount = participantCount
        self.role = role
    }
}

/// One upcoming scheduled meeting (decoded from GET /meetings/upcoming,
/// hosted ∪ invited). The home screen surfaces TODAY's events above RECENT.
public struct HomeUpcomingMeeting: Equatable, Identifiable {
    public let id: String
    public let title: String
    public let scheduledAt: Date
    public let durationMinutes: Int
    public let roomCode: String?
    /// Whether the signed-in user hosts this meeting (drives the scheduled-
    /// start green room: "Start Meeting" + the Meeting Settings button).
    public let isHosted: Bool

    public init(id: String, title: String, scheduledAt: Date,
                durationMinutes: Int, roomCode: String?, isHosted: Bool = false) {
        self.id = id
        self.title = title
        self.scheduledAt = scheduledAt
        self.durationMinutes = durationMinutes
        self.roomCode = roomCode
        self.isHosted = isHosted
    }
}

@MainActor
public final class HomeViewModel: ObservableObject {

    // MARK: - Pushed state (AppDelegate → bridge → here)

    @Published public var authState: HomeAuthState = .connecting
    @Published public var displayName: String = ""
    @Published public var tier: String = "free"
    @Published public var interviewRequiresPro: Bool = false
    @Published public var statusText: String = ""
    @Published public var indicator: Int = 0           // InterConnectionIndicatorState raw
    @Published public var hostedRoomCode: String = ""
    @Published public var actionsEnabled: Bool = true
    @Published public var billingStatusText: String = ""
    @Published public var billingActionEnabled: Bool = true

    // MARK: - Local state

    @Published public var joinCode: String = "" {
        didSet {
            let cleaned = HomeViewModel.sanitizeRoomCode(joinCode)
            if cleaned != joinCode { joinCode = cleaned }
        }
    }
    /// Guest display name (only used when signed out).
    @Published public var guestName: String = ""
    @Published public private(set) var history: [HomeMeetingHistoryItem] = []
    @Published public private(set) var historyLoaded: Bool = false
    /// Today's scheduled meetings (events strip above RECENT).
    @Published public private(set) var upcomingToday: [HomeUpcomingMeeting] = []

    // MARK: - Action callbacks (bridge → AppDelegate selectors)

    public var onHostCall: (() -> Void)?
    public var onHostInterview: (() -> Void)?
    public var onJoin: (() -> Void)?
    public var onSchedule: (() -> Void)?
    public var onTeams: (() -> Void)?
    public var onSignIn: (() -> Void)?
    public var onSignOut: (() -> Void)?
    public var onSettings: (() -> Void)?
    public var onAccountSettings: (() -> Void)?
    public var onViewPlans: (() -> Void)?
    public var onManageSubscription: (() -> Void)?
    /// Asks the host to (re)load meeting history (signed-in only).
    public var onLoadHistory: (() -> Void)?
    /// Join a scheduled meeting through the scheduled-start flow
    /// (roomCode, meetingId, isHosted) — the green room then knows the role.
    public var onJoinScheduledMeeting: ((String, String, Bool) -> Void)?

    public init() {}

    // MARK: - Derived state

    public var isSignedIn: Bool { authState == .signedIn }

    /// The display name all host/join flows use: the account's name when signed
    /// in (or offline-with-session), the typed guest name otherwise.
    public var effectiveDisplayName: String {
        switch authState {
        case .signedIn, .offlineWithSession:
            return displayName
        case .signedOut, .connecting:
            return guestName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Hosting/scheduling/teams need a live authenticated session.
    public var canUseAuthenticatedActions: Bool {
        authState == .signedIn && actionsEnabled
    }

    /// Join is available to everyone (guests included) when not mid-operation.
    public var canJoin: Bool {
        actionsEnabled && joinCode.count == 6 && !effectiveDisplayName.isEmpty
    }

    public var isPaidTier: Bool {
        tier == "pro" || tier == "pro+"
    }

    public var greeting: String {
        HomeViewModel.greeting(for: Date(), name: isSignedIn || authState == .offlineWithSession
                               ? displayName : "")
    }

    /// Subtitle under the greeting per state.
    public var identitySubtitle: String {
        switch authState {
        case .signedIn:           return tier == "free" ? "Free plan" : "\(tier.capitalized) plan"
        case .offlineWithSession: return "Offline — reconnecting…"
        case .signedOut:          return "Sign in to host meetings"
        case .connecting:         return "Connecting…"
        }
    }

    // MARK: - Inputs

    public func setHistory(_ items: [HomeMeetingHistoryItem]) {
        history = items
        historyLoaded = true
    }

    public func clearHistory() {
        history = []
        historyLoaded = false
        upcomingToday = []
    }

    /// Keep only TODAY's still-relevant events, soonest first.
    public func setUpcomingMeetings(_ all: [HomeUpcomingMeeting], now: Date = Date(),
                                    calendar: Calendar = .current) {
        upcomingToday = all
            .filter { calendar.isDate($0.scheduledAt, inSameDayAs: now) }
            .sorted { $0.scheduledAt < $1.scheduledAt }
    }

    public func submitJoin() {
        guard canJoin else { return }
        onJoin?()
    }

    /// Join an upcoming event from its row — routes through the scheduled-
    /// meeting flow so the server assigns the right role and the green room
    /// shows host chrome; falls back to a plain code join.
    public func joinUpcoming(_ event: HomeUpcomingMeeting) {
        guard let code = event.roomCode, !code.isEmpty else { return }
        if let scheduled = onJoinScheduledMeeting {
            scheduled(code, event.id, event.isHosted)
        } else {
            joinCode = code
            submitJoin()
        }
    }

    // MARK: - Pure helpers (unit-tested)

    /// Uppercase, strip non-alphanumerics + true confusables (0/O/1/I per G7),
    /// cap at 6. NOTE: `L` is intentionally NOT stripped — the server's room-code
    /// alphabet (`ABCDEFGHJKLMNPQRSTUVWXYZ…`, excluding only I/O/0/1) INCLUDES L,
    /// so stripping it here made any legitimate code containing L (e.g. "5XZ7L9")
    /// impossible to type — the field truncated to 5 chars and Join never enabled.
    public nonisolated static func sanitizeRoomCode(_ raw: String) -> String {
        let confusables: Set<Character> = ["0", "O", "1", "I"]
        let cleaned = raw.uppercased().filter { ch in
            (ch.isLetter || ch.isNumber) && ch.isASCII && !confusables.contains(ch)
        }
        return String(cleaned.prefix(6))
    }

    /// Time-of-day greeting; appends the first name when known.
    public nonisolated static func greeting(for date: Date, name: String,
                                            calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        let base: String
        switch hour {
        case 5..<12:  base = "Good morning"
        case 12..<17: base = "Good afternoon"
        default:      base = "Good evening"
        }
        let first = name.split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? base : "\(base), \(first)"
    }

    /// Two-letter initials for the avatar chip.
    public nonisolated static func initials(from name: String) -> String {
        let words = name.split(separator: " ").prefix(2)
        guard !words.isEmpty else { return "?" }
        if words.count == 1 { return String(words[0].prefix(1)).uppercased() }
        return words.map { String($0.prefix(1)).uppercased() }.joined()
    }

    /// "Today, 10:00 AM" / "Yesterday, 2:00 PM" / "Jun 6, 4:30 PM" row label.
    public nonisolated static func historyTimeLabel(_ date: Date, now: Date = Date(),
                                                    calendar: Calendar = .current) -> String {
        let time = DateFormatter()
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.dateFormat = "h:mm a"
        let t = time.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "Today, \(t)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday, \(t)" }
        let day = DateFormatter()
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.dateFormat = "MMM d"
        return "\(day.string(from: date)), \(t)"
    }

    /// "Today, Jun 12" — events strip header.
    public nonisolated static func todayHeaderLabel(_ now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return "Today, \(f.string(from: now))"
    }

    /// Decode the GET /meetings/upcoming response (hosted ∪ invited, de-duped).
    public nonisolated static func parseUpcoming(_ data: Data) -> [HomeUpcomingMeeting] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        var seen = Set<String>()
        var result: [HomeUpcomingMeeting] = []
        for key in ["hosted", "invited"] {
            for dict in (obj[key] as? [[String: Any]]) ?? [] {
                guard let id = dict["id"] as? String, !seen.contains(id),
                      let raw = dict["scheduledAt"] as? String,
                      let date = iso.date(from: raw) ?? isoPlain.date(from: raw) else { continue }
                seen.insert(id)
                result.append(HomeUpcomingMeeting(
                    id: id,
                    title: dict["title"] as? String ?? "Meeting",
                    scheduledAt: date,
                    durationMinutes: dict["durationMinutes"] as? Int ?? 30,
                    roomCode: dict["roomCode"] as? String,
                    isHosted: key == "hosted"))
            }
        }
        return result
    }

    /// Decode the GET /meetings/history response payload.
    public nonisolated static func parseHistory(_ data: Data) -> [HomeMeetingHistoryItem] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["meetings"] as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        return arr.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let code = dict["roomCode"] as? String,
                  let startedRaw = dict["startedAt"] as? String,
                  let started = iso.date(from: startedRaw) ?? isoPlain.date(from: startedRaw) else {
                return nil
            }
            return HomeMeetingHistoryItem(
                id: id,
                roomCode: code,
                roomName: dict["roomName"] as? String ?? "Meeting",
                roomType: dict["roomType"] as? String ?? "call",
                status: dict["status"] as? String ?? "ended",
                startedAt: started,
                durationMinutes: dict["durationMinutes"] as? Int,
                participantCount: dict["participantCount"] as? Int ?? 0,
                role: dict["role"] as? String ?? "participant"
            )
        }
    }
}
