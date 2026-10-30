//
//  ToolSurfacePresenceInvariantTests.swift
//  interTests
//
//  Property-based test for the interviewer-collaborative-tools spec,
//  design.md **Property 2: Surface presence does not mutate content**
//  (Validates: Requirements 2.7).
//
//  Property 2 states that NO per-side tool lifecycle transition — Inactive ↔
//  Open ↔ Tile, Dismiss, and tool switch (Code ↔ Board) — ever reads-modifies
//  the shared CRDT document. Opening shows the current state via snapshot
//  recovery; closing / dismissing leaves the document byte-for-byte /
//  element-for-element unchanged. Surface presence is a purely *local,
//  in-memory UI* concern (see design § Shared-Session Model and § Per-Side Tool
//  Lifecycle: "lifecycle changes never mutate or reset content"); the shared
//  document stays live throughout and is only ever changed by edit ops, never
//  by presentation transitions.
//
//  ── MODEL-LEVEL CAVEAT (read me) ──────────────────────────────────────────
//  The per-side lifecycle STATE MACHINE itself is not yet implemented — it is
//  task 3.2, and its driven unit tests are task 3.5. This file therefore pins
//  the invariant at the level that is *reachable today*: the document / model
//  level. We model the lifecycle as a PURE sequence of presence states over a
//  fixed shared document and assert that applying an arbitrary seeded sequence
//  of presence transitions — which, by construction, perform NO document
//  operations — leaves the document signature identical (text / liveCount for
//  code, element-for-element rendered signature for board).
//
//  The transition function (`LifecyclePresence.applying(_:)`) deliberately has
//  NO access to any document: presence transitions are *content-free by
//  construction*. That is the load-bearing guarantee this test pins — opening,
//  collapsing to a tile, dismissing, and switching tools must remain
//  content-free. Once the real lifecycle state machine (task 3.2) and its unit
//  tests (task 3.5) exist, the full lifecycle-DRIVEN assertion (presence
//  changes routed through the actual handler against the live host's documents)
//  is exercised there; this test guards the underlying model invariant so a
//  regression that smuggled a document mutation into a presentation transition
//  would be caught against the pure model.
//
//  Convention: follows the repo's seeded-XCTest pattern (no external PBT lib),
//  modeled on `BoardDocumentPropertyTests.swift` — a per-iteration SplitMix64
//  RNG, ≥100 seeded iterations, and the seed printed on failure for exact
//  replay. `CodeEditorDocument` / `BoardDocument` are `@MainActor`, so the test
//  case is annotated accordingly.
//

import CoreGraphics
import XCTest
@testable import inter

// MARK: - Deterministic, seeded RNG
//
// A SplitMix64 generator, distinctly named so it does not collide with the
// `BoardPBTGenerator` / `SeededGenerator` / `RGASeededGenerator` already
// declared elsewhere in the same test target. Seeded per-iteration so every
// draw is reproducible from the printed seed.

private struct PresencePBTGenerator: RandomNumberGenerator {
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

/// Minimum iterations per property (design/Testing Strategy: ≥100).
private let kPresenceIterations = 150

/// A generous cap so the seeded content generators never trip the document
/// size clamps — this test is about presence, not the caps.
private let kPresenceBigCap = 1_000_000

private let kCodeAlphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789 \n\t(){}[]=+-;")

// MARK: - Pure, content-free lifecycle presence model (task 3.2 not yet built)
//
// This models ONLY the user-facing presentation state from design § Per-Side
// Tool Lifecycle. It deliberately holds NO reference to any document and its
// transition function takes NO document argument — presence transitions are
// content-free *by construction*. That is the invariant Property 2 pins.

/// Which tool is currently presented. Each document persists independently for
/// the whole call; switching never mutates either document.
private enum ToolKind: CaseIterable { case code, board }

/// The per-side surface presence states (design state diagram).
private enum ToolPresence: CaseIterable { case inactive, open, tile, dismissed }

/// The lifecycle transition events that drive presence (design state diagram +
/// transition rules). Every one of these is a *presentation* change only.
private enum LifecycleEvent: CaseIterable {
    case controlBarButton   // Inactive / Dismissed -> Open (deliberate click)
    case controlBarToggle   // Open <-> Tile (edit-mode toggle, control-bar only)
    case cameraClick        // Open -> Tile (auto-collapse + spotlight camera)
    case tileClose          // Tile -> Dismissed (tile ⋯ -> Close)
    case toolClosed         // Open -> Inactive (restores remembered Grid/Stage)
    case switchTool         // Code <-> Board (each doc persists; shows current state)
}

/// The pure presence state. Note: NO document is reachable from here.
private struct LifecyclePresence {
    var presence: ToolPresence
    var tool: ToolKind

