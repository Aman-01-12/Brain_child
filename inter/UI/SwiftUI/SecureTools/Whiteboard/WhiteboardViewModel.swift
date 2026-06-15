//
//  WhiteboardViewModel.swift
//  inter
//
//  View model driving the SwiftUI secure-interview whiteboard (Whiteboard).
//
//  This is the gesture-translation + validation boundary between the SwiftUI
//  Canvas / in-window overlays (task 5.2) and the pure `StrokeModel` logic
//  layer. It owns exactly one `StrokeModel`, exposes the active tool / color to
//  the overlays, surfaces the in-progress stroke/shape so the Canvas can draw a
//  live preview, and — most importantly — enforces every element-creation
//  validation gate BEFORE mutating the model so an invalid gesture can never
//  add an element.
//
//  Scope: pure logic + Combine/SwiftUI (ObservableObject) + CoreGraphics for
//  geometry only. No AppKit, no networking, no NSWindow — all auxiliary UI is
//  in-window (S-A6). Follows the established @MainActor view-model pattern used
//  by CodeEditorViewModel.
//

import Combine
import CoreGraphics
import SwiftUI

@MainActor
final class WhiteboardViewModel: ObservableObject {

    // MARK: - Model

    /// The single owned stroke model. Exposed so the Canvas can observe it
    /// directly for committed elements; this view model re-publishes the
    /// model's changes (see `init`) so views observing the view model also
    /// refresh when committed `elements` change.
    let model = StrokeModel()

    // MARK: - Tuning constants

    /// M1 mitigation: the minimum distance (in points) a new freehand point
    /// must be from the last retained point before it is kept. Coalescing on
    /// this threshold bounds the per-stroke point count so the off-screen
    /// `Canvas` redraw stays cheap at the 10 fps capture rate.
    static let freehandMinPointDistance: CGFloat = 1.5

    /// The minimum width AND height (in points) a shape drag must span before a
    /// shape element is created (R8.1 / R8.2).
    static let minShapeExtent: CGFloat = 4.0

    /// The hard cap on text-element character count (R8.7).
    static let maxTextLength = 256

    /// How long the transient "shape not created" indication stays visible
    /// before it auto-dismisses (R8.2). In-window state only — never an alert.
    private static let shapeNotCreatedDisplaySeconds: UInt64 = 1

    // MARK: - Published overlay / preview state

    /// In-progress freehand path, published so the Canvas can render the live
    /// stroke while the pointer is dragging (R7.4). `nil` when not drawing.
    @Published private(set) var inProgressStroke: [CGPoint]?

    /// In-progress shape rubber-band rect, published so the Canvas can render
    /// the shape preview while dragging. `nil` when not dragging a shape.
    @Published private(set) var inProgressShape: CGRect?

    /// Transient in-window flag the view shows when a shape drag was too small
    /// to create an element (R8.2). Auto-clears after a short delay.
    @Published private(set) var shapeNotCreated = false

    /// The geometric kind used for the next shape element. The model's
    /// `WhiteboardTool` only distinguishes `.shape` generically, so the
    /// concrete kind (rectangle / ellipse / line) is tracked here and chosen
    /// from the in-window tool selector (task 5.2).
    @Published var activeShapeKind: ShapeKind = .rectangle

    // MARK: - Active tool / color (bound through to the model)

    /// The active drawing tool, bound straight through to the model so a single
    /// source of truth drives both gesture routing and element creation.
    var activeTool: WhiteboardTool {
        get { model.activeTool }
        set {
            objectWillChange.send()
            model.activeTool = newValue
        }
    }

    /// The active drawing color applied to created freehand / shape / text
    /// elements (R8.8, R8.9), bound straight through to the model.
    var activeColor: WhiteboardColor {
        get { model.activeColor }
        set {
            objectWillChange.send()
            model.activeColor = newValue
        }
    }

