//
//  InterDropdown.swift
//  inter
//
//  Canonical design-system dropdown machinery — replaces native NSMenu /
//  Picker(.menu) / DatePicker(.field) chrome on migrated screens so menus,
//  selects, and the schedule time picker all share the catalogue look
//  (popover bg, 1px border, radius 10 panel; hover-accent rows, radius 6).
//
//  Pieces:
//    • .interDropdown(isPresented:alignment:matchTriggerWidth:)  — anchors a
//      borderless child panel below (or above, when space runs out) the
//      trigger. Click-outside / Esc / window-move dismiss. The panel adopts
//      the host window's appearance so dynamic tokens resolve identically.
//    • InterMenuContainer / InterMenuRow / InterMenuSeparator — action menus.
//    • InterSelect<Value>     — single-choice select with checkmark rows.
//    • InterTimeSelect        — Zoom-style time-of-day picker (30-min steps).
//

import AppKit
import SwiftUI

// MARK: - Anchored panel presenter

/// Builds the borderless child panel a dropdown renders into. Internal (not
/// private) so the security-critical configuration is unit-testable.
@MainActor
enum InterDropdownPanelFactory {
    static func makePanel(size: NSSize, parentWindow: NSWindow) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // SECURITY [paranoid #2]: the dropdown panel is a separate NSWindow, so
        // it does NOT inherit the parent's capture protection. Inside the secure
        // interview window the parent is NSWindowSharingNone — a default-sharing
        // child panel would leak menu content (participant names, room state) to
        // screen capture. Always mirror the parent's sharingType.
        panel.sharingType = parentWindow.sharingType
        // Float above the parent even when the parent sits at an elevated level
        // (secure window = NSScreenSaverWindowLevel; .popUpMenu is below that).
        panel.level = max(.popUpMenu, NSWindow.Level(rawValue: parentWindow.level.rawValue + 1))
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.appearance = parentWindow.effectiveAppearance
        return panel
    }
}

/// Owns the borderless child NSPanel a dropdown renders into, plus the event
/// monitors that implement menu-like dismissal.
@MainActor
private final class InterDropdownPresenter: ObservableObject {
    private var panel: NSPanel?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var parentObservers: [NSObjectProtocol] = []
    private(set) var isShown = false

    /// Called when the presenter dismisses itself (outside click / Esc / move).
    var onDismiss: (() -> Void)?

    func present<Content: View>(anchor: NSView,
                                alignment: HorizontalAlignment,
                                matchTriggerWidth: Bool,
                                opensUpward: Bool,
                                @ViewBuilder content: () -> Content) {
        dismiss()
        guard let parentWindow = anchor.window else { return }

        let hosting = NSHostingView(rootView: content())
        hosting.appearance = parentWindow.effectiveAppearance
        var size = hosting.fittingSize
        if matchTriggerWidth {
            size.width = max(size.width, anchor.bounds.width)
        }
        size.width = max(size.width, 160)

        let panel = InterDropdownPanelFactory.makePanel(size: size, parentWindow: parentWindow)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting

        // Anchor frame in screen coordinates.
        let anchorInWindow = anchor.convert(anchor.bounds, to: nil)
        let anchorOnScreen = parentWindow.convertToScreen(anchorInWindow)

        var x: CGFloat
        switch alignment {
        case .trailing: x = anchorOnScreen.maxX - size.width
        case .center:   x = anchorOnScreen.midX - size.width / 2
        default:        x = anchorOnScreen.minX
        }
        var y = opensUpward
            ? anchorOnScreen.maxY + 4                  // above the trigger (bottom bars)
            : anchorOnScreen.minY - 4 - size.height    // below the trigger

        // Keep the panel on the anchor's screen; flip when out of room.
        if let screen = parentWindow.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if opensUpward {
                if y + size.height > visible.maxY {
                    y = anchorOnScreen.minY - 4 - size.height
                }
            } else if y < visible.minY {
                y = anchorOnScreen.maxY + 4
            }
            x = min(max(x, visible.minX + 4), visible.maxX - size.width - 4)
        }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
        parentWindow.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        self.panel = panel
        isShown = true

        // Outside-click dismissal. Clicks inside the anchor are swallowed so a
        // trigger click closes the menu instead of immediately reopening it.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak anchor, weak parentWindow] event in
            guard let self, let panel = self.panel else { return event }
            if event.window === panel { return event }
            let clickedAnchor: Bool = {
                guard let anchor, let parentWindow, event.window === parentWindow else { return false }
                let point = anchor.convert(event.locationInWindow, from: nil)
                return anchor.bounds.contains(point)
            }()
            Task { @MainActor in self.dismissAndNotify() }
            return clickedAnchor ? nil : event
        }
        // Esc closes (menu convention).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                Task { @MainActor in self?.dismissAndNotify() }
                return nil
            }
            return event
        }
        // Parent move / resize / close → dismiss.
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification,
                     NSWindow.didResizeNotification,
                     NSWindow.willCloseNotification,
                     NSWindow.didResignKeyNotification] {
            parentObservers.append(center.addObserver(forName: name, object: parentWindow, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.dismissAndNotify() }
            })
        }
    }

    private func dismissAndNotify() {
        guard isShown else { return }
        dismiss()
        onDismiss?()
    }

    func dismiss() {
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor); clickMonitor = nil }
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor); keyMonitor = nil }
        parentObservers.forEach { NotificationCenter.default.removeObserver($0) }
        parentObservers.removeAll()
        if let panel = panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        isShown = false
    }
}

