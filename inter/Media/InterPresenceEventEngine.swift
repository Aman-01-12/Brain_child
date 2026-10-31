// ============================================================================
// InterPresenceEventEngine.swift
// inter
//
// PRESENCE MONITORING (provisional, server flag default OFF).
//
// The pure hysteresis core of the candidate presence detector. NO AVFoundation,
// NO Vision, NO networking and NO clock: time is INJECTED on every call, so the
// whole state machine is enumerable in a unit test with no sleeping and no
// capture session. Delete this file with the rest of the feature.
// See .agents/tasks/presence-monitoring/REMOVAL.md.
//
// WHAT THIS FILE IS ALLOWED TO PRODUCE:
// five event types, each a (type, start, end, duration) tuple of String / Double
// / Int. There is no score, index, percentage, rating, risk level or
// candidate-to-candidate comparison here, and there never may be (research memo
// §7.2). There is no emotion, affect, attention, engagement, focus, confidence,
// stress, honesty or personality inference anywhere in this pipeline — in a
// hiring context that is an EU AI Act Art. 5(1)(f) prohibited practice.
// `PresenceEvent` is structurally incapable of carrying a pixel buffer, an
// image, a `Data` or a numeric series, and `asPayload()` is the ONLY
// serialisation path out of it.
// ============================================================================

import Foundation

// MARK: - Event type names (the wire strings)

/// The five event types a client may ever construct. `monitoring_gap` is
/// server-generated and deliberately absent; `head_off_axis` does not exist in
/// this build at all (no head pose is collected anywhere — plan §F).
public enum InterPresenceEventType {
    public static let faceAbsent = "face_absent"
    public static let multipleFaces = "multiple_faces"
    public static let imageQualityInsufficient = "image_quality_insufficient"
    public static let cameraDisabled = "camera_disabled"
    public static let cameraEnabled = "camera_enabled"

    /// Every type the engine can emit. Used by the tests to prove nothing else
    /// ever appears.
    public static let all: [String] = [
        faceAbsent, multipleFaces, imageQualityInsufficient, cameraDisabled, cameraEnabled
    ]
}

// MARK: - Thresholds

/// The operating point the server handed down on the `/room/join` response as
/// the `presenceThresholds` JSON *string*. An event means nothing without it,
/// which is why the server stamps the same snapshot on every stored row and the
/// interviewer's timeline footer shows it.
///
/// The key names are the server's (`token-server/presenceConfig.js`
/// `thresholdSnapshot()`); `detectorConfidenceFloor` is the Vision face
/// detector's own bounding-box confidence and feeds
/// `image_quality_insufficient` ONLY — never `face_absent`.
public struct PresenceThresholds: Equatable {

    /// Frame sampling period. 2 Hz: a 3 s threshold still gets ~6 samples.
    public let sampleIntervalMs: Int
    /// Continuous time `faceCount == 0` must hold before an event opens.
    public let faceAbsentOpenMs: Int
    /// Continuous time `faceCount >= 2` must hold before an event opens.
    public let multipleFacesOpenMs: Int
    /// Continuous time a quality objection must hold before an event opens.
    public let imageQualityOpenMs: Int
    /// Continuous time a condition must be CLEAR before its event closes.
    public let closeMs: Int
    /// Vision bounding-box confidence floor. Below it the FRAME is suspect.
    public let detectorConfidenceFloor: Double
    /// Minimum normalised face-box area (width * height) before the frame is
    /// treated as too small/far to judge.
    public let minBoxAreaFraction: Double
    /// Server-side silence window; carried so the client can log the operating
    /// point it was given. The client does not act on it.
    public let gapSeconds: Int

    public init(sampleIntervalMs: Int = 500,
                faceAbsentOpenMs: Int = 10_000,
                multipleFacesOpenMs: Int = 3_000,
                imageQualityOpenMs: Int = 15_000,
                closeMs: Int = 1_000,
                detectorConfidenceFloor: Double = 0.35,
                minBoxAreaFraction: Double = 0.01,
                gapSeconds: Int = 60) {
        self.sampleIntervalMs = sampleIntervalMs
        self.faceAbsentOpenMs = faceAbsentOpenMs
        self.multipleFacesOpenMs = multipleFacesOpenMs
        self.imageQualityOpenMs = imageQualityOpenMs
        self.closeMs = closeMs
        self.detectorConfidenceFloor = detectorConfidenceFloor
        self.minBoxAreaFraction = minBoxAreaFraction
        self.gapSeconds = gapSeconds
    }

    /// The §7.1 defaults, identical to the server's snapshot. Used when the
    /// server sent nothing parseable, so a malformed field can never silently
    /// widen a threshold.
    public static let defaults = PresenceThresholds()

