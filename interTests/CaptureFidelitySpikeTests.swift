//
//  CaptureFidelitySpikeTests.swift
//  interTests
//
//  SPIKE (capture-fidelity BLOCKER) — see
//  docs/superpowers/specs/2026-06-07-swiftui-migration-research.md §9.3 / §13.
//
//  Question this answers:
//    The secure tool-capture pipeline (`InterViewSnapshotVideoSource`) snapshots an
//    NSView via `cacheDisplayInRect:toBitmapImageRep:` at 10fps. Does that exact API
//    reproduce a HOSTED SwiftUI surface PIXEL-CORRECTLY? And if not, does the
//    documented fallback (`ImageRenderer`, macOS 13+) succeed instead?
//
//  This spike drives the SAME `cacheDisplayInRect:` call the source uses (so the
//  result transfers directly to the real pipeline) and, in the same run, renders the
//  same view via `ImageRenderer` — giving a head-to-head verdict.
//
//  Two surfaces, because the risk differs:
//    • Plain SwiftUI (HStack of Colors + Text) → the CODE EDITOR case.
//    • SwiftUI `Canvas { … }`                  → the WHITEBOARD case (GraphicsContext
//      can be GPU/Metal-backed — exactly what `cacheDisplayInRect:` may return blank).
//
//  PASS = sampled pixels match the drawn colors (left red, right blue).
//  Each surface writes two PNGs (cacheDisplay + ImageRenderer) to the temp dir and
//  prints their paths so the result can be eyeballed, not just asserted.
//
//  Throwaway spike kept as a guard for the later editor/canvas migration.
//

import XCTest
import SwiftUI
import AppKit
@testable import inter

final class CaptureFidelitySpikeTests: XCTestCase {

    // MARK: - Deterministic, sampleable test surfaces

    /// Plain SwiftUI: left half solid red, right half solid blue, white label.
    private struct PlainSurface: View {
        var body: some View {
            ZStack {
                HStack(spacing: 0) { Color.red; Color.blue }
                Text("EDITOR").font(.system(size: 48, weight: .bold)).foregroundStyle(.white)
            }
        }
    }

    /// SwiftUI `Canvas` (the whiteboard primitive): same left-red / right-blue split,
    /// drawn through GraphicsContext so we test the GPU-backed path specifically.
    private struct CanvasSurface: View {
        var body: some View {
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)),
                         with: .color(.red))
                ctx.fill(Path(CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)),
                         with: .color(.blue))
                ctx.draw(Text("BOARD").font(.system(size: 48, weight: .bold)).foregroundColor(.white),
                         at: CGPoint(x: size.width / 2, y: size.height / 2))
            }
        }
    }

    // MARK: - Tests

    @MainActor
    func testPlainSwiftUIView_cacheDisplay_vs_imageRenderer() {
        let cache = captureViaCacheDisplay(PlainSurface(), label: "editor")
        assertLeftRedRightBlue(cache, mechanism: "cacheDisplayInRect:", surface: "plain SwiftUI (editor)")

        // Always also exercise the fallback so we know it's available + correct.
        let render = captureViaImageRenderer(PlainSurface(), label: "editor")
        assertLeftRedRightBlue(render, mechanism: "ImageRenderer", surface: "plain SwiftUI (editor)")
    }

    @MainActor
    func testSwiftUICanvas_cacheDisplay_vs_imageRenderer() {
        // The at-risk case. If cacheDisplay FAILS here, the whiteboard migration must
        // use ImageRenderer — and the ImageRenderer assertion below proves that works.
        let cache = captureViaCacheDisplay(CanvasSurface(), label: "board")
        assertLeftRedRightBlue(cache, mechanism: "cacheDisplayInRect: (if this fails → use ImageRenderer)",
                               surface: "SwiftUI Canvas (whiteboard)")

        let render = captureViaImageRenderer(CanvasSurface(), label: "board")
        assertLeftRedRightBlue(render, mechanism: "ImageRenderer", surface: "SwiftUI Canvas (whiteboard)")
    }

    // MARK: - Capture mechanisms

    private struct Sample {
        var left: (r: Double, g: Double, b: Double)?
        var right: (r: Double, g: Double, b: Double)?
        var png: String?
        var w = 0, h = 0
    }

    /// The EXACT mechanism `InterViewSnapshotVideoSource` uses: host the view in an
    /// offscreen NSWindow, let SwiftUI render, then `cacheDisplay(in:to:)`.
    @MainActor
    private func captureViaCacheDisplay<V: View>(_ view: V, label: String) -> Sample {
        let size = NSSize(width: 800, height: 450)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.wantsLayer = true

        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()

        // Let SwiftUI commit its first render (no 10fps loop here to wait on).
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        hosting.displayIfNeeded()

        var s = Sample()
        if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            s = sample(rep, label: "\(label)_cacheDisplay")
        }
        window.orderOut(nil)
        return s
    }

    /// The documented FALLBACK: `ImageRenderer` rasterizes the SwiftUI view directly
    /// (bypasses `cacheDisplayInRect:`).
    @MainActor
    private func captureViaImageRenderer<V: View>(_ view: V, label: String) -> Sample {
        let size = CGSize(width: 800, height: 450)
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return Sample() }
        let rep = NSBitmapImageRep(cgImage: cg)
        return sample(rep, label: "\(label)_imageRenderer")
    }

    // MARK: - Sampling + artifacts

    private func sample(_ rep: NSBitmapImageRep, label: String) -> Sample {
        var s = Sample()
        s.w = rep.pixelsWide
        s.h = rep.pixelsHigh
        func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double)? {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return nil }
            return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        }
        if s.w > 0 && s.h > 0 {
            s.left  = rgb(s.w / 4, s.h / 2)
            s.right = rgb(min(s.w - 1, 3 * s.w / 4), s.h / 2)
        }
        if let data = rep.representation(using: .png, properties: [:]) {
            let path = NSTemporaryDirectory() + "spike_\(label)_\(Int(Date().timeIntervalSince1970)).png"
            if (try? data.write(to: URL(fileURLWithPath: path))) != nil { s.png = path }
        }
        print("🧪 SPIKE [\(label)] \(s.w)x\(s.h) left=\(fmt(s.left)) right=\(fmt(s.right)) png=\(s.png ?? "none")")
        return s
    }

    private func fmt(_ c: (r: Double, g: Double, b: Double)?) -> String {
        guard let c = c else { return "nil" }
        return String(format: "R%.2f G%.2f B%.2f", c.r, c.g, c.b)
    }

    private func assertLeftRedRightBlue(_ s: Sample, mechanism: String, surface: String) {
        XCTAssertNotNil(s.left,  "[\(surface) via \(mechanism)] no pixels — capture produced nothing")
        XCTAssertNotNil(s.right, "[\(surface) via \(mechanism)] no pixels — capture produced nothing")
        if let l = s.left {
            XCTAssertGreaterThan(l.r, 0.45, "[\(surface) via \(mechanism)] left should be RED-dominant; got \(fmt(l)) — likely BLANK")
            XCTAssertLessThan(l.b, 0.45,    "[\(surface) via \(mechanism)] left should not be blue; got \(fmt(l))")
        }
        if let r = s.right {
            XCTAssertGreaterThan(r.b, 0.45, "[\(surface) via \(mechanism)] right should be BLUE-dominant; got \(fmt(r)) — likely BLANK")
            XCTAssertLessThan(r.r, 0.45,    "[\(surface) via \(mechanism)] right should not be red; got \(fmt(r))")
        }
    }
}
