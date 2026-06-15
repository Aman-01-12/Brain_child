//
//  TeamMembersViewModel.swift
//  inter
//
//  Drives the "Manage members" sheet: the team's active members, the caller's
//  role (gates the add/remove controls), instant-add-by-email, and remove.
//  Mirrors the redefined server contract:
//    • POST /teams/:id/members { email } → 201 { member } | 404 NO_INTER_ACCOUNT
//    • DELETE /teams/:id/members/:mid → { ok: true }
//    • GET /teams/:id → { members[], callerRole }
//  Owner/admin can add and remove anyone (not the owner); a plain member can
//  only remove themselves. The server is the authority — the UI gating is UX.
//
//  Data flows through an injectable `InterTeamMembersProviding` seam so the
//  add/remove/role logic is unit-testable without a live server.
//

import Foundation
import Combine

/// Distinct outcomes for an instant-add so the UI can show a precise message.
public enum InterAddMemberError: Error, Equatable {
    case noInterAccount   // 404 — email isn't registered with the platform
    case notAuthorized    // 403 — caller isn't owner/admin
    case invalidEmail     // 400 — malformed email
    case rateLimited      // 429 — too many attempts
    case other(String)    // network / unknown (carries a display string)
}

public protocol InterTeamMembersProviding: AnyObject {
    func loadMembers(teamId: String,
                     completion: @escaping (Result<(members: [InterTeamMember], callerRole: String), Error>) -> Void)
    func addMember(teamId: String, email: String,
                   completion: @escaping (Result<InterTeamMember, InterAddMemberError>) -> Void)
    func removeMember(teamId: String, memberId: String,
                      completion: @escaping (Result<Void, Error>) -> Void)
}

@MainActor
public final class TeamMembersViewModel: ObservableObject {

    @Published public private(set) var members: [InterTeamMember] = []
    @Published public private(set) var callerRole: String = "member"
    @Published public var draftEmail: String = ""
    @Published public private(set) var isLoading = false
    @Published public private(set) var isAdding = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var infoMessage: String?

    public let teamId: String
    public let teamName: String
    private let currentUserId: String?
    private let provider: InterTeamMembersProviding

    public init(teamId: String, teamName: String, currentUserId: String?,
                provider: InterTeamMembersProviding) {
        self.teamId = teamId
        self.teamName = teamName
        self.currentUserId = currentUserId
        self.provider = provider
    }

    /// Owner/admin can add members and remove others.
    public var canManage: Bool { callerRole == "owner" || callerRole == "admin" }

    /// Whether the current viewer may remove this member. The owner is never
    /// removable; owners/admins may remove others; a plain member may remove only
    /// themselves (leave).
    public func canRemove(_ member: InterTeamMember) -> Bool {
        if member.role == "owner" { return false }
        if canManage { return true }
        guard let me = currentUserId, let theirs = member.userId else { return false }
        return me == theirs
    }

    /// Whether the add field should attempt a send (non-empty + plausibly valid).
    public var canAdd: Bool {
        !isAdding && TeamMembersViewModel.isPlausibleEmail(draftEmail)
    }

    public func load() {
        isLoading = true
        errorMessage = nil
        provider.loadMembers(teamId: teamId) { [weak self] result in
            Task { @MainActor in
                guard let self = self else { return }
                self.isLoading = false
                switch result {
                case .success(let payload):
                    self.callerRole = payload.callerRole
                    self.members = payload.members.filter { $0.status == "active" }
                case .failure:
                    self.errorMessage = "Couldn't load members. Please try again."
                }
            }
        }
    }

    public func addMember() {
        let email = draftEmail.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard TeamMembersViewModel.isPlausibleEmail(email) else {
            errorMessage = TeamMembersViewModel.message(for: .invalidEmail)
            return
        }
        isAdding = true
        errorMessage = nil
        infoMessage = nil
        provider.addMember(teamId: teamId, email: email) { [weak self] result in
            Task { @MainActor in
                guard let self = self else { return }
                self.isAdding = false
                switch result {
                case .success(let member):
                    // Converge: replace any existing row for this person, else append.
                    self.members.removeAll { $0.id == member.id || $0.email.lowercased() == member.email.lowercased() }
                    self.members.append(member)
                    self.draftEmail = ""
                    self.infoMessage = "\(member.displayName) was added."
                case .failure(let err):
                    self.errorMessage = TeamMembersViewModel.message(for: err)
                }
            }
        }
    }

    public func removeMember(_ member: InterTeamMember) {
        provider.removeMember(teamId: teamId, memberId: member.id) { [weak self] result in
            Task { @MainActor in
                guard let self = self else { return }
                switch result {
                case .success:
                    self.members.removeAll { $0.id == member.id }
                    self.infoMessage = "\(member.displayName) was removed."
                case .failure:
                    self.errorMessage = "Couldn't remove \(member.displayName). Please try again."
                }
            }
        }
    }

    // MARK: - Pure helpers (unit-tested)

    /// Lightweight client-side email shape check (server re-validates). Mirrors the
    /// server's `^[^\s@]+@[^\s@]+\.[^\s@]+$` with a length bound.
    public nonisolated static func isPlausibleEmail(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 3, s.count <= 254 else { return false }
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".") && !domain.contains(" ")
    }

    public nonisolated static func message(for error: InterAddMemberError) -> String {
        switch error {
        case .noInterAccount: return "That email isn't registered with Inter yet. Ask them to sign up first."
        case .notAuthorized:  return "Only the team owner or an admin can add members."
        case .invalidEmail:   return "Enter a valid email address."
        case .rateLimited:    return "Too many attempts. Please slow down and try again."
        case .other(let s):   return s.isEmpty ? "Couldn't add that member. Please try again." : s
        }
    }

    /// Capitalised role label for the member-row chip ("owner" → "Owner").
    public nonisolated static func roleLabel(_ role: String) -> String {
        guard let first = role.first else { return role }
        return String(first).uppercased() + role.dropFirst()
    }
}