    /// Parse the raw `presenceThresholds` JSON text from the join response.
    /// Every key falls back to its default independently; a malformed or empty
    /// string yields the defaults.
    public static func parse(json: String) -> PresenceThresholds {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return .defaults
        }
        let d = PresenceThresholds.defaults
        func int(_ key: String, _ fallback: Int) -> Int {
            if let v = dict[key] as? Int, v > 0 { return v }
            if let v = dict[key] as? Double, v > 0 { return Int(v) }
            return fallback
        }
        func double(_ key: String, _ fallback: Double) -> Double {
            if let v = dict[key] as? Double, v.isFinite, v >= 0 { return v }
            if let v = dict[key] as? Int { return Double(v) }
            return fallback
        }
        return PresenceThresholds(
            sampleIntervalMs: int("sampleIntervalMs", d.sampleIntervalMs),
            faceAbsentOpenMs: int("faceAbsentOpenMs", d.faceAbsentOpenMs),
            multipleFacesOpenMs: int("multipleFacesOpenMs", d.multipleFacesOpenMs),
            imageQualityOpenMs: int("imageQualityOpenMs", d.imageQualityOpenMs),
            closeMs: int("closeMs", d.closeMs),
            detectorConfidenceFloor: double("detectorConfidenceFloor", d.detectorConfidenceFloor),
            minBoxAreaFraction: double("minBoxAreaFraction", d.minBoxAreaFraction),
            gapSeconds: int("gapSeconds", d.gapSeconds))
    }

    // Seconds, for the state machine.
    var faceAbsentOpen: TimeInterval { TimeInterval(faceAbsentOpenMs) / 1000.0 }
    var multipleFacesOpen: TimeInterval { TimeInterval(multipleFacesOpenMs) / 1000.0 }
    var imageQualityOpen: TimeInterval { TimeInterval(imageQualityOpenMs) / 1000.0 }
    var close: TimeInterval { TimeInterval(closeMs) / 1000.0 }
    var sampleInterval: TimeInterval { TimeInterval(sampleIntervalMs) / 1000.0 }
}

// MARK: - Sample

/// One 500 ms observation. Five scalars — this is the WHOLE of what the client
/// knows about a frame, and the frame itself is gone by the time this exists.
///
/// `minConfidence` and `maxBoxAreaFraction` are facts about the VIDEO (how well
/// the face detector could see), never about the person. They feed
/// `image_quality_insufficient` only.
public struct PresenceSample: Equatable {
    public let faceCount: Int
    public let maxBoxAreaFraction: Double
    public let minConfidence: Double
    public let detectorFailed: Bool
    public let cameraMuted: Bool

    public init(faceCount: Int,
                maxBoxAreaFraction: Double,
                minConfidence: Double,
                detectorFailed: Bool,
                cameraMuted: Bool) {
        self.faceCount = faceCount
        self.maxBoxAreaFraction = maxBoxAreaFraction
        self.minConfidence = minConfidence
        self.detectorFailed = detectorFailed
        self.cameraMuted = cameraMuted
    }

    /// The sample a muted camera produces: no evidence of anything, and the
    /// §7.1 "camera unmuted" precondition for `face_absent` is false by
    /// construction.
    public static let cameraOff = PresenceSample(faceCount: 0,
                                                 maxBoxAreaFraction: 1.0,
                                                 minConfidence: 1.0,
                                                 detectorFailed: false,
                                                 cameraMuted: true)
}

// MARK: - Event

/// A closed presence event. String / Double / Int only, by design: there is no
/// member that could hold a `CVPixelBuffer`, an `NSImage`, a `Data`, a crop, a
/// thumbnail, a landmark set or a per-frame series, so "never send pixels" is a
/// property of the type rather than a rule someone has to remember.
public struct PresenceEvent: Equatable {

    /// One of `InterPresenceEventType`.
    public let eventType: String
    /// Unix epoch seconds (wall clock) at which the condition began holding.
    public let startedAt: Double
    /// Unix epoch seconds at which the condition stopped holding. Equal to
    /// `startedAt` for the instantaneous camera transitions.
    public let endedAt: Double
    /// `endedAt - startedAt` in whole milliseconds, never negative.
    public let durationMs: Int

    public init(eventType: String, startedAt: Double, endedAt: Double) {
        let end = max(startedAt, endedAt)
        self.eventType = eventType
        self.startedAt = startedAt
        self.endedAt = end
        // The server rejects a negative durationMs, so the clamp above is also
        // what keeps a clock that stepped backwards from producing one.
        self.durationMs = Int(((end - startedAt) * 1000.0).rounded())
    }

    /// Exactly the keys the server's ingest allowlist accepts
    /// (`token-server/presenceEvents.js` `ALLOWED_EVENT_KEYS`). Anything else in
    /// a payload is a 400 `PRESENCE_UNKNOWN_FIELD`, and the prohibited concepts
    /// are a 400 `PRESENCE_FORBIDDEN_FIELD`.
    public static let allowedPayloadKeys: [String] = [
        "eventType", "startedAt", "endedAt", "durationMs", "detectorVersion"
    ]

