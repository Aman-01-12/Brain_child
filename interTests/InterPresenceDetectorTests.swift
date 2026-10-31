// ============================================================================
// interTests/InterPresenceDetectorTests.swift
//
// PRESENCE MONITORING (provisional, server flag default OFF) — Phase 1.
//
// The hysteresis state machine (inter/Media/InterPresenceEventEngine.swift) and
// the Vision adapter's pure core (inter/Media/InterPresenceDetector.swift).
// Every case here comes from plan.md item 20; the three research-memo §7.8 cases
// are named individually below and are the point of the file:
//
//   1. testSubThresholdAbsence_emitsNothing
//   2. testFlickerInsideCloseThreshold_doesNotSplitOneEventInTwo
//   3. testZeroDetectionsWithLowCaptureQuality_isImageQuality_neverFaceAbsent
//
// The engine takes its time as a parameter, so none of this sleeps and none of
// it needs a camera. The engine is driven BOTH directly (as the pure core) and
// through the detector's reading → sample adapter, which is the shape a real
// VNDetectFaceRectanglesRequest result arrives in.
//
// DEVIATION from plan item 20, recorded on purpose: the adapter is fed
// `PresenceFaceReading` values rather than synthetic `VNFaceObservation`s.
// `VNFaceObservation.confidence` is read-only and cannot be synthesised, and the
// only public factory for one (`faceObservation(withRequestRevision:boundingBox:
// roll:yaw:)`) takes the head-pose arguments this feature must not touch at all.
// `InterPresenceDetector.sample(from:)` is the SHIPPING function that
// `analyse(pixelBuffer:)` calls with exactly these three numbers, so the tests
// still exercise production code — plus one real end-to-end Vision run on a
// blank frame below.
// ============================================================================

import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
@testable import inter

final class InterPresenceDetectorTests: XCTestCase {

    // MARK: - Fixtures

    private let thresholds = PresenceThresholds.defaults

    /// A sample with one well-seen face.
    private func presentSample() -> PresenceSample {
        return InterPresenceDetector.sample(from: [PresenceFaceReading(areaFraction: 0.09,
                                                                       confidence: 0.95)])
    }

    /// Two well-seen faces.
    private func twoFacesSample() -> PresenceSample {
        return InterPresenceDetector.sample(from: [
            PresenceFaceReading(areaFraction: 0.09, confidence: 0.95),
            PresenceFaceReading(areaFraction: 0.05, confidence: 0.88)
        ])
    }

    /// Two faces the detector could barely see — simultaneously multi-face and
    /// low quality, which is the precedence-lock case.
    private func twoFacesLowQualitySample() -> PresenceSample {
        return InterPresenceDetector.sample(from: [
            PresenceFaceReading(areaFraction: 0.09, confidence: 0.95),
            PresenceFaceReading(areaFraction: 0.004, confidence: 0.12)
        ])
    }

    /// Vision ran and found nobody. This is the adapter's EMPTY-but-successful
    /// result, which must route to `face_absent` and never to image quality.
    private func absentSample() -> PresenceSample {
        return InterPresenceDetector.sample(from: [])
    }

    /// Vision threw or returned nothing: a fact about the video.
    private func failedSample() -> PresenceSample {
        return InterPresenceDetector.failedSample()
    }

    private func lowConfidenceNoFaceSample() -> PresenceSample {
        // Constructed directly: zero faces AND a confidence below the floor.
        return PresenceSample(faceCount: 0,
                              maxBoxAreaFraction: 1.0,
                              minConfidence: 0.10,
                              detectorFailed: false,
                              cameraMuted: false)
    }

    private func mutedSample() -> PresenceSample {
        return PresenceSample.cameraOff
    }

    private func makeEngine(multipleFaces: Bool = true) -> InterPresenceEventEngine {
        return InterPresenceEventEngine(thresholds: thresholds, multipleFacesEnabled: multipleFaces)
    }

    /// Feed one sample repeatedly from `from` up to and including `to`, every
    /// `step` seconds (0.5 s = the shipped 2 Hz cadence), collecting everything
    /// the engine closes along the way.
    private func drive(_ engine: InterPresenceEventEngine,
                       _ sample: PresenceSample,
                       from: Double,
                       to: Double,
                       step: Double = 0.5) -> [PresenceEvent] {
        var events: [PresenceEvent] = []
        var t = from
        while t <= to + 1e-9 {
            events += engine.ingest(sample, at: t)
            t += step
        }
        return events
    }