    /// Apply a lifecycle event, returning the next presence state. This
    /// function CANNOT touch a document (it has none) — that is precisely what
    /// makes every transition content-free. Transitions that do not apply in
    /// the current state are no-ops on `presence` (the surface stays put),
    /// matching the design state machine.
    func applying(_ event: LifecycleEvent) -> LifecyclePresence {
        var next = self
        switch event {
        case .controlBarButton:
            // Reachable from Inactive or Dismissed via the control bar.
            if presence == .inactive || presence == .dismissed { next.presence = .open }
        case .controlBarToggle:
            if presence == .open { next.presence = .tile }
            else if presence == .tile { next.presence = .open }
        case .cameraClick:
            if presence == .open { next.presence = .tile }
        case .tileClose:
            if presence == .tile { next.presence = .dismissed }
        case .toolClosed:
            if presence == .open { next.presence = .inactive }
        case .switchTool:
            // Tool switch flips which document is presented; persistence of the
            // other document is unaffected and neither is mutated.
            next.tool = (tool == .code) ? .board : .code
        }
        return next
    }
}

// MARK: - Document signatures (stable content snapshots)

/// Code document signature: the rendered text plus live-character count and the
/// full element count (including tombstones, via the snapshot) so a mutation to
/// ANY of text, liveness, or the element list is detected byte-for-byte.
@MainActor
private func codeSignature(_ doc: CodeEditorDocument) -> String {
    let snap = doc.snapshot()
    return "text=\(doc.text)|live=\(doc.liveCount)|elems=\(snap.elements.count)"
}

/// Board element signature: id plus every rendered field, so two boards are
/// equal element-for-element only if every property matches.
private func boardElementSignature(_ el: BoardElement) -> String {
    let frame = el.frame.map { "\($0.origin.x),\($0.origin.y),\($0.size.width),\($0.size.height)" } ?? "nil"
    let points = el.points.map { pts in pts.map { "\($0.x):\($0.y)" }.joined(separator: "|") } ?? "nil"
    return [
        el.id,
        el.kind.rawValue,
        points,
        frame,
        "\(el.rotation)",
        "\(el.strokeColor)",
        "\(el.strokeWidth)",
        el.text ?? "nil",
        el.zKey,
        el.groupId ?? "nil"
    ].joined(separator: "~")
}

@MainActor
private func boardSignature(_ doc: BoardDocument) -> [String] {
    doc.renderedElements.map(boardElementSignature)
}

// MARK: - Seeded content builders

/// A shared code document seeded with some content via real edit ops, so the
/// snapshot we pin is non-trivial.
@MainActor
private func makeSeededCodeDocument(_ rng: inout PresencePBTGenerator) -> CodeEditorDocument {
    let doc = CodeEditorDocument(site: "A", maxLiveChars: kPresenceBigCap, maxHistoryEntries: kPresenceBigCap)
    let edits = Int.random(in: 3...20, using: &rng)
    for _ in 0..<edits {
        let len = Int.random(in: 1...12, using: &rng)
        let s = String((0..<len).map { _ in kCodeAlphabet.randomElement(using: &rng)! })
        let offset = Int.random(in: 0...max(0, doc.liveCount), using: &rng)
        _ = doc.localInsert(at: offset, s)
        // Occasionally delete a span so tombstones exist in the snapshot.
        if doc.liveCount > 2, Int.random(in: 0..<3, using: &rng) == 0 {
            let lo = Int.random(in: 0..<doc.liveCount, using: &rng)
            let hi = Int.random(in: lo...doc.liveCount, using: &rng)
            _ = doc.localDelete(range: lo..<hi)
        }
    }
    return doc
}

/// A shared board document seeded with some elements via real add/update ops.
@MainActor
private func makeSeededBoardDocument(_ rng: inout PresencePBTGenerator) -> BoardDocument {
    let doc = BoardDocument(site: "A",
                            maxElements: kPresenceBigCap,
                            maxStrokePoints: kPresenceBigCap,
                            maxHistoryEntries: kPresenceBigCap)
    let kinds: [BoardElementKind] = [.freehand, .rectangle, .ellipse, .line, .arrow, .text]
    let adds = Int.random(in: 3...18, using: &rng)
    for _ in 0..<adds {
        let kind = kinds.randomElement(using: &rng)!
        let color = WhiteboardColor.allCases.randomElement(using: &rng)!
        let width = CGFloat(Int.random(in: 1...8, using: &rng))
        let frame = CGRect(x: CGFloat(Int.random(in: -300...300, using: &rng)),
                           y: CGFloat(Int.random(in: -300...300, using: &rng)),
                           width: CGFloat(Int.random(in: 1...400, using: &rng)),
                           height: CGFloat(Int.random(in: 1...400, using: &rng)))
        switch kind {
        case .freehand, .line, .arrow:
            let n = Int.random(in: 1...12, using: &rng)
            let points = (0..<n).map { _ in
                CGPoint(x: CGFloat(Int.random(in: -500...500, using: &rng)),
                        y: CGFloat(Int.random(in: -500...500, using: &rng)))
            }
            _ = doc.addElement(kind: kind, points: points, strokeColor: color, strokeWidth: width)
        case .text:
            let len = Int.random(in: 1...8, using: &rng)
            let txt = String((0..<len).map { _ in kCodeAlphabet.randomElement(using: &rng)! })
            _ = doc.addElement(kind: .text, frame: frame, strokeColor: color, strokeWidth: width, text: txt)
        default:
            _ = doc.addElement(kind: kind, frame: frame, strokeColor: color, strokeWidth: width)
        }
    }
    return doc
}

/// A random seeded sequence of lifecycle events.
private func makeEventSequence(_ rng: inout PresencePBTGenerator) -> [LifecycleEvent] {
    let count = Int.random(in: 5...40, using: &rng)
    return (0..<count).map { _ in LifecycleEvent.allCases.randomElement(using: &rng)! }
}

// MARK: - Property 2: Surface presence does not mutate content

@MainActor
final class ToolSurfacePresenceInvariantTests: XCTestCase {

