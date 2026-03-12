// ============================================================================
// InterRoomController.swift
// inter
//
// Phase 1.9 — Central orchestrator for the LiveKit room lifecycle.
//
// Owns:
//   • LiveKit.Room instance
//   • InterLiveKitPublisher (publish local tracks)
//   • InterLiveKitSubscriber (subscribe to remote tracks)
//   • InterTokenService (JWT management)
//   • InterCallStatsCollector (diagnostics)
//
// LIFECYCLE:
//   1. AppDelegate creates InterRoomController once at launch. Outlives modes.
//   2. User action → connect(configuration:completion:)
//   3. Host: createRoom → receives room code → room.connect()
//   4. Joiner: joinRoom(roomCode) → room.connect()
//   5. Mode transitions [G4]: transitionMode() detaches sources, keeps room alive
//   6. disconnect() → unpublish, stop stats, room.disconnect()
//
// THREADING:
// All public methods are called on the main queue. Internal state transitions
// use a private serial queue. KVO properties are set on the main queue.
//
// ISOLATION INVARIANT [G8]:
// If this controller is nil or fails, the app works identically to local-only.
// AppDelegate checks `_roomController != nil` before any network operation.
// ============================================================================

import Foundation
import os.log
import LiveKit

// MARK: - InterRoomController

@objc public class InterRoomController: NSObject {

    // MARK: - KVO-Observable Properties

    /// Current connection state. KVO-observable from Objective-C.
    @objc public private(set) dynamic var connectionState: InterRoomConnectionState = .disconnected

    /// Participant presence state with 3-second grace period. [G6]
    @objc public private(set) dynamic var participantPresenceState: InterParticipantPresenceState = .alone

    /// Number of remote participants currently in the room.
    @objc public private(set) dynamic var remoteParticipantCount: Int = 0

    /// Room code (6-char alphanumeric). Set after create or join. [G7]
    @objc public private(set) dynamic var roomCode: String = ""

    // MARK: - Owned Components

    /// Publisher: manages local track publishing.
    @objc public let publisher = InterLiveKitPublisher()

    /// Subscriber: manages remote track subscription.
    @objc public let subscriber = InterLiveKitSubscriber()

    /// Token service: JWT fetch/cache/refresh.
    @objc public let tokenService = InterTokenService()

    /// Stats collector: periodic stats gathering. Created on connect, destroyed on disconnect.
    @objc public private(set) var statsCollector: InterCallStatsCollector?

    // MARK: - Private Properties

    /// The LiveKit Room instance. Created fresh for each connection.
    private var room: Room?

    /// The room configuration for the current session.
    private var configuration: InterRoomConfiguration?

    /// Private serial queue for state transitions.
    private let stateQueue = DispatchQueue(label: "inter.room.state", qos: .userInitiated)

    /// Grace timer for participant-left delay. [G6]
    private var participantGraceTimer: DispatchSourceTimer?

    /// Flag to prevent double-connect.
    private(set) var isConnecting = false

    /// Connect timestamp for duration tracking.
    private var connectStartTime: CFAbsoluteTime = 0

    /// Session start timestamp (for disconnect duration logging).
    private var sessionStartTime: CFAbsoluteTime = 0

    // MARK: - Connect

