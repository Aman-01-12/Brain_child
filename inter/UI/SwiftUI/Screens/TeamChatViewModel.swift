//
//  TeamChatViewModel.swift
//  inter
//
//  Presentation layer for one team's chat room. Wraps the tested
//  InterTeamsChatService (which owns REST + realtime + reconciliation) and adds
//  view concerns: the composer draft, send/retry intent, and pure formatting
//  helpers (initials, relative time, self-authorship). Pure helpers are
//  unit-tested; data flow is already covered by InterTeamsChatServiceTests.
//

import Foundation
import Combine

@MainActor
public final class TeamChatViewModel: ObservableObject {

    @Published public var draft: String = ""
    @Published public private(set) var messages: [InterTeamMessage] = []
    @Published public private(set) var connectionState: InterRealtimeConnectionState = .disconnected

    public let teamName: String
    private let service: InterTeamsChatService
    private let currentUserId: String?
    private let currentDisplayName: String
    private var cancellables = Set<AnyCancellable>()

    public init(teamName: String,
                currentUserId: String?,
                currentDisplayName: String,
                service: InterTeamsChatService) {
        self.teamName = teamName
        self.service = service
        self.currentUserId = currentUserId
        self.currentDisplayName = currentDisplayName

        // Re-publish the service's reconciled state so the SwiftUI view observes
        // this single view model.
        service.$messages.receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.messages = $0 }
            .store(in: &cancellables)
        service.$connectionState.receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.connectionState = $0 }
            .store(in: &cancellables)
    }

    public func start() { service.start() }
    public func stop() { service.stop() }
    public func loadOlder() {
        guard let oldest = messages.first(where: { $0.status == .confirmed }) else { return }
        service.loadHistory(before: oldest.id)
    }

    /// Whether the send control is enabled (non-empty after trimming).
    public var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func send() {
        guard canSend else { return }
        service.sendText(draft, senderUserId: currentUserId, senderName: currentDisplayName)
        draft = ""
    }

    public func retry(_ message: InterTeamMessage) {
        service.retryFailed(message)
    }

    // MARK: - Pure presentation helpers (unit-tested)

    /// True if this message was authored by the local user (drives bubble side/color).
    public func isMine(_ message: InterTeamMessage) -> Bool {
        guard let me = currentUserId, let sender = message.senderUserId else { return false }
        return me == sender
    }

    /// Up-to-two-letter uppercase initials from a display name (avatar fallback).
    public nonisolated static func initials(from name: String) -> String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "\t" }).prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }
        let joined = letters.joined().uppercased()
        return joined.isEmpty ? "?" : joined
    }

    public func initials(_ message: InterTeamMessage) -> String {
        Self.initials(from: message.senderName)
    }

    /// Short relative time for a message timestamp ("now", "5m", "3h", "2d",
    /// then a date). Stable, locale-light formatting for compact chat metadata.
    public nonisolated static func relativeTime(from date: Date, reference: Date = Date()) -> String {
        let seconds = reference.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 7 { return "\(days)d" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    public func timeLabel(_ message: InterTeamMessage) -> String {
        Self.relativeTime(from: message.createdAt)
    }
}
