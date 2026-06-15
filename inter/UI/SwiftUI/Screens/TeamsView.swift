//
//  TeamsView.swift
//  inter
//
//  Root of the Teams screen — the SwiftUI replacement for the old AppKit teams
//  panel. Composes the left rail (TeamsSidebarView) with the selected team's
//  chat room (TeamChatView), plus the create-team and manage-members sheets.
//  Layout follows the design handoff `ref_teams` two-pane structure, with the
//  channel list replaced by the persistent group chat (per the Task 3 redefine).
//
//  Self-contained (Option A): it owns its data through the injected view models
//  / factories and surfaces file download + attach as callbacks the host wires
//  to the transport. No AppDelegate invite/accept delegate contract.
//

import SwiftUI

public struct TeamsView: View {
    @ObservedObject var listViewModel: TeamsListViewModel
    let makeChatViewModel: (InterTeamSummary) -> TeamChatViewModel
    let makeMembersViewModel: (InterTeamSummary) -> TeamMembersViewModel
    var onDownloadFile: (InterTeamSummary, InterTeamFile) -> Void
    var onAttach: (InterTeamSummary) -> Void
    var onToggleAppearance: () -> Void

    @State private var managingTeam: InterTeamSummary?
    @State private var showingCreate = false

    public init(listViewModel: TeamsListViewModel,
                makeChatViewModel: @escaping (InterTeamSummary) -> TeamChatViewModel,
                makeMembersViewModel: @escaping (InterTeamSummary) -> TeamMembersViewModel,
                onDownloadFile: @escaping (InterTeamSummary, InterTeamFile) -> Void = { _, _ in },
                onAttach: @escaping (InterTeamSummary) -> Void = { _ in },
                onToggleAppearance: @escaping () -> Void = {}) {
        self.listViewModel = listViewModel
        self.makeChatViewModel = makeChatViewModel
        self.makeMembersViewModel = makeMembersViewModel
        self.onDownloadFile = onDownloadFile
        self.onAttach = onAttach
        self.onToggleAppearance = onToggleAppearance
    }

    public var body: some View {
        HStack(spacing: 0) {
            TeamsSidebarView(viewModel: listViewModel,
                             onCreateTeam: { showingCreate = true },
                             onToggleAppearance: onToggleAppearance)
            Divider().overlay(Color(nsColor: InterColor.border))
            rightPane
        }
        .background(Color(nsColor: InterColor.card))
        // Seamless window chrome: paint surfaces up into the title-bar area (the
        // sidebar header insets itself below the floating traffic lights).
        .ignoresSafeArea(.container, edges: .top)
        .interResignsFocusOnBackgroundTap()
        .onAppear { listViewModel.loadTeams() }
        .sheet(isPresented: $showingCreate) {
            CreateTeamSheet(
                onCreate: { name in
                    listViewModel.createTeam(name: name)
                    showingCreate = false
                },
                onClose: { showingCreate = false }
            )
        }
        .sheet(item: $managingTeam) { team in
            TeamMembersView(makeViewModel: { makeMembersViewModel(team) },
                            onClose: { managingTeam = nil })
        }
    }

    @ViewBuilder private var rightPane: some View {
        if let team = listViewModel.selectedTeam {
            TeamRoomView(
                team: team,
                makeChatVM: { makeChatViewModel(team) },
                onManageMembers: { managingTeam = team },
                onDownloadFile: { onDownloadFile(team, $0) },
                onAttach: { onAttach(team) }
            )
            .id(team.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: InterSpacing.x3) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 36, weight: .regular))
                .foregroundColor(Color(nsColor: InterColor.mutedForeground).opacity(0.6))
            Text("Select a team")
                .font(InterFont.swiftUI(16, .semibold))
                .foregroundColor(Color(nsColor: InterColor.cardForeground))
            Text("Pick a team to chat and share files, or create a new one.")
                .font(InterFont.swiftUI(13))
                .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                .multilineTextAlignment(.center)
        }
        .padding(InterSpacing.x6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: InterColor.card))
    }
}

// MARK: - Per-team room (owns the chat view model's lifecycle)

/// Wraps a team's `TeamChatViewModel` as a `@StateObject` so the realtime
/// connection + history are started when the room appears and stopped when the
/// user switches teams (the parent applies `.id(team.id)` to force a fresh room
/// per selection). The view model is created exactly once per identity.
private struct TeamRoomView: View {
    @StateObject private var chatVM: TeamChatViewModel
    let team: InterTeamSummary
    var onManageMembers: () -> Void
    var onDownloadFile: (InterTeamFile) -> Void
    var onAttach: () -> Void

    init(team: InterTeamSummary,
         makeChatVM: @escaping () -> TeamChatViewModel,
         onManageMembers: @escaping () -> Void,
         onDownloadFile: @escaping (InterTeamFile) -> Void,
         onAttach: @escaping () -> Void) {
        self.team = team
        _chatVM = StateObject(wrappedValue: makeChatVM())
        self.onManageMembers = onManageMembers
        self.onDownloadFile = onDownloadFile
        self.onAttach = onAttach
    }

    var body: some View {
        TeamChatView(
            viewModel: chatVM,
            teamSeed: team.id,
            memberCount: team.memberCount,
            onDownloadFile: onDownloadFile,
            onAttach: onAttach,
            onManageMembers: onManageMembers
        )
        .onAppear { chatVM.start() }
        .onDisappear { chatVM.stop() }
    }
}

// MARK: - Create / join a team sheet

private struct CreateTeamSheet: View {
    var onCreate: (String) -> Void
    var onClose: () -> Void

    @State private var name = ""

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x4) {
            HStack {
                Text("Create a team")
                    .font(InterFont.swiftUI(16, .semibold))
                    .foregroundColor(Color(nsColor: InterColor.cardForeground))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).handCursor().help("Close")
            }

            VStack(alignment: .leading, spacing: InterSpacing.x2) {
                Text("Team name")
                    .font(InterFont.swiftUI(12, .semibold))
                    .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                InterInputField(
                    placeholder: "e.g. Platform",
                    text: $name,
                    onSubmit: { if canCreate { onCreate(name) } }
                )
            }

            Text("You'll be the owner. Add teammates by their Inter email once the team exists.")
                .font(InterFont.swiftUI(11))
                .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: InterSpacing.x2) {
                Spacer()
                InterButton("Cancel", variant: .secondary, size: .medium, action: onClose)
                InterButton("Create", variant: .primary, size: .medium,
                            enabled: canCreate, action: { onCreate(name) })
            }
        }
        .padding(InterSpacing.x5)
        .frame(width: 380)
        .background(Color(nsColor: InterColor.card))
        .interResignsFocusOnBackgroundTap()
    }
}
