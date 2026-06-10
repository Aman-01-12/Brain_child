//
//  BrandIcons.swift
//  inter
//
//  Real Google / Microsoft brand marks rendered as vector shapes — no bitmap assets, no
//  asset catalog. The Google "G" uses the official multi-colour path data (translated from
//  the catalogue's inline SVG) via a tiny SVG-path parser; the Microsoft mark is the four
//  official-colour squares. Both scale crisply at any size.
//

import SwiftUI
import AppKit

// MARK: - Minimal SVG path → SwiftUI Path

/// Supports the M/L/H/V/C/S/Z commands (absolute + relative) used by the bundled brand
/// marks. Not a general SVG engine — just enough to render vetted, fixed path data.
struct SVGPath {
    let d: String
    let viewBox: CGSize

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let sx = rect.width / viewBox.width
        let sy = rect.height / viewBox.height
        func map(_ pt: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + pt.x * sx, y: rect.minY + pt.y * sy)
        }

        let scanner = Scanner2(d)
        var current = CGPoint.zero
        var startPt = CGPoint.zero
        var lastControl: CGPoint?
        var lastCmd: Character = " "

        while let cmd = scanner.nextCommand() {
            switch cmd {
            case "M", "m":
                var first = true
                while scanner.hasNumber {
                    var pt = CGPoint(x: scanner.number(), y: scanner.number())
                    if cmd == "m" { pt.x += current.x; pt.y += current.y }
                    current = pt
                    if first { startPt = current; p.move(to: map(current)); first = false }
                    else { p.addLine(to: map(current)) }
                }
                lastControl = nil
            case "L", "l":
                while scanner.hasNumber {
                    var pt = CGPoint(x: scanner.number(), y: scanner.number())
                    if cmd == "l" { pt.x += current.x; pt.y += current.y }
                    current = pt; p.addLine(to: map(current))
                }
                lastControl = nil
            case "H", "h":
                while scanner.hasNumber {
                    var x = scanner.number()
                    if cmd == "h" { x += current.x }
                    current.x = x; p.addLine(to: map(current))
                }
                lastControl = nil
            case "V", "v":
                while scanner.hasNumber {
                    var y = scanner.number()
                    if cmd == "v" { y += current.y }
                    current.y = y; p.addLine(to: map(current))
                }
                lastControl = nil
            case "C", "c":
                while scanner.hasNumber {
                    var c1 = CGPoint(x: scanner.number(), y: scanner.number())
                    var c2 = CGPoint(x: scanner.number(), y: scanner.number())
                    var end = CGPoint(x: scanner.number(), y: scanner.number())
                    if cmd == "c" {
                        c1.x += current.x; c1.y += current.y
                        c2.x += current.x; c2.y += current.y
                        end.x += current.x; end.y += current.y
                    }
                    p.addCurve(to: map(end), control1: map(c1), control2: map(c2))
                    lastControl = c2; current = end
                }
            case "S", "s":
                while scanner.hasNumber {
                    var c2 = CGPoint(x: scanner.number(), y: scanner.number())
                    var end = CGPoint(x: scanner.number(), y: scanner.number())
                    if cmd == "s" {
                        c2.x += current.x; c2.y += current.y
                        end.x += current.x; end.y += current.y
                    }
                    let c1: CGPoint
                    if "CcSs".contains(lastCmd), let lc = lastControl {
                        c1 = CGPoint(x: 2 * current.x - lc.x, y: 2 * current.y - lc.y)
                    } else {
                        c1 = current
                    }
                    p.addCurve(to: map(end), control1: map(c1), control2: map(c2))
                    lastControl = c2; current = end
                }
            case "Z", "z":
                p.closeSubpath(); current = startPt; lastControl = nil
            default:
                break
            }
            lastCmd = cmd
        }
        return p
    }

    /// Tiny tokenizer for SVG path data (handles `-`/`.` as implicit separators).
    private final class Scanner2 {
        private let chars: [Character]
        private var i = 0
        init(_ s: String) { chars = Array(s) }

        private func skip() {
            while i < chars.count, " ,\n\t\r".contains(chars[i]) { i += 1 }
        }
        func nextCommand() -> Character? {
            skip()
            guard i < chars.count, chars[i].isLetter else { return nil }
            defer { i += 1 }
            return chars[i]
        }
        var hasNumber: Bool {
            skip()
            guard i < chars.count else { return false }
            let c = chars[i]
            return c == "-" || c == "+" || c == "." || (c >= "0" && c <= "9")
        }
        func number() -> CGFloat {
            skip()
            var s = ""
            if i < chars.count, chars[i] == "-" || chars[i] == "+" { s.append(chars[i]); i += 1 }
            var dot = false
            while i < chars.count {
                let c = chars[i]
                if c >= "0" && c <= "9" { s.append(c); i += 1 }
                else if c == "." && !dot { dot = true; s.append(c); i += 1 }
                else { break }
            }
            return CGFloat(Double(s) ?? 0)
        }
    }
}

// MARK: - Brand marks

/// Official multi-colour Google "G".
struct GoogleIcon: View {
    private static let parts: [(String, UInt32)] = [
        ("M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z", 0x4285F4),
        ("M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z", 0x34A853),
        ("M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l3.66-2.84z", 0xFBBC05),
        ("M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z", 0xEA4335),
    ]
    var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            for (d, hex) in Self.parts {
                let path = SVGPath(d: d, viewBox: CGSize(width: 24, height: 24)).path(in: rect)
                ctx.fill(path, with: .color(Color(nsColor: NSColor(hex: hex))))
            }
        }
    }
}

/// Official four-square Microsoft mark.
struct MicrosoftIcon: View {
    var body: some View {
        Canvas { ctx, size in
            let gap = size.width * 0.08
            let s = (size.width - gap) / 2
            func square(_ x: CGFloat, _ y: CGFloat, _ hex: UInt32) {
                ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)),
                         with: .color(Color(nsColor: NSColor(hex: hex))))
            }
            square(0, 0, 0xF25022)        // red
            square(s + gap, 0, 0x7FBA00)  // green
            square(0, s + gap, 0x00A4EF)  // blue
            square(s + gap, s + gap, 0xFFB900) // yellow
        }
    }
}
