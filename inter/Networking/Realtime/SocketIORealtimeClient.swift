//
//  SocketIORealtimeClient.swift
//  inter
//
//  socket.io-client-swift implementation of InterRealtimeClient (Teams-chat
//  decision-council Option B1). Pinned to socket.io-client-swift 16.1.1.
//
//  Transport choices (matching the design spec + OWASP WebSocket guidance):
//   - .forceWebsockets(true): skip HTTP long-polling; use the WSS transport only.
//   - .reconnects(false): the library's auto-reconnect is DISABLED so we own the
//     reconnect loop and can pull a FRESH access token for every attempt (H6) —
//     the council's requirement that a rotated token is always used on reconnect.
//   - JWT is sent via connect(withPayload: ["token": jwt]); in the Socket.IO v3+
//     protocol the CONNECT-packet payload is the handshake `auth` object, so the
//     server reads it as socket.handshake.auth.token (matches teamsRealtime.js).
//
//  Teardown (paranoid 2C): disconnect() cancels the reconnect timer, tears down
//  the socket + manager, and clears the event router — one teardown path, no
//  leaked handlers/timers.
//

import Foundation
import SocketIO

public final class SocketIORealtimeClient: InterRealtimeClient {

    public weak var stateDelegate: InterRealtimeClientStateDelegate?
    private let stateLock = NSLock()
    private var _state: InterRealtimeConnectionState = .disconnected
    /// Thread-safe read of the last published connection state.
    public var state: InterRealtimeConnectionState {
        stateLock.lock(); defer { stateLock.unlock() }
        return _state
    }
    /// Set the state from any thread; notifies the delegate on main only when it changes.
    private func setState(_ newValue: InterRealtimeConnectionState) {
        stateLock.lock()
        let changed = (_state != newValue)
        _state = newValue
        stateLock.unlock()
        guard changed else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.stateDelegate?.realtimeClient(self, didChange: newValue)
        }
    }

    private let serverURL: URL
    private let namespace: String
    private let joinEvent: String
    private let leaveEvent: String
    private let enableLogging: Bool
    private let router = InterRealtimeEventRouter()

    // All socket/manager/timer access is confined to `queue` (the manager's
    // handle queue) so there is no cross-thread races on these references.
    private let queue = DispatchQueue(label: "inter.realtime.socketio")
    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private var tokenProvider: (() -> String?)?
    private var socketListenerEvents = Set<String>()   // events with an underlying socket.on
    private var joinedRooms = Set<String>()            // rooms to (re)join on every connect
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var intentionalDisconnect = false

    private let maxReconnectDelay: TimeInterval = 30

    /// - Parameters:
    ///   - serverURL: token-server base URL (the namespace is appended internally).
    ///   - namespace: Socket.IO namespace. Defaults to "/teams".
    ///   - joinEvent/leaveEvent: room join/leave event names. Default to the team
    ///     chat contract; parameterized so the same client can later serve other
    ///     namespaces (lobby/moderation) without code changes here.
    public init(serverURL: URL,
                namespace: String = "/teams",
                joinEvent: String = "team:join",
                leaveEvent: String = "team:leave",
                enableLogging: Bool = false) {
        self.serverURL = serverURL
        self.namespace = namespace
        self.joinEvent = joinEvent
        self.leaveEvent = leaveEvent
        self.enableLogging = enableLogging
    }

    // MARK: - InterRealtimeClient

    public func connect(tokenProvider: @escaping () -> String?) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.tokenProvider = tokenProvider
            self.intentionalDisconnect = false
            self.reconnectAttempt = 0
            self.establishConnection()
        }
    }

    public func join(room: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            // Remember the room so it is (re)joined on every connect — a join emitted
            // before the socket is connected, or lost across a reconnect, would
            // otherwise silently drop the user out of the room. The connect handler
            // replays joinedRooms, so membership always converges to the latest set.
            self.joinedRooms.insert(room)
            if self.state == .connected, let socket = self.socket {
                socket.emit(self.joinEvent, ["teamId": room])
            }
        }
    }

    public func leave(room: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.joinedRooms.remove(room)
            if let socket = self.socket {
                socket.emit(self.leaveEvent, ["teamId": room])
            }
        }
    }

    public func on(_ event: String, handler: @escaping (Data) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.router.on(event, handler)
            self.ensureSocketListener(for: event)
        }
    }

    public func disconnect() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.intentionalDisconnect = true
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.socket?.removeAllHandlers()
            self.socket?.disconnect()
            self.manager?.disconnect()
            self.socket = nil
            self.manager = nil
            self.socketListenerEvents.removeAll()
            self.joinedRooms.removeAll()
            self.router.removeAll()       // 2C: release every event handler
            self.tokenProvider = nil
            self.setState(.disconnected)
        }
    }

    // MARK: - Connection lifecycle (queue-confined)

    private func establishConnection() {
        guard let token = tokenProvider?(), !token.isEmpty else {
            // No valid session — abort; nothing to (re)connect with.
            setState(.disconnected)
            return
        }

        setState(reconnectAttempt == 0 ? .connecting : .reconnecting)

        // Rebuild the manager/socket each attempt so a fresh CONNECT payload
        // (fresh token) is sent. forceWebsockets + reconnects(false): we own retries.
        socket?.removeAllHandlers()
        manager?.disconnect()

        let mgr = SocketManager(socketURL: serverURL, config: [
            .forceWebsockets(true),
            .reconnects(false),
            .log(enableLogging),
            .compress,
        ])
        let sock = mgr.socket(forNamespace: namespace)
        self.manager = mgr
        self.socket = sock

        sock.on(clientEvent: .connect) { [weak self] _, _ in
            self?.queue.async {
                guard let self = self else { return }
                self.reconnectAttempt = 0
                self.setState(.connected)
                // Replay room subscriptions on every (re)connect so membership
                // survives drops — without this a reconnected client would stop
                // receiving team messages until the next manual join.
                if let socket = self.socket {
                    for room in self.joinedRooms {
                        socket.emit(self.joinEvent, ["teamId": room])
                    }
                }
            }
        }
        sock.on(clientEvent: .error) { [weak self] _, _ in
            self?.queue.async { self?.scheduleReconnect() }
        }
        sock.on(clientEvent: .disconnect) { [weak self] _, _ in
            self?.queue.async { self?.scheduleReconnect() }
        }

        // Re-attach any event listeners registered before (re)connect.
        for event in socketListenerEvents { attachRawListener(sock, event) }

        sock.connect(withPayload: ["token": token])
    }

    private func scheduleReconnect() {
        guard !intentionalDisconnect else { return }
        guard reconnectWorkItem == nil else { return }   // one pending attempt at a time

        setState(.reconnecting)
        reconnectAttempt += 1
        // Exponential backoff, capped.
        let delay = min(maxReconnectDelay, pow(2.0, Double(min(reconnectAttempt, 5))))
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.reconnectWorkItem = nil
            guard !self.intentionalDisconnect else { return }
            self.establishConnection()
        }
        reconnectWorkItem = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // Register one underlying socket.on per distinct event; the router fans out
    // to all registered handlers for that event.
    private func ensureSocketListener(for event: String) {
        guard !socketListenerEvents.contains(event) else { return }
        socketListenerEvents.insert(event)
        if let sock = socket { attachRawListener(sock, event) }
    }

    private func attachRawListener(_ sock: SocketIOClient, _ event: String) {
        sock.on(event) { [weak self] data, _ in
            guard let self = self else { return }
            // Socket.IO hands back an array of emitted args; forward the first as
            // JSON Data through the router. Treat all message content as untrusted
            // (parsed downstream, never eval'd).
            let payload = data.first ?? [:]
            let json: Data
            if JSONSerialization.isValidJSONObject(payload),
               let d = try? JSONSerialization.data(withJSONObject: payload) {
                json = d
            } else {
                json = Data()
            }
            self.queue.async { self.router.dispatch(event, json) }
        }
    }
}
