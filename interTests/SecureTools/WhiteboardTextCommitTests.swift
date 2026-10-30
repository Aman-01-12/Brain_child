//
//  WhiteboardTextCommitTests.swift
//  interTests
//
//  Tests for Fix 3 (collab-tool-ux-fixes spec, Requirement 3): the inline
//  whiteboard text editor must commit its in-progress text on focus loss, not
//  only on Escape. Excalidraw commits on blur; we mirror that by committing when
//  the field editor resigns first responder, when the editor's OWN hosting
//  window resigns key, and on Escape — funneling every trigger through a single
//  idempotent `commitOnce()` guard that is reset per editing session.
//
//  These cases drive the production
//  `SecureWhiteboardTextField.Coordinator` directly against a REAL
//  `SecureCodeTextView` field editor mounted in a REAL `NSWindow`, so the
//  first-responder/window-key seams (and the own-window observer scoping) are
//  exercised against the same AppKit plumbing the app uses — no mocks. The
//  `onCommit` closure increments a counter so each property is an explicit,
//  automated assertion.
//
//  The Coordinator is not `@MainActor` but its `commitOnce()` calls
//  `MainActor.assumeIsolated`, so every case runs on the main thread (this test
//  case is `@MainActor`).
//
//  Property 5: Inline text commits on focus loss.
//  Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7
//

import AppKit
import SwiftUI
import XCTest
@testable import inter

// MARK: - Deterministic, seeded RNG
//
// Follows the established repo convention (see `BoardDocumentPropertyTests`,
// `StrokeModelPropertyTests`): a SplitMix64 generator, distinctly named so it
// does not collide with siblings, seeded per-iteration so every draw is
// reproducible and any counterexample can be replayed exactly.

private struct WhiteboardCommitPBTGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Minimum iterations per property (repo convention: ≥100).
private let kCommitIterations = 150

@MainActor
final class WhiteboardTextCommitTests: XCTestCase {

    // MARK: - Commit-trigger model

    /// The three commit triggers that funnel through the Coordinator's
    /// per-session `commitOnce()` guard. (A fourth, "new-pointer", is sourced at
    /// the `WhiteboardRootView` layer via `commitTextEntry()` — task 3.2 — so it
    /// is not a Coordinator-level seam and is not modelled here.)
    private enum CommitTrigger: CaseIterable {
        case escape          // cancelOperation: (Escape key)
        case blur            // textDidEndEditing (first-responder resign)
        case ownWindowResign // NSWindow.didResignKeyNotification on the OWN window
    }

    // MARK: - Test harness

    /// A live editing session: a real `SecureCodeTextView` field editor mounted
    /// in a real `NSWindow`, with its Coordinator attached (binding the
    /// own-window resign observer) and an `onCommit` counter.
    private final class Session {
        let window: NSWindow
        let textView: SecureCodeTextView
        let coordinator: SecureWhiteboardTextField.Coordinator
        private let box: StringBox
        private let counter: Counter

        final class StringBox { var value: String; init(_ v: String) { value = v } }
        final class Counter { var count = 0 }

        var commitCount: Int { counter.count }

        init(initialText: String = "") {
            let counter = Counter()
            let box = StringBox(initialText)
            self.counter = counter
            self.box = box

            // Real window so `textView.window` is non-nil and the resign observer
            // can scope to it.
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled], backing: .buffered, defer: false)
            self.window = window

            // Minimal TextKit stack mirroring the production field editor.
            let textStorage = NSTextStorage(string: initialText)
            let layoutManager = NSLayoutManager()
            textStorage.addLayoutManager(layoutManager)
            let textContainer = NSTextContainer(
                size: NSSize(width: CGFloat.greatestFiniteMagnitude,
                             height: CGFloat.greatestFiniteMagnitude))
            layoutManager.addTextContainer(textContainer)
            let textView = SecureCodeTextView(
                frame: NSRect(x: 0, y: 0, width: 200, height: 40),
                textContainer: textContainer)
            self.textView = textView
            // Mount in the hierarchy so `textView.window === window`.
            window.contentView?.addSubview(textView)

