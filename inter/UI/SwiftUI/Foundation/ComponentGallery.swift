//
//  ComponentGallery.swift
//  inter
//
//  A debug harness window for building and screenshotting SwiftUI screens in isolation.
//  Opened on demand (launch arg `--component-gallery` or env `INTER_COMPONENT_GALLERY=1`),
//  never in normal runs. Two jobs:
//    1. `present(_:title:size:)` — mount any single screen view at a fixed logical size
//       through the real `InterHostingController` seam (Tasks 1–15 use this).
//    2. `presentDefaultGallery()` — a token sanity board: theme swatches (which flip with
//       the appearance toggle) next to stage swatches (which must stay fixed dark), plus a
//       General Sans type sample. This is the foundation-gate visual check.
//

import AppKit
import SwiftUI

@objc public final class ComponentGallery: NSObject {

    /// Strong refs so on-demand debug windows aren't deallocated immediately.
    private static var windows: [NSWindow] = []

    /// Open the default gallery only if the launch flag / env var is present.
    @objc public static func presentIfLaunchFlagPresent() {
        let args = ProcessInfo.processInfo.arguments
        let env = ProcessInfo.processInfo.environment
        guard args.contains("--component-gallery") || env["INTER_COMPONENT_GALLERY"] == "1" else { return }
        presentDefaultGallery()
    }

    /// Open the token sanity board.
    @objc public static func presentDefaultGallery() {
        let window = makeWindow(title: "Inter Component Gallery",
                                size: CGSize(width: 760, height: 760))
        let root = ComponentGalleryView { mode in
            InterAppearance.apply(mode, to: window)
        }
        window.contentViewController = InterHostingController(mode: .system, rootView: root)
        InterAppearance.applyDefault(to: window) // start dark
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    /// Mount any single screen view at a fixed size through the real hosting seam.
    public static func present<Content: View>(_ rootView: Content,
                                              title: String,
                                              size: CGSize,
                                              mode: InterAppearance.Mode = InterAppearance.defaultMode) {
        let window = makeWindow(title: title, size: size)
        window.contentViewController = InterHostingController(mode: mode, rootView: rootView)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private static func makeWindow(title: String, size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        windows.append(window)
        return window
    }
}

// MARK: - Default gallery view (token sanity board)

private struct ComponentGalleryView: View {

    /// Drives the REAL window appearance so dynamic theme tokens re-resolve.
    let onAppearanceChange: (InterAppearance.Mode) -> Void
    @State private var isDark = true

    var body: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x5) {
            header
            swatchRow("Theme — must flip with the toggle", [
                ("background", InterColor.background), ("card", InterColor.card),
                ("secondary", InterColor.secondary),   ("primary", InterColor.primary),
            ])
            swatchRow("Stage — must stay dark", [
                ("stage", InterColor.stage), ("surface", InterColor.stageSurface),
                ("elevated", InterColor.stageElevated),
            ])
            typography
            Spacer(minLength: 0)
        }
        .padding(InterSpacing.x6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: InterColor.background))
    }

    private var header: some View {
        HStack {
            Text("Inter Component Gallery")
                .font(InterFont.swiftUI(InterFont.Size.display, .bold))
                .foregroundStyle(Color(nsColor: InterColor.foreground))
            Spacer()
            Picker("", selection: $isDark) {
                Text("Dark").tag(true)
                Text("Light").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            .onChange(of: isDark) { _, newValue in
                onAppearanceChange(newValue ? .dark : .light)
            }
        }
    }

    private func swatchRow(_ title: String, _ items: [(String, NSColor)]) -> some View {
        VStack(alignment: .leading, spacing: InterSpacing.x2) {
            Text(title.uppercased())
                .font(InterFont.swiftUI(InterFont.Size.caption, .semibold))
                .foregroundStyle(Color(nsColor: InterColor.mutedForeground))
            HStack(spacing: InterSpacing.x3) {
                ForEach(items, id: \.0) { name, color in
                    VStack(spacing: InterSpacing.x1) {
                        RoundedRectangle(cornerRadius: InterRadius.md)
                            .fill(Color(nsColor: color))
                            .frame(width: 96, height: 56)
                            .overlay(
                                RoundedRectangle(cornerRadius: InterRadius.md)
                                    .stroke(Color(nsColor: InterColor.border), lineWidth: 1)
                            )
                        Text(name)
                            .font(InterFont.swiftUI(InterFont.Size.caption))
                            .foregroundStyle(Color(nsColor: InterColor.mutedForeground))
                    }
                }
            }
        }
    }

    private var typography: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x2) {
            Text("TYPOGRAPHY — GENERAL SANS")
                .font(InterFont.swiftUI(InterFont.Size.caption, .semibold))
                .foregroundStyle(Color(nsColor: InterColor.mutedForeground))
            Text("Display 24 / Bold").font(InterFont.swiftUI(InterFont.Size.display, .bold))
            Text("Title 20 / Semibold").font(InterFont.swiftUI(InterFont.Size.title, .semibold))
            Text("Body 16 / Regular").font(InterFont.swiftUI(InterFont.Size.body))
            Text("Caption 12 / Medium").font(InterFont.swiftUI(InterFont.Size.caption, .medium))
        }
        .foregroundStyle(Color(nsColor: InterColor.foreground))
    }
}
