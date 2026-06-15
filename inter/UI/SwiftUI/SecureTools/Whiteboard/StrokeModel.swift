//
//  StrokeModel.swift
//  inter
//
//  Pure value/logic layer backing the secure-interview SwiftUI whiteboard.
//
//  This file defines ONLY the pure, in-memory value types for the whiteboard
//  stroke model (task 1.1). It deliberately depends on nothing but CoreGraphics
//  (for CGPoint / CGRect) and Foundation (for UUID): no AppKit, no SwiftUI, and
//  no I/O. Keeping these types pure makes them directly unit- and
//  property-testable.
//
//  The StrokeModel class itself (mutations, undo/redo history, clear, and
//  hit-testing) is implemented separately in task 1.2 and extends this file.
//

import CoreGraphics
import Foundation

// MARK: - Tool selection

/// The drawing tool currently selected in the whiteboard.
enum WhiteboardTool {
    case freehand
    case shape
    case eraser
    case text
}

// MARK: - Color palette

/// A fixed in-window drawing-color palette.
///
/// Modeled as an enum of palette entries so the type is `Equatable` and free of
/// any AppKit `NSColor` dependency. A concrete CG/SwiftUI color for rendering
/// can be derived from a case later in the view layer; the model itself stays
/// pure.
enum WhiteboardColor: Equatable, CaseIterable {
    case white
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case black
}

// MARK: - Shape kinds

/// The geometric kind of a shape element.
enum ShapeKind: Equatable {
    case rectangle
    case ellipse
    case line
}

// MARK: - Whiteboard element

/// A single drawing element in the whiteboard, in draw order.
///
/// Each element has a stable identity, a `Kind` describing its geometry/content,
/// and the drawing color that was active when it was created.
struct WhiteboardElement: Equatable, Identifiable {

    /// The geometry/content of an element.
    enum Kind: Equatable {
        /// A freehand stroke following the pointer path.
        case freehand(points: [CGPoint])
        /// A shape (rectangle, ellipse, or line) sized to a drag extent.
        case shape(rect: CGRect, kind: ShapeKind)
        /// A text element placed at an origin (1...256 characters).
        case text(string: String, origin: CGPoint)
    }

    let id: UUID
    var kind: Kind
    var color: WhiteboardColor

    init(id: UUID = UUID(), kind: Kind, color: WhiteboardColor) {
        self.id = id
        self.kind = kind
        self.color = color
    }
}

// MARK: - Reversible change

/// One reversible change to the model: the addition or removal of a single
/// element. This is the unit recorded on the undo/redo history.
enum WhiteboardChange: Equatable {
    /// An element was added (to the end of the draw-order collection).
    case add(WhiteboardElement)
    /// An element was removed from the given index in the draw-order collection.
    case remove(WhiteboardElement, atIndex: Int)
}

// MARK: - Stroke model

import Combine

/// The in-memory model backing the secure-interview whiteboard.
///
/// `StrokeModel` owns the ordered, draw-order collection of elements plus the
/// undo/redo history. It is a pure logic layer: it depends only on
/// CoreGraphics/Foundation for geometry and Combine for `ObservableObject`
/// conformance. It performs no I/O, holds no AppKit references, and never
/// touches the network — which keeps it directly unit- and property-testable.
///
/// History semantics (Requirement 9):
/// - A reversible change is the addition or removal of exactly one element.
/// - Every mutation records one `WhiteboardChange`, pushes it onto `undoStack`
///   (trimmed to the 50 most recent), and clears `redoStack`.
/// - `undo` inverts the top undo change and moves it to `redoStack`; `redo`
///   reapplies the top redo change and moves it back to `undoStack`. Both are
///   no-ops (no error) on an empty stack.
@MainActor
final class StrokeModel: ObservableObject {

    /// The ordered, draw-order collection of elements. Index 0 is drawn first
    /// (bottom); the last element is drawn last (topmost).
    @Published private(set) var elements: [WhiteboardElement] = []

    /// The undo history, bounded to the 50 most recent changes (R9.7).
    private(set) var undoStack: [WhiteboardChange] = []

    /// The redo history. Cleared whenever a new reversible change is recorded
    /// (R9.6).
    private(set) var redoStack: [WhiteboardChange] = []

    /// The drawing color applied to newly created shape and text elements
    /// (R8.8, R8.9).
    var activeColor: WhiteboardColor = .white

    /// The currently selected drawing tool.
    var activeTool: WhiteboardTool = .freehand

    /// The maximum number of changes retained in the undo history (R9.7).
    static let historyLimit = 50

    /// The distance, in points, within which `hitTest(_:)` considers a point to
    /// be touching an element's geometry.
    private static let hitTolerance: CGFloat = 8.0

    // MARK: Mutations

    /// Append `element` to the draw-order collection, recording the addition as
    /// a reversible change.
    ///
    /// Pushes a `.add` change onto the undo history (trimmed to the 50 most
    /// recent) and clears the redo history (R9.6, R9.7).
    func add(_ element: WhiteboardElement) {
        elements.append(element)
        record(.add(element))
    }

    /// Remove the element at `index` from the draw-order collection, recording
    /// the removal as a reversible change.
    ///
    /// Out-of-range indices are ignored so the model can never crash on a stale
    /// index. Pushes a `.remove` change onto the undo history (trimmed to the 50
    /// most recent) and clears the redo history (R9.6, R9.7).
    func removeElement(at index: Int) {
        guard elements.indices.contains(index) else { return }
        let removed = elements.remove(at: index)
        record(.remove(removed, atIndex: index))
    }

