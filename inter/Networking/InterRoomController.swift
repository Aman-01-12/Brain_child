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

    /// Identity of the current dominant/active speaker (nil if none or local).
    /// Updated by LiveKit's activeSpeakersChanged delegate. Used by the layout
    /// manager for speaker highlight effects.
    @objc public private(set) dynamic var activeSpeakerIdentity: String = ""

    /// Room code (6-char alphanumeric). Set after create or join. [G7]
    @objc public private(set) dynamic var roomCode: String = ""

    /// Room type: "call" or "interview". Set from the token server response.
    /// Used by AppDelegate to determine which mode/role to enter on join.
    @objc public private(set) dynamic var roomType: String = ""

    // MARK: - Owned Components

    /// Publisher: manages local track publishing.
    @objc public let publisher = InterLiveKitPublisher()

    /// Subscriber: manages remote track subscription.
    @objc public let subscriber = InterLiveKitSubscriber()

    /// Token service: JWT fetch/cache/refresh.
    @objc public let tokenService = InterTokenService()

    /// Stats collector: periodic stats gathering. Created on connect, destroyed on disconnect.
    @objc public private(set) var statsCollector: InterCallStatsCollector?

    /// [Phase 8] Chat + control signal controller. Created by the caller (AppDelegate)
    /// and wired in before connect. The room controller forwards DataChannel data to it.
    @objc public weak var chatController: InterChatController?

    /// [Phase 8.5] Live-poll controller. Wired in by the caller before connect.
    @objc public weak var pollController: InterPollController?

    /// [Phase 8.6] Q&A controller. Wired in by the caller before connect.
    @objc public weak var qaController: InterQAController?

    /// The local participant's identity string (ObjC-safe accessor).
    @objc public var localParticipantIdentity: String {
        return room?.localParticipant.identity?.stringValue ?? ""
    }

    /// The local participant's display name (ObjC-safe accessor).
    @objc public var localParticipantName: String {
        return room?.localParticipant.name ?? "You"
    }

    /// Whether the local participant is the host (room creator).
    @objc public var isHost: Bool {
        return configuration?.isHost ?? false
    }

    /// [Phase 9] Token server base URL (e.g. "http://localhost:3000").
    /// Exposed for the moderation controller to make HTTP calls.
    @objc public var tokenServerURL: String {
        return configuration?.tokenServerURL ?? ""
    }

    // MARK: - Private Properties

    /// The LiveKit Room instance. Created fresh for each connection.
    private var room: Room?

    /// The room configuration for the current session.
    private var configuration: InterRoomConfiguration?

    /// Private serial queue for state transitions.
    private let stateQueue = DispatchQueue(label: "inter.room.state", qos: .userInitiated)

    /// Grace timer for participant-left delay. [G6]
    private var participantGraceTimer: DispatchSourceTimer?

    /// Token auto-refresh timer. Fires at ~80% of TTL to keep the session alive.
    private var tokenRefreshTimer: DispatchSourceTimer?

    /// Memory pressure source for graceful degradation under low-memory conditions.
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    /// Whether screen share was unpublished due to memory pressure (for auto-restore).
    private var screenShareSuspendedForMemory = false

    /// Debounce work item for clearing active speaker identity.
    /// Prevents green border flicker when VAD briefly sends active=false during continuous speech.
    private var activeSpeakerClearWork: DispatchWorkItem?

    /// Cooldown interval (seconds) before clearing the active speaker border.
    private let activeSpeakerClearDelay: TimeInterval = 1.0

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
                displayName: configuration.participantName,
                roomType: configuration.roomType.isEmpty ? "call" : configuration.roomType
            ) { [weak self] response, error in
                self?.handleTokenResponse(
                    token: response?.token,
                    serverURL: response?.serverURL ?? configuration.serverURL,
                    roomCode: response?.roomCode,
                    roomType: response?.roomType ?? "call",
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
                    roomType: response?.roomType ?? "call",
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
        roomType: String,
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

        // Store room code and room type on main queue (synchronous if already on main,
        // otherwise dispatched before the async connect begins).
        if let code = roomCode, !code.isEmpty {
            DispatchQueue.main.async {
                self.roomCode = code
            }
        }
        // roomType must be set before the connect completion fires so AppDelegate
        // can read it — use sync dispatch if off main, direct assignment if on main.
        if Thread.isMainThread {
            self.roomType = roomType
        } else {
            DispatchQueue.main.sync {
                self.roomType = roomType
            }
        }

        // Step 2: Create and connect the LiveKit Room
        let connectOptions = ConnectOptions(
            autoSubscribe: true,
            reconnectAttempts: 3,
            reconnectAttemptDelay: 2.0
        )

        // Phase 7.2.1: Enable adaptive streaming — LiveKit automatically adjusts
        // video resolution/framerate based on subscriber viewport size.
        let roomOptions = RoomOptions(
            adaptiveStream: true,
            dynacast: true
        )

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

                // Schedule token auto-refresh [4.5.4]
                self.scheduleTokenRefresh()

                // Start memory pressure monitor
                self.startMemoryPressureMonitor()

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

        // Stop stats collector and export data
        if let collector = statsCollector {
            if let jsonData = collector.exportToJSON() {
                let byteCount = jsonData.count
                interLogInfo(InterLog.networking, "RoomController: exported %d bytes of call stats JSON", byteCount)
                // Store in a well-known location for later retrieval / debugging
                if let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyyMMdd_HHmmss"
                    let filename = "inter_call_stats_\(formatter.string(from: Date())).json"
                    let fileURL = cachesDir.appendingPathComponent(filename)
                    do {
                        try jsonData.write(to: fileURL)
                        interLogInfo(InterLog.networking, "RoomController: stats saved to %{public}@", fileURL.path)
                    } catch {
                        interLogError(InterLog.networking, "RoomController: failed to write stats: %{public}@",
                                      error.localizedDescription)
                    }
                }
            }
            collector.stop()
        }
        statsCollector = nil

        // Unpublish all tracks (fire-and-forget)
        publisher.unpublishAll(captureSession: nil, sessionQueue: nil)
        publisher.localParticipant = nil

        // Detach subscriber
        subscriber.detach()

        // Cancel grace timer
        cancelGraceTimer()

        // Cancel token refresh timer
        cancelTokenRefreshTimer()

        // Stop memory pressure monitor
        stopMemoryPressureMonitor()

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
            self.activeSpeakerClearWork?.cancel()
            self.activeSpeakerClearWork = nil
            self.activeSpeakerIdentity = ""
            self.roomCode = ""
            self.roomType = ""
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

    /// Schedule a timer to refresh the token at ~80% of its TTL.
    /// Called after connect and after each successful refresh.
    private func scheduleTokenRefresh() {
        cancelTokenRefreshTimer()

        guard let config = configuration else { return }
        let code = roomCode.isEmpty ? config.roomCode : roomCode
        let ttl = tokenService.cachedTokenTTL(forRoom: code, identity: config.participantIdentity)

        // If TTL is unknown or already expired, try refreshing in 60 seconds
        let interval: TimeInterval
        if ttl > 60 {
            // Fire at 80% of remaining TTL (e.g. 5-minute token → refresh at 4 minutes)
            interval = ttl * 0.8
        } else if ttl > 0 {
            // Less than 60s — refresh immediately
            interval = 1.0
        } else {
            // Unknown TTL — default to 4 minutes (typical LiveKit token is 5-10 min)
            interval = 240.0
        }

        interLogInfo(InterLog.networking, "RoomController: scheduling token refresh in %ds (TTL=%.0fs)",
                     Int(interval), ttl)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval)
        timer.setEventHandler { [weak self] in
            self?.refreshToken()
        }
        timer.resume()
        tokenRefreshTimer = timer
    }

    private func cancelTokenRefreshTimer() {
        tokenRefreshTimer?.cancel()
        tokenRefreshTimer = nil
    }

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
                // Schedule a retry in 30 seconds
                self?.scheduleTokenRefreshRetry()
                return
            }

            guard let token = token else { return }

            interLogInfo(InterLog.networking, "RoomController: token refreshed successfully")

            // Note: LiveKit SDK currently doesn't expose a public API to update the token
            // on an existing room connection. The token will be used on the next reconnect.
            // For now, we store it in the token service cache.
            _ = token

            // Reschedule refresh based on the new token's TTL
            self?.scheduleTokenRefresh()
        }
    }

    /// Schedule a short retry after a failed refresh attempt.
    private func scheduleTokenRefreshRetry() {
        cancelTokenRefreshTimer()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30.0)
        timer.setEventHandler { [weak self] in
            self?.refreshToken()
        }
        timer.resume()
        tokenRefreshTimer = timer

        interLogInfo(InterLog.networking, "RoomController: token refresh retry scheduled in 30s")
    }

    // MARK: - Memory Pressure Response

    /// Start monitoring system memory pressure.
    /// On `.warning`: log but keep going (screen share stays up).
    /// On `.critical`: unpublish screen share to free memory.
    private func startMemoryPressureMonitor() {
        stopMemoryPressureMonitor()

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let event = source.data
            if event.contains(.critical) {
                self.handleMemoryPressureCritical()
            } else if event.contains(.warning) {
                self.handleMemoryPressureWarning()
            }
        }
        source.resume()
        memoryPressureSource = source
        interLogInfo(InterLog.networking, "RoomController: memory pressure monitor started")
    }

    private func stopMemoryPressureMonitor() {
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        screenShareSuspendedForMemory = false
    }

    private func handleMemoryPressureWarning() {
        interLogInfo(InterLog.networking, "RoomController: memory pressure WARNING — monitoring")
        // Log a diagnostic note; screen share stays active.
        // The system may reclaim memory from other processes first.
    }

    private func handleMemoryPressureCritical() {
        interLogError(InterLog.networking, "RoomController: memory pressure CRITICAL — unpublishing screen share")

        guard publisher.screenSharePublication != nil else { return }
        screenShareSuspendedForMemory = true
        publisher.unpublishScreenShare {
            interLogInfo(InterLog.networking, "RoomController: screen share unpublished (memory pressure)")
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

    // MARK: - Phase 8: Participant List for DM Selector

    /// Returns an array of dictionaries with "identity" and "name" keys
    /// for each remote participant currently in the room.
    @objc public func remoteParticipantList() -> [[String: String]] {
        guard let room = room else { return [] }
        return room.remoteParticipants.values.map { participant in
            [
                "identity": participant.identity?.stringValue ?? "",
                "name": participant.name ?? participant.identity?.stringValue ?? "Unknown"
            ]
        }
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
        // Re-schedule token refresh after reconnect (the old token may have been used)
        DispatchQueue.main.async {
            self.scheduleTokenRefresh()
        }
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

    // MARK: Active Speakers

    public nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        // Find the loudest remote participant (first in the sorted list that isn't local)
        let remoteSpeaker = participants.first { $0 is RemoteParticipant }
        let identity = remoteSpeaker?.identity?.stringValue ?? ""

        DispatchQueue.main.async {
            // Cancel any pending "clear speaker" timer.
            self.activeSpeakerClearWork?.cancel()
            self.activeSpeakerClearWork = nil

            if !identity.isEmpty {
                // Active remote speaker detected — update immediately.
                if self.activeSpeakerIdentity != identity {
                    self.activeSpeakerIdentity = identity
                    interLogInfo(InterLog.networking, "RoomController: active speaker → %{public}@", identity)
                }
            } else {
                // No remote speaker right now. Debounce the clear so brief VAD
                // dips (breaths, pauses between words) don't flicker the border.
                guard !self.activeSpeakerIdentity.isEmpty else { return }

                let work = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.activeSpeakerIdentity = ""
                    self.activeSpeakerClearWork = nil
                    interLogInfo(InterLog.networking, "RoomController: active speaker → (none) [debounced]")
                }
                self.activeSpeakerClearWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + self.activeSpeakerClearDelay, execute: work)
            }
        }
    }

    // MARK: DataChannel [Phase 8]

    public nonisolated func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        let senderIdentity = participant?.identity?.stringValue
        interLogDebug(InterLog.room, "RoomController: received data (%d bytes) on topic '%{public}@' from %{public}@",
                      data.count, topic, senderIdentity ?? "server")

        DispatchQueue.main.async {
            switch topic {
            case "poll":
                self.pollController?.handleReceivedData(data, senderIdentity: senderIdentity)
            case "qa":
                self.qaController?.handleReceivedData(data, senderIdentity: senderIdentity)
            default:
                self.chatController?.handleReceivedData(data, topic: topic, participant: senderIdentity)
            }
        }
    }
}
