//
//  BoardDocument.swift
//  inter
//
//  The convergence core of the collaborative whiteboard: a LWW-Element-Map
//  (an OR-Map of `elementId -> element`) where every mutable property of an
//  element is an independent last-writer-wins register tagged with a
//  `(lamport, site)` stamp. This is the tldraw/Excalidraw-class CRDT for
//  board-like data and is the whiteboard sibling of the code editor's RGA — but
//  a DIFFERENT algorithm: a whiteboard is a *set of independently-addressable
//  objects*, not a character sequence, so concurrent edits to different
//  elements always commute and concurrent edits to the same property resolve
//  deterministically by stamp.
//
//  Like `CodeEditorDocument`, this is a pure, `@MainActor`, dependency-light
//  model: it depends only on Foundation + CoreGraphics (for `CGPoint`/`CGRect`)
//  and on the pure `WhiteboardColor` palette enum declared in `StrokeModel.swift`
//  (reused by reference, never redefined). It performs NO networking and holds
//  NO AppKit/SwiftUI references, which keeps it directly unit- and
//  property-testable. The transport (`InterWhiteboardController`), wire encoding
//  (`InterWhiteboardMessage`), and the native canvas surface are separate layers
//  that drive this model.
//
//  Why a LWW-Element-Map (see design.md "Document Model & Convergence"):
//  convergence is a *structural* guarantee — operations commute (different
//  elements / different properties) or resolve by a deterministic total order on
//  `(lamport, site)` (same property of the same element), and every operation is
//  idempotent (re-applying a stamp `<=` the stored stamp is a no-op). Two
//  replicas that have applied the same SET of operations in ANY order therefore
//  render an identical board (R2.2, R2.3). Deletes are tombstones that win over
//  concurrent updates ("delete-wins"), and z-order is a fractional-index LWW
//  register so concurrent reorders converge without renumbering the board.
//
//  Naming: every type here carries a `Board` prefix to avoid colliding with the
//  pure types already declared in `StrokeModel.swift` (`WhiteboardElement`,
//  `ShapeKind`, `WhiteboardTool`, `WhiteboardColor`). In particular this file
//  declares its OWN element-kind enum (`BoardElementKind`) because it needs an
//  `arrow` case that `ShapeKind` does not have.
//

import CoreGraphics
import Foundation

// MARK: - Scalar aliases

/// Globally-unique element identity: `"<attestedSite>:<counter>"`. The `site`
/// segment is the LiveKit-attested participant identity (never self-declared),
/// the counter is a per-site monotonic value — the pair is unique for the
/// session and stable across replicas.
typealias BoardElementID = String

/// Logical clock value. Max-merged on receipt so every replica's clock advances
/// past any stamp it has observed.
typealias BoardLamport = UInt64

// MARK: - LWW stamp

/// The version tag attached to every property write: a Lamport timestamp paired
/// with the originating attested site. `Comparable` provides the deterministic
/// total order used to resolve concurrent writes to the same property — higher
/// `lamport` wins, ties broken by `site`. `.zero` (lamport 0) sorts below every
/// real stamp (real stamps start at 1), so the first write to any property
/// always wins over its unset default.
struct BoardStamp: Comparable, Codable, Equatable {
    var lamport: BoardLamport
    var site: String

    static let zero = BoardStamp(lamport: 0, site: "")

    static func < (lhs: BoardStamp, rhs: BoardStamp) -> Bool {
        if lhs.lamport != rhs.lamport { return lhs.lamport < rhs.lamport }
        return lhs.site < rhs.site
    }
}

// MARK: - Element kind

/// The geometry/content kind of a board element. Declared here (rather than
/// reusing `ShapeKind`) precisely because the whiteboard needs an `arrow` case.
/// `String`-backed so it encodes compactly and stably in snapshots.
enum BoardElementKind: String, Codable, Equatable {
    case freehand
    case rectangle
    case ellipse
    case line
    case arrow
    case text
}

// MARK: - Per-property version tags

/// One LWW stamp per mutable property of an element. Per-property tags are what
/// make a concurrent "move" (touches `frame`) and "recolor" (touches
/// `strokeColor`) of the *same* element both survive — they write different
/// registers and never clobber one another (Property 3).
struct BoardVersionTags: Codable, Equatable {
    var present: BoardStamp = .zero
    var kind: BoardStamp = .zero
    var points: BoardStamp = .zero
    var frame: BoardStamp = .zero
    var rotation: BoardStamp = .zero
    var strokeColor: BoardStamp = .zero
    var strokeWidth: BoardStamp = .zero
    var text: BoardStamp = .zero
    var zKey: BoardStamp = .zero
    var groupId: BoardStamp = .zero
    var deleted: BoardStamp = .zero
}

// MARK: - Element

/// A single board element. All geometry is in shared WORLD space
/// (viewport-independent — R5.4). Mutable properties each carry their own stamp
/// in `v`; `present` marks that the element has been formally added (an element
/// merely *referenced* by an early-arriving update is materialised with
/// `present == false` and is not rendered until its add arrives), and `deleted`
/// is the tombstone flag (delete-wins). An element is rendered iff
/// `present && !deleted`.
struct BoardElement: Equatable {
    let id: BoardElementID
    var present: Bool
    var kind: BoardElementKind
    var points: [CGPoint]?
    var frame: CGRect?
    var rotation: CGFloat
    var strokeColor: WhiteboardColor
    var strokeWidth: CGFloat
    var text: String?
    var zKey: String
    var groupId: String?
    var deleted: Bool
    var v: BoardVersionTags

