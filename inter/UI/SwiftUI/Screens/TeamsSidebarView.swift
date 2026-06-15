//
//  TeamsSidebarView.swift
//  inter
//
//  Left rail of the Teams screen, matching the design handoff `ref_teams`
//  sidebar: a "Teams" header with a + button, a scrollable list of team rows
//  (colour avatar tile + name + member count + unread badge), the selected row
//  highlighted with a violet tint, and a "Create or join a team" footer button.
//  The per-team unread badge reuses that screen's violet count pill.
//
//  Presentation only — selection and creation are surfaced as callbacks so the
//  container owns the data (TeamsListViewModel) and the create flow.
//

import SwiftUI

struct TeamsSidebarView: View {
    @ObservedObject var viewModel: TeamsListViewModel
    var onCreateTeam: () -> Void
    var onToggleAppearance: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @State private var footerHovering = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .interTitlebarInset() // clear the floating traffic lights (seamless chrome)
            list
            footer
        }
        .frame(width: 224) // w-56
        .background(Color(nsColor: InterColor.muted)) // bg-muted per TeamsMock.tsx
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: InterSpacing.x1) {
            Text("Teams")
                .font(InterFont.swiftUI(14, .semibold)) // text-sm font-semibold
                .foregroundColor(Color(nsColor: InterColor.foreground))
            Spacer()
            SidebarIconButton(systemName: colorScheme == .dark ? "sun.max.fill" : "moon.fill",
                              help: colorScheme == .dark ? "Switch to light mode" : "Switch to dark mode",
                              action: onToggleAppearance)
            SidebarIconButton(systemName: "plus",
                              help: "Create or join a team",
                              action: onCreateTeam)
        }
        .padding(.horizontal, InterSpacing.x4)
        .frame(height: 48) // h-12
    }

    // MARK: - List

    @ViewBuilder private var list: some View {
        if viewModel.isLoading && viewModel.teams.isEmpty {
            VStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.teams.isEmpty {
            VStack(spacing: InterSpacing.x2) {
                Spacer()
                Text("No teams yet")
                    .font(InterFont.swiftUI(13, .semibold))
                    .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                Text("Create a team to start chatting and sharing files.")
                    .font(InterFont.swiftUI(11))
                    .foregroundColor(Color(nsColor: InterColor.mutedForeground).opacity(0.8))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.horizontal, InterSpacing.x4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: InterSpacing.x1) {
                    ForEach(viewModel.teams) { team in
                        TeamSidebarRow(
                            team: team,
                            isSelected: team.id == viewModel.selectedTeamId,
                            onTap: { viewModel.selectTeam(team.id) }
                        )
                    }
                }
                .padding(InterSpacing.x2)
            }
        }
    }

    // MARK: - Footer

    // Fixed content height (36) + p-3 padding = 60pt total, matching the chat
    // composer's resting height exactly so the two top dividers align.
    private var footer: some View {
        Button(action: onCreateTeam) {
            HStack(spacing: InterSpacing.x1_5) {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                Text("Create or join a team").font(InterFont.swiftUI(12, .semibold))
            }
            .foregroundColor(Color(nsColor: InterColor.primary))
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: InterRadius.lg, style: .continuous)
                    .fill(Color(nsColor: InterColor.primary).opacity(footerHovering ? 0.10 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .onHover { footerHovering = $0 }
        .padding(InterSpacing.x3)
    }
}

// MARK: - Header icon button (w-7 h-7 rounded-md, hover:bg-secondary)

private struct SidebarIconButton: View {
    let systemName: String
    let help: String
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                        .fill(Color(nsColor: InterColor.secondary).opacity(hovering ? 1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - One team row

private struct TeamSidebarRow: View {
    let team: InterTeamSummary
    let isSelected: Bool
    var onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: InterSpacing.x2_5) {
                TeamAvatarTile(name: team.name, seed: team.id, size: 32, cornerRadius: InterRadius.lg)
                VStack(alignment: .leading, spacing: 1) {
                    Text(team.name)
                        .font(InterFont.swiftUI(12, .semibold))
                        .foregroundColor(Color(nsColor: InterColor.foreground))
                        .lineLimit(1)
                    Text("\(team.memberCount) member\(team.memberCount == 1 ? "" : "s")")
                        .font(InterFont.swiftUI(10))
                        .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                        .lineLimit(1)
                }
                Spacer(minLength: InterSpacing.x1)
                if let badge = TeamsListViewModel.unreadBadgeText(team.unreadCount) {
                    Text(badge)
                        .font(InterFont.swiftUI(10, .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, InterSpacing.x1_5)
                        .frame(minWidth: 20, minHeight: 18)
                        .background(Capsule().fill(Color(nsColor: InterColor.primary)))
                        .accessibilityLabel("\(team.unreadCount) unread")
                }
            }
            .padding(.horizontal, InterSpacing.x2_5)
            .padding(.vertical, InterSpacing.x2_5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                    .fill(rowBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                            .strokeBorder(Color(nsColor: InterColor.primary).opacity(isSelected ? 0.30 : 0),
                                          lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .handCursor()
        .onHover { isHovering = $0 }
    }

    private var rowBackground: Color {
        if isSelected { return Color(nsColor: InterColor.primary).opacity(0.12) }
        if isHovering { return Color(nsColor: InterColor.accent) } // hover:bg-accent
        return .clear
    }
}
