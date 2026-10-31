//
//  PresenceConsentViewModel.swift
//  inter
//
//  PRESENCE MONITORING (provisional, server flag default OFF).
//
//  Drives the candidate's pre-join presence-monitoring consent screen, which
//  replaces the bare NSAlert ONLY when the server armed the room. With the
//  master flag off the server omits the presence block from /room/join, so
//  `mode(armed: false, …)` is `.legacyAlert` for every other combination and the
//  untouched NSAlert path runs — that is the zero-impact guarantee, and it is
//  what InterPresenceConsentViewModelTests enumerates.
//
//  STRUCTURAL GUARANTEE (research memo §7.8): this type holds NO camera, NO
//  media controller and NO capture session. It cannot enable a camera, and the
//  test asserts that absence rather than trusting a comment. Declining is a
//  pure state transition that fires one closure.
//
//  Delete this file, PresenceConsentView.swift, InterPresenceConsentHostView.swift
//  and the single `if` in AppDelegate's consent gate to remove the screen.
//  See .agents/tasks/presence-monitoring/REMOVAL.md.
//

import Foundation
import Combine

/// Which screen the candidate gets at the pre-connect gate.
public enum PresenceConsentMode: Int {
    /// Not armed — the legacy secure-interview NSAlert runs, byte-for-byte unchanged.
    case legacyAlert = 0
    /// Armed: the two-option offer (join monitored / join with monitoring off).
    case monitoredOffer = 1
    /// Armed but policy-excluded (EU residency or under 18): monitoring is off and
    /// the monitored option is NEVER offered.
    case monitoringOffNotice = 2
}

/// What the candidate chose. Monitoring-off and monitored BOTH join.
public enum PresenceConsentDecision: Int {
    case cancel = 0
    case joinWithMonitoring = 1
    case joinWithoutMonitoring = 2
}

/// Which pane the screen is showing.
public enum PresenceConsentState: Int {
    case monitoredOffer = 0
    case monitoringOffNotice = 1
    case details = 2
}

/// The single source of the research-memo §7.4 disclosure copy. The mid-session
/// details sheet renders these same strings, so the pre-join promise and the
/// in-session explanation cannot drift apart.
///
/// COPY RULE (§7.10): none of these strings may contain cheating, dishonesty,
/// integrity, attention, focus, engagement, emotion, mood, confidence,
/// proctoring, eye tracking, gaze, identity, accuracy or tamper-proof.
/// `InterPresenceConsentViewModelTests` asserts that, one word per assertion.
///
/// DELIBERATE DEVIATION from plan item 13(b): §7.4 item 2 is reproduced in plain
/// language rather than verbatim, because its verbatim wording names four of the
/// words §7.10 forbids ("emotion, mood, attention, confidence"). The substance —
/// an explicit, prominent negative list — is preserved in full; only the nouns
/// are paraphrased so the copy guard can be a blanket word check.
public struct PresenceDisclosure {

    // MARK: Secure-interview restrictions (carried over from the NSAlert this replaces)

    public static let secureModeHeading = "Secure interview mode"
    public static let secureModeFullScreen = "The interview runs in a full-screen secure window."
    public static let secureModeSharing = "Screen sharing is restricted to the interview tools."
    public static let secureModeExternalDisplays = "External displays are blocked for the session."

    /// §7.4 item 1 — exactly what is measured, one line per event type.
    public static let measuredHeading = "What is recorded"
    public static let measuredItems: [String] = [
        "Whether a face is visible to your camera.",
        "How many faces are visible.",
        "Whether the picture is clear enough for that check to work at all.",
        "When you turn your camera off, and when you turn it back on.",
    ]

    /// §7.4 item 2 — the negative list, in plain language.
    public static let notMeasuredHeading = "What is not recorded"
    public static let notMeasuredItems: [String] = [
        "We do not analyse your expression or how you look.",
        "We do not try to work out how you feel or what you are thinking.",
        "We do not try to judge whether you are telling the truth.",
        "We do not recognise who you are from your face.",
        "We keep no photo, no video and no still image of you for this.",
        "Nothing about you is decided automatically.",
    ]

