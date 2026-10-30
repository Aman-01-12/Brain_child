//
//  WhiteboardRootView.swift
//  inter
//
//  SwiftUI `Canvas` + in-window overlays for the secure-interview COLLABORATIVE
//  whiteboard. Hosted by the bridge's `NSHostingView<WhiteboardRootView>`.
//
//  Responsibilities:
//    - Render the board through the LOCAL pan/zoom transform (R5.2): a gridded
//      dark surface, every `document.renderedElements` element in zKey order —
//      freehand / rectangle / ellipse / line / ARROW with a hand-drawn (sketchy)
//      stroke style and per-element color/width (R1.2, R1.3), and text elements.
//    - Draw the SELECTION overlay (bounding box, 8 resize handles, rotate
//      handle) and the marquee rectangle as in-window overlays (R3.3, R7.6).
//    - Route the full pointer gesture set to the view model (select / marquee /
//      move / resize / rotate / freehand / shape / arrow / eraser / text), plus
//      command-drag PAN and pinch/zoom-button ZOOM (R5.1).
//    - Present ALL auxiliary UI — tool selector (incl. Arrow + Select), color
//      palette, stroke-width control, group/ungroup, z-order, delete,
//      undo/redo/clear, zoom — as in-window overlays (R1.4, R7.6).
//    - Draw labelled remote cursors + remote-selection overlays (R2.4).
//
//  Security invariants (S-A6 / R7):
//    - NO `Menu`, `.popover`, `.sheet`, `.contextMenu`, or alert anywhere — none
//      may spawn a separate `NSWindow`/`NSPanel` (R7.6).
//    - Inline text entry goes through the hardened `SecureWhiteboardTextField`
//      (literal entry, sanitised menu, no panels).
//    - NO `.drawingGroup()` anywhere — a GPU-only path would defeat
//      `cacheDisplayInRect:` capture (R7.2).
//
//  The model stays pure: the WhiteboardColor → SwiftUI Color mapping lives here.
//

import AppKit
import SwiftUI

struct WhiteboardRootView: View {

    @ObservedObject var viewModel: WhiteboardViewModel

    // MARK: Visual constants

    private let backgroundColor = Color(white: 0.09)
    private let cornerRadius: CGFloat = 16.0
    private let borderColor = Color(white: 1.0).opacity(0.08)
    private let gridColor = Color(white: 1.0).opacity(0.05)
    private let gridSpacing: CGFloat = 32.0
    private let selectionColor = Color(red: 0.27, green: 0.55, blue: 0.93)
    private let handleSize: CGFloat = 8.0
    private let textFontSize: CGFloat = 16.0

    // MARK: Gesture / overlay state

    @State private var isGestureActive = false
    @State private var lastHoverScreen: CGPoint?
    @State private var canvasSize: CGSize = .zero
    @State private var panBase: CGSize?
    @State private var magnifyBase: CGFloat?

    // Inline text-entry overlay state.
    @State private var textEntryScreen: CGPoint?
    @State private var textEntryWorld: CGPoint?
    @State private var textEntryValue: String = ""
    @State private var textEntryEditingID: BoardElementID?
    @State private var textEntrySize: CGSize = CGSize(width: 24, height: 24)
    @State private var textEntryColor: WhiteboardColor = .white

