//
//  SelectionTransformController.swift
//  inter
//
//  The pure selection + transform geometry layer of the collaborative
//  whiteboard. It is the sibling of `BoardDocument` (the convergence core) and
//  mirrors how the collaborative code editor kept its transform/geometry logic
//  in a pure, dependency-light, directly-testable type: this controller holds
//  ONLY local selection state and computes geometry. It performs NO networking
//  and defines NO wire types — it drives `BoardDocument`'s mutators (which mint
//  the LWW `(lamport, site)` stamps) and forwards the `BoardOp`s those mutators
//  produce back to the caller for publishing.
//
//  Layering decision (per design.md "Components and Interfaces"):
//  ──────────────────────────────────────────────────────────────────────────
//  • The *math* is split out into a pure, value-only namespace
//    (`SelectionGeometry` + `BoardTransform`) that knows nothing about the
//    document or the main actor. This is the natural property-test target for
//    Property 6 (transform inverse) — tests can transform a `BoardElement`
//    and its inverse with no `BoardDocument` at all.
//  • The *controller* (`SelectionTransformController`) owns the selection set
//    and, for every mutating operation, calls `BoardDocument.updateElement(…)`
//    / `deleteElement(…)` / `group(…)` / `bringToFront(…)` etc. We deliberately
//    let the DOCUMENT mint stamps (rather than returning bare patches) so the
//    Lamport clock has a single owner and so a multi-element selection emits
//    exactly one `BoardOp` per affected member (R3.10) with no stamp bookkeeping
//    duplicated here.
//
//  Transform order — LOCKED to translate → rotate → scale:
//  ──────────────────────────────────────────────────────────────────────────
//  A composite gesture is expressed as an ordered list of `BoardTransform`
//  steps and is always built/applied in the order move (translate) → rotate →
//  scale. The inverse of a step list is the reversed list of per-step inverses,
//  which is what makes "transform then inverse restores the original geometry
//  within float tolerance" hold (Property 6). Each individual step is itself
//  exactly invertible:
//    • move(dx,dy)             ↔ move(-dx,-dy)
//    • rotate(θ, about: P)     ↔ rotate(-θ, about: P)
//    • scale(sx,sy, anchor: A) ↔ scale(1/sx, 1/sy, anchor: A)   (sx,sy ≠ 0)
//
//  Rotated-group resize (the trickiest case the design flags): the element
//  model can represent only `frame` (an axis-aligned box) + `rotation`, never a
//  sheared parallelogram. A non-uniform world-space scale of an already-rotated
//  member is therefore inherently un-representable WITHOUT shear. We resolve
//  this by keeping every step independently invertible: a `scale` step moves a
//  frame member's CENTRE through the true world-space scale (so it tracks the
//  bounding-box change) while scaling the member's own width/height by the same
//  factors and leaving its rotation untouched. This is a documented, deliberate
//  approximation of the forward resize for rotated members, chosen precisely so
//  that the inverse (1/sx, 1/sy about the same anchor) restores the member
//  exactly — inverseability is the invariant we must not break.
//

import CoreGraphics
import Foundation

// MARK: - Transform model

/// One atomic, exactly-invertible geometric step applied to board geometry.
///
/// A gesture is modelled as an ordered list of these, always assembled in the
/// LOCKED order translate → rotate → scale. The list's `inverse` is the reversed
/// list of per-step inverses, so applying a list and then its inverse restores
/// the original geometry within floating-point tolerance (Property 6).
enum BoardTransform: Equatable {

    /// Translate by `(dx, dy)` in world space.
    case move(dx: CGFloat, dy: CGFloat)

    /// Rotate by `angle` radians about world-space pivot `about`.
    case rotate(angle: CGFloat, about: CGPoint)

    /// Scale by `(sx, sy)` about the fixed world-space `anchor` (the handle
    /// opposite the one being dragged). `sx`/`sy` must be non-zero to remain
    /// invertible.
    case scale(sx: CGFloat, sy: CGFloat, anchor: CGPoint)