    /// `true` when the element should appear on the rendered board.
    var isRendered: Bool { present && !deleted }

    /// A bare placeholder used when an update/delete references an id whose
    /// `add` has not yet been integrated (causal materialisation). It is not
    /// rendered (`present == false`) and every stamp is `.zero`, so any real
    /// write wins.
    static func placeholder(id: BoardElementID) -> BoardElement {
        BoardElement(
            id: id,
            present: false,
            kind: .freehand,
            points: nil,
            frame: nil,
            rotation: 0,
            strokeColor: .white,
            strokeWidth: 1,
            text: nil,
            zKey: "",
            groupId: nil,
            deleted: false,
            v: BoardVersionTags()
        )
    }
}

// MARK: - Element Codable (snapshot encoding)

/// `WhiteboardColor` (declared in `StrokeModel.swift`) intentionally is NOT made
/// `Codable` here — adding a retroactive conformance to a shared type risks a
/// duplicate-conformance clash with a sibling file. Instead the color travels as
/// a small stable integer code, mapped locally.
private enum BoardColorCodec {
    static func code(_ c: WhiteboardColor) -> Int {
        switch c {
        case .white:  return 0
        case .red:    return 1
        case .orange: return 2
        case .yellow: return 3
        case .green:  return 4
        case .blue:   return 5
        case .purple: return 6
        case .black:  return 7
        }
    }

    static func color(_ i: Int) -> WhiteboardColor {
        switch i {
        case 1: return .red
        case 2: return .orange
        case 3: return .yellow
        case 4: return .green
        case 5: return .blue
        case 6: return .purple
        case 7: return .black
        default: return .white
        }
    }
}

extension BoardElement: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, present, kind, points, frame, rotation
        case color, strokeWidth, text, zKey, groupId, deleted, v
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(BoardElementID.self, forKey: .id)
        present = try c.decode(Bool.self, forKey: .present)
        kind = try c.decode(BoardElementKind.self, forKey: .kind)
        points = try c.decodeIfPresent([CGPoint].self, forKey: .points)
        frame = try c.decodeIfPresent(CGRect.self, forKey: .frame)
        rotation = try c.decode(CGFloat.self, forKey: .rotation)
        strokeColor = BoardColorCodec.color(try c.decode(Int.self, forKey: .color))
        strokeWidth = try c.decode(CGFloat.self, forKey: .strokeWidth)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        zKey = try c.decode(String.self, forKey: .zKey)
        groupId = try c.decodeIfPresent(String.self, forKey: .groupId)
        deleted = try c.decode(Bool.self, forKey: .deleted)
        v = try c.decode(BoardVersionTags.self, forKey: .v)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(present, forKey: .present)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(points, forKey: .points)
        try c.encodeIfPresent(frame, forKey: .frame)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(BoardColorCodec.code(strokeColor), forKey: .color)
        try c.encode(strokeWidth, forKey: .strokeWidth)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encode(zKey, forKey: .zKey)
        try c.encodeIfPresent(groupId, forKey: .groupId)
        try c.encode(deleted, forKey: .deleted)
        try c.encode(v, forKey: .v)
    }
}

// MARK: - Property writes & operations

/// A single property write carried inside an operation. Each value names the
/// register it targets; the operation's stamp is applied to whichever registers
/// its patch touches. (`groupId` and `text` carry an optional payload so they
/// can be set OR cleared, both as LWW writes.)
enum BoardPropertyValue: Equatable {
    case present(Bool)
    case kind(BoardElementKind)
    case points([CGPoint])
    case frame(CGRect)
    case rotation(CGFloat)
    case strokeColor(WhiteboardColor)
    case strokeWidth(CGFloat)
    case text(String?)
    case zKey(String)
    case groupId(String?)
    case deleted(Bool)
}

/// The high-level shape of an operation. Purely informational for history and
/// for the wire layer (`InterWhiteboardMessage`, a separate file); integration
/// is uniform regardless of kind.
enum BoardOpKind: Equatable {
    case add
    case update
    case delete
}

/// A replicated board operation: "apply this `patch` of property writes to
/// element `id` at logical time `stamp`". Adds assert the full element state
/// (including `present` and `deleted`), updates carry a subset, deletes carry
/// `deleted = true`. Every op is idempotent and commutes/resolves by stamp.
struct BoardOp: Equatable {
    let kind: BoardOpKind
    let id: BoardElementID
    let stamp: BoardStamp
    let patch: [BoardPropertyValue]

    /// Builds the full-state assertion patch for an element. Used for both fresh
    /// adds and for undo/redo "restore" ops (which re-assert a prior element
    /// state — including its `deleted` flag — at a new higher stamp).
    static func add(element: BoardElement, stamp: BoardStamp) -> BoardOp {
        var patch: [BoardPropertyValue] = [
            .present(true),
            .kind(element.kind),
            .rotation(element.rotation),
            .strokeColor(element.strokeColor),
            .strokeWidth(element.strokeWidth),
            .text(element.text),
            .zKey(element.zKey),
            .groupId(element.groupId),
            .deleted(element.deleted)
        ]
        if let p = element.points { patch.append(.points(p)) }
        if let f = element.frame { patch.append(.frame(f)) }
        return BoardOp(kind: .add, id: element.id, stamp: stamp, patch: patch)
    }

