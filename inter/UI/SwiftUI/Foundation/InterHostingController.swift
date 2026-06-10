//
//  InterHostingController.swift
//  inter
//
//  The single seam every SwiftUI screen mounts through. An `NSHostingController` that
//  pins a manual appearance (default dark) onto its hosted view, so theme tokens resolve
//  light/dark deterministically and stage tokens stay fixed dark — independent of the
//  AppKit host window's own appearance. AppKit keeps owning the NSWindow (and all of its
//  security properties); SwiftUI only ever renders *inside* this controller's view.
//

import AppKit
import SwiftUI

public final class InterHostingController<Content: View>: NSHostingController<Content> {

    private let appearanceMode: InterAppearance.Mode

    public init(mode: InterAppearance.Mode = InterAppearance.defaultMode, rootView: Content) {
        self.appearanceMode = mode
        super.init(rootView: rootView)
        // Force the hosting view to load, then pin the appearance on it. Doing this here
        // (rather than in a lifecycle callback) guarantees it is set before first display.
        self.view.appearance = InterAppearance.nsAppearance(mode)
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