    /// The exact inverse of this single step.
    var inverse: BoardTransform {
        switch self {
        case .move(let dx, let dy):
            return .move(dx: -dx, dy: -dy)
        case .rotate(let angle, let about):
            return .rotate(angle: -angle, about: about)
        case .scale(let sx, let sy, let anchor):
            // Guard against a degenerate (zero) factor: a zero scale is not
            // invertible, so its inverse is the identity (scale by 1) rather
            // than a divide-by-zero. Callers never produce a zero factor.
            let ix = sx == 0 ? 1 : 1 / sx
            let iy = sy == 0 ? 1 : 1 / sy
            return .scale(sx: ix, sy: iy, anchor: anchor)
        }
    }
}

extension Array where Element == BoardTransform {
    /// The inverse of an ordered transform list: the reversed list of each
    /// step's inverse. `(t0, t1, t2)` ⁻¹ == `(t2⁻¹, t1⁻¹, t0⁻¹)`.
    var inverse: [BoardTransform] {
        reversed().map { $0.inverse }
    }
}

// MARK: - Resize / rotate handle geometry (R3.3)

/// The eight resize handles around a selection's axis-aligned bounding box.
enum BoardResizeHandle: CaseIterable, Equatable {
    case topLeft, top, topRight
    case left, right
    case bottomLeft, bottom, bottomRight
}

/// The on-screen handle geometry for a selection: its bounding box, the eight
/// resize-handle anchor points, and the single rotate-handle point above the
/// top edge. All points are in world space (the selection box is itself
/// axis-aligned, so these need no rotation). Rendered by the canvas overlay
/// (R3.3); produced purely so it is unit-testable.
struct BoardSelectionHandles: Equatable {
    var boundingBox: CGRect
    var resizeHandles: [BoardResizeHandle: CGPoint]
    var rotateHandle: CGPoint

    /// Distance, in world units, the rotate handle floats above the top edge.
    static let rotateHandleOffset: CGFloat = 24
}

// MARK: - Pure geometry namespace

/// Stateless, value-only geometry used by the controller and exercised directly
/// by the property tests. Nothing here touches `BoardDocument`, AppKit, or the
/// main actor — it is pure CoreGraphics math on `BoardElement` values.
enum SelectionGeometry {

    /// Default hit-test tolerance, matching `StrokeModel`'s.
    static let hitTolerance: CGFloat = 8.0

    // MARK: World bounds

    /// The axis-aligned world-space bounding box of a single element, or `nil`
    /// for an element with no geometry. Frame-based elements account for their
    /// `rotation` (the AABB of the rotated rectangle); points-based elements use
    /// the AABB of their points.
    static func worldBounds(of element: BoardElement) -> CGRect? {
        if let points = element.points, !points.isEmpty {
            return boundingBox(ofPoints: points)
        }
        if let frame = element.frame {
            let corners = rotatedCorners(of: frame, rotation: element.rotation)
            return boundingBox(ofPoints: corners)
        }
        return nil
    }

    /// The union of the world bounds of every element, or `nil` when none have
    /// geometry. This is the selection bounding box (R3.3).
    static func boundingBox(of elements: [BoardElement]) -> CGRect? {
        var result: CGRect?
        for element in elements {
            guard let b = worldBounds(of: element) else { continue }
            result = result.map { $0.union(b) } ?? b
        }
        return result
    }

