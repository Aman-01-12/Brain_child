//
//  WhiteboardViewModel.swift
//  inter
//
//  View model driving the SwiftUI secure-interview whiteboard.
//
//  In the one-way candidate-tool-share model the whiteboard is a LOCAL,
//  single-user surface. This is the gesture-translation + validation boundary
//  between the SwiftUI `Canvas` / in-window overlays (`WhiteboardRootView`) and
//  the pure convergence/transform logic layers — `BoardDocument` (the
//  LWW-Element-Map) and `SelectionTransformController` (selection + transform
//  geometry). Local gestures are translated into `BoardOp`s that mutate the
//  in-memory `BoardDocument`; there is NO CRDT transport, no remote presence,
//  and no networking side effect. The candidate may publish the rendered
//  surface as a screen-share via the capture pipeline.
//
//  Pan/zoom (R5): a LOCAL `Viewport { offset, scale }` (clamped) is held here.
//  EVERY pointer location is converted screen→world before hit-testing / op
//  creation, so edits land at the correct world position regardless of the
//  camera (R5.2); element geometry is always world space (R5.4).
//
//  Scope: pure logic + Combine/SwiftUI (ObservableObject) + CoreGraphics for
//  geometry only. No AppKit, no NSWindow — all auxiliary UI is in-window
//  (R7.6). Follows the established @MainActor view-model pattern.
//

import Combine
import CoreGraphics
import SwiftUI

// MARK: - Tool selection

/// The active whiteboard tool. The legacy `WhiteboardTool` (in `StrokeModel.swift`)
/// cannot express the new SELECT and ARROW tools, so the collaborative surface
/// uses this richer enum; `WhiteboardColor` (shared with `BoardDocument`) is
/// reused unchanged.
enum WhiteboardToolKind: Equatable, CaseIterable {
    case select
    case freehand
    case rectangle
    case ellipse
    case line
    case arrow
    case eraser
    case text

    /// The board-element kind a draw tool creates (`nil` for non-draw tools).
    var elementKind: BoardElementKind? {
        switch self {
        case .freehand:  return .freehand
        case .rectangle: return .rectangle
        case .ellipse:   return .ellipse
        case .line:      return .line
        case .arrow:     return .arrow
        case .select, .eraser, .text: return nil
        }
    }
}

// MARK: - Viewport (R5)

/// The LOCAL pan/zoom camera over the shared world-space board. NEVER synced
/// (R5.3). Screen↔world conversion uses `screen = world * scale + offset`.
struct WhiteboardViewport: Equatable {
    var offset: CGSize = .zero
    var scale: CGFloat = 1.0

    static let minScale: CGFloat = 0.25
    static let maxScale: CGFloat = 4.0

    /// Clamp `scale` into the allowed range.
    static func clampScale(_ s: CGFloat) -> CGFloat {
        min(max(s, minScale), maxScale)
    }
}

// MARK: - View model

@MainActor
final class WhiteboardViewModel: ObservableObject {

    // MARK: - Tuning constants

    /// Minimum distance (world units) a new freehand point must be from the last
    /// retained point before it is kept — bounds the per-stroke point count.
    static let freehandMinPointDistance: CGFloat = 1.5

    /// Minimum width AND height (world units) a shape/segment drag must span
    /// before an element is created.
    static let minShapeExtent: CGFloat = 4.0

    /// Hard cap on a text element's character count.
    static let maxTextLength = 256

    /// The site stamped into a STANDALONE (pre-configure) document. Replaced by
    /// the attested identity once the shared document is installed.
    static let standaloneSite = "local"

    /// How long the transient "shape too small" / cap notices stay visible.
    private static let noticeDisplaySeconds: UInt64 = 2

    // MARK: - Session collaborators

    /// The shared LWW-Element-Map. Created locally for standalone use; replaced
    /// by the bridge-owned shared document in `configure`.
    private(set) var document: BoardDocument

    /// Selection + transform geometry over `document`. Recreated whenever the
    /// document is replaced.
    private(set) var selection: SelectionTransformController

    // MARK: - Published tool / style state

    /// The active tool, driving gesture routing and toolbar highlighting.
    @Published var activeTool: WhiteboardToolKind = .freehand

    /// The active stroke color applied to created elements.
    @Published var activeColor: WhiteboardColor = .white

    /// The active stroke width applied to created elements.
    @Published var activeStrokeWidth: CGFloat = 3.0

