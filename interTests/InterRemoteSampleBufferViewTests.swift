// interTests/InterRemoteSampleBufferViewTests.swift
// Unit tests for CVPixelBuffer→CMSampleBuffer wrapping in InterRemoteSampleBufferView.

import XCTest
import CoreVideo
import CoreMedia
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
}