    /// Connect to a LiveKit room.
    ///
    /// - If `configuration.isHost` is true, creates a new room and receives a room code.
    /// - If `configuration.isHost` is false, joins an existing room using `configuration.roomCode`.
    ///
    /// - Parameters:
    ///   - configuration: Room connection settings.
    ///   - completion: Called on main queue with optional error.
    @objc public func connect(
        configuration: InterRoomConfiguration,
        completion: @escaping (NSError?) -> Void
    ) {
        guard connectionState == .disconnected || connectionState == .disconnectedWithError else {
            interLogError(InterLog.networking, "RoomController: connect called in state %d, ignoring",
                          connectionState.rawValue)
            completion(InterNetworkErrorCode.connectionFailed.error(message: "Already connected or connecting"))
            return
        }

        guard !isConnecting else {
            interLogError(InterLog.networking, "RoomController: double-connect prevented")
            completion(InterNetworkErrorCode.connectionFailed.error(message: "Connection already in progress"))
            return
        }

        isConnecting = true
        self.configuration = configuration.copy() as? InterRoomConfiguration
        connectStartTime = CFAbsoluteTimeGetCurrent()

        setConnectionState(.connecting)

        interLogInfo(InterLog.networking, "RoomController: connecting (isHost=%d, identity=%{public}@)",
                     configuration.isHost ? 1 : 0, configuration.participantIdentity)

        // Step 1: Obtain a token from the token server
        if configuration.isHost {
            tokenService.createRoom(
                serverURL: configuration.tokenServerURL,
                identity: configuration.participantIdentity,
                displayName: configuration.participantName
            ) { [weak self] response, error in
                self?.handleTokenResponse(
                    token: response?.token,
                    serverURL: response?.serverURL ?? configuration.serverURL,
                    roomCode: response?.roomCode,
                    error: error,
                    completion: completion
                )
            }
        } else {
            tokenService.joinRoom(
                serverURL: configuration.tokenServerURL,
                roomCode: configuration.roomCode,
                identity: configuration.participantIdentity,
                displayName: configuration.participantName
            ) { [weak self] response, error in
                self?.handleTokenResponse(
                    token: response?.token,
                    serverURL: response?.serverURL ?? configuration.serverURL,
                    roomCode: configuration.roomCode,
                    error: error,
                    completion: completion
                )
            }
        }
    }

    /// Handle the token server response and connect to the LiveKit room.
    private func handleTokenResponse(
        token: String?,
        serverURL: String,
        roomCode: String?,
        error: NSError?,
        completion: @escaping (NSError?) -> Void
    ) {
        if let error = error {
            interLogError(InterLog.networking, "RoomController: token fetch failed: %{public}@",
                          error.localizedDescription)
            isConnecting = false
            setConnectionState(.disconnectedWithError)
            completion(error)
            return
        }

        guard let token = token else {
            interLogError(InterLog.networking, "RoomController: token is nil but no error")
            isConnecting = false
            setConnectionState(.disconnectedWithError)
            completion(InterNetworkErrorCode.tokenFetchFailed.error(message: "Token was nil"))
            return
        }

        // Store room code
        if let code = roomCode, !code.isEmpty {
            DispatchQueue.main.async {
                self.roomCode = code
            }
        }

        // Step 2: Create and connect the LiveKit Room
        let connectOptions = ConnectOptions(
            autoSubscribe: true,
            reconnectAttempts: 3,
            reconnectAttemptDelay: 2.0
        )

        let roomOptions = RoomOptions()

        let newRoom = Room(delegate: self, connectOptions: connectOptions, roomOptions: roomOptions)

        // Clean up previous room if any (e.g. retry after error)
        if let oldRoom = self.room {
            self.subscriber.detach()
            oldRoom.remove(delegate: self)
        }

        self.room = newRoom
        self.publisher.localParticipant = newRoom.localParticipant
        self.subscriber.attach(to: newRoom)

        // Async connect
        Task {
            do {
                try await newRoom.connect(url: serverURL, token: token)

                let latencyMs = Int((CFAbsoluteTimeGetCurrent() - self.connectStartTime) * 1000)
                interLogInfo(InterLog.networking, "RoomController: connected (latency=%dms)", latencyMs)

                self.sessionStartTime = CFAbsoluteTimeGetCurrent()
                self.isConnecting = false
                self.setConnectionState(.connected)

                // Update publisher reference (in case localParticipant changed after connect)
                self.publisher.localParticipant = newRoom.localParticipant

                // Create stats collector
                let collector = InterCallStatsCollector()
                collector.start(room: newRoom)
                self.statsCollector = collector

                // Update participant count
                self.updateParticipantPresence()

                DispatchQueue.main.async {
                    completion(nil)
                }
            } catch {
                let latencyMs = Int((CFAbsoluteTimeGetCurrent() - self.connectStartTime) * 1000)

                // Extract LiveKit error details when available for diagnostics
                let detail: String
                if let lkError = error as? NSError,
                   lkError.domain == "io.livekit.swift-sdk" {
                    let underlying = lkError.userInfo[NSUnderlyingErrorKey] as? NSError
                    detail = "code=\(lkError.code) desc=\(lkError.localizedDescription)"
                        + (underlying.map { " underlying=\($0.localizedDescription)" } ?? "")
                } else {
                    detail = error.localizedDescription
                }

                interLogError(InterLog.networking, "RoomController: connect failed after %dms: %{public}@",
                              latencyMs, detail)

                self.isConnecting = false
                self.setConnectionState(.disconnectedWithError)

                let nsError = InterNetworkErrorCode.connectionFailed.error(
                    message: "Room connect failed",
                    underlyingError: error
                )
                DispatchQueue.main.async {
                    completion(nsError)
                }
            }
        }
    }

