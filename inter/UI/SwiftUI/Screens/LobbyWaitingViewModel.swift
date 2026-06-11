//
//  LobbyWaitingViewModel.swift
//  inter
//
//  State for the participant-side waiting room (`lobby`, participant view). Mirrors the
//  legacy `InterLobbyWaitingView` API (showJoining/showWaiting/setPosition/setStatusMessage/
//  showDenied/showAdmitted + cancel) so `AppDelegate`'s polling/admission flow is unchanged.
//

import Foundation

public enum LobbyWaitingState {
    case joining
    case waiting
    case denied
    case admitted
}

public final class LobbyWaitingViewModel: ObservableObject {

    @Published public var state: LobbyWaitingState = .waiting
    /// Position in queue; 0 hides the line.
    @Published public var position: Int = 0
    /// Optional override of the default status message for the current state.
    @Published public var customMessage: String?

    /// Cancel / Leave / OK tapped — bridged to `lobbyWaitingViewDidCancel:`.
    public var onCancel: (() -> Void)?

    public init() {}

    public func cancel() { onCancel?() }

    // Per-state presentation (visual source: LobbyMock.tsx participant view).

    public var iconSystemName: String {
        switch state {
        case .joining: return "video.fill"
        default:       return "person.2.fill"
        }
    }

    public var title: String {
        switch state {
        case .joining:  return "Joining Meeting"
        case .waiting:  return "Waiting Room"
        case .denied:   return "Access Denied"
        case .admitted: return "You're In!"
        }
    }

    public var message: String {
        if let customMessage, !customMessage.isEmpty { return customMessage }
        switch state {
        case .joining:  return "Connecting to the meeting…"
        case .waiting:  return "Please wait, the host will let you in shortly."
        case .denied:   return "The host has denied your request to join."
        case .admitted: return "Admitted. Connecting…"
        }
    }

    /// Accent for icon + title, by state (violet / red / emerald).
    public enum Accent { case brand, danger, success }
    public var accent: Accent {
        switch state {
        case .joining, .waiting: return .brand
        case .denied:            return .danger
        case .admitted:          return .success
        }
    }

    public var showsSpinner: Bool {
        switch state {
        case .joining, .waiting: return true
        case .denied, .admitted: return false
        }
    }

    public var showsPosition: Bool { state == .waiting && position > 0 }

    /// Button title, or nil to hide (admitted has no button).
    public var buttonTitle: String? {
        switch state {
        case .joining:  return "Cancel"
        case .waiting:  return "Leave"
        case .denied:   return "OK"
        case .admitted: return nil
        }
    }

    /// The OK button (denied) is a primary action; Cancel/Leave are secondary.
    public var buttonIsPrimary: Bool { state == .denied }
}