    static func update(id: BoardElementID, patch: [BoardPropertyValue], stamp: BoardStamp) -> BoardOp {
        BoardOp(kind: .update, id: id, stamp: stamp, patch: patch)
    }

    static func delete(id: BoardElementID, stamp: BoardStamp) -> BoardOp {
        BoardOp(kind: .delete, id: id, stamp: stamp, patch: [.deleted(true)])
    }
}

// MARK: - Snapshot

/// A full authoritative board for late-join / reconnect recovery (R6.1, R6.3):
/// the complete element list (including tombstones and their per-property
/// stamps) plus the current Lamport clock. `applySnapshot` merges it idempotently
/// — each property keeps the writer with the higher stamp — so applying a
/// snapshot twice, or overlapping it with live ops, converges (Property 2).
struct BoardSnapshot: Codable, Equatable {
    let elements: [BoardElement]
    let lamport: BoardLamport
}

// MARK: - Document

/// The LWW-Element-Map document model. Owned for the whole session by the
/// whiteboard bridge. Pure, `@MainActor`, no networking.
@MainActor
final class BoardDocument {

    // MARK: Configuration

    /// The local participant's attested identity, stamped into every locally
    /// generated `BoardElementID` and every local write's `BoardStamp.site`.
    let site: String

    /// Hard cap on the number of LIVE (rendered) elements. Local additions past
    /// this cap are refused (R8.3); REMOTE ops are ALWAYS applied so convergence
    /// is never sacrificed for the cap.
    let maxElements: Int

    /// Hard cap on the number of points retained in a single freehand stroke.
    /// Local point streams are clamped to this; remote strokes are applied as
    /// received.
    let maxStrokePoints: Int

    /// Upper bound on retained undo/redo history entries (R9.3).
    private let maxHistoryEntries: Int

    // MARK: Storage

    /// `id -> element`, including tombstones and not-yet-present placeholders.
    private(set) var elements: [BoardElementID: BoardElement] = [:]

    /// Count of rendered (`present && !deleted`) elements, maintained
    /// incrementally so the cap check is O(1).
    private(set) var liveCount: Int = 0

    /// Logical clock; advanced by local writes and max-merged on every observed
    /// remote stamp.
    private(set) var lamport: BoardLamport = 0

    /// Per-site monotonic counter for minting fresh local element ids.
    private var elementCounter: UInt64 = 0

    // MARK: Undo / redo

    /// A history entry: the prior full state of every element a local action
    /// touched (`nil` value == the element did not exist before the action).
    /// Undo restores each id to its captured prior state via fresh LWW writes,
    /// so it converges on the peer and only ever touches the action's own
    /// elements (never the remote participant's concurrent edits to *other*
    /// elements — R9.2).
    private typealias BoardReversal = [BoardElementID: BoardElement?]

    private var undoStack: [BoardReversal] = []
    private var redoStack: [BoardReversal] = []

    // MARK: Flags

    /// Set `true` when the most recent LOCAL addition was refused for exceeding
    /// `maxElements`. The UI surfaces a non-blocking notice from this (R8.3).
    private(set) var didHitElementCap: Bool = false

    /// Set `true` when a local freehand stroke's points were clamped to
    /// `maxStrokePoints`.
    private(set) var didHitPointCap: Bool = false

    // MARK: Init

    init(site: String,
         maxElements: Int = 5_000,
         maxStrokePoints: Int = 10_000,
         maxHistoryEntries: Int = 200) {
        self.site = site
        self.maxElements = max(0, maxElements)
        self.maxStrokePoints = max(1, maxStrokePoints)
        self.maxHistoryEntries = max(0, maxHistoryEntries)
    }

    /// Clears the cap flags (e.g. once the user has dismissed the notice or
    /// removed elements).
    func clearCapFlags() {
        didHitElementCap = false
        didHitPointCap = false
    }

    /// `true` when the document holds no elements at all (not even tombstones) —
    /// the controller uses this to decide whether a freshly-mounted/reconnected
    /// replica should request an authoritative snapshot (R6.1, R6.2).
    var isEmpty: Bool { elements.isEmpty }

    /// The element with `id`, if known (may be a tombstone or placeholder).
    func element(id: BoardElementID) -> BoardElement? { elements[id] }
}

// MARK: - Rendered order (R1.5 / R2.6)

extension BoardDocument {

    /// The visible board: non-deleted elements sorted back-to-front by `zKey`,
    /// with `id` as a deterministic tie-break (two elements can momentarily
    /// share a `zKey` after concurrent "send to front"). The canvas draws this
    /// list in order.
    var renderedElements: [BoardElement] {
        elements.values
            .filter { $0.isRendered }
            .sorted { lhs, rhs in
                if lhs.zKey != rhs.zKey { return lhs.zKey < rhs.zKey }
                return lhs.id < rhs.id
            }
    }
}

// MARK: - Local mutations (R2.1)

extension BoardDocument {