    private func types(_ events: [PresenceEvent]) -> [String] {
        return events.map { $0.eventType }
    }

    // MARK: - §7.8 case 1 — a sub-threshold event emits nothing

    func testSubThresholdAbsence_emitsNothing() {
        let engine = makeEngine()
        // 9.5 s of nobody (samples 0.0 … 9.5), then the candidate is back.
        var events = drive(engine, absentSample(), from: 0.0, to: 9.5)
        // Hold the present state long past the 1.0 s close threshold.
        events += drive(engine, presentSample(), from: 10.0, to: 12.0)

        XCTAssertTrue(events.isEmpty,
                      "9.5 s of absence never reached the 10.0 s open threshold, so the "
                      + "candidate event must be DISCARDED entirely — transient detector "
                      + "noise must never reach the store. Got \(types(events)).")
        XCTAssertTrue(engine.flush(at: 20.0).isEmpty, "nothing may be left open")
    }

    func testSubThresholdMultipleFaces_emitsNothing() {
        let engine = makeEngine(multipleFaces: true)
        var events = drive(engine, twoFacesSample(), from: 0.0, to: 2.5)
        events += drive(engine, presentSample(), from: 3.0, to: 5.0)
        XCTAssertTrue(events.isEmpty,
                      "2.5 s of two faces is below the 3.0 s open threshold. Got \(types(events)).")
    }

    func testSubThresholdImageQuality_emitsNothing() {
        let engine = makeEngine()
        var events = drive(engine, failedSample(), from: 0.0, to: 14.0)
        events += drive(engine, presentSample(), from: 14.5, to: 16.5)
        XCTAssertTrue(events.isEmpty,
                      "14 s of unreadable video is below the 15.0 s open threshold. "
                      + "Got \(types(events)).")
    }

    // MARK: - §7.8 case 2 — flicker must not split one event in two

    func testFlickerInsideCloseThreshold_doesNotSplitOneEventInTwo() {
        let engine = makeEngine()
        // Nobody from 0.0 to 9.5 …
        var events = drive(engine, absentSample(), from: 0.0, to: 9.5)
        // … one 0.5 s blip of a face at 10.0 (shorter than the 1.0 s close) …
        events += engine.ingest(presentSample(), at: 10.0)
        // … then nobody again until 20.0.
        events += drive(engine, absentSample(), from: 10.5, to: 20.0)
        XCTAssertTrue(events.isEmpty, "nothing closes while the absence is still in progress")

        // The candidate returns for good at 20.5 and stays.
        events += drive(engine, presentSample(), from: 20.5, to: 22.0)

        XCTAssertEqual(types(events), [InterPresenceEventType.faceAbsent],
                       "a 0.5 s blip inside the 1.0 s close threshold must NOT split the "
                       + "absence into two records. Got \(types(events)).")
        XCTAssertEqual(events.first?.startedAt, 0.0)
        XCTAssertEqual(events.first?.endedAt, 20.5,
                       "the event ends when the condition actually cleared, not when we noticed")
        XCTAssertEqual(events.first?.durationMs, 20_500)
    }

    func testRecoveryLongerThanCloseThreshold_splitsIntoTwoEvents() {
        let engine = makeEngine()
        var events = drive(engine, absentSample(), from: 0.0, to: 14.5)
        // 1.5 s of presence — past the 1.0 s close threshold, so the first
        // event is finished.
        events += drive(engine, presentSample(), from: 15.0, to: 16.5)
        events += drive(engine, absentSample(), from: 17.0, to: 30.0)
        events += drive(engine, presentSample(), from: 30.5, to: 32.0)

        XCTAssertEqual(types(events),
                       [InterPresenceEventType.faceAbsent, InterPresenceEventType.faceAbsent],
                       "a 1.5 s recovery is a genuine return, so the record is two events. "
                       + "Got \(types(events)).")
        XCTAssertEqual(events.first?.startedAt, 0.0)
        XCTAssertEqual(events.first?.endedAt, 15.0)
        XCTAssertEqual(events.last?.startedAt, 17.0)
        XCTAssertEqual(events.last?.endedAt, 30.5)
    }

