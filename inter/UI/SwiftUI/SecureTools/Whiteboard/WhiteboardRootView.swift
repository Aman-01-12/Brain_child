//
//  WhiteboardRootView.swift
//  inter
//
//  SwiftUI Canvas + in-window overlays for the secure-interview whiteboard
//  (Whiteboard). This is the rootView hosted by the bridge's
//  NSHostingView<WhiteboardRootView> (task 5.2).
//
//  Responsibilities:
//    - Render the whiteboard surface with a SwiftUI `Canvas`: a white @ 0.09
//      background with a 16pt corner radius (R7.2), a 32pt reference grid across
//      the full bounds (R7.3, matching the AppKit InterSecureWhiteboardView),
//      every committed `StrokeModel` element in draw order (freehand strokes at
//      3pt width R7.4; rectangle / ellipse / line shapes; text elements) using
//      each element's color, plus the live in-progress stroke / shape preview.
//    - Route pointer input through a single `DragGesture(minimumDistance: 0)` to
//      the active tool: freehand append, shape rubber-band, eraser hit-erase,
//      and text placement (R7.5, R8.1, R8.3, R8.5).
//    - Present ALL auxiliary UI — tool selector, color picker, shape-kind
//      selector, undo/redo/clear, and the text-entry field — as in-window
//      overlays inside this view's `ZStack`, within the host bounds so the
//      Snapshot_Source captures them (R10.2, R10.3, R10.4).
//
//  Security invariants (S-A6):
//    - NO `Menu`, `.popover`, `.sheet`, `.contextMenu`, or alert anywhere — none
//      of which may spawn a separate `NSWindow`/`NSPanel` (R10.5, R10.6).
//    - The text-entry field is hardened (H2): autocorrection / spell-check /
//      substitutions are disabled so entered text is stored literally and no
//      spelling/substitutions `NSPanel` can open.
//    - NO `.drawingGroup()` anywhere in this subtree — the capture pipeline
//      relies on cacheDisplayInRect: reproducing the hosted SwiftUI content, and
//      a GPU-only path would defeat that (R2.3).
//
//  The model stays pure: WhiteboardColor → SwiftUI Color mapping lives here, in
//  the view layer, never in the model.
//

import SwiftUI

struct WhiteboardRootView: View {

    @ObservedObject var viewModel: WhiteboardViewModel

    // MARK: Visual constants

    /// Whiteboard background: white @ 0.09 brightness (R7.2). Matches the AppKit
    /// InterSecureWhiteboardView fill.
    private let backgroundColor = Color(white: 0.09)
    /// Corner radius applied to the whiteboard surface (R7.2).
    private let cornerRadius: CGFloat = 16.0
    /// 1pt border, white @ 0.08 alpha — mirrors the AppKit border.
    private let borderColor = Color(white: 1.0).opacity(0.08)
    /// Reference grid line color: white @ 0.05 alpha (matches the AppKit grid).
    private let gridColor = Color(white: 1.0).opacity(0.05)
    /// Reference grid spacing in points (R7.3).
    private let gridSpacing: CGFloat = 32.0
    /// Freehand / shape stroke width in points (R7.4).
    private let strokeWidth: CGFloat = 3.0
    /// Point size used to render text elements (matches the model's hit-test
    /// glyph metrics estimate).
    private let textFontSize: CGFloat = 14.0

    // MARK: Gesture / overlay state

    /// Tracks whether the current pointer drag has already begun a gesture, so
    /// the first `onChanged` starts the stroke / shape and later changes append
    /// or update it.
    @State private var isGestureActive = false

    /// Where the text-entry overlay is anchored (in canvas coordinates) while
    /// the text tool is placing text. `nil` hides the overlay.
    @State private var textEntryLocation: CGPoint?

    /// The in-progress text-entry buffer for the in-window text field.
    @State private var textEntryValue: String = ""