/// Captures the trigger's backing NSView so the panel can anchor to it.
private struct DropdownAnchorView: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct InterDropdownModifier<DropdownContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let alignment: HorizontalAlignment
    let matchTriggerWidth: Bool
    let opensUpward: Bool
    @ViewBuilder let dropdownContent: () -> DropdownContent

    @StateObject private var presenter = InterDropdownPresenter()
    @State private var anchorView: NSView?

    func body(content: Content) -> some View {
        content
            .background(DropdownAnchorView { anchorView = $0 })
            .onChange(of: isPresented) { shown in
                if shown, let anchor = anchorView {
                    presenter.onDismiss = { isPresented = false }
                    presenter.present(anchor: anchor,
                                      alignment: alignment,
                                      matchTriggerWidth: matchTriggerWidth,
                                      opensUpward: opensUpward,
                                      content: dropdownContent)
                } else if !shown {
                    presenter.dismiss()
                }
            }
            .onDisappear { presenter.dismiss() }
    }
}

extension View {
    /// Presents design-system dropdown content in a borderless panel anchored
    /// to this view (below by default; `opensUpward` for bottom bars).
    func interDropdown<Content: View>(isPresented: Binding<Bool>,
                                      alignment: HorizontalAlignment = .leading,
                                      matchTriggerWidth: Bool = false,
                                      opensUpward: Bool = false,
                                      @ViewBuilder content: @escaping () -> Content) -> some View {
        modifier(InterDropdownModifier(isPresented: isPresented,
                                       alignment: alignment,
                                       matchTriggerWidth: matchTriggerWidth,
                                       opensUpward: opensUpward,
                                       dropdownContent: content))
    }
}

// MARK: - Menu chrome

/// The dropdown panel chrome: popover bg, hairline border, radius 10.
/// `stage: true` uses the FIXED dark stage tokens (in-call surfaces are never
/// appearance-aware).
struct InterMenuContainer<Content: View>: View {
    var minWidth: CGFloat = 180
    var stage = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            content()
        }
        .padding(InterSpacing.x1)
        .frame(minWidth: minWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: InterRadius.xl, style: .continuous)
                .fill(stage ? Color(nsColor: InterColor.stageElevated)
                            : Color(nsColor: InterColor.popover))
                .overlay(RoundedRectangle(cornerRadius: InterRadius.xl, style: .continuous)
                    .strokeBorder(stage ? Color.white.opacity(0.10)
                                        : Color(nsColor: InterColor.border), lineWidth: 1))
        )
        .padding(2) // breathing room so the panel shadow isn't clipped
    }
}

/// One menu action row: hover-accent fill, optional leading icon or checkmark,
/// destructive variant.
struct InterMenuRow: View {
    let title: String
    var icon: String? = nil
    var checked: Bool? = nil      // non-nil reserves the checkmark gutter
    var destructive = false
    var enabled = true
    var stage = false
    let action: () -> Void

    @State private var hovering = false

    private var textColor: Color {
        if destructive { return Color(nsColor: InterStatus.danger) }
        return stage ? Color.white.opacity(0.9)
                     : Color(nsColor: InterColor.popoverForeground)
    }

    private var hoverFill: Color {
        if destructive { return Color(nsColor: InterStatus.danger).opacity(0.12) }
        return stage ? Color.white.opacity(0.08) : Color(nsColor: InterColor.accent)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: InterSpacing.x2) {
                if let checked = checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(nsColor: InterColor.primary))
                        .frame(width: 12)
                        .opacity(checked ? 1 : 0)
                }
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .frame(width: 16)
                }
                Text(title)
                    .font(InterFont.swiftUI(13))
                    .lineLimit(1)
                Spacer(minLength: InterSpacing.x3)
            }
            .foregroundColor(textColor)
            .padding(.horizontal, InterSpacing.x2_5)
            .padding(.vertical, InterSpacing.x1_5 + 1)
            .background(
                RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                    .fill(hovering && enabled ? hoverFill : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 }
        .handCursor()
    }
}

struct InterMenuSeparator: View {
    var stage = false
    var body: some View {
        Rectangle()
            .fill(stage ? Color.white.opacity(0.10) : Color(nsColor: InterColor.border))
            .frame(height: 1)
            .padding(.vertical, InterSpacing.x1)
            .padding(.horizontal, InterSpacing.x1_5)
    }
}

