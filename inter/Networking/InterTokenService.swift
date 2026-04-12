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
import IOKit
import Security
import CryptoKit

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

// MARK: - Auth Session Delegate

/// Delegate protocol for auth session lifecycle events.
/// Callbacks are delivered on the main queue.
@objc public protocol InterAuthSessionDelegate: AnyObject {
    /// Called when the auth session expires or is compromised, requiring re-login.
    func authSessionDidExpire()
    /// Called on successful authentication (login, register, or session restore).
    func authSessionDidAuthenticate(userId: String, tier: String)
}

// MARK: - Auth Response Model

/// Parsed response from /auth/login or /auth/register.
@objc public class InterAuthResponse: NSObject {
    @objc public let userId: String
    @objc public let email: String
    @objc public let displayName: String
    @objc public let tier: String
    @objc public let accessToken: String
    @objc public let refreshToken: String
    @objc public let expiresIn: TimeInterval

    init(userId: String, email: String, displayName: String, tier: String,
         accessToken: String, refreshToken: String, expiresIn: TimeInterval) {
        self.userId = userId
        self.email = email
        self.displayName = displayName
        self.tier = tier
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
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

    /// URLSession with TLS certificate pinning for auth operations.
    private let authSession: URLSession

    /// TLS pinning delegate (retained by authSession).
    private let pinnedDelegate: InterPinnedSessionDelegate

    /// Token cache keyed by "roomCode:identity".
    private var tokenCache: [String: TokenCacheEntry] = [:]

    /// Serial queue protecting the token cache.
    private let cacheQueue = DispatchQueue(label: "inter.tokenService.cache", qos: .userInitiated)

    /// Maximum number of retries for 5xx/timeout errors.
    private let maxRetries = 1

    // MARK: - Auth Properties

    /// Delegate for session lifecycle events.
    @objc public weak var authDelegate: InterAuthSessionDelegate?

    /// Current access token (JWT). Stored in memory only — NEVER persisted to disk.
    @objc public private(set) var currentAccessToken: String?

    /// Current authenticated user ID.
    @objc public private(set) var currentUserId: String?

    /// Current authenticated user email.
    @objc public private(set) var currentEmail: String?

    /// Current authenticated display name.
    @objc public private(set) var currentDisplayName: String?

    /// Current authenticated user tier (e.g. "free", "pro").
    @objc public private(set) var currentTier: String?

    /// Tier snapshot taken when a meeting starts. While set, `effectiveTier`
    /// returns this value so that mid-meeting tier changes (from token refresh)
    /// do not affect the active meeting.
    private var meetingStartTier: String?

    /// The tier that should be used for in-meeting decisions. Returns the
    /// locked meeting tier if a meeting is active, otherwise the latest
    /// account tier from the most recent token refresh.
    @objc public var effectiveTier: String? {
        return meetingStartTier ?? currentTier
    }

    /// Lock the current tier for the duration of a meeting. Call at room connect.
    /// Must be called on the main thread.
    @objc public func lockTierForMeeting() {
        assert(Thread.isMainThread, "lockTierForMeeting must be called on the main thread")
        meetingStartTier = currentTier
        interLogInfo(InterLog.networking, "Auth: tier locked for meeting (%{public}@)",
                     meetingStartTier ?? "nil")
    }

    /// Unlock the tier after a meeting ends. If the account tier changed during
    /// the meeting, the delegate is notified so the UI can update.
    /// Must be called on the main thread.
    @objc public func unlockTierFromMeeting() {
        assert(Thread.isMainThread, "unlockTierFromMeeting must be called on the main thread")
        guard meetingStartTier != nil else { return }
        let lockedTier = meetingStartTier
        meetingStartTier = nil
        interLogInfo(InterLog.networking, "Auth: tier unlocked from meeting (was %{public}@, now %{public}@)",
                     lockedTier ?? "nil", currentTier ?? "nil")
        if lockedTier != currentTier, let userId = currentUserId {
            authDelegate?.authSessionDidAuthenticate(userId: userId, tier: currentTier ?? "free")
        }
    }

    // MARK: - Billing: Post-Checkout Tier Verification

    /// Poll `/billing/status` until the user's tier changes from the `previousTier`,
    /// then trigger a token refresh to propagate the new tier into the JWT.
    ///
    /// Called after the macOS app returns from the LS checkout page via the
    /// `inter://billing/success` deep link. The LS webhook typically lands within
    /// 1-3 seconds — this retry loop handles the race between redirect and webhook.
    ///
    /// - Parameters:
    ///   - previousTier: The tier the user had before starting the checkout.
    ///   - maxAttempts: Maximum number of poll attempts (default 5).
    ///   - interval: Seconds between polls (default 2.0).
    ///   - completion: Called on main queue with the new tier (or nil if timed out).
    @objc public func refreshAndWaitForTierChange(
        previousTier: String,
        maxAttempts: Int = 5,
        interval: TimeInterval = 2.0,
        completion: @escaping (_ newTier: String?) -> Void
    ) {
        guard authServerBaseURL != nil else {
            interLogError(InterLog.networking, "Auth: tier poll skipped — no active session")
            completeOnMain { completion(nil) }
            return
        }

        // Step 1: Refresh the access token first — the user likely spent minutes
        // in the browser checkout, so the current token may be expired.
        // This also picks up the new tier if the webhook already landed.
        refreshAccessToken { [weak self] success in
            guard let self = self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            if !success {
                interLogError(InterLog.networking, "Auth: pre-poll token refresh failed")
                self.completeOnMain { completion(nil) }
                return
            }

            // Step 2: Check if the refresh already picked up the new tier
            if let currentTier = self.currentTier, currentTier != previousTier {
                interLogInfo(InterLog.networking,
                             "Auth: tier already changed after refresh (%{public}@ → %{public}@)",
                             previousTier, currentTier)
                self.completeOnMain { completion(currentTier) }
                return
            }

            // Step 3: Webhook hasn't landed yet — start polling /billing/status
            guard let serverURL = self.authServerBaseURL else {
                self.completeOnMain { completion(nil) }
                return
            }

            self.pollBillingStatus(
                serverURL: serverURL,
                previousTier: previousTier,
                attempt: 1,
                maxAttempts: maxAttempts,
                interval: interval,
                completion: completion
            )
        }
    }

    /// Recursive poll helper — calls `/billing/status`, compares tier, retries or finishes.
    private func pollBillingStatus(
        serverURL: String,
        previousTier: String,
        attempt: Int,
        maxAttempts: Int,
        interval: TimeInterval,
        completion: @escaping (_ newTier: String?) -> Void
    ) {
        // Read token fresh each attempt — it may have been refreshed between retries
        guard let accessToken = currentAccessToken else {
            completeOnMain { completion(nil) }
            return
        }

        fetchBillingStatus(serverURL: serverURL, accessToken: accessToken) { [weak self] tier in
            guard let self = self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // Tier changed — trigger a full token refresh so the new tier enters the JWT,
            // then report the confirmed tier from the refreshed access token.
            if let tier = tier, tier != previousTier {
                interLogInfo(InterLog.networking,
                             "Auth: billing status tier changed (%{public}@ → %{public}@) on attempt %d",
                             previousTier, tier, attempt)
                self.refreshAccessToken { [weak self] success in
                    let confirmedTier = success ? self?.currentTier : tier
                    DispatchQueue.main.async { completion(confirmedTier) }
                }
                return
            }

            // No change yet — retry if attempts remain
            if attempt < maxAttempts {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + interval
                ) { [weak self] in
                    self?.pollBillingStatus(
                        serverURL: serverURL,
                        previousTier: previousTier,
                        attempt: attempt + 1,
                        maxAttempts: maxAttempts,
                        interval: interval,
                        completion: completion
                    )
                }
            } else {
                // Exhausted all attempts — the webhook may still be in flight.
                // The proactive refresh timer will catch it within 15 minutes.
                interLogInfo(InterLog.networking,
                             "Auth: billing status poll exhausted %d attempts — tier still %{public}@",
                             maxAttempts, previousTier)
                self.completeOnMain { completion(nil) }
            }
        }
    }