    var body: some View {
        ZStack {
            // Whiteboard surface background (white @ 0.09) behind the Canvas.
            backgroundColor

            canvas
                .gesture(pointerGesture)

            // In-window overlays (R10.3): all auxiliary controls live inside the
            // host bounds so the Snapshot_Source captures them. No new window.
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
        Canvas { context, size in
            drawGrid(in: context, size: size)
            drawElements(in: &context)
            drawInProgress(in: &context)
        }
        // NOTE: deliberately NO `.drawingGroup()` here (R2.3).
    }

    /// Draw the 32pt reference grid across the full bounds (R7.3).
    private func drawGrid(in context: GraphicsContext, size: CGSize) {
        var grid = Path()
        var x: CGFloat = 0
        while x <= size.width {
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
            x += gridSpacing
        }
        var y: CGFloat = 0
        while y <= size.height {
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
            y += gridSpacing
        }
        context.stroke(grid, with: .color(gridColor), lineWidth: 1.0)
    }

    /// Draw every committed element in draw order, each in its own color (R7.1).
    private func drawElements(in context: inout GraphicsContext) {
        for element in viewModel.elements {
            let color = Self.swiftUIColor(for: element.color)
            switch element.kind {
            case .freehand(let points):
                context.stroke(freehandPath(points), with: .color(color),
                               style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round))
            case .shape(let rect, let kind):
                context.stroke(shapePath(rect, kind: kind), with: .color(color),
                               style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round))
            case .text(let string, let origin):
                let text = Text(string)
                    .font(.system(size: textFontSize, design: .monospaced))
                    .foregroundColor(color)
                context.draw(text, at: origin, anchor: .topLeading)
            }
        }
    }

    /// Draw the live in-progress freehand stroke and shape rubber-band preview
    /// in the active color (R7.4).
    private func drawInProgress(in context: inout GraphicsContext) {
        let color = Self.swiftUIColor(for: viewModel.activeColor)
        if let points = viewModel.inProgressStroke, points.count >= 1 {
            context.stroke(freehandPath(points), with: .color(color),
                           style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round))
        }
        if let rect = viewModel.inProgressShape {
            context.stroke(shapePath(rect, kind: viewModel.activeShapeKind), with: .color(color),
                           style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round,
                                              dash: [6, 4]))
        }
    }

    /// Build a freehand path through the retained points.
    private func freehandPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            // A single point: draw a tiny segment so a dot is visible.
            path.addLine(to: first)
        } else {
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
        return path
    }

    /// Build a shape path for the given rect and kind. A `.line` is drawn along
    /// the rect's origin → opposite-corner diagonal, matching the model's
    /// hit-testing (StrokeModel.shapeContains).
    private func shapePath(_ rect: CGRect, kind: ShapeKind) -> Path {
        switch kind {
        case .rectangle:
            return Path(roundedRect: rect.standardized, cornerRadius: 0)
        case .ellipse:
            return Path(ellipseIn: rect.standardized)
        case .line:
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            return path
        }
    }

    // MARK: - Pointer gesture

    /// A single drag gesture routed to the active tool. `onChanged` accumulates
    /// (freehand append / shape rubber-band / eraser hit-erase); `onEnded`
    /// commits (freehand / shape) or handles tap (eraser / text).
    private var pointerGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = value.location
                switch viewModel.activeTool {
                case .freehand:
                    if isGestureActive {
                        viewModel.appendFreehandPoint(point)
                    } else {
                        viewModel.beginFreehandStroke(at: point)
                        isGestureActive = true
                    }
                case .shape:
                    if isGestureActive {
                        viewModel.updateShapeDrag(to: point)
                    } else {
                        viewModel.beginShapeDrag(at: point)
                        isGestureActive = true
                    }
                case .eraser:
                    viewModel.eraseAt(point)
                    isGestureActive = true
                case .text:
                    isGestureActive = true
                }
            }
            .onEnded { value in
                let point = value.location
                switch viewModel.activeTool {
                case .freehand:
                    viewModel.endFreehandStroke()
                case .shape:
                    viewModel.commitShapeDrag(at: point)
                case .eraser:
                    // No erase here: `onChanged` already fires on touch-down (the
                    // gesture's minimumDistance is 0), so a tap erases exactly once
                    // and a drag erases along its path. Erasing again on `onEnded`
                    // would remove a SECOND stacked element on a single tap (W2).
                    break
                case .text:
                    // Show the in-window text-entry overlay at the tap location;
                    // the actual element is created on confirm (R8.5).
                    textEntryValue = ""
                    textEntryLocation = point
                }
                isGestureActive = false
            }
    }

    // MARK: - In-window overlays

    @ViewBuilder
    private var overlays: some View {
        // Top toolbar: tool selector + undo/redo/clear.
        VStack {
            HStack(alignment: .top) {
                toolSelector
                Spacer()
                historyControls
            }
            Spacer()
            // Bottom toolbar: color picker + (when relevant) shape-kind selector.
            HStack(alignment: .bottom) {
                colorPicker
                Spacer()
                if viewModel.activeTool == .shape {
                    shapeKindSelector
                }
            }
        }
        .padding(12)

        // Transient "shape not created" indication (R8.2) — in-window banner.
        if viewModel.shapeNotCreated {
            Text("Shape too small — not created")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(Color(white: 0.0).opacity(0.6))
                )
                .allowsHitTesting(false)
        }

        // Text-entry overlay (H2-hardened) anchored at the tap location.
        if let location = textEntryLocation {
            textEntryOverlay
                .position(location)
        }
    }

    // MARK: Tool selector

    private var toolSelector: some View {
        HStack(spacing: 6) {
            toolButton(.freehand, label: "Pen")
            toolButton(.shape, label: "Shape")
            toolButton(.eraser, label: "Eraser")
            toolButton(.text, label: "Text")
        }
        .padding(6)
        .background(overlayBackground)
    }

    private func toolButton(_ tool: WhiteboardTool, label: String) -> some View {
        Button {
            viewModel.selectTool(tool)
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(viewModel.activeTool == tool
                              ? Color.white.opacity(0.22)
                              : Color.white.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: History controls

    private var historyControls: some View {
        HStack(spacing: 6) {
            controlButton("Undo") { viewModel.undo() }
            controlButton("Redo") { viewModel.redo() }
            controlButton("Clear") { viewModel.clear() }
        }
        .padding(6)
        .background(overlayBackground)
    }

    private func controlButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: Color picker

    private var colorPicker: some View {
        HStack(spacing: 8) {
            ForEach(WhiteboardColor.allCases, id: \.self) { color in
                Button {
                    viewModel.selectColor(color)
                } label: {
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

    // MARK: Shape-kind selector

    private var shapeKindSelector: some View {
        HStack(spacing: 6) {
            shapeKindButton(.rectangle, label: "Rect")
            shapeKindButton(.ellipse, label: "Ellipse")
            shapeKindButton(.line, label: "Line")
        }
        .padding(6)
        .background(overlayBackground)
    }

    private func shapeKindButton(_ kind: ShapeKind, label: String) -> some View {
        Button {
            viewModel.selectShapeKind(kind)
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(viewModel.activeShapeKind == kind
                              ? Color.white.opacity(0.22)
                              : Color.white.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: Text-entry overlay (H2)

    private var textEntryOverlay: some View {
        // H2 / W1 hardening: the entry field is a hardened NSViewRepresentable
        // (SecureWhiteboardTextField) reusing the code editor's SecureCodeTextView,
        // so its right-click menu is restricted to Cut/Copy/Paste/Select All and
        // Services is refused — no spelling/substitutions NSPanel can open from it
        // (S-A6). All substitution disables are applied so text is stored literally.
        // No Menu/.popover/.sheet here.
        VStack(spacing: 8) {
            SecureWhiteboardTextField(
                text: $textEntryValue,
                characterLimit: WhiteboardViewModel.maxTextLength,   // R8.7
                onSubmit: { confirmTextEntry() }
            )
            .frame(width: 200, height: 20)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(white: 0.16))
            )
            HStack(spacing: 8) {
                controlButton("Add") { confirmTextEntry() }
                controlButton("Cancel") { cancelTextEntry() }
            }
        }
        .padding(10)
        .background(overlayBackground)
    }

    private func confirmTextEntry() {
        guard let location = textEntryLocation else { return }
        viewModel.placeText(textEntryValue, at: location)   // empty → no element (R8.6)
        textEntryValue = ""
        textEntryLocation = nil
    }

    private func cancelTextEntry() {
        textEntryValue = ""
        textEntryLocation = nil
    }

    // MARK: Shared overlay chrome

    private var overlayBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(white: 0.16).opacity(0.92))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1.0)
            )
    }

    // MARK: - Color mapping (view layer only; the model stays pure)

    /// Map a pure `WhiteboardColor` palette entry to a concrete SwiftUI `Color`.
    /// This mapping lives in the view layer so the model carries no AppKit /
    /// SwiftUI color dependency.
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
}
