// ============================================================================
// InterTokenService.swift
// inter
//
// Phase 1.3 — Token fetch, caching, and refresh via the token server.
//
// ISOLATION INVARIANT [G8]:
// This class has NO side effects on local media, recording, or UI.
// All errors are reported via completion blocks. If the token server is
// unreachable, callers receive an NSError — the app continues locally.
//
// SECURITY:
// - API key/secret are NEVER embedded in the client binary.
// - JWTs are returned from the server and cached in memory only.
// - Tokens are NEVER logged (not even at debug level).
// ============================================================================

import Foundation
import os.log

// MARK: - Token Response Model

/// Parsed response from the token server's /room/create endpoint.
@objc public class InterCreateRoomResponse: NSObject {
    /// The 6-character room code.
    @objc public let roomCode: String
    /// The LiveKit room name (e.g. "inter-ABC123").
    @objc public let roomName: String
    /// JWT access token.
    @objc public let token: String
    /// LiveKit server WebSocket URL.
    @objc public let serverURL: String
    /// Room type: "call" or "interview". Defaults to "call" for backward compatibility.
    @objc public let roomType: String

    @objc public init(roomCode: String, roomName: String, token: String, serverURL: String, roomType: String = "call") {
        self.roomCode = roomCode
        self.roomName = roomName
        self.token = token
        self.serverURL = serverURL
        self.roomType = roomType
        super.init()
    }
}

/// Parsed response from the token server's /room/join endpoint.
@objc public class InterJoinRoomResponse: NSObject {
    /// The LiveKit room name.
    @objc public let roomName: String
    /// JWT access token.
    @objc public let token: String
    /// LiveKit server WebSocket URL.
    @objc public let serverURL: String
    /// Room type: "call" or "interview". Determines the mode the joiner enters.
    @objc public let roomType: String

    @objc public init(roomName: String, token: String, serverURL: String, roomType: String = "call") {
        self.roomName = roomName
        self.token = token
        self.serverURL = serverURL
        self.roomType = roomType
        super.init()
    }
}

// MARK: - Token Cache Entry

/// Internal cache entry holding a token and its expiration time.
private struct TokenCacheEntry {
    let token: String
    let expiresAt: Date

    /// Returns true if the token has more than 60 seconds of life remaining.
    var isValid: Bool {
        return expiresAt.timeIntervalSinceNow > 60.0
    }
}

// MARK: - InterTokenService

/// Fetches, caches, and refreshes JWTs from the token server.
///
/// All public methods deliver their completion block on the **main queue**.
/// Network requests use a 10-second timeout and retry once on 5xx/timeout.
/// 4xx errors are NOT retried — they indicate client-side problems.
///
/// Usage from ObjC:
/// ```objc
/// InterTokenService *tokenService = [[InterTokenService alloc] init];
/// [tokenService createRoomWithServerURL:@"http://localhost:3000"
///                              identity:@"host-alice"
///                           displayName:@"Alice"
///                            completion:^(InterCreateRoomResponse *resp, NSError *err) { ... }];
/// ```
@objc public class InterTokenService: NSObject {

    // MARK: - Private Properties

    /// URLSession with 10-second timeout.
    private let session: URLSession

    /// Token cache keyed by "roomCode:identity".
    private var tokenCache: [String: TokenCacheEntry] = [:]

    /// Serial queue protecting the token cache.
    private let cacheQueue = DispatchQueue(label: "inter.tokenService.cache", qos: .userInitiated)

    /// Maximum number of retries for 5xx/timeout errors.
    private let maxRetries = 1

    // MARK: - Init

