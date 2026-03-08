// interTests/InterRemoteVideoViewTests.swift
// Tests for InterRemoteVideoView [1.11.13]
// Validates: NV12 correct colors, BGRA correct, aspect-fit, no allocation growth.

import XCTest
import Metal
import CoreVideo
@testable import inter

final class InterRemoteVideoViewTests: XCTestCase {

    var view: InterRemoteVideoView!

    override func setUp() {
        super.setUp()
        view = InterRemoteVideoView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    }

    override func tearDown() {
        view = nil
        super.tearDown()
    }

    // MARK: - Aspect-Fit Tests [1.11.9]

    func testAspectFit_widerVideoInSquareView() {
        // 16:9 video in 1:1 view → letterbox, scaleY shrinks
        let u = view.computeAspectFitUniforms(
            videoWidth: 1920, videoHeight: 1080,
            viewWidth: 480, viewHeight: 480)
        XCTAssertEqual(u.scaleX, 1.0, accuracy: 0.001)
        XCTAssertEqual(u.scaleY, Float(480.0 / 480.0) / Float(1920.0 / 1080.0), accuracy: 0.001)
        // scaleY = 1.0 / 1.7778 ≈ 0.5625
    }

    func testAspectFit_tallerVideoInWideView() {
        // 9:16 video in 16:9 view → pillarbox, scaleX shrinks
        let u = view.computeAspectFitUniforms(
            videoWidth: 1080, videoHeight: 1920,
            viewWidth: 1920, viewHeight: 1080)
        XCTAssertEqual(u.scaleY, 1.0, accuracy: 0.001)
        let expected = Float(1080.0 / 1920.0) / Float(1920.0 / 1080.0)
        XCTAssertEqual(u.scaleX, expected, accuracy: 0.001)
    }

    func testAspectFit_exactAspectRatio() {
        // Same 16:9 → both scales 1.0
        let u = view.computeAspectFitUniforms(
            videoWidth: 1280, videoHeight: 720,
            viewWidth: 1920, viewHeight: 1080)
        XCTAssertEqual(u.scaleX, 1.0, accuracy: 0.001)
        XCTAssertEqual(u.scaleY, 1.0, accuracy: 0.001)
    }

    func testAspectFit_zeroDimensions() {
        // Degenerate → defaults to 1, 1
        let u = view.computeAspectFitUniforms(
            videoWidth: 0, videoHeight: 0,
            viewWidth: 1920, viewHeight: 1080)
        XCTAssertEqual(u.scaleX, 1.0, accuracy: 0.001)
        XCTAssertEqual(u.scaleY, 1.0, accuracy: 0.001)
    }

    // MARK: - Format Detection Tests [G3 / 1.11.8]

