//
//  CodeEditorDocument.swift
//  inter
//
//  The convergence core of the collaborative code editor: a Replicated
//  Growable Array (RGA) sequence CRDT over `Character`s. This is a pure,
//  `@MainActor`, dependency-light model — NO networking, NO AppKit/SwiftUI,
//  only Foundation value types. The transport (InterCodeEditorController),
//  wire encoding (InterCodeEditorMessage), and the native editor surface are
//  separate layers that drive this model.
//
//  Why an RGA (see design.md "Document Model & Convergence"): deterministic
//  convergence is a *structural* guarantee (ops commute and are idempotent)
//  rather than a protocol invariant, so two replicas that have applied the
//  same SET of operations in ANY order render identical text (R2.2, R2.3). It
//  is symmetric (either peer may reconnect and merge automatically — R4.2,
//  R8.2) and its algebraic laws map directly onto property-based tests.
//
//  Structure:
//    - The document is an ordered list of `Element`s (characters), including
//      tombstones for deleted characters, plus an `id -> array index` map for
//      O(1) lookup.
//    - Every character has a globally-unique `ElementID { site, seq }` where
//      `site` is the attested participant identity and `seq` is a per-site
//      monotonic counter. The pair gives each character a stable identity for
//      the session (used for cursor anchoring — R2.4, R2.5).
//    - Concurrent inserts after the same `originLeft` are ordered by
//      `(seq, site)` DESCENDING so every replica agrees (R2.3).
//    - Deletes mark a tombstone; rendered text skips tombstones (R5.4).
//    - Inserts whose `originLeft` has not yet arrived are buffered until their
//      origin is integrated (causal readiness).
//
//  This file is intentionally written to be unit- and property-testable in
//  isolation (Task 2 proves the convergence properties against it).
//

import Foundation

// MARK: - Value types

/// Globally-unique identity of a single character element.
///
/// `site` is the LiveKit-attested participant identity (never self-declared);
/// `seq` is a per-site monotonic counter. The pair is unique across the
/// session. `Comparable` provides the deterministic total order used to break
/// ties when two sites insert after the same `originLeft`: order by `seq`, then
/// by `site` as a stable secondary key.
struct ElementID: Hashable, Comparable {
    let site: String
    let seq: UInt64

    static func < (lhs: ElementID, rhs: ElementID) -> Bool {
        if lhs.seq != rhs.seq { return lhs.seq < rhs.seq }
        return lhs.site < rhs.site
    }
}

/// A single character in the RGA sequence.
///
/// `originLeft` is the id of the element this character was inserted to the
/// right of (`nil` == inserted at the head). `deleted` is the tombstone flag:
/// once `true` the element is never rendered but its id is retained so that
/// element ordering stays stable across replicas.
struct Element: Equatable {
    let id: ElementID
    let value: Character
    let originLeft: ElementID?
    var deleted: Bool
}

/// A replicated operation. Inserts and deletes are the only mutations; both are
/// idempotent and commutative, which is what gives the document its
/// convergence guarantee. This is the model-level op; the wire encoding
/// (`InterCodeEditorMessage`) is a separate layer.
struct Op: Equatable {
    enum Kind: Equatable {
        case insert
        case delete
    }

    let kind: Kind
    let id: ElementID
    /// The character for an insert; `nil` for a delete.
    let value: Character?
    /// The left origin for an insert; `nil` for a delete or a head insert.
    let originLeft: ElementID?

    static func insert(id: ElementID, value: Character, originLeft: ElementID?) -> Op {
        Op(kind: .insert, id: id, value: value, originLeft: originLeft)
    }

    static func delete(id: ElementID) -> Op {
        Op(kind: .delete, id: id, value: nil, originLeft: nil)
    }
}

