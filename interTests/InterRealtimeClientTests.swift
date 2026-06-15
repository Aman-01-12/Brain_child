//
//  InterRealtimeClientTests.swift
//  interTests
//
//  Unit tests for the InterRealtimeClient façade's pure core (the event router).
//  No transport/network — validates fan-out dispatch, isolation, the teardown
//  leak-guard (paranoid 2C), and thread-safety.
//

import XCTest
@testable import inter

final class InterRealtimeClientTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testDispatchInvokesRegisteredHandler() {
        let router = InterRealtimeEventRouter()
        var received: String?
        router.on("team:message") { received = String(data: $0, encoding: .utf8) }

        let count = router.dispatch("team:message", data("hello"))

        XCTAssertEqual(count, 1)
        XCTAssertEqual(received, "hello")
    }

    func testMultipleHandlersForSameEventAllFireInOrder() {
        let router = InterRealtimeEventRouter()
        var order: [Int] = []
        router.on("e") { _ in order.append(1) }
        router.on("e") { _ in order.append(2) }

        let count = router.dispatch("e", Data())

        XCTAssertEqual(count, 2)
        XCTAssertEqual(order, [1, 2], "handlers must fire in registration order")
    }

    func testDispatchUnknownEventInvokesNothing() {
        let router = InterRealtimeEventRouter()
        router.on("known") { _ in XCTFail("must not fire for a different event") }

        let count = router.dispatch("unknown", Data())

        XCTAssertEqual(count, 0)
    }

    func testHandlersAreScopedToTheirEvent() {
        let router = InterRealtimeEventRouter()
        var aFired = false
        var bFired = false
        router.on("a") { _ in aFired = true }
        router.on("b") { _ in bFired = true }

        router.dispatch("a", Data())

        XCTAssertTrue(aFired)
        XCTAssertFalse(bFired)
    }

    /// Paranoid 2C: disconnect()/teardown must release every handler so no closure
    /// (and whatever it captures) leaks past the client's lifecycle.
    func testRemoveAllClearsHandlers() {
        let router = InterRealtimeEventRouter()
        router.on("team:message") { _ in XCTFail("handler must not fire after removeAll") }
        router.on("team:member-added") { _ in XCTFail("handler must not fire after removeAll") }
        XCTAssertEqual(router.registeredEventCount, 2)

        router.removeAll()

        XCTAssertEqual(router.registeredEventCount, 0)
        XCTAssertEqual(router.dispatch("team:message", Data()), 0)
        XCTAssertEqual(router.dispatch("team:member-added", Data()), 0)
    }

    /// The router is touched from background socket callbacks; concurrent
    /// registration + dispatch must not crash or corrupt state.
    func testConcurrentRegisterAndDispatchIsSafe() {
        let router = InterRealtimeEventRouter()
        let iterations = 500
        let group = DispatchGroup()
        let q = DispatchQueue(label: "test.concurrent", attributes: .concurrent)

        for i in 0..<iterations {
            group.enter()
            q.async {
                router.on("evt-\(i % 8)") { _ in }
                router.dispatch("evt-\(i % 8)", Data())
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 10)
        XCTAssertEqual(result, .success, "concurrent access must complete without deadlock")
        XCTAssertLessThanOrEqual(router.registeredEventCount, 8)
    }
}
