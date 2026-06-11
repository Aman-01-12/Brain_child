//
//  LobbyHostViewModel.swift
//  inter
//
//  State + logic for the host-side waiting room (`lobby`). Mirrors the public surface of
//  the legacy `InterLobbyPanel` so `AppDelegate`'s delegate wiring is unchanged:
//  add/remove/clear waiting participants, the lobby on/off toggle (host-only), and the
//  admit / deny / admit-all / toggle callbacks.
//
//  NOTE (gap decisions, user 2026-06-11): the mock shows a per-row ROLE and a
//  "Message waiting room" button. The app's lobby queue has neither (payload is
//  {identity, displayName}). Both are intentionally SKIPPED for now — rows show
//  avatar + name + wait time only; no message button.
//

import Foundation
import Combine

public struct LobbyWaitingEntry: Identifiable, Equatable {
    public let id: String          // participant identity
    public let displayName: String
    public let joinDate: Date

    public init(id: String, displayName: String, joinDate: Date) {
        self.id = id
        self.displayName = displayName
        self.joinDate = joinDate
    }

    /// Single-letter… actually two-letter initials for the avatar (e.g. "Alice Chen" → "AC").
    public var initials: String {
        let parts = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}

public final class LobbyHostViewModel: ObservableObject {

    @Published public private(set) var waiting: [LobbyWaitingEntry] = []
    @Published public var lobbyEnabled = false
    /// Co-hosts may admit/deny but not toggle the waiting room — drives the switch's enabled state.
    @Published public var lobbyToggleEnabled = true
    /// Bumped on a timer so relative wait-times ("Just now" → "1 min ago") refresh while open.
    @Published public var timeTick = 0

    // Callbacks bridged to the existing Obj-C delegate by `InterLobbyHostHostView`.
    public var onAdmit: ((_ identity: String, _ displayName: String) -> Void)?
    public var onDeny: ((_ identity: String) -> Void)?
    public var onAdmitAll: (() -> Void)?
    public var onToggleLobby: ((_ enabled: Bool) -> Void)?

    private var timer: Timer?

    public init() {
        // Refresh relative timestamps periodically (matches the "live" intent of the queue).
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.timeTick &+= 1
        }
    }

    deinit { timer?.invalidate() }

    public var count: Int { waiting.count }
    public var isEmpty: Bool { waiting.isEmpty }

    // MARK: Mutations (called by the bridge ← legacy panel API)

    public func add(identity: String, displayName: String) {
        guard !waiting.contains(where: { $0.id == identity }) else { return } // dedup
        waiting.append(LobbyWaitingEntry(id: identity, displayName: displayName, joinDate: Date()))
    }

    public func remove(identity: String) {
        waiting.removeAll { $0.id == identity }
    }

    public func clear() {
        waiting.removeAll()
    }

    // MARK: Intents (UI → callbacks)

    public func admit(_ entry: LobbyWaitingEntry) { onAdmit?(entry.id, entry.displayName) }
    public func deny(_ entry: LobbyWaitingEntry) { onDeny?(entry.id) }
    public func admitAll() { onAdmitAll?() }

    public func setLobbyEnabled(_ enabled: Bool) {
        guard enabled != lobbyEnabled else { return }
        lobbyEnabled = enabled
        onToggleLobby?(enabled)
    }

    /// Relative wait label matching the mock ("Just now" / "N min ago" / "N hr ago").
    public func waitLabel(for entry: LobbyWaitingEntry) -> String {
        _ = timeTick // depend on the tick so SwiftUI re-renders on refresh
        let elapsed = max(0, -entry.joinDate.timeIntervalSinceNow)
        if elapsed < 60 { return "Just now" }
        let minutes = Int(elapsed / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        return "\(hours) hr ago"
    }
}