/// A full authoritative state for late-join / reconnect recovery (R4.1, R4.3).
/// Carries the complete ordered element list (including tombstones, so ids stay
/// consistent) plus a per-site sequence vector (the max `seq` observed per
/// site) so a receiver can advance its own counters and merge idempotently.
struct Snapshot: Equatable {
    let elements: [Element]
    let seqVector: [String: UInt64]
}

// MARK: - Document

/// The RGA document model. Owned for the whole session by the editor bridge.
@MainActor
final class CodeEditorDocument {

    // MARK: Configuration

    /// The local participant's attested identity, stamped into every locally
    /// generated `ElementID.site`.
    let site: String

    /// Hard cap on the number of LIVE (non-tombstone) characters. Local inserts
    /// past this cap are refused (R6.3); REMOTE ops are ALWAYS applied so
    /// convergence is never sacrificed for the cap.
    let maxLiveChars: Int

    /// Upper bound on retained local undo/redo history entries.
    private let maxHistoryEntries: Int

    // MARK: Storage

    /// The ordered RGA sequence, including tombstones.
    private(set) var elements: [Element] = []

    /// `ElementID -> array index` for O(1) lookup. Kept in sync with `elements`.
    private var index: [ElementID: Int] = [:]

    /// Number of live (non-tombstone) elements. Maintained incrementally so the
    /// size clamp does not need an O(n) scan.
    private(set) var liveCount: Int = 0

    /// Per-site max `seq` observed (the snapshot sequence vector).
    private var seqVector: [String: UInt64] = [:]

    /// Local monotonic counter for generating new element ids.
    private var counter: UInt64 = 0

    // MARK: Causal-readiness buffers

    /// Inserts whose `originLeft` is not yet present, keyed by the missing
    /// origin id. Integrated (and cascaded) once the origin arrives.
    private var pendingInserts: [ElementID: [Op]] = [:]

    /// Deletes whose target element is not yet present. Applied when the
    /// element is later integrated.
    private var pendingDeletes: Set<ElementID> = []

    // MARK: Undo / redo

    /// Stacks of op-groups. `undoStack` holds the most recently applied local
    /// actions (or the inverses produced by redo); `redoStack` holds the
    /// inverses produced by undo. Inversion is recomputed against current state
    /// because RGA insert/delete are not perfect inverses by id (resurrecting
    /// deleted text re-inserts fresh ids — see `applyInverse`).
    private var undoStack: [[Op]] = []
    private var redoStack: [[Op]] = []

    // MARK: Flags

    /// Set `true` when the most recent local insert was refused for exceeding
    /// `maxLiveChars` (R6.3). The UI surfaces a non-blocking notice from this.
    private(set) var didHitSizeLimit: Bool = false

    // MARK: Init

    init(site: String, maxLiveChars: Int = 100_000, maxHistoryEntries: Int = 200) {
        self.site = site
        self.maxLiveChars = max(0, maxLiveChars)
        self.maxHistoryEntries = max(0, maxHistoryEntries)
    }

    /// Clears the size-limit flag (e.g. once the user has dismissed the notice
    /// or removed characters).
    func clearSizeLimitFlag() {
        didHitSizeLimit = false
    }

    /// `true` when the document holds no elements at all (not even tombstones).
    /// Used by the controller to decide whether a freshly-mounted / reconnected
    /// replica should request an authoritative snapshot (R4.1, R4.2). A document
    /// with only tombstones is NOT empty — its element ids must stay consistent.
    var isEmpty: Bool { elements.isEmpty }

    /// The number of inserts currently buffered awaiting an `originLeft` that
    /// has not yet been integrated (causal-readiness backlog). The controller
    /// watches this to self-heal: an origin that never resolves within a bounded
    /// window triggers a snapshot request (R8.4). Pure read of internal state.
    var pendingInsertCount: Int { pendingInserts.count }

    /// `true` when at least one insert is buffered awaiting an unresolved
    /// `originLeft`.
    var hasUnresolvedInserts: Bool { !pendingInserts.isEmpty }
}

