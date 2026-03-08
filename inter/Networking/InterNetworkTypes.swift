// ============================================================================
// InterNetworkTypes.swift
// inter
//
// Phase 1.1 — Foundation types for the networking layer.
//
// ISOLATION INVARIANT [G8]:
// Every type in the Networking/ directory is side-effect-free and
// failure-tolerant. If the entire networking layer is removed or
// _roomController is nil, the app MUST function identically to its
// current local-only state. No type here may call into local media
// controllers, recording, or UI directly. All communication flows
// outward via KVO, delegation, or completion blocks.
// ============================================================================

import Foundation

// MARK: - Room Connection State

/// Observable connection state for the LiveKit room.
/// KVO-compatible for UI binding from Objective-C.
@objc public enum InterRoomConnectionState: Int {
    /// Not connected to any room.
    case disconnected = 0
    /// Connection attempt in progress.
    case connecting = 1
    /// Successfully connected and signaling active.
    case connected = 2
    /// Temporarily lost connection; SDK is attempting automatic reconnect.
    case reconnecting = 3
    /// Disconnected due to an error (check associated NSError).
    case disconnectedWithError = 4
}

// MARK: - Track Kind

/// Identifies the type of media track being published or subscribed.
@objc public enum InterTrackKind: Int {
    case camera = 0
    case microphone = 1
    case screenShare = 2
}

// MARK: - Participant Presence [G6]

/// Observable participant presence state.
/// Uses a 3-second grace period before surfacing `.participantLeft`
/// to avoid UI flicker during transient reconnections.
@objc public enum InterParticipantPresenceState: Int {
    /// Connected to room but no remote participants present.
    case alone = 0
    /// At least one remote participant is in the room.
    case participantJoined = 1
    /// All remote participants have left (after 3s grace period).
    case participantLeft = 2
}

// MARK: - Camera Network State (Swift-only) [G2]

/// Internal state machine for two-phase camera mute/unmute.
///
/// Valid transitions:
///   active → muting → muted → enabling → active
///
/// - `active`:    Camera is publishing and LiveKit track is unmuted.
/// - `muting`:    LiveKit track muted; waiting for capture device to stop.
/// - `muted`:     Both LiveKit track and capture device are stopped.
/// - `enabling`:  Capture device started; waiting for first real frame before unmuting track.
enum InterCameraNetworkState {
    case active
    case muting
    case muted
    case enabling

    /// Returns the valid next state, or nil if the transition is invalid.
    func nextState(for action: InterCameraNetworkAction) -> InterCameraNetworkState? {
        switch (self, action) {
        case (.active, .beginMute):     return .muting
        case (.muting, .deviceStopped): return .muted
        case (.muted, .beginEnable):    return .enabling
        case (.enabling, .firstFrame):  return .active
        default:                        return nil
        }
    }
}

/// Actions that drive camera network state transitions.
enum InterCameraNetworkAction {
    /// User requested mute — mute LiveKit track first.
    case beginMute
    /// Capture device has stopped after mute.
    case deviceStopped
    /// User requested unmute — start capture device first.
    case beginEnable
    /// First real frame received after re-enabling capture.
    case firstFrame
}

// MARK: - Microphone Network State (Swift-only) [G2]

/// Internal state machine for two-phase microphone mute/unmute.
/// Same transition pattern as camera.
enum InterMicrophoneNetworkState {
    case active
    case muting
    case muted
    case enabling

    func nextState(for action: InterMicrophoneNetworkAction) -> InterMicrophoneNetworkState? {
        switch (self, action) {
        case (.active, .beginMute):      return .muting
        case (.muting, .deviceStopped):  return .muted
        case (.muted, .beginEnable):     return .enabling
        case (.enabling, .firstSample):  return .active
        default:                         return nil
        }
    }
}

enum InterMicrophoneNetworkAction {
    case beginMute
    case deviceStopped
    case beginEnable
    /// First audio sample buffer received after re-enabling capture.
    case firstSample
}

// MARK: - Room Configuration [G7]

/// Configuration required to connect to a LiveKit room.
/// Passed from ObjC (AppDelegate / SecureWindowController) into the Swift networking layer.
@objc public class InterRoomConfiguration: NSObject, NSCopying {

    /// WebSocket URL of the LiveKit server (e.g. "ws://localhost:7880" or "wss://live.example.com").
    @objc public var serverURL: String

    /// Base URL of the token server (e.g. "http://localhost:3000").
    @objc public var tokenServerURL: String

    /// 6-character room code. Set by host after creation, or by joiner before joining.
    @objc public var roomCode: String

    /// Unique identity for this participant (persists across reconnects).
    @objc public var participantIdentity: String

    /// Display name shown to other participants.
    @objc public var participantName: String

    /// Whether this participant is the room host (creator).
    @objc public var isHost: Bool

    @objc public init(serverURL: String,
                      tokenServerURL: String,
                      roomCode: String = "",
                      participantIdentity: String,
                      participantName: String,
                      isHost: Bool = false) {
        self.serverURL = serverURL
        self.tokenServerURL = tokenServerURL
        self.roomCode = roomCode
        self.participantIdentity = participantIdentity
        self.participantName = participantName
        self.isHost = isHost
        super.init()
    }

    public func copy(with zone: NSZone? = nil) -> Any {
        let copy = InterRoomConfiguration(
            serverURL: serverURL,
            tokenServerURL: tokenServerURL,
            roomCode: roomCode,
            participantIdentity: participantIdentity,
            participantName: participantName,
            isHost: isHost
        )
        return copy
    }

    public override var description: String {
        // Never log tokens or secrets. Room code is semi-sensitive but useful for debugging.
        return "<InterRoomConfiguration server=\(serverURL) identity=\(participantIdentity) isHost=\(isHost) roomCode=\(roomCode.isEmpty ? "(none)" : "***")>"
    }
}

// MARK: - Error Domain [G7]

/// Error domain for all networking-layer errors.
/// Accessible from ObjC as `InterNetworkErrorDomain` (global NSString constant).
public let InterNetworkErrorDomain = "com.secure.inter.network"

/// Error codes within `InterNetworkErrorDomain`.
@objc public enum InterNetworkErrorCode: Int {
    /// Token server did not return a valid token.
    case tokenFetchFailed = 1000
    /// Could not connect to the LiveKit server.
    case connectionFailed = 1001
    /// Failed to publish a local track.
    case publishFailed = 1002
    /// Failed to subscribe to a remote track.
    case subscribeFailed = 1003
    /// Token has expired (auto-refresh should handle this).
    case tokenExpired = 1004
    /// Token server or LiveKit server is unreachable.
    case serverUnreachable = 1005
    /// Room code is invalid (404 from token server).
    case roomCodeInvalid = 1006
    /// Room code has expired (410 from token server).
    case roomCodeExpired = 1007
}

// MARK: - Error Helpers

extension InterNetworkErrorCode {
    /// Create an NSError with this code and a human-readable message.
    func error(message: String, underlyingError: Error? = nil) -> NSError {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: message]
        if let underlying = underlyingError {
            userInfo[NSUnderlyingErrorKey] = underlying
        }
        return NSError(domain: InterNetworkErrorDomain, code: self.rawValue, userInfo: userInfo)
    }
}