    /// THE single serialisation path. There is no other encoder, no
    /// `Codable` conformance and no dictionary built anywhere else in the
    /// presence pipeline, so a new field cannot reach the wire by accident.
    ///
    /// `detectorVersion` is emitted only when supplied; the server stamps its
    /// own from the session row and discards the client's either way.
    public func asPayload(detectorVersion: String = "") -> [String: Any] {
        var payload: [String: Any] = [
            "eventType": eventType,
            "startedAt": PresenceEvent.iso8601(startedAt),
            "endedAt": PresenceEvent.iso8601(endedAt),
            "durationMs": durationMs
        ]
        if !detectorVersion.isEmpty {
            payload["detectorVersion"] = detectorVersion
        }
        return payload
    }

    /// The server refuses a numeric timestamp (an epoch number is ambiguous
    /// between seconds and milliseconds and it will not guess), so every stamp
    /// goes out as ISO-8601 with fractional seconds in UTC.
    static func iso8601(_ epochSeconds: Double) -> String {
        return isoFormatter.string(from: Date(timeIntervalSince1970: epochSeconds))
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}

// MARK: - Engine

/// The hysteresis state machine.
///
/// ───────────────────────────────────────────────────────────────────────────
/// PRECEDENCE LOCK — fixed by the test suite, not by reading order
/// (the `deriveRemoteTileState` discipline from the consent-first moderation
/// spec). Read top to bottom; the first line that matches owns the sample.
///
///   cameraMuted                        -> emit the camera transition only;
///                                         close and DISCARD every other open
///                                         candidate; face_absent cannot open.
///   detectorFailed || quality < floor  -> feeds image_quality_insufficient
///                                         ONLY. It MUST NOT feed face_absent.
///   faceCount == 0 && quality >= floor -> feeds face_absent.
///   faceCount >= 2                     -> feeds multiple_faces, independently
///                                         of the quality branch: a frame can be
///                                         both multi-face and low quality and
///                                         the honest record is both.
/// ───────────────────────────────────────────────────────────────────────────
///
/// THE CRITICAL RULE — a detection failure is a data-quality fact about the
/// VIDEO, recorded as `image_quality_insufficient`, and NEVER as `face_absent`,
/// which would attribute it to the candidate's behaviour (research memo §7.1,
/// §4.1). Detection failure rates are not uniform across skin tones, lighting
/// or webcam quality; mislabelling a failure as absence converts an equipment
/// inequality into an accusation. Asserted directly in
/// `interTests/InterPresenceDetectorTests.swift`.
///
/// HYSTERESIS — open an event only after its condition has held continuously
/// for the open threshold; close it only after the condition has been clear
/// continuously for `closeMs`; DISCARD entirely any candidate that never
/// reached its open threshold, so transient detector noise never reaches the
/// store.
public final class InterPresenceEventEngine {

    // MARK: Candidate state

    /// One condition's hysteresis state. A "candidate" exists from the moment
    /// its condition first holds; it becomes an `isOpen` event only once the
    /// open threshold has elapsed.
    private struct Candidate {
        let eventType: String
        let openThreshold: TimeInterval
        /// When the condition first began holding continuously.
        var startedAt: Double?
        /// When the condition most recently stopped holding (nil while holding).
        var clearedAt: Double?
        /// True once `openThreshold` elapsed — only then is the event real.
        var isOpen: Bool = false

        mutating func reset() {
            startedAt = nil
            clearedAt = nil
            isOpen = false
        }
    }

    private let thresholds: PresenceThresholds
    private let multipleFacesEnabled: Bool

    private var faceAbsent: Candidate
    private var multipleFaces: Candidate
    private var imageQuality: Candidate

    /// The camera state the engine believes it is in. Seeded `false` (camera on)
    /// because monitoring is only ever started inside a live call; a candidate
    /// who joined with the camera already off therefore gets an honest
    /// `camera_disabled` on the first sample.
    private var cameraMuted: Bool = false

    public init(thresholds: PresenceThresholds, multipleFacesEnabled: Bool) {
        self.thresholds = thresholds
        self.multipleFacesEnabled = multipleFacesEnabled
        self.faceAbsent = Candidate(eventType: InterPresenceEventType.faceAbsent,
                                    openThreshold: thresholds.faceAbsentOpen)
        self.multipleFaces = Candidate(eventType: InterPresenceEventType.multipleFaces,
                                       openThreshold: thresholds.multipleFacesOpen)
        self.imageQuality = Candidate(eventType: InterPresenceEventType.imageQualityInsufficient,
                                      openThreshold: thresholds.imageQualityOpen)
    }