    /// The committed elements in draw order, for rendering (R7.1).
    var elements: [WhiteboardElement] {
        model.elements
    }

    // MARK: - Private state

    /// Accumulated, already-coalesced freehand points for the active stroke.
    private var freehandPoints: [CGPoint] = []

    /// The anchor point where the current shape drag began.
    private var shapeDragStart: CGPoint?

    /// Re-publish subscription so views observing this view model also update
    /// when the model's committed `elements` change.
    private var modelObservation: AnyCancellable?

    /// The pending auto-dismiss task for the "shape not created" indication.
    private var shapeNotCreatedResetTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        modelObservation = model.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    // MARK: - Tool / color selection

    /// Select the active drawing tool from the in-window tool selector.
    func selectTool(_ tool: WhiteboardTool) {
        activeTool = tool
    }

    /// Select the active drawing color from the in-window color picker (R8.8).
    func selectColor(_ color: WhiteboardColor) {
        activeColor = color
    }

    /// Select the geometric kind used for subsequently drawn shapes.
    func selectShapeKind(_ kind: ShapeKind) {
        activeShapeKind = kind
    }

    // MARK: - Freehand gesture

    /// Begin a freehand stroke at `point`. Starts accumulating the (coalesced)
    /// path; no element is created until release.
    func beginFreehandStroke(at point: CGPoint) {
        freehandPoints = [point]
        inProgressStroke = freehandPoints
    }

    /// Append `point` to the in-progress freehand stroke.
    ///
    /// M1 mitigation: the point is retained only when it is at least
    /// `freehandMinPointDistance` (~1.5 pt) from the last retained point. This
    /// coalescing bounds the per-stroke point count so the off-screen `Canvas`
    /// redraw stays cheap under the 10 fps capture loop.
    func appendFreehandPoint(_ point: CGPoint) {
        guard let last = freehandPoints.last else {
            // No active stroke; treat as an implicit begin.
            beginFreehandStroke(at: point)
            return
        }
        // M1 mitigation: drop points closer than the minimum distance.
        if Self.distance(last, point) < Self.freehandMinPointDistance {
            return
        }
        freehandPoints.append(point)
        inProgressStroke = freehandPoints
    }

    /// End the freehand stroke. On a real stroke, adds exactly ONE freehand
    /// element carrying the active color (R7.5). A zero-length path — a
    /// press/release with no movement, or all points within negligible distance
    /// (which coalescing collapses to a single retained point) — adds NO
    /// element and leaves the model unchanged (R7.6).
    func endFreehandStroke() {
        defer {
            freehandPoints = []
            inProgressStroke = nil
        }
        // After coalescing, a real stroke has at least two retained points;
        // a zero-length path retains only its single starting point.
        guard freehandPoints.count >= 2 else { return }
        let element = WhiteboardElement(
            kind: .freehand(points: freehandPoints),
            color: model.activeColor
        )
        model.add(element)
    }

    // MARK: - Shape gesture

    /// Begin a shape drag at `point`, recording the anchor for the rubber-band.
    func beginShapeDrag(at point: CGPoint) {
        shapeDragStart = point
        inProgressShape = CGRect(origin: point, size: .zero)
    }

    /// Update the in-progress shape drag to `point`, publishing the current
    /// rubber-band rect for the Canvas preview.
    func updateShapeDrag(to point: CGPoint) {
        guard let start = shapeDragStart else { return }
        inProgressShape = Self.rect(from: start, to: point)
    }