    /// Adds a new element of `kind`, returning the op(s) to publish. Refuses
    /// (returns `[]`, sets `didHitElementCap`) when the board is already at
    /// `maxElements` (R8.3). Freehand point streams are clamped to
    /// `maxStrokePoints` (setting `didHitPointCap`). The new element is placed at
    /// the front via a fractional `zKey` greater than the current top.
    func addElement(kind: BoardElementKind,
                    points: [CGPoint]? = nil,
                    frame: CGRect? = nil,
                    rotation: CGFloat = 0,
                    strokeColor: WhiteboardColor,
                    strokeWidth: CGFloat,
                    text: String? = nil,
                    groupId: String? = nil) -> [BoardOp] {
        didHitElementCap = false
        didHitPointCap = false

        guard liveCount < maxElements else {
            didHitElementCap = true
            return []
        }

        var clampedPoints = points
        if let p = points, p.count > maxStrokePoints {
            clampedPoints = Array(p.prefix(maxStrokePoints))
            didHitPointCap = true
        }

        let stamp = nextStamp()
        let id = nextElementID()
        let zKey = BoardFractionalIndex.keyBetween(currentTopZKey(), nil)
        let element = BoardElement(
            id: id,
            present: true,
            kind: kind,
            points: clampedPoints,
            frame: frame,
            rotation: rotation,
            strokeColor: strokeColor,
            strokeWidth: strokeWidth,
            text: text,
            zKey: zKey,
            groupId: groupId,
            deleted: false,
            v: BoardVersionTags()
        )
        return applyLocalGroup([BoardOp.add(element: element, stamp: stamp)])
    }

    /// Applies a property update to an existing element, returning the op(s) to
    /// publish. Freehand `points` are clamped to `maxStrokePoints`. A no-op
    /// (returns `[]`) when the id is unknown / not rendered or the patch is
    /// empty.
    func updateElement(_ id: BoardElementID, _ patch: [BoardPropertyValue]) -> [BoardOp] {
        didHitPointCap = false
        guard let existing = elements[id], existing.isRendered, !patch.isEmpty else { return [] }

        let clamped: [BoardPropertyValue] = patch.map { value in
            if case .points(let p) = value, p.count > maxStrokePoints {
                didHitPointCap = true
                return .points(Array(p.prefix(maxStrokePoints)))
            }
            return value
        }
        let stamp = nextStamp()
        return applyLocalGroup([BoardOp.update(id: id, patch: clamped, stamp: stamp)])
    }

    /// Deletes an element (tombstone), returning the op to publish. A no-op when
    /// the id is unknown or already not rendered.
    func deleteElement(_ id: BoardElementID) -> [BoardOp] {
        guard let existing = elements[id], existing.isRendered else { return [] }
        let stamp = nextStamp()
        return applyLocalGroup([BoardOp.delete(id: id, stamp: stamp)])
    }

    /// Mints the next monotonic local element id, keeping the counter ahead of
    /// anything observed so a reconnect/snapshot merge cannot collide with a
    /// fresh local id.
    private func nextElementID() -> BoardElementID {
        elementCounter += 1
        return "\(site):\(elementCounter)"
    }
}

// MARK: - Z-order (R3.9)

extension BoardDocument {

    /// Moves `id` to the front (topmost) by giving it a `zKey` greater than the
    /// current top.
    func bringToFront(_ id: BoardElementID) -> [BoardOp] {
        let rendered = renderedElements
        guard let el = elements[id], el.isRendered, let top = rendered.last, top.id != id else { return [] }
        return updateZKey(id, BoardFractionalIndex.keyBetween(top.zKey, nil))
    }

    /// Moves `id` to the back (bottommost) by giving it a `zKey` less than the
    /// current bottom.
    func sendToBack(_ id: BoardElementID) -> [BoardOp] {
        let rendered = renderedElements
        guard let el = elements[id], el.isRendered, let bottom = rendered.first, bottom.id != id else { return [] }
        return updateZKey(id, BoardFractionalIndex.keyBetween(nil, bottom.zKey))
    }

    /// Moves `id` up one step, placing it just above its current upper neighbour.
    func bringForward(_ id: BoardElementID) -> [BoardOp] {
        let rendered = renderedElements
        guard let i = rendered.firstIndex(where: { $0.id == id }), i < rendered.count - 1 else { return [] }
        let next = rendered[i + 1]
        let afterNext: String? = (i + 2 < rendered.count) ? rendered[i + 2].zKey : nil
        return updateZKey(id, BoardFractionalIndex.keyBetween(next.zKey, afterNext))
    }

    /// Moves `id` down one step, placing it just below its current lower
    /// neighbour.
    func sendBackward(_ id: BoardElementID) -> [BoardOp] {
        let rendered = renderedElements
        guard let i = rendered.firstIndex(where: { $0.id == id }), i > 0 else { return [] }
        let prev = rendered[i - 1]
        let beforePrev: String? = (i - 2 >= 0) ? rendered[i - 2].zKey : nil
        return updateZKey(id, BoardFractionalIndex.keyBetween(beforePrev, prev.zKey))
    }

    private func updateZKey(_ id: BoardElementID, _ newKey: String) -> [BoardOp] {
        let stamp = nextStamp()
        return applyLocalGroup([BoardOp.update(id: id, patch: [.zKey(newKey)], stamp: stamp)])
    }

