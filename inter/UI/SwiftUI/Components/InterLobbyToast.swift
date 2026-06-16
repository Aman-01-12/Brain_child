//
//  InterLobbyToast.swift
//  inter
//
//  Transient "someone is waiting in the lobby" toast for the normal call window.
//  Positioned bottom-LEFT, just above the SwiftUI control bar (per the approved
//  waiting-room notification design). Fires only for newly-seen waiters (the
//  moderation controller already dedupes the join delegate), coalesces into a
//  single banner when several arrive, auto-dismisses, and offers an "Open"
//  action that surfaces the Waiting Room panel.
//
//  Hosted via a thin @objc presenter so AppDelegate (Objective-C) can drive it
//  exactly like the other call-window chrome. The hosting view is sized to the
//  card only, so clicks outside it pass through to the video tiles underneath.
//

import AppKit
import SwiftUI

@MainActor
final class LobbyToastModel: ObservableObject {
    @Published var message: String = ""
}

struct LobbyToastView: View {
    @ObservedObject var model: LobbyToastModel
    let onOpen: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: InterSpacing.x2) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color(nsColor: InterColor.primary))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text("Waiting Room")
                    .font(InterFont.swiftUI(10, .semibold))
                    .foregroundColor(.white.opacity(0.55))
                Text(model.message)
                    .font(InterFont.swiftUI(13, .medium))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: InterSpacing.x2)

            Button(action: onOpen) {
                Text("Open")
                    .font(InterFont.swiftUI(12, .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, InterSpacing.x2_5)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                        .fill(Color(nsColor: InterColor.primary)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()
            .help("Open the Waiting Room")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()
            .help("Dismiss")
        }
        .padding(.horizontal, InterSpacing.x3)
        .padding(.vertical, InterSpacing.x2_5)
        .background(RoundedRectangle(cornerRadius: InterRadius.lg, style: .continuous)
            .fill(Color(nsColor: InterColor.stage)))
        .overlay(RoundedRectangle(cornerRadius: InterRadius.lg, style: .continuous)
            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}

/// Thin AppKit presenter that owns the toast's hosting view and lifecycle.
@MainActor
@objc(InterLobbyToastPresenter)
public final class InterLobbyToastPresenter: NSObject {

    private let model = LobbyToastModel()
    private weak var parentView: NSView?
    private var hostingView: NSHostingView<LobbyToastView>?
    private var dismissWorkItem: DispatchWorkItem?
    private let barInset: CGFloat
    /// True while the dismiss fade-out is in flight, so a `show(message:)` racing the
    /// 0.2s animation cancels the teardown and restores the existing toast instead of
    /// creating a second overlapping one (the "coalesce into a single banner" contract).
    private var isDismissing = false

    /// Invoked when the host taps "Open". The toast dismisses itself afterward.
    @objc public var onOpen: (() -> Void)?

    /// - Parameters:
    ///   - parentView: the call-window content view the toast is added into.
    ///   - barInset: the control-bar height; the toast floats just above it.
    @objc public init(parentView: NSView, barInset: CGFloat) {
        self.parentView = parentView
        self.barInset = barInset
        super.init()
    }

    /// Show (or coalesce into) the toast with `message` and (re)arm auto-dismiss.
    @objc public func show(message: String) {
        guard let parent = parentView else { return }
        model.message = message

        if let host = hostingView {
            // Existing toast (possibly mid-dismiss): cancel the fade-out and restore it
            // so rapid arrivals coalesce into one banner instead of overlapping.
            dismissWorkItem?.cancel()
            dismissWorkItem = nil
            isDismissing = false
            host.animator().alphaValue = 1
        } else {
            let host = NSHostingView(rootView: LobbyToastView(
                model: model,
                onOpen: { [weak self] in self?.handleOpen() },
                onClose: { [weak self] in self?.dismiss() }))
            host.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(host, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 16),
                host.bottomAnchor.constraint(equalTo: parent.bottomAnchor,
                                             constant: -(barInset + 12)),
                host.widthAnchor.constraint(equalToConstant: 320),
            ])
            host.alphaValue = 0
            host.animator().alphaValue = 1
            hostingView = host
        }

        scheduleAutoDismiss()
    }

    /// Hide and remove the toast (idempotent).
    @objc public func dismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        guard let host = hostingView, !isDismissing else { return }
        isDismissing = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            host.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // If a show() cancelled the dismiss mid-flight, the toast was restored —
            // don't tear it down.
            guard let self, self.isDismissing else { return }
            host.removeFromSuperview()
            self.hostingView = nil
            self.isDismissing = false
        })
    }

    private func handleOpen() {
        onOpen?()
        dismiss()
    }

    private func scheduleAutoDismiss() {
        dismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: work)
    }
}