    /// Commit the shape drag. When the drag extent spans at least
    /// `minShapeExtent` in BOTH width and height, adds exactly ONE shape element
    /// sized to the drag extent and carrying the active color (R8.1). When the
    /// width OR height is below the threshold, adds NO element and surfaces the
    /// transient in-window "shape not created" indication (R8.2).
    func commitShapeDrag(at point: CGPoint) {
        defer {
            shapeDragStart = nil
            inProgressShape = nil
        }
        guard let start = shapeDragStart else { return }
        let rect = Self.rect(from: start, to: point)
        guard rect.width >= Self.minShapeExtent, rect.height >= Self.minShapeExtent else {
            // R8.2: too small — create nothing and flag the in-window indication.
            flagShapeNotCreated()
            return
        }
        let element = WhiteboardElement(
            kind: .shape(rect: rect, kind: activeShapeKind),
            color: model.activeColor
        )
        model.add(element)
    }

    // MARK: - Text placement

    /// Limit raw text input to at most `maxTextLength` characters (R8.7). The
    /// in-window text field calls this to cap entry as the candidate types.
    func limitTextInput(_ raw: String) -> String {
        guard raw.count > Self.maxTextLength else { return raw }
        return String(raw.prefix(Self.maxTextLength))
    }

    /// Place text at `point`. A non-empty string of 1...256 characters adds
    /// exactly ONE text element carrying the active color at the placement
    /// location (R8.5, R8.9). Empty text adds NO element and leaves the model
    /// unchanged (R8.6). Input longer than 256 characters is capped (R8.7).
    func placeText(_ string: String, at point: CGPoint) {
        let capped = limitTextInput(string)
        guard !capped.isEmpty else { return }   // R8.6: empty → no element.
        let element = WhiteboardElement(
            kind: .text(string: capped, origin: point),
            color: model.activeColor
        )
        model.add(element)
    }

    // MARK: - Eraser

    /// Act with the eraser at `point`: remove the topmost element under the
    /// point when one is hit (R8.3) and leave the model unchanged when the point
    /// hits no element (R8.4). Delegates hit-testing to the model.
    func eraseAt(_ point: CGPoint) {
        guard let index = model.hitTest(point) else { return }
        model.removeElement(at: index)
    }

    // MARK: - Undo / redo passthroughs

    /// Revert the most recent reversible change (R9.1, R9.3). A thin passthrough
    /// to the model so the in-window undo button has a stable view-model entry
    /// point; the model re-publish keeps the Canvas in sync. No-op on empty
    /// history. (Added for task 5.2 — does not change any existing signature.)
    func undo() {
        model.undo()
    }

    /// Reapply the most recently reverted change (R9.2, R9.4). A thin passthrough
    /// to the model for the in-window redo button. No-op on empty history.
    /// (Added for task 5.2 — does not change any existing signature.)
    func redo() {
        model.redo()
    }

    // MARK: - Bridge entry points

    /// Empty the whiteboard, delegating to the model's clear (R9.5). Also clears
    /// any in-progress gesture / transient state so a cleared canvas is fully
    /// reset.
    func clear() {
        model.clear()
        resetTransientState()
    }

    /// Detach for the bridge teardown (R3.6): cancel any pending transient task
    /// and drop in-progress gesture state. Holds no closures afterward beyond
    /// the model re-publish subscription, which is released here too.
    func detach() {
        resetTransientState()
        modelObservation?.cancel()
        modelObservation = nil
    }

    // MARK: - Private helpers

    /// Raise the transient "shape not created" indication and schedule its
    /// auto-dismiss. In-window state only — no alert / NSWindow (R8.2, S-A6).
    private func flagShapeNotCreated() {
        shapeNotCreated = true
        shapeNotCreatedResetTask?.cancel()
        shapeNotCreatedResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.shapeNotCreatedDisplaySeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.shapeNotCreated = false
        }
    }

    /// Clear all in-progress gesture and transient indication state.
    private func resetTransientState() {
        shapeNotCreatedResetTask?.cancel()
        shapeNotCreatedResetTask = nil
        shapeNotCreated = false
        freehandPoints = []
        inProgressStroke = nil
        shapeDragStart = nil
        inProgressShape = nil
    }

    /// Build the normalized drag-extent rect spanning two points.
    private static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    /// Euclidean distance between two points.
    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
