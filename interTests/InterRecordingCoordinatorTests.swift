// ============================================================================
// InterRecordingCoordinatorTests.swift
// interTests
//
// Phase 10D.7 — Comprehensive tests for edge cases, disk space monitor,
// orphaned file cleanup, room disconnect auto-stop, and state transitions.
// ============================================================================

import XCTest
@testable import inter

final class InterRecordingCoordinatorTests: XCTestCase {

    // -----------------------------------------------------------------------
    // MARK: - State Machine Tests
    // -----------------------------------------------------------------------

    func testInitialStateIsIdle() {
        let coordinator = InterRecordingCoordinator()
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testCannotPauseWhenIdle() {
        let coordinator = InterRecordingCoordinator()
        XCTAssertFalse(coordinator.canPause)
    }

    func testCannotResumeWhenIdle() {
        let coordinator = InterRecordingCoordinator()
        XCTAssertFalse(coordinator.canResume)
    }

    func testCannotStopWhenIdle() {
        let coordinator = InterRecordingCoordinator()
        XCTAssertFalse(coordinator.canStop)
    }

    func testIsLocalRecordingActiveWhenIdle() {
        let coordinator = InterRecordingCoordinator()
        XCTAssertFalse(coordinator.isLocalRecordingActive)
    }

    // -----------------------------------------------------------------------
    // MARK: - Disk Space Helper Tests
    // -----------------------------------------------------------------------

    func testAvailableDiskSpaceReturnsNonZero() {
        let space = InterRecordingCoordinator.availableDiskSpaceBytes()
        XCTAssertGreaterThan(space, 0, "Available disk space should be > 0 on a running system")
    }

    func testAvailableDiskSpaceIsReasonable() throws {
        // Skip on CI environments where disk space may be intentionally constrained.
        // Detected via common CI environment variables (GitHub Actions, Xcode Cloud, Jenkins, etc.).
        let env = ProcessInfo.processInfo.environment
        let isCI = env["CI"] != nil
            || env["GITHUB_ACTIONS"] != nil
            || env["XCODE_CLOUD"] != nil
            || env["JENKINS_URL"] != nil
            || env["TF_BUILD"] != nil   // Azure Pipelines
        try XCTSkipIf(isCI, "Skipping disk-space threshold check in CI — environment may have limited free space")

        // Should be at least 100 MB on any dev machine (sanity check)
        let space = InterRecordingCoordinator.availableDiskSpaceBytes()
        let oneHundredMB: UInt64 = 100_000_000
        XCTAssertGreaterThan(space, oneHundredMB,
                             "Expected > 100 MB free, got \(space / 1_000_000) MB")
    }

    // -----------------------------------------------------------------------
    // MARK: - Orphaned File Cleanup Tests
    // -----------------------------------------------------------------------

    func testCleanOrphanedRecordingFilesRemovesTmpFiles() {
        let fm = FileManager.default
        let documentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let recordingsDir = documentsURL.appendingPathComponent("Inter Recordings", isDirectory: true)
        try? fm.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        // Create a fake .tmp file
        let tmpFile = recordingsDir.appendingPathComponent("orphaned_session.tmp")
        fm.createFile(atPath: tmpFile.path, contents: Data("test".utf8))
        XCTAssertTrue(fm.fileExists(atPath: tmpFile.path), "Temp file should exist before cleanup")

        // Run cleanup
        InterRecordingCoordinator.cleanOrphanedRecordingFiles()

        // Verify .tmp file was removed
        XCTAssertFalse(fm.fileExists(atPath: tmpFile.path), "Orphaned .tmp file should be removed")
    }

    func testCleanOrphanedRecordingFilesRemovesCorruptMp4() {
        let fm = FileManager.default
        let documentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let recordingsDir = documentsURL.appendingPathComponent("Inter Recordings", isDirectory: true)
        try? fm.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        // Create a very small .mp4 file (< 1 KB) simulating a corrupt/incomplete recording
        let corruptFile = recordingsDir.appendingPathComponent("Inter Recording Corrupt.mp4")
        let tinyData = Data(repeating: 0, count: 100) // 100 bytes, well under 1 KB
        fm.createFile(atPath: corruptFile.path, contents: tinyData)
        XCTAssertTrue(fm.fileExists(atPath: corruptFile.path), "Corrupt file should exist before cleanup")

        // Run cleanup
        InterRecordingCoordinator.cleanOrphanedRecordingFiles()

        // Verify corrupt .mp4 was removed
        XCTAssertFalse(fm.fileExists(atPath: corruptFile.path), "Corrupt .mp4 (< 1 KB) should be removed")
    }

    func testCleanOrphanedRecordingFilesPreservesValidMp4() {
        let fm = FileManager.default
        let documentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let recordingsDir = documentsURL.appendingPathComponent("Inter Recordings", isDirectory: true)
        try? fm.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        // Create a valid-sized .mp4 file (> 1 KB)
        let validFile = recordingsDir.appendingPathComponent("Inter Recording Valid.mp4")
        let validData = Data(repeating: 0xFF, count: 2048) // 2 KB
        fm.createFile(atPath: validFile.path, contents: validData)
        XCTAssertTrue(fm.fileExists(atPath: validFile.path), "Valid file should exist before cleanup")

        // Run cleanup
        InterRecordingCoordinator.cleanOrphanedRecordingFiles()

        // Verify valid .mp4 was NOT removed
        XCTAssertTrue(fm.fileExists(atPath: validFile.path), "Valid .mp4 (> 1 KB) should be preserved")

        // Cleanup test artifact
        try? fm.removeItem(at: validFile)
    }

    func testCleanOrphanedRecordingFilesHandlesMissingDirectory() {
        // This should not crash even if the recordings directory doesn't exist
        let fm = FileManager.default
        let documentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let recordingsDir = documentsURL.appendingPathComponent("Inter Recordings", isDirectory: true)

        // Temporarily rename if it exists
        let backupDir = documentsURL.appendingPathComponent("Inter Recordings Backup", isDirectory: true)
        let existed = fm.fileExists(atPath: recordingsDir.path)
        if existed {
            try? fm.moveItem(at: recordingsDir, to: backupDir)
        }

        // Should not crash
        InterRecordingCoordinator.cleanOrphanedRecordingFiles()

        // Restore if we moved it
        if existed {
            try? fm.moveItem(at: backupDir, to: recordingsDir)
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - Room Disconnect Tests
    // -----------------------------------------------------------------------

    func testHandleRoomDisconnectWhenIdleIsNoOp() {
        let coordinator = InterRecordingCoordinator()
        let expectation = XCTestExpectation(description: "handleRoomDisconnect completes")

        // This should not crash or change state
        coordinator.handleRoomDisconnect(serverURL: nil, roomCode: nil, callerIdentity: nil)

        // Give the coordinatorQueue time to process
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(coordinator.state, .idle)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    // -----------------------------------------------------------------------
    // MARK: - Concurrency / Thread Safety Tests
    // -----------------------------------------------------------------------

    func testConcurrentStateReads() {
        let coordinator = InterRecordingCoordinator()

        // Reading state from multiple threads concurrently should not crash
        // (protected by os_unfair_lock).
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in
            let _ = coordinator.state
            let _ = coordinator.canPause
            let _ = coordinator.canResume
            let _ = coordinator.canStop
            let _ = coordinator.isLocalRecordingActive
        }
    }

    func testConcurrentCloudEgressIdReads() {
        let coordinator = InterRecordingCoordinator()

        // Reading cloudEgressId from multiple threads should not crash
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in
            let _ = coordinator.cloudEgressId
            let _ = coordinator.cloudRecordingSessionId
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - Double-Start Prevention
    // -----------------------------------------------------------------------

    func testDoubleStopWhenIdleIsNoOp() {
        let coordinator = InterRecordingCoordinator()
        let expectation = XCTestExpectation(description: "stopRecording completes")

        coordinator.stopRecording()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(coordinator.state, .idle, "State should remain idle after stopRecording on idle coordinator")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testPauseWhenIdleIsNoOp() {
        let coordinator = InterRecordingCoordinator()
        let expectation = XCTestExpectation(description: "pauseRecording completes")

        coordinator.pauseRecording()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(coordinator.state, .idle, "State should remain idle after pause on idle coordinator")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testResumeWhenIdleIsNoOp() {
        let coordinator = InterRecordingCoordinator()
        let expectation = XCTestExpectation(description: "resumeRecording completes")

        coordinator.resumeRecording()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(coordinator.state, .idle, "State should remain idle after resume on idle coordinator")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }
}
