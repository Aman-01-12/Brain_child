// ============================================================================
// InterPermissions.swift
// inter
//
// Phase 9.1.2 — Role-based permission model for meeting management.
//
// Defines participant roles and their associated permissions.
// The permission matrix determines what actions each role can perform.
// Roles are assigned via JWT metadata from the token server and can be
// changed at runtime via the POST /room/promote endpoint.
//
// ROLES (ordered by privilege):
//   Host      — Room creator. All permissions. Cannot be demoted.
//   Co-host   — Promoted by host. All permissions except promoting to host.
//   Panelist  — Can unmute self, share screen, launch polls. No moderation.
//   Presenter — Can unmute self and share screen. No moderation.
//   Participant — Default role. Can unmute self (unless hard-muted).
//
// ISOLATION INVARIANT [G8]:
//   This file is pure data — no UI, no network, no side effects.
//   If removed, the app functions without role enforcement.
// ============================================================================

import Foundation
import os.log

// MARK: - Participant Role

/// The role of a participant in a meeting room.
/// Roles are hierarchical: host > co-host > panelist > presenter > participant.
@objc public enum InterParticipantRole: Int, Codable, CaseIterable, Comparable {
    case participant = 0
    case presenter = 1
    case panelist = 2
    case coHost = 3
    case host = 4

    /// String representation matching the JWT metadata field.
    public var stringValue: String {
        switch self {
        case .host: return "host"
        case .coHost: return "co-host"
        case .panelist: return "panelist"
        case .presenter: return "presenter"
        case .participant: return "participant"
        }
    }

    /// Human-readable display name for the UI.
    public var displayName: String {
        switch self {
        case .host: return "Host"
        case .coHost: return "Co-host"
        case .panelist: return "Panelist"
        case .presenter: return "Presenter"
        case .participant: return "Participant"
        }
    }

    /// Parse from the JWT metadata role string.
    /// Falls back to .participant for unknown strings.
    public static func from(string: String?) -> InterParticipantRole {
        guard let str = string?.lowercased() else { return .participant }
        switch str {
        case "host": return .host
        case "co-host", "cohost": return .coHost
        case "panelist": return .panelist
        case "presenter": return .presenter
        case "participant": return .participant
        // Legacy interview roles map to equivalent meeting roles
        case "interviewer": return .host
        case "interviewee": return .participant
        default: return .participant
        }
    }

    // Comparable conformance for role hierarchy
    public static func < (lhs: InterParticipantRole, rhs: InterParticipantRole) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Permission

/// Individual permissions that can be granted to a role.
/// Each permission maps to a specific moderation or room management action.
@objc public enum InterPermission: Int, CaseIterable {
    /// Can mute other participants' audio or video (server-authoritative).
    case canMuteOthers = 0
    /// Can remove a participant from the room entirely.
    case canRemoveParticipant = 1
    /// Can start/stop/pause local recording.
    case canStartRecording = 2
    /// Can disable/enable the room chat for all participants.
    case canDisableChat = 3
    /// Can create and manage polls.
    case canLaunchPolls = 4
    /// Can force-spotlight a participant for all viewers.
    case canForceSpotlight = 5
    /// Can lock/unlock the meeting (prevent new joins).
    case canLockMeeting = 6
    /// Can admit/deny participants from the lobby/waiting room.
    case canAdmitFromLobby = 7
    /// Can promote/demote other participants' roles (up to own level - 1).
    case canPromoteParticipants = 8
    /// Can suspend a participant (mute all tracks + disable chat).
    case canSuspendParticipant = 9
    /// Can ask a participant to unmute (soft request via DataChannel).
    case canAskToUnmute = 10
    /// Can set or change the meeting password.
    case canManagePassword = 11
    /// Can unmute own microphone (denied only when hard-muted by host).
    case canUnmuteSelf = 12
    /// Can share screen.
    case canShareScreen = 13
}

// MARK: - Permission Matrix

/// The central permission matrix mapping roles to their allowed actions.
/// This is the single source of truth for access control in the client.
///
/// Server-side endpoints independently validate permissions using the same
/// matrix logic — this client-side check controls UI visibility only.
@objc public class InterPermissionMatrix: NSObject {

    // MARK: - Permission Lookup

    /// Returns the set of permissions granted to the given role.
    @objc public static func permissions(for role: InterParticipantRole) -> [NSNumber] {
        return permissionSet(for: role).map { NSNumber(value: $0.rawValue) }
    }

    /// Check whether a specific role has a specific permission.
    @objc public static func role(_ role: InterParticipantRole, hasPermission permission: InterPermission) -> Bool {
        return permissionSet(for: role).contains(permission)
    }

    /// Check whether a role can promote a target to a given new role.
    /// Rules: Only host/co-host can promote. Cannot promote above own level - 1.
    /// Host is the only role that can create co-hosts.
    @objc public static func canRole(_ promoterRole: InterParticipantRole,
                                     promoteToRole targetRole: InterParticipantRole) -> Bool {
        guard permissionSet(for: promoterRole).contains(.canPromoteParticipants) else {
            return false
        }
        // Host can promote to any role (including co-host)
        if promoterRole == .host {
            return targetRole != .host // Cannot create another host
        }
        // Co-host can promote up to panelist (not to co-host or host)
        if promoterRole == .coHost {
            return targetRole.rawValue <= InterParticipantRole.panelist.rawValue
        }
        return false
    }