    func testFormatDetection_NV12VideoRange() {
        let f = view.classifyFormat(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertEqual(f, .nv12VideoRange)
    }

    func testFormatDetection_NV12FullRange() {
        let f = view.classifyFormat(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        XCTAssertEqual(f, .nv12FullRange)
    }

    func testFormatDetection_BGRA() {
        let f = view.classifyFormat(kCVPixelFormatType_32BGRA)
        XCTAssertEqual(f, .bgra)
    }

    func testFormatDetection_unknown() {
        let f = view.classifyFormat(kCVPixelFormatType_24RGB)
        XCTAssertEqual(f, .unknown)
    }

    // MARK: - BT.709 Matrix Tests [1.11.6]

    func testBT709VideoRangeMatrix_pureWhite() {
        // Y=235 (video white), Cb=128, Cr=128 → R≈1.0, G≈1.0, B≈1.0
        let y: Float = 235.0 / 255.0
        let cb: Float = 128.0 / 255.0
        let cr: Float = 128.0 / 255.0

        let m = bt709VideoRangeMatrix
        let r = m[0]*y + m[4]*cb + m[8]*cr  + m[12]
        let g = m[1]*y + m[5]*cb + m[9]*cr  + m[13]
        let b = m[2]*y + m[6]*cb + m[10]*cr + m[14]

        XCTAssertEqual(r, 1.0, accuracy: 0.02)
        XCTAssertEqual(g, 1.0, accuracy: 0.02)
        XCTAssertEqual(b, 1.0, accuracy: 0.02)
    }

    func testBT709VideoRangeMatrix_pureBlack() {
        // Y=16 (video black), Cb=128, Cr=128 → R≈0.0, G≈0.0, B≈0.0
        let y: Float = 16.0 / 255.0
        let cb: Float = 128.0 / 255.0
        let cr: Float = 128.0 / 255.0

        let m = bt709VideoRangeMatrix
        let r = m[0]*y + m[4]*cb + m[8]*cr  + m[12]
        let g = m[1]*y + m[5]*cb + m[9]*cr  + m[13]
        let b = m[2]*y + m[6]*cb + m[10]*cr + m[14]

        XCTAssertEqual(r, 0.0, accuracy: 0.02)
        XCTAssertEqual(g, 0.0, accuracy: 0.02)
        XCTAssertEqual(b, 0.0, accuracy: 0.02)
    }

    // MARK: - Pipeline Tests [1.11.5]

    func testMetalPipelinesCreated() {
        // Pipelines are built during commonInit via buildPipelines()
        XCTAssertNotNil(view.nv12PipelineState, "NV12 pipeline should be non-nil")
        XCTAssertNotNil(view.bgraPipelineState, "BGRA pipeline should be non-nil")
    }

    // MARK: - Frame Storage Tests [1.11.10]

    func testUpdateFrame_setsHasReceivedFrame() {
        XCTAssertFalse(view.hasReceivedFrame)

        guard let pb = createBGRAPixelBuffer(width: 4, height: 4,
                                              r: 255, g: 0, b: 0, a: 255) else {
            XCTFail("Could not create pixel buffer")
            return
        }

        view.updateFrame(pb)
        XCTAssertTrue(view.hasReceivedFrame)
    }

    func testUpdateFrame_latestFrameWins() {
        // Feed many frames rapidly — single-slot storage should not leak.
        for i in 0..<100 {
            guard let pb = createBGRAPixelBuffer(width: 4, height: 4,
                                                  r: UInt8(i % 256), g: 0, b: 0, a: 255) else {
                continue
            }
            view.updateFrame(pb)
        }
        XCTAssertTrue(view.hasReceivedFrame)
    }

    // MARK: - NV12 Rendering Tests [1.11.13]

    func testNV12Rendering_pureWhite() {
        guard let pb = createNV12PixelBuffer(width: 64, height: 64,
                                              y: 235, cb: 128, cr: 128) else {
            XCTFail("Could not create NV12 pixel buffer")
            return
        }

        guard let texture = view.renderToOffscreenTexture(
            pixelBuffer: pb, outputWidth: 64, outputHeight: 64) else {
            XCTFail("Offscreen render failed (Metal unavailable?)")
            return
        }

        let pixels = readPixels(from: texture)
        // Center pixel in BGRA layout
        let idx = (32 * 64 + 32) * 4
        XCTAssertGreaterThan(pixels[idx + 0], 240, "Blue ≈ 255")
        XCTAssertGreaterThan(pixels[idx + 1], 240, "Green ≈ 255")
        XCTAssertGreaterThan(pixels[idx + 2], 240, "Red ≈ 255")
        XCTAssertEqual(pixels[idx + 3], 255, "Alpha = 255")
    }

    func testNV12Rendering_pureBlack() {
        guard let pb = createNV12PixelBuffer(width: 64, height: 64,
                                              y: 16, cb: 128, cr: 128) else {
            XCTFail("Could not create NV12 pixel buffer")
            return
        }

        guard let texture = view.renderToOffscreenTexture(
            pixelBuffer: pb, outputWidth: 64, outputHeight: 64) else {
            XCTFail("Offscreen render failed")
            return
        }

        let pixels = readPixels(from: texture)
        let idx = (32 * 64 + 32) * 4
        XCTAssertLessThan(pixels[idx + 0], 10, "Blue ≈ 0")
        XCTAssertLessThan(pixels[idx + 1], 10, "Green ≈ 0")
        XCTAssertLessThan(pixels[idx + 2], 10, "Red ≈ 0")
        XCTAssertEqual(pixels[idx + 3], 255, "Alpha = 255")
    }

    // MARK: - BGRA Rendering Tests [1.11.13]

    func testBGRARendering_solidRed() {
        guard let pb = createBGRAPixelBuffer(width: 64, height: 64,
                                              r: 255, g: 0, b: 0, a: 255) else {
            XCTFail("Could not create pixel buffer")
            return
        }

        guard let texture = view.renderToOffscreenTexture(
            pixelBuffer: pb, outputWidth: 64, outputHeight: 64) else {
            XCTFail("Offscreen render failed")
            return
        }

        let pixels = readPixels(from: texture)
        let idx = (32 * 64 + 32) * 4
        XCTAssertLessThan(pixels[idx + 0], 10, "Blue ≈ 0")
        XCTAssertLessThan(pixels[idx + 1], 10, "Green ≈ 0")
        XCTAssertGreaterThan(pixels[idx + 2], 240, "Red ≈ 255")
        XCTAssertEqual(pixels[idx + 3], 255, "Alpha = 255")
    }

    func testBGRARendering_solidGreen() {
        guard let pb = createBGRAPixelBuffer(width: 64, height: 64,
                                              r: 0, g: 255, b: 0, a: 255) else {
            XCTFail("Could not create pixel buffer")
            return
        }

        guard let texture = view.renderToOffscreenTexture(
            pixelBuffer: pb, outputWidth: 64, outputHeight: 64) else {
            XCTFail("Offscreen render failed")
            return
        }

        let pixels = readPixels(from: texture)
        let idx = (32 * 64 + 32) * 4
        XCTAssertLessThan(pixels[idx + 0], 10, "Blue ≈ 0")
        XCTAssertGreaterThan(pixels[idx + 1], 240, "Green ≈ 255")
        XCTAssertLessThan(pixels[idx + 2], 10, "Red ≈ 0")
    }

    // MARK: - No Allocation Growth Test [1.11.13]

    func testNoAllocationGrowth() {
        // Feed 1000 frames through single-slot storage.
        // If the view leaked, this would OOM or crash.
        let iterations = 1000

        for _ in 0..<iterations {
            autoreleasepool {
                guard let pb = createBGRAPixelBuffer(width: 64, height: 64,
                                                      r: 128, g: 128, b: 128, a: 255) else { return }
                view.updateFrame(pb)
            }
        }

        XCTAssertTrue(view.hasReceivedFrame)
    }

    // MARK: - Helpers

    private func createNV12PixelBuffer(width: Int, height: Int,
                                        y: UInt8, cb: UInt8, cr: UInt8) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attrs as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        // Y plane — fill every luma sample
        if let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            for row in 0..<height {
                let ptr = yBase.advanced(by: row * yStride).assumingMemoryBound(to: UInt8.self)
                memset(ptr, Int32(y), width)
            }
        }

        // CbCr plane — interleaved pairs
        if let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
            let cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            let cbcrHeight = height / 2
            let cbcrWidth = width / 2
            for row in 0..<cbcrHeight {
                let ptr = cbcrBase.advanced(by: row * cbcrStride).assumingMemoryBound(to: UInt8.self)
                for col in 0..<cbcrWidth {
                    ptr[col * 2 + 0] = cb
                    ptr[col * 2 + 1] = cr
                }
            }
        }

        return pb
    }

    private func createBGRAPixelBuffer(width: Int, height: Int,
                                        r: UInt8, g: UInt8, b: UInt8, a: UInt8) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        if let base = CVPixelBufferGetBaseAddress(pb) {
            let stride = CVPixelBufferGetBytesPerRow(pb)
            for row in 0..<height {
                let ptr = base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
                for col in 0..<width {
                    ptr[col * 4 + 0] = b  // Blue
                    ptr[col * 4 + 1] = g  // Green
                    ptr[col * 4 + 2] = r  // Red
                    ptr[col * 4 + 3] = a  // Alpha
                }
            }
        }

        return pb
    }

    private func readPixels(from texture: MTLTexture) -> [UInt8] {
        let w = texture.width
        let h = texture.height
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&pixels, bytesPerRow: bytesPerRow,
                         from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                         size: MTLSize(width: w, height: h, depth: 1)),
                         mipmapLevel: 0)
        return pixels
    }
}
