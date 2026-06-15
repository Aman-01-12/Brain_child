//
//  RequestsPanelViewModel.swift
//  inter
//
//  Host/co-host "Requests" panel — consolidates the four legacy queue panels
//  (raised hands / screen share / mic unlock / camera unlock) into one surface
//  segregated by request type. Participants never see this panel; they get
//  button-state feedback instead (Zoom pattern).
//
//  Rows are pushed by AppDelegate (which already owns all four queues) through
//  the bridge; approve/deny flow back as callbacks carrying the same payloads
//  the legacy per-queue delegate methods used.
//

import Foundation
import Combine

public enum CallRequestKind: String, CaseIterable, Identifiable {
    case raisedHand = "Raised Hands"
    case screenShare = "Screen Share"
    case micUnlock = "Mic Unlock"
    case cameraUnlock = "Camera Unlock"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .raisedHand: return "hand.raised"
        case .screenShare: return "rectangle.on.rectangle"
        case .micUnlock: return "mic"
        case .cameraUnlock: return "video"
        }
    }

    /// Whether rows of this kind can be denied (raised hands are acknowledged/
    /// lowered, not denied; the legacy speaker queue only had "dismiss").
    public var supportsDeny: Bool { self != .raisedHand }
}

public struct CallRequest: Equatable, Identifiable {
    public let id: String          // "<kind>:<identity>"
    public let kind: CallRequestKind
    public let identity: String
    public let displayName: String
    public let timestamp: Date

    public init(kind: CallRequestKind, identity: String, displayName: String, timestamp: Date) {
        self.id = "\(kind.rawValue):\(identity)"
        self.kind = kind
        self.identity = identity
        self.displayName = displayName
        self.timestamp = timestamp
    }
}

@MainActor
public final class RequestsPanelViewModel: ObservableObject {

    @Published public private(set) var requests: [CallRequest] = []

    /// Approve (admit/allow/lower-hand). Carries kind + identity.
    public var onApprove: ((CallRequestKind, String) -> Void)?
    /// Deny (reject). Only for kinds where supportsDeny.
    public var onDeny: ((CallRequestKind, String) -> Void)?

    public init() {}

    /// Replace all rows of one kind (each legacy queue pushes independently).
    public func setRequests(_ rows: [CallRequest], for kind: CallRequestKind) {
        var others = requests.filter { $0.kind != kind }
        others.append(contentsOf: rows)
        requests = RequestsPanelViewModel.sorted(others)
    }

    public func removeAll() {
        requests = []
    }

    public var totalCount: Int { requests.count }

    /// Rows for one section, oldest first.
    public func rows(for kind: CallRequestKind) -> [CallRequest] {
        requests.filter { $0.kind == kind }
    }

    /// Section kinds that currently have rows, in canonical order.
    public var activeKinds: [CallRequestKind] {
        CallRequestKind.allCases.filter { kind in requests.contains { $0.kind == kind } }
    }

    public func approve(_ request: CallRequest) {
        onApprove?(request.kind, request.identity)
        requests.removeAll { $0.id == request.id }
    }

    public func deny(_ request: CallRequest) {
        guard request.kind.supportsDeny else { return }
        onDeny?(request.kind, request.identity)
        requests.removeAll { $0.id == request.id }
    }

    // MARK: - Pure helpers (unit-tested)

    /// Canonical sort: kind order, then oldest-first within a kind.
    public nonisolated static func sorted(_ rows: [CallRequest]) -> [CallRequest] {
        let kindOrder = Dictionary(uniqueKeysWithValues:
            CallRequestKind.allCases.enumerated().map { ($1, $0) })
        return rows.sorted {
            let a = kindOrder[$0.kind] ?? 0
            let b = kindOrder[$1.kind] ?? 0
            if a != b { return a < b }
            return $0.timestamp < $1.timestamp
        }
    }

    /// Approve button label per kind.
    public nonisolated static func approveLabel(for kind: CallRequestKind) -> String {
        switch kind {
        case .raisedHand: return "Lower Hand"
        case .screenShare: return "Allow"
        case .micUnlock: return "Allow"
        case .cameraUnlock: return "Allow"
        }
    }
}