    /// Check whether a role can demote a target from their current role.
    /// Rules: Only host/co-host can demote. Cannot demote someone of equal or higher role.
    @objc public static func canRole(_ demoterRole: InterParticipantRole,
                                     demoteFromRole targetCurrentRole: InterParticipantRole) -> Bool {
        guard permissionSet(for: demoterRole).contains(.canPromoteParticipants) else {
            return false
        }
        // Cannot demote someone of equal or higher role
        return demoterRole.rawValue > targetCurrentRole.rawValue
    }

    // MARK: - Internal Permission Sets

    /// Swift-typed permission set for a role.
    static func permissionSet(for role: InterParticipantRole) -> Set<InterPermission> {
        switch role {
        case .host:
            return hostPermissions
        case .coHost:
            return coHostPermissions
        case .panelist:
            return panelistPermissions
        case .presenter:
            return presenterPermissions
        case .participant:
            return participantPermissions
        }
    }

    // -------------------------------------------------------------------------
    // Permission sets — defined as static Sets for O(1) lookup.
    // -------------------------------------------------------------------------

    /// Host: all permissions.
    private static let hostPermissions: Set<InterPermission> = Set(InterPermission.allCases)

    /// Co-host: all permissions (same as host in practice — server enforces
    /// that co-hosts cannot create other co-hosts).
    private static let coHostPermissions: Set<InterPermission> = [
        .canMuteOthers,
        .canRemoveParticipant,
        .canStartRecording,
        .canDisableChat,
        .canLaunchPolls,
        .canForceSpotlight,
        .canLockMeeting,
        .canAdmitFromLobby,
        .canPromoteParticipants,
        .canSuspendParticipant,
        .canAskToUnmute,
        .canManagePassword,
        .canUnmuteSelf,
        .canShareScreen,
    ]

    /// Panelist: can unmute self, share screen, launch polls.
    private static let panelistPermissions: Set<InterPermission> = [
        .canUnmuteSelf,
        .canShareScreen,
        .canLaunchPolls,
    ]

    /// Presenter: can unmute self and share screen.
    private static let presenterPermissions: Set<InterPermission> = [
        .canUnmuteSelf,
        .canShareScreen,
    ]

    /// Participant: can unmute self (unless hard-muted).
    private static let participantPermissions: Set<InterPermission> = [
        .canUnmuteSelf,
    ]
}

// MARK: - Role Info (ObjC-Friendly Wrapper)

/// ObjC-accessible wrapper exposing role information for a participant.
/// Used by AppDelegate and UI code to drive permission-gated visibility.
@objc public class InterRoleInfo: NSObject {

    /// The participant's current role.
    @objc public let role: InterParticipantRole

    /// The participant's identity string.
    @objc public let identity: String

    /// Human-readable role display name.
    @objc public var roleDisplayName: String {
        return role.displayName
    }

    /// Whether this participant has moderation privileges (host or co-host).
    @objc public var isModerator: Bool {
        return role >= .coHost
    }

    /// Whether this participant is the room host.
    @objc public var isHost: Bool {
        return role == .host
    }

    /// Check a specific permission.
    @objc public func hasPermission(_ permission: InterPermission) -> Bool {
        return InterPermissionMatrix.role(role, hasPermission: permission)
    }

    @objc public init(role: InterParticipantRole, identity: String) {
        self.role = role
        self.identity = identity
        super.init()
    }
}

// MARK: - Metadata Parser

/// Utility to extract role from LiveKit participant metadata JSON.
///
/// LiveKit delivers participant metadata as a JSON string in the JWT.
/// Format: `{"role": "host"}` or `{"role": "co-host"}`.
@objc public class InterParticipantMetadata: NSObject {

    /// Parse the role from a LiveKit metadata JSON string.
    /// Returns .participant if metadata is nil, empty, or missing the role field.
    @objc public static func parseRole(from metadata: String?) -> InterParticipantRole {
        guard let metadata = metadata, !metadata.isEmpty,
              let data = metadata.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roleStr = json["role"] as? String else {
            return .participant
        }
        return InterParticipantRole.from(string: roleStr)
    }

    /// Create metadata JSON string with the given role.
    /// Used when promoting a participant (server-side, but useful for local preview).
    @objc public static func metadataJSON(forRole role: InterParticipantRole) -> String {
        return "{\"role\": \"\(role.stringValue)\"}"
    }

    /// Parse all metadata fields from a LiveKit metadata JSON string.
    /// Returns a dictionary with "role" and any future fields.
    @objc public static func parseAll(from metadata: String?) -> [String: String] {
        guard let metadata = metadata, !metadata.isEmpty,
              let data = metadata.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var result: [String: String] = [:]
        for (key, value) in json {
            if let str = value as? String {
                result[key] = str
            }
        }
        return result
    }
}