    // MARK: - §7.8 case 3 — a detection failure is NEVER face_absent

    func testZeroDetectionsWithLowCaptureQuality_isImageQuality_neverFaceAbsent() {
        let engine = makeEngine()
        // 30 s where the detector could not judge the frame at all.
        var events = drive(engine, failedSample(), from: 0.0, to: 30.0)
        events += drive(engine, presentSample(), from: 30.5, to: 32.0)

        XCTAssertEqual(types(events), [InterPresenceEventType.imageQualityInsufficient],
                       "a detection failure is a data-quality fact about the VIDEO. "
                       + "Got \(types(events)).")
        XCTAssertFalse(events.contains { $0.eventType == InterPresenceEventType.faceAbsent },
                       "THE critical rule (§7.1, §4.1): a detection failure must NEVER be "
                       + "recorded as face_absent, which would attribute an equipment or "
                       + "lighting inequality to the candidate's behaviour.")
    }

    func testZeroDetectionsWithConfidenceBelowFloor_isImageQuality_neverFaceAbsent() {
        let engine = makeEngine()
        var events = drive(engine, lowConfidenceNoFaceSample(), from: 0.0, to: 30.0)
        events += drive(engine, presentSample(), from: 30.5, to: 32.0)

        XCTAssertEqual(types(events), [InterPresenceEventType.imageQualityInsufficient],
                       "confidence below the 0.35 floor is a quality objection, not an absence. "
                       + "Got \(types(events)).")
        XCTAssertFalse(events.contains { $0.eventType == InterPresenceEventType.faceAbsent },
                       "a frame the detector could not trust must never be recorded as "
                       + "face_absent")
    }

    func testBoxAreaBelowFloor_isImageQuality_neverFaceAbsent() {
        let engine = makeEngine()
        // One face, but a tiny box: too far away or too low-resolution to judge.
        let tiny = InterPresenceDetector.sample(from: [PresenceFaceReading(areaFraction: 0.004,
                                                                           confidence: 0.9)])
        var events = drive(engine, tiny, from: 0.0, to: 30.0)
        events += drive(engine, presentSample(), from: 30.5, to: 32.0)

        XCTAssertEqual(types(events), [InterPresenceEventType.imageQualityInsufficient])
        XCTAssertFalse(events.contains { $0.eventType == InterPresenceEventType.faceAbsent })
    }

    /// The empty-but-successful Vision result must NOT be mistaken for poor
    /// quality: that is what keeps a real absence recordable at all.
    func testEmptySuccessfulDetection_yieldsFaceAbsent_notImageQuality() {
        let engine = makeEngine()
        var events = drive(engine, absentSample(), from: 0.0, to: 12.0)
        events += drive(engine, presentSample(), from: 12.5, to: 14.0)

        XCTAssertEqual(types(events), [InterPresenceEventType.faceAbsent],
                       "Vision ran and found nobody — there is no quality objection against "
                       + "the frame, so the honest record is face_absent. Got \(types(events)).")
    }

    // MARK: - Camera-muted suppression

    func testCameraMuted_suppressesFaceAbsent_andEmitsTransitionsOnly() {
        let engine = makeEngine()
        // 60 s with the camera off and nobody in frame.
        let events = drive(engine, mutedSample(), from: 0.0, to: 60.0)

        XCTAssertEqual(types(events), [InterPresenceEventType.cameraDisabled],
                       "with the camera off there is no evidence of anything, so the only "
                       + "honest record is the single transition. Got \(types(events)).")
        XCTAssertFalse(events.contains { $0.eventType == InterPresenceEventType.faceAbsent },
                       "a muted camera must never produce face_absent — §7.1 requires the "
                       + "camera to be unmuted before absence means anything")
        XCTAssertEqual(events.first?.durationMs, 0, "a camera transition is instantaneous")
        XCTAssertEqual(events.first?.startedAt, events.first?.endedAt)
    }

    func testUnmuting_emitsCameraEnabledWithZeroDuration() {
        let engine = makeEngine()
        _ = drive(engine, mutedSample(), from: 0.0, to: 10.0)
        let events = engine.ingest(presentSample(), at: 10.5)

        XCTAssertEqual(types(events), [InterPresenceEventType.cameraEnabled])
        XCTAssertEqual(events.first?.durationMs, 0)
        XCTAssertEqual(events.first?.startedAt, 10.5)
        XCTAssertEqual(events.first?.endedAt, 10.5)
    }