    @objc public override init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 15.0
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
        super.init()
    }

    /// Initializer accepting an injected URLSession (for testing).
    init(session: URLSession) {
        self.session = session
        super.init()
    }

    // MARK: - Public API

    /// Create a new room. [G7]
    ///
    /// Calls `POST /room/create` on the token server.
    /// - Parameters:
    ///   - serverURL: Base URL of the token server (e.g. "http://localhost:3000").
    ///   - identity: Unique participant identity.
    ///   - displayName: Human-readable name shown to remote participants.
    ///   - roomType: Room type string ("call" or "interview"). Defaults to "call".
    ///   - completion: Called on the main queue with either a response or an error.
    @objc public func createRoom(serverURL: String,
                                 identity: String,
                                 displayName: String,
                                 roomType: String = "call",
                                 completion: @escaping (InterCreateRoomResponse?, NSError?) -> Void) {
        var body: [String: Any] = [
            "identity": identity,
            "displayName": displayName
        ]
        // Only send roomType when non-default to stay backward-compatible with older servers
        if !roomType.isEmpty && roomType != "call" {
            body["roomType"] = roomType
        }

        interLogInfo(InterLog.networking, "Token: creating room (identity=%{private}@)", identity)

        performRequest(
            url: "\(serverURL)/room/create",
            body: body,
            retryCount: 0
        ) { [weak self] result in
            switch result {
            case .success(let data):
                guard let json = self?.parseJSON(data),
                      let roomCode = json["roomCode"] as? String,
                      let roomName = json["roomName"] as? String,
                      let token = json["token"] as? String,
                      let wsURL = json["serverURL"] as? String else {
                    let error = InterNetworkErrorCode.tokenFetchFailed.error(
                        message: "Malformed response from /room/create"
                    )
                    interLogError(InterLog.networking, "Token: /room/create malformed response")
                    self?.completeOnMain { completion(nil, error) }
                    return
                }

                // roomType is optional in the response for backward compatibility
                let responseRoomType = json["roomType"] as? String ?? "call"

                // Cache the token
                self?.cacheToken(token, forRoom: roomCode, identity: identity)

                let response = InterCreateRoomResponse(
                    roomCode: roomCode,
                    roomName: roomName,
                    token: token,
                    serverURL: wsURL,
                    roomType: responseRoomType
                )
                interLogInfo(InterLog.networking, "Token: room created (code=***, type=%{public}@)", responseRoomType)
                self?.completeOnMain { completion(response, nil) }

            case .failure(let error):
                interLogError(InterLog.networking, "Token: /room/create failed (code=%{public}d)", error.code)
                self?.completeOnMain { completion(nil, error) }
            }
        }
    }

    /// Join an existing room. [G7]
    ///
    /// Calls `POST /room/join` on the token server.
    /// Returns `InterNetworkErrorCode.roomCodeInvalid` (404) or `.roomCodeExpired` (410)
    /// for bad room codes.
    @objc public func joinRoom(serverURL: String,
                               roomCode: String,
                               identity: String,
                               displayName: String,
                               completion: @escaping (InterJoinRoomResponse?, NSError?) -> Void) {
        // Check cache first
        if let cached = cachedToken(forRoom: roomCode, identity: identity) {
            interLogDebug(InterLog.networking, "Token: using cached token for join")
            // We still need roomName/serverURL — but cached means we already joined before.
            // For simplicity, always fetch from server on join (cache is mainly for refresh).
        }

        let body: [String: Any] = [
            "roomCode": roomCode,
            "identity": identity,
            "displayName": displayName
        ]

        interLogInfo(InterLog.networking, "Token: joining room (code=***, identity=%{private}@)", identity)

        performRequest(
            url: "\(serverURL)/room/join",
            body: body,
            retryCount: 0
        ) { [weak self] result in
            switch result {
            case .success(let data):
                guard let json = self?.parseJSON(data) else {
                    let error = InterNetworkErrorCode.tokenFetchFailed.error(
                        message: "Malformed response from /room/join"
                    )
                    interLogError(InterLog.networking, "Token: /room/join malformed response (not JSON)")
                    self?.completeOnMain { completion(nil, error) }
                    return
                }

                // Phase 9.3 — Lobby/waiting room response
                if let status = json["status"] as? String, status == "waiting" {
                    let position = json["position"] as? Int ?? 0
                    let error = InterNetworkErrorCode.lobbyWaiting.error(
                        message: "You are in the waiting room (position \(position)). The host will admit you shortly."
                    )
                    interLogInfo(InterLog.networking, "Token: /room/join → lobby waiting (position=%d)", position)
                    self?.completeOnMain { completion(nil, error) }
                    return
                }

                guard let roomName = json["roomName"] as? String,
                      let token = json["token"] as? String,
                      let wsURL = json["serverURL"] as? String else {
                    let error = InterNetworkErrorCode.tokenFetchFailed.error(
                        message: "Malformed response from /room/join"
                    )
                    interLogError(InterLog.networking, "Token: /room/join malformed response")
                    self?.completeOnMain { completion(nil, error) }
                    return
                }

                // roomType is optional for backward compatibility with older servers
                let responseRoomType = json["roomType"] as? String ?? "call"

                self?.cacheToken(token, forRoom: roomCode, identity: identity)

                let response = InterJoinRoomResponse(
                    roomName: roomName,
                    token: token,
                    serverURL: wsURL,
                    roomType: responseRoomType
                )
                interLogInfo(InterLog.networking, "Token: room joined (code=***, type=%{public}@)", responseRoomType)
                self?.completeOnMain { completion(response, nil) }

            case .failure(let error):
                interLogError(InterLog.networking, "Token: /room/join failed (code=%{public}d)", error.code)
                self?.completeOnMain { completion(nil, error) }
            }
        }
    }

    /// Refresh a token for an active participant. [G7]
    ///
    /// Calls `POST /token/refresh`. Returns cached token if it has >60s remaining.
    @objc public func refreshToken(serverURL: String,
                                   roomCode: String,
                                   identity: String,
                                   completion: @escaping (String?, NSError?) -> Void) {
        // Return cached if still valid
        if let cached = cachedToken(forRoom: roomCode, identity: identity) {
            interLogDebug(InterLog.networking, "Token: returning cached token (>60s remaining)")
            completeOnMain { completion(cached, nil) }
            return
        }

        let body: [String: Any] = [
            "roomCode": roomCode,
            "identity": identity
        ]

        interLogInfo(InterLog.networking, "Token: refreshing (code=***, identity=%{private}@)", identity)

        performRequest(
            url: "\(serverURL)/token/refresh",
            body: body,
            retryCount: 0
        ) { [weak self] result in
            switch result {
            case .success(let data):
                guard let json = self?.parseJSON(data),
                      let token = json["token"] as? String else {
                    let error = InterNetworkErrorCode.tokenFetchFailed.error(
                        message: "Malformed response from /token/refresh"
                    )
                    interLogError(InterLog.networking, "Token: /token/refresh malformed response")
                    self?.completeOnMain { completion(nil, error) }
                    return
                }

                self?.cacheToken(token, forRoom: roomCode, identity: identity)
                interLogInfo(InterLog.networking, "Token: refreshed successfully")
                self?.completeOnMain { completion(token, nil) }

            case .failure(let error):
                interLogError(InterLog.networking, "Token: /token/refresh failed (code=%{public}d)", error.code)
                self?.completeOnMain { completion(nil, error) }
            }
        }
    }

    /// Invalidate all cached tokens (e.g. on disconnect).
    @objc public func invalidateCache() {
        cacheQueue.sync {
            tokenCache.removeAll()
        }
        interLogDebug(InterLog.networking, "Token: cache invalidated")
    }

    /// Returns the number of seconds until the cached token expires for the
    /// given room and identity. Returns `nil` when no cached entry exists.
    /// Used by InterRoomController to schedule auto-refresh timers.
    @objc public func cachedTokenTTL(forRoom roomCode: String, identity: String) -> TimeInterval {
        let key = cacheKey(room: roomCode, identity: identity)
        return cacheQueue.sync {
            guard let entry = tokenCache[key] else { return -1 }
            return entry.expiresAt.timeIntervalSinceNow
        }
    }

    // MARK: - Private: Network

    /// Perform a POST request with JSON body. Retries once on 5xx/timeout.
    private func performRequest(
        url urlString: String,
        body: [String: Any],
        retryCount: Int,
        completion: @escaping (Result<Data, NSError>) -> Void
    ) {
        guard let url = URL(string: urlString) else {
            let error = InterNetworkErrorCode.serverUnreachable.error(
                message: "Invalid token server URL: \(urlString)"
            )
            completion(.failure(error))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            let nsError = InterNetworkErrorCode.tokenFetchFailed.error(
                message: "Failed to serialize request body",
                underlyingError: error
            )
            completion(.failure(nsError))
            return
        }

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            // Handle transport error (timeout, network down, etc.)
            if let error = error {
                let nsError = error as NSError
                if self.shouldRetry(statusCode: nil, nsError: nsError, retryCount: retryCount) {
                    interLogInfo(InterLog.networking, "Token: retrying after transport error (%{public}@)", nsError.localizedDescription)
                    self.performRequest(url: urlString, body: body, retryCount: retryCount + 1, completion: completion)
                    return
                }
                let wrappedError = InterNetworkErrorCode.serverUnreachable.error(
                    message: "Token server unreachable: \(nsError.localizedDescription)",
                    underlyingError: nsError
                )
                completion(.failure(wrappedError))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  let data = data else {
                let error = InterNetworkErrorCode.tokenFetchFailed.error(
                    message: "No response from token server"
                )
                completion(.failure(error))
                return
            }

            let statusCode = httpResponse.statusCode

            // Success
            if (200..<300).contains(statusCode) {
                completion(.success(data))
                return
            }

            // Client errors — no retry
            if statusCode == 404 {
                let error = InterNetworkErrorCode.roomCodeInvalid.error(
                    message: "Room code not found"
                )
                completion(.failure(error))
                return
            }

            if statusCode == 410 {
                let error = InterNetworkErrorCode.roomCodeExpired.error(
                    message: "Room code has expired"
                )
                completion(.failure(error))
                return
            }

            if statusCode == 429 {
                let error = InterNetworkErrorCode.tokenFetchFailed.error(
                    message: "Rate limit exceeded"
                )
                completion(.failure(error))
                return
            }

            if statusCode == 403 {
                let error = InterNetworkErrorCode.roomFull.error(
                    message: "Room is full"
                )
                completion(.failure(error))
                return
            }

            if statusCode == 423 {
                let error = InterNetworkErrorCode.meetingLocked.error(
                    message: "This meeting is locked. No new participants can join."
                )
                completion(.failure(error))
                return
            }

            if statusCode == 401 {
                let bodyStr = String(data: data, encoding: .utf8) ?? ""
                let isPasswordRequired = bodyStr.contains("passwordRequired")
                if isPasswordRequired {
                    let error = InterNetworkErrorCode.passwordRequired.error(
                        message: "This meeting requires a password"
                    )
                    completion(.failure(error))
                    return
                }
            }

            if (400..<500).contains(statusCode) {
                let bodyStr = String(data: data, encoding: .utf8) ?? "(unreadable)"
                let error = InterNetworkErrorCode.tokenFetchFailed.error(
                    message: "Token server error \(statusCode): \(bodyStr)"
                )
                completion(.failure(error))
                return
            }

            // Server errors (5xx) — retry once
            if self.shouldRetry(statusCode: statusCode, nsError: nil, retryCount: retryCount) {
                interLogInfo(InterLog.networking, "Token: retrying after %{public}d", statusCode)
                self.performRequest(url: urlString, body: body, retryCount: retryCount + 1, completion: completion)
                return
            }

            let error = InterNetworkErrorCode.tokenFetchFailed.error(
                message: "Token server returned \(statusCode)"
            )
            completion(.failure(error))
        }

        task.resume()
    }

    /// Whether to retry: 5xx or timeout, and haven't exceeded max retries.
    private func shouldRetry(statusCode: Int?, nsError: NSError?, retryCount: Int) -> Bool {
        guard retryCount < maxRetries else { return false }

        if let code = statusCode, code >= 500 {
            return true
        }

        if let nsError = nsError {
            let retryableCodes: Set<Int> = [
                NSURLErrorTimedOut,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorNotConnectedToInternet
            ]
            return retryableCodes.contains(nsError.code)
        }

        return false
    }

    // MARK: - Private: JSON

    private func parseJSON(_ data: Data) -> [String: Any]? {
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Private: Cache

    private func cacheKey(room: String, identity: String) -> String {
        return "\(room):\(identity)"
    }

    /// Extract expiration from a JWT (base64 decode the payload, read "exp").
    private func extractExpiration(from token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }

        var base64 = String(parts[1])
        // Pad to multiple of 4
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else {
            return nil
        }

        return Date(timeIntervalSince1970: exp)
    }

    private func cacheToken(_ token: String, forRoom roomCode: String, identity: String) {
        let key = cacheKey(room: roomCode, identity: identity)
        guard let expiration = extractExpiration(from: token) else {
            // Can't determine TTL — don't cache.
            return
        }
        let entry = TokenCacheEntry(token: token, expiresAt: expiration)
        cacheQueue.sync {
            tokenCache[key] = entry
        }
        let remaining = Int(expiration.timeIntervalSinceNow)
        interLogDebug(InterLog.networking, "Token: cached (TTL=%{public}ds)", remaining)
    }

    private func cachedToken(forRoom roomCode: String, identity: String) -> String? {
        let key = cacheKey(room: roomCode, identity: identity)
        return cacheQueue.sync {
            guard let entry = tokenCache[key], entry.isValid else {
                return nil
            }
            return entry.token
        }
    }

    // MARK: - Private: Threading

    /// Dispatch a block to the main queue for completion callback delivery.
    private func completeOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}