    /// The local pan/zoom camera (R5).
    @Published var viewport = WhiteboardViewport()

    // MARK: - Published board / overlay state

    /// Monotonic counter bumped on every document mutation (local or remote) so
    /// SwiftUI re-renders the `Canvas` (the `BoardDocument` is not itself
    /// observable).
    @Published private(set) var boardVersion: Int = 0

    /// The live draw preview while a draw gesture is in flight (world space).
    @Published private(set) var drawPreview: DrawPreview?

    /// The live marquee rectangle while rubber-band selecting (world space).
    @Published private(set) var marqueeRect: CGRect?

    /// Transient in-window notice when a gesture created nothing (too small).
    @Published private(set) var transientNotice: String?

    /// Set when a local addition was refused at the element/point cap (R8.3).
    @Published private(set) var didHitSizeLimit = false

    /// The live draw preview payload.
    enum DrawPreview: Equatable {
        case stroke([CGPoint])
        case frame(CGRect, BoardElementKind)
        case segment(CGPoint, CGPoint, BoardElementKind)
    }

    // MARK: - Private gesture state

    /// The active pointer-gesture mode (set on pointer-down, cleared on up).
    private enum GestureMode {
        case none
        case freehand
        case shape(BoardElementKind, start: CGPoint)
        case segment(BoardElementKind, start: CGPoint)
        case erase
        case move(last: CGPoint)
        case resize(BoardResizeHandle)
        case rotate(center: CGPoint, last: CGPoint)
        case marquee(start: CGPoint, base: Set<BoardElementID>)
    }
    private var gestureMode: GestureMode = .none

    /// Accumulated (coalesced) freehand points for the active stroke (world).
    private var freehandPoints: [CGPoint] = []