    /// The AABB of an arbitrary point cloud.
    static func boundingBox(ofPoints points: [CGPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = Swift.min(minX, p.x); maxX = Swift.max(maxX, p.x)
            minY = Swift.min(minY, p.y); maxY = Swift.max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The four world-space corners of `frame` rotated by `rotation` radians
    /// about its centre, ordered TL, TR, BR, BL (in the frame's local sense).
    static func rotatedCorners(of frame: CGRect, rotation: CGFloat) -> [CGPoint] {
        let c = CGPoint(x: frame.midX, y: frame.midY)
        let local = [
            CGPoint(x: frame.minX, y: frame.minY),
            CGPoint(x: frame.maxX, y: frame.minY),
            CGPoint(x: frame.maxX, y: frame.maxY),
            CGPoint(x: frame.minX, y: frame.maxY)
        ]
        guard rotation != 0 else { return local }
        return local.map { rotate($0, about: c, by: rotation) }
    }

    // MARK: Hit testing (R3.1)

    /// Whether `element` is hit by a click at `point` (within `tolerance`).
    /// Dispatches on the element kind: freehand and open shapes test proximity
    /// to their path; closed shapes/text test containment in the (possibly
    /// rotated) frame.
    static func hitTest(_ element: BoardElement,
                        at point: CGPoint,
                        tolerance: CGFloat = hitTolerance) -> Bool {
        switch element.kind {
        case .freehand:
            guard let points = element.points else { return false }
            return polylineContains(points, point, tolerance: tolerance)
        case .line, .arrow:
            if let points = element.points, points.count >= 2 {
                return polylineContains(points, point, tolerance: tolerance)
            }
            if let frame = element.frame {
                // A bare line/arrow stored as a frame is its diagonal.
                let a = CGPoint(x: frame.minX, y: frame.minY)
                let b = CGPoint(x: frame.maxX, y: frame.maxY)
                return distanceToSegment(point, a, b) <= tolerance
            }
            return false
        case .rectangle, .ellipse, .text:
            guard let frame = element.frame else { return false }
            // Transform the hit point into the element's un-rotated local space.
            let c = CGPoint(x: frame.midX, y: frame.midY)
            let local = rotate(point, about: c, by: -element.rotation)
            return frame.insetBy(dx: -tolerance, dy: -tolerance).contains(local)
        }
    }

    /// Whether a polyline (open path through `points`) passes within `tolerance`
    /// of `point`.
    private static func polylineContains(_ points: [CGPoint],
                                         _ point: CGPoint,
                                         tolerance: CGFloat) -> Bool {
        guard let first = points.first else { return false }
        if points.count == 1 { return distance(first, point) <= tolerance }
        for i in 0..<(points.count - 1) {
            if distanceToSegment(point, points[i], points[i + 1]) <= tolerance { return true }
        }
        return false
    }

    // MARK: Transform application (R3.4, R3.5, R3.6)

    /// Applies an ordered transform list to an element in list order. The list
    /// is always assembled in the locked translate → rotate → scale order by the
    /// controller; this just folds it.
    static func apply(_ transforms: [BoardTransform], to element: BoardElement) -> BoardElement {
        transforms.reduce(element) { apply($1, to: $0) }
    }

    /// Applies a single transform step to an element, returning a new element.
    /// Geometry carried in `points` is transformed point-wise (fully invertible
    /// via the inverse affine); geometry carried in `frame` is transformed by
    /// moving/scaling its centre and size and adjusting its `rotation`, so it
    /// stays representable as frame + rotation (see the rotated-resize note at
    /// the top of this file).
    static func apply(_ transform: BoardTransform, to element: BoardElement) -> BoardElement {
        var result = element

        if let points = element.points {
            result.points = points.map { transformPoint($0, transform) }
        }

        if let frame = element.frame {
            let centre = CGPoint(x: frame.midX, y: frame.midY)
            switch transform {
            case .move(let dx, let dy):
                result.frame = frame.offsetBy(dx: dx, dy: dy)
            case .rotate(let angle, let about):
                let newCentre = rotate(centre, about: about, by: angle)
                result.frame = rect(center: newCentre, size: frame.size)
                result.rotation = element.rotation + angle
            case .scale(let sx, let sy, let anchor):
                let newCentre = scale(centre, about: anchor, sx: sx, sy: sy)
                let newSize = CGSize(width: frame.width * sx, height: frame.height * sy)
                result.frame = rect(center: newCentre, size: newSize)
                // rotation deliberately unchanged (see top-of-file note).
            }
        }

        return result
    }

    /// Applies a single transform to a bare point.
    private static func transformPoint(_ p: CGPoint, _ transform: BoardTransform) -> CGPoint {
        switch transform {
        case .move(let dx, let dy):
            return CGPoint(x: p.x + dx, y: p.y + dy)
        case .rotate(let angle, let about):
            return rotate(p, about: about, by: angle)
        case .scale(let sx, let sy, let anchor):
            return scale(p, about: anchor, sx: sx, sy: sy)
        }
    }

    // MARK: Patch derivation

    /// The minimal `[BoardPropertyValue]` patch capturing the geometry that
    /// changed between `old` and `new` (points / frame / rotation). Fed to
    /// `BoardDocument.updateElement`, which stamps and emits one `BoardOp`.
    static func transformPatch(old: BoardElement, new: BoardElement) -> [BoardPropertyValue] {
        var patch: [BoardPropertyValue] = []
        if old.points != new.points, let p = new.points { patch.append(.points(p)) }
        if old.frame != new.frame, let f = new.frame { patch.append(.frame(f)) }
        if old.rotation != new.rotation { patch.append(.rotation(new.rotation)) }
        return patch
    }

    // MARK: Low-level helpers

    /// Rotates `p` about `pivot` by `angle` radians.
    static func rotate(_ p: CGPoint, about pivot: CGPoint, by angle: CGFloat) -> CGPoint {
        guard angle != 0 else { return p }
        let s = sin(angle), c = cos(angle)
        let dx = p.x - pivot.x, dy = p.y - pivot.y
        return CGPoint(x: pivot.x + dx * c - dy * s,
                       y: pivot.y + dx * s + dy * c)
    }

    /// Scales `p` about `anchor` by `(sx, sy)`.
    static func scale(_ p: CGPoint, about anchor: CGPoint, sx: CGFloat, sy: CGFloat) -> CGPoint {
        CGPoint(x: anchor.x + (p.x - anchor.x) * sx,
                y: anchor.y + (p.y - anchor.y) * sy)
    }

    /// Builds a rect with the given centre and size.
    static func rect(center: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: center.x - size.width / 2,
               y: center.y - size.height / 2,
               width: size.width,
               height: size.height)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    private static func distanceToSegment(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        if lenSq == 0 { return distance(point, a) }
        var t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lenSq
        t = Swift.min(Swift.max(t, 0), 1)
        return distance(point, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }
}

// MARK: - Controller

/// Holds the local selection set and drives `BoardDocument` mutators to apply
/// transforms / structure / z-order changes, returning the `BoardOp`s the
/// document mints so the caller can publish them. Pure of networking and wire
/// types; `@MainActor` because it calls the `@MainActor` document.
///
/// Selection is LOCAL-only state (never synced as board ops — design.md
/// "Rendering & selection mapping"): a remote op that does not delete a selected
/// element leaves the selection intact (R2.5). `pruneSelection()` drops ids that
/// are no longer rendered (e.g. a peer deleted them).
@MainActor
final class SelectionTransformController {

    /// The shared board model this controller selects within and mutates.
    let document: BoardDocument

    /// The set of currently-selected element ids (local-only).
    private(set) var selection: Set<BoardElementID> = []

    init(document: BoardDocument) {
        self.document = document
    }

    // MARK: Derived selection state

    /// `true` when nothing is selected.
    var isEmpty: Bool { selection.isEmpty }

    /// The selected elements that still exist and are rendered, sorted
    /// back-to-front by `zKey` (deterministic order for op fan-out and z-order
    /// operations).
    var selectedElements: [BoardElement] {
        document.renderedElements.filter { selection.contains($0.id) }
    }

    /// The selected element ids in deterministic back-to-front order.
    private var orderedSelection: [BoardElementID] {
        selectedElements.map { $0.id }
    }

    // MARK: - Selection (R3.1, R3.2)

    /// Clears the selection.
    func clearSelection() {
        selection.removeAll()
    }

    /// Drops any selected id that is no longer rendered (e.g. deleted by a peer),
    /// preserving the rest (R2.5). Call after integrating remote ops.
    func pruneSelection() {
        selection = selection.filter { document.element(id: $0)?.isRendered == true }
    }

    /// Replaces the selection with `ids`, expanded so that selecting any group
    /// member selects the whole group (R3.8). Non-rendered ids are dropped.
    @discardableResult
    func setSelection(_ ids: Set<BoardElementID>) -> Set<BoardElementID> {
        selection = expandGroups(ids)
        return selection
    }

    /// Single-click selection: selects the TOPMOST element under `point`
    /// (highest in render order), expanded to its whole group (R3.1, R3.8).
    /// With `additive` (modifier-click) the hit group is toggled into/out of the
    /// existing selection (R3.2); without it the selection is replaced. A click
    /// on empty canvas clears the selection (unless additive).
    @discardableResult
    func selectSingle(at point: CGPoint, additive: Bool = false) -> Set<BoardElementID> {
        guard let hit = topmostHit(at: point) else {
            if !additive { selection.removeAll() }
            return selection
        }
        let group = expandGroups([hit])
        if additive {
            if selection.isSuperset(of: group) {
                selection.subtract(group)   // toggle the group off
            } else {
                selection.formUnion(group)  // add the group
            }
        } else {
            selection = group
        }
        return selection
    }

    /// Marquee (rubber-band) multi-selection: selects every element whose world
    /// bounds intersect `rect`, expanded to whole groups (R3.2, R3.8). With
    /// `additive` the marquee result is unioned into the existing selection;
    /// otherwise it replaces it.
    @discardableResult
    func selectMarquee(_ rect: CGRect, additive: Bool = false) -> Set<BoardElementID> {
        let region = rect.standardized
        var hits: Set<BoardElementID> = []
        for element in document.renderedElements {
            if let b = SelectionGeometry.worldBounds(of: element), b.intersects(region) {
                hits.insert(element.id)
            }
        }
        let expanded = expandGroups(hits)
        selection = additive ? selection.union(expanded) : expanded
        return selection
    }

    /// The id of the topmost (frontmost) rendered element hit by `point`, or
    /// `nil` if none. Render order is back-to-front, so iterate in reverse.
    private func topmostHit(at point: CGPoint) -> BoardElementID? {
        for element in document.renderedElements.reversed() {
            if SelectionGeometry.hitTest(element, at: point) { return element.id }
        }
        return nil
    }

    /// Expands a set of ids so that, for any id belonging to a group, every
    /// rendered member of that group is included (R3.8).
    private func expandGroups(_ ids: Set<BoardElementID>) -> Set<BoardElementID> {
        let rendered = document.renderedElements
        let groupIds = Set(ids.compactMap { document.element(id: $0)?.groupId })
        var result: Set<BoardElementID> = []
        for element in rendered {
            if ids.contains(element.id) {
                result.insert(element.id)
            } else if let g = element.groupId, groupIds.contains(g) {
                result.insert(element.id)
            }
        }
        // Keep any selected ids that survived even if (defensively) not rendered.
        return result.isEmpty ? ids.filter { document.element(id: $0)?.isRendered == true } : result
    }

    // MARK: - Bounding box + handles (R3.2, R3.3)

    /// The axis-aligned world bounding box of the current selection, or `nil`
    /// when nothing (with geometry) is selected.
    var selectionBounds: CGRect? {
        SelectionGeometry.boundingBox(of: selectedElements)
    }

    /// The handle geometry for the current selection (bounding box, eight resize
    /// handles, rotate handle), or `nil` when there is no selection bounds.
    func selectionHandles() -> BoardSelectionHandles? {
        guard let box = selectionBounds else { return nil }
        return SelectionTransformController.handles(for: box)
    }

    /// Pure handle layout for an axis-aligned box (split out for testing).
    static func handles(for box: CGRect) -> BoardSelectionHandles {
        let b = box.standardized
        let resize: [BoardResizeHandle: CGPoint] = [
            .topLeft:     CGPoint(x: b.minX, y: b.minY),
            .top:         CGPoint(x: b.midX, y: b.minY),
            .topRight:    CGPoint(x: b.maxX, y: b.minY),
            .left:        CGPoint(x: b.minX, y: b.midY),
            .right:       CGPoint(x: b.maxX, y: b.midY),
            .bottomLeft:  CGPoint(x: b.minX, y: b.maxY),
            .bottom:      CGPoint(x: b.midX, y: b.maxY),
            .bottomRight: CGPoint(x: b.maxX, y: b.maxY)
        ]
        let rotate = CGPoint(x: b.midX, y: b.minY - BoardSelectionHandles.rotateHandleOffset)
        return BoardSelectionHandles(boundingBox: b, resizeHandles: resize, rotateHandle: rotate)
    }
}

// MARK: - Transforms (R3.4, R3.5, R3.6, R3.10)

extension SelectionTransformController {

    /// Applies an ordered transform list to every selected member, emitting one
    /// `BoardOp` per affected member (R3.10). The document mints the stamps. Ops
    /// are returned back-to-front (selection order) for the caller to publish.
    @discardableResult
    func applyTransform(_ transforms: [BoardTransform]) -> [BoardOp] {
        guard !transforms.isEmpty else { return [] }
        var ops: [BoardOp] = []
        for id in orderedSelection {
            guard let old = document.element(id: id), old.isRendered else { continue }
            let new = SelectionGeometry.apply(transforms, to: old)
            let patch = SelectionGeometry.transformPatch(old: old, new: new)
            guard !patch.isEmpty else { continue }
            ops.append(contentsOf: document.updateElement(id, patch))
        }
        return ops
    }

    /// Moves the whole selection by `(dx, dy)` (R3.4). A zero move is a no-op.
    @discardableResult
    func move(dx: CGFloat, dy: CGFloat) -> [BoardOp] {
        guard dx != 0 || dy != 0 else { return [] }
        return applyTransform([.move(dx: dx, dy: dy)])
    }

    /// Rotates the whole selection by `angle` radians about the selection centre
    /// (R3.6). A zero rotation is a no-op.
    @discardableResult
    func rotate(by angle: CGFloat) -> [BoardOp] {
        guard angle != 0, let box = selectionBounds else { return [] }
        let pivot = CGPoint(x: box.midX, y: box.midY)
        return applyTransform([.rotate(angle: angle, about: pivot)])
    }

    /// Scales the whole selection by `(sx, sy)` about `anchor`, scaling member
    /// elements proportionally to the bounding-box change (R3.5). A unit scale
    /// (1, 1) is a no-op.
    @discardableResult
    func scale(sx: CGFloat, sy: CGFloat, about anchor: CGPoint) -> [BoardOp] {
        guard sx != 1 || sy != 1 else { return [] }
        guard sx != 0, sy != 0 else { return [] }
        return applyTransform([.scale(sx: sx, sy: sy, anchor: anchor)])
    }

    /// Resizes the selection by dragging `handle` to world point `to`, scaling
    /// members proportionally to the bounding-box change (R3.5). Computes the
    /// scale factors and the fixed anchor (the opposite handle) from the current
    /// selection bounds, then applies a single scale step.
    @discardableResult
    func resize(handle: BoardResizeHandle, to point: CGPoint) -> [BoardOp] {
        guard let box = selectionBounds else { return [] }
        guard let params = SelectionTransformController.scaleParameters(handle: handle, box: box, to: point)
        else { return [] }
        return scale(sx: params.sx, sy: params.sy, about: params.anchor)
    }

    /// Pure computation of the `(sx, sy, anchor)` for dragging `handle` of the
    /// axis-aligned `box` to `point` (split out for testing). Returns `nil` for a
    /// degenerate box (zero width/height on the affected axis).
    static func scaleParameters(handle: BoardResizeHandle,
                                box: CGRect,
                                to point: CGPoint) -> (sx: CGFloat, sy: CGFloat, anchor: CGPoint)? {
        let b = box.standardized

        // Which edges the handle drags, and therefore which corner stays fixed.
        let dragsLeft   = handle == .topLeft || handle == .left || handle == .bottomLeft
        let dragsRight  = handle == .topRight || handle == .right || handle == .bottomRight
        let dragsTop    = handle == .topLeft || handle == .top || handle == .topRight
        let dragsBottom = handle == .bottomLeft || handle == .bottom || handle == .bottomRight

        var sx: CGFloat = 1
        var sy: CGFloat = 1
        // The anchor is the edge OPPOSITE the dragged edge; for an axis the
        // handle does not drag, the anchor coordinate is irrelevant (scale 1).
        var anchorX = b.minX
        var anchorY = b.minY

        if dragsLeft {
            guard b.width != 0 else { return nil }
            anchorX = b.maxX
            sx = (anchorX - point.x) / b.width
        } else if dragsRight {
            guard b.width != 0 else { return nil }
            anchorX = b.minX
            sx = (point.x - anchorX) / b.width
        }

        if dragsTop {
            guard b.height != 0 else { return nil }
            anchorY = b.maxY
            sy = (anchorY - point.y) / b.height
        } else if dragsBottom {
            guard b.height != 0 else { return nil }
            anchorY = b.minY
            sy = (point.y - anchorY) / b.height
        }

        return (sx, sy, CGPoint(x: anchorX, y: anchorY))
    }
}

// MARK: - Delete / group / ungroup (R3.7, R3.8)

extension SelectionTransformController {

    /// Deletes every selected element, emitting one delete `BoardOp` per member
    /// (R3.7, R3.10), then clears the selection.
    @discardableResult
    func deleteSelection() -> [BoardOp] {
        var ops: [BoardOp] = []
        for id in orderedSelection {
            ops.append(contentsOf: document.deleteElement(id))
        }
        selection.removeAll()
        return ops
    }

    /// Groups the current selection into a fresh group (one op per member —
    /// R3.10), so that selecting any member afterwards selects the whole group
    /// (R3.8). Needs ≥2 members. The selection is unchanged.
    @discardableResult
    func groupSelection() -> [BoardOp] {
        document.group(orderedSelection)
    }

    /// Ungroups the current selection: clears `groupId` on every selected member
    /// (R3.8). After ungrouping, selecting a former member yields only that
    /// element.
    @discardableResult
    func ungroupSelection() -> [BoardOp] {
        document.ungroup(orderedSelection)
    }
}

// MARK: - Z-order on the selection (R3.9)

extension SelectionTransformController {

    /// Brings the whole selection to the front, preserving the members' relative
    /// order (R3.9). Members are raised bottom-to-top so the topmost-selected
    /// ends up frontmost.
    @discardableResult
    func bringSelectionToFront() -> [BoardOp] {
        var ops: [BoardOp] = []
        for id in orderedSelection {            // back-to-front
            ops.append(contentsOf: document.bringToFront(id))
        }
        return ops
    }

    /// Sends the whole selection to the back, preserving relative order (R3.9).
    /// Members are lowered top-to-bottom so the bottommost-selected ends up
    /// backmost.
    @discardableResult
    func sendSelectionToBack() -> [BoardOp] {
        var ops: [BoardOp] = []
        for id in orderedSelection.reversed() { // front-to-back
            ops.append(contentsOf: document.sendToBack(id))
        }
        return ops
    }

    /// Moves the whole selection one step forward (R3.9). Processed front-to-back
    /// so members do not leapfrog one another.
    @discardableResult
    func bringSelectionForward() -> [BoardOp] {
        var ops: [BoardOp] = []
        for id in orderedSelection.reversed() {
            ops.append(contentsOf: document.bringForward(id))
        }
        return ops
    }

    /// Moves the whole selection one step backward (R3.9). Processed back-to-front
    /// so members do not leapfrog one another.
    @discardableResult
    func sendSelectionBackward() -> [BoardOp] {
        var ops: [BoardOp] = []
        for id in orderedSelection {
            ops.append(contentsOf: document.sendBackward(id))
        }
        return ops
    }
}
