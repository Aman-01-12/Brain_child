//
//  InterAudioInputMatcherTests.swift
//  interTests
//
//  Locks the in-call mic-switch matching logic: deviceId match wins, then name,
//  else nil (caller must no-op — never force an invalid device). Fails if the
//  precedence or the safe no-op is reverted (paranoid finding #1).
//

import XCTest
@testable import inter

final class InterAudioInputMatcherTests: XCTestCase {

    private let devices = [
        (id: "builtin-uid", name: "MacBook Pro Microphone"),
        (id: "usb-uid",     name: "AirPods Pro"),
    ]

    func testDeviceIdMatchWins() {
        // deviceId takes precedence even when the name points elsewhere.
        XCTAssertEqual(InterAudioInputMatcher.matchIndex(devices: devices,
                                                         wantID: "usb-uid",
                                                         wantName: "MacBook Pro Microphone"), 1)
    }

    func testFallsBackToNameWhenIdMisses() {
        XCTAssertEqual(InterAudioInputMatcher.matchIndex(devices: devices,
                                                         wantID: "no-such-id",
                                                         wantName: "AirPods Pro"), 1)
    }

    func testNameOnly() {
        XCTAssertEqual(InterAudioInputMatcher.matchIndex(devices: devices,
                                                         wantID: nil,
                                                         wantName: "MacBook Pro Microphone"), 0)
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(InterAudioInputMatcher.matchIndex(devices: devices,
                                                       wantID: "x", wantName: "y"))
        XCTAssertNil(InterAudioInputMatcher.matchIndex(devices: [],
                                                       wantID: "x", wantName: "y"))
        XCTAssertNil(InterAudioInputMatcher.matchIndex(devices: devices,
                                                       wantID: "", wantName: ""))
        XCTAssertNil(InterAudioInputMatcher.matchIndex(devices: devices,
                                                       wantID: nil, wantName: nil))
    }
}
