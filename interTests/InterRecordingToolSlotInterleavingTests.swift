//
//  InterRecordingToolSlotInterleavingTests.swift
//  interTests
//
//  Screen-share slot ownership in `InterRecordingCoordinator`.
//
//  REDUCED for the candidate-tool-share-tile architecture pivot (Phase 2,
//  task 5.1). The interviewer-local `.tool` slot occupant no longer exists in
//  the one-way model: the candidate shares the tool as a genuine screen-share
//  track, so the ONLY occupant of the single screen-share slot is a real remote
//  screen share. The former `.tool` slot-interleaving assertions (Speaker tool
//  routing, the `"__tool__"` tile, and the Speaker→Grid flip re-route) have been
//  removed; what remains pins the surviving contract:
//
//    • a genuine remote screen share single-sources the slot
//      (`screenShareDidChange(true, realId)` → `screenShare(realId)` occupant),
//    • genuine frames write the slot (`updateScreenShareFrame:` non-nil),
//    • on track-end the slot is vacated and CLEARED (`updateScreenShareFrame:`
//      with nil), leaving no stale frame.
//
//  Test seam (documented):
//  Routing only runs while `.recording` / `.paused`, against a concrete
//  Metal-backed `InterComposedRenderer`, with slot ownership mutated only on the
//  serial `coordinatorQueue`. To assert the screen-share entry points
//  deterministically WITHOUT the GPU pipeline, this test injects a
//  `SlotShareMockRenderer` (records the renderer entry points instead of
//  rendering) via the `test_*` seam and drives the genuine remote screen share
//  through the PRODUCTION `screenShareDidChange(isActive:participantId:)` and
//  `didReceiveRemoteScreenShareFrame(_:fromParticipant:)` entry points. The mock
//  is built with a real Metal device (mirroring `InterComposedRendererTests`);
//  the test is skipped when Metal is unavailable.
//

import XCTest
import CoreVideo
import Metal
@testable import inter

// MARK: - Recording mock renderer (uniquely named for this file)

/// `InterComposedRenderer` subclass that overrides the screen-share routing
/// entry point to RECORD calls (instead of rendering). The overridden method
/// never calls `super`, so the Metal pipeline is never exercised for it — but
/// `super.init` still requires a real device, exactly as
/// `InterComposedRendererTests`.
private final class SlotShareMockRenderer: InterComposedRenderer {

    private let lock = NSLock()
    private var _screenShareFrames: [CVPixelBuffer?] = []

    init(device: MTLDevice, commandQueue: MTLCommandQueue) {
        super.init(device: device,
                   commandQueue: commandQueue,
                   outputSize: CGSize(width: 1920, height: 1080))
    }

    override func updateScreenShareFrame(_ pixelBuffer: CVPixelBuffer?) {
        lock.lock(); _screenShareFrames.append(pixelBuffer); lock.unlock()
    }

    /// Number of NON-nil writes to the single screen-share slot.
    func screenShareNonNilCount() -> Int {
        lock.lock(); defer { lock.unlock() }; return _screenShareFrames.filter { $0 != nil }.count
    }
    /// Whether the most-recent screen-share write was a CLEAR (nil), i.e. the
    /// slot was last vacated and holds no stale frame.
    func lastWriteWasClear() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let last = _screenShareFrames.last else { return false }
        return last == nil
    }
}

// MARK: - Tests

final class InterRecordingToolSlotInterleavingTests: XCTestCase {

    // MARK: Helpers

    /// Build a `SlotShareMockRenderer` over the system Metal device, or skip when
    /// Metal is unavailable (mirrors `InterComposedRendererTests`).
    private func makeMockRenderer() throws -> SlotShareMockRenderer {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable on this host")
        }
        return SlotShareMockRenderer(device: device, commandQueue: queue)
    }

    /// Minimal BGRA `CVPixelBuffer` standing in for a genuine screen-share frame.
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

    /// A coordinator wired with the mock renderer and forced into `.recording`.
    private func makeWiredCoordinator(renderer: SlotShareMockRenderer) -> InterRecordingCoordinator {
        let coordinator = InterRecordingCoordinator()
        coordinator.test_injectRenderer(renderer)
        coordinator.test_setRecordingState(.recording)
        return coordinator
    }

    /// Flush the coordinator's serial queue: `test_slotOccupant()` runs
    /// `coordinatorQueue.sync`, which (FIFO on a serial queue) guarantees all
    /// previously-enqueued async work has completed before the mock snapshots are
    /// read on the test thread.
    @discardableResult
    private func flush(_ coordinator: InterRecordingCoordinator) -> String {
        coordinator.test_slotOccupant()
    }

    // -----------------------------------------------------------------------
    // MARK: - Genuine remote screen share owns / clears the single slot
    // -----------------------------------------------------------------------

    /// A genuine remote screen share single-sources the slot and its frames write
    /// the screen-share slot (non-nil). Repeat frames keep the same occupant and
    /// keep writing — no spurious clear mid-stream.
    func testGenuineRemoteShareOwnsSlotAndWritesFrames() throws {
        let mock = try makeMockRenderer()
        let realId = "remote-sharer-UUID-A"
        let coordinator = makeWiredCoordinator(renderer: mock)

        coordinator.screenShareDidChange(isActive: true, participantId: realId)
        XCTAssertEqual(flush(coordinator), "screenShare:\(realId)",
                       "A genuine remote share must own the single screen-share slot")

        let frame1 = try XCTUnwrap(makePixelBuffer())
        coordinator.didReceiveRemoteScreenShareFrame(frame1, fromParticipant: realId)
        XCTAssertEqual(flush(coordinator), "screenShare:\(realId)",
                       "Delivering a genuine frame keeps the share as the slot occupant")
        XCTAssertEqual(mock.screenShareNonNilCount(), 1,
                       "The genuine frame must write the screen-share slot exactly once")

        let frame2 = try XCTUnwrap(makePixelBuffer(width: 640, height: 360))
        coordinator.didReceiveRemoteScreenShareFrame(frame2, fromParticipant: realId)
        XCTAssertEqual(flush(coordinator), "screenShare:\(realId)",
                       "A repeat frame from the same sharer keeps the same occupant (no churn)")
        XCTAssertEqual(mock.screenShareNonNilCount(), 2,
                       "Each genuine frame writes the slot; the occupant never spuriously clears")
    }

    /// When the genuine remote screen-share track ends, the slot is vacated and
    /// CLEARED (`updateScreenShareFrame(nil)`) so no stale frame remains, and the
    /// occupant returns to `none`.
    func testGenuineRemoteShareEndClearsSlot() throws {
        let mock = try makeMockRenderer()
        let realId = "remote-sharer-UUID-B"
        let coordinator = makeWiredCoordinator(renderer: mock)

        coordinator.screenShareDidChange(isActive: true, participantId: realId)
        let frame = try XCTUnwrap(makePixelBuffer())
        coordinator.didReceiveRemoteScreenShareFrame(frame, fromParticipant: realId)
        XCTAssertEqual(flush(coordinator), "screenShare:\(realId)",
                       "precondition: the genuine share owns the slot and a frame was written")
        XCTAssertEqual(mock.screenShareNonNilCount(), 1)

        coordinator.screenShareDidChange(isActive: false, participantId: realId)
        XCTAssertEqual(flush(coordinator), "none",
                       "Ending the genuine share must vacate the screen-share slot")
        XCTAssertTrue(mock.lastWriteWasClear(),
                      "The vacated slot must be CLEARED (updateScreenShareFrame(nil)) — no stale frame")
    }
}