    var body: some View {
        ZStack {
            backgroundColor

            canvas
                .highPriorityGesture(panGesture)
                .gesture(pointerGesture)
                .gesture(zoomGesture)
                .onContinuousHover { phase in
                    if case .active(let p) = phase { lastHoverScreen = p }
                }

            overlays
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1.0)
        )
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geo in
            Canvas { context, size in
                // Touch boardVersion so the Canvas re-renders on every mutation.
                _ = viewModel.boardVersion

                // World-space layer: pan + zoom transform applied once.
                var world = context
                world.translateBy(x: viewModel.viewport.offset.width,
                                  y: viewModel.viewport.offset.height)
                world.scaleBy(x: viewModel.viewport.scale, y: viewModel.viewport.scale)

                drawGrid(in: &world, size: size)
                drawElements(in: &world)
                drawPreview(in: &world)

                // Screen-space overlays (handles/marquee).
                drawSelectionOverlay(in: &context)
                drawMarquee(in: &context)
            }
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { canvasSize = $0 }
        }
        // NOTE: deliberately NO `.drawingGroup()` here (R7.2).
    }

    // MARK: Grid

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        let scale = viewModel.viewport.scale
        let topLeft = viewModel.toWorld(.zero)
        let bottomRight = viewModel.toWorld(CGPoint(x: size.width, y: size.height))
        var grid = Path()

        var x = (topLeft.x / gridSpacing).rounded(.down) * gridSpacing
        while x <= bottomRight.x {
            grid.move(to: CGPoint(x: x, y: topLeft.y))
            grid.addLine(to: CGPoint(x: x, y: bottomRight.y))
            x += gridSpacing
        }
        var y = (topLeft.y / gridSpacing).rounded(.down) * gridSpacing
        while y <= bottomRight.y {
            grid.move(to: CGPoint(x: topLeft.x, y: y))
            grid.addLine(to: CGPoint(x: bottomRight.x, y: y))
            y += gridSpacing
        }
        context.stroke(grid, with: .color(gridColor), lineWidth: 1.0 / max(scale, 0.001))
    }

    // MARK: Elements

    private func drawElements(in context: inout GraphicsContext) {
        for element in viewModel.renderedElements {
            drawElement(element, in: &context)
        }
    }

    private func drawElement(_ element: BoardElement, in context: inout GraphicsContext) {
        let color = Self.swiftUIColor(for: element.strokeColor)
        let width = max(0.5, element.strokeWidth)
        let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        let seed = element.id.hashValue

        switch element.kind {
        case .freehand:
            guard let points = element.points else { return }
            context.stroke(polyPath(points), with: .color(color), style: style)

        case .line:
            guard let points = element.points, points.count >= 2 else { return }
            context.stroke(sketchySegment(points[0], points[points.count - 1], seed: seed),
                           with: .color(color), style: style)

        case .arrow:
            guard let points = element.points, points.count >= 2 else { return }
            let a = points[0], b = points[points.count - 1]
            var path = sketchySegment(a, b, seed: seed)
            path.addPath(arrowHead(from: a, to: b))
            context.stroke(path, with: .color(color), style: style)

        case .rectangle, .ellipse, .text:
            guard let frame = element.frame else { return }
            var c = context
            if element.rotation != 0 {
                let center = CGPoint(x: frame.midX, y: frame.midY)
                c.translateBy(x: center.x, y: center.y)
                c.rotate(by: .radians(Double(element.rotation)))
                c.translateBy(x: -center.x, y: -center.y)
            }
            switch element.kind {
            case .rectangle:
                c.stroke(sketchyRect(frame, seed: seed), with: .color(color), style: style)
            case .ellipse:
                c.stroke(sketchyEllipse(frame, seed: seed), with: .color(color), style: style)
            case .text:
                let text = Text(element.text ?? "")
                    .font(.system(size: textFontSize, design: .monospaced))
                    .foregroundColor(color)
                c.draw(text, at: frame.origin, anchor: .topLeading)
            default:
                break
            }
        }
    }

    // MARK: Live preview

    private func drawPreview(in context: inout GraphicsContext) {
        guard let preview = viewModel.drawPreview else { return }
        let color = Self.swiftUIColor(for: viewModel.activeColor)
        let style = StrokeStyle(lineWidth: max(0.5, viewModel.activeStrokeWidth),
                                lineCap: .round, lineJoin: .round)
        let dashed = StrokeStyle(lineWidth: max(0.5, viewModel.activeStrokeWidth),
                                 lineCap: .round, lineJoin: .round, dash: [6, 4])
        switch preview {
        case .stroke(let points):
            context.stroke(polyPath(points), with: .color(color), style: style)
        case .frame(let rect, let kind):
            let path = kind == .ellipse ? Path(ellipseIn: rect.standardized)
                                        : Path(rect.standardized)
            context.stroke(path, with: .color(color), style: dashed)
        case .segment(let a, let b, let kind):
            var path = Path()
            path.move(to: a); path.addLine(to: b)
            if kind == .arrow { path.addPath(arrowHead(from: a, to: b)) }
            context.stroke(path, with: .color(color), style: style)
        }
    }

    // MARK: Selection overlay (R3.3)

    private func drawSelectionOverlay(in context: inout GraphicsContext) {
        guard viewModel.activeTool == .select, let handles = viewModel.selectionHandles() else { return }
        let box = screenRect(handles.boundingBox)

        context.stroke(Path(box), with: .color(selectionColor),
                       style: StrokeStyle(lineWidth: 1.0, dash: [4, 3]))

        // Rotate handle: a line up to a circle.
        let rotate = viewModel.toScreen(handles.rotateHandle)
        var stem = Path()
        stem.move(to: CGPoint(x: box.midX, y: box.minY))
        stem.addLine(to: rotate)
        context.stroke(stem, with: .color(selectionColor), lineWidth: 1.0)
        let rotateRect = CGRect(x: rotate.x - handleSize / 2, y: rotate.y - handleSize / 2,
                                width: handleSize, height: handleSize)
        context.fill(Path(ellipseIn: rotateRect), with: .color(selectionColor))

        // Resize handles: small filled squares.
        for (_, world) in handles.resizeHandles {
            let p = viewModel.toScreen(world)
            let r = CGRect(x: p.x - handleSize / 2, y: p.y - handleSize / 2,
                           width: handleSize, height: handleSize)
            context.fill(Path(r), with: .color(.white))
            context.stroke(Path(r), with: .color(selectionColor), lineWidth: 1.0)
        }
    }

    private func drawMarquee(in context: inout GraphicsContext) {
        guard let rect = viewModel.marqueeRect else { return }
        let screen = screenRect(rect)
        context.fill(Path(screen), with: .color(selectionColor.opacity(0.12)))
        context.stroke(Path(screen), with: .color(selectionColor),
                       style: StrokeStyle(lineWidth: 1.0, dash: [4, 3]))
    }

    // MARK: - Pointer gesture

    private var pointerGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // Belt-and-suspenders: a new pointer-down while an inline text entry is in
                // progress commits it through the existing single commitTextEntry() → commitText
                // path (idempotent with the first-responder-resign path) so the commit stays
                // single-sourced — no separate commit logic is introduced here.
                if !isGestureActive, textEntryScreen != nil {
                    commitTextEntry()
                }
                guard !NSEvent.modifierFlags.contains(.command) else { return }
                guard viewModel.activeTool != .text else { return }
                if isGestureActive {
                    viewModel.pointerDragged(toScreen: value.location)
                } else {
                    viewModel.pointerDown(atScreen: value.location,
                                          additive: NSEvent.modifierFlags.contains(.shift))
                    isGestureActive = true
                }
            }
            .onEnded { value in
                if viewModel.activeTool == .text {
                    openTextEntry(atScreen: value.location)
                } else if isGestureActive {
                    viewModel.pointerUp(atScreen: value.location)
                }
                isGestureActive = false
            }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .modifiers(.command)
            .onChanged { value in
                let base = panBase ?? viewModel.viewport.offset
                if panBase == nil { panBase = base }
                viewModel.viewport.offset = CGSize(width: base.width + value.translation.width,
                                                   height: base.height + value.translation.height)
            }
            .onEnded { _ in panBase = nil }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                let base = magnifyBase ?? viewModel.viewport.scale
                if magnifyBase == nil { magnifyBase = base }
                let target = base * scale
                let factor = target / viewModel.viewport.scale
                viewModel.zoom(by: factor, aboutScreen: zoomPivot)
            }
            .onEnded { _ in magnifyBase = nil }
    }

    private var zoomPivot: CGPoint {
        lastHoverScreen ?? CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
    }

    // MARK: - In-window overlays

    @ViewBuilder
    private var overlays: some View {
        VStack(alignment: .leading) {
            // Top toolbars. Stacked vertically (NOT in an HStack + Spacer): a
            // Spacer hands each group its full one-row ideal width, which defeats
            // the per-group FlowLayout wrapping and clips on narrow / portrait
            // boards. As direct VStack children each group is instead offered the
            // real (possibly narrow) board width, so its FlowLayout wraps to fit.
            VStack(alignment: .leading, spacing: 8) {
                toolSelector
                historyControls
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 8)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    colorPalette
                    strokeWidthControl
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 8) {
                    if viewModel.hasSelection { selectionActions }
                    zoomControls
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)

        if let notice = viewModel.transientNotice {
            noticeBanner(notice)
        }

        if let screen = textEntryScreen {
            textEntryOverlay
                .frame(width: max(24, textEntrySize.width), height: max(24, textEntrySize.height))
                .position(x: screen.x + max(24, textEntrySize.width) / 2,
                          y: screen.y + max(24, textEntrySize.height) / 2)
        }
    }

    // MARK: Tool selector

    private var toolSelector: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            toolButton(.select, "Select")
            toolButton(.freehand, "Pen")
            toolButton(.rectangle, "Rect")
            toolButton(.ellipse, "Ellipse")
            toolButton(.line, "Line")
            toolButton(.arrow, "Arrow")
            toolButton(.eraser, "Eraser")
            toolButton(.text, "Text")
        }
        .padding(6)
        .background(overlayBackground)
    }

    private func toolButton(_ tool: WhiteboardToolKind, _ label: String) -> some View {
        Button { viewModel.selectTool(tool) } label: {
            chrome(label, active: viewModel.activeTool == tool)
        }
        .buttonStyle(.plain)
    }

    // MARK: History controls

    private var historyControls: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            controlButton("Undo") { viewModel.undo() }
            controlButton("Redo") { viewModel.redo() }
            controlButton("Clear") { viewModel.clear() }
        }
        .padding(6)
        .background(overlayBackground)
    }

    // MARK: Selection actions (group / z-order / delete)

    private var selectionActions: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            controlButton("Group") { viewModel.groupSelection() }
            controlButton("Ungroup") { viewModel.ungroupSelection() }
            controlButton("Front") { viewModel.bringSelectionToFront() }
            controlButton("Back") { viewModel.sendSelectionToBack() }
            controlButton("Fwd") { viewModel.bringSelectionForward() }
            controlButton("Bwd") { viewModel.sendSelectionBackward() }
            controlButton("Delete") { viewModel.deleteSelection() }
        }
        .padding(6)
        .background(overlayBackground)
    }

    // MARK: Zoom controls

    private var zoomControls: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            controlButton("−") { viewModel.zoomOut(aboutScreen: zoomPivot) }
            controlButton("Reset") { viewModel.resetViewport() }
            controlButton("+") { viewModel.zoomIn(aboutScreen: zoomPivot) }
        }
        .padding(6)
        .background(overlayBackground)
    }

    // MARK: Color palette

    private var colorPalette: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(WhiteboardColor.allCases, id: \.self) { color in
                Button { viewModel.selectColor(color) } label: {
                    Circle()
                        .fill(Self.swiftUIColor(for: color))
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle().strokeBorder(
                                Color.white.opacity(viewModel.activeColor == color ? 0.95 : 0.25),
                                lineWidth: viewModel.activeColor == color ? 2.0 : 1.0)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(overlayBackground)
    }

    // MARK: Stroke-width control

    private var strokeWidthControl: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach([CGFloat(1), 3, 6, 10], id: \.self) { width in
                Button { viewModel.selectStrokeWidth(width) } label: {
                    Circle()
                        .fill(Color.white)
                        .frame(width: width + 6, height: width + 6)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(viewModel.activeStrokeWidth == width
                                      ? Color.white.opacity(0.22) : Color.white.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(overlayBackground)
    }

    // MARK: Inline text entry (Excalidraw-style, hardened — R4)

    private var textEntryOverlay: some View {
        SecureWhiteboardTextField(
            text: $textEntryValue,
            characterLimit: WhiteboardViewModel.maxTextLength,
            textColor: Self.nsColor(for: textEntryColor),
            onCommit: { commitTextEntry() },
            onSizeChange: { textEntrySize = $0 }
        )
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(white: 0.16).opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(selectionColor, lineWidth: 1.0)
                )
        )
    }

    private func openTextEntry(atScreen screen: CGPoint) {
        let world = viewModel.toWorld(screen)
        if let existing = viewModel.editableTextElement(atWorld: world) {
            textEntryEditingID = existing.id
            textEntryValue = existing.text ?? ""
            textEntryColor = existing.strokeColor
            let origin = existing.frame?.origin ?? world
            textEntryWorld = origin
            textEntryScreen = viewModel.toScreen(origin)
        } else {
            textEntryEditingID = nil
            textEntryValue = ""
            textEntryColor = viewModel.activeColor
            textEntryWorld = world
            textEntryScreen = screen
        }
        textEntrySize = CGSize(width: 24, height: 24)
    }

    private func commitTextEntry() {
        guard let world = textEntryWorld else { return }
        viewModel.commitText(textEntryValue, atWorld: world, editing: textEntryEditingID)
        closeTextEntry()
    }

    private func closeTextEntry() {
        textEntryScreen = nil
        textEntryWorld = nil
        textEntryEditingID = nil
        textEntryValue = ""
    }

    // MARK: Shared chrome

    private func chrome(_ label: String, active: Bool) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .fixedSize()
            .frame(minWidth: 64)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? Color.white.opacity(0.22) : Color.white.opacity(0.06))
            )
    }

    private func controlButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { chrome(label, active: false) }
            .buttonStyle(.plain)
    }

    private func noticeBanner(_ text: String) -> some View {
        VStack {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color(white: 0.0).opacity(0.6)))
                .allowsHitTesting(false)
                .padding(.top, 56)
            Spacer()
        }
    }

    private var overlayBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(white: 0.16).opacity(0.92))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1.0)
            )
    }

    // MARK: - Geometry helpers

    /// Convert a world rect to its on-screen rect under the current viewport.
    private func screenRect(_ world: CGRect) -> CGRect {
        let origin = viewModel.toScreen(world.standardized.origin)
        let scale = viewModel.viewport.scale
        return CGRect(x: origin.x, y: origin.y,
                      width: world.standardized.width * scale,
                      height: world.standardized.height * scale)
    }

    /// A simple polyline path through world points (used for freehand + preview).
    private func polyPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: first)
        } else {
            for p in points.dropFirst() { path.addLine(to: p) }
        }
        return path
    }

    // MARK: Hand-drawn (sketchy) styling (R1.3)

    /// Deterministic [-1, 1] noise from an integer seed (stable per element so
    /// the sketch does not shimmer on redraw).
    private func noise(_ seed: Int, _ index: Int) -> CGFloat {
        var x = UInt64(bitPattern: Int64(seed &* 73_856_093 &+ index &* 19_349_663))
        x ^= x >> 29
        x = x &* 0x9E37_79B9_7F4A_7C15
        x ^= x >> 32
        return CGFloat(Double(x % 2000) / 1000.0 - 1.0)
    }

    private func jitterMagnitude(for rect: CGRect) -> CGFloat {
        min(2.5, max(0.8, min(rect.width, rect.height) * 0.02))
    }

    private func sketchyRect(_ frame: CGRect, seed: Int) -> Path {
        let r = frame.standardized
        let j = jitterMagnitude(for: r)
        let corners = [
            CGPoint(x: r.minX, y: r.minY),
            CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.maxX, y: r.maxY),
            CGPoint(x: r.minX, y: r.maxY)
        ]
        var path = Path()
        for (i, c) in corners.enumerated() {
            let p = CGPoint(x: c.x + noise(seed, i * 2) * j, y: c.y + noise(seed, i * 2 + 1) * j)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    private func sketchyEllipse(_ frame: CGRect, seed: Int) -> Path {
        let r = frame.standardized
        let cx = r.midX, cy = r.midY
        let rx = r.width / 2, ry = r.height / 2
        let j = jitterMagnitude(for: r)
        let steps = 24
        var path = Path()
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
            let p = CGPoint(x: cx + cos(t) * rx + noise(seed, i) * j,
                            y: cy + sin(t) * ry + noise(seed, i + 100) * j)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    private func sketchySegment(_ a: CGPoint, _ b: CGPoint, seed: Int) -> Path {
        let mid = CGPoint(x: (a.x + b.x) / 2 + noise(seed, 1) * 1.5,
                          y: (a.y + b.y) / 2 + noise(seed, 2) * 1.5)
        var path = Path()
        path.move(to: a)
        path.addQuadCurve(to: b, control: mid)
        return path
    }

    private func arrowHead(from a: CGPoint, to b: CGPoint) -> Path {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let length: CGFloat = 14
        let spread: CGFloat = .pi / 7
        var path = Path()
        path.move(to: b)
        path.addLine(to: CGPoint(x: b.x - length * cos(angle - spread),
                                 y: b.y - length * sin(angle - spread)))
        path.move(to: b)
        path.addLine(to: CGPoint(x: b.x - length * cos(angle + spread),
                                 y: b.y - length * sin(angle + spread)))
        return path
    }

    // MARK: - Color mapping (view layer only; the model stays pure)

    static func swiftUIColor(for color: WhiteboardColor) -> Color {
        switch color {
        case .white:  return Color(white: 0.96)
        case .red:    return Color(red: 0.93, green: 0.27, blue: 0.27)
        case .orange: return Color(red: 0.96, green: 0.55, blue: 0.20)
        case .yellow: return Color(red: 0.96, green: 0.83, blue: 0.28)
        case .green:  return Color(red: 0.30, green: 0.78, blue: 0.42)
        case .blue:   return Color(red: 0.27, green: 0.55, blue: 0.93)
        case .purple: return Color(red: 0.62, green: 0.40, blue: 0.93)
        case .black:  return Color(white: 0.0)
        }
    }

    /// AppKit mirror of `swiftUIColor(for:)` for the inline field editor, kept in
    /// lock-step with the SwiftUI mapping above so the edit overlay and the canvas
    /// render identical ink. Exhaustive over `WhiteboardColor` (no `default`).
    static func nsColor(for color: WhiteboardColor) -> NSColor {
        switch color {
        case .white:  return NSColor(calibratedWhite: 0.96, alpha: 1.0)
        case .red:    return NSColor(srgbRed: 0.93, green: 0.27, blue: 0.27, alpha: 1.0)
        case .orange: return NSColor(srgbRed: 0.96, green: 0.55, blue: 0.20, alpha: 1.0)
        case .yellow: return NSColor(srgbRed: 0.96, green: 0.83, blue: 0.28, alpha: 1.0)
        case .green:  return NSColor(srgbRed: 0.30, green: 0.78, blue: 0.42, alpha: 1.0)
        case .blue:   return NSColor(srgbRed: 0.27, green: 0.55, blue: 0.93, alpha: 1.0)
        case .purple: return NSColor(srgbRed: 0.62, green: 0.40, blue: 0.93, alpha: 1.0)
        case .black:  return NSColor(calibratedWhite: 0.0, alpha: 1.0)
        }
    }
}

// MARK: - FlowLayout (wrapping toolbar row)

/// A left-to-right layout that wraps its subviews onto additional rows when the
/// proposed width is exceeded, so the whiteboard's toolbar groups never clip on
/// narrow / portrait boards (the per-button chrome — uniform min-width,
/// `.fixedSize()`, no truncation — is unchanged; only the ROW now wraps).
///
/// Replaces the fixed `HStack` in each toolbar group. Because it honours the
/// proposed width in both `sizeThatFits` and `placeSubviews`, putting a group in
/// a context that hands it the real (possibly narrow) board width — e.g. a plain
/// `VStack` child rather than an `HStack` + `Spacer` — makes it wrap to fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height }
            + CGFloat(max(0, rows.count - 1)) * lineSpacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y),
                                      anchor: .topLeading,
                                      proposal: ProposedViewSize(width: size.width, height: size.height))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let advance = (current.indices.isEmpty ? 0 : spacing) + size.width
            if !current.indices.isEmpty && current.width + advance > maxWidth {
                rows.append(current)
                current = Row(indices: [index], width: size.width, height: size.height)
            } else {
                current.width += advance
                current.height = max(current.height, size.height)
                current.indices.append(index)
            }
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }
}
