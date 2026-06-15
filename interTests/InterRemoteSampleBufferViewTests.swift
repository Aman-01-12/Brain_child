// interTests/InterRemoteSampleBufferViewTests.swift
// Unit tests for CVPixelBuffer→CMSampleBuffer wrapping in InterRemoteSampleBufferView.

import XCTest
import CoreVideo
import CoreMedia
import AVFoundation
import AppKit
@testable import inter

final class InterRemoteSampleBufferViewTests: XCTestCase {

    private func makePixelBuffer(width: Int, height: Int, fmt: OSType) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        let r = CVPixelBufferCreate(kCFAllocatorDefault, width, height, fmt, attrs as CFDictionary, &pb)
        XCTAssertEqual(r, kCVReturnSuccess)
        return pb!
    }

    func test_wrap_nv12_producesValidSampleBuffer() {
        let pb = makePixelBuffer(width: 320, height: 240,
                                 fmt: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let sb = InterRemoteSampleBufferView.makeSampleBuffer(from: pb)
        XCTAssertNotNil(sb)
        XCTAssertTrue(CMSampleBufferIsValid(sb!))
        XCTAssertEqual(CMSampleBufferGetNumSamples(sb!), 1)
    }

    func test_wrap_bgra_producesValidSampleBuffer() {
        let pb = makePixelBuffer(width: 64, height: 64, fmt: kCVPixelFormatType_32BGRA)
        let sb = InterRemoteSampleBufferView.makeSampleBuffer(from: pb)
        XCTAssertNotNil(sb)
        XCTAssertTrue(CMSampleBufferIsValid(sb!))
    }

    // MARK: - Display-layer centering across resize (off-center regression)
    //
    // The display layer carries a mirror transform (scaleX:-1). Setting `.frame` on a
    // transformed layer is undefined per Apple's docs; the fix sizes+centers via
    // bounds+position and disables implicit actions so live resize can't animate the
    // geometry. NOTE: these are INVARIANT checks (the layer stays full-size and
    // centered after layout), not a strict mutation guard — the field bug is a
    // CoreAnimation timing effect during live-resize/transition animations that a
    // static layout test can't deterministically reproduce. They still catch gross
    // breakage (wrong size / off-center) and lock the documented contract.

    /// The AVSampleBufferDisplayLayer is the view layer's sole sublayer.
    private func displayLayer(of view: InterRemoteSampleBufferView) -> CALayer {
        let sub = view.layer?.sublayers?.first
        XCTAssertNotNil(sub, "expected the display layer as a sublayer")
        return sub!
    }

    private func assertCentered(_ view: InterRemoteSampleBufferView,
                                file: StaticString = #filePath, line: UInt = #line) {
        view.layoutSubtreeIfNeeded()
        let dl = displayLayer(of: view)
        XCTAssertEqual(dl.bounds.size.width, view.bounds.size.width, accuracy: 0.5,
                       "layer width must match view", file: file, line: line)
        XCTAssertEqual(dl.bounds.size.height, view.bounds.size.height, accuracy: 0.5,
                       "layer height must match view", file: file, line: line)
        XCTAssertEqual(dl.position.x, view.bounds.midX, accuracy: 0.5,
                       "layer must be horizontally centered", file: file, line: line)
        XCTAssertEqual(dl.position.y, view.bounds.midY, accuracy: 0.5,
                       "layer must be vertically centered", file: file, line: line)
    }

    func test_displayLayer_centeredAfterResize_withMirror() {
        let view = InterRemoteSampleBufferView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        XCTAssertTrue(view.isMirrored, "default is mirrored — the transform that broke .frame")
        assertCentered(view)

        // Simulate stage<->grid / window-resize size changes.
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        assertCentered(view)

        view.frame = NSRect(x: 0, y: 0, width: 480, height: 800) // portrait-ish
        assertCentered(view)

        view.frame = NSRect(x: 0, y: 0, width: 200, height: 120)
        assertCentered(view)
    }

    func test_displayLayer_centered_whenNotMirrored() {
        let view = InterRemoteSampleBufferView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        view.isMirrored = false
        view.frame = NSRect(x: 0, y: 0, width: 500, height: 250)
        assertCentered(view)
    }
}
