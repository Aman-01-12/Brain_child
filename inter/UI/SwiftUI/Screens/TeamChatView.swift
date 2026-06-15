//
//  TeamChatView.swift
//  inter
//
//  SwiftUI chat pane for a team room. Visual language is taken from the design
//  handoff chat reference (ref_chat_{dark,light}.png / ChatMock.tsx): sender
//  bubbles (mine = violet, others = secondary), avatar initials, file chips with
//  download, and an attach | pill-input | send composer. In-call-only elements
//  from that reference are intentionally excluded (Polls tab, "To: Everyone" DM
//  recipient selector, emoji reactions — out of scope per the design spec §3).
//
//  Rendering is pure SwiftUI `Text` — user content can never execute (paranoid H7).
//

import SwiftUI

public struct TeamChatView: View {
    @ObservedObject var viewModel: TeamChatViewModel
    /// Stable seed (team id) for the header avatar's deterministic colour.
    var teamSeed: String
    /// Member count shown in the header (0 hides the label).
    var memberCount: Int
    /// Invoked when the user taps a file chip's download control.
    var onDownloadFile: (InterTeamFile) -> Void
    /// Invoked when the user taps the attach button.
    var onAttach: () -> Void
    /// Invoked when the user taps "Manage members" in the header.
    var onManageMembers: () -> Void

    @FocusState private var composerFocused: Bool

    public init(viewModel: TeamChatViewModel,
                teamSeed: String = "",
                memberCount: Int = 0,
                onDownloadFile: @escaping (InterTeamFile) -> Void = { _ in },
                onAttach: @escaping () -> Void = {},
                onManageMembers: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.teamSeed = teamSeed
        self.memberCount = memberCount
        self.onDownloadFile = onDownloadFile
        self.onAttach = onAttach
        self.onManageMembers = onManageMembers
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            messageList
            composer
        }
        .background(Color(nsColor: InterColor.card))
        .interResignsFocusOnBackgroundTap()
    }

    // MARK: - Header (two rows, per ref_teams: identity+status, then members+manage)

    private var header: some View {
        VStack(spacing: 0) {
            // Row 1 — team identity + connection status (h-12 px-5 bg-card)
            HStack(spacing: InterSpacing.x2 + 2) {
                TeamAvatarTile(name: viewModel.teamName, seed: teamSeed, size: 28)
                Text(viewModel.teamName)
                    .font(InterFont.swiftUI(14, .semibold)) // text-sm font-semibold
                    .foregroundColor(Color(nsColor: InterColor.cardForeground))
                    .lineLimit(1)
                connectionBadge
                Spacer(minLength: 0)
            }
            .padding(.horizontal, InterSpacing.x5)
            .frame(height: 48)


            // Row 2 — member count + manage members
            HStack(spacing: InterSpacing.x2) {
                if memberCount > 0 {
                    Text("\(memberCount) member\(memberCount == 1 ? "" : "s")")
                        .font(InterFont.swiftUI(12))
                        .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button(action: onManageMembers) {
                    Text("Manage members")
                        .font(InterFont.swiftUI(12, .semibold))
                        .foregroundColor(Color(nsColor: InterColor.primary))
                }
                .buttonStyle(.plain)
                .handCursor()
                .help("Add or remove members")
            }
            .padding(.horizontal, InterSpacing.x5) // px-5
            .padding(.vertical, InterSpacing.x3)   // py-3
        }
        .background(Color(nsColor: InterColor.card))
    }

    @ViewBuilder private var connectionBadge: some View {
        let (color, label): (NSColor, String) = {
            switch viewModel.connectionState {
            case .connected:    return (InterStatus.success, "Active")
            case .connecting:   return (InterStatus.warning, "Connecting")
            case .reconnecting: return (InterStatus.warning, "Reconnecting")
            case .disconnected: return (InterStatus.danger, "Offline")
            }
        }()
        Text(label)
            .font(InterFont.swiftUI(10, .semibold))
            .foregroundColor(Color(nsColor: color))
            .padding(.horizontal, InterSpacing.x1_5) // px-1.5
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(nsColor: color).opacity(0.16)))
            .accessibilityLabel("Connection: \(label)")
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: InterSpacing.x3) {
                    ForEach(viewModel.messages, id: \.id) { message in
                        TeamMessageRow(
                            message: message,
                            isMine: viewModel.isMine(message),
                            initials: viewModel.initials(message),
                            timeLabel: viewModel.timeLabel(message),
                            onDownloadFile: onDownloadFile,
                            onRetry: { viewModel.retry(message) }
                        )
                        .id(message.id)
                    }
                }
                .padding(InterSpacing.x3)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                // Keep the newest message visible as it arrives / is sent.
                if let last = viewModel.messages.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: InterSpacing.x2) {
            Button(action: onAttach) {
                Image(systemName: "paperclip")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(Color(nsColor: InterColor.cardForeground).opacity(0.6))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .handCursor()
            .help("Attach a file")

            TextField("Type a message…", text: $viewModel.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(InterFont.swiftUI(14))
                .lineLimit(1...5)
                .padding(.horizontal, InterSpacing.x4)
                .padding(.vertical, 8)
                .frame(minHeight: 36) // ChatMock input: py-2 + text-sm → 36 resting
                .background(
                    RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                        .fill(Color(nsColor: InterColor.inputBackground))
                        .overlay(RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                            .strokeBorder(Color(nsColor: composerFocused ? InterColor.ring : InterColor.border),
                                          lineWidth: composerFocused ? 1.5 : 1))
                )
                .focused($composerFocused)
                .onSubmit { viewModel.send() }

            Button(action: { viewModel.send() }) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(viewModel.canSend
                        ? Color(nsColor: InterColor.primaryForeground)
                        : Color(nsColor: InterColor.cardForeground).opacity(0.3))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(viewModel.canSend
                        ? Color(nsColor: InterColor.primary)
                        : Color.clear))
            }
            .buttonStyle(.plain)
            .handCursor()
            .disabled(!viewModel.canSend)
            .help("Send")
        }
        .padding(.horizontal, InterSpacing.x3) // px-3 per ChatMock composer
        .padding(.vertical, InterSpacing.x3)
        // Blend the bar with the chat canvas; the INPUT carries the contrast
        // (inputBackground = lighter slate on dark, darker periwinkle on light).
        .background(Color(nsColor: InterColor.card))
    }
}