// MARK: - Rendered text & cursor anchoring (R2.5, R2.6)

extension CodeEditorDocument {

    /// The visible string: the in-order concatenation of non-tombstone element
    /// values.
    var text: String {
        var s = String()
        s.reserveCapacity(liveCount)
        for el in elements where !el.deleted {
            s.append(el.value)
        }
        return s
    }

    /// The live element id at the given 0-based live offset, or `nil` if the
    /// offset is out of range. Used to anchor a cursor to a stable id.
    func id(at offset: Int) -> ElementID? {
        guard offset >= 0 else { return nil }
        var live = 0
        for el in elements where !el.deleted {
            if live == offset { return el.id }
            live += 1
        }
        return nil
    }

    /// The 0-based live offset of the element with `id`, or `nil` if the id is
    /// unknown or tombstoned. Round-trips with `id(at:)` for every live offset
    /// (Property 6).
    func offset(of id: ElementID) -> Int? {
        guard let idx = index[id], !elements[idx].deleted else { return nil }
        var live = 0
        var i = 0
        while i < idx {
            if !elements[i].deleted { live += 1 }
            i += 1
        }
        return live
    }
}

// MARK: - Local edits (R2.1)

extension CodeEditorDocument {

    /// Inserts `text` at the given live offset, generating fresh `(site, seq+1)`
    /// ids, mutating the RGA, and returning the generated ops for publishing.
    ///
    /// Refuses the whole insertion (returns `[]` and sets `didHitSizeLimit`)
    /// when it would push the live character count past `maxLiveChars` (R6.3).
    /// The offset is clamped into `0...liveCount`.
    func localInsert(at offset: Int, _ text: String) -> [Op] {
        didHitSizeLimit = false
        let chars = Array(text)
        guard !chars.isEmpty else { return [] }

        if liveCount + chars.count > maxLiveChars {
            didHitSizeLimit = true
            return []
        }

        let clamped = min(max(offset, 0), liveCount)
        var leftID: ElementID? = clamped > 0 ? id(at: clamped - 1) : nil

        var ops: [Op] = []
        ops.reserveCapacity(chars.count)
        for ch in chars {
            let newID = nextLocalID()
            let op = Op.insert(id: newID, value: ch, originLeft: leftID)
            integrate(op)
            ops.append(op)
            leftID = newID
        }

        recordLocalAction(ops)
        return ops
    }

    /// Deletes the live characters in `range` (live offsets), marking tombstones
    /// and returning the generated delete ops for publishing. The range is
    /// clamped into `0...liveCount`.
    func localDelete(range: Range<Int>) -> [Op] {
        let lo = min(max(range.lowerBound, 0), liveCount)
        let hi = min(max(range.upperBound, lo), liveCount)
        guard lo < hi else { return [] }

        // Collect the target ids first, before mutating liveness.
        let targets = liveIDs(in: lo..<hi)
        var ops: [Op] = []
        ops.reserveCapacity(targets.count)
        for id in targets {
            let op = Op.delete(id: id)
            integrate(op)
            ops.append(op)
        }

        recordLocalAction(ops)
        return ops
    }

    /// Generates the next monotonic local id, keeping the counter ahead of any
    /// previously-observed sequence for this site (so reconnect/snapshot merges
    /// cannot collide with fresh local ids).
    private func nextLocalID() -> ElementID {
        counter = max(counter, seqVector[site] ?? 0) + 1
        return ElementID(site: site, seq: counter)
    }

    /// Live element ids whose live offset falls in `range`.
    private func liveIDs(in range: Range<Int>) -> [ElementID] {
        var result: [ElementID] = []
        var live = 0
        for el in elements where !el.deleted {
            if live >= range.upperBound { break }
            if live >= range.lowerBound { result.append(el.id) }
            live += 1
        }
        return result
    }
}

// MARK: - Integration of ops (local or remote) (R2.2, R2.3)

extension CodeEditorDocument {