    /// The largest `zKey` among present elements, or `nil` for an empty board.
    private func currentTopZKey() -> String? {
        elements.values.filter { $0.present }.map { $0.zKey }.max()
    }
}

// MARK: - Group / ungroup (R3.8)

extension BoardDocument {

    /// Assigns a fresh shared `groupId` to every given rendered element (one op
    /// per member — R3.10), returning all ops as a single undoable action.
    func group(_ ids: [BoardElementID]) -> [BoardOp] {
        let members = ids.filter { elements[$0]?.isRendered == true }
        guard members.count >= 2 else { return [] }
        let gid = "g:\(UUID().uuidString)"
        let ops = members.map { id -> BoardOp in
            BoardOp.update(id: id, patch: [.groupId(gid)], stamp: nextStamp())
        }
        return applyLocalGroup(ops)
    }

    /// Clears the `groupId` of every given rendered element, returning all ops as
    /// a single undoable action.
    func ungroup(_ ids: [BoardElementID]) -> [BoardOp] {
        let members = ids.filter { elements[$0]?.isRendered == true && elements[$0]?.groupId != nil }
        guard !members.isEmpty else { return [] }
        let ops = members.map { id -> BoardOp in
            BoardOp.update(id: id, patch: [.groupId(nil)], stamp: nextStamp())
        }
        return applyLocalGroup(ops)
    }
}

// MARK: - Integration of ops (local or remote) (R2.2, R2.3)

extension BoardDocument {

    /// Integrates a remotely-received op. Identical resolution to a local op,
    /// minus history recording: each property write wins iff the op's stamp is
    /// strictly greater than the stored stamp for that property, so the op is
    /// idempotent (re-delivery is a no-op) and commutes with concurrent ops to
    /// other elements/properties. The local clock max-merges the op's stamp.
    func integrate(_ op: BoardOp) {
        observe(op.stamp.lamport)

        var el = elements[op.id] ?? BoardElement.placeholder(id: op.id)
        let wasRendered = (elements[op.id]?.isRendered) ?? false

        var changed = false
        for value in op.patch {
            if applyWrite(value, to: &el, stamp: op.stamp) { changed = true }
        }

        if changed || elements[op.id] == nil {
            elements[op.id] = el
            updateLiveCount(wasRendered: wasRendered, isRendered: el.isRendered)
        }
    }

    /// Applies a single property write under LWW, returning `true` if it changed
    /// the element. A write wins only when its stamp strictly exceeds the stored
    /// stamp for that exact property — this is the per-property
    /// last-writer-wins rule and the source of idempotency.
    private func applyWrite(_ value: BoardPropertyValue, to el: inout BoardElement, stamp: BoardStamp) -> Bool {
        switch value {
        case .present(let b):
            guard stamp > el.v.present else { return false }
            el.present = b; el.v.present = stamp; return true
        case .kind(let k):
            guard stamp > el.v.kind else { return false }
            el.kind = k; el.v.kind = stamp; return true
        case .points(let p):
            guard stamp > el.v.points else { return false }
            el.points = p; el.v.points = stamp; return true
        case .frame(let f):
            guard stamp > el.v.frame else { return false }
            el.frame = f; el.v.frame = stamp; return true
        case .rotation(let r):
            guard stamp > el.v.rotation else { return false }
            el.rotation = r; el.v.rotation = stamp; return true
        case .strokeColor(let c):
            guard stamp > el.v.strokeColor else { return false }
            el.strokeColor = c; el.v.strokeColor = stamp; return true
        case .strokeWidth(let w):
            guard stamp > el.v.strokeWidth else { return false }
            el.strokeWidth = w; el.v.strokeWidth = stamp; return true
        case .text(let t):
            guard stamp > el.v.text else { return false }
            el.text = t; el.v.text = stamp; return true
        case .zKey(let z):
            guard stamp > el.v.zKey else { return false }
            el.zKey = z; el.v.zKey = stamp; return true
        case .groupId(let g):
            guard stamp > el.v.groupId else { return false }
            el.groupId = g; el.v.groupId = stamp; return true
        case .deleted(let d):
            guard stamp > el.v.deleted else { return false }
            el.deleted = d; el.v.deleted = stamp; return true
        }
    }

    private func updateLiveCount(wasRendered: Bool, isRendered: Bool) {
        if !wasRendered && isRendered { liveCount += 1 }
        else if wasRendered && !isRendered { liveCount -= 1 }
    }

    /// Mints the next local stamp at the next clock tick.
    private func nextStamp() -> BoardStamp {
        lamport += 1
        return BoardStamp(lamport: lamport, site: site)
    }

    /// Max-merges an observed Lamport value into the local clock.
    private func observe(_ value: BoardLamport) {
        if value > lamport { lamport = value }
    }
}

// MARK: - Local apply + undo/redo (R9.1, R9.2, R9.3)

extension BoardDocument {

    /// Integrates a single locally-generated op and records it for undo. Thin
    /// wrapper over `applyLocalGroup` for callers that hold a pre-stamped op.
    func applyLocal(_ op: BoardOp) -> [BoardOp] {
        applyLocalGroup([op])
    }

    /// Integrates a group of locally-generated ops as one atomic, undoable
    /// action: captures the prior state of every touched element, integrates the
    /// ops, then pushes a single reversal entry. Returns the ops to publish.
    private func applyLocalGroup(_ ops: [BoardOp]) -> [BoardOp] {
        guard !ops.isEmpty else { return [] }
        let before = captureBefore(ids: ops.map { $0.id })
        for op in ops { integrate(op) }
        recordReversal(before)
        return ops
    }

