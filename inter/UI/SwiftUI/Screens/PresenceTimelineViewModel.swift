//
//  PresenceTimelineViewModel.swift
//  inter
//
//  PRESENCE MONITORING (provisional, server flag default OFF).
//
//  The interviewer's post-session evaluation surface: a timestamped list of what
//  the candidate's camera saw, per-type counts and durations, the operating point
//  those were measured under, and a place to write down what the interviewer
//  decided it meant.
//
//  Everything here is parsed from the server's timeline response; this type
//  derives no new facts. Delete this file, PresenceTimelineView.swift and the
//  bridge setters to remove the interviewer surface.
//  See .agents/tasks/presence-monitoring/REMOVAL.md.
//

import Foundation
import Combine

/// One interviewer note attached to one event. Additive and append-only —
/// nobody edits history (the DB forbids UPDATE/DELETE on the audit trail).
public struct PresenceNote: Identifiable, Equatable {
    public let id: String
    public let author: String
    public let createdAt: String
    public let text: String

    public init(id: String, author: String, createdAt: String, text: String) {
        self.id = id
        self.author = author
        self.createdAt = createdAt
        self.text = text
    }
}

/// Per-type counts and durations — THE WHOLE EVALUATION SURFACE.
///
/// §7.2, and this is load-bearing: there is no total, no weighting, no
/// normalisation, no percentage, no rating, no colour-coded risk level and no
/// comparison to any other candidate or session, and none may ever be added.
/// A base-rate argument (§6.3) makes any such number's implied precision wrong,
/// and a number hides that an event is a measurement rather than a finding.
/// If a buyer asks for a score, the answer is the event list.
public struct PresenceTypeSummary: Identifiable, Equatable {
    public let eventType: String
    public let count: Int
    public let totalDurationMs: Int
    /// Whether the server surfaces this type to a live interviewer. Computed
    /// server-side; shown here only so the reviewer knows what was on screen.
    public let liveSurfaceable: Bool

    public var id: String { eventType }

    public init(eventType: String, count: Int, totalDurationMs: Int, liveSurfaceable: Bool) {
        self.eventType = eventType
        self.count = count
        self.totalDurationMs = totalDurationMs
        self.liveSurfaceable = liveSurfaceable
    }
}

/// One row of the timeline. `id` is the server event id; an OPEN monitoring gap
/// is computed on the fly server-side with no id and arrives here as 0.
public struct PresenceTimelineRow: Identifiable, Equatable {
    public let id: Int
    public let eventType: String
    public let startedAt: String
    public let endedAt: String?
    public let durationMs: Int
    /// Offset from session start — what jump-to-timestamp consumes.
    public let offsetMs: Int
    /// "client" or "server" (a monitoring_gap is the server's own record).
    public let source: String
    public let liveSurfaceable: Bool
    public let notes: [PresenceNote]

    public init(id: Int, eventType: String, startedAt: String, endedAt: String?,
                durationMs: Int, offsetMs: Int, source: String,
                liveSurfaceable: Bool, notes: [PresenceNote]) {
        self.id = id
        self.eventType = eventType
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationMs = durationMs
        self.offsetMs = offsetMs
        self.source = source
        self.liveSurfaceable = liveSurfaceable
        self.notes = notes
    }

    /// Only a persisted event can carry a note.
    public var acceptsNote: Bool { id > 0 }
}

@MainActor
public final class PresenceTimelineViewModel: ObservableObject {

    // MARK: - Server-provided state

    @Published public private(set) var rows: [PresenceTimelineRow] = []
    @Published public private(set) var summary: [PresenceTypeSummary] = []
    @Published public private(set) var sessionDurationMs: Int = 0
    @Published public private(set) var monitoringEnabled = false
    @Published public private(set) var consentState = "pending"
    @Published public private(set) var detectorVersion = ""
    @Published public private(set) var thresholdsJSON = ""
    @Published public private(set) var multipleFacesEnabled = false
    @Published public private(set) var loaded = false

    /// Set when a read or a write failed, so the panel says so instead of
    /// showing an empty list that reads as "nothing happened".
    @Published public var statusText = ""

    /// Whether a recording exists for this session. FALSE keeps the Jump control
    /// visible but DISABLED with an honest caption — hiding it would let the
    /// interviewer assume a clip exists somewhere.
    @Published public var recordingAvailable = false

    /// Per-row note drafts, keyed by event id.
    @Published public var noteDrafts: [Int: String] = [:]

    // MARK: - Handlers (the bridge wires these)

    public var onRefresh: (() -> Void)?
    /// Emits the event's offset from session start, in seconds.
    public var onJumpToOffset: ((Double) -> Void)?
    /// (eventId, note text)
    public var onAddNote: ((Int, String) -> Void)?
    public var onCopyJSON: (() -> Void)?
    public var onSaveCSV: (() -> Void)?

    public init() {}

    // MARK: - Intents

    public func refresh() {
        onRefresh?()
    }

    public func jumpTo(row: PresenceTimelineRow) {
        guard recordingAvailable else { return }
        onJumpToOffset?(Double(row.offsetMs) / 1000.0)
    }

    public func addNote(row: PresenceTimelineRow, text: String) {
        guard row.acceptsNote, Self.noteIsSaveable(text) else { return }
        onAddNote?(row.id, text.trimmingCharacters(in: .whitespacesAndNewlines))
        noteDrafts[row.id] = ""
    }

    public func copyJSON() {
        onCopyJSON?()
    }

    public func saveCSV() {
        onSaveCSV?()
    }

    // MARK: - Ingest

