//
//  InterCallControlBarBridgeTests.swift
//  interTests
//
//  Tests the interviewer Code/Board tool additions on the normal-mode
//  AppKit↔SwiftUI control-bar bridge (`InterCallControlBarBridge`), wired in
//  task 1.4: the `interviewToolChangedHandler` callback plus the three `@objc`
//  setters `setInterviewToolsVisible(_:)`, `setSelectedInterviewToolKind(_:)`,
//  and `setToolBadge(_:)` (Requirements 2.6, 4.6, 5.3).
//
//  REACHABILITY NOTE
//  -----------------
//  The bridge owns its `CallControlBarViewModel` as a `private let viewModel`.
//  Production access is intentionally NOT weakened for tests, so the published
//  tool state the setters mutate (`interviewToolsVisible`, `selectedToolKind`,
//  `toolBadgeActive`) is not directly readable from this target. We therefore
//  assert only the genuinely reachable surface:
//
//    * The bridge instantiates and the three `@objc` tool setters are callable
//      on the main actor without crashing (they each run
//      `MainActor.assumeIsolated`). This is a compile-time + runtime smoke check
//      that the parity surface exists and is invocable — the same surface
//      `InterMediaWiringController` / `AppDelegate` drive in production.
//    * `interviewToolChangedHandler` is an assignable stored property whose
//      closure, once assigned, is retained by the bridge and is invocable with
//      the raw `InterInterviewToolKind` value.
//
//  What is NOT asserted here (and why):
//    * That a *user selection* in the SwiftUI segmented control routes through
//      `viewModel.onSelectTool` into `interviewToolChangedHandler`. The view
//      model is `private`, and only the SwiftUI control drives `onSelectTool`,
//      so that routing is not reachable from this target. It is covered by the
//      view-model test (task 1.2, `CallControlBarViewModelTests` — `onSelectTool`
//      routing) and the SwiftUI control (task 1.3).
//    * That each setter flips its backing `@Published` value. The published
//      values are behind the `private` view model and are validated at the
//      view-model layer (task 1.2).
//

import XCTest
@testable import inter

@MainActor
final class InterCallControlBarBridgeTests: XCTestCase {

    private func makeBridge() -> InterCallControlBarBridge {
        InterCallControlBarBridge(frame: NSRect(x: 0, y: 0, width: 600, height: 64))
    }

    // `InterInterviewToolKind` is an ObjC `NS_ENUM(NSUInteger, …)`, so its
    // `rawValue` is `UInt`; the bridge surface carries the raw kind as `Int`.
    private func raw(_ kind: InterInterviewToolKind) -> Int { Int(kind.rawValue) }

    // MARK: - Instantiation

    func testBridgeInstantiates() {
        let bridge = makeBridge()
        XCTAssertNotNil(bridge, "the normal-mode control-bar bridge constructs and hosts its view")
    }

    // MARK: - Tool setters are callable (main-actor smoke)

    func testInterviewToolSettersAreCallableWithoutCrashing() {
        let bridge = makeBridge()

        // Each setter runs `MainActor.assumeIsolated` internally; invoking them
        // on the main actor exercises that path. We cannot read the resulting
        // private view-model state (see header), so this is a callability +
        // no-crash smoke check of the production-driven surface.
        bridge.setInterviewToolsVisible(true)
        bridge.setInterviewToolsVisible(false)

        bridge.setSelectedInterviewToolKind(raw(.codeEditor))
        bridge.setSelectedInterviewToolKind(raw(.whiteboard))
        bridge.setSelectedInterviewToolKind(raw(.none))

        bridge.setToolBadge(true)
        bridge.setToolBadge(false)
    }

    // MARK: - interviewToolChangedHandler assignability / retention

    func testInterviewToolChangedHandlerIsAssignableAndRetained() {
        let bridge = makeBridge()
        XCTAssertNil(bridge.interviewToolChangedHandler, "handler is unset by default")

        var received: [Int] = []
        bridge.interviewToolChangedHandler = { received.append($0) }

        XCTAssertNotNil(bridge.interviewToolChangedHandler,
                        "assigned closure is retained as a stored property on the bridge")

        // Invoke the retained closure directly with raw InterInterviewToolKind
        // values. (A real user selection drives this via the private view
        // model's `onSelectTool`, which is covered by the view-model test 1.2.)
        bridge.interviewToolChangedHandler?(raw(.codeEditor))
        bridge.interviewToolChangedHandler?(raw(.whiteboard))

        XCTAssertEqual(received,
                       [raw(.codeEditor), raw(.whiteboard)],
                       "the retained handler fires with the raw tool kind it was invoked with")
    }

    func testInterviewToolChangedHandlerIsClearable() {
        let bridge = makeBridge()
        bridge.interviewToolChangedHandler = { _ in }
        XCTAssertNotNil(bridge.interviewToolChangedHandler)
        bridge.interviewToolChangedHandler = nil
        XCTAssertNil(bridge.interviewToolChangedHandler, "handler can be torn down (teardown parity)")
    }
}