    /// Undoes the most recent local action, emitting inverse LWW ops (re-add a
    /// deleted element / restore a prior property value) with NEW higher stamps
    /// so the peer converges (R9.1) and remote concurrent edits to OTHER elements
    /// are never reverted (R9.2). Returns `[]` when there is nothing to undo.
    func undo() -> [BoardOp] {
        guard let before = undoStack.popLast() else { return [] }
        let redoSnapshot = captureBefore(ids: Array(before.keys))
        let ops = restore(to: before)
        redoStack.append(redoSnapshot)
        return ops
    }

    /// Redoes the most recently undone action. Returns `[]` when there is nothing
    /// to redo.
    func redo() -> [BoardOp] {
        guard let before = redoStack.popLast() else { return [] }
        let undoSnapshot = captureBefore(ids: Array(before.keys))
        let ops = restore(to: before)
        undoStack.append(undoSnapshot)
        return ops
    }

    /// Snapshots the current state of the given ids (`nil` value when an id does
    /// not yet exist), de-duplicating ids.
    private func captureBefore(ids: [BoardElementID]) -> BoardReversal {
        var result: BoardReversal = [:]
        for id in ids where result[id] == nil {
            result[id] = elements[id]
        }
        return result
    }

    /// Drives every captured id back to its prior state via fresh-stamped ops:
    /// a prior rendered element is re-asserted in full (un-deleting it if it was
    /// since tombstoned); a prior-absent / prior-not-present id is tombstoned.
    private func restore(to before: BoardReversal) -> [BoardOp] {
        var produced: [BoardOp] = []
        for (id, prior) in before {
            let stamp = nextStamp()
            if let prior = prior, prior.present {
                let op = BoardOp.add(element: prior, stamp: stamp)
                integrate(op)
                produced.append(op)
            } else {
                // Prior state was absent / not-yet-present: ensure it is gone.
                guard elements[id]?.isRendered == true else { continue }
                let op = BoardOp.delete(id: id, stamp: stamp)
                integrate(op)
                produced.append(op)
            }
        }
        return produced
    }

    /// Pushes a reversal entry onto the undo stack, clears the redo stack
    /// (standard editor semantics), and bounds the history size (R9.3).
    private func recordReversal(_ before: BoardReversal) {
        guard !before.isEmpty else { return }
        undoStack.append(before)
        redoStack.removeAll(keepingCapacity: true)
        if maxHistoryEntries > 0, undoStack.count > maxHistoryEntries {
            undoStack.removeFirst(undoStack.count - maxHistoryEntries)
        }
    }
}

// MARK: - Clear (R9.4)

extension BoardDocument {

    /// Removes every rendered element via convergent delete ops (so the peer's
    /// board clears too) and resets the local undo/redo history. Returns the
    /// delete ops to publish.
    func clear() -> [BoardOp] {
        let targets = renderedElements.map { $0.id }
        var ops: [BoardOp] = []
        ops.reserveCapacity(targets.count)
        for id in targets {
            let op = BoardOp.delete(id: id, stamp: nextStamp())
            integrate(op)
            ops.append(op)
        }
        undoStack.removeAll(keepingCapacity: true)
        redoStack.removeAll(keepingCapacity: true)
        return ops
    }
}

// MARK: - Snapshot encode / decode (R6.1, R6.3)

extension BoardDocument {

    /// Captures the full authoritative board for recovery: every element
    /// (including tombstones and their per-property stamps) plus the current
    /// Lamport clock.
    func snapshot() -> BoardSnapshot {
        BoardSnapshot(elements: Array(elements.values), lamport: lamport)
    }

    /// Merges a snapshot idempotently, resolving each property by its own stamp
    /// so the newer writer survives. Applying the same snapshot twice — or
    /// overlapping it with live ops — yields the same state as applying it once
    /// (Property 2). The local clock advances past the snapshot's clock and every
    /// merged stamp.
    func applySnapshot(_ snapshot: BoardSnapshot) {
        for incoming in snapshot.elements {
            mergeElement(incoming)
        }
        observe(snapshot.lamport)
    }

    /// Per-property LWW merge of a whole element (used by snapshot apply). Unlike
    /// `integrate(op)` — which stamps every touched property with one op stamp —
    /// this respects each incoming property's individual stamp, so an element
    /// whose properties were last written at different logical times merges
    /// correctly.
    private func mergeElement(_ incoming: BoardElement) {
        var el = elements[incoming.id] ?? BoardElement.placeholder(id: incoming.id)
        let wasRendered = (elements[incoming.id]?.isRendered) ?? false
        var changed = elements[incoming.id] == nil

        func merge<T>(_ keyPath: WritableKeyPath<BoardElement, T>,
                      _ stampPath: WritableKeyPath<BoardVersionTags, BoardStamp>,
                      _ incomingValue: T) {
            let incomingStamp = incoming.v[keyPath: stampPath]
            observe(incomingStamp.lamport)
            if incomingStamp > el.v[keyPath: stampPath] {
                el[keyPath: keyPath] = incomingValue
                el.v[keyPath: stampPath] = incomingStamp
                changed = true
            }
        }

        merge(\.present, \.present, incoming.present)
        merge(\.kind, \.kind, incoming.kind)
        merge(\.points, \.points, incoming.points)
        merge(\.frame, \.frame, incoming.frame)
        merge(\.rotation, \.rotation, incoming.rotation)
        merge(\.strokeColor, \.strokeColor, incoming.strokeColor)
        merge(\.strokeWidth, \.strokeWidth, incoming.strokeWidth)
        merge(\.text, \.text, incoming.text)
        merge(\.zKey, \.zKey, incoming.zKey)
        merge(\.groupId, \.groupId, incoming.groupId)
        merge(\.deleted, \.deleted, incoming.deleted)

        if changed {
            elements[incoming.id] = el
            updateLiveCount(wasRendered: wasRendered, isRendered: el.isRendered)
        }
    }
}