    /// Applies an op to the document. Identical for locally-generated and
    /// remotely-received ops. Idempotent: re-applying a known insert id or an
    /// already-tombstoned delete is a no-op.
    func integrate(_ op: Op) {
        switch op.kind {
        case .insert:
            integrateInsert(op)
        case .delete:
            integrateDelete(op)
        }
    }

    private func integrateInsert(_ op: Op) {
        bumpSeqVector(op.id)

        // Malformed (insert without a value) — ignore safely (R5.4).
        guard op.value != nil else { return }

        // Idempotent: already known.
        if index[op.id] != nil { return }

        // Causal readiness: origin not yet present -> buffer.
        if let origin = op.originLeft, index[origin] == nil {
            pendingInserts[origin, default: []].append(op)
            return
        }

        // Place this op and cascade any inserts that were waiting on it. An
        // explicit worklist (rather than recursion) keeps deep dependency
        // chains from overflowing the stack.
        var work: [Op] = [op]
        while let cur = work.popLast() {
            if index[cur.id] != nil { continue }
            guard let value = cur.value else { continue }

            if let origin = cur.originLeft, index[origin] == nil {
                pendingInserts[origin, default: []].append(cur)
                continue
            }

            bumpSeqVector(cur.id)
            let leftIndex = cur.originLeft.flatMap { index[$0] } ?? -1
            let pos = insertionPosition(for: cur.id, afterLeftIndex: leftIndex)
            elements.insert(Element(id: cur.id, value: value, originLeft: cur.originLeft, deleted: false), at: pos)
            reindex(from: pos)
            liveCount += 1

            // A delete may have arrived before this element — apply it now.
            if pendingDeletes.remove(cur.id) != nil {
                markDeleted(cur.id)
            }

            // Cascade: integrate inserts that were buffered against this id.
            if let waiters = pendingInserts.removeValue(forKey: cur.id) {
                work.append(contentsOf: waiters)
            }
        }
    }

    private func integrateDelete(_ op: Op) {
        bumpSeqVector(op.id)

        guard let idx = index[op.id] else {
            // Target not yet present — buffer until it arrives (R5.4).
            pendingDeletes.insert(op.id)
            return
        }

        // Idempotent: already a tombstone.
        guard !elements[idx].deleted else { return }
        markDeleted(op.id)
    }

    /// Computes the array position for a new element inserted to the right of
    /// `leftIndex` (`-1` == head), implementing the causal-tree preorder with a
    /// `(seq, site)`-DESCENDING tie-break among siblings sharing the same
    /// origin. Because the rule depends only on ids and origins, every replica
    /// arrives at the same ordering regardless of arrival order (R2.3).
    private func insertionPosition(for newID: ElementID, afterLeftIndex leftIndex: Int) -> Int {
        var i = leftIndex + 1
        while i < elements.count {
            let cur = elements[i]
            let curOrigin = cur.originLeft.flatMap { index[$0] } ?? -1

            // Reached an element anchored to the left of our origin: stop here.
            if curOrigin < leftIndex { break }

            // A sibling (same origin) with a smaller id: the new element, having
            // the larger id, sorts before it — stop here.
            if curOrigin == leftIndex && newID > cur.id { break }

            // Otherwise `cur` is either a higher-id sibling or a descendant of
            // one; skip past it (and, implicitly, its subtree).
            i += 1
        }
        return i
    }

    private func markDeleted(_ id: ElementID) {
        guard let idx = index[id], !elements[idx].deleted else { return }
        elements[idx].deleted = true
        liveCount -= 1
    }

    /// Rebuilds the `id -> index` map for every entry from `start` onward.
    private func reindex(from start: Int) {
        var j = start
        while j < elements.count {
            index[elements[j].id] = j
            j += 1
        }
    }

    private func bumpSeqVector(_ id: ElementID) {
        if let current = seqVector[id.site], current >= id.seq { return }
        seqVector[id.site] = id.seq
    }
}