    // Feature: interviewer-collaborative-tools, Property 2 — Surface presence
    // does not mutate content (MODEL LEVEL; see file header caveat).
    //
    // Build shared Code + Board documents with seeded content, capture their
    // signatures, then drive an arbitrary seeded sequence of presence
    // transitions (Inactive↔Open↔Tile, Dismiss, tool switch) that — by
    // construction — perform NO document ops, and assert each document's
    // signature is identical before and after every transition and after the
    // whole sequence.
    //
    // Validates: Requirements 2.7
    func testProperty2_SurfacePresenceDoesNotMutateContent() {
        let base: UInt64 = 0x7501_0002_0000
        for i in 0..<kPresenceIterations {
            let seed = base &+ UInt64(i)
            var rng = PresencePBTGenerator(seed: seed)

            // Shared documents with seeded content (the "live throughout" docs).
            let codeDoc = makeSeededCodeDocument(&rng)
            let boardDoc = makeSeededBoardDocument(&rng)

            // Pin the content signatures BEFORE any presence activity.
            let codeBefore = codeSignature(codeDoc)
            let boardBefore = boardSignature(boardDoc)

            // Start from the canonical initial presentation state (Inactive).
            var state = LifecyclePresence(presence: .inactive, tool: .code)
            let events = makeEventSequence(&rng)

            let msg = { (which: String) in
                "Property 2 (\(which)) failed: seed=0x\(String(seed, radix: 16)) iteration=\(i)\n"
                + "events=\(events)"
            }

            // Drive every presence transition. A content-free transition must
            // leave BOTH documents byte-for-byte / element-for-element intact at
            // every step.
            for event in events {
                state = state.applying(event)
                XCTAssertEqual(codeSignature(codeDoc), codeBefore,
                               msg("code mutated by presence transition \(event)"))
                XCTAssertEqual(boardSignature(boardDoc), boardBefore,
                               msg("board mutated by presence transition \(event)"))
            }

            // Final guard: after the full transition sequence the shared
            // documents are unchanged (closing / dismissing leaves content
            // intact; tool switch never mutates either document).
            XCTAssertEqual(codeSignature(codeDoc), codeBefore, msg("code changed after sequence"))
            XCTAssertEqual(boardSignature(boardDoc), boardBefore, msg("board changed after sequence"))

            // Sanity: the seeded content was actually non-trivial, so the
            // invariant is being pinned against a real document, not an empty
            // one. (A vacuous all-empty signature would make the test toothless.)
            XCTAssertFalse(codeDoc.text.isEmpty && boardDoc.renderedElements.isEmpty,
                           msg("seeded documents were unexpectedly empty"))
        }
    }
}
