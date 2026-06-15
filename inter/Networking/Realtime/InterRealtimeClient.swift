//
//  InterRealtimeClient.swift
//  inter
//
//  Transport-agnostic façade for the app's realtime layer.
//
//  Produced from the Teams-chat decision-council verdict: "build the
//  InterRealtimeClient façade first, then connect a transport behind it." The
//  wire implementation (official socket.io-client-swift, or a first-party
//  URLSessionWebSocketTask client) lives BEHIND this protocol, so the transport
//  choice is reversible and the same realtime pipe can later serve lobby,
//  moderation, and presence — not just team chat.
//
//  Design properties:
//   - REST remains the source of truth for all writes; this client is a
//     read/fan-out delivery channel (a dropped frame never loses data — the
//     consumer reconciles from persisted history).
//   - connect(tokenProvider:) pulls a FRESH access token on every (re)connect
//     so a rotated/refreshed token is always used (paranoid H6).
//   - disconnect() is the single teardown path (paranoid 2C: no leaked handlers,
//     timers, or sockets after logout / window close).
//

import Foundation

/// Connection lifecycle of a realtime client, surfaced to the UI for a status indicator.
@objc public enum InterRealtimeConnectionState: Int {
    case disconnected
    case connecting
    case connected
    case reconnecting
}

/// Receives connection-state transitions from an `InterRealtimeClient`.
public protocol InterRealtimeClientStateDelegate: AnyObject {
    func realtimeClient(_ client: InterRealtimeClient,
                        didChange state: InterRealtimeConnectionState)
}

/// The reusable realtime seam. Implementations own a transport; consumers only
/// see connect / join / on / leave / disconnect.
public protocol InterRealtimeClient: AnyObject {
    /// Observes connection-state changes. Weak — the owner retains the client.
    var stateDelegate: InterRealtimeClientStateDelegate? { get set }

    /// Current connection state (last published transition).
    var state: InterRealtimeConnectionState { get }

    /// Connect, or reconnect after a drop. `tokenProvider` is invoked on every
    /// (re)connect to obtain a fresh access token for the handshake; returning
    /// nil aborts the connect (no valid session).
    func connect(tokenProvider: @escaping () -> String?)

    /// Join a server-side room (e.g. "team:<uuid>"). Idempotent.
    func join(room: String)

    /// Leave a previously joined room. Idempotent.
    func leave(room: String)

    /// Register a handler for a named server event. Multiple handlers per event
    /// are allowed and invoked in registration order.
    func on(_ event: String, handler: @escaping (Data) -> Void)

    /// Tear down: drop the connection and release all handlers/timers. After this
    /// the client is inert until `connect` is called again.
    func disconnect()
}

/// Thread-safe event→handlers registry and dispatcher shared by realtime-client
/// implementations. Pure (no transport), so it is unit-testable in isolation and
/// gives every implementation ONE teardown path (`removeAll`) — the paranoid 2C
/// guard against leaked event handlers after disconnect/logout.
public final class InterRealtimeEventRouter {
    private let lock = NSLock()
    private var handlers: [String: [(Data) -> Void]] = [:]

    public init() {}

    /// Register a handler for `event`. Handlers accumulate (fan-out within the client).
    public func on(_ event: String, _ handler: @escaping (Data) -> Void) {
        lock.lock(); defer { lock.unlock() }
        handlers[event, default: []].append(handler)
    }

    /// Invoke every handler registered for `event` with `payload`. Handlers run
    /// outside the lock so a handler may safely re-enter the router. Returns the
    /// number of handlers invoked.
    @discardableResult
    public func dispatch(_ event: String, _ payload: Data) -> Int {
        lock.lock()
        let list = handlers[event] ?? []
        lock.unlock()
        for handler in list { handler(payload) }
        return list.count
    }

    /// Number of distinct events with at least one handler (diagnostics/tests).
    public var registeredEventCount: Int {
        lock.lock(); defer { lock.unlock() }
        return handlers.count
    }

    /// Release every handler. The single teardown path — call from `disconnect()`.
    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        handlers.removeAll()
    }
}