    func testMutingDiscardsAnOpenAbsence() {
        let engine = makeEngine()
        // An absence that is already past its open threshold …
        var events = drive(engine, absentSample(), from: 0.0, to: 12.0)
        XCTAssertTrue(events.isEmpty)
        // … then the camera goes off.
        events += engine.ingest(mutedSample(), at: 12.5)

        XCTAssertEqual(types(events), [InterPresenceEventType.cameraDisabled],
                       "the precedence lock closes and DISCARDS every other open candidate "
                       + "when the camera is muted. Got \(types(events)).")
        XCTAssertTrue(engine.flush(at: 60.0).isEmpty,
                      "the discarded absence must not reappear at flush")
    }

    // MARK: - Precedence lock

    func testTwoFacesAndLowQuality_emitsBoth_andNeverFaceAbsent() {
        let engine = makeEngine(multipleFaces: true)
        var events = drive(engine, twoFacesLowQualitySample(), from: 0.0, to: 20.0)
        events += drive(engine, presentSample(), from: 20.5, to: 22.0)

        let emitted = Set(types(events))
        XCTAssertTrue(emitted.contains(InterPresenceEventType.multipleFaces),
                      "a frame can be both multi-face and low quality and the honest record "
                      + "is both. Got \(types(events)).")
        XCTAssertTrue(emitted.contains(InterPresenceEventType.imageQualityInsufficient),
                      "the quality branch is independent of the face-count branch")
        XCTAssertFalse(emitted.contains(InterPresenceEventType.faceAbsent),
                       "two faces are present, so absence is impossible")
        XCTAssertEqual(events.count, 2, "exactly one of each. Got \(types(events)).")
    }

    func testEngineEmitsOnlyTheFiveKnownTypes() {
        let engine = makeEngine(multipleFaces: true)
        var events = drive(engine, mutedSample(), from: 0.0, to: 2.0)
        events += drive(engine, absentSample(), from: 2.5, to: 15.0)
        events += drive(engine, twoFacesLowQualitySample(), from: 15.5, to: 40.0)
        events += drive(engine, presentSample(), from: 40.5, to: 43.0)
        events += engine.flush(at: 44.0)

        for type in types(events) {
            XCTAssertTrue(InterPresenceEventType.all.contains(type),
                          "unexpected event type '\(type)' — the engine may only ever emit "
                          + "\(InterPresenceEventType.all)")
        }
        XCTAssertFalse(types(events).contains("head_off_axis"),
                       "head pose does not exist in this build and must not be constructible")
        XCTAssertFalse(types(events).contains("monitoring_gap"),
                       "monitoring_gap is server-generated; a client must never construct it")
    }

    // MARK: - multiple_faces is OFF by default

    func testMultipleFacesDisabled_neverConstructsTheEvent() {
        let engine = makeEngine(multipleFaces: false)
        var events = drive(engine, twoFacesSample(), from: 0.0, to: 30.0)
        events += drive(engine, presentSample(), from: 30.5, to: 32.0)

        XCTAssertTrue(events.isEmpty,
                      "with the server gate off the engine must NEVER CONSTRUCT a "
                      + "multiple_faces event — suppression happens at the engine, not as a "
                      + "filter at upload, so a suppressed event never exists as an "
                      + "uploadable object. Got \(types(events)).")
        XCTAssertTrue(engine.flush(at: 40.0).isEmpty)
    }

    func testMultipleFacesDisabled_leavesFaceAbsentUnaffected() {
        let engine = makeEngine(multipleFaces: false)
        var events = drive(engine, absentSample(), from: 0.0, to: 12.0)
        events += drive(engine, presentSample(), from: 12.5, to: 14.0)
        XCTAssertEqual(types(events), [InterPresenceEventType.faceAbsent],
                       "the multiple_faces gate must not disturb the other types")
    }

    // MARK: - Exact threshold boundaries

