//
//  InterTeamModels.swift
//  inter
//
//  Value models + the message store for team chat. The store is the testable
//  core: it merges fetched history with live socket fan-out, dedups by the
//  server's monotonic id, sorts by (createdAt, id), and reconciles optimistic
//  local echoes. Persistence is the source of truth; a dropped/duplicate/late
//  socket frame can never lose or reorder a message (design spec §11, paranoid
//  H10).
//

import Foundation

/// A team chat file attachment (metadata only; bytes are fetched via a
/// presigned URL on demand). Mirrors the server `formatMessage().file` shape.
public struct InterTeamFile: Codable, Equatable {
    public let fileId: String
    public let originalName: String
    public let mimeType: String
    public let sizeBytes: Int64?
    public let isImage: Bool

    enum CodingKeys: String, CodingKey {
        case fileId, originalName, mimeType, sizeBytes, isImage
    }
}

/// Local delivery state of a message — drives the composer's pending/failed UI.
public enum InterTeamMessageStatus: Equatable {
    case confirmed   // persisted server-side (has a real id)
    case pending     // optimistic local echo, POST in flight
    case failed      // POST failed; offer retry
}

/// A single team chat message. `id` is the server's monotonic BIGSERIAL as a
/// string ("1", "2", …) once confirmed; a pending echo uses a synthetic
/// "pending:<clientKey>" id until the REST response returns the real row.
public struct InterTeamMessage: Equatable {
    public let id: String
    public let teamId: String
    public let senderUserId: String?
    public let senderName: String
    public let kind: String              // "text" | "file"
    public let body: String?
    public let file: InterTeamFile?
    public let createdAt: Date
    public var status: InterTeamMessageStatus
    /// Client idempotency key — present for messages this client sent, used to
    /// reconcile the optimistic echo with the persisted row.
    public let clientKey: String?

    public init(id: String, teamId: String, senderUserId: String?, senderName: String,
                kind: String, body: String?, file: InterTeamFile?, createdAt: Date,
                status: InterTeamMessageStatus = .confirmed, clientKey: String? = nil) {
        self.id = id
        self.teamId = teamId
        self.senderUserId = senderUserId
        self.senderName = senderName
        self.kind = kind
        self.body = body
        self.file = file
        self.createdAt = createdAt
        self.status = status
        self.clientKey = clientKey
    }

    /// Numeric ordering key from the server id; pending echoes sort after all
    /// confirmed messages (Int64.max) so they appear at the bottom until confirmed.
    var orderingId: Int64 {
        if status == .pending { return Int64.max }
        return Int64(id) ?? 0
    }
}

/// Thread-confined message store (the owning service serializes access). Holds
/// confirmed messages keyed by server id and pending echoes keyed by clientKey,
/// and produces a single sorted, de-duplicated view.
public final class InterTeamMessageStore {
    private var confirmedById: [String: InterTeamMessage] = [:]
    private var pendingByKey: [String: InterTeamMessage] = [:]

    public init() {}

    /// Upsert one server message (from history or live fan-out), de-duplicating
    /// by id. If it carries a clientKey that matches a local pending echo, that
    /// echo is dropped (handles fan-out arriving before our own REST response).
    public func ingest(_ message: InterTeamMessage) {
        confirmedById[message.id] = message
        if let key = message.clientKey { pendingByKey.removeValue(forKey: key) }
    }

    /// Bulk upsert a page of history.
    public func ingestHistory(_ messages: [InterTeamMessage]) {
        for m in messages { ingest(m) }
    }

    /// Record an optimistic local echo before the POST completes.
    public func addPending(_ message: InterTeamMessage) {
        guard let key = message.clientKey else { return }
        var m = message
        m.status = .pending
        pendingByKey[key] = m
    }

    /// Reconcile a pending echo with the persisted row returned by the REST POST.
    /// Removes the pending entry and upserts the confirmed message (dedup by id),
    /// so a later fan-out frame with the same id is a no-op.
    public func confirmPending(clientKey: String, with serverMessage: InterTeamMessage) {
        pendingByKey.removeValue(forKey: clientKey)
        confirmedById[serverMessage.id] = serverMessage
    }

    /// Mark a pending echo as failed (POST error) so the UI can offer retry.
    public func failPending(clientKey: String) {
        guard var m = pendingByKey[clientKey] else { return }
        m.status = .failed
        pendingByKey[clientKey] = m
    }

    /// Drop a failed/pending echo (e.g. user discards a failed send).
    public func removePending(clientKey: String) {
        pendingByKey.removeValue(forKey: clientKey)
    }

    /// The merged, de-duplicated, ordered message list: confirmed sorted by
    /// (createdAt, numeric id), then pending/failed echoes after, oldest-first.
    public var messages: [InterTeamMessage] {
        let confirmed = confirmedById.values.sorted { a, b in
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.orderingId < b.orderingId
        }
        let pending = pendingByKey.values.sorted { $0.createdAt < $1.createdAt }
        return confirmed + pending
    }

    /// Highest confirmed server id seen (for read-cursor / unread math). 0 if none.
    public var highestConfirmedId: Int64 {
        confirmedById.values.reduce(0) { max($0, Int64($1.id) ?? 0) }
    }

    public var confirmedCount: Int { confirmedById.count }

    /// Reset everything (e.g. switching teams or teardown).
    public func removeAll() {
        confirmedById.removeAll()
        pendingByKey.removeAll()
    }
}

/// Summary of a team in the sidebar list, including the in-app unread badge.
public struct InterTeamSummary: Codable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let description: String?
    public let ownerUserId: String?
    public let memberCount: Int
    public let unreadCount: Int
}

/// A team member row (owner/admin/member).
public struct InterTeamMember: Codable, Equatable, Identifiable {
    public let id: String
    public let teamId: String?
    public let userId: String?
    public let email: String
    public let displayName: String
    public let role: String      // owner | admin | member
    public let status: String    // active | pending | removed
}
