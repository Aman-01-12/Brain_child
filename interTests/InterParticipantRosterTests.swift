// interTests/InterParticipantRosterTests.swift
// Unit tests for InterParticipantRoster snapshot computation.

import XCTest
@testable import inter

final class InterParticipantRosterTests: XCTestCase {

    private func makeRoster() -> (InterParticipantRoster, SnapshotSink) {
        let sink = SnapshotSink()
        let roster = InterParticipantRoster()
        roster.onSnapshot = { sink.last = $0 }
        return (roster, sink)
    }

    final class SnapshotSink {
        var last: [InterParticipantSnapshotEntry] = []
    }

    func test_localOnly_emitsSingleLocalEntry() {
        let (roster, sink) = makeRoster()
        roster.setLocal(identity: "me", displayName: "Me", cameraOn: false, micMuted: false)
        XCTAssertEqual(sink.last.count, 1)
        XCTAssertTrue(sink.last[0].isLocal)
        XCTAssertEqual(sink.last[0].identity, "me")
        XCTAssertFalse(sink.last[0].cameraOn)
    }

    func test_localFirstThenRemoteJoinOrder() {
        let (roster, sink) = makeRoster()
        roster.setLocal(identity: "me", displayName: "Me", cameraOn: true, micMuted: false)
        roster.participantJoined("a", displayName: "Alice")
        roster.participantJoined("b", displayName: "Bob")
        XCTAssertEqual(sink.last.map { $0.identity }, ["me", "a", "b"])
        XCTAssertTrue(sink.last[0].isLocal)
        XCTAssertFalse(sink.last[1].isLocal)
    }

    func test_remoteCameraOn_requiresUnmuteAndFirstFrame() {
        let (roster, sink) = makeRoster()
        roster.participantJoined("a", displayName: "Alice")
        // joined but no track/frame yet → camera off (avatar)
        XCTAssertFalse(sink.last.first { $0.identity == "a" }!.cameraOn)
        // subscribed + unmuted but still no frame → still off (avoid black feed)
        roster.cameraSubscribed("a")
        roster.cameraMuted("a", muted: false)
        XCTAssertFalse(sink.last.first { $0.identity == "a" }!.cameraOn)
        // first frame arrives → camera on
        roster.cameraFirstFrame("a")
        XCTAssertTrue(sink.last.first { $0.identity == "a" }!.cameraOn)
    }

    func test_remoteCameraMute_turnsOffEvenAfterFrame() {
        let (roster, sink) = makeRoster()
        roster.participantJoined("a", displayName: "Alice")
        roster.cameraSubscribed("a")
        roster.cameraMuted("a", muted: false)
        roster.cameraFirstFrame("a")
        XCTAssertTrue(sink.last.first { $0.identity == "a" }!.cameraOn)
        roster.cameraMuted("a", muted: true)
        XCTAssertFalse(sink.last.first { $0.identity == "a" }!.cameraOn)
    }

    func test_participantLeft_removesEntry() {
        let (roster, sink) = makeRoster()
        roster.participantJoined("a", displayName: "Alice")
        roster.participantJoined("b", displayName: "Bob")
        roster.participantLeft("a")
        XCTAssertEqual(sink.last.map { $0.identity }, ["b"])
    }

    func test_resync_reemitsCurrentSnapshot() {
        let (roster, sink) = makeRoster()
        roster.participantJoined("a", displayName: "Alice")
        sink.last = []
        roster.resync()
        XCTAssertEqual(sink.last.map { $0.identity }, ["a"])
    }

    func test_activeSpeaker_setsIsSpeakingOnMatchingEntry() {
        let (roster, sink) = makeRoster()
        roster.participantJoined("a", displayName: "Alice")
        roster.participantJoined("b", displayName: "Bob")
        roster.setActiveSpeaker("b")
        XCTAssertFalse(sink.last.first { $0.identity == "a" }!.isSpeaking)
        XCTAssertTrue(sink.last.first { $0.identity == "b" }!.isSpeaking)
        roster.setActiveSpeaker("")   // none
        XCTAssertFalse(sink.last.first { $0.identity == "b" }!.isSpeaking)
    }

    func test_displayNameUpdate_reflectedInSnapshot() {
        let (roster, sink) = makeRoster()
        roster.participantJoined("a", displayName: "a")
        roster.updateDisplayName("Alice", for: "a")
        XCTAssertEqual(sink.last.first { $0.identity == "a" }!.displayName, "Alice")
    }

    func test_micMuteAndHandRaise_reflectedInSnapshot() {
        let (roster, sink) = makeRoster()
        roster.participantJoined("a", displayName: "Alice")
        roster.micMuted("a", muted: true)
        roster.handRaised("a", raised: true)
        let e = sink.last.first { $0.identity == "a" }!
        XCTAssertTrue(e.micMuted)
        XCTAssertTrue(e.handRaised)
    }
}
