//
//  ChatView.swift
//  inter
//
//  SwiftUI in-call chat content, hosted inside the legacy InterChatPanel's
//  slide-in container. Visual language follows the design handoff
//  (ref_chat_{dark,light}.png / ChatMock.tsx §7.4 collab-panel recipe): header
//  ("Meeting Chat" + Export + Close), message feed (own = violet trailing
//  bubble, others = leading bubble + avatar initial + name/time caption,
//  DM = purple tint + pill, system = centered capsule, file chip with Save…),
//  and a composer (To: recipient dropdown, 📎, rounded-full input, 😊 native
//  emoji palette, circular ➤ send).
//
//  Faithful-to-domain differences from the mock (inventory §5 wins):
//  no Chat|Polls tabs (polls is its own window), no Search/⋯ buttons, and no
//  hover reaction strip (no backing API — logged as a gap). The host bridge
//  pins dark appearance, so theme tokens resolve to the dark palette exactly
//  like today's hardcoded panel.
//

import AppKit
import SwiftUI

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            messageFeed
            composer
        }
        .background(Color(nsColor: InterColor.card))
        .interResignsFocusOnBackgroundTap()
    }

    // MARK: - Header ("Meeting Chat" + Export + Close)

    private var header: some View {
        HStack(spacing: InterSpacing.x0_5) {
            Text("Meeting Chat")
                .font(InterFont.swiftUI(InterFont.Size.secondary, .semibold))
                .foregroundColor(Color(nsColor: InterColor.foreground))
            Spacer(minLength: 0)
            if viewModel.isExportVisible {
                headerIconButton("square.and.arrow.up", help: "Export chat transcript") {
                    viewModel.export()
                }
            }
            headerIconButton("xmark", help: "Close") {
                viewModel.close()
            }
        }
        .padding(.horizontal, InterSpacing.x4)
        .frame(height: 48) // h-12
        .background(Color(nsColor: InterColor.muted))
        .overlay(Rectangle()
            .fill(Color(nsColor: InterColor.border))
            .frame(height: 1), alignment: .bottom)
    }

    private func headerIconButton(_ systemImage: String, help: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .help(help)
    }

    // MARK: - Message feed

    private var messageFeed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: InterSpacing.x3) {
                    if viewModel.messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(viewModel.messages, id: \.messageId) { message in
                            messageRow(message)
                                .id(message.messageId)
                        }
                    }
                }
                .padding(InterSpacing.x3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: viewModel.messages.count) { _ in
                if let last = viewModel.messages.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.messageId, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: InterSpacing.x2) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(Color(nsColor: InterColor.mutedForeground))
            Text("No messages yet")
                .font(InterFont.swiftUI(13, .semibold))
                .foregroundColor(Color(nsColor: InterColor.foreground))
            Text("Messages sent here are visible to everyone in the meeting.")
                .font(InterFont.swiftUI(InterFont.Size.caption))
                .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, InterSpacing.x8)
    }

    @ViewBuilder
    private func messageRow(_ message: InterChatMessageInfo) -> some View {
        if message.messageType == .system {
            systemRow(message)
        } else {
            ChatBubbleRow(
                message: message,
                caption: ChatViewModel.captionName(
                    for: message,
                    recipientName: message.isFromLocalUser && message.messageType == .directMessage
                        ? viewModel.displayName(for: message.recipientIdentity)
                        : nil),
                onDownload: { viewModel.download(message) }
            )
        }
    }

    // System message — centered capsule.
    private func systemRow(_ message: InterChatMessageInfo) -> some View {
        Text(message.text)
            .font(InterFont.swiftUI(InterFont.Size.dense11))
            .foregroundColor(Color(nsColor: InterColor.mutedForeground))
            .padding(.horizontal, InterSpacing.x2_5)
            .padding(.vertical, InterSpacing.x1)
            .background(Capsule().fill(Color(nsColor: InterColor.secondary)))
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
    }

    // MARK: - Composer (To: dropdown + 📎 + input + 😊 + ➤)

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !viewModel.participants.isEmpty {
                recipientPicker
                    .padding(.horizontal, InterSpacing.x3)
                    .padding(.top, InterSpacing.x2)
                    .padding(.bottom, InterSpacing.x1_5)
            }
            HStack(spacing: InterSpacing.x2) {
                composerIconButton("paperclip",
                                   help: viewModel.isUploading ? "Uploading…" : "Share a file (max 10 MB)",
                                   enabled: viewModel.canAttach,
                                   spinning: viewModel.isUploading) {
                    viewModel.attach()
                }

                TextField(viewModel.placeholder, text: $viewModel.draft)
                    .textFieldStyle(.plain)
                    .font(InterFont.swiftUI(13))
                    .foregroundColor(Color(nsColor: InterColor.foreground))
                    .padding(.horizontal, InterSpacing.x4)
                    .frame(height: 34)
                    .background(
                        Capsule().fill(Color(nsColor: InterColor.inputBackground))
                            .overlay(Capsule().strokeBorder(
                                Color(nsColor: inputFocused ? InterColor.ring : InterColor.border),
                                lineWidth: inputFocused ? 1.5 : 1))
                    )
                    .focused($inputFocused)
                    .disabled(!viewModel.isInputEnabled)
                    .onSubmit { viewModel.send() }

                composerIconButton("face.smiling", help: "Insert emoji",
                                   enabled: viewModel.isInputEnabled) {
                    inputFocused = true
                    NSApp.orderFrontCharacterPalette(nil)
                }

                sendButton
            }
            .padding(.horizontal, InterSpacing.x3)
            .padding(.top, viewModel.participants.isEmpty ? InterSpacing.x3 : 0)
            .padding(.bottom, InterSpacing.x3)
        }
        .background(Color(nsColor: InterColor.muted))
        .overlay(Rectangle()
            .fill(Color(nsColor: InterColor.border))
            .frame(height: 1), alignment: .top)
        .onChange(of: viewModel.focusTick) { _ in inputFocused = true }
    }

    /// "To: <Everyone | name> ⌄" — menu mirrors the legacy NSPopUpButton.
    private var recipientPicker: some View {
        Menu {
            Button("Everyone") { viewModel.selectRecipient(nil) }
            Divider()
            ForEach(viewModel.participants, id: \.identity) { participant in
                Button(participant.name) { viewModel.selectRecipient(participant.identity) }
            }
        } label: {
            HStack(spacing: InterSpacing.x1) {
                Text("To:")
                    .font(InterFont.swiftUI(InterFont.Size.dense10))
                    .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                Text(viewModel.selectedRecipientName ?? "Everyone")
                    .font(InterFont.swiftUI(InterFont.Size.caption, .semibold))
                    .foregroundColor(Color(nsColor: viewModel.selectedRecipientIdentity == nil
                        ? InterColor.foreground
                        : InterStatus.dm))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(Color(nsColor: InterColor.mutedForeground))
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .handCursor()
        .disabled(!viewModel.isInputEnabled)
    }

    private func composerIconButton(_ systemImage: String, help: String,
                                    enabled: Bool, spinning: Bool = false,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if spinning {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                }
            }
            .frame(width: 32, height: 32)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .help(help)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private var sendButton: some View {
        Button(action: { viewModel.send() }) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(viewModel.canSend
                    ? .white
                    : Color(nsColor: InterColor.mutedForeground).opacity(0.5))
                .frame(width: 32, height: 32)
                .background(Circle().fill(viewModel.canSend
                    ? Color(nsColor: InterColor.primary)
                    : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .disabled(!viewModel.canSend)
        .help("Send")
        .animation(.easeInOut(duration: 0.15), value: viewModel.canSend)
    }
}

// MARK: - One message row (bubble + avatar + caption + optional file chip)

private struct ChatBubbleRow: View {
    let message: InterChatMessageInfo
    let caption: String?
    var onDownload: () -> Void

    private var isMe: Bool { message.isFromLocalUser }
    private var isDM: Bool { message.messageType == .directMessage }
    private var isFile: Bool { message.messageType == .fileMessage }

    var body: some View {
        HStack(alignment: .top, spacing: InterSpacing.x2_5) {
            if isMe { Spacer(minLength: InterSpacing.x8) }

            if !isMe { avatar }

            VStack(alignment: isMe ? .trailing : .leading, spacing: InterSpacing.x0_5) {
                if let caption {
                    HStack(spacing: InterSpacing.x2) {
                        Text(caption)
                            .font(InterFont.swiftUI(InterFont.Size.caption, .semibold))
                            .foregroundColor(Color(nsColor: isDM && isMe
                                ? InterStatus.dm
                                : InterColor.foreground))
                            .lineLimit(1)
                        Text(message.formattedTime)
                            .font(InterFont.swiftUI(InterFont.Size.dense10))
                            .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                        if isDM {
                            dmPill
                        }
                    }
                }

                bubble

                if isMe && caption == nil {
                    Text(message.formattedTime)
                        .font(InterFont.swiftUI(InterFont.Size.dense10))
                        .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                        .padding(.top, 1)
                }
            }

            if !isMe { Spacer(minLength: InterSpacing.x8) }
        }
        .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
    }

    private var avatar: some View {
        Text(ChatViewModel.initial(for: message.senderName))
            .font(InterFont.swiftUI(InterFont.Size.dense10, .bold))
            .foregroundColor(Color(nsColor: isDM ? InterStatus.dm : InterColor.primary))
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color(nsColor: isDM ? InterStatus.dm : InterColor.primary)
                .opacity(0.16)))
            .padding(.top, 2)
    }

    private var dmPill: some View {
        Text("DM")
            .font(InterFont.swiftUI(InterFont.Size.dense10, .semibold))
            .foregroundColor(Color(nsColor: InterStatus.dm))
            .padding(.horizontal, InterSpacing.x1_5)
            .background(Capsule().fill(Color(nsColor: InterStatus.dm).opacity(0.16)))
    }

    // Asymmetric corner: the corner nearest the sender is tightened (mock's
    // rounded-br-sm / rounded-bl-sm).
    private var bubbleShape: UnevenRoundedRectangle {
        let r = InterRadius.xl + 2 // rounded-2xl 16
        let tight: CGFloat = 4
        return UnevenRoundedRectangle(
            topLeadingRadius: r,
            bottomLeadingRadius: isMe ? r : tight,
            bottomTrailingRadius: isMe ? tight : r,
            topTrailingRadius: r,
            style: .continuous)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x2) {
            if isFile {
                fileChip
            }
            if !message.text.isEmpty {
                Text(message.text) // pure Text — user content never executes
                    .font(InterFont.swiftUI(13))
                    .lineSpacing(2)
                    .foregroundColor(bubbleForeground)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, InterSpacing.x3)
        .padding(.vertical, InterSpacing.x2)
        .background(
            bubbleShape.fill(bubbleFill)
                .overlay(bubbleShape.strokeBorder(bubbleBorder, lineWidth: isDM && !isMe ? 1 : 0))
        )
    }

    private var bubbleFill: Color {
        if isMe { return Color(nsColor: InterColor.primary) }
        if isDM { return Color(nsColor: InterStatus.dm).opacity(0.12) }
        return Color(nsColor: InterColor.secondary)
    }

    private var bubbleForeground: Color {
        if isMe { return .white }
        return Color(nsColor: InterColor.foreground)
    }

    private var bubbleBorder: Color {
        isDM && !isMe ? Color(nsColor: InterStatus.dm).opacity(0.30) : .clear
    }

    // File chip: icon + name + size + "Save…" (inventory §5).
    private var fileChip: some View {
        HStack(spacing: InterSpacing.x2) {
            Image(systemName: "paperclip")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(nsColor: InterStatus.danger))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                    .fill(Color(nsColor: InterStatus.danger).opacity(0.14)))

            VStack(alignment: .leading, spacing: 0) {
                Text(message.fileName)
                    .font(InterFont.swiftUI(InterFont.Size.dense11, .medium))
                    .foregroundColor(Color(nsColor: InterColor.foreground))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(message.formattedFileSize)
                    .font(InterFont.swiftUI(InterFont.Size.dense10))
                    .foregroundColor(Color(nsColor: InterColor.mutedForeground))
            }
            .frame(minWidth: 0)

            Button(action: onDownload) {
                Text("Save…")
                    .font(InterFont.swiftUI(InterFont.Size.dense11, .semibold))
                    .foregroundColor(Color(nsColor: InterColor.primary))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()
            .help("Save file to disk")
        }
        .padding(InterSpacing.x2)
        .frame(width: 200)
        .background(
            RoundedRectangle(cornerRadius: InterRadius.lg, style: .continuous)
                .fill(Color(nsColor: InterColor.card))
                .overlay(RoundedRectangle(cornerRadius: InterRadius.lg, style: .continuous)
                    .strokeBorder(Color(nsColor: InterColor.border), lineWidth: 1))
        )
    }
}