    // MARK: Undo / redo

    /// Revert the most recent reversible change, moving it onto the redo
    /// history. A no-op with no error when the undo history is empty (R9.3).
    func undo() {
        guard let change = undoStack.popLast() else { return }
        invert(change)
        redoStack.append(change)
    }

    /// Reapply the most recently reverted change, moving it back onto the undo
    /// history. A no-op with no error when the redo history is empty (R9.4).
    func redo() {
        guard let change = redoStack.popLast() else { return }
        reapply(change)
        undoStack.append(change)
    }

    // MARK: Clear

    /// Remove every element and reset both histories to empty (R9.5).
    func clear() {
        elements = []
        undoStack = []
        redoStack = []
    }

    // MARK: Hit-testing

    /// Return the index of the topmost element (last in draw order) whose
    /// geometry is at or near `point`, or `nil` when no element is hit.
    ///
    /// Used by the eraser tool (R8.3, R8.4). The search runs from the top of the
    /// draw order downward so the visually frontmost element wins. Pure and
    /// deterministic: the same model and point always return the same result.
    func hitTest(_ point: CGPoint) -> Int? {
        for index in stride(from: elements.count - 1, through: 0, by: -1) {
            if Self.element(elements[index], contains: point) {
                return index
            }
        }
        return nil
    }

    // MARK: - Private helpers

    /// Record a change: push onto the undo history (trimming to the 50 most
    /// recent) and discard the redo history (R9.6, R9.7).
    private func record(_ change: WhiteboardChange) {
        undoStack.append(change)
        if undoStack.count > Self.historyLimit {
            undoStack.removeFirst(undoStack.count - Self.historyLimit)
        }
        redoStack = []
    }

    /// Apply the inverse of `change` to `elements` (used by `undo`).
    private func invert(_ change: WhiteboardChange) {
        switch change {
        case .add(let element):
            // The element was appended; remove it by identity so the inversion
            // is robust even if the trailing index has shifted.
            if let index = elements.lastIndex(where: { $0.id == element.id }) {
                elements.remove(at: index)
            }
        case .remove(let element, let index):
            // Reinsert at the original index, clamping to a valid position.
            let target = min(max(index, 0), elements.count)
            elements.insert(element, at: target)
        }
    }

    /// Reapply `change` to `elements` (used by `redo`).
    private func reapply(_ change: WhiteboardChange) {
        switch change {
        case .add(let element):
            // Originally appended to the end of the draw order.
            elements.append(element)
        case .remove(_, let index):
            guard elements.indices.contains(index) else { return }
            elements.remove(at: index)
        }
    }

    /// Whether `element`'s geometry is at or near `point`, within the hit
    /// tolerance.
    private static func element(_ element: WhiteboardElement, contains point: CGPoint) -> Bool {
        switch element.kind {
        case .freehand(let points):
            return freehandContains(points, point)
        case .shape(let rect, let kind):
            return shapeContains(rect, kind: kind, point: point)
        case .text(let string, let origin):
            return textContains(string, origin: origin, point: point)
        }
    }

    /// A freehand stroke is hit when `point` is within tolerance of any of its
    /// vertices or line segments.
    private static func freehandContains(_ points: [CGPoint], _ point: CGPoint) -> Bool {
        guard let first = points.first else { return false }
        if points.count == 1 {
            return distance(first, point) <= hitTolerance
        }
        for index in 0..<(points.count - 1) {
            if distanceToSegment(point, points[index], points[index + 1]) <= hitTolerance {
                return true
            }
        }
        return false
    }

    /// A shape is hit when `point` falls inside (or within tolerance of) its
    /// bounding rectangle; a `.line` shape is hit when `point` is near the
    /// diagonal of the rect (origin → opposite corner).
    private static func shapeContains(_ rect: CGRect, kind: ShapeKind, point: CGPoint) -> Bool {
        let normalized = rect.standardized
        switch kind {
        case .rectangle, .ellipse:
            return normalized.insetBy(dx: -hitTolerance, dy: -hitTolerance).contains(point)
        case .line:
            let start = CGPoint(x: rect.minX, y: rect.minY)
            let end = CGPoint(x: rect.maxX, y: rect.maxY)
            return distanceToSegment(point, start, end) <= hitTolerance
        }
    }

    /// A text element is hit when `point` falls within an estimated bounding box
    /// anchored at its origin. The box width scales with character count and is
    /// padded by the hit tolerance on all sides.
    private static func textContains(_ string: String, origin: CGPoint, point: CGPoint) -> Bool {
        // Approximate glyph metrics for a 13pt monospaced font.
        let approxCharWidth: CGFloat = 8.0
        let approxLineHeight: CGFloat = 16.0
        let width = max(approxCharWidth, CGFloat(string.count) * approxCharWidth)
        let box = CGRect(x: origin.x, y: origin.y, width: width, height: approxLineHeight)
        return box.insetBy(dx: -hitTolerance, dy: -hitTolerance).contains(point)
    }

    /// Euclidean distance between two points.
    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Shortest distance from `point` to the line segment `a`–`b`.
    private static func distanceToSegment(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        if lengthSquared == 0 {
            return distance(point, a)
        }
        // Project point onto the segment, clamping t to [0, 1].
        var t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
        t = min(max(t, 0), 1)
        let projection = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return distance(point, projection)
    }
}