// MARK: - Fractional indexing for z-order

/// A dependency-free fractional-indexing helper. A `zKey` is a
/// lexicographically-sortable ORDER KEY in the style of David Greenspan's
/// fractional-indexing design (rocicorp/fractional-indexing, CC0): an integer
/// part whose FIRST character is a length HEADER (`a`…`z` for widths 2…27, and
/// `A`…`Z` for the negative range) followed by base-62 magnitude digits, plus an
/// optional free-form fractional tail. `keyBetween` returns a key STRICTLY
/// between its (optional) bounds, so a new or reordered element can always be
/// slotted between two neighbours without renumbering the board — and because
/// the resulting `zKey` is an LWW string register compared LEXICOGRAPHICALLY,
/// concurrent reorders converge (Property 5).
///
/// CRITICAL — bounded key length: APPENDING (the `keyBetween(top, nil)` path
/// used by every `addElement` / bring-to-front) INCREMENTS the fixed-width
/// integer and only lengthens the key when that integer OVERFLOWS, so N
/// sequential adds produce O(log N)-length keys (≈3–4 chars for thousands of
/// elements). The previous "append a mid digit" scheme grew keys O(N), so past
/// ~256 sequential adds a key breached `WhiteboardWireElement`'s `zKey.count
/// <= 256` cap and the add op was SILENTLY DROPPED at wire conversion — a peer
/// never saw those elements (permanent divergence). Short keys keep every add
/// well under the wire cap.
///
/// Ported from the canonical CC0 implementation (no rights reserved); see
/// https://github.com/rocicorp/fractional-indexing and the referenced
/// "Implementing Fractional Indexing" write-up. Made FAIL-SAFE here (never
/// throws — a live drawing tool must not crash on a degenerate reorder): on any
/// precondition violation that valid board state never produces, it falls back
/// to a still-ordered key.
enum BoardFractionalIndex {

    /// Ordered base-62 alphabet (`0-9A-Za-z`) in strict ASCII-ascending order so
    /// lexicographic string comparison matches digit/magnitude comparison.
    private static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    /// The smallest representable integer part (`A` + 26 zeros); reserved/invalid
    /// as a whole order key, matching the canonical algorithm.
    private static var smallestInteger: String { "A" + String(repeating: digits[0], count: 26) }

    /// Returns a key STRICTLY between `lo` and `hi`. `nil` `lo` means "no lower
    /// bound" (smaller than everything), `nil` `hi` means "no upper bound"
    /// (larger than everything — the APPEND path). When both are `nil`, returns
    /// the first key (`"a0"`). FAIL-SAFE: never throws.
    static func keyBetween(_ lo: String?, _ hi: String?) -> String {
        if let key = generate(lo, hi) { return key }
        // Unreachable for valid board state (bounds are always well-formed,
        // in-order order keys). Fall back to a still-ordered, valid key rather
        // than crash: greater than `lo` when present, else a low key < `hi`.
        if let lo = lo { return lo + String(digits[digits.count / 2]) }
        if hi != nil { return smallestInteger + String(digits[digits.count / 2]) }
        return "a" + String(digits[0])
    }

    // MARK: Canonical generator (fail-safe: `nil` instead of throwing)

    private static func generate(_ a: String?, _ b: String?) -> String? {
        if let a = a, !isValidOrderKey(a) { return nil }
        if let b = b, !isValidOrderKey(b) { return nil }
        if let a = a, let b = b, a >= b { return nil }

        guard let a = a else {
            // No lower bound (prepend / first key).
            guard let b = b else { return "a" + String(digits[0]) }
            guard let ib = integerPart(b) else { return nil }
            let fb = String(b.dropFirst(ib.count))
            if ib == smallestInteger {
                guard let mid = midpoint("", fb) else { return nil }
                return ib + mid
            }
            if ib < b { return ib }
            return decrementInteger(ib)
        }

        guard let b = b else {
            // No upper bound — the APPEND path (bounded growth lives here).
            guard let ia = integerPart(a) else { return nil }
            let fa = String(a.dropFirst(ia.count))
            if let incremented = incrementInteger(ia) { return incremented }
            guard let mid = midpoint(fa, nil) else { return nil }
            return ia + mid
        }

        // Strictly between two keys.
        guard let ia = integerPart(a), let ib = integerPart(b) else { return nil }
        let fa = String(a.dropFirst(ia.count))
        let fb = String(b.dropFirst(ib.count))
        if ia == ib {
            guard let mid = midpoint(fa, fb) else { return nil }
            return ia + mid
        }
        guard let incremented = incrementInteger(ia) else { return nil }
        if incremented < b { return incremented }
        guard let mid = midpoint(fa, nil) else { return nil }
        return ia + mid
    }