    func testFaceAbsentOpenThresholdBoundary() {
        // 9.999 s: below the threshold ⇒ discarded.
        let below = makeEngine()
        _ = below.ingest(absentSample(), at: 0.0)
        _ = below.ingest(absentSample(), at: 9.999)
        var events = below.ingest(presentSample(), at: 10.5)
        events += below.ingest(presentSample(), at: 11.5)
        XCTAssertTrue(events.isEmpty, "9.999 s < 10.0 s ⇒ nothing. Got \(types(events)).")

        // 10.001 s: at or past the threshold ⇒ one event.
        let above = makeEngine()
        _ = above.ingest(absentSample(), at: 0.0)
        _ = above.ingest(absentSample(), at: 10.001)
        var opened = above.ingest(presentSample(), at: 11.0)
        opened += above.ingest(presentSample(), at: 12.001)
        XCTAssertEqual(types(opened), [InterPresenceEventType.faceAbsent],
                       "10.001 s ≥ 10.0 s ⇒ one event. Got \(types(opened)).")
        XCTAssertEqual(opened.first?.endedAt, 11.0)
    }

    func testMultipleFacesOpenThresholdBoundary() {
        let below = makeEngine(multipleFaces: true)
        _ = below.ingest(twoFacesSample(), at: 0.0)
        _ = below.ingest(twoFacesSample(), at: 2.999)
        var events = below.ingest(presentSample(), at: 3.5)
        events += below.ingest(presentSample(), at: 4.5)
        XCTAssertTrue(events.isEmpty, "2.999 s < 3.0 s ⇒ nothing. Got \(types(events)).")

        let above = makeEngine(multipleFaces: true)
        _ = above.ingest(twoFacesSample(), at: 0.0)
        _ = above.ingest(twoFacesSample(), at: 3.001)
        var opened = above.ingest(presentSample(), at: 4.0)
        opened += above.ingest(presentSample(), at: 5.001)
        XCTAssertEqual(types(opened), [InterPresenceEventType.multipleFaces])
    }

    func testImageQualityOpenThresholdBoundary() {
        let below = makeEngine()
        _ = below.ingest(failedSample(), at: 0.0)
        _ = below.ingest(failedSample(), at: 14.999)
        var events = below.ingest(presentSample(), at: 15.5)
        events += below.ingest(presentSample(), at: 16.5)
        XCTAssertTrue(events.isEmpty, "14.999 s < 15.0 s ⇒ nothing. Got \(types(events)).")

        let above = makeEngine()
        _ = above.ingest(failedSample(), at: 0.0)
        _ = above.ingest(failedSample(), at: 15.001)
        var opened = above.ingest(presentSample(), at: 16.0)
        opened += above.ingest(presentSample(), at: 17.001)
        XCTAssertEqual(types(opened), [InterPresenceEventType.imageQualityInsufficient])
    }

    func testCloseThresholdBoundary() {
        // Clear for exactly 1.0 s closes the event (the comparison is >=).
        let engine = makeEngine()
        _ = engine.ingest(absentSample(), at: 0.0)
        _ = engine.ingest(absentSample(), at: 11.0)
        XCTAssertTrue(engine.ingest(presentSample(), at: 11.5).isEmpty,
                      "the event stays open while the clear is shorter than 1.0 s")
        let events = engine.ingest(presentSample(), at: 12.5)
        XCTAssertEqual(types(events), [InterPresenceEventType.faceAbsent])
        XCTAssertEqual(events.first?.endedAt, 11.5,
                       "the event ends at the moment the condition cleared")
    }

    // MARK: - flush at stop

    func testFlushClosesAnOpenEvent() {
        let engine = makeEngine()
        _ = drive(engine, absentSample(), from: 0.0, to: 12.0)
        let events = engine.flush(at: 20.0)

        XCTAssertEqual(types(events), [InterPresenceEventType.faceAbsent],
                       "hanging up mid-absence must still record the absence. "
                       + "Got \(types(events)).")
        XCTAssertEqual(events.first?.startedAt, 0.0)
        XCTAssertEqual(events.first?.endedAt, 20.0)
        XCTAssertEqual(events.first?.durationMs, 20_000)
        XCTAssertTrue(engine.flush(at: 21.0).isEmpty, "flush is not repeatable — state is reset")
    }

    func testFlushDiscardsASubThresholdEvent() {
        let engine = makeEngine()
        _ = drive(engine, absentSample(), from: 0.0, to: 5.0)
        XCTAssertTrue(engine.flush(at: 6.0).isEmpty,
                      "a candidate that never reached its open threshold is discarded at stop "
                      + "exactly as it is mid-session")
    }