    // MARK: - Disconnect

    /// Disconnect from the room. Unpublishes all tracks and cleans up.
    @objc public func disconnect() {
        disconnect(reason: "user initiated")
    }

    private func disconnect(reason: String) {
        guard connectionState != .disconnected else { return }

        interLogInfo(InterLog.networking, "RoomController: disconnecting (reason=%{public}@)", reason)

        // Stop stats collector
        statsCollector?.stop()
        statsCollector = nil

        // Unpublish all tracks (fire-and-forget)
        publisher.unpublishAll(captureSession: nil, sessionQueue: nil)
        publisher.localParticipant = nil

        // Detach subscriber
        subscriber.detach()

        // Cancel grace timer
        cancelGraceTimer()

        // Disconnect room
        if let room = room {
            Task {
                await room.disconnect()
            }
        }
        room = nil

        // Log session duration
        if sessionStartTime > 0 {
            let durationSecs = Int(CFAbsoluteTimeGetCurrent() - sessionStartTime)
            interLogInfo(InterLog.networking, "RoomController: session duration=%ds", durationSecs)
        }

        // Reset state
        configuration = nil
        isConnecting = false
        sessionStartTime = 0
        connectStartTime = 0

        setConnectionState(.disconnected)

        DispatchQueue.main.async {
            self.remoteParticipantCount = 0
            self.participantPresenceState = .alone
            self.roomCode = ""
        }
    }

    // MARK: - G4: Mode Transition

    /// Transition between call modes (Normal ↔ Secure).
    /// Unpublishes all tracks and detaches sources, but keeps the room connected.
    /// The subscriber stays active so remote frames continue flowing.
    ///
    /// After completion, the caller re-attaches sources and re-publishes.
    @objc public func transitionMode(completion: @escaping () -> Void) {
        guard connectionState == .connected || connectionState == .reconnecting else {
            interLogInfo(InterLog.networking, "RoomController: transitionMode — not connected, skipping")
            completion()
            return
        }

        interLogInfo(InterLog.networking, "RoomController: mode transition — detaching sources")

        // Unpublish all tracks, then detach sources
        publisher.unpublishAll(captureSession: nil, sessionQueue: nil) { [weak self] in
            self?.publisher.detachAllSources()
            interLogInfo(InterLog.networking, "RoomController: mode transition complete — ready for re-attach")
            completion()
        }
    }

    // MARK: - Token Refresh

    /// Refresh the authentication token. Called when token is about to expire.
    private func refreshToken() {
        guard let config = configuration, connectionState == .connected else { return }

        let code = roomCode.isEmpty ? config.roomCode : roomCode

        interLogInfo(InterLog.networking, "RoomController: refreshing token")

        tokenService.refreshToken(
            serverURL: config.tokenServerURL,
            roomCode: code,
            identity: config.participantIdentity
        ) { [weak self] token, error in
            if let error = error {
                interLogError(InterLog.networking, "RoomController: token refresh failed: %{public}@",
                              error.localizedDescription)
                // Don't disconnect — the SDK will handle token expiry via reconnection.
                return
            }

            guard let token = token else { return }

            interLogInfo(InterLog.networking, "RoomController: token refreshed successfully")

            // Note: LiveKit SDK currently doesn't expose a public API to update the token
            // on an existing room connection. The token will be used on the next reconnect.
            // For now, we store it in the token service cache.
            _ = token
        }
    }

