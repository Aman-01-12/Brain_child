//
//  SecureToolsNetworkAuditTests.swift
//  interTests
//
//  Local-only / no-network audit for the SecureTools migration (Requirement
//  11). The migrated candidate tools (Code_Editor, Whiteboard) and the
//  Tool_Bridge must introduce NO network surface: no networking-module imports,
//  no URL/socket/DNS APIs, and all candidate-entered content held only in local
//  process memory.
//
//  This audit has two complementary parts:
//
//  1. A STATIC import / API scan over every SecureTools `.swift` source file on
//     disk (resolved from `#filePath`), asserting none references a networking
//     module or a network API. This is the strongest available guarantee that
//     the tools are local-only across their entire lifecycle (R11.1, R11.2,
//     R11.3, R11.5).
//
//  2. A lightweight BEHAVIORAL assertion that the editor text and Stroke_Model
//     elements are retained on in-memory `@Published` state with no file or
//     network side effect, documenting R11.4.
//
//  XCTest only (no SwiftCheck) — this is an audit, not a property test.
//
//  Validates: Requirements 11.1, 11.2, 11.3, 11.4, 11.5.
//

import XCTest
import CoreGraphics
@testable import inter

@MainActor
final class SecureToolsNetworkAuditTests: XCTestCase {

    // MARK: - Source-tree resolution

    /// Forbidden tokens: any networking-module import or network API. Scanning
    /// for these across the SecureTools sources proves the tools open/accept no
    /// connection, issue no outbound URL request, and perform no DNS resolution
    /// anywhere in their code (R11.1, R11.2, R11.3, R11.5).
    private static let forbiddenTokens: [String] = [
        "import Network",
        "import URLSession",
        "URLSession",
        "URLRequest",
        "URL(string:",
        "NWConnection",
        "import Socket",
        "CFSocket",
        "getaddrinfo",
        "Host(",
        "NSURLConnection",
        "import LiveKit",
        "WebSocket",
        "dataTask",
        "downloadTask",
        "uploadTask",
    ]

    /// Resolve the SecureTools source directory on disk from this test file's
    /// location. `#filePath` points at
    /// `<repo>/interTests/SecureTools/SecureToolsNetworkAuditTests.swift`; the
    /// SecureTools sources live at `<repo>/inter/UI/SwiftUI/SecureTools`.
    private func resolveSecureToolsSourceDir() -> URL {
        // <repo>/interTests/SecureTools/SecureToolsNetworkAuditTests.swift
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()   // .../interTests/SecureTools
            .deletingLastPathComponent()   // .../interTests
            .deletingLastPathComponent()   // .../<repo>
        return repoRoot
            .appendingPathComponent("inter", isDirectory: true)
            .appendingPathComponent("UI", isDirectory: true)
            .appendingPathComponent("SwiftUI", isDirectory: true)
            .appendingPathComponent("SecureTools", isDirectory: true)
    }

    /// Enumerate every `.swift` file under `dir` (recursively).
    private func swiftSources(under dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var results: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            results.append(url)
        }
        return results
    }

    // MARK: - 1. Static import / API scan (R11.1, R11.2, R11.3, R11.5)

    func testSecureToolsSourcesImportNoNetworkingModules() throws {
        let sourceDir = resolveSecureToolsSourceDir()

        // Prefer resolving via FileManager from #filePath. If the directory is
        // genuinely not present in this environment (e.g. a sandbox that does
        // not vend the source tree), SKIP rather than pass vacuously.
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sourceDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw XCTSkip("""
                SecureTools source directory not resolvable in this environment: \
                \(sourceDir.path). Cannot run the static no-network import scan.
                """)
        }

        let sources = swiftSources(under: sourceDir)
        XCTAssertFalse(
            sources.isEmpty,
            "expected to find SecureTools .swift sources under \(sourceDir.path); found none"
        )

        var violations: [String] = []
        for file in sources {
            let contents: String
            do {
                contents = try String(contentsOf: file, encoding: .utf8)
            } catch {
                XCTFail("could not read SecureTools source \(file.path): \(error)")
                continue
            }
            for token in Self.forbiddenTokens where contents.contains(token) {
                violations.append("  • \(file.lastPathComponent): contains forbidden token \"\(token)\"")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            SecureTools sources must import no networking module and use no \
            network API (R11.1, R11.2, R11.3, R11.5). Scanned \(sources.count) \
            file(s) under \(sourceDir.path). Violations:
            \(violations.joined(separator: "\n"))
            """
        )
    }

    // MARK: - 2. In-memory-only content (R11.4)

    /// Documents R11.4: candidate-entered content (editor text and Stroke_Model
    /// elements) is retained only on in-memory `@Published` state. There is no
    /// file or network side effect to assert against directly, so this confirms
    /// the content lives on the model's in-process properties.
    func testEditorAndModelRetainContentInMemoryOnly() {
        // Code_Editor: text is held purely on the in-memory @Published property.
        let editor = CodeEditorViewModel()
        XCTAssertEqual(editor.text, "", "a fresh editor holds no text")

        let sample = "func solve() -> Int { return 42 } // \"quotes\" -- dashes"
        editor.text = sample
        XCTAssertEqual(
            editor.text, sample,
            "editor text must be retained verbatim on the in-memory @Published property (R11.4)"
        )

        // Whiteboard: elements live in the in-memory BoardDocument, surfaced via
        // the view model's `renderedElements`. With no collaborative controller
        // installed the view model operates purely standalone — no networking.
        let whiteboard = WhiteboardViewModel()
        XCTAssertTrue(whiteboard.renderedElements.isEmpty, "a fresh whiteboard holds no elements")

        // Place a text element through the real creation path.
        whiteboard.commitText("solution sketch", atWorld: CGPoint(x: 12, y: 12), editing: nil)

        // Draw a rectangle through the pointer-gesture path.
        whiteboard.selectTool(.rectangle)
        whiteboard.pointerDown(atScreen: CGPoint(x: 0, y: 0), additive: false)
        whiteboard.pointerDragged(toScreen: CGPoint(x: 40, y: 40))
        whiteboard.pointerUp(atScreen: CGPoint(x: 40, y: 40))

        XCTAssertEqual(
            whiteboard.renderedElements.count, 2,
            "added elements must live in the in-memory BoardDocument (R11.4)"
        )

        // The content is reachable only via the in-process document — clearing
        // is the only thing that drops it (no external persistence).
        whiteboard.clear()
        XCTAssertTrue(
            whiteboard.renderedElements.isEmpty,
            "clearing drops the in-memory elements; content has no external persistence (R11.4)"
        )
    }
}