            let binding = Binding<String>(get: { box.value }, set: { box.value = $0 })
            let coordinator = SecureWhiteboardTextField.Coordinator(
                text: binding, characterLimit: 280,
                onCommit: { counter.count += 1 }, onSizeChange: { _ in })
            self.coordinator = coordinator
            // `attach` binds the resign observer to the OWN window and resets the
            // per-session commit guard.
            coordinator.attach(textView)
        }

        /// Begin a fresh editing session on the same persisted Coordinator (the
        /// re-`attach` / new-active-edit path), resetting the per-session guard.
        func beginNewSession(viaAttach: Bool) {
            if viaAttach {
                coordinator.attach(textView)
            } else {
                coordinator.beginSession()
            }
        }

        func fire(_ trigger: CommitTrigger) {
            switch trigger {
            case .escape:
                _ = coordinator.textView(
                    textView, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
            case .blur:
                coordinator.textDidEndEditing(
                    Notification(name: NSText.didEndEditingNotification, object: textView))
            case .ownWindowResign:
                NotificationCenter.default.post(
                    name: NSWindow.didResignKeyNotification, object: window)
            }
        }
    }

    // MARK: - P3.1 — commit on blur (first-responder resign)

    func testCommitOnBlur() {
        let session = Session(initialText: "annotation")
        XCTAssertEqual(session.commitCount, 0, "no commit before any trigger")

        session.fire(.blur)
        XCTAssertEqual(session.commitCount, 1,
                       "resigning first responder (click-outside / tab away) must commit (3.1)")
    }

    // MARK: - P3.3 — Escape still commits

    func testEscapeStillCommits() {
        let session = Session(initialText: "annotation")

        session.fire(.escape)
        XCTAssertEqual(session.commitCount, 1,
                       "Escape (cancelOperation:) must still commit (3.3)")
    }

    // MARK: - P3.2 — own-window resign commits; other-window resign does NOT

    func testOwnWindowResignCommitsExactlyOnce() {
        let session = Session(initialText: "annotation")

        session.fire(.ownWindowResign)
        XCTAssertEqual(session.commitCount, 1,
                       "the editor's OWN hosting window resigning key must commit (3.2)")
    }

    func testForeignWindowResignDoesNotCommit() {
        let session = Session(initialText: "annotation")

        // A DIFFERENT, unrelated window (e.g. an interviewer-side panel) resigns
        // key. The observer is scoped to `object: textView.window`, so this must
        // NOT deliver to the coordinator and must NOT commit (3.3 / Finding #6).
        let foreignWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification, object: foreignWindow)
        XCTAssertEqual(session.commitCount, 0,
                       "an unrelated window resigning key must NOT commit (3.3)")

        // The OWN window still commits — proving the observer is live, just scoped.
        session.fire(.ownWindowResign)
        XCTAssertEqual(session.commitCount, 1,
                       "the OWN window resigning key must still commit exactly once (3.2)")
    }

    // MARK: - P3.6 — empty / abandoned edit follows the same commit path

    func testEmptyEditStillCommits() {
        // An empty/abandoned edit must still invoke onCommit (the same path the
        // Escape route uses) — no behavioral regression versus Escape (3.7). The
        // empty-text semantics themselves live in `commitText`.
        let blurSession = Session(initialText: "")
        blurSession.fire(.blur)
        XCTAssertEqual(blurSession.commitCount, 1,
                       "an empty edit committed on blur still invokes the commit path (3.7)")

        let escapeSession = Session(initialText: "")
        escapeSession.fire(.escape)
        XCTAssertEqual(escapeSession.commitCount, 1,
                       "an empty edit committed on Escape still invokes the commit path (3.7)")
    }

    // MARK: - P3.4 — per-session idempotency under combined triggers (property)

    func testPerSessionIdempotencyUnderCombinedTriggers() {
        let base: UInt64 = 0xC031_0004_0000
        for i in 0..<kCommitIterations {
            let seed = base &+ UInt64(i)
            var rng = WhiteboardCommitPBTGenerator(seed: seed)

            // A random non-empty multiset/sequence of {Escape, blur,
            // own-window-resign} — possibly with repeats and in any order.
            let triggerCount = Int.random(in: 1...6, using: &rng)
            let triggers = (0..<triggerCount).map { _ in
                CommitTrigger.allCases.randomElement(using: &rng)!
            }

            let session = Session(initialText: "edit-\(i)")
            for trigger in triggers { session.fire(trigger) }

            XCTAssertEqual(
                session.commitCount, 1,
                "Property 5 (per-session idempotency) failed: seed=0x\(String(seed, radix: 16)) "
                + "iteration=\(i) triggers=\(triggers) — commit must fire at most once per session (3.4)")
        }
    }

    // MARK: - P3.5 — cross-session reset: a new session commits AGAIN (property)

    func testCrossSessionResetCommitsAgain() {
        let base: UInt64 = 0xC031_0005_0000
        for i in 0..<kCommitIterations {
            let seed = base &+ UInt64(i)
            var rng = WhiteboardCommitPBTGenerator(seed: seed)

            let session = Session(initialText: "edit-\(i)")

            // --- Session 1: a random trigger sequence commits exactly once. ---
            let firstCount = Int.random(in: 1...4, using: &rng)
            for _ in 0..<firstCount {
                session.fire(CommitTrigger.allCases.randomElement(using: &rng)!)
            }
            XCTAssertEqual(
                session.commitCount, 1,
                "Property 5 (session 1) failed: seed=0x\(String(seed, radix: 16)) iteration=\(i) "
                + "— first session must commit exactly once")

            // --- Begin session 2 on the SAME persisted Coordinator. The
            // per-session guard MUST reset so the new session commits AGAIN — the
            // persisted Coordinator must not silently block later sessions
            // (Findings #5 / #11). Alternate between the re-attach path and the
            // beginSession (updateNSView new-seed) path across iterations. ---
            session.beginNewSession(viaAttach: i.isMultiple(of: 2))

            let secondCount = Int.random(in: 1...4, using: &rng)
            for _ in 0..<secondCount {
                session.fire(CommitTrigger.allCases.randomElement(using: &rng)!)
            }
            XCTAssertEqual(
                session.commitCount, 2,
                "Property 5 (session 2 reset) failed: seed=0x\(String(seed, radix: 16)) iteration=\(i) "
                + "viaAttach=\(i.isMultiple(of: 2)) — a NEW session must reset the guard and commit "
                + "again (3.5); the persisted Coordinator must not block it")
        }
    }
}
