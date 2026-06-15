//
//  InterSecureToolHostViewTests.swift
//  interTests
//
//  Integration tests for the Objective-C stable captured host
//  (`InterSecureToolHostView`) after the SwiftUI migration. The host now holds
//  an `InterSecureToolsBridge` and swaps the bridge-vended `NSHostingView`
//  leaves into its single leaf slot when the active Tool_Kind changes, while
//  keeping its public header API (`activeToolKind`, `setActiveToolKind:`,
//  `activateActiveToolResponder`) unchanged.
//
//  These tests exercise that public API only. Because the bridge vends generic
//  `NSHostingView<…>` instances, the assertions check view-class / containment
//  (a hosting NSView is added beyond the placeholder, placeholder visibility
//  toggles) rather than the concrete SwiftUI root types.
//
//  Requirements traced: 1.6, 1.7, 6.2, 6.3.
//

import XCTest
import AppKit
@testable import inter

@MainActor
final class InterSecureToolHostViewTests: XCTestCase {

    // MARK: - Helpers

    private func makeHost() -> InterSecureToolHostView {
        InterSecureToolHostView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
    }

    /// The placeholder is a private `NSTextField` label subview of the host.
    /// Locate it by class so the tests stay on the public API surface.
    private func placeholderLabel(in host: InterSecureToolHostView) -> NSTextField? {
        host.subviews.compactMap { $0 as? NSTextField }.first
    }

    /// A bridge-vended leaf is an `NSHostingView<…>` (a generic NSView). It
    /// cannot be matched by a non-generic cast, so detect it by class name.
    private func isHostingView(_ view: NSView) -> Bool {
        String(describing: type(of: view)).contains("NSHostingView")
    }

    /// The hosted leaf the host added beyond the placeholder label (if any).
    private func hostedLeaf(in host: InterSecureToolHostView) -> NSView? {
        host.subviews.first { isHostingView($0) }
            ?? host.subviews.first { !($0 is NSTextField) }
    }

    // MARK: - R1.6 / R6.2: CodeEditor swap mounts a hosted leaf, hides placeholder

    func testSetActiveToolKindCodeEditorSwapsToHostedViewAndHidesPlaceholder() {
        let host = makeHost()

        host.setActiveToolKind(.codeEditor)

        XCTAssertEqual(host.activeToolKind, .codeEditor,
                       "selecting CodeEditor must update the active tool kind (R1.6)")

        let leaf = hostedLeaf(in: host)
        XCTAssertNotNil(leaf,
                        "selecting CodeEditor must add the bridge's hosting leaf beyond the placeholder (R1.6, R6.2)")
        XCTAssertTrue(isHostingView(leaf!),
                      "the mounted leaf must be an NSHostingView vended by the bridge (R6.2)")

        let placeholder = placeholderLabel(in: host)
        XCTAssertNotNil(placeholder, "the host must keep its placeholder label")
        XCTAssertTrue(placeholder!.isHidden,
                      "mounting a tool surface must hide the placeholder (R1.6)")
    }

    // MARK: - R1.6 / R6.2: Whiteboard swap mounts a hosted leaf, hides placeholder

    func testSetActiveToolKindWhiteboardSwaps() {
        let host = makeHost()

        host.setActiveToolKind(.whiteboard)

        XCTAssertEqual(host.activeToolKind, .whiteboard,
                       "selecting Whiteboard must update the active tool kind (R1.6)")

        let leaf = hostedLeaf(in: host)
        XCTAssertNotNil(leaf,
                        "selecting Whiteboard must add the bridge's hosting leaf beyond the placeholder (R1.6)")
        XCTAssertTrue(isHostingView(leaf!),
                      "the mounted leaf must be an NSHostingView vended by the bridge (R6.2)")

        let placeholder = placeholderLabel(in: host)
        XCTAssertNotNil(placeholder, "the host must keep its placeholder label")
        XCTAssertTrue(placeholder!.isHidden,
                      "mounting a tool surface must hide the placeholder (R1.6)")
    }

