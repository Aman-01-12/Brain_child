// interTests/InterCameraWiringTests.swift
// Unit tests for Camera Mute feature (Camera Mute T10)
//
// Validates:
//   - Signal types 36-39 are defined with correct raw values
//   - InterScreenShareQueue does not conflict (distinct class)
//   - ModerationController exposes host camera mute/lift methods

import XCTest
@testable import inter

final class InterCameraWiringTests: XCTestCase {

    // MARK: - Signal Types

    func testSignalTypes_cameraRawValues() {
        XCTAssertEqual(InterControlSignalType.requestMuteCameraOne.rawValue, 36)
        XCTAssertEqual(InterControlSignalType.requestMuteCameraAll.rawValue, 37)
        XCTAssertEqual(InterControlSignalType.liftCameraLockOne.rawValue, 38)
        XCTAssertEqual(InterControlSignalType.liftCameraLockAll.rawValue, 39)
    }

    func testSignalTypes_cameraDistinctFromExistingTypes() {
        let cameraTypes: [InterControlSignalType] = [
            .requestMuteCameraOne, .requestMuteCameraAll,
            .liftCameraLockOne, .liftCameraLockAll
        ]
        let allRaw = cameraTypes.map { $0.rawValue }
        // All unique
        XCTAssertEqual(Set(allRaw).count, 4)
        // No collision with existing types (0–35)
        for raw in allRaw {
            XCTAssertGreaterThan(raw, 35, "Camera signal type \(raw) collides with existing type")
        }
    }

    // MARK: - InterScreenShareQueue

    func testScreenShareQueue_addAndRemove() {
        let queue = InterScreenShareQueue()
        XCTAssertEqual(queue.entries.count, 0)

        queue.addRequest(identity: "alice", displayName: "Alice")
        XCTAssertEqual(queue.entries.count, 1)
        XCTAssertEqual(queue.entries.first?.participantIdentity, "alice")
        XCTAssertEqual(queue.entries.first?.displayName, "Alice")

        queue.removeRequest(identity: "alice")
        XCTAssertEqual(queue.entries.count, 0)
    }

    func testScreenShareQueue_noDuplicates() {
        let queue = InterScreenShareQueue()
        queue.addRequest(identity: "bob", displayName: "Bob")
        queue.addRequest(identity: "bob", displayName: "Bob Again")
        // Should deduplicate
        XCTAssertEqual(queue.entries.count, 1)
    }

    func testScreenShareQueue_hasPendingRequest() {
        let queue = InterScreenShareQueue()
        XCTAssertFalse(queue.hasPendingRequest(for: "carol"))
        queue.addRequest(identity: "carol", displayName: "Carol")
        XCTAssertTrue(queue.hasPendingRequest(for: "carol"))
    }

    func testScreenShareQueue_reset() {
        let queue = InterScreenShareQueue()
        queue.addRequest(identity: "dave", displayName: "Dave")
        queue.addRequest(identity: "eve", displayName: "Eve")
        XCTAssertEqual(queue.entries.count, 2)
        queue.reset()
        XCTAssertEqual(queue.entries.count, 0)
    }

    // MARK: - ModerationController camera mute methods

    func testModerationController_cameraMuteMethodsExist() {
        let controller = InterModerationController()
        // These should not crash when called on an unattached controller.
        // (Guards inside prevent signal sending when no room is attached.)
        controller.muteCameraOne(identity: "frank")
        controller.muteCameraAll()
        controller.liftCameraLockOne(identity: "frank")
        controller.liftCameraLockAll()
    }

    // MARK: - InterMicUnlockQueue

    func testMicUnlockQueue_addDeduplicates() {
        let queue = InterMicUnlockQueue()
        queue.addRequest(identity: "alice", displayName: "Alice")
        queue.addRequest(identity: "alice", displayName: "Alice")
        XCTAssertEqual(queue.count, 1, "Duplicate identity must not create two entries (F10 mitigation)")
    }

    func testMicUnlockQueue_addDoesNotRefreshOnDuplicate() {
        let queue = InterMicUnlockQueue()
        queue.addRequest(identity: "alice", displayName: "Alice")
        let first = queue.entries[0].timestamp
        Thread.sleep(forTimeInterval: 0.01)
        queue.addRequest(identity: "alice", displayName: "Alice")
        XCTAssertEqual(queue.entries[0].timestamp, first, "Duplicate must not refresh timestamp")
    }

    func testMicUnlockQueue_remove() {
        let queue = InterMicUnlockQueue()
        queue.addRequest(identity: "alice", displayName: "Alice")
        queue.removeRequest(identity: "alice")
        XCTAssertEqual(queue.count, 0)
    }

    func testMicUnlockQueue_reset() {
        let queue = InterMicUnlockQueue()
        queue.addRequest(identity: "alice", displayName: "Alice")
        queue.addRequest(identity: "bob",   displayName: "Bob")
        queue.reset()
        XCTAssertEqual(queue.count, 0)
        XCTAssertTrue(queue.entries.isEmpty)
    }

    func testMicUnlockQueue_hasPendingRequest() {
        let queue = InterMicUnlockQueue()
        queue.addRequest(identity: "alice", displayName: "Alice")
        XCTAssertTrue(queue.hasPendingRequest(for: "alice"))
        XCTAssertFalse(queue.hasPendingRequest(for: "bob"))
    }
}
