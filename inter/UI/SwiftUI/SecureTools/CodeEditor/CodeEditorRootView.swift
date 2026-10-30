//
//  CodeEditorRootView.swift
//  inter
//
//  SwiftUI wrapper for the secure code editor (Code_Editor). Lays out the
//  CodeEditorTextView representable over the same dark chrome as the AppKit
//  InterSecureCodeEditorView and overlays a placeholder while the editor is
//  empty (R5.1–R5.7). This is the rootView hosted by the bridge's
//  NSHostingView<CodeEditorRootView>.
//
//  Visual parity targets (matched verbatim to InterSecureCodeEditorView):
//    - Monospaced 13pt text (the text view sets its own font; the chrome here
//      matches the surrounding visuals).
//    - Text color white @ 0.94 brightness (set on the text view).
//    - Text-area background white @ 0.10 brightness.
//    - Surrounding chrome background white @ 0.08 brightness.
//    - 16pt corner radius; 1pt border white @ 0.10 alpha.
//    - 18pt content inset on all edges.
//
//  Placeholder visibility is driven by the @Published `text` on the view model,
//  so SwiftUI flips it on the next render tick — well within the 100ms capture
//  cadence (R5.6/R5.7).
//
//  NOTE: No `.drawingGroup()` appears anywhere in this subtree. The capture
//  pipeline relies on cacheDisplayInRect: reproducing the hosted SwiftUI
//  content, and a GPU-only rendering path would defeat that (R2.2).
//

import SwiftUI

struct CodeEditorRootView: View {

    @ObservedObject var viewModel: CodeEditorViewModel

    // MARK: Visual parity constants (mirror InterSecureCodeEditorView)

    /// Surrounding chrome background: white @ 0.08 brightness.
    private let chromeBackgroundColor = Color(white: 0.08)
    /// Text-area background: white @ 0.10 brightness.
    private let textAreaBackgroundColor = Color(white: 0.10)
    /// 1pt border, white @ 0.10 alpha.
    private let borderColor = Color(white: 1.0).opacity(0.10)
    /// Placeholder text color: white @ 0.72 brightness.
    private let placeholderColor = Color(white: 0.72)

    private let chromeCornerRadius: CGFloat = 16.0
    private let textAreaCornerRadius: CGFloat = 12.0
    private let borderWidth: CGFloat = 1.0
    private let contentInset: CGFloat = 18.0
    private let placeholderInset: CGFloat = 12.0

    /// Replicates the AppKit editor's placeholder string verbatim.
    private let placeholderText =
        "Open the secure editor and type here. Only this editor surface is shared in interview mode."

    /// Native language selector (R1.3). A `.menu`-style `Picker` renders as an
    /// AppKit pop-up button — a transient NSMenu, never a separate capturable
    /// NSWindow/NSPanel (consistent with the H1 sanitized-menu posture). The
    /// selection is routed through `setLanguage(_:)` so the change advances the
    /// shared Lamport register and re-highlights, rather than writing the
    /// published property directly.
    private var languageBar: some View {
        HStack(spacing: 8.0) {
            Text("Language")
                .font(.system(size: 11.0, weight: .medium))
                .foregroundColor(placeholderColor)

            Picker("Language", selection: Binding(
                get: { viewModel.language },
                set: { viewModel.setLanguage($0) }
            )) {
                ForEach(CodeLanguage.allCases) { language in
                    Text(language.displayName).tag(language.displayName)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 170.0)

            Spacer(minLength: 0)
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Language selector chrome (R1.3): a native pop-up offering the
                // supported languages, wired to the view model's LWW language
                // register via setLanguage(_:).
                languageBar
                    .padding(.horizontal, contentInset)
                    .padding(.top, 12.0)
                    .padding(.bottom, 8.0)

                // [candidate-tool-share-tile] Single, plain editing area — no nested
                // rounded "card inside a card". The editor sits directly on the single
                // tile background and fills the whole surface below the language bar.
                ZStack {
                    CodeEditorTextView(viewModel: viewModel)

                    // Placeholder shown WHILE the editor is empty, hidden once any
                    // text is present. Driven by @Published text.
                    if viewModel.text.isEmpty {
                        Text(placeholderText)
                            .font(.system(size: 14.0, weight: .regular))
                            .foregroundColor(placeholderColor)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(.horizontal, contentInset)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(chromeBackgroundColor)
    }
}