    /// Fetch current tier + subscription status from `/billing/status`.
    /// Returns the tier string on success, nil on any error.
    private func fetchBillingStatus(
        serverURL: String,
        accessToken: String,
        completion: @escaping (_ tier: String?) -> Void
    ) {
        performAuthHTTPRequest(
            url: "\(serverURL)/billing/status",
            method: "GET",
            body: nil,
            bearerToken: accessToken,
            retryCount: 0
        ) { data, httpResponse, error in
            guard error == nil,
                  let httpResponse = httpResponse,
                  httpResponse.statusCode == 200,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tier = json["tier"] as? String else {
                completion(nil)
                return
            }
            completion(tier)
        }
    }

    /// Request a checkout URL from the server for the given variant ID.
    /// The server calls the LS API and returns a signed checkout URL.
    /// - Parameters:
    ///   - variantId: The LS variant ID (e.g. "1516868" for Pro).
    ///   - completion: Called on main queue with the checkout URL, or nil on failure.
    @objc public func requestCheckoutURL(
        variantId: String,
        completion: @escaping (_ url: String?) -> Void
    ) {
        guard let serverURL = authServerBaseURL,
              let accessToken = currentAccessToken else {
            interLogError(InterLog.networking, "Auth: checkout skipped — no active session")
            completeOnMain { completion(nil) }
            return
        }

        let body: [String: Any] = ["variantId": variantId]
        performAuthHTTPRequest(
            url: "\(serverURL)/billing/checkout",
            method: "POST",
            body: body,
            bearerToken: accessToken,
            retryCount: 0
        ) { [weak self] data, httpResponse, error in
            guard let self = self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            guard error == nil,
                  let httpResponse = httpResponse,
                  httpResponse.statusCode == 200,
                  let data = data,
                  let json = self.parseJSON(data),
                  let url = json["url"] as? String else {
                if let data = data, let json = self.parseJSON(data),
                   let errorMsg = json["error"] as? String {
                    interLogError(InterLog.networking, "Auth: checkout failed — %{public}@", errorMsg)
                } else {
                    interLogError(InterLog.networking, "Auth: checkout request failed (HTTP %d)",
                                  httpResponse?.statusCode ?? 0)
                }
                self.completeOnMain { completion(nil) }
                return
            }

            self.completeOnMain { completion(url) }
        }
    }

