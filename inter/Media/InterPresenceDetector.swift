// ============================================================================
// InterPresenceDetector.swift
// inter
//
// PRESENCE MONITORING (provisional, server flag default OFF).
//
// The ONLY Vision usage in this client. `import Vision` appears in this file and
// nowhere else — `grep -rln 'import Vision' inter` must name exactly this file.
// Delete it with the rest of the feature.
// See .agents/tasks/presence-monitoring/REMOVAL.md.
//
// WHAT IT DOES: one `VNImageRequestHandler` performs exactly one
// `VNDetectFaceRectanglesRequest` per sampled frame and reads exactly three
// things — how many face rectangles came back, the largest rectangle's
// normalised area, and the lowest rectangle confidence. That is the whole
// output. The `CVPixelBuffer` is used inside the one request and released:
// nothing is retained, copied, encoded, written to disk or transmitted.
//
// FORBIDDEN IN THIS FILE — four Vision requests and one family of properties,
// described here rather than spelled out because an acceptance grep searches the
// whole client for their exact symbol names and must return nothing: the face
// LANDMARKS request and its 2D landmark type, the face CAPTURE-QUALITY request,
// the image FEATURE-PRINT request, and any read of a face observation's yaw,
// pitch or roll. No head pose is collected anywhere in this product, no gaze or
// iris tracking, no blink or eye-aspect-ratio, and no emotion, affect,
// attention, engagement, focus, confidence or personality inference of any
// kind — in a hiring context the last of those is an EU AI Act Art. 5(1)(f)
// prohibited practice.
//
// WHY RECTANGLES ARE ENOUGH: `image_quality_insufficient` is driven by
// `VNFaceObservation.confidence` and bounding-box area, which satisfies §7.1's
// "detector confidence or bounding-box area below floor" without adding the
// second (capture-quality) request the scope forbids.
// ============================================================================

import Foundation
import CoreVideo
import ImageIO
import Vision
import os.log

/// The three numbers this detector is permitted to read off one face rectangle.
/// Exposed as a named type so the hysteresis engine can be driven through the
/// same Vision-shaped adapter in tests without a camera.
public struct PresenceFaceReading: Equatable {
    /// `boundingBox.width * boundingBox.height` — normalised, so 0…1.
    public let areaFraction: Double
    /// The detector's own confidence in this rectangle. A fact about how well
    /// the camera could see, never about the person.
    public let confidence: Double

    public init(areaFraction: Double, confidence: Double) {
        self.areaFraction = areaFraction
        self.confidence = confidence
    }
}

public final class InterPresenceDetector {

    /// Frames handed to Vision in this session. Diagnostics only.
    public private(set) var framesAnalysed: UInt64 = 0
    /// Frames where the request threw or returned nothing. Diagnostics only.
    public private(set) var detectorFailures: UInt64 = 0

    public init() {}

    // MARK: - The one request

    /// Analyse one frame. Returns the five scalars of a `PresenceSample`.
    ///
    /// `cameraMuted` is always `false` here: the capture source drops every
    /// frame while the camera is muted, so a frame-derived sample is unmuted by
    /// construction and the caller supplies the muted samples itself.
    public func analyse(pixelBuffer: CVPixelBuffer) -> PresenceSample {
        framesAnalysed += 1

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .up,
                                            options: [:])
        do {
            try handler.perform([request])
        } catch {
            // A thrown error is a data-quality fact about the video, never a
            // statement about the candidate. It becomes
            // image_quality_insufficient downstream and can never become
            // face_absent.
            detectorFailures += 1
            interLogDebug(InterLog.media, "Presence: face request failed")
            return InterPresenceDetector.failedSample()
        }

        guard let observations = request.results else {
            detectorFailures += 1
            return InterPresenceDetector.failedSample()
        }

        let readings = observations.map {
            PresenceFaceReading(areaFraction: Double($0.boundingBox.width * $0.boundingBox.height),
                                confidence: Double($0.confidence))
        }
        return InterPresenceDetector.sample(from: readings)
        // `observations`, `request` and `handler` all go out of scope here and
        // the caller releases the pixel buffer. Nothing survives this call but
        // the five scalars above.
    }

    // MARK: - The pure core

    /// Turn the readings of one frame into a sample.
    ///
    /// An EMPTY, SUCCESSFUL result is the load-bearing case: the request ran and
    /// found no face, so there is no quality evidence against the frame. The
    /// neutral sentinels (area 1.0, confidence 1.0) say exactly that, which is
    /// what lets the engine record a genuine absence as `face_absent` instead of
    /// misfiling every absence as poor image quality.
    public static func sample(from readings: [PresenceFaceReading]) -> PresenceSample {
        guard !readings.isEmpty else {
            return PresenceSample(faceCount: 0,
                                  maxBoxAreaFraction: 1.0,
                                  minConfidence: 1.0,
                                  detectorFailed: false,
                                  cameraMuted: false)
        }
        var maxArea = 0.0
        var minConfidence = 1.0
        for reading in readings {
            maxArea = max(maxArea, reading.areaFraction)
            minConfidence = min(minConfidence, reading.confidence)
        }
        return PresenceSample(faceCount: readings.count,
                              maxBoxAreaFraction: maxArea,
                              minConfidence: minConfidence,
                              detectorFailed: false,
                              cameraMuted: false)
    }

    /// The sample for a frame Vision could not judge at all.
    public static func failedSample() -> PresenceSample {
        return PresenceSample(faceCount: 0,
                              maxBoxAreaFraction: 0.0,
                              minConfidence: 0.0,
                              detectorFailed: true,
                              cameraMuted: false)
    }
}