    /// Auto-dismiss task for `transientNotice`.
    private var noticeResetTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        let doc = BoardDocument(site: WhiteboardViewModel.standaloneSite)
        self.document = doc
        self.selection = SelectionTransformController(document: doc)
    }

    // MARK: - Bridge entry points

    /// Empty the whiteboard, resetting the undo/redo history so the next capture
    /// is blank (R9.4). Kept as the stable bridge-facing API
    /// (`InterSecureToolsBridge.clearWhiteboard`).
    func clear() {
        _ = document.clear()
        selection.clearSelection()
        resetTransientState()
        bumpBoard()
    }

    /// Detach at teardown (R11.1): drop transient overlay/gesture state. The
    /// document is retained (in-memory, standalone-safe) so a post-teardown
    /// `clear()` from the bridge stays safe.
    func detach() {
        resetTransientState()
        selection.clearSelection()
        didHitSizeLimit = false
    }

    // MARK: - Tool / style selection

    func selectTool(_ tool: WhiteboardToolKind) {
        guard tool != activeTool else { return }
        activeTool = tool
        // Leaving the select tool drops the in-window handles.
        if tool != .select { selection.clearSelection() }
        bumpBoard()
    }

    func selectColor(_ color: WhiteboardColor) {
        activeColor = color
        // Recolor the current selection too (a natural Excalidraw-style action).
        if !selection.isEmpty {
            var ops: [BoardOp] = []
            for id in selection.selection {
                ops.append(contentsOf: document.updateElement(id, [.strokeColor(color)]))
            }
            publish(ops, flush: true)
            bumpBoard()
        }
    }

    func selectStrokeWidth(_ width: CGFloat) {
        activeStrokeWidth = width
        if !selection.isEmpty {
            var ops: [BoardOp] = []
            for id in selection.selection {
                ops.append(contentsOf: document.updateElement(id, [.strokeWidth(width)]))
            }
            publish(ops, flush: true)
            bumpBoard()
        }
    }

    // MARK: - Rendered state (for the canvas)

    /// The visible board in back-to-front draw order.
    var renderedElements: [BoardElement] { document.renderedElements }

    /// The current local selection ids.
    var selectedIDs: Set<BoardElementID> { selection.selection }

    var hasSelection: Bool { !selection.isEmpty }

    /// The handle geometry (world space) for the current selection, if any.
    func selectionHandles() -> BoardSelectionHandles? { selection.selectionHandles() }

    func element(_ id: BoardElementID) -> BoardElement? { document.element(id: id) }

    // MARK: - Coordinate conversion (R5.2)

    /// Convert a screen point to shared world space (inverse viewport transform).
    func toWorld(_ screen: CGPoint) -> CGPoint {
        CGPoint(x: (screen.x - viewport.offset.width) / viewport.scale,
                y: (screen.y - viewport.offset.height) / viewport.scale)
    }

    /// Convert a world point to screen space (viewport transform).
    func toScreen(_ world: CGPoint) -> CGPoint {
        CGPoint(x: world.x * viewport.scale + viewport.offset.width,
                y: world.y * viewport.scale + viewport.offset.height)
    }

    // MARK: - Pan / zoom (R5.1)

    /// Pan the camera by a screen-space delta.
    func panBy(dx: CGFloat, dy: CGFloat) {
        viewport.offset.width += dx
        viewport.offset.height += dy
    }

    /// Zoom by `factor` keeping the world point under `screenPivot` fixed
    /// (zoom about the pointer — R5.1).
    func zoom(by factor: CGFloat, aboutScreen screenPivot: CGPoint) {
        let worldPivot = toWorld(screenPivot)
        let newScale = WhiteboardViewport.clampScale(viewport.scale * factor)
        viewport.scale = newScale
        viewport.offset = CGSize(
            width: screenPivot.x - worldPivot.x * newScale,
            height: screenPivot.y - worldPivot.y * newScale)
    }

    func zoomIn(aboutScreen pivot: CGPoint) { zoom(by: 1.2, aboutScreen: pivot) }
    func zoomOut(aboutScreen pivot: CGPoint) { zoom(by: 1.0 / 1.2, aboutScreen: pivot) }

    /// Reset the camera to the identity viewport.
    func resetViewport() { viewport = WhiteboardViewport() }

    // MARK: - Pointer gesture routing (R2.1, R3.x)

    /// Begin a pointer gesture at a SCREEN point. `additive` is the modifier
    /// (shift/⌘-click) state for selection.
    func pointerDown(atScreen screen: CGPoint, additive: Bool) {
        let world = toWorld(screen)
        switch activeTool {
        case .freehand:
            freehandPoints = [world]
            drawPreview = .stroke(freehandPoints)
            gestureMode = .freehand
        case .rectangle:
            gestureMode = .shape(.rectangle, start: world)
            drawPreview = .frame(CGRect(origin: world, size: .zero), .rectangle)
        case .ellipse:
            gestureMode = .shape(.ellipse, start: world)
            drawPreview = .frame(CGRect(origin: world, size: .zero), .ellipse)
        case .line:
            gestureMode = .segment(.line, start: world)
            drawPreview = .segment(world, world, .line)
        case .arrow:
            gestureMode = .segment(.arrow, start: world)
            drawPreview = .segment(world, world, .arrow)
        case .eraser:
            gestureMode = .erase
            eraseAtWorld(world)
        case .text:
            // Text entry is opened by the view's inline editor overlay.
            gestureMode = .none
        case .select:
            beginSelectGesture(world: world, screen: screen, additive: additive)
        }
        bumpBoard()
    }

    /// Continue the active gesture to a SCREEN point.
    func pointerDragged(toScreen screen: CGPoint) {
        let world = toWorld(screen)
        switch gestureMode {
        case .freehand:
            appendFreehandPoint(world)
        case .shape(let kind, let start):
            drawPreview = .frame(Self.rect(from: start, to: world), kind)
        case .segment(let kind, let start):
            drawPreview = .segment(start, world, kind)
        case .erase:
            eraseAtWorld(world)
        case .move(let last):
            let ops = selection.move(dx: world.x - last.x, dy: world.y - last.y)
            gestureMode = .move(last: world)
            publishStreaming(ops)
        case .resize(let handle):
            publishStreaming(selection.resize(handle: handle, to: world))
        case .rotate(let center, let last):
            let a0 = atan2(last.y - center.y, last.x - center.x)
            let a1 = atan2(world.y - center.y, world.x - center.x)
            let ops = selection.rotate(by: a1 - a0)
            gestureMode = .rotate(center: center, last: world)
            publishStreaming(ops)
        case .marquee(let start, let base):
            let r = Self.rect(from: start, to: world)
            marqueeRect = r
            selection.setSelection(base)
            selection.selectMarquee(r, additive: true)
        case .none:
            break
        }
        bumpBoard()
    }

    /// Finish the active gesture at a SCREEN point.
    func pointerUp(atScreen screen: CGPoint) {
        let world = toWorld(screen)
        switch gestureMode {
        case .freehand:
            endFreehandStroke()
        case .shape(let kind, let start):
            commitShape(kind, from: start, to: world)
        case .segment(let kind, let start):
            commitSegment(kind, from: start, to: world)
        case .erase, .move, .resize, .rotate:
            break  // gesture ops were already applied to the local document
        case .marquee:
            marqueeRect = nil
        case .none:
            break
        }
        gestureMode = .none
        drawPreview = nil
        bumpBoard()
    }

    // MARK: - Select-gesture dispatch

    private func beginSelectGesture(world: CGPoint, screen: CGPoint, additive: Bool) {
        // 1. Handle hit-test (screen space, fixed pixel tolerance) when a
        //    selection exists.
        if let handles = selection.selectionHandles() {
            let rotateScreen = toScreen(handles.rotateHandle)
            if Self.near(rotateScreen, screen, tolerance: 12) {
                let box = handles.boundingBox
                gestureMode = .rotate(center: CGPoint(x: box.midX, y: box.midY), last: world)
                return
            }
            for (handle, point) in handles.resizeHandles {
                if Self.near(toScreen(point), screen, tolerance: 12) {
                    gestureMode = .resize(handle)
                    return
                }
            }
        }

        // 2. Element hit-test (topmost wins).
        let hit = document.renderedElements.reversed().first {
            SelectionGeometry.hitTest($0, at: world)
        }
        if let hit = hit {
            if additive {
                selection.selectSingle(at: world, additive: true)
            } else if !selection.selection.contains(hit.id) {
                selection.selectSingle(at: world, additive: false)
            }
            gestureMode = .move(last: world)
        } else {
            // 3. Empty canvas → marquee (clearing first unless additive).
            let base = additive ? selection.selection : []
            if !additive { selection.clearSelection() }
            gestureMode = .marquee(start: world, base: base)
            marqueeRect = CGRect(origin: world, size: .zero)
        }
    }

    // MARK: - Freehand

    private func appendFreehandPoint(_ point: CGPoint) {
        guard let last = freehandPoints.last else {
            freehandPoints = [point]
            drawPreview = .stroke(freehandPoints)
            return
        }
        guard Self.distance(last, point) >= Self.freehandMinPointDistance else { return }
        freehandPoints.append(point)
        drawPreview = .stroke(freehandPoints)
    }

    private func endFreehandStroke() {
        defer { freehandPoints = [] }
        guard freehandPoints.count >= 2 else { return }   // zero-length → nothing
        let ops = document.addElement(
            kind: .freehand, points: freehandPoints,
            strokeColor: activeColor, strokeWidth: activeStrokeWidth)
        afterAdd(ops)
    }

    // MARK: - Shapes / segments

    private func commitShape(_ kind: BoardElementKind, from start: CGPoint, to end: CGPoint) {
        let rect = Self.rect(from: start, to: end)
        guard rect.width >= Self.minShapeExtent, rect.height >= Self.minShapeExtent else {
            flagNotice("Too small — not created")
            return
        }
        let ops = document.addElement(
            kind: kind, frame: rect,
            strokeColor: activeColor, strokeWidth: activeStrokeWidth)
        afterAdd(ops)
    }

    private func commitSegment(_ kind: BoardElementKind, from start: CGPoint, to end: CGPoint) {
        guard Self.distance(start, end) >= Self.minShapeExtent else {
            flagNotice("Too small — not created")
            return
        }
        let ops = document.addElement(
            kind: kind, points: [start, end],
            strokeColor: activeColor, strokeWidth: activeStrokeWidth)
        afterAdd(ops)
    }

    // MARK: - Eraser

    private func eraseAtWorld(_ world: CGPoint) {
        guard let hit = document.renderedElements.reversed().first(where: {
            SelectionGeometry.hitTest($0, at: world)
        }) else { return }
        let ops = document.deleteElement(hit.id)
        selection.pruneSelection()
        publishStreaming(ops)
    }

    // MARK: - Text (Excalidraw-style, R4)

    /// The topmost rendered TEXT element under `worldPoint`, for re-editing.
    func editableTextElement(atWorld worldPoint: CGPoint) -> BoardElement? {
        document.renderedElements.reversed().first {
            $0.kind == .text && SelectionGeometry.hitTest($0, at: worldPoint)
        }
    }

    /// Commit inline text (R4.3, R4.5, R4.7). Creating: a non-empty string adds
    /// exactly one text element at `worldPoint`; empty adds none. Editing an
    /// existing element: a non-empty string updates it; empty deletes it.
    func commitText(_ string: String, atWorld worldPoint: CGPoint, editing id: BoardElementID?) {
        let trimmed = String(string.prefix(Self.maxTextLength))
        if let id = id {
            if trimmed.isEmpty {
                publish(document.deleteElement(id), flush: true)
                selection.pruneSelection()
            } else {
                let frame = Self.textFrame(for: trimmed,
                                           at: document.element(id: id)?.frame?.origin ?? worldPoint)
                publish(document.updateElement(id, [.text(trimmed), .frame(frame)]), flush: true)
            }
            bumpBoard()
            return
        }
        guard !trimmed.isEmpty else { return }   // empty → no element (R4.7)
        let frame = Self.textFrame(for: trimmed, at: worldPoint)
        let ops = document.addElement(
            kind: .text, frame: frame, strokeColor: activeColor,
            strokeWidth: activeStrokeWidth, text: trimmed)
        afterAdd(ops)
    }

    /// Cap raw entry length as the field types (R4 / size cap).
    func limitTextInput(_ raw: String) -> String {
        raw.count > Self.maxTextLength ? String(raw.prefix(Self.maxTextLength)) : raw
    }

    // MARK: - Structure / z-order / history passthroughs (R3.7–R3.9, R9)

    func deleteSelection() { publish(selection.deleteSelection(), flush: true); bumpBoard() }
    func groupSelection() { publish(selection.groupSelection(), flush: true); bumpBoard() }
    func ungroupSelection() { publish(selection.ungroupSelection(), flush: true); bumpBoard() }
    func bringSelectionToFront() { publish(selection.bringSelectionToFront(), flush: true); bumpBoard() }
    func sendSelectionToBack() { publish(selection.sendSelectionToBack(), flush: true); bumpBoard() }
    func bringSelectionForward() { publish(selection.bringSelectionForward(), flush: true); bumpBoard() }
    func sendSelectionBackward() { publish(selection.sendSelectionBackward(), flush: true); bumpBoard() }

    func undo() { publish(document.undo(), flush: true); selection.pruneSelection(); bumpBoard() }
    func redo() { publish(document.redo(), flush: true); selection.pruneSelection(); bumpBoard() }

    // MARK: - Notice acknowledgement

    func clearSizeLimitNotice() {
        didHitSizeLimit = false
        document.clearCapFlags()
    }

    // MARK: - Op-application helpers

    /// Apply already-generated ops. In the one-way local model the document was
    /// already mutated at the call site, so these helpers only surface a local
    /// cap notice when an add was refused/clamped — there is no transport.
    private func publishStreaming(_ ops: [BoardOp]) {
        // No transport in the local model; ops were applied to the document
        // when the call site generated them.
    }

    private func publish(_ ops: [BoardOp], flush: Bool) {
        // No transport in the local model; ops were applied to the document
        // when the call site generated them.
    }

    /// Surface a cap notice if a freshly-added element was refused/clamped.
    private func afterAdd(_ ops: [BoardOp]) {
        if document.didHitElementCap || document.didHitPointCap {
            didHitSizeLimit = true
            flagNotice("Board is full")
        }
        bumpBoard()
    }

    // MARK: - Private helpers

    private func bumpBoard() { boardVersion &+= 1 }

    private func flagNotice(_ message: String) {
        transientNotice = message
        noticeResetTask?.cancel()
        noticeResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.noticeDisplaySeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.transientNotice = nil
        }
    }

    private func resetTransientState() {
        noticeResetTask?.cancel()
        noticeResetTask = nil
        transientNotice = nil
        freehandPoints = []
        drawPreview = nil
        marqueeRect = nil
        gestureMode = .none
    }

    /// Estimate a world-space text bounding box from the string and a 16pt font.
    private static func textFrame(for string: String, at origin: CGPoint) -> CGRect {
        let charWidth: CGFloat = 9.0
        let lineHeight: CGFloat = 20.0
        let lines = string.components(separatedBy: "\n")
        let longest = lines.map { $0.count }.max() ?? 0
        let width = max(charWidth, CGFloat(longest) * charWidth)
        let height = max(lineHeight, CGFloat(lines.count) * lineHeight)
        return CGRect(x: origin.x, y: origin.y, width: width, height: height)
    }

    private static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    private static func near(_ a: CGPoint, _ b: CGPoint, tolerance: CGFloat) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }
}
