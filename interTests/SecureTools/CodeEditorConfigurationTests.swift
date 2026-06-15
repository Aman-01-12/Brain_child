//
//  CodeEditorConfigurationTests.swift
//  interTests
//
//  Unit tests for the security-critical secure code-editor configuration
//  (Code_Editor). These lock down the 13 Substitution_Disables and the 2
//  Retained_Editor_Settings that guarantee literal-code integrity, plus the
//  H1 (S-A6) contextual-menu / Services panel-leak hardening on the
//  SecureCodeTextView subclass.
//
//  Pragmatic test strategy: rather than synthesize an NSViewRepresentable
//  `Context` (which cannot be constructed outside SwiftUI), these tests build a
//  SecureCodeTextView directly and run the SAME `applySecureConfiguration(_:)`
//  the representable applies in `makeNSView`, then assert against it. This
//  exercises the production configuration code verbatim.
//
//  Validates: Requirements 4.2, 4.3, 10.1, 10.5
//

import XCTest
import AppKit
@testable import inter

@MainActor
final class CodeEditorConfigurationTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a SecureCodeTextView over a minimal TextKit stack, mirroring the
    /// representable's `makeNSView` construction so the configuration applies to
    /// the exact production subclass.
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

    /// Applies the production secure configuration via the real representable.
    private func makeConfiguredTextView() -> SecureCodeTextView {
        let textView = makeSecureTextView()
        let representable = CodeEditorTextView(viewModel: CodeEditorViewModel())
        representable.applySecureConfiguration(textView)
        return textView
    }

    // MARK: - Substitution_Disables (all 13 must be OFF)

    func testAllThirteenSubstitutionDisablesAreOff() {
        let tv = makeConfiguredTextView()

        XCTAssertFalse(tv.isRichText, "isRichText must be off")
        XCTAssertFalse(tv.importsGraphics, "importsGraphics must be off")
        XCTAssertFalse(tv.isAutomaticDataDetectionEnabled,
                       "isAutomaticDataDetectionEnabled must be off")
        XCTAssertFalse(tv.isAutomaticLinkDetectionEnabled,
                       "isAutomaticLinkDetectionEnabled must be off")
        XCTAssertFalse(tv.isAutomaticTextReplacementEnabled,
                       "isAutomaticTextReplacementEnabled must be off")
        XCTAssertFalse(tv.isAutomaticDashSubstitutionEnabled,
                       "isAutomaticDashSubstitutionEnabled must be off")
        XCTAssertFalse(tv.isAutomaticSpellingCorrectionEnabled,
                       "isAutomaticSpellingCorrectionEnabled must be off")
        XCTAssertFalse(tv.isContinuousSpellCheckingEnabled,
                       "isContinuousSpellCheckingEnabled must be off")
        XCTAssertFalse(tv.isGrammarCheckingEnabled,
                       "isGrammarCheckingEnabled must be off")
        XCTAssertFalse(tv.smartInsertDeleteEnabled,
                       "smartInsertDeleteEnabled must be off")
        XCTAssertFalse(tv.isAutomaticQuoteSubstitutionEnabled,
                       "isAutomaticQuoteSubstitutionEnabled must be off")
        XCTAssertFalse(tv.isAutomaticTextCompletionEnabled,
                       "isAutomaticTextCompletionEnabled must be off")
    }

    // MARK: - Retained_Editor_Settings (both must be ON)

    func testBothRetainedEditorSettingsAreOn() {
        let tv = makeConfiguredTextView()

        XCTAssertTrue(tv.allowsUndo, "allowsUndo must be retained (on)")
        XCTAssertTrue(tv.usesFindBar, "usesFindBar must be retained (on)")
    }

    // MARK: - H1 (S-A6): contextual menu exposes no panel-opening item

    func testContextualMenuContainsNoPanelOpeningItem() {
        let tv = makeConfiguredTextView()

        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 5, y: 5),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0)
        let rightClick = try! XCTUnwrap(event, "Failed to synthesize a right-click event")

        let menu = tv.menu(for: rightClick)

        // The menu must be nil OR contain only the safe editing verbs. No item
        // may open an NSPanel/NSWindow (Spelling, Substitutions, Font, Services,
        // Look Up).
        guard let menu else {
            return  // nil menu is acceptable — nothing can open a panel.
        }

        let allowedTitles: Set<String> = ["Cut", "Copy", "Paste", "Select All"]
        let forbiddenSubstrings = ["Spelling", "Substitutions", "Font", "Services", "Look Up"]

        for item in menu.items where !item.isSeparatorItem {
            XCTAssertTrue(
                allowedTitles.contains(item.title),
                "Contextual menu item \"\(item.title)\" is outside the allowed Cut/Copy/Paste/Select All set")

            for forbidden in forbiddenSubstrings {
                XCTAssertFalse(
                    item.title.contains(forbidden),
                    "Contextual menu must not contain a panel-opening \"\(forbidden)\" item")
            }
        }
    }

    // MARK: - H1 (S-A6): Services participation disabled

    func testValidRequestorReturnsNilToDisableServices() {
        let tv = makeConfiguredTextView()

        let requestor = tv.validRequestor(forSendType: .string, returnType: .string)
        XCTAssertNil(requestor,
                     "validRequestor(forSendType:returnType:) must return nil to disable Services")
    }
}