    // MARK: - No forbidden output

    func testPayloadKeysAreExactlyTheServerAllowlist() {
        let engine = makeEngine()
        _ = drive(engine, absentSample(), from: 0.0, to: 12.0)
        let events = engine.flush(at: 20.0)
        guard let event = events.first else { return XCTFail("expected one event") }

        let bare = event.asPayload()
        XCTAssertEqual(Set(bare.keys), ["eventType", "startedAt", "endedAt", "durationMs"],
                       "asPayload() is the ONLY serialisation path and emits exactly these keys")

        let stamped = event.asPayload(detectorVersion: "presence-1.0.0")
        XCTAssertEqual(Set(stamped.keys),
                       ["eventType", "startedAt", "endedAt", "durationMs", "detectorVersion"])
        XCTAssertTrue(Set(stamped.keys).isSubset(of: Set(PresenceEvent.allowedPayloadKeys)),
                      "every emitted key must be in the server's ALLOWED_EVENT_KEYS or the "
                      + "batch is a 400 PRESENCE_UNKNOWN_FIELD")
    }

    func testPayloadCarriesNoForbiddenConcept() {
        let engine = makeEngine(multipleFaces: true)
        _ = drive(engine, twoFacesLowQualitySample(), from: 0.0, to: 20.0)
        let events = engine.flush(at: 21.0) + [PresenceEvent(eventType: InterPresenceEventType.cameraDisabled,
                                                             startedAt: 1.0, endedAt: 1.0)]
        XCTAssertFalse(events.isEmpty)

        let forbidden = ["score", "confidence", "emotion", "landmarks", "yaw", "pitch", "roll",
                         "attention", "engagement", "gaze", "iris", "blink", "image", "frame",
                         "thumbnail", "crop", "rating", "risk"]
        for event in events {
            let payload = event.asPayload(detectorVersion: "presence-1.0.0")
            for key in payload.keys {
                let lower = key.lowercased()
                for word in forbidden {
                    XCTAssertFalse(lower.contains(word),
                                   "payload key '\(key)' names the prohibited concept '\(word)'")
                }
            }
            // Values are scalars only. A pixel buffer, an image or a Data could
            // not be constructed into a PresenceEvent in the first place, and
            // this pins the serialised side too.
            for (key, value) in payload {
                XCTAssertTrue(value is String || value is Int,
                              "payload value for '\(key)' must be a String or an Int, got "
                              + "\(type(of: value))")
            }
        }
    }

    func testPayloadTimestampsAreISO8601Strings() {
        let event = PresenceEvent(eventType: InterPresenceEventType.faceAbsent,
                                  startedAt: 1_762_000_000.5,
                                  endedAt: 1_762_000_012.5)
        let payload = event.asPayload(detectorVersion: "presence-1.0.0")

        guard let startedAt = payload["startedAt"] as? String,
              let endedAt = payload["endedAt"] as? String else {
            return XCTFail("the server refuses a numeric timestamp with 400 PRESENCE_PAYLOAD_INVALID")
        }
        XCTAssertTrue(startedAt.hasSuffix("Z"), "stamps go out in UTC: \(startedAt)")
        XCTAssertTrue(startedAt.contains("."), "with fractional seconds: \(startedAt)")
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertNotNil(parser.date(from: startedAt))
        XCTAssertNotNil(parser.date(from: endedAt))
        XCTAssertEqual(payload["durationMs"] as? Int, 12_000)
    }

    // MARK: - The Vision adapter's pure core

    func testAdapterReadsOnlyCountAreaAndConfidence() {
        let sample = InterPresenceDetector.sample(from: [
            PresenceFaceReading(areaFraction: 0.20, confidence: 0.91),
            PresenceFaceReading(areaFraction: 0.05, confidence: 0.44)
        ])
        XCTAssertEqual(sample.faceCount, 2)
        XCTAssertEqual(sample.maxBoxAreaFraction, 0.20, accuracy: 1e-9,
                       "the LARGEST box area is what the quality floor is judged against")
        XCTAssertEqual(sample.minConfidence, 0.44, accuracy: 1e-9,
                       "the LOWEST confidence is what the quality floor is judged against")
        XCTAssertFalse(sample.detectorFailed)
        XCTAssertFalse(sample.cameraMuted)
    }