    // MARK: - R1.6: returning to None tears down the leaf and shows the placeholder

    func testSetActiveToolKindNoneShowsPlaceholder() {
        let host = makeHost()

        // Mount a tool first, then return to None.
        host.setActiveToolKind(.codeEditor)
        XCTAssertNotNil(hostedLeaf(in: host), "precondition: a tool leaf is mounted")

        host.setActiveToolKind(InterInterviewToolKind.none)

        XCTAssertEqual(host.activeToolKind, InterInterviewToolKind.none,
                       "selecting None must clear the active tool kind (R1.6)")

        XCTAssertNil(hostedLeaf(in: host),
                     "returning to None must remove the hosted tool leaf (R1.6)")

        let placeholder = placeholderLabel(in: host)
        XCTAssertNotNil(placeholder, "the host must keep its placeholder label")
        XCTAssertFalse(placeholder!.isHidden,
                       "with no tool active the placeholder must be visible (R1.6)")
    }

    // MARK: - R1.7: an unrecognized Tool_Kind preserves the current view

    func testUnrecognizedToolKindPreservesCurrentView() {
        let host = makeHost()

        // Establish a valid, displayed tool surface first.
        host.setActiveToolKind(.codeEditor)
        let leafBefore = hostedLeaf(in: host)
        XCTAssertNotNil(leafBefore, "precondition: CodeEditor leaf is mounted")

        // InterInterviewToolKind is an NS_ENUM (NSUInteger). Swift imports its
        // init?(rawValue:) as failable and returns nil for unknown raw values,
        // so construct an out-of-range case by reinterpreting the raw storage
        // (the enum shares layout with its NSUInteger raw value).
        let unrecognized = unsafeBitCast(UInt(999), to: InterInterviewToolKind.self)

        host.setActiveToolKind(unrecognized)

        // R1.7: the host must NOT blank the captured surface — it keeps the
        // previously displayed tool view and the active kind is unchanged.
        XCTAssertEqual(host.activeToolKind, .codeEditor,
                       "an unrecognized Tool_Kind must leave the active kind unchanged (R1.7)")

        let leafAfter = hostedLeaf(in: host)
        XCTAssertNotNil(leafAfter,
                        "an unrecognized Tool_Kind must preserve the displayed tool leaf (R1.7)")
        XCTAssertTrue(leafBefore === leafAfter,
                      "the SAME tool leaf must remain mounted after an unrecognized kind (R1.7)")

        let placeholder = placeholderLabel(in: host)
        XCTAssertNotNil(placeholder)
        XCTAssertTrue(placeholder!.isHidden,
                      "the preserved tool surface must keep the placeholder hidden (R1.7)")
    }

    // MARK: - R6.2 / R6.3: activating the responder is crash-safe per kind

    func testActivateResponderForCodeEditorDoesNotCrash() {
        let host = makeHost()

        // CodeEditor mounted: activating the responder routes focus through the
        // bridge. Without a window the editor cannot actually become first
        // responder — that is fine; it must simply not crash (R6.2).
        host.setActiveToolKind(.codeEditor)
        host.activateActiveToolResponder()
        XCTAssertEqual(host.activeToolKind, .codeEditor,
                       "activating the responder must not disturb the active kind (R6.2)")

        // Non-CodeEditor kinds must also be crash-safe and must NOT focus the
        // editor (R6.3). Exercise both Whiteboard and None.
        host.setActiveToolKind(.whiteboard)
        host.activateActiveToolResponder()
        XCTAssertEqual(host.activeToolKind, .whiteboard,
                       "activating the responder for a non-editor kind must be a safe no-op for focus (R6.3)")

        host.setActiveToolKind(InterInterviewToolKind.none)
        host.activateActiveToolResponder()
        XCTAssertEqual(host.activeToolKind, InterInterviewToolKind.none,
                       "activating the responder with no tool must not crash or change state (R6.3)")
    }
}
