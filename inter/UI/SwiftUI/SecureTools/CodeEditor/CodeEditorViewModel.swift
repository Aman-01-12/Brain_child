//
//  CodeEditorViewModel.swift
//  inter
//
//  View model backing the SwiftUI secure code editor (Code_Editor). Holds the
//  editor text in process memory only (no serialization, no networking — R11.4)
//  and owns a weak reference to the wrapped NSTextView so it can drive focus
//  activation without creating a retain cycle (see the design's memory
//  analysis). Follows the established @MainActor pattern used by
//  InterSecureChromeBridge's view models.
//

import AppKit
import SwiftUI

@MainActor
final class CodeEditorViewModel: ObservableObject {

    /// The editor's only model state. Held purely in local process memory and
    /// never serialized or transmitted off-device (R11.4). Drives the
    /// placeholder visibility in CodeEditorRootView.
    @Published var text: String = ""

    /// Weak link to the wrapped NSTextView. Weak avoids a retain cycle between
    /// the view model (held strongly by the bridge) and the text view (held by
    /// the hosting view hierarchy).
    private weak var textView: NSTextView?

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

    /// Releases the weak text-view linkage at session teardown.
    func detach() {
        textView = nil
    }
}
