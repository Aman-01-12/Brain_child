//
//  SecureToolsWindowAuditTests.swift
//  interTests
//
//  S-A6 no-new-window security audit for the migrated secure tools, plus the
//  H1 right-click panel-leak mitigation verification and a static-usage scan of
//  the SecureTools sources.
//
//  The defining S-A6 invariant is that NO auxiliary tool UI (color picker, tool
//  selector, text entry, contextual menu, spelling/substitutions/font panel)
//  may spawn a separate `NSWindow`/`NSPanel` out of the captured, protected
//  interview surface. These tests exercise the real interaction paths while the
//  hosting views are realized in a window and assert that no NEW `NSWindow`
//  appears as a result, then statically scan the on-disk SecureTools sources to
//  prove none of the window-spawning SwiftUI/AppKit APIs are even referenced.
//
//  Window-count methodology: the test host is the full `inter.app`, which can
//  create its own windows asynchronously. Counting global `NSApp.windows` after
//  pumping the run loop is therefore noisy and unreliable. Instead each audit
//  snapshots the SET of live window identities immediately before and after a
//  block of SYNCHRONOUS interactions (no run-loop pump), and asserts that the
//  set difference — windows that appeared *because of* the interaction — is
//  empty. A panel-spawning API (NSAlert.runModal, panel.makeKeyAndOrderFront,
//  a SwiftUI sheet/popover/menu) would register its window synchronously within
//  the call, so this captures the leak precisely without app-launch noise.
//
//  Validates: Requirements 3.8, 10.1, 10.2, 10.3, 10.4, 10.5, 10.6.
//

import XCTest
import AppKit
@testable import inter

@MainActor
final class SecureToolsWindowAuditTests: XCTestCase {

    // MARK: - Helpers

    /// Reach the bridge's privately-held `WhiteboardViewModel` without widening
    /// its public API (mirrors `InterSecureToolsBridgeTests`' reflection).
    private func whiteboardViewModel(of bridge: InterSecureToolsBridge) -> WhiteboardViewModel? {
        Mirror(reflecting: bridge)
            .children
            .first { $0.label == "whiteboardViewModel" }?
            .value as? WhiteboardViewModel
    }