    /// Fetch the customer portal URL from the server.
    /// - Parameter completion: Called on main queue with the portal URL, or nil.
    @objc public func requestPortalURL(
        completion: @escaping (_ url: String?) -> Void
    ) {
        guard let serverURL = authServerBaseURL,
              let accessToken = currentAccessToken else {
            interLogError(InterLog.networking, "Auth: portal URL skipped — no active session")
            completeOnMain { completion(nil) }
            return
        }

        performAuthHTTPRequest(
            url: "\(serverURL)/billing/portal-url",
            method: "GET",
            body: nil,
            bearerToken: accessToken,
            retryCount: 0
        ) { [weak self] data, httpResponse, error in
            guard let self = self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            guard error == nil,
                  let httpResponse = httpResponse,
                  httpResponse.statusCode == 200,
                  let data = data,
                  let json = self.parseJSON(data),
                  let url = json["portalUrl"] as? String else {
                self.completeOnMain { completion(nil) }
                return
            }
            self.completeOnMain { completion(url) }
        }
    }

    /// Whether the user is authenticated.
    @objc public private(set) var isAuthenticated: Bool = false

    /// Base URL of the token server for auth operations.
    private var authServerBaseURL: String?

    /// Timer for proactive access token refresh.
    private var refreshTimer: Timer?

    /// Keychain service identifier for refresh token storage.
    private static let keychainService = "com.inter.app.refreshtoken"

    /// Keychain account identifier (single-user desktop app).
    private static let keychainAccount = "current-session"

    /// UserDefaults key for persisting the current user ID across launches.
    private static let userIdDefaultsKey = "InterCurrentAuthUserId"

    // MARK: - Init

