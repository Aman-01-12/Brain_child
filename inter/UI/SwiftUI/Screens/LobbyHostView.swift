//
//  LobbyHostView.swift
//  inter
//
//  SwiftUI port of the host-side waiting room (`lobby`). Visual source of truth:
//  inter-design-handoff/react-reference/mocks/LobbyMock.tsx (host view) +
//  reference-screens/ref_lobby_{dark,light}.png. Behaviour preserved from the legacy
//  `InterLobbyPanel` via `InterLobbyHostHostView` (delegate + public API unchanged).
//
//  Skipped per gap decisions (user 2026-06-11): per-row role, "Message waiting room".
//

import SwiftUI

public struct LobbyHostView: View {

    @ObservedObject var viewModel: LobbyHostViewModel

    public init(viewModel: LobbyHostViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            toggleRow
            eyebrow
            list
        }
        .background(Color(nsColor: InterColor.card))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: InterSpacing.x2_5) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color(nsColor: InterColor.mutedForeground))
            Text("Waiting Room")
                .font(InterFont.swiftUI(InterFont.Size.secondary, .semibold))
                .foregroundStyle(Color(nsColor: InterColor.foreground))
            countPill
            Spacer()
            if !viewModel.isEmpty {
                InterButton("Admit All (\(viewModel.count))", variant: .primary, size: .small) {
                    viewModel.admitAll()
                }
            }
        }
        .padding(.horizontal, InterSpacing.x5)
        .padding(.vertical, InterSpacing.x3)
        .background(Color(nsColor: InterColor.muted))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: InterColor.border)).frame(height: 1)
        }
    }

    private var countPill: some View {
        Text("\(viewModel.count)")
            .font(InterFont.swiftUI(InterFont.Size.dense11, .semibold))
            .foregroundStyle(Color(nsColor: InterColor.primary))
            .frame(height: 20)
            .padding(.horizontal, InterSpacing.x2)
            .background(Color(nsColor: InterColor.primary).opacity(0.15))
            .clipShape(Capsule())
    }

    // MARK: Enable-waiting-room toggle row

    private var toggleRow: some View {
        HStack(spacing: InterSpacing.x2_5) {
            InterToggle(isOn: Binding(
                get: { viewModel.lobbyEnabled },
                set: { viewModel.setLobbyEnabled($0) }
            ), enabled: viewModel.lobbyToggleEnabled)

            Text("Enable Waiting Room")
                .font(InterFont.swiftUI(InterFont.Size.secondary))
                .foregroundStyle(Color(nsColor: InterColor.foreground))
            Text("(disabled for co-hosts)")
                .font(InterFont.swiftUI(InterFont.Size.caption))
                .foregroundStyle(Color(nsColor: InterColor.mutedForeground))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, InterSpacing.x5)
        .padding(.vertical, InterSpacing.x2_5)
        .background(Color(nsColor: InterColor.card))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: InterColor.border)).frame(height: 1)
        }
        .opacity(viewModel.lobbyToggleEnabled ? 1 : 0.55)
    }

    // MARK: Section eyebrow

    private var eyebrow: some View {
        HStack {
            Text("Waiting to join".uppercased())
                .font(InterFont.swiftUI(InterFont.Size.dense11, .semibold))
                .tracking(0.5)
                .foregroundStyle(Color(nsColor: InterColor.mutedForeground))
            Spacer()
        }
        .padding(.horizontal, InterSpacing.x5)
        .padding(.top, InterSpacing.x3)
        .padding(.bottom, InterSpacing.x1_5)
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            if viewModel.isEmpty {
                Text("No one is waiting")
                    .font(InterFont.swiftUI(InterFont.Size.secondary))
                    .foregroundStyle(Color(nsColor: InterColor.mutedForeground))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else {
                LazyVStack(spacing: InterSpacing.x2) {
                    ForEach(viewModel.waiting) { entry in
                        LobbyRow(
                            entry: entry,
                            waitLabel: viewModel.waitLabel(for: entry),
                            onAdmit: { viewModel.admit(entry) },
                            onDeny: { viewModel.deny(entry) }
                        )
                    }
                }
                .padding(.horizontal, InterSpacing.x5)
                .padding(.bottom, InterSpacing.x5)
                .padding(.top, InterSpacing.x0_5)
            }
        }
    }
}

// MARK: - Row

private struct LobbyRow: View {
    let entry: LobbyWaitingEntry
    let waitLabel: String
    let onAdmit: () -> Void
    let onDeny: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: InterSpacing.x3) {
            // Avatar
            Text(entry.initials)
                .font(InterFont.swiftUI(InterFont.Size.dense11, .bold))
                .foregroundStyle(Color(nsColor: InterColor.primary))
                .frame(width: 36, height: 36)
                .background(Color(nsColor: InterColor.primary).opacity(0.15))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(InterFont.swiftUI(InterFont.Size.secondary, .semibold))
                    .foregroundStyle(Color(nsColor: InterColor.foreground))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                    Text(waitLabel)
                }
                .font(InterFont.swiftUI(InterFont.Size.caption))
                .foregroundStyle(Color(nsColor: InterColor.mutedForeground))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            InterButton("Deny", systemImage: "xmark", variant: .dangerOutline, size: .compact, action: onDeny)
            InterButton("Admit", systemImage: "checkmark", variant: .primary, size: .compact, action: onAdmit)
        }
        .padding(.horizontal, InterSpacing.x3)
        .padding(.vertical, InterSpacing.x3)
        .background(Color(nsColor: hovering ? InterColor.muted : InterColor.card))
        .overlay(
            RoundedRectangle(cornerRadius: InterRadius.xl, style: .continuous)
                .stroke(Color(nsColor: InterColor.border), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: InterRadius.xl, style: .continuous))
        .onHover { hovering = $0 }
    }
}