    // MARK: Condition derivation (pure)

    /// Whether the frame itself is too poor to judge. `detectorFailed` or a
    /// confidence/area below the floor. This is the ONLY consumer of
    /// `minConfidence` and `maxBoxAreaFraction`.
    public static func qualityInsufficient(_ sample: PresenceSample,
                                           thresholds: PresenceThresholds) -> Bool {
        if sample.detectorFailed { return true }
        if sample.minConfidence < thresholds.detectorConfidenceFloor { return true }
        if sample.maxBoxAreaFraction < thresholds.minBoxAreaFraction { return true }
        return false
    }

    // MARK: Ingest

    /// Feed one sample taken at `t` (Unix epoch seconds). Returns every event
    /// that CLOSED on this sample — events still in progress are not returned
    /// and events that never reached their threshold are never returned at all.
    public func ingest(_ sample: PresenceSample, at t: TimeInterval) -> [PresenceEvent] {
        var emitted: [PresenceEvent] = []

        // ── Precedence line 1: the camera. ───────────────────────────────────
        if sample.cameraMuted != cameraMuted {
            cameraMuted = sample.cameraMuted
            let type = cameraMuted
                ? InterPresenceEventType.cameraDisabled
                : InterPresenceEventType.cameraEnabled
            emitted.append(PresenceEvent(eventType: type, startedAt: t, endedAt: t))
        }

        if cameraMuted {
            // No frames, so no evidence. Every other candidate is DISCARDED,
            // not emitted: with the camera off the condition that opened it can
            // no longer be attributed to anything the candidate did.
            faceAbsent.reset()
            multipleFaces.reset()
            imageQuality.reset()
            return emitted
        }

        // ── Precedence lines 2-4. ────────────────────────────────────────────
        let qualityBad = InterPresenceEventEngine.qualityInsufficient(sample, thresholds: thresholds)

        // A detection failure or a frame the detector could not judge feeds
        // image_quality_insufficient ONLY.
        emitted += step(&imageQuality, condition: qualityBad, at: t)

        // face_absent requires an UNMUTED camera and a frame good enough to
        // trust. `!qualityBad` is the load-bearing clause: without it a webcam
        // the detector cannot read would be recorded as an absent candidate.
        emitted += step(&faceAbsent, condition: sample.faceCount == 0 && !qualityBad, at: t)

        // multiple_faces is independent of the quality branch. When the server
        // gate is off the engine does not even track the candidate, so a
        // suppressed event never exists as an uploadable object anywhere.
        if multipleFacesEnabled {
            emitted += step(&multipleFaces, condition: sample.faceCount >= 2, at: t)
        }

        return emitted
    }

    /// Close whatever is still open at stop. Only candidates that already
    /// passed their open threshold are emitted; the rest are discarded.
    public func flush(at t: TimeInterval) -> [PresenceEvent] {
        var emitted: [PresenceEvent] = []
        if let event = close(&imageQuality, at: t) { emitted.append(event) }
        if let event = close(&faceAbsent, at: t) { emitted.append(event) }
        if let event = close(&multipleFaces, at: t) { emitted.append(event) }
        return emitted
    }

    // MARK: Hysteresis

    private func step(_ candidate: inout Candidate,
                      condition: Bool,
                      at t: TimeInterval) -> [PresenceEvent] {
        if condition {
            // The condition holds: any pending clear was a flicker shorter than
            // the close threshold, so the SAME event continues. This is what
            // stops one real absence being split into two records.
            candidate.clearedAt = nil
            if candidate.startedAt == nil { candidate.startedAt = t }
            if let started = candidate.startedAt,
               !candidate.isOpen,
               (t - started) >= candidate.openThreshold {
                candidate.isOpen = true
            }
            return []
        }

        guard candidate.startedAt != nil else { return [] }
        if candidate.clearedAt == nil { candidate.clearedAt = t }
        guard let cleared = candidate.clearedAt, (t - cleared) >= thresholds.close else {
            return []
        }
        // Clear for long enough: close the event at the moment the condition
        // actually stopped holding, not at the moment we noticed.
        if let event = close(&candidate, at: cleared) {
            return [event]
        }
        return []
    }

    /// Emit a candidate if — and only if — it ever reached its open threshold,
    /// then reset it either way. The event ends when its condition stopped
    /// holding (`clearedAt`), falling back to `t` for the stop-time flush of a
    /// condition that is still holding.
    private func close(_ candidate: inout Candidate, at t: TimeInterval) -> PresenceEvent? {
        defer { candidate.reset() }
        guard candidate.isOpen, let started = candidate.startedAt else { return nil }
        return PresenceEvent(eventType: candidate.eventType,
                             startedAt: started,
                             endedAt: candidate.clearedAt ?? t)
    }
}