    @objc public override init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 15.0
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)

        // Auth session with TLS certificate pinning delegate
        self.pinnedDelegate = InterPinnedSessionDelegate()
        let authConfig = URLSessionConfiguration.default
        authConfig.timeoutIntervalForRequest = 10.0
        authConfig.timeoutIntervalForResource = 15.0
        authConfig.waitsForConnectivity = false
        self.authSession = URLSession(configuration: authConfig,
                                      delegate: pinnedDelegate,
                                      delegateQueue: nil)
        super.init()
    }

    /// Initializer accepting an injected URLSession (for testing).
    init(session: URLSession) {
        self.session = session
        self.pinnedDelegate = InterPinnedSessionDelegate()
        self.authSession = session // In tests, bypass pinning
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

    // MARK: - Auth Public API

    /// Register a new account.
    ///
    /// Calls `POST /auth/register`. On success, stores refresh token in Keychain,
    /// caches access token in memory, and schedules proactive refresh.
    @objc public func register(email: String,
                               password: String,
                               displayName: String,
                               serverURL: String,
                               completion: @escaping (InterAuthResponse?, NSError?) -> Void) {
        let clientId = getHardwareUUID() ?? UUID().uuidString
        let body: [String: Any] = [
            "email": email,
            "password": password,
            "displayName": displayName,
            "clientId": clientId,
        ]

        interLogInfo(InterLog.networking, "Auth: registering (email=%{private}@)", email)

        performAuthHTTPRequest(url: "\(serverURL)/auth/register", method: "POST",
                               body: body, bearerToken: nil, retryCount: 0) { [weak self] data, httpResponse, error in
            guard let self = self else { return }

            if let error = error {
                self.completeOnMain { completion(nil, error) }
                return
            }

            guard let httpResponse = httpResponse, let data = data else {
                self.completeOnMain { completion(nil, InterNetworkErrorCode.authFailed.error(message: "No response")) }
                return
            }

            if httpResponse.statusCode == 201, let authResponse = self.parseAuthResponse(data, serverURL: serverURL) {
                interLogInfo(InterLog.networking, "Auth: registered successfully")
                self.completeOnMain {
                    self.authDelegate?.authSessionDidAuthenticate(userId: authResponse.userId, tier: authResponse.tier)
                    completion(authResponse, nil)
                }
            } else {
                let parsed = self.parseJSON(data)
                let message = parsed?["error"] as? String ?? "Registration failed (\(httpResponse.statusCode))"
                let nsError = InterNetworkErrorCode.authFailed.error(message: message)
                interLogError(InterLog.networking, "Auth: register failed (%{public}d)", httpResponse.statusCode)
                self.completeOnMain { completion(nil, nsError) }
            }
        }
    }

    /// Log in with existing credentials.
    ///
    /// Calls `POST /auth/login`. On success, stores refresh token in Keychain,
    /// caches access token in memory, and schedules proactive refresh.
    @objc public func login(email: String,
                            password: String,
                            serverURL: String,
                            completion: @escaping (InterAuthResponse?, NSError?) -> Void) {
        let clientId = getHardwareUUID() ?? UUID().uuidString
        let body: [String: Any] = [
            "email": email,
            "password": password,
            "clientId": clientId,
        ]

        interLogInfo(InterLog.networking, "Auth: logging in (email=%{private}@)", email)

        performAuthHTTPRequest(url: "\(serverURL)/auth/login", method: "POST",
                               body: body, bearerToken: nil, retryCount: 0) { [weak self] data, httpResponse, error in
            guard let self = self else { return }

            if let error = error {
                self.completeOnMain { completion(nil, error) }
                return
            }

            guard let httpResponse = httpResponse, let data = data else {
                self.completeOnMain { completion(nil, InterNetworkErrorCode.authFailed.error(message: "No response")) }
                return
            }

            if httpResponse.statusCode == 200, let authResponse = self.parseAuthResponse(data, serverURL: serverURL) {
                interLogInfo(InterLog.networking, "Auth: login successful")
                self.completeOnMain {
                    self.authDelegate?.authSessionDidAuthenticate(userId: authResponse.userId, tier: authResponse.tier)
                    completion(authResponse, nil)
                }
            } else {
                let parsed = self.parseJSON(data)
                let message = parsed?["error"] as? String ?? "Login failed (\(httpResponse.statusCode))"
                let nsError = InterNetworkErrorCode.authFailed.error(message: message)
                interLogError(InterLog.networking, "Auth: login failed (%{public}d)", httpResponse.statusCode)
                self.completeOnMain { completion(nil, nsError) }
            }
        }
    }

    /// Silently refresh the access token using the stored refresh token.
    ///
    /// Calls `POST /auth/refresh`. Rotates the refresh token in Keychain.
    /// On `SESSION_COMPROMISED`, clears all auth state and notifies delegate.
    @objc public func refreshAccessToken(completion: ((Bool) -> Void)?) {
        // Snapshot all shared state reads here, on whatever thread calls us (main for
        // the proactive timer; background for URLSession retry via performAuthenticatedRequest).
        // This avoids reading the properties from the URLSession callback thread below.
        let userId = currentUserId
        let serverURL = authServerBaseURL
        let refreshToken = loadRefreshToken()

        guard let userId = userId,
              let serverURL = serverURL,
              let refreshToken = refreshToken else {
            interLogError(InterLog.networking, "Auth: refresh skipped — no stored session")
            completeOnMain { completion?(false) }
            return
        }

        let clientId = getHardwareUUID() ?? UUID().uuidString
        let body: [String: Any] = [
            "refreshToken": refreshToken,
            "clientId": clientId,
        ]

        performAuthHTTPRequest(url: "\(serverURL)/auth/refresh", method: "POST",
                               body: body, bearerToken: nil, retryCount: 0) { [weak self] data, httpResponse, error in
            guard let self = self else {
                DispatchQueue.main.async { completion?(false) }
                return
            }

            if let error = error {
                interLogError(InterLog.networking, "Auth: refresh network error (%{public}@)", error.localizedDescription)
                self.completeOnMain { completion?(false) }
                return
            }

            guard let httpResponse = httpResponse, let data = data else {
                self.completeOnMain { completion?(false) }
                return
            }

            if httpResponse.statusCode == 200,
               let json = self.parseJSON(data),
               let newAccessToken = json["accessToken"] as? String,
               let newRefreshToken = json["refreshToken"] as? String,
               let expiresIn = json["expiresIn"] as? TimeInterval {

                // Derive new values from the JWT payload using only local variables —
                // no reads of shared properties on this background thread.
                let payload = self.extractJWTPayload(from: newAccessToken)
                let newEmail       = payload?["email"]       as? String
                let newDisplayName = payload?["displayName"] as? String
                let newTier        = payload?["tier"]        as? String

                // Store the new refresh token in Keychain (upsert — no delete-first window)
                // BEFORE touching any in-memory state. If the write fails the old Keychain
                // token is still intact; abort the rotation so the proactive timer or a
                // subsequent performAuthenticatedRequest retry can try again.
                guard self.storeRefreshToken(newRefreshToken) else {
                    interLogError(InterLog.networking,
                                  "Auth: Keychain rotation failed — aborting token rotation; existing session preserved")
                    self.completeOnMain { completion?(false) }
                    return
                }

                // Keychain write succeeded — commit remaining in-memory state on the main
                // thread, consistent with clearAuthState(). Both this dispatch and the
                // completeOnMain below are enqueued in order so state is committed before
                // the completion callback fires.
                let writeWork = { [weak self] in
                    guard let self = self else { return }
                    self.currentAccessToken = newAccessToken
                    if let v = newEmail       { self.currentEmail = v }
                    if let v = newDisplayName { self.currentDisplayName = v }
                    if let v = newTier        { self.currentTier = v }
                    self.isAuthenticated = true
                }
                if Thread.isMainThread { writeWork() } else { DispatchQueue.main.async(execute: writeWork) }

                self.scheduleProactiveRefresh(expiresIn: expiresIn)

                interLogInfo(InterLog.networking, "Auth: access token refreshed (TTL=%{public}ds)", Int(expiresIn))
                self.completeOnMain {
                    self.authDelegate?.authSessionDidAuthenticate(userId: userId, tier: self.currentTier ?? "free")
                    completion?(true)
                }
            } else {
                // Check error code for specific handling
                let json = self.parseJSON(data)
                let code = json?["code"] as? String

                if code == "SESSION_COMPROMISED" {
                    interLogError(InterLog.networking, "Auth: SESSION_COMPROMISED — forcing re-login")
                    self.clearAuthState()
                    self.completeOnMain {
                        self.authDelegate?.authSessionDidExpire()
                        completion?(false)
                    }
                } else if httpResponse.statusCode == 429 || httpResponse.statusCode >= 500 {
                    // Transient server errors — do NOT clear auth state.
                    // The proactive timer or next performAuthenticatedRequest retry will
                    // try again. Expiring the session here would force a needless re-login.
                    interLogError(InterLog.networking, "Auth: refresh transient failure (%{public}d) — will retry",
                                  httpResponse.statusCode)
                    self.completeOnMain { completion?(false) }
                } else {
                    interLogError(InterLog.networking, "Auth: refresh failed (%{public}d, code=%{public}@)",
                                  httpResponse.statusCode, code ?? "none")
                    self.clearAuthState()
                    self.completeOnMain {
                        self.authDelegate?.authSessionDidExpire()
                        completion?(false)
                    }
                }
            }
        }
    }

    /// Log out — revoke the current refresh token on the server and clear local state.
    ///
    /// Calls `POST /auth/logout`. Always clears local state even if the server call fails.
    @objc public func logout(completion: (() -> Void)?) {
        let refreshToken = loadRefreshToken()
        let serverURL = authServerBaseURL
        let accessToken = currentAccessToken

        // Clear local state immediately
        clearAuthState()

        guard let serverURL = serverURL, let accessToken = accessToken else {
            completeOnMain { completion?() }
            return
        }

        var body: [String: Any] = [:]
        if let refreshToken = refreshToken {
            body["refreshToken"] = refreshToken
        }

        performAuthHTTPRequest(url: "\(serverURL)/auth/logout", method: "POST",
                               body: body, bearerToken: accessToken, retryCount: 0) { [weak self] _, httpResponse, _ in
            if let statusCode = httpResponse?.statusCode, statusCode != 204 {
                interLogError(InterLog.networking, "Auth: logout server response %{public}d", statusCode)
            } else {
                interLogInfo(InterLog.networking, "Auth: logged out")
            }
            self?.completeOnMain { completion?() }
        }
    }

    /// Attempt to restore a previous session using the stored refresh token.
    ///
    /// Reads userId from UserDefaults and refresh token from Keychain.
    /// If both exist, calls `refreshAccessToken` to obtain a fresh access token.
    @objc public func attemptSessionRestore(serverURL: String, completion: @escaping (Bool) -> Void) {
        guard let userId = UserDefaults.standard.string(forKey: Self.userIdDefaultsKey),
              loadRefreshToken() != nil else {
            interLogInfo(InterLog.networking, "Auth: no stored session to restore")
            completeOnMain { completion(false) }
            return
        }

        self.currentUserId = userId
        self.authServerBaseURL = serverURL

        refreshAccessToken { [weak self] success in
            if !success {
                self?.clearAuthState()
            }
            self?.completeOnMain { completion(success) }
        }
    }

    /// Perform an HTTP request with the current access token.
    ///
    /// If the server returns 401 + `TOKEN_EXPIRED`, silently refreshes and retries once.
    /// If refresh fails, notifies delegate via `authSessionDidExpire()`.
    @objc public func performAuthenticatedRequest(_ request: URLRequest,
                                                  completion: @escaping (Data?, URLResponse?, NSError?) -> Void) {
        var authedRequest = request
        if let token = currentAccessToken {
            authedRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        authSession.dataTask(with: authedRequest) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                self.completeOnMain { completion(nil, response, error as NSError) }
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                self.completeOnMain { completion(data, response, nil) }
                return
            }

            // Check for TOKEN_EXPIRED → silent refresh + replay
            if httpResponse.statusCode == 401,
               let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = json["code"] as? String,
               code == "TOKEN_EXPIRED" {
                self.refreshAccessToken { [weak self] success in
                    guard let self = self else { return }
                    if success, let newToken = self.currentAccessToken {
                        var retried = request
                        retried.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                        self.authSession.dataTask(with: retried) { data, response, error in
                            self.completeOnMain { completion(data, response, error as NSError?) }
                        }.resume()
                    } else {
                        self.completeOnMain {
                            self.authDelegate?.authSessionDidExpire()
                            completion(nil, response, InterNetworkErrorCode.sessionExpired.error(
                                message: "Session expired. Please log in again."))
                        }
                    }
                }
            } else {
                self.completeOnMain { completion(data, response, nil) }
            }
        }.resume()
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

    // MARK: - Private: Auth HTTP

    /// Low-level HTTP request for auth operations. Returns raw data + response for caller interpretation.
    private func performAuthHTTPRequest(
        url urlString: String,
        method: String,
        body: [String: Any]?,
        bearerToken: String?,
        retryCount: Int,
        completion: @escaping (Data?, HTTPURLResponse?, NSError?) -> Void
    ) {
        guard let url = URL(string: urlString) else {
            completion(nil, nil, InterNetworkErrorCode.serverUnreachable.error(message: "Invalid URL: \(urlString)"))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = method

        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        if let token = bearerToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        authSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                let nsError = error as NSError
                if self.shouldRetry(statusCode: nil, nsError: nsError, retryCount: retryCount) {
                    self.performAuthHTTPRequest(url: urlString, method: method, body: body,
                                                bearerToken: bearerToken, retryCount: retryCount + 1,
                                                completion: completion)
                    return
                }
                completion(nil, nil, InterNetworkErrorCode.serverUnreachable.error(
                    message: "Server unreachable: \(nsError.localizedDescription)", underlyingError: nsError))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(nil, nil, InterNetworkErrorCode.authFailed.error(message: "No HTTP response"))
                return
            }

            completion(data, httpResponse, nil)
        }.resume()
    }

    // MARK: - Private: Auth Response Parsing

    /// Parse an auth login/register response and persist auth state.
    ///
    /// JSON parsing uses only local variables (thread-safe). All writes to shared
    /// auth properties are dispatched to the main thread, consistent with clearAuthState().
    /// Both this dispatch and the completeOnMain in the caller are enqueued from the same
    /// background URLSession thread in order, so state is committed before the completion
    /// callback fires.
    private func parseAuthResponse(_ data: Data, serverURL: String) -> InterAuthResponse? {
        guard let json = parseJSON(data),
              let user = json["user"] as? [String: Any],
              let userId = user["id"] as? String,
              let email = user["email"] as? String,
              let displayName = user["displayName"] as? String,
              let tier = user["tier"] as? String,
              let accessToken = json["accessToken"] as? String,
              let refreshToken = json["refreshToken"] as? String,
              let expiresIn = json["expiresIn"] as? TimeInterval else {
            return nil
        }

        // Store the refresh token in Keychain BEFORE committing any in-memory state.
        // Mirrors the guard in refreshAccessToken: if the write fails, return nil so the
        // caller (login/register) treats the response as a failure.
        guard storeRefreshToken(refreshToken) else {
            interLogError(InterLog.networking,
                          "Auth: Keychain write failed during login/register — aborting auth state commit")
            return nil
        }

        // Keychain write succeeded — commit remaining in-memory state on the main
        // thread, consistent with clearAuthState(). Both this dispatch and the
        // completeOnMain in the caller are enqueued from the same background URLSession
        // thread in order, so state is committed before the completion callback fires.
        let writeWork = { [weak self] in
            guard let self = self else { return }
            self.currentAccessToken = accessToken
            self.currentUserId = userId
            self.currentEmail = email
            self.currentDisplayName = displayName
            self.currentTier = tier
            self.authServerBaseURL = serverURL
            self.isAuthenticated = true
            UserDefaults.standard.set(userId, forKey: Self.userIdDefaultsKey)
        }
        if Thread.isMainThread { writeWork() } else { DispatchQueue.main.async(execute: writeWork) }

        scheduleProactiveRefresh(expiresIn: expiresIn)

        return InterAuthResponse(userId: userId, email: email, displayName: displayName,
                                 tier: tier, accessToken: accessToken,
                                 refreshToken: refreshToken, expiresIn: expiresIn)
    }

    /// Decode JWT payload to extract user claims.
    private func extractJWTPayload(from token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = String(parts[1])
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Private: Proactive Refresh

    /// Schedule a timer to refresh the access token before it expires.
    private func scheduleProactiveRefresh(expiresIn: TimeInterval) {
        let refreshAt = max(expiresIn - 75, 10) // 75 seconds before expiry, minimum 10s
        DispatchQueue.main.async { [weak self] in
            self?.refreshTimer?.invalidate()
            self?.refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshAt, repeats: false) { [weak self] _ in
                self?.refreshAccessToken { _ in }
            }
        }
    }

    // MARK: - Private: Auth State

    /// Clear all auth state — local memory, Keychain, UserDefaults.
    /// All mutations are dispatched to the main queue to avoid races with
    /// URLSession callbacks that call this from background threads.
    private func clearAuthState() {
        let work = { [weak self] in
            guard let self = self else { return }
            self.refreshTimer?.invalidate()
            self.refreshTimer = nil
            self.currentAccessToken = nil
            self.currentUserId = nil
            self.currentEmail = nil
            self.currentDisplayName = nil
            self.currentTier = nil
            self.meetingStartTier = nil
            self.authServerBaseURL = nil
            self.isAuthenticated = false
            self.deleteRefreshToken()
            UserDefaults.standard.removeObject(forKey: Self.userIdDefaultsKey)
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    // MARK: - Private: Hardware UUID

    /// macOS hardware UUID — stable across app reinstalls on the same machine.
    /// Used as `clientId` for device binding on refresh token operations.
    private func getHardwareUUID() -> String? {
        let port: mach_port_t
        if #available(macOS 12.0, *) {
            port = kIOMainPortDefault
        } else {
            port = kIOMasterPortDefault
        }
        let service = IOServiceGetMatchingService(port,
                          IOServiceMatching("IOPlatformExpertDevice"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let uuidProperty = IORegistryEntryCreateCFProperty(service,
                  "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return uuidProperty.takeRetainedValue() as? String
    }

    // MARK: - Private: Keychain

    /// Store refresh token in Keychain. Overwrites any existing value.
    @discardableResult
    private func storeRefreshToken(_ token: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }

        let lookupQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]

        // Try to update an existing item first; add only if absent.
        // This avoids a delete-then-add window where neither the old nor the
        // new token is present — a failed SecItemAdd after delete would
        // permanently end the session with no recovery path.
        let updateAttrs: [String: Any] = [
            kSecValueData as String:      data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemUpdate(lookupQuery as CFDictionary, updateAttrs as CFDictionary)

        if status == errSecItemNotFound {
            var addQuery = lookupQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        if status != errSecSuccess {
            interLogError(InterLog.networking,
                          "Keychain: storeRefreshToken failed (OSStatus=%{public}d)", status)
            return false
        }
        return true
    }

    /// Load refresh token from Keychain. Returns nil if not found.
    private func loadRefreshToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Delete refresh token from Keychain.
    private func deleteRefreshToken() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - TLS Certificate Pinning Delegate

/// URLSessionDelegate that pins the server's SubjectPublicKeyInfo (SPKI) SHA-256 hash.
///
/// Pin the PUBLIC KEY (not the certificate) so certificate renewals don't break pinning.
/// Supported key types: RSA-2048, RSA-4096, EC P-256, EC P-384.
///
/// Compute the SPKI SHA-256 fingerprint from a live endpoint:
///   openssl s_client -connect api.example.com:443 </dev/null 2>/dev/null \
///     | openssl x509 -noout -pubkey \
///     | openssl pkey -pubin -outform DER \
///     | openssl dgst -sha256 -binary | base64
///
/// Or from a certificate file:
///   openssl x509 -in cert.pem -pubkey -noout \
///     | openssl pkey -pubin -outform DER \
///     | openssl dgst -sha256 -binary | base64
///
/// In development (localhost/127.0.0.1), TLS challenges are handled with default
/// behavior since there is no TLS on plain `http://localhost`.
///
/// Rotation policy: add the new key hash to the set BEFORE deploying the new
/// certificate; remove the old hash after the rollover window closes (24–72 h).
/// Always keep at least one pre-generated backup pin. Never ship with an empty
/// set in production.
class InterPinnedSessionDelegate: NSObject, URLSessionDelegate {

    /// Set of accepted SPKI SHA-256 hashes (base64-encoded, SubjectPublicKeyInfo DER SHA-256).
    ///
    /// Populate before shipping to production. Compute each pin with:
    ///   openssl s_client -connect <host>:<port> </dev/null 2>/dev/null \
    ///     | openssl x509 -noout -pubkey \
    ///     | openssl pkey -pubin -outform DER \
    ///     | openssl dgst -sha256 -binary | base64
    ///
    /// Include a backup pin (pre-generated key pair, not yet deployed) so an
    /// emergency rotation never locks users out. Update this set and rotate the
    /// app before the signing certificate expires.
    ///
    /// Format: "<base64-sha256>", // <host> primary|backup (<key-type>, expires YYYY-MM)
    private let pinnedSPKIHashes: Set<String> = [
        // TODO: Populate with production server SPKI SHA-256 hashes before shipping.
        // Example (replace with values from the openssl pipeline above):
        // "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=", // api.example.com primary (EC-P256, expires 2027-03)
        // "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",   // api.example.com backup  (pre-generated, not yet deployed)
    ]

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // If no pins configured, allow default handling (development/CI mode only).
        // This branch must never execute in production — populate pinnedSPKIHashes above.
        if pinnedSPKIHashes.isEmpty {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Extract the leaf certificate's public key
        let cert: SecCertificate?
        if #available(macOS 12.0, *) {
            cert = (SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate])?.first
        } else {
            cert = SecTrustGetCertificateAtIndex(serverTrust, 0)
        }

        guard let leafCert = cert,
              let pubKey = SecCertificateCopyKey(leafCert) else {
            interLogError(InterLog.networking, "TLS: failed to extract server public key")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        guard let serverHash = spkiHash(for: pubKey) else {
            interLogError(InterLog.networking, "TLS: unsupported key type/size — connection rejected")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        if pinnedSPKIHashes.contains(serverHash) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            interLogError(InterLog.networking, "TLS: SPKI hash mismatch — connection rejected")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    // MARK: - Private: SPKI Hash

    /// Computes the SubjectPublicKeyInfo (SPKI) SHA-256 hash of `pubKey`, base64-encoded.
    ///
    /// Reconstructs the SubjectPublicKeyInfo DER by prepending the appropriate ASN.1
    /// algorithm-identifier header to the raw key bytes from `SecKeyCopyExternalRepresentation`,
    /// producing the same value as:
    ///   openssl pkey -pubin -outform DER | openssl dgst -sha256 -binary | base64
    ///
    /// Headers sourced from RFC 3279 §2.3 (RSA) and RFC 5480 §2 (EC).
    /// Assumes standard public exponent (e=65537) for RSA keys — all modern CA-issued
    /// certificates use this value. Returns nil for unsupported key types or sizes.
    private func spkiHash(for pubKey: SecKey) -> String? {
        guard let attrs = SecKeyCopyAttributes(pubKey) as? [String: Any],
              let keyType = attrs[kSecAttrKeyType as String] as? String,
              let keyBits = attrs[kSecAttrKeySizeInBits as String] as? Int,
              let rawKey = SecKeyCopyExternalRepresentation(pubKey, nil) as Data? else {
            return nil
        }

        // ASN.1 SubjectPublicKeyInfo algorithm-identifier headers.
        // Pre-pend to the raw external representation to form SubjectPublicKeyInfo DER,
        // matching the output of the openssl SPKI pipeline documented above.
        let header: [UInt8]
        if keyType == (kSecAttrKeyTypeRSA as String) {
            switch keyBits {
            case 2048:
                // SEQUENCE { SEQUENCE { OID rsaEncryption, NULL }, BIT STRING { rawKey } }
                header = [
                    0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09,
                    0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01,
                    0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00,
                ]
            case 4096:
                header = [
                    0x30, 0x82, 0x02, 0x22, 0x30, 0x0d, 0x06, 0x09,
                    0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01,
                    0x01, 0x05, 0x00, 0x03, 0x82, 0x02, 0x0f, 0x00,
                ]
            default:
                interLogError(InterLog.networking,
                              "TLS: unsupported RSA key size (%{public}d bits) — pinning rejected", keyBits)
                return nil
            }
        } else if keyType == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            switch keyBits {
            case 256:
                // SEQUENCE { SEQUENCE { OID ecPublicKey, OID prime256v1 }, BIT STRING { rawKey } }
                header = [
                    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86,
                    0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
                    0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
                    0x42, 0x00,
                ]
            case 384:
                // SEQUENCE { SEQUENCE { OID ecPublicKey, OID secp384r1 }, BIT STRING { rawKey } }
                header = [
                    0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86,
                    0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x05, 0x2b,
                    0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00,
                ]
            default:
                interLogError(InterLog.networking,
                              "TLS: unsupported EC key size (%{public}d bits) — pinning rejected", keyBits)
                return nil
            }
        } else {
            interLogError(InterLog.networking, "TLS: unsupported key algorithm for SPKI pinning")
            return nil
        }

        var spki = Data(header)
        spki.append(rawKey)
        return Data(SHA256.hash(data: spki)).base64EncodedString()
    }
}