    func testAdapterEmptyResultIsNotAQualityObjection() {
        let sample = InterPresenceDetector.sample(from: [])
        XCTAssertEqual(sample.faceCount, 0)
        XCTAssertFalse(sample.detectorFailed, "the request succeeded; it just found nobody")
        XCTAssertFalse(InterPresenceEventEngine.qualityInsufficient(sample, thresholds: thresholds),
                       "an empty but successful result carries no evidence against the frame, "
                       + "which is what lets a genuine absence be recorded as face_absent")
    }

    func testAdapterFailedSampleIsAQualityObjection() {
        let sample = InterPresenceDetector.failedSample()
        XCTAssertTrue(sample.detectorFailed)
        XCTAssertTrue(InterPresenceEventEngine.qualityInsufficient(sample, thresholds: thresholds))
    }

    /// One real end-to-end run: a blank BGRA frame through the shipping
    /// `analyse(pixelBuffer:)`, i.e. through a real
    /// `VNDetectFaceRectanglesRequest`. A blank frame contains no face, so the
    /// only acceptable answers are "no faces" or "could not judge" — never a
    /// face, and never a crash.
    func testAnalyseBlankFrame_findsNoFace() {
        guard let pixelBuffer = createBlankPixelBuffer(width: 640, height: 480) else {
            return XCTFail("could not allocate a test pixel buffer")
        }
        let detector = InterPresenceDetector()
        let sample = detector.analyse(pixelBuffer: pixelBuffer)

        XCTAssertEqual(sample.faceCount, 0, "a blank frame contains no face")
        XCTAssertFalse(sample.cameraMuted,
                       "a frame-derived sample is unmuted by construction — the capture source "
                       + "drops every frame while the camera is muted")
        XCTAssertEqual(detector.framesAnalysed, 1)
        if sample.detectorFailed {
            XCTAssertEqual(detector.detectorFailures, 1,
                           "a failure is counted and becomes image_quality_insufficient, "
                           + "never face_absent")
        }
    }

    // MARK: - Thresholds from the wire

    func testThresholdsParseTheServerSnapshot() {
        // The exact shape token-server/presenceConfig.js thresholdSnapshot()
        // writes into the room hash and /room/join returns as a STRING.
        let json = """
        {"sampleIntervalMs":500,"faceAbsentOpenMs":10000,"multipleFacesOpenMs":3000,\
        "imageQualityOpenMs":15000,"closeMs":1000,"detectorConfidenceFloor":0.35,\
        "minBoxAreaFraction":0.01,"gapSeconds":60}
        """
        let parsed = PresenceThresholds.parse(json: json)
        XCTAssertEqual(parsed, PresenceThresholds.defaults,
                       "the shipped defaults must match the server's snapshot exactly, or the "
                       + "stored thresholds would not describe what actually ran")
        XCTAssertEqual(parsed.faceAbsentOpenMs, 10_000)
        XCTAssertEqual(parsed.multipleFacesOpenMs, 3_000)
        XCTAssertEqual(parsed.imageQualityOpenMs, 15_000)
        XCTAssertEqual(parsed.closeMs, 1_000)
        XCTAssertEqual(parsed.detectorConfidenceFloor, 0.35, accuracy: 1e-9)
        XCTAssertEqual(parsed.minBoxAreaFraction, 0.01, accuracy: 1e-9)
    }

    func testThresholdsFallBackToDefaults() {
        XCTAssertEqual(PresenceThresholds.parse(json: ""), PresenceThresholds.defaults)
        XCTAssertEqual(PresenceThresholds.parse(json: "not json"), PresenceThresholds.defaults)
        XCTAssertEqual(PresenceThresholds.parse(json: "{}"), PresenceThresholds.defaults)
        // A malformed single field must not silently widen a threshold.
        let partial = PresenceThresholds.parse(json: #"{"faceAbsentOpenMs":"soon"}"#)
        XCTAssertEqual(partial.faceAbsentOpenMs, 10_000)
    }

    // MARK: - Helpers

    private func createBlankPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA,
                                         attributes as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0x20, CVPixelBufferGetBytesPerRow(buffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