// MARK: - Undo / redo as inverse ops (R1.5)

extension CodeEditorDocument {

    /// Undoes the most recent local action, applying the inverse locally and
    /// returning the inverse ops to publish. Undo of inserts emits deletes of
    /// those ids; undo of deletes re-inserts the characters (with fresh ids, so
    /// the operation stays convergent). Returns `[]` when there is nothing to
    /// undo.
    func undo() -> [Op] {
        guard let group = undoStack.popLast() else { return [] }
        let inverse = applyInverse(of: group)
        redoStack.append(inverse)
        return inverse
    }

    /// Redoes the most recently undone action. Returns `[]` when there is
    /// nothing to redo.
    func redo() -> [Op] {
        guard let group = redoStack.popLast() else { return [] }
        let inverse = applyInverse(of: group)
        undoStack.append(inverse)
        return inverse
    }

    /// Records a freshly-applied local action onto the undo stack and clears the
    /// redo stack (standard editor semantics). Bounds the history size.
    private func recordLocalAction(_ ops: [Op]) {
        guard !ops.isEmpty else { return }
        undoStack.append(ops)
        redoStack.removeAll(keepingCapacity: true)
        if maxHistoryEntries > 0, undoStack.count > maxHistoryEntries {
            undoStack.removeFirst(undoStack.count - maxHistoryEntries)
        }
    }

    /// Builds and applies the inverse of an op-group against current state,
    /// returning the ops produced. Inserts invert to deletes; deletes invert to
    /// fresh inserts that resurrect the character at its current live-left
    /// neighbour, chaining consecutive resurrections so original order is
    /// preserved.
    private func applyInverse(of group: [Op]) -> [Op] {
        var produced: [Op] = []
        produced.reserveCapacity(group.count)

        for op in group {
            switch op.kind {
            case .insert:
                // Undo an insert -> tombstone the element.
                let del = Op.delete(id: op.id)
                integrate(del)
                produced.append(del)

            case .delete:
                // Undo a delete -> re-insert the character with a fresh id at
                // its current live-left neighbour. Skip if the target is gone.
                guard let idx = index[op.id] else { continue }
                let value = elements[idx].value
                let leftID = liveLeftNeighbour(beforeArrayIndex: idx)
                let ins = Op.insert(id: nextLocalID(), value: value, originLeft: leftID)
                integrate(ins)
                produced.append(ins)
            }
        }
        return produced
    }

    /// The id of the nearest live element to the left of `arrayIndex`, or `nil`
    /// if there is none (insert at head).
    private func liveLeftNeighbour(beforeArrayIndex arrayIndex: Int) -> ElementID? {
        var i = arrayIndex - 1
        while i >= 0 {
            if !elements[i].deleted { return elements[i].id }
            i -= 1
        }
        return nil
    }
}

// MARK: - Snapshot encode / decode (R4.1, R4.3)

extension CodeEditorDocument {

    /// Captures the full authoritative state for recovery: the complete ordered
    /// element list (including tombstones) plus the per-site sequence vector.
    func snapshot() -> Snapshot {
        Snapshot(elements: elements, seqVector: seqVector)
    }

    /// Merges a snapshot into the document idempotently. Unknown elements are
    /// integrated; elements already present are left in place (newer local
    /// elements survive); tombstones from the snapshot are applied (deletion is
    /// monotonic). Applying the same snapshot twice yields the same state as
    /// applying it once (Property 2).
    func applySnapshot(_ snapshot: Snapshot) {
        for element in snapshot.elements {
            if index[element.id] == nil {
                integrate(Op.insert(id: element.id, value: element.value, originLeft: element.originLeft))
            }
            if element.deleted {
                integrate(Op.delete(id: element.id))
            }
        }
        for (site, seq) in snapshot.seqVector {
            if (seqVector[site] ?? 0) < seq {
                seqVector[site] = seq
            }
        }
    }
}
