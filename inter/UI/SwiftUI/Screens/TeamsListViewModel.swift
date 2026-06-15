//
//  TeamsListViewModel.swift
//  inter
//
//  Drives the Teams sidebar: the list of teams the user belongs to, each with an
//  in-app unread badge, plus selection and team creation. Mirrors the design
//  handoff `ref_teams` sidebar (team rows + "Create or join a team"), with the
//  unread badge reusing the violet count pill from that screen's channel list.
//
//  Data comes through an injectable `InterTeamsListProviding` seam so the
//  selection / unread / create logic is unit-testable without a live server.
//

import Foundation
import Combine

/// The teams-list REST surface the sidebar depends on (list + create). Per-team
/// chat + member management are separate concerns (InterTeamsChatService / the
/// members view); this is only what the sidebar itself needs.
public protocol InterTeamsListProviding: AnyObject {
    func loadTeams(completion: @escaping (Result<[InterTeamSummary], Error>) -> Void)
    func createTeam(name: String, description: String?,
                    completion: @escaping (Result<InterTeamSummary, Error>) -> Void)
}

@MainActor
public final class TeamsListViewModel: ObservableObject {

    @Published public private(set) var teams: [InterTeamSummary] = []
    @Published public private(set) var selectedTeamId: String?
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var errorMessage: String?

    private let provider: InterTeamsListProviding

    public init(provider: InterTeamsListProviding) {
        self.provider = provider
    }

    /// The currently-selected team, if any.
    public var selectedTeam: InterTeamSummary? {
        guard let id = selectedTeamId else { return nil }
        return teams.first { $0.id == id }
    }

    public func loadTeams() {
        isLoading = true
        errorMessage = nil
        provider.loadTeams { [weak self] result in
            Task { @MainActor in
                guard let self = self else { return }
                self.isLoading = false
                switch result {
                case .success(let teams):
                    self.teams = teams
                    // Preserve selection if still present; otherwise select the first team.
                    if let sel = self.selectedTeamId, teams.contains(where: { $0.id == sel }) {
                        // keep current selection
                    } else {
                        self.selectedTeamId = teams.first?.id
                    }
                case .failure:
                    self.errorMessage = "Couldn't load your teams. Please try again."
                }
            }
        }
    }

    /// Select a team and optimistically clear its unread badge (the chat service
    /// advances the server read cursor when the room opens).
    public func selectTeam(_ teamId: String) {
        selectedTeamId = teamId
        clearUnread(teamId)
    }

    /// Zero a team's unread badge locally (optimistic; server cursor is advanced
    /// by the chat service on open / on new-message receipt).
    public func clearUnread(_ teamId: String) {
        guard let idx = teams.firstIndex(where: { $0.id == teamId }), teams[idx].unreadCount != 0 else { return }
        let t = teams[idx]
        teams[idx] = InterTeamSummary(id: t.id, name: t.name, description: t.description,
                                      ownerUserId: t.ownerUserId, memberCount: t.memberCount,
                                      unreadCount: 0)
    }

    public func createTeam(name: String, description: String? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        provider.createTeam(name: trimmed, description: description) { [weak self] result in
            Task { @MainActor in
                guard let self = self else { return }
                switch result {
                case .success(let team):
                    // Insert (or move) to the front and select it.
                    self.teams.removeAll { $0.id == team.id }
                    self.teams.insert(team, at: 0)
                    self.selectedTeamId = team.id
                case .failure:
                    self.errorMessage = "Couldn't create the team. Please try again."
                }
            }
        }
    }

    // MARK: - Pure presentation helpers (unit-tested)

    /// Two-letter uppercase initials for a team's avatar tile (e.g. "Platform" → "PL").
    public nonisolated static func avatarInitials(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "?" }
        let words = trimmed.split(separator: " ")
        if words.count >= 2 {
            return (String(words[0].prefix(1)) + String(words[1].prefix(1))).uppercased()
        }
        return String(trimmed.prefix(2)).uppercased()
    }

    /// Capped unread badge text; nil when there is nothing unread (no badge shown).
    public nonisolated static func unreadBadgeText(_ count: Int) -> String? {
        if count <= 0 { return nil }
        return count > 9 ? "9+" : String(count)
    }
}