    /// Build a SecureCodeTextView over a minimal TextKit stack, mirroring the
    /// representable's `makeNSView` construction (same approach as
    /// `CodeEditorConfigurationTests`).
    private func makeSecureTextView() -> SecureCodeTextView {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(
            size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        return SecureCodeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300),
                                  textContainer: textContainer)
    }

    /// A host window used only to realize the views so SwiftUI lays them out.
    /// The window is never shown and never closed inside the test (closing /
    /// pumping the run loop in the app test host is both noisy and crash-prone);
    /// ARC releases it when the test method returns.
    private func makeHostWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                 styleMask: [.borderless],
                 backing: .buffered,
                 defer: false)
    }

    /// Identity snapshot of every live application window.
    private func liveWindowIdentities() -> Set<ObjectIdentifier> {
        Set(NSApp.windows.map(ObjectIdentifier.init))
    }

    /// Synthesize a right-click event at `point`.
    private func rightClick(at point: NSPoint) throws -> NSEvent {
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0)
        return try XCTUnwrap(event, "Failed to synthesize a right-click event")
    }

    /// Recursively find the first NSTextView inside a realized hosting view.
    private func firstTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let found = firstTextView(in: subview) { return found }
        }
        return nil
    }

    // MARK: - S-A6: tool interactions spawn no new window

    /// Drive the interactions that COULD plausibly surface an auxiliary panel —
    /// whiteboard color / tool / text / shape overlays, the bridge clear, and a
    /// code-editor right-click — and assert no NEW `NSWindow` appears as a
    /// result (R3.8, R10.1, R10.2, R10.3, R10.4).
    func testToolInteractionsDoNotSpawnNewWindows() throws {
        let bridge = InterSecureToolsBridge()

        // Realize both hosting views inside a temporary window so SwiftUI lays
        // them out (overlays included) exactly as it would on screen.
        let host = makeHostWindow()
        let editor = bridge.codeEditorHostingView
        let board = bridge.whiteboardHostingView
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        board.frame = NSRect(x: 0, y: 300, width: 800, height: 300)
        host.contentView?.addSubview(editor)
        host.contentView?.addSubview(board)
        host.contentView?.layoutSubtreeIfNeeded()
        editor.layoutSubtreeIfNeeded()
        board.layoutSubtreeIfNeeded()

        let viewModel = try XCTUnwrap(whiteboardViewModel(of: bridge),
                                      "bridge must own exactly one WhiteboardViewModel")

        // Snapshot live windows AFTER setup so the temporary host is already in
        // the baseline; any window that appears during the synchronous
        // interaction block below is a leak.
        let before = liveWindowIdentities()

        // --- Synchronous interaction block (no run-loop pump) ---
        bridge.clearWhiteboard()

        viewModel.selectColor(.red)
        viewModel.selectTool(.freehand)
        viewModel.selectColor(.blue)
        viewModel.selectTool(.text)
        viewModel.placeText("overlay interaction", at: CGPoint(x: 24, y: 24))
        viewModel.selectTool(.shape)
        viewModel.selectShapeKind(.ellipse)
        viewModel.beginShapeDrag(at: CGPoint(x: 0, y: 0))
        viewModel.updateShapeDrag(to: CGPoint(x: 60, y: 60))
        viewModel.commitShapeDrag(at: CGPoint(x: 60, y: 60))

        if let textView = firstTextView(in: editor) {
            let menu = textView.menu(for: try rightClick(at: NSPoint(x: 10, y: 10)))
            _ = menu?.items   // realize the menu items; none may open a window
        }
        // --- end interaction block ---

        let after = liveWindowIdentities()
        let newWindows = after.subtracting(before)
        XCTAssertTrue(
            newWindows.isEmpty,
            "Tool interactions must not spawn a new NSWindow/NSPanel (S-A6: R3.8, R10.1–R10.4). "
            + "\(newWindows.count) new window(s) appeared.")

        // Detach so the view-model timers / subscriptions release.
        bridge.invalidateHandlers()
        editor.removeFromSuperview()
        board.removeFromSuperview()
    }

    // MARK: - H1 (S-A6): code-editor right-click opens no window

    /// Build the hardened `SecureCodeTextView`, realize it in a temporary
    /// window, synthesize a right-click, and assert (a) any returned menu
    /// contains only Cut/Copy/Paste/Select All with no panel-opening item and
    /// (b) no NEW `NSWindow` appears (R10.1, R10.5).
    func testCodeEditorRightClickOpensNoWindow() throws {
        let textView = makeSecureTextView()

        let host = makeHostWindow()
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        host.contentView?.addSubview(textView)
        host.contentView?.layoutSubtreeIfNeeded()

        let before = liveWindowIdentities()

        let menu = textView.menu(for: try rightClick(at: NSPoint(x: 5, y: 5)))

        if let menu {
            let allowedTitles: Set<String> = ["Cut", "Copy", "Paste", "Select All"]
            let forbiddenSubstrings = ["Spelling", "Substitutions", "Font", "Services", "Look Up"]

            for item in menu.items where !item.isSeparatorItem {
                XCTAssertTrue(
                    allowedTitles.contains(item.title),
                    "Contextual menu item \"\(item.title)\" is outside the allowed "
                    + "Cut/Copy/Paste/Select All set (H1)")
                for forbidden in forbiddenSubstrings {
                    XCTAssertFalse(
                        item.title.contains(forbidden),
                        "Contextual menu must not contain a panel-opening \"\(forbidden)\" item (H1)")
                }
            }
        }

        let after = liveWindowIdentities()
        let newWindows = after.subtracting(before)
        XCTAssertTrue(
            newWindows.isEmpty,
            "A right-click on the secure code editor must open no NSWindow/NSPanel "
            + "(H1 / S-A6: R10.1, R10.5). \(newWindows.count) new window(s) appeared.")

        textView.removeFromSuperview()
    }

    // MARK: - Static usage scan of the SecureTools sources

    /// Scan every `.swift` file under `inter/UI/SwiftUI/SecureTools` and assert
    /// none references a window-spawning SwiftUI/AppKit API. This is the
    /// belt-and-suspenders companion to the live-window audit: even a path that
    /// is never exercised at runtime must not reference these APIs (R10.5,
    /// R10.6).
    ///
    /// The scan runs over source with comments and string literals stripped, so
    /// it flags only real API *usage* — not documentation that names a forbidden
    /// API in a comment (e.g. "no `.popover`/`.contextMenu` here"). The `Menu(`
    /// token is matched with a leading word boundary so the legitimate, required
    /// AppKit `NSMenu(` (the H1 sanitized contextual menu) is NOT flagged while
    /// the forbidden SwiftUI `Menu(` would be.
    func testSecureToolsSourcesContainNoWindowSpawningAPIs() throws {
        let sourceDir = try secureToolsSourceDirectory()

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: sourceDir,
                                                      includingPropertiesForKeys: nil) else {
            return XCTFail("Could not enumerate SecureTools source directory at \(sourceDir.path)")
        }

        // Plain substring tokens (no overlap with a legitimate identifier).
        let forbiddenTokens = [
            ".popover",
            ".sheet(",
            ".contextMenu",
            "NSWindow(",
            "NSPanel(",
            "NSAlert",
            ".alert(",
            "NSSavePanel",
            "NSOpenPanel",
        ]
        // `Menu(` only when not preceded by an identifier char, so the required
        // AppKit `NSMenu(` is allowed but a SwiftUI `Menu(` is caught.
        let swiftUIMenuRegex = try NSRegularExpression(pattern: "(?<![A-Za-z0-9_])Menu\\(")
        // W1 regression guard: a raw SwiftUI `TextField` on macOS edits through the
        // window field editor, whose right-click menu opens Spelling / Substitutions
        // NSPanels out of the captured surface. Text entry MUST go through the hardened
        // SecureWhiteboardTextField / SecureCodeTextView representable. Match `TextField(`
        // only when NOT preceded by an identifier char, so the hardened wrapper
        // `SecureWhiteboardTextField(` is allowed but a bare SwiftUI `TextField(` is caught.
        let swiftUITextFieldRegex = try NSRegularExpression(pattern: "(?<![A-Za-z0-9_])TextField\\(")

        var scannedFileCount = 0
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let rawContents = try String(contentsOf: fileURL, encoding: .utf8)
            let code = codeStrippedOfCommentsAndStrings(rawContents)
            scannedFileCount += 1

            for token in forbiddenTokens {
                XCTAssertFalse(
                    code.contains(token),
                    "Forbidden window-spawning token \"\(token)\" found in "
                    + "\(fileURL.lastPathComponent) (S-A6: R10.5, R10.6)")
            }

            let menuMatches = swiftUIMenuRegex.numberOfMatches(
                in: code, range: NSRange(code.startIndex..., in: code))
            XCTAssertEqual(
                menuMatches, 0,
                "Forbidden SwiftUI `Menu(` usage found in \(fileURL.lastPathComponent) "
                + "(S-A6: R10.5, R10.6)")

            let textFieldMatches = swiftUITextFieldRegex.numberOfMatches(
                in: code, range: NSRange(code.startIndex..., in: code))
            XCTAssertEqual(
                textFieldMatches, 0,
                "Forbidden SwiftUI `TextField(` usage found in \(fileURL.lastPathComponent); "
                + "use the hardened SecureWhiteboardTextField instead (W1 / S-A6: R10.5, R10.6)")
        }

        XCTAssertGreaterThan(
            scannedFileCount, 0,
            "Expected to scan at least one SecureTools .swift source under \(sourceDir.path); "
            + "scanning zero files would pass vacuously.")
    }

    // MARK: - Static-scan support

    /// Resolve the on-disk `inter/UI/SwiftUI/SecureTools` directory relative to
    /// this test's source file. From
    /// `<repo>/interTests/SecureTools/SecureToolsWindowAuditTests.swift`, three
    /// parent steps reach `<repo>`; from there descend into the source tree.
    /// Throws `XCTSkip` (rather than passing vacuously) when the directory
    /// cannot be resolved in the test environment.
    private func secureToolsSourceDirectory() throws -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()   // .../interTests/SecureTools
            .deletingLastPathComponent()   // .../interTests
            .deletingLastPathComponent()   // .../<repo>

        let sourceDir = repoRoot
            .appendingPathComponent("inter")
            .appendingPathComponent("UI")
            .appendingPathComponent("SwiftUI")
            .appendingPathComponent("SecureTools")

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceDir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw XCTSkip(
                "Could not resolve the SecureTools source directory on disk at "
                + "\(sourceDir.path); skipping the static scan rather than passing vacuously.")
        }
        return sourceDir
    }

    /// Return `source` with line comments, block comments, and string literals
    /// removed, so the static scan flags only real API usage. A single-pass
    /// state machine handles `//`, `/* */`, `"..."` (with escapes), and `"""..."""`
    /// multiline strings.
    private func codeStrippedOfCommentsAndStrings(_ source: String) -> String {
        enum Mode { case code, lineComment, blockComment, string, multiString }
        var mode: Mode = .code
        var result = ""
        let chars = Array(source)
        let n = chars.count
        var i = 0

        func peek(_ offset: Int) -> Character? {
            let j = i + offset
            return (j < n) ? chars[j] : nil
        }

        while i < n {
            let c = chars[i]
            switch mode {
            case .code:
                if c == "/" && peek(1) == "/" { mode = .lineComment; i += 2; continue }
                if c == "/" && peek(1) == "*" { mode = .blockComment; i += 2; continue }
                if c == "\"" {
                    if peek(1) == "\"" && peek(2) == "\"" { mode = .multiString; i += 3; continue }
                    mode = .string; i += 1; continue
                }
                result.append(c)
                i += 1
            case .lineComment:
                if c == "\n" { mode = .code; result.append(c) }
                i += 1
            case .blockComment:
                if c == "*" && peek(1) == "/" { mode = .code; i += 2; continue }
                i += 1
            case .string:
                if c == "\\" { i += 2; continue }       // skip escaped character
                if c == "\"" { mode = .code; i += 1; continue }
                i += 1
            case .multiString:
                if c == "\"" && peek(1) == "\"" && peek(2) == "\"" {
                    mode = .code; i += 3; continue
                }
                i += 1
            }
        }
        return result
    }
}