    /// §7.4 item 3 — where the processing happens.
    public static let whereProcessed =
        "This runs on your own Mac. No picture of you is sent to our servers for it."

    /// §7.4 item 4 — what is stored and for how long.
    public static func storedAndKept(retentionDays: Int) -> String {
        let days = max(1, retentionDays)
        return "What is stored is a short list of timestamped notes — for example "
            + "\"no face visible for 14 seconds\" — kept for \(days) days and then deleted."
    }

    /// §7.4 item 5 — who sees it.
    public static let whoSees = "Your interviewer and their hiring team see those notes."

    /// §7.4 item 6 — nothing is automated.
    public static let noAutomatedDecision =
        "No decision about you is automated. Your interviewer reads the notes and decides "
        + "what they mean, the same way they weigh everything else in the interview."

    /// §7.4 item 7 — the real alternative. No reason is requested, which is also
    /// the accommodation path (§4.2): nobody has to disclose anything to opt out.
    public static let declineExplainer =
        "You can join with monitoring off. You are not asked why, and nothing is recorded "
        + "about what your camera sees. Your interviewer is told monitoring is off."

    /// §7.4 item 8 — copy and deletion requests.
    public static func rightsRequest(contact: String) -> String {
        let target = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.isEmpty {
            return "To ask for a copy of these notes, or to have them deleted, contact the "
                + "organisation running this interview."
        }
        return "To ask for a copy of these notes, or to have them deleted, write to \(target)."
    }

    /// Shown when monitoring is off by policy. It deliberately does NOT tell the
    /// candidate which policy applied — making someone read back a protected
    /// characteristic on the way into an interview is the harm, not the fix.
    public static let monitoringOffNotice =
        "Presence monitoring is off for this interview. Nothing about what your camera sees "
        + "is recorded, and there is nothing for you to turn off."

    public static let detailsHeading = "What is and isn't measured"

    /// Every disclosure string in one array, for the §7.10 copy guard.
    public static func allCopy(retentionDays: Int = 90, contact: String = "privacy@example.invalid") -> [String] {
        var all: [String] = [
            secureModeHeading, secureModeFullScreen, secureModeSharing, secureModeExternalDisplays,
            measuredHeading, notMeasuredHeading,
            whereProcessed, whoSees, noAutomatedDecision, declineExplainer,
            monitoringOffNotice, detailsHeading,
            storedAndKept(retentionDays: retentionDays),
            rightsRequest(contact: contact),
        ]
        all.append(contentsOf: measuredItems)
        all.append(contentsOf: notMeasuredItems)
        return all
    }
}

@MainActor
public final class PresenceConsentViewModel: ObservableObject {

    /// Which pane is on screen.
    @Published public private(set) var state: PresenceConsentState

    /// Which screen the server's arming decision produced.
    public let mode: PresenceConsentMode
    public let retentionDays: Int
    public let rightsContact: String
    /// Whether this build/config blocks external displays in secure interviews.
    public let externalDisplayPolicy: Bool
    /// True when the screen is being reused mid-session as a read-only details
    /// sheet: there is no decision to make and the action row is a single Close.
    public let detailsOnly: Bool
    /// Indicator state (0 absent / 1 on / 2 off / 3 paused) shown in details mode.
    /// Published so an open details sheet can never show a stale state.
    @Published public private(set) var monitoringState: Int

    /// Fires exactly once, with the candidate's decision. Terminal.
    public var onDecision: ((PresenceConsentDecision) -> Void)?
    /// Fires when a details-only presentation should close.
    public var onDismissDetails: (() -> Void)?

    private var decided = false

    public init(mode: PresenceConsentMode,
                retentionDays: Int = 90,
                rightsContact: String = "",
                externalDisplayPolicy: Bool = false,
                detailsOnly: Bool = false,
                monitoringState: Int = 0) {
        self.mode = mode
        self.retentionDays = retentionDays
        self.rightsContact = rightsContact
        self.externalDisplayPolicy = externalDisplayPolicy
        self.detailsOnly = detailsOnly
        self.monitoringState = monitoringState
        if detailsOnly {
            self.state = .details
        } else {
            self.state = (mode == .monitoringOffNotice) ? .monitoringOffNotice : .monitoredOffer
        }
    }