// MARK: - One message row (avatar + bubble + file/thumbnail)

struct TeamMessageRow: View {
    let message: InterTeamMessage
    let isMine: Bool
    let initials: String
    let timeLabel: String
    var onDownloadFile: (InterTeamFile) -> Void
    var onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: InterSpacing.x2 + 2) {
            if isMine { Spacer(minLength: 40) } else { avatar }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
                if !isMine {
                    HStack(spacing: InterSpacing.x2) {
                        Text(message.senderName)
                            .font(InterFont.swiftUI(12, .semibold))
                            .foregroundColor(Color(nsColor: InterColor.cardForeground))
                        Text(timeLabel)
                            .font(InterFont.swiftUI(10))
                            .foregroundColor(Color(nsColor: InterColor.cardForeground).opacity(0.5))
                    }
                }
                bubble
                if isMine {
                    HStack(spacing: 4) {
                        if message.status == .pending { statusLabel("Sending…") }
                        if message.status == .failed {
                            Button(action: onRetry) { statusLabel("Failed — retry") }
                                .buttonStyle(.plain).handCursor()
                        }
                        if message.status == .confirmed { statusLabel(timeLabel) }
                    }
                }
            }
            if isMine { avatar } else { Spacer(minLength: 40) }
        }
    }

    private func statusLabel(_ s: String) -> some View {
        Text(s)
            .font(InterFont.swiftUI(10))
            .foregroundColor(Color(nsColor: message.status == .failed ? InterStatus.danger : InterColor.cardForeground).opacity(message.status == .failed ? 1 : 0.5))
    }

    private var avatar: some View {
        Circle()
            .fill(Color(nsColor: InterColor.primary).opacity(0.18))
            .frame(width: 28, height: 28)
            .overlay(
                Text(initials)
                    .font(InterFont.swiftUI(10, .bold))
                    .foregroundColor(Color(nsColor: InterColor.primary))
            )
    }

    @ViewBuilder private var bubble: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x2) {
            if let body = message.body, !body.isEmpty {
                Text(body)   // pure Text — no HTML/markdown execution (H7)
                    .font(InterFont.swiftUI(14))
                    .foregroundColor(isMine
                        ? Color(nsColor: InterColor.primaryForeground)
                        : Color(nsColor: InterColor.cardForeground))
                    .textSelection(.enabled)
            }
            if let file = message.file {
                if file.isImage {
                    fileThumbnail(file)
                } else {
                    fileChip(file)
                }
            }
        }
        .padding(.horizontal, InterSpacing.x3)
        .padding(.vertical, InterSpacing.x2 + 2)
        .background(
            RoundedRectangle(cornerRadius: InterRadius.bubble, style: .continuous)
                .fill(isMine ? Color(nsColor: InterColor.primary) : Color(nsColor: InterColor.secondary))
        )
        .opacity(message.status == .pending ? 0.7 : 1)
    }

    // File download chip — icon, name, size, download control.
    private func fileChip(_ file: InterTeamFile) -> some View {
        HStack(spacing: InterSpacing.x2) {
            Image(systemName: "paperclip")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(nsColor: InterColor.primary))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: InterRadius.sm).fill(Color(nsColor: InterColor.primary).opacity(0.15)))
            VStack(alignment: .leading, spacing: 1) {
                Text(file.originalName)
                    .font(InterFont.swiftUI(11, .medium))
                    .foregroundColor(bubbleSecondaryText)
                    .lineLimit(1).truncationMode(.middle)
                Text(byteLabel(file.sizeBytes))
                    .font(InterFont.swiftUI(10))
                    .foregroundColor(bubbleSecondaryText.opacity(0.7))
            }
            .frame(maxWidth: 150, alignment: .leading)
            Button(action: { onDownloadFile(file) }) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(bubbleSecondaryText.opacity(0.8))
            }
            .buttonStyle(.plain).handCursor().help("Download")
        }
        .padding(InterSpacing.x2)
        .background(RoundedRectangle(cornerRadius: InterRadius.md).fill(Color(nsColor: InterColor.card)))
    }

    // Image attachment — tappable thumbnail placeholder (bytes fetched on demand).
    private func fileThumbnail(_ file: InterTeamFile) -> some View {
        Button(action: { onDownloadFile(file) }) {
            ZStack {
                RoundedRectangle(cornerRadius: InterRadius.md)
                    .fill(Color(nsColor: InterColor.card))
                    .frame(width: 180, height: 120)
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundColor(Color(nsColor: InterColor.primary).opacity(0.7))
                    Text(file.originalName)
                        .font(InterFont.swiftUI(10))
                        .foregroundColor(bubbleSecondaryText.opacity(0.8))
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 160)
                }
            }
        }
        .buttonStyle(.plain).handCursor().help("Open image")
    }

    private var bubbleSecondaryText: Color {
        isMine ? Color(nsColor: InterColor.primaryForeground) : Color(nsColor: InterColor.cardForeground)
    }

    private func byteLabel(_ bytes: Int64?) -> String {
        guard let bytes = bytes else { return "" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}
