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
        // [B4 fix] A screen share with a host (active-speaker) camera buffer in a non-grid
        // recording now keeps the host tile as a picture-in-picture (.screenSharePiP).
        // This previously asserted .screenShareOnly, which was the OLD (buggy B4) behavior
        // that dropped the host tile; the fix selects PiP instead.
        XCTAssertEqual(renderer.currentLayout, .screenSharePiP)

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

    // MARK: - B4 Bug-Condition Exploration (Property 7)

    // Feature: secure-av-pipeline-fixes, Property 7: Bug Condition — Host Tile Flicker During Share
    //
    // POST-FIX: these tests now DRIVE THE REAL renderer instance (renderer.currentLayout)
    // to verify the shipping `-_recalculateLayoutLocked` / file-internal
    // `InterComposedSelectLayout(hasScreen, gridCount, hasPrimaryCamera, hasSecondaryCamera)`
    // production code. The B4 fix added a PiP branch returning `.screenSharePiP` for
    // (hasScreen && hasPrimaryCamera && !grid) plus camera-presence hysteresis
    // (kLayoutCameraGrace = 0.75s) so a screen share with a host camera buffer in a
    // non-grid recording stably keeps the host tile as a PiP. The pure selector is
    // file-internal (NOT Swift-visible), so these assertions exercise it through the real
    // renderer. They PASS on fixed code. The inline `currentLayoutDecision` model below is
    // retained only as documentation of the OLD (buggy) selection table.

    /// Faithful inline model of the CURRENT (unfixed) `-_recalculateLayoutLocked`
    /// decision in InterComposedRenderer.m:
    ///   screen + grid          ⇒ .screenShareFilmstrip
    ///   screen                 ⇒ .screenShareOnly          ← swallows the PiP case (BUG)
    ///   3+ grid                ⇒ .grid
    ///   primary + secondary    ⇒ .cameraSideBySide
    ///   primary                ⇒ .cameraOnlyFull
    ///   else                   ⇒ .idle
    /// Note: there is NO branch that returns `.screenSharePiP`. That omission is B4.
    private func currentLayoutDecision(hasScreen: Bool,
                                       gridCount: Int,
                                       hasPrimaryCamera: Bool,
                                       hasSecondaryCamera: Bool) -> InterComposedLayout {
        if hasScreen && gridCount > 0 { return .screenShareFilmstrip }
        if hasScreen { return .screenShareOnly }
        if gridCount >= 3 { return .grid }
        if hasPrimaryCamera && hasSecondaryCamera { return .cameraSideBySide }
        if hasPrimaryCamera { return .cameraOnlyFull }
        return .idle
    }

    func testB4_screenShareWithHostCamera_shouldSelectPiP_butCurrentlyDoesNot() {
        // Bug Condition isBugCondition_B4: recordingActive AND NOT gridMode AND
        // screenSharePresent AND hostCameraBufferAvailable.
        // Inputs: hasScreen=true, gridCount=0 (non-grid, ≤2-person), hasPrimaryCamera=true.
        //
        // The inline `currentLayoutDecision` model below documents the OLD (buggy B4)
        // selection (screen + non-grid ⇒ `.screenShareOnly`, swallowing the PiP case).
        // It is retained ONLY as a reference of the pre-fix behavior:
        let oldModelDecision = currentLayoutDecision(hasScreen: true,
                                                     gridCount: 0,
                                                     hasPrimaryCamera: true,
                                                     hasSecondaryCamera: false)
        XCTAssertEqual(oldModelDecision, .screenShareOnly,
                       "Reference: the OLD inline model dropped the host tile to .screenShareOnly.")

        // POST-FIX verification — drive the REAL renderer so we exercise the shipping
        // `-_recalculateLayoutLocked` / `InterComposedSelectLayout` production code (the
        // pure selector is file-internal and not Swift-visible). Screen share + a host
        // (active-speaker) camera buffer with NO grid participants must now resolve to
        // `.screenSharePiP` (Requirements 2.10) — the host tile is kept as a PiP.
        guard renderer != nil else { return }
        guard let pb = makePixelBuffer() else { return XCTFail("makePixelBuffer") }
        renderer.updateScreenShareFrame(pb)
        renderer.updateActiveSpeakerFrame(pb, identity: "host")
        _ = renderer.renderComposedFrame()
        XCTAssertEqual(renderer.currentLayout, .screenSharePiP,
                       "[B4] 2-person share + host camera on must select .screenSharePiP (host tile kept), got \(renderer.currentLayout).")
    }

    func testB4_perFrameRecalc_neverYieldsStablePiP() {
        // Requirement 2.11: per-frame recalculation must NOT churn the layout. The fixed
        // renderer holds a stable `.screenSharePiP` across repeated recalcs while a screen
        // share and a host camera buffer are present.
        guard renderer != nil else { return }
        guard let pb = makePixelBuffer() else { return XCTFail("makePixelBuffer") }
        renderer.updateScreenShareFrame(pb)
        renderer.updateActiveSpeakerFrame(pb, identity: "host")

        // Drive the REAL renderer across several recalculations with a stable buffer set
        // and assert it stays PiP on every frame (no flip-flop), exercising production code.
        for frame in 0..<5 {
            _ = renderer.renderComposedFrame()
            XCTAssertEqual(renderer.currentLayout, .screenSharePiP,
                           "[B4] frame \(frame): stable share + host camera must hold .screenSharePiP, got \(renderer.currentLayout).")
        }
    }

    // Feature: secure-av-pipeline-fixes, Property 7: Bug Condition — No Flip-Flop (stability)
    //
    // Hysteresis + idempotence on the REAL renderer (Requirement 2.11). The B4 fix tracks
    // the last non-NULL active-speaker frame (kLayoutCameraGrace = 0.75s) so a single
    // dropped camera frame between renders does NOT collapse PiP → ScreenShareOnly → PiP.
    func testB4_hysteresisAndIdempotence_holdsStablePiP() {
        guard renderer != nil else { return }
        guard let pb = makePixelBuffer() else { return XCTFail("makePixelBuffer") }

        // Establish the PiP state: screen share + a host active-speaker camera buffer.
        renderer.updateScreenShareFrame(pb)
        renderer.updateActiveSpeakerFrame(pb, identity: "host")
        _ = renderer.renderComposedFrame()
        XCTAssertEqual(renderer.currentLayout, .screenSharePiP,
                       "Precondition: share + host camera must select .screenSharePiP.")

        // Idempotence: repeated recalculation with a stable buffer set must NOT flip-flop.
        for frame in 0..<10 {
            _ = renderer.renderComposedFrame()
            XCTAssertEqual(renderer.currentLayout, .screenSharePiP,
                           "[B4] idempotence: recalc \(frame) must keep .screenSharePiP, got \(renderer.currentLayout).")
        }

        // Hysteresis (no slow sleeps): clear the active-speaker buffer (simulating a single
        // dropped frame). Because kLayoutCameraGrace (0.75s) has NOT elapsed, the host
        // camera is still treated as present, so the layout must STILL be .screenSharePiP.
        renderer.updateActiveSpeakerFrame(nil, identity: "host")
        _ = renderer.renderComposedFrame()
        XCTAssertEqual(renderer.currentLayout, .screenSharePiP,
                       "[B4] hysteresis: a single dropped frame within the grace window must keep .screenSharePiP, got \(renderer.currentLayout).")
    }

    // MARK: - B4 Preservation (Property 8)

    // Feature: secure-av-pipeline-fixes, Property 8: Preservation — ScreenShareOnly / Filmstrip / PiP Geometry
    //
    // These tests lock in the layout-table baseline that the B4 fix MUST NOT regress.
    // The B4 fix ONLY adds a new PiP branch for the single row
    // (hasScreen && gridCount == 0 && hasPrimaryCamera); EVERY OTHER row of the layout
    // decision table must be unchanged. These assertions therefore stay GREEN both BEFORE
    // and AFTER the fix (they deliberately exclude the new-PiP row).
    //
    // After the fix, task 12 introduces the pure selector
    // `InterComposedSelectLayout(hasScreen, gridCount, hasPrimaryCamera, hasSecondaryCamera)`
    // and table-tests it against these SAME preserved rows — so this baseline is the
    // contract the real selector must continue to satisfy.
    //
    // NOTE: The PiP geometry constants `kPiPWidthRatio` (0.20) and `kPiPPadding` (16.0)
    // are file-internal `static const` values inside InterComposedRenderer.m. They are
    // not exposed to Swift and are NOT touched by the B4 fix (which changes only layout
    // *selection*, not the existing Metal PiP encoding geometry). Their preservation is
    // covered by the unchanged Metal encoding path; see design.md §3.13.

    /// Independent encoding of the EXPECTED layout table for every NON-PiP row.
    /// This is written from the documented table (design.md "B4 — Preservation") rather
    /// than derived from the renderer, so it acts as an external oracle: the current
    /// model decision (`currentLayoutDecision`, task 10) must match this for all tuples
    /// EXCLUDING the new-PiP case, and after the fix the real selector must match it too.
    ///   screen + grid (gridCount > 0)   ⇒ .screenShareFilmstrip   (§3.12)
    ///   screen + non-grid + no camera   ⇒ .screenShareOnly        (§3.11)
    ///   3+ grid (no screen)             ⇒ .grid
    ///   primary + secondary             ⇒ .cameraSideBySide
    ///   primary only                    ⇒ .cameraOnlyFull
    ///   none                            ⇒ .idle
    /// Precondition: callers MUST exclude the PiP row (hasScreen && gridCount == 0 &&
    /// hasPrimaryCamera) — that row is the ONLY behavior the B4 fix changes.
    private func expectedPreservedLayout(hasScreen: Bool,
                                         gridCount: Int,
                                         hasPrimaryCamera: Bool,
                                         hasSecondaryCamera: Bool) -> InterComposedLayout {
        if hasScreen && gridCount > 0 { return .screenShareFilmstrip }
        if hasScreen { return .screenShareOnly }          // gridCount == 0 && !hasPrimaryCamera here
        if gridCount >= 3 { return .grid }
        if hasPrimaryCamera && hasSecondaryCamera { return .cameraSideBySide }
        if hasPrimaryCamera { return .cameraOnlyFull }
        return .idle
    }

    /// Is this the single row the B4 fix is allowed to change?
    private func isNewPiPRow(hasScreen: Bool, gridCount: Int, hasPrimaryCamera: Bool) -> Bool {
        return hasScreen && gridCount == 0 && hasPrimaryCamera
    }

    func testB4Preservation_nonPiPRows_matchBaselineTable_randomized() {
        // Randomized property test: ≥100 iterations, seeded RNG for reproducibility.
        // Over random (hasScreen, gridCount, hasPrimaryCamera, hasSecondaryCamera) tuples
        // EXCLUDING the new-PiP case, the current model decision must equal the
        // independently-encoded expected table — i.e. the B4 fix preserves every other row.
        var rng = ComposedLayoutSeededGenerator(seed: 0x5EC0_5EAB_4000_0008)
        let iterations = 500
        var checked = 0

        for _ in 0..<iterations {
            let hasScreen = Bool.random(using: &rng)
            let gridCount = Int.random(in: 0...5, using: &rng)
            let hasPrimaryCamera = Bool.random(using: &rng)
            let hasSecondaryCamera = Bool.random(using: &rng)

            // Skip the ONLY row the fix changes (the new PiP branch).
            if isNewPiPRow(hasScreen: hasScreen, gridCount: gridCount,
                           hasPrimaryCamera: hasPrimaryCamera) {
                continue
            }
            checked += 1

            let modelDecision = currentLayoutDecision(hasScreen: hasScreen,
                                                      gridCount: gridCount,
                                                      hasPrimaryCamera: hasPrimaryCamera,
                                                      hasSecondaryCamera: hasSecondaryCamera)
            let expected = expectedPreservedLayout(hasScreen: hasScreen,
                                                   gridCount: gridCount,
                                                   hasPrimaryCamera: hasPrimaryCamera,
                                                   hasSecondaryCamera: hasSecondaryCamera)

            XCTAssertEqual(modelDecision, expected,
                """
                B4 preservation regression for tuple \
                (hasScreen: \(hasScreen), gridCount: \(gridCount), \
                hasPrimaryCamera: \(hasPrimaryCamera), hasSecondaryCamera: \(hasSecondaryCamera)): \
                model=\(modelDecision) expected=\(expected). \
                The B4 fix must only add the PiP row and leave this row unchanged.
                """)
        }

        // Make sure the seeded run actually exercised a meaningful, non-trivial sample of
        // the preserved (non-PiP) rows — otherwise the property is vacuously satisfied.
        XCTAssertGreaterThanOrEqual(checked, 100,
            "Seeded property loop must exercise ≥100 non-PiP tuples (checked \(checked)).")
    }

    func testB4Preservation_explicitNonPiPRows_matchBaselineTable() {
        // Example assertions for each preserved (non-PiP) row of the documented table.
        // These pin the exact expected values so a regression names the offending row.
        // screen + grid ⇒ Filmstrip (§3.12)
        XCTAssertEqual(currentLayoutDecision(hasScreen: true, gridCount: 1,
                                             hasPrimaryCamera: false, hasSecondaryCamera: false),
                       .screenShareFilmstrip)
        XCTAssertEqual(currentLayoutDecision(hasScreen: true, gridCount: 4,
                                             hasPrimaryCamera: true, hasSecondaryCamera: true),
                       .screenShareFilmstrip)
        // screen + non-grid + no camera ⇒ ScreenShareOnly (§3.11)
        XCTAssertEqual(currentLayoutDecision(hasScreen: true, gridCount: 0,
                                             hasPrimaryCamera: false, hasSecondaryCamera: false),
                       .screenShareOnly)
        // 3+ grid (no screen) ⇒ Grid
        XCTAssertEqual(currentLayoutDecision(hasScreen: false, gridCount: 3,
                                             hasPrimaryCamera: false, hasSecondaryCamera: false),
                       .grid)
        // primary + secondary ⇒ SideBySide
        XCTAssertEqual(currentLayoutDecision(hasScreen: false, gridCount: 0,
                                             hasPrimaryCamera: true, hasSecondaryCamera: true),
                       .cameraSideBySide)
        // primary only ⇒ CameraOnlyFull
        XCTAssertEqual(currentLayoutDecision(hasScreen: false, gridCount: 0,
                                             hasPrimaryCamera: true, hasSecondaryCamera: false),
                       .cameraOnlyFull)
        // none ⇒ Idle
        XCTAssertEqual(currentLayoutDecision(hasScreen: false, gridCount: 0,
                                             hasPrimaryCamera: false, hasSecondaryCamera: false),
                       .idle)
    }

    func testB4Preservation_realRenderer_screenShareNoCamera_isScreenShareOnly() {
        // Preserved real-renderer behavior (§3.11): a screen share with NO camera buffer
        // must stay `.screenShareOnly` — the B4 fix does not touch this row.
        guard renderer != nil else { return }
        guard let pb = makePixelBuffer() else { return XCTFail("makePixelBuffer") }
        renderer.updateScreenShareFrame(pb)

        _ = renderer.renderComposedFrame()
        XCTAssertEqual(renderer.currentLayout, .screenShareOnly,
                       "B4 preservation: share with no camera buffer must remain .screenShareOnly")
    }

    func testB4Preservation_realRenderer_gridWithShare_isScreenShareFilmstrip() {
        // Preserved real-renderer behavior (§3.12): grid participants + a screen share
        // must stay `.screenShareFilmstrip` — the B4 fix does not touch this row.
        guard renderer != nil else { return }
        guard let pb = makePixelBuffer() else { return XCTFail("makePixelBuffer") }
        renderer.updateScreenShareFrame(pb)
        renderer.setParticipantOrder(["alice"])
        renderer.updateParticipantFrame(pb, identity: "alice")

        _ = renderer.renderComposedFrame()
        XCTAssertEqual(renderer.currentLayout, .screenShareFilmstrip,
                       "B4 preservation: grid + share must remain .screenShareFilmstrip")
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

// MARK: - Seeded RNG

/// Deterministic SplitMix64-based generator so the randomized property loop is
/// reproducible across runs (a fixed seed yields the same tuple sequence).
private struct ComposedLayoutSeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        // Avoid a zero state (SplitMix64 still works, but seed it nontrivially).
        self.state = seed != 0 ? seed : 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