/// Non-interactive section caption inside a menu (groups related rows).
struct InterMenuSectionLabel: View {
    let text: String
    var stage = false
    var body: some View {
        Text(text.uppercased())
            .font(InterFont.swiftUI(9, .bold))
            .tracking(1.0)
            .foregroundColor(stage ? Color.white.opacity(0.45)
                                   : Color(nsColor: InterColor.mutedForeground))
            .padding(.horizontal, InterSpacing.x2_5)
            .padding(.top, InterSpacing.x1_5)
            .padding(.bottom, 2)
    }
}

// MARK: - Select (single-choice dropdown)

/// Design-system replacement for Picker(.menu): field-chrome trigger with a
/// chevron; dropdown rows with a checkmark on the current value. Scrolls and
/// auto-centers on the selection for long option lists (e.g. timezones).
struct InterSelect<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    /// Fill the available width (form fields) or hug content (inline rows).
    var fillWidth = true
    var enabled = true

    @State private var open = false
    @State private var hovering = false

    private var currentLabel: String {
        options.first(where: { $0.value == selection })?.label ?? ""
    }

    var body: some View {
        Button(action: { if enabled { open.toggle() } }) {
            HStack(spacing: InterSpacing.x2) {
                Text(currentLabel)
                    .font(InterFont.swiftUI(InterFont.Size.secondary))
                    .foregroundColor(Color(nsColor: InterColor.foreground))
                    .lineLimit(1)
                if fillWidth { Spacer(minLength: 0) }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Color(nsColor: InterColor.mutedForeground))
            }
            .frame(maxWidth: fillWidth ? .infinity : nil, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .interFieldChrome(isFocused: open)
        .fixedSize(horizontal: !fillWidth, vertical: false)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .handCursor()
        .interDropdown(isPresented: $open, alignment: .leading, matchTriggerWidth: fillWidth) {
            InterMenuContainer(minWidth: 160) {
                optionList
            }
        }
    }

    @ViewBuilder private var optionList: some View {
        if options.count > 9 {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) { rows }
                }
                .frame(maxHeight: 300)
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
            }
        } else {
            rows
        }
    }

    private var rows: some View {
        ForEach(options, id: \.value) { option in
            InterMenuRow(title: option.label,
                         checked: option.value == selection,
                         action: {
                selection = option.value
                open = false
            })
            .id(option.value)
        }
    }
}

// MARK: - Time select (schedule start-time picker)

/// Zoom-style time-of-day picker: field trigger showing "6:00 PM", dropdown of
/// 30-minute slots that scrolls to the current selection. Writes hour/minute
/// onto the bound date, preserving its day.
struct InterTimeSelect: View {
    @Binding var selection: Date
    var calendar: Calendar = .current

    @State private var open = false

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private var currentMinutes: Int {
        let c = calendar.dateComponents([.hour, .minute], from: selection)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Nearest 30-minute slot (for scroll positioning + checkmark).
    private var nearestSlot: Int { (currentMinutes + 15) / 30 * 30 % (24 * 60) }

    var body: some View {
        Button(action: { open.toggle() }) {
            HStack(spacing: InterSpacing.x2) {
                Text(InterTimeSelect.formatter.string(from: selection))
                    .font(InterFont.swiftUI(InterFont.Size.secondary))
                    .foregroundColor(Color(nsColor: InterColor.foreground))
                Spacer(minLength: 0)
                Image(systemName: "clock")
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: InterColor.mutedForeground))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .interFieldChrome(isFocused: open)
        .handCursor()
        .interDropdown(isPresented: $open, alignment: .leading, matchTriggerWidth: true) {
            InterMenuContainer(minWidth: 140) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(stride(from: 0, to: 24 * 60, by: 30)), id: \.self) { minutes in
                                InterMenuRow(title: label(forMinutes: minutes),
                                             checked: minutes == nearestSlot,
                                             action: {
                                    apply(minutes: minutes)
                                    open = false
                                })
                                .id(minutes)
                            }
                        }
                    }
                    .frame(maxHeight: 280)
                    .onAppear { proxy.scrollTo(nearestSlot, anchor: .center) }
                }
            }
        }
    }

    private func label(forMinutes minutes: Int) -> String {
        var comps = calendar.dateComponents([.year, .month, .day], from: selection)
        comps.hour = minutes / 60
        comps.minute = minutes % 60
        guard let date = calendar.date(from: comps) else { return "" }
        return InterTimeSelect.formatter.string(from: date)
    }

    private func apply(minutes: Int) {
        var comps = calendar.dateComponents([.year, .month, .day], from: selection)
        comps.hour = minutes / 60
        comps.minute = minutes % 60
        if let date = calendar.date(from: comps) {
            selection = date
        }
    }
}