    // MARK: - State Management

    private func setConnectionState(_ newState: InterRoomConnectionState) {
        DispatchQueue.main.async {
            let oldState = self.connectionState
            guard oldState != newState else { return }
            self.connectionState = newState
            interLogInfo(InterLog.networking, "RoomController: state %d → %d", oldState.rawValue, newState.rawValue)
        }
    }

    // MARK: - G6: Participant Presence

    private func updateParticipantPresence() {
        guard let room = room else { return }

        let count = room.remoteParticipants.count

        DispatchQueue.main.async {
            self.remoteParticipantCount = count

            if count > 0 {
                // Cancel any pending grace timer — participant(s) present
                self.cancelGraceTimer()
                self.participantPresenceState = .participantJoined
            } else if self.participantPresenceState == .participantJoined {
                // Start 3-second grace timer before surfacing .participantLeft
                self.startGraceTimer()
            }
            // If already .alone, stay .alone
        }
    }

    private func startGraceTimer() {
        cancelGraceTimer()

        interLogInfo(InterLog.networking, "RoomController: participant left — starting 3s grace timer")

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 3.0)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            // Double-check: participant might have reconnected during grace period
            if self.remoteParticipantCount == 0 {
                self.participantPresenceState = .participantLeft
                interLogInfo(InterLog.networking, "RoomController: grace timer expired — participant left")
            }
        }
        timer.resume()
        participantGraceTimer = timer
    }

    private func cancelGraceTimer() {
        participantGraceTimer?.cancel()
        participantGraceTimer = nil
    }
}

// MARK: - RoomDelegate

extension InterRoomController: RoomDelegate {

    // MARK: Connection Events

    public nonisolated func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        // Map LiveKit ConnectionState to our InterRoomConnectionState
        let mapped: InterRoomConnectionState
        switch connectionState {
        case .disconnected:
            mapped = .disconnected
        case .connecting:
            mapped = .connecting
        case .reconnecting:
            mapped = .reconnecting
        case .connected:
            mapped = .connected
        @unknown default:
            mapped = .disconnected
        }

        interLogInfo(InterLog.networking, "RoomController: LiveKit connectionState → %d", mapped.rawValue)
        self.setConnectionState(mapped)
    }

    public nonisolated func roomDidConnect(_ room: Room) {
        interLogInfo(InterLog.networking, "RoomController: roomDidConnect")
        self.setConnectionState(.connected)
    }

    public nonisolated func roomIsReconnecting(_ room: Room) {
        interLogInfo(InterLog.networking, "RoomController: roomIsReconnecting")
        self.setConnectionState(.reconnecting)
    }

    public nonisolated func roomDidReconnect(_ room: Room) {
        interLogInfo(InterLog.networking, "RoomController: roomDidReconnect")
        self.setConnectionState(.connected)
        self.updateParticipantPresence()
    }

    public nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        if let error = error {
            interLogError(InterLog.networking, "RoomController: disconnected with error: %{public}@",
                          error.localizedDescription)
            self.setConnectionState(.disconnectedWithError)
        } else {
            interLogInfo(InterLog.networking, "RoomController: disconnected cleanly")
            self.setConnectionState(.disconnected)
        }
    }

    // MARK: Participant Events [G6]

    public nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        interLogInfo(InterLog.networking, "RoomController: participant connected: %{public}@",
                     participant.identity?.stringValue ?? "(unknown)")
        self.updateParticipantPresence()
    }

    public nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        interLogInfo(InterLog.networking, "RoomController: participant disconnected: %{public}@",
                     participant.identity?.stringValue ?? "(unknown)")
        self.updateParticipantPresence()
    }
}
