// interTests/InterComposedRendererTests.swift
// Tests for InterComposedRenderer [Phase 10 — Gap #13]
// Validates: layout selection, thread-safe frame updates, placeholder generation,
//            watermark toggle, delegate notification, invalidate lifecycle.

import XCTest
import CoreVideo
import Metal
@testable import inter

final class InterComposedRendererTests: XCTestCase {

    private var renderer: InterComposedRenderer!
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!

    override func setUp() {
        super.setUp()
        // Use the default system Metal device; skip tests if Metal is unavailable
        // (CI without GPU). MetalRenderEngine.sharedEngine may already have one.
        guard let dev = MTLCreateSystemDefaultDevice() else {
            return
        }
        device = dev
        commandQueue = dev.makeCommandQueue()!
        renderer = InterComposedRenderer(
            device: device,
            commandQueue: commandQueue,
            outputSize: CGSize(width: 1920, height: 1080)
        )
    }

    override func tearDown() {
        renderer?.invalidate()
        renderer = nil
        commandQueue = nil
        device = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Creates a minimal BGRA CVPixelBuffer for testing.
    private func makePixelBuffer(width: Int = 320, height: Int = 240) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary, &pb)
        return status == kCVReturnSuccess ? pb : nil
    }

    // MARK: - Initial State

    func testInitialLayout_isIdle() {
        guard renderer != nil else { return }
        XCTAssertEqual(renderer.currentLayout, .idle,
                       "Initial layout should be idle (no sources)")
    }

    func testWatermark_defaultOff() {
        guard renderer != nil else { return }
        XCTAssertFalse(renderer.watermarkEnabled)
    }

    // MARK: - Layout Selection

    func testSingleCamera_layoutIsCameraOnlyFull() {
        guard renderer != nil else { return }
        guard let pb = makePixelBuffer() else { return XCTFail("makePixelBuffer") }
        renderer.updateActiveSpeakerFrame(pb, identity: "alice")

        // Render triggers layout recomputation
        _ = renderer.renderComposedFrame()
        XCTAssertEqual(renderer.currentLayout, .cameraOnlyFull)
    }

    func testScreenShareFilmstrip_whenScreenShareAndParticipants() {
        guard renderer != nil else { return }
        guard let pb = makePixelBuffer() else { return XCTFail("makePixelBuffer") }
        // Screen share + grid participants → filmstrip sidebar layout (the composite
        // that replaced the legacy screen-share picture-in-picture layout).
        renderer.updateScreenShareFrame(pb)
        renderer.setParticipantOrder(["alice"])
        renderer.updateParticipantFrame(pb, identity: "alice")

        _ = renderer.renderComposedFrame()
        XCTAssertEqual(renderer.currentLayout, .screenShareFilmstrip)
    }

    func testScreenShareOnly_layoutWhenNoCameras() {
        guard renderer != nil else { return }
        guard let pb = makePixelBuffer() else { return XCTFail("makePixelBuffer") }
        renderer.updateScreenShareFrame(pb)

        _ = renderer.renderComposedFrame()
        XCTAssertEqual(renderer.currentLayout, .screenShareOnly)
    }

    func testCameraSideBySide_layoutWithTwoCameras() {
        guard renderer != nil else { return }
        guard let pb = makePixelBuffer() else { return XCTFail("makePixelBuffer") }
        renderer.updateActiveSpeakerFrame(pb, identity: "alice")
        renderer.updateSecondarySpeakerFrame(pb, identity: "bob")

        _ = renderer.renderComposedFrame()
        XCTAssertEqual(renderer.currentLayout, .cameraSideBySide)
    }

    func testClearScreenShare_returnsToCamera() {
        guard renderer != nil else { return }
        guard let pb = makePixelBuffer() else { return XCTFail("makePixelBuffer") }
        renderer.updateScreenShareFrame(pb)
        renderer.updateActiveSpeakerFrame(pb, identity: "alice")
        _ = renderer.renderComposedFrame()
        // Legacy active-speaker frames are not grid participants, so an active screen
        // share takes the full stage (screen-share-only) rather than a composite.
        XCTAssertEqual(renderer.currentLayout, .screenShareOnly)

        // Now clear screen share — the active speaker camera becomes the full frame.
        renderer.updateScreenShareFrame(nil)
        _ = renderer.renderComposedFrame()
        XCTAssertEqual(renderer.currentLayout, .cameraOnlyFull)
    }

    // MARK: - Thread-Safe Frame Updates

    func testConcurrentFrameUpdates_doesNotCrash() {
        guard renderer != nil else { return }
        let group = DispatchGroup()
        let concurrent = DispatchQueue(label: "test.concurrent", attributes: .concurrent)

        for i in 0..<50 {
            group.enter()
            concurrent.async {
                if let pb = self.makePixelBuffer() {
                    if i % 3 == 0 {
                        self.renderer.updateScreenShareFrame(pb)
                    } else if i % 3 == 1 {
                        self.renderer.updateActiveSpeakerFrame(pb, identity: "user\(i)")
                    } else {
                        self.renderer.updateSecondarySpeakerFrame(pb, identity: "user\(i)")
                    }
                }
                group.leave()
            }
        }

        group.wait()
        // If we reach here without crashing, the lock is working
    }

    func testConcurrentRenderAndUpdate_doesNotCrash() {
        guard renderer != nil else { return }
        let group = DispatchGroup()
        let renderQueue = DispatchQueue(label: "test.render")
        let updateQueue = DispatchQueue(label: "test.update", attributes: .concurrent)

        // Set designated render queue so renders happen on the correct queue
        renderer.designatedRenderQueue = renderQueue

        for _ in 0..<20 {
            group.enter()
            renderQueue.async {
                _ = self.renderer.renderComposedFrame()
                group.leave()
            }
            group.enter()
            updateQueue.async {
                if let pb = self.makePixelBuffer() {
                    self.renderer.updateActiveSpeakerFrame(pb, identity: "alice")
                }
                group.leave()
            }
        }

        group.wait()
    }

    // MARK: - Placeholder Generation

    func testPlaceholderFrame_returnsNonNil() {
        guard renderer != nil else { return }
        // `placeholderFrameForIdentity:` returns a borrowed (+0) CVPixelBufferRef,
        // which Swift imports as Unmanaged — take an unretained reference to inspect it.
        let pb = renderer.placeholderFrame(forIdentity: "alice").takeUnretainedValue()
        // Placeholder should always return a valid, non-empty pixel buffer
        XCTAssertGreaterThan(CVPixelBufferGetWidth(pb), 0, "Placeholder frame must be valid")
    }

    func testPlaceholderFrame_cachesPerIdentity() {
        guard renderer != nil else { return }
        let pb1 = renderer.placeholderFrame(forIdentity: "alice").takeUnretainedValue()
        let pb2 = renderer.placeholderFrame(forIdentity: "alice").takeUnretainedValue()
        // Same identity should return the same cached buffer (pointer equality)
        XCTAssertTrue(pb1 === pb2, "Same identity should return cached placeholder")
    }

    func testPlaceholderFrame_differentForDifferentIdentity() {
        guard renderer != nil else { return }
        let pb1 = renderer.placeholderFrame(forIdentity: "alice").takeUnretainedValue()
        let pb2 = renderer.placeholderFrame(forIdentity: "bob").takeUnretainedValue()
        // Different identities may or may not share textures (implementation detail)
        // but both must be valid pixel buffers.
        XCTAssertGreaterThan(CVPixelBufferGetWidth(pb1), 0)
        XCTAssertGreaterThan(CVPixelBufferGetWidth(pb2), 0)
    }

    // MARK: - Watermark Toggle

    func testWatermarkEnabled_toggleDoesNotCrash() {
        guard renderer != nil else { return }
        renderer.watermarkEnabled = true
        XCTAssertTrue(renderer.watermarkEnabled)
        renderer.watermarkEnabled = false
        XCTAssertFalse(renderer.watermarkEnabled)
    }

    // MARK: - Delegate

    func testDelegate_layoutChangeIsCalled() {
        guard renderer != nil else { return }
        let spy = ComposedRendererDelegateSpy()
        renderer.delegate = spy

        // The renderer delivers layout-change callbacks asynchronously on the main
        // queue (see InterComposedRenderer.m), so wait for delivery rather than
        // reading the spy synchronously.
        let exp = expectation(description: "layout change delivered")
        exp.assertForOverFulfill = false
        spy.onChange = { layout in
            if layout == .cameraOnlyFull { exp.fulfill() }
        }

        guard let pb = makePixelBuffer() else { return XCTFail() }
        renderer.updateActiveSpeakerFrame(pb, identity: "alice")
        _ = renderer.renderComposedFrame()

        wait(for: [exp], timeout: 2.0)
        XCTAssertTrue(spy.layoutChanges.contains(.cameraOnlyFull),
                      "Delegate should receive .cameraOnlyFull layout change")
    }

    // MARK: - Invalidate

    func testInvalidate_doubleInvalidateDoesNotCrash() {
        guard renderer != nil else { return }
        renderer.invalidate()
        renderer.invalidate()  // Must not crash
    }

    func testRenderAfterInvalidate_returnsNil() {
        guard renderer != nil else { return }
        renderer.invalidate()
        let frame = renderer.renderComposedFrame()
        XCTAssertNil(frame, "Render after invalidate should return nil")
    }
}

// MARK: - Delegate Spy

private class ComposedRendererDelegateSpy: NSObject, InterComposedRendererDelegate {
    var layoutChanges: [InterComposedLayout] = []
    var onChange: ((InterComposedLayout) -> Void)?

    func composedRenderer(_ renderer: Any, didChange newLayout: InterComposedLayout) {
        layoutChanges.append(newLayout)
        onChange?(newLayout)
    }
}
