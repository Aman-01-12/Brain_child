//
//  CodeEditorRootViewTests.swift
//  interTests
//
//  Unit tests for placeholder visibility toggling in CodeEditorRootView
//  (Code_Editor). The placeholder label is shown WHILE `viewModel.text.isEmpty`
//  and hidden once any character is present, driven by the @Published `text`
//  on CodeEditorViewModel.
//
//  SwiftUI view-body visibility is awkward to introspect directly, so these
//  tests exercise the DRIVING CONDITION that governs placeholder visibility —
//  the `text.isEmpty` predicate on the view model — which is exactly the
//  expression CodeEditorRootView.body branches on. A CodeEditorRootView is also
//  constructed to confirm the view compiles against the model.
//
//  Validates: Requirements 5.5, 5.6, 5.7
//

import XCTest
import SwiftUI
@testable import inter

@MainActor
final class CodeEditorRootViewTests: XCTestCase {

    /// The placeholder-visibility predicate as used in CodeEditorRootView.body:
    /// the placeholder is rendered `if viewModel.text.isEmpty`.
    private func placeholderIsVisible(for viewModel: CodeEditorViewModel) -> Bool {
        viewModel.text.isEmpty
    }

    // R5.5: WHILE the editor contains zero characters, the placeholder is shown.
    func testPlaceholderShownWhenEmpty() {
        let viewModel = CodeEditorViewModel()

        XCTAssertTrue(viewModel.text.isEmpty,
                      "A fresh view model starts with empty text")
        XCTAssertTrue(placeholderIsVisible(for: viewModel),
                      "R5.5: placeholder must be visible while the editor is empty")
    }

    // R5.6: WHEN at least one character is entered, the placeholder is hidden.
    func testPlaceholderHiddenWhenTextEntered() {
        let viewModel = CodeEditorViewModel()

        viewModel.text = "x"

        XCTAssertFalse(viewModel.text.isEmpty,
                       "Text is non-empty after entering a character")
        XCTAssertFalse(placeholderIsVisible(for: viewModel),
                       "R5.6: placeholder must be hidden once any character is present")
    }

    // R5.7: WHEN the last remaining character is deleted, the placeholder
    // reappears (visibility predicate flips false -> true).
    func testPlaceholderReappearsWhenCleared() {
        let viewModel = CodeEditorViewModel()

        viewModel.text = "some code"
        XCTAssertFalse(placeholderIsVisible(for: viewModel),
                       "Placeholder hidden while text is present")

        viewModel.text = ""
        XCTAssertTrue(placeholderIsVisible(for: viewModel),
                      "R5.7: placeholder must reappear once the editor is emptied again")
    }

    // Sanity check that CodeEditorRootView builds against the view model.
    // No body introspection — this just ensures the view compiles and can be
    // instantiated with the @Published-driven model.
    func testRootViewBuildsAgainstViewModel() {
        let viewModel = CodeEditorViewModel()
        let view = CodeEditorRootView(viewModel: viewModel)

        XCTAssertNotNil(view.body,
                        "CodeEditorRootView should construct a body against the view model")
    }
}