    // MARK: Integer-part helpers

    private static func digitIndex(_ c: Character) -> Int? { digits.firstIndex(of: c) }

    /// The integer-part LENGTH implied by a header char (`a`…`z` → 2…27,
    /// `A`…`Z` → 27…2); `nil` for a non-header first char.
    private static func integerLength(_ head: Character) -> Int? {
        guard let h = head.asciiValue else { return nil }
        let a = Character("a").asciiValue!, z = Character("z").asciiValue!
        let A = Character("A").asciiValue!, Z = Character("Z").asciiValue!
        if h >= a && h <= z { return Int(h - a) + 2 }
        if h >= A && h <= Z { return Int(Z - h) + 2 }
        return nil
    }

    private static func integerPart(_ key: String) -> String? {
        guard let head = key.first, let len = integerLength(head), len <= key.count else { return nil }
        return String(key.prefix(len))
    }

    /// A whole order key is valid when its integer part is well-formed and its
    /// fractional tail has no trailing zero (the canonical invariant). The
    /// reserved `smallestInteger` is not a valid standalone key.
    private static func isValidOrderKey(_ key: String) -> Bool {
        if key == smallestInteger { return false }
        guard let i = integerPart(key) else { return false }
        let f = key.dropFirst(i.count)
        if f.last == digits[0] { return false }
        return true
    }

    /// Next integer after `x` (same scheme). `nil` on overflow (`x` is the
    /// largest integer) or a malformed input.
    private static func incrementInteger(_ x: String) -> String? {
        guard let head = x.first, let len = integerLength(head), len == x.count else { return nil }
        var digs = Array(x.dropFirst())
        var carry = true
        var i = digs.count - 1
        while carry && i >= 0 {
            guard let d0 = digitIndex(digs[i]) else { return nil }
            let d = d0 + 1
            if d == digits.count { digs[i] = digits[0] } else { digs[i] = digits[d]; carry = false }
            i -= 1
        }
        if carry {
            if head == "Z" { return "a" + String(digits[0]) }
            if head == "z" { return nil }
            let h = Character(UnicodeScalar(head.asciiValue! + 1))
            if h > "a" { digs.append(digits[0]) } else { digs.removeLast() }
            return String(h) + String(digs)
        }
        return String(head) + String(digs)
    }

    /// Previous integer before `x`. `nil` on underflow or a malformed input.
    private static func decrementInteger(_ x: String) -> String? {
        guard let head = x.first, let len = integerLength(head), len == x.count else { return nil }
        var digs = Array(x.dropFirst())
        var borrow = true
        var i = digs.count - 1
        while borrow && i >= 0 {
            guard let d0 = digitIndex(digs[i]) else { return nil }
            let d = d0 - 1
            if d == -1 { digs[i] = digits[digits.count - 1] } else { digs[i] = digits[d]; borrow = false }
            i -= 1
        }
        if borrow {
            if head == "a" { return "Z" + String(digits[digits.count - 1]) }
            if head == "A" { return nil }
            let h = Character(UnicodeScalar(head.asciiValue! - 1))
            if h < "Z" { digs.append(digits[digits.count - 1]) } else { digs.removeLast() }
            return String(h) + String(digs)
        }
        return String(head) + String(digs)
    }

    /// A fractional string strictly between `a` and `b` (the fractional tails;
    /// `a` may be empty = smallest, `b` may be `nil` = largest). `nil` on a
    /// precondition violation (`a >= b` or a trailing-zero input).
    private static func midpoint(_ a: String, _ b: String?) -> String? {
        let zero = digits[0]
        if let b = b, a >= b { return nil }
        if a.last == zero { return nil }
        if let b = b, b.last == zero { return nil }

        if let b = b {
            // Strip the longest common prefix (padding `a` with zeros), then
            // recurse on the remainder.
            let aChars = Array(a), bChars = Array(b)
            var n = 0
            while n < bChars.count {
                let ac = n < aChars.count ? aChars[n] : zero
                if ac == bChars[n] { n += 1 } else { break }
            }
            if n > 0 {
                let bPrefix = String(bChars[0..<n])
                let aRest = String(aChars[min(n, aChars.count)...])
                let bRest = String(bChars[n...])
                guard let mid = midpoint(aRest, bRest) else { return nil }
                return bPrefix + mid
            }
        }

        let digitA = a.isEmpty ? 0 : (digitIndex(Array(a)[0]) ?? 0)
        let digitB: Int
        if let b = b, let first = b.first { digitB = digitIndex(first) ?? digits.count } else { digitB = digits.count }

        if digitB - digitA > 1 {
            let midDigit = Int((0.5 * Double(digitA + digitB)).rounded())
            return String(digits[midDigit])
        }
        // Consecutive first digits.
        if let b = b, b.count > 1 {
            return String(b.prefix(1))
        }
        let aRest = a.isEmpty ? "" : String(Array(a)[1...])
        guard let mid = midpoint(aRest, nil) else { return nil }
        return String(digits[digitA]) + mid
    }
}