    /// Pushed by the window controller while a details sheet is open.
    public func setMonitoringState(_ state: Int) {
        monitoringState = state
    }

    // MARK: - Intents

    public func acceptMonitoring() {
        guard mode == .monitoredOffer else { return }
        finish(.joinWithMonitoring)
    }

    public func declineMonitoring() {
        finish(.joinWithoutMonitoring)
    }

    public func cancelJoin() {
        finish(.cancel)
    }

    public func showDetails() {
        guard !decided, state != .details else { return }
        state = .details
    }

    public func dismissDetails() {
        guard state == .details else { return }
        if detailsOnly {
            onDismissDetails?()
            return
        }
        state = (mode == .monitoringOffNotice) ? .monitoringOffNotice : .monitoredOffer
    }

    /// One decision per screen. A second intent after a decision does nothing —
    /// a double-tap must not join twice or join after a cancel.
    private func finish(_ decision: PresenceConsentDecision) {
        guard !decided, !detailsOnly else { return }
        decided = true
        onDecision?(decision)
    }

    // MARK: - Derived copy

    public var title: String { "You're joining an interview session" }

    public var subtitle: String {
        switch mode {
        case .monitoringOffNotice, .legacyAlert:
            return PresenceDisclosure.monitoringOffNotice
        case .monitoredOffer:
            return "This interview can record a few plain facts about what your camera sees. "
                + "Here is exactly what that is, and you can join with it switched off."
        }
    }

    public var secureModeItems: [String] {
        var items = [PresenceDisclosure.secureModeFullScreen,
                     PresenceDisclosure.secureModeSharing]
        if externalDisplayPolicy { items.append(PresenceDisclosure.secureModeExternalDisplays) }
        return items
    }

    public var storedCopy: String { PresenceDisclosure.storedAndKept(retentionDays: retentionDays) }
    public var rightsCopy: String { PresenceDisclosure.rightsRequest(contact: rightsContact) }

    /// Label for the details-mode state row, or nil when there is nothing to say.
    public var currentIndicatorLabel: String? {
        Self.indicatorLabel(monitoringState)
    }

    // MARK: - Pure helpers (enumerated by the tests)

    /// THE zero-impact function. `armed == false` ⇒ `.legacyAlert`, for every
    /// combination of the other two flags, so a flag-off server cannot produce
    /// this screen at all. EU residency or under-18 ⇒ the monitored option is
    /// never offered (research memo §7.9 items 7 and 8; EU AI Act Art. 5(1)(f)
    /// exposure and the DPDP child threshold respectively).
    public nonisolated static func mode(armed: Bool, regionEU: Bool, under18: Bool) -> PresenceConsentMode {
        guard armed else { return .legacyAlert }
        if regionEU || under18 { return .monitoringOffNotice }
        return .monitoredOffer
    }

    /// The candidate's persistent chrome chip label. 0 absent / 1 on / 2 off /
    /// 3 paused because the camera is off. A stale "on" is a lie and a stale
    /// "off" is worse, so every state has its own words.
    public nonisolated static func indicatorLabel(_ state: Int) -> String? {
        switch state {
        case 1: return "Presence monitoring on"
        case 2: return "Presence monitoring off"
        case 3: return "Presence monitoring paused — camera off"
        default: return nil
        }
    }

    /// Button titles, kept here so the view has no copy of its own.
    public nonisolated static let joinMonitoredTitle = "Join with presence monitoring"
    public nonisolated static let joinUnmonitoredTitle = "Join with monitoring off"
    public nonisolated static let joinOnlyTitle = "Join interview"
    public nonisolated static let cancelTitle = "Cancel and leave"
    public nonisolated static let detailsRowTitle = "What is and isn't measured"
    public nonisolated static let closeDetailsTitle = "Close"
    public nonisolated static let backFromDetailsTitle = "Back"
}