    /// Applies a `GET /presence/timeline` response. Unknown keys are ignored and
    /// missing keys fall back to inert defaults — this never invents a value.
    public func apply(timeline: [AnyHashable: Any]) {
        monitoringEnabled    = timeline["monitoringEnabled"] as? Bool ?? false
        consentState         = timeline["consentState"] as? String ?? "pending"
        detectorVersion      = timeline["detectorVersion"] as? String ?? ""
        multipleFacesEnabled = timeline["multipleFacesEnabled"] as? Bool ?? false
        sessionDurationMs    = timeline["sessionDurationMs"] as? Int ?? 0

        if let thresholds = timeline["thresholds"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: thresholds,
                                                  options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            thresholdsJSON = text
        } else {
            thresholdsJSON = ""
        }

        summary = (timeline["summary"] as? [[String: Any]] ?? []).compactMap { dict in
            guard let type = dict["eventType"] as? String else { return nil }
            return PresenceTypeSummary(eventType: type,
                                       count: dict["count"] as? Int ?? 0,
                                       totalDurationMs: dict["totalDurationMs"] as? Int ?? 0,
                                       liveSurfaceable: dict["liveSurfaceable"] as? Bool ?? false)
        }

        rows = (timeline["events"] as? [[String: Any]] ?? []).compactMap { dict in
            guard let type = dict["eventType"] as? String,
                  let startedAt = dict["startedAt"] as? String else { return nil }
            let notes = (dict["notes"] as? [[String: Any]] ?? []).enumerated().map { index, note in
                PresenceNote(id: "\(dict["id"] as? Int ?? 0)-\(index)",
                             author: note["author"] as? String ?? "Interviewer",
                             createdAt: note["createdAt"] as? String ?? "",
                             text: note["text"] as? String ?? "")
            }
            return PresenceTimelineRow(id: dict["id"] as? Int ?? 0,
                                       eventType: type,
                                       startedAt: startedAt,
                                       endedAt: dict["endedAt"] as? String,
                                       durationMs: dict["durationMs"] as? Int ?? 0,
                                       offsetMs: dict["offsetMs"] as? Int ?? 0,
                                       source: dict["source"] as? String ?? "client",
                                       liveSurfaceable: dict["liveSurfaceable"] as? Bool ?? false,
                                       notes: notes)
        }
        loaded = true
        statusText = ""
    }

    // MARK: - Derived

    public var consentCaption: String {
        switch consentState {
        case "granted":     return monitoringEnabled ? "Candidate agreed — monitoring on"
                                                     : "Candidate agreed — monitoring not running"
        case "declined":    return "Candidate joined with monitoring off"
        case "not_offered": return "Monitoring was not offered for this session"
        default:            return "No consent recorded yet"
        }
    }

    public var footerCaption: String {
        var parts: [String] = []
        if !detectorVersion.isEmpty { parts.append("Detector \(detectorVersion)") }
        if !thresholdsJSON.isEmpty { parts.append("Thresholds in force: \(thresholdsJSON)") }
        if !multipleFacesEnabled {
            parts.append("Second-face events were not enabled for this room.")
        }
        return parts.joined(separator: "  ·  ")
    }

    public var jumpCaption: String? {
        recordingAvailable ? nil : "No recording for this session"
    }

    // MARK: - Pure helpers (unit-tested)

    /// Mirrors the server's >= 10-character rule so the Save button is honest.
    /// The SERVER is the control — it rejects a short note with
    /// PRESENCE_NOTE_REASON_REQUIRED regardless of what this returns.
    public nonisolated static func noteIsSaveable(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10
    }

    /// Plain words for an event type. Each one names what the camera saw and
    /// stops there; none of them says what it means.
    public nonisolated static func eventTypeLabel(_ eventType: String) -> String {
        switch eventType {
        case "face_absent":               return "Face not visible"
        case "multiple_faces":            return "Second face visible"
        case "image_quality_insufficient": return "Picture not clear enough to tell"
        case "camera_disabled":           return "Camera turned off"
        case "camera_enabled":            return "Camera turned back on"
        case "monitoring_gap":            return "No reports received"
        default:                          return eventType
        }
    }

    /// "41 s" / "1 m 20 s" / "—" for an instantaneous transition.
    public nonisolated static func durationCaption(_ durationMs: Int) -> String {
        guard durationMs > 0 else { return "—" }
        let totalSeconds = Int((Double(durationMs) / 1000.0).rounded())
        if totalSeconds < 60 { return "\(max(1, totalSeconds)) s" }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return seconds == 0 ? "\(minutes) m" : "\(minutes) m \(seconds) s"
    }

    /// "00:14:02" from an offset — the timestamp a reviewer reads off the clip.
    public nonisolated static func offsetCaption(_ offsetMs: Int) -> String {
        let totalSeconds = max(0, offsetMs) / 1000
        return String(format: "%02d:%02d:%02d",
                      totalSeconds / 3600, (totalSeconds % 3600) / 60, totalSeconds % 60)
    }

    /// One summary line, e.g. "Face not visible — 3 events, 41 s total".
    /// Count and duration, nothing above that (§7.2).
    public nonisolated static func summaryCaption(_ row: PresenceTypeSummary) -> String {
        let events = row.count == 1 ? "1 event" : "\(row.count) events"
        guard row.totalDurationMs > 0 else {
            return "\(eventTypeLabel(row.eventType)) — \(events)"
        }
        return "\(eventTypeLabel(row.eventType)) — \(events), \(durationCaption(row.totalDurationMs)) total"
    }
}
