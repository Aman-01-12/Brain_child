//
//  InterTeamsChatService.swift
//  inter
//
//  Orchestrates one team's chat: REST is the source of truth (history + writes),
//  the InterRealtimeClient façade delivers live fan-out, and InterTeamMessageStore
//  reconciles the two (dedup by id, optimistic echo, ordering). The REST surface
//  is an injectable protocol so the orchestration is unit-testable without a
//  live server.
//
//  Threading: all store mutation + @Published updates happen on the main queue,
//  so SwiftUI observation and the store's single-thread assumption both hold.
//

import Foundation
import Combine

// MARK: - Server JSON decode

public extension InterTeamMessage {
    /// Decode from the server's `formatMessage` dictionary. Returns nil if a
    /// required field is missing/malformed (treated as a dropped frame — the next
    /// history fetch reconciles). `clientKey` is attached by the caller, not the server.
    init?(serverJSON json: [String: Any], iso: ISO8601DateFormatter, clientKey: String? = nil) {
        guard let id = json["id"] as? String,
              let teamId = json["teamId"] as? String,
              let senderName = json["senderName"] as? String,
              let kind = json["kind"] as? String,
              let createdAtStr = json["createdAt"] as? String,
              let createdAt = iso.date(from: createdAtStr) else { return nil }

        var file: InterTeamFile?
        if let f = json["file"] as? [String: Any],
           let fileId = f["fileId"] as? String,
           let originalName = f["originalName"] as? String,
           let mimeType = f["mimeType"] as? String {
            let size = (f["sizeBytes"] as? NSNumber)?.int64Value
            file = InterTeamFile(fileId: fileId, originalName: originalName,
                                 mimeType: mimeType, sizeBytes: size,
                                 isImage: (f["isImage"] as? Bool) ?? false)
        }

        self.init(id: id, teamId: teamId,
                  senderUserId: json["senderUserId"] as? String,
                  senderName: senderName, kind: kind,
                  body: json["body"] as? String, file: file, createdAt: createdAt,
                  status: .confirmed, clientKey: clientKey)
    }
}

// MARK: - Injectable REST transport

/// The team-chat REST surface the service depends on. Concrete impl talks to the
/// token server; tests inject a fake to exercise orchestration deterministically.
public protocol InterTeamsChatTransport: AnyObject {
    func loadMessages(teamId: String, before: String?,
                      completion: @escaping (Result<[InterTeamMessage], Error>) -> Void)
    func sendMessage(teamId: String, body: String, idempotencyKey: String,
                     completion: @escaping (Result<InterTeamMessage, Error>) -> Void)
    func markRead(teamId: String, messageId: String,
                  completion: @escaping (Result<Void, Error>) -> Void)
}

// MARK: - Service

@MainActor
public final class InterTeamsChatService: ObservableObject {

    @Published public private(set) var messages: [InterTeamMessage] = []
    @Published public private(set) var connectionState: InterRealtimeConnectionState = .disconnected

    private let teamId: String
    private let transport: InterTeamsChatTransport
    private let realtime: InterRealtimeClient
    private let tokenProvider: () -> String?
    private let store = InterTeamMessageStore()
    private var didStart = false
    private let iso: ISO8601DateFormatter

    public init(teamId: String,
                transport: InterTeamsChatTransport,
                realtime: InterRealtimeClient,
                tokenProvider: @escaping () -> String?) {
        self.teamId = teamId
        self.transport = transport
        self.realtime = realtime
        self.tokenProvider = tokenProvider
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.iso = f
    }

    /// Begin: connect the socket, register the live handler, join the room, then
    /// fetch the latest history page. Live frames arriving during the fetch are
    /// merged + de-duplicated by id, so ordering is correct regardless of timing.
    public func start() {
        guard !didStart else { return }   // idempotent: avoid duplicate live handlers on re-entry
        didStart = true
        realtime.on("team:message") { [weak self] data in
            self?.handleLiveMessage(data)
        }
        realtime.connect(tokenProvider: tokenProvider)
        realtime.join(room: teamId)
        loadHistory()
    }

    /// Tear down: leave the room and disconnect. The socket's own disconnect
    /// releases handlers (2C); we also clear the store.
    public func stop() {
        didStart = false
        realtime.leave(room: teamId)
        realtime.disconnect()
        store.removeAll()
        republish()
    }

    public func loadHistory(before: String? = nil) {
        transport.loadMessages(teamId: teamId, before: before) { [weak self] result in
            Task { @MainActor in
                guard let self = self else { return }
                if case .success(let msgs) = result {
                    self.store.ingestHistory(msgs)
                    self.republish()
                    self.markReadToLatest()
                }
            }
        }
    }

    /// Send a text message: show an optimistic echo immediately, POST it, then
    /// reconcile with the persisted row (or mark failed for retry).
    public func sendText(_ raw: String, senderUserId: String?, senderName: String) {
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let key = UUID().uuidString
        let echo = InterTeamMessage(id: "pending:\(key)", teamId: teamId,
                                    senderUserId: senderUserId, senderName: senderName,
                                    kind: "text", body: body, file: nil, createdAt: Date(),
                                    status: .pending, clientKey: key)
        store.addPending(echo)
        republish()

        transport.sendMessage(teamId: teamId, body: body, idempotencyKey: key) { [weak self] result in
            Task { @MainActor in
                guard let self = self else { return }
                switch result {
                case .success(let server):
                    self.store.confirmPending(clientKey: key, with: server)
                    self.markReadToLatest()
                case .failure:
                    self.store.failPending(clientKey: key)
                }
                self.republish()
            }
        }
    }

    /// Retry a previously failed send: drop the failed echo and re-send the body.
    public func retryFailed(_ message: InterTeamMessage) {
        guard message.status == .failed, let key = message.clientKey, let body = message.body else { return }
        store.removePending(clientKey: key)
        republish()
        sendText(body, senderUserId: message.senderUserId, senderName: message.senderName)
    }

    // MARK: - Internals

    private func handleLiveMessage(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = InterTeamMessage(serverJSON: obj, iso: iso) else { return }
        Task { @MainActor in
            self.store.ingest(message)
            self.republish()
            self.markReadToLatest()
        }
    }

    private func republish() {
        messages = store.messages
    }

    /// Advance the server read cursor to the highest confirmed id (best-effort;
    /// idempotent server-side via GREATEST set-to-max).
    private func markReadToLatest() {
        let high = store.highestConfirmedId
        guard high > 0 else { return }
        transport.markRead(teamId: teamId, messageId: String(high)) { _ in }
    }
}
