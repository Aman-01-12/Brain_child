//
//  CodeEditorViewModel.swift
//  inter
//
//  View model backing the SwiftUI secure code editor (Code_Editor). In the
//  one-way candidate-tool-share model the editor is a LOCAL, single-user
//  surface: `text` is a plain in-memory @Published string with no networking
//  side effect, and the candidate may publish the rendered surface as a
//  screen-share via the capture pipeline. There is no CRDT document, transport
//  controller, remote-cursor presence, or language network register.
//
//  Follows the established @MainActor ObservableObject pattern used by
//  InterSecureChromeBridge's view models.
//

import AppKit
import SwiftUI

@MainActor
final class CodeEditorViewModel: ObservableObject {

    /// The editor's rendered text — a plain in-memory @Published string (the
    /// local one-way behaviour). The wrapped text view writes this on edit and
    /// the placeholder visibility in `CodeEditorRootView` observes it.
    @Published var text: String = ""

    /// The current language selection. The surface observes this to drive
    /// re-highlighting; changing it locally is done through `setLanguage(_:)`.
    @Published var language: String = "Plain text"

    /// Weak link to the wrapped NSTextView. Weak avoids a retain cycle between
    /// the view model (held strongly by the bridge) and the text view (held by
    /// the hosting view hierarchy).
    private weak var textView: NSTextView?

    // MARK: - Surface wiring

    /// Called by CodeEditorTextView.makeNSView to register the wrapped text
    /// view so focus activation can reach it.
    func attach(textView: NSTextView) {
        self.textView = textView
    }

    /// Makes the wrapped NSTextView the window's first responder so keystrokes
    /// route to the editor (R6.1). Returns `false` — leaving the existing first
    /// responder unchanged — when the text view is not attached, is not in a
    /// window, or cannot become first responder (R6.4).
    func requestFocus() -> Bool {
        guard let tv = textView, let window = tv.window else { return false }
        return window.makeFirstResponder(tv)
    }

    /// Releases the weak text-view linkage at teardown.
    func detach() {
        textView = nil
    }

    // MARK: - Language selection

    /// Change the editor language locally and update the published `language`
    /// so the surface re-highlights the existing content for the new language
    /// without touching the text.
    func setLanguage(_ newLanguage: String) {
        guard newLanguage != language else { return }
        language = newLanguage
    }

    // MARK: - Diff helpers

    /// Character-grained diff between two strings reduced to a single change
    /// region: the common prefix length, the number of deleted characters, and
    /// the inserted substring. Operates on `Character`s so the offsets line up
    /// with character offsets.
    static func characterDiff(old: String, new: String) -> (offset: Int, deleted: Int, inserted: String) {
        let o = Array(old)
        let n = Array(new)
        var prefix = 0
        let maxPrefix = min(o.count, n.count)
        while prefix < maxPrefix && o[prefix] == n[prefix] { prefix += 1 }

        var suffix = 0
        let maxSuffix = min(o.count, n.count) - prefix
        while suffix < maxSuffix && o[o.count - 1 - suffix] == n[n.count - 1 - suffix] { suffix += 1 }

        let deleted = o.count - prefix - suffix
        let inserted = String(n[prefix ..< (n.count - suffix)])
        return (prefix, deleted, inserted)
    }

    /// UTF-16-grained single-region diff used for caret math against the text
    /// view (whose offsets are UTF-16 units).
    static func utf16Diff(old: NSString, new: NSString) -> (offset: Int, deleted: Int, inserted: Int) {
        let oldLen = old.length
        let newLen = new.length
        var prefix = 0
        let maxPrefix = min(oldLen, newLen)
        while prefix < maxPrefix && old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }

        var suffix = 0
        let maxSuffix = min(oldLen, newLen) - prefix
        while suffix < maxSuffix
            && old.character(at: oldLen - 1 - suffix) == new.character(at: newLen - 1 - suffix) {
            suffix += 1
        }

        let deleted = oldLen - prefix - suffix
        let inserted = newLen - prefix - suffix
        return (prefix, deleted, inserted)
    }
}
