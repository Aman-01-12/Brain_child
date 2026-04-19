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

// MARK: - Session Restore Result

/// Tri-state result of session restore at launch — enables "signed in but offline" UX.
@objc public enum InterSessionRestoreResult: Int {
    /// Session fully restored — access token obtained, user is online and authenticated.
    case restored = 0
    /// Server was unreachable but local credentials (Keychain + UserDefaults) exist.
    /// The app should show the user as "signed in (offline)" with cached profile data.
    /// A background retry timer will silently restore the full session when the server
    /// becomes reachable.
    case offlineWithPersistedSession = 1
    /// No stored credentials exist — the user has never signed in or has explicitly
    /// signed out. Show the unauthenticated (Sign In / Sign Up) UI.
    case noSession = 2
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

// MARK: - Circuit Breaker (T9)

/// Three-state circuit breaker with exponential backoff for network resilience.
///
/// States:
///   CLOSED    → Normal operation. All requests go through.
///   OPEN      → Server unreachable. Requests fail immediately with cached error.
///   HALF_OPEN → Probe state. One request allowed through to test recovery.
///
/// Backoff schedule (with ±500ms jitter):
///   After 1st failure:  2s → 2nd: 4s → 3rd: 8s → 4th+: 16s (capped)
private class InterCircuitBreaker {

    enum State {
        case closed
        case open
        case halfOpen
    }

    /// Serial queue protecting mutable state.
    private let queue = DispatchQueue(label: "inter.circuitBreaker")

    /// Current circuit state.
    private(set) var state: State = .closed

    /// Consecutive failure count.
    private var failureCount = 0

    /// Number of consecutive failures required to trip the circuit.
    private let failureThreshold: Int

    /// Timer that transitions from OPEN → HALF_OPEN after backoff delay.
    private var recoveryTimer: DispatchSourceTimer?

    /// Backoff base in seconds.
    private let baseBackoff: TimeInterval = 2.0

    /// Maximum backoff cap in seconds.
    private let maxBackoff: TimeInterval = 16.0

    /// Called (off the main queue) when the circuit transitions to half-open.
    /// The owner can use this to trigger an immediate retry probe.
    var onHalfOpen: (() -> Void)?

    init(failureThreshold: Int = 3) {
        self.failureThreshold = failureThreshold
    }

    /// Check whether a request should proceed.
    /// Returns `true` if the request is allowed, `false` if the circuit is OPEN.
    func shouldAllow() -> Bool {
        return queue.sync {
            switch state {
            case .closed:
                return true
            case .halfOpen:
                // Allow one probe request through
                return true
            case .open:
                return false
            }
        }
    }

    /// Record a successful request. Resets the circuit to CLOSED.
    func recordSuccess() {
        queue.sync {
            failureCount = 0
            state = .closed
            recoveryTimer?.cancel()
            recoveryTimer = nil
        }
    }

    /// Record a failed request. If threshold is reached, trips the circuit.
    func recordFailure() {
        queue.sync {
            failureCount += 1

            if state == .halfOpen {
                // Probe failed — re-open with increased backoff
                state = .open
                scheduleRecoveryProbe()
                return
            }

            if failureCount >= failureThreshold {
                state = .open
                scheduleRecoveryProbe()
            }
        }
    }

    /// Reset the breaker (e.g., on logout or explicit user retry).
    func reset() {
        queue.sync {
            failureCount = 0
            state = .closed
            recoveryTimer?.cancel()
            recoveryTimer = nil
        }
    }

    /// Whether the circuit is currently open (failing fast).
    var isOpen: Bool {
        return queue.sync { state == .open }
    }

    // Must be called while holding `queue`.
    private func scheduleRecoveryProbe() {
        recoveryTimer?.cancel()

        // Exponential backoff: 2s, 4s, 8s, 16s (capped)
        let attempt = failureCount - failureThreshold + 1
        let delay = min(baseBackoff * pow(2.0, Double(max(0, attempt - 1))), maxBackoff)
        // Jitter: ±500ms
        let jitter = Double.random(in: -0.5...0.5)
        let actualDelay = max(0.5, delay + jitter)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + actualDelay)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            // Transition to half-open — next request will be a probe
            self.state = .halfOpen
            interLogInfo(InterLog.networking, "CircuitBreaker: half-open probe after %{public}.1fs", actualDelay)
            self.onHalfOpen?()
        }
        timer.resume()
        recoveryTimer = timer

        interLogInfo(InterLog.networking, "CircuitBreaker: OPEN — recovery probe in %{public}.1fs (failures=%{public}d)",
                     actualDelay, failureCount)
    }
}

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

    /// Circuit breaker for auth network calls (T9).
    /// Trips after 3 consecutive failures, probes with exponential backoff.
    private let circuitBreaker = InterCircuitBreaker(failureThreshold: 3)

    // MARK: - Task Tracking (T8)

    /// In-flight URLSessionDataTasks tracked for lifecycle cleanup.
    /// Protected by `inflightLock`.
    private var inflightTasks = Set<URLSessionDataTask>()

    /// Lock protecting the inflight task set.
    private let inflightLock = NSLock()

    /// Track a task before resuming it. Must be paired with `untrackTask` in the completion handler.
    private func trackTask(_ task: URLSessionDataTask) {
        inflightLock.lock()
        inflightTasks.insert(task)
        inflightLock.unlock()
    }

    /// Remove a task from tracking after its completion handler fires.
    private func untrackTask(_ task: URLSessionDataTask) {
        inflightLock.lock()
        inflightTasks.remove(task)
        inflightLock.unlock()
    }

    /// Cancel all in-flight network requests. Called from `clearAuthState()` and `deinit`.
    @objc public func cancelPendingRequests() {
        inflightLock.lock()
        let tasks = inflightTasks
        inflightTasks.removeAll()
        inflightLock.unlock()
        tasks.forEach { $0.cancel() }
    }

    deinit {
        cancelPendingRequests()
        refreshTimer?.invalidate()
        sessionRetryTimer?.invalidate()
    }

    // MARK: - Refresh Coalescing (T7)

    /// Whether a token refresh HTTP request is currently in-flight.
    /// Protected by `refreshCoalesceQueue`.
    private var isRefreshInFlight = false

    /// Queued completion handlers waiting for the in-flight refresh to finish.
    /// Protected by `refreshCoalesceQueue`.
    private var pendingRefreshCompletions: [(RefreshOutcome) -> Void] = []

    /// Serial queue protecting refresh coalescing state.
    private let refreshCoalesceQueue = DispatchQueue(label: "inter.tokenService.refreshCoalesce")

    /// Deliver the refresh outcome to the original caller and all queued waiters,
    /// then reset the in-flight flag so the next refresh can proceed.
    private func drainRefreshCompletions(outcome: RefreshOutcome, originalCompletion: @escaping (RefreshOutcome) -> Void) {
        let waiters: [(RefreshOutcome) -> Void] = refreshCoalesceQueue.sync {
            let queued = pendingRefreshCompletions
            pendingRefreshCompletions.removeAll()
            isRefreshInFlight = false
            return queued
        }
        completeOnMain {
            originalCompletion(outcome)
            for waiter in waiters {
                waiter(outcome)
            }
        }
    }

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

    // MARK: - Tier Validation

    private static let knownTiers: Set<String> = ["free", "pro", "pro+"]

    /// Returns a validated tier string, or `nil` if the input is empty or unrecognised.
    private func validatedTier(_ raw: String?) -> String? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        let lowered = raw.lowercased()
        if Self.knownTiers.contains(lowered) {
            return lowered
        }
        interLogError(InterLog.networking, "Auth: unknown tier value '%{public}@' — ignoring", raw)
        return nil
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
            // Fall back to the poll-detected tier if JWT extraction fails for any reason.
            if let tier = tier, tier != previousTier {
                interLogInfo(InterLog.networking,
                             "Auth: billing status tier changed (%{public}@ → %{public}@) on attempt %d",
                             previousTier, tier, attempt)
                self.refreshAccessToken { [weak self] success in
                    let confirmedTier = self?.currentTier ?? tier
                    DispatchQueue.main.async { completion(confirmedTier) }
                }
                return
            }

            // No change yet — retry if attempts remain
            if attempt < maxAttempts {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + interval
                ) { [weak self] in
                    guard let self = self else {
                        DispatchQueue.main.async { completion(nil) }
                        return
                    }
                    self.pollBillingStatus(
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

    /// Request a billing plans page URL from the server.
    /// The server issues a short-lived JWT and returns a URL pointing to the hosted
    /// pricing page. The caller opens this URL in the default browser.
    /// - Parameter completion: Called on main queue with the plans page URL, or nil on failure.
    @objc public func requestBillingPageURL(
        completion: @escaping (_ url: String?) -> Void
    ) {
        guard let serverURL = authServerBaseURL,
              let accessToken = currentAccessToken else {
            interLogError(InterLog.networking, "Auth: billing page skipped — no active session")
            completeOnMain { completion(nil) }
            return
        }

        performAuthHTTPRequest(
            url: "\(serverURL)/billing/plans-token",
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
                  let url = json["url"] as? String else {
                if let data = data, let json = self.parseJSON(data),
                   let errorMsg = json["error"] as? String {
                    interLogError(InterLog.networking, "Auth: billing page failed — %{public}@", errorMsg)
                } else {
                    interLogError(InterLog.networking, "Auth: billing page request failed (HTTP %d)",
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
                if let data = data, let json = self.parseJSON(data),
                   let errorMsg = json["error"] as? String {
                    interLogError(InterLog.networking, "Auth: portal URL failed — %{public}@", errorMsg)
                } else {
                    interLogError(InterLog.networking, "Auth: portal URL request failed (HTTP %d)",
                                  httpResponse?.statusCode ?? 0)
                }
                self.completeOnMain { completion(nil) }
                return
            }
            self.completeOnMain { completion(url) }
        }
    }

    /// Whether the user is authenticated.
    @objc public private(set) var isAuthenticated: Bool = false

    // MARK: - Public URL Resolution (no auth required)

    /// Ask the server for the public (unauthenticated) billing plans page URL.
    /// The server owns the canonical URL — the app never constructs it.
    @objc public func requestPublicPlansURL(
        completion: @escaping (_ url: String?) -> Void
    ) {
        guard let serverURL = authServerBaseURL else {
            interLogError(InterLog.networking, "Public plans URL skipped — no server URL")
            completeOnMain { completion(nil) }
            return
        }

        performAuthHTTPRequest(
            url: "\(serverURL)/billing/public-plans-url",
            method: "GET",
            body: nil,
            bearerToken: nil,
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
                interLogError(InterLog.networking, "Public plans URL request failed (HTTP %d)",
                              httpResponse?.statusCode ?? 0)
                self.completeOnMain { completion(nil) }
                return
            }
            self.completeOnMain { completion(url) }
        }
    }

    /// Ask the server for the OAuth start URL for the given provider.
    /// The server owns the canonical URL — the app never constructs it.
    @objc public func requestOAuthStartURL(
        provider: String,
        completion: @escaping (_ url: String?) -> Void
    ) {
        guard let serverURL = authServerBaseURL else {
            interLogError(InterLog.networking, "OAuth start URL skipped — no server URL")
            completeOnMain { completion(nil) }
            return
        }

        guard let encodedProvider = provider.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            completeOnMain { completion(nil) }
            return
        }

        performAuthHTTPRequest(
            url: "\(serverURL)/auth/oauth/start-url?provider=\(encodedProvider)",
            method: "GET",
            body: nil,
            bearerToken: nil,
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
                interLogError(InterLog.networking, "OAuth start URL request failed (HTTP %d)",
                              httpResponse?.statusCode ?? 0)
                self.completeOnMain { completion(nil) }
                return
            }
            self.completeOnMain { completion(url) }
        }
    }

    /// Base URL of the token server for auth operations.
    private var authServerBaseURL: String?

    /// Public read-only accessor for the current auth server base URL (ObjC-accessible).
    @objc public var serverURL: String? { authServerBaseURL }

    /// Timer for proactive access token refresh.
    private var refreshTimer: Timer?

    /// Keychain service identifier for refresh token storage.
    private static let keychainService = "com.inter.app.refreshtoken"

    /// Keychain account identifier (single-user desktop app).
    private static let keychainAccount = "current-session"

    /// UserDefaults key for persisting the current user ID across launches.
    private static let userIdDefaultsKey = "InterCurrentAuthUserId"

    /// UserDefaults keys for caching user profile across launches (offline mode).
    private static let emailDefaultsKey       = "InterCurrentAuthEmail"
    private static let displayNameDefaultsKey = "InterCurrentAuthDisplayName"
    private static let tierDefaultsKey        = "InterCurrentAuthTier"

    /// Timer for retrying session restore when server was unreachable at launch.
    private var sessionRetryTimer: Timer?

    // MARK: - Init

    @objc public override init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 15.0
        config.waitsForConnectivity = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)

        // Auth session with TLS certificate pinning delegate
        self.pinnedDelegate = InterPinnedSessionDelegate()
        let authConfig = URLSessionConfiguration.default
        authConfig.timeoutIntervalForRequest = 10.0
        authConfig.timeoutIntervalForResource = 15.0
        authConfig.waitsForConnectivity = false
        authConfig.urlCache = nil
        authConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.authSession = URLSession(configuration: authConfig,
                                      delegate: pinnedDelegate,
                                      delegateQueue: nil)
        super.init()

        // When the circuit breaker enters half-open, kick the session retry
        // immediately so the probe window isn't wasted waiting on the timer.
        circuitBreaker.onHalfOpen = { [weak self] in
            DispatchQueue.main.async {
                self?.fireImmediateSessionRetryProbe()
            }
        }
    }

    /// Initializer accepting an injected URLSession (for testing).
    init(session: URLSession) {
        self.session = session
        self.pinnedDelegate = InterPinnedSessionDelegate()
        self.authSession = session // In tests, bypass pinning
        super.init()

        circuitBreaker.onHalfOpen = { [weak self] in
            DispatchQueue.main.async {
                self?.fireImmediateSessionRetryProbe()
            }
        }
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
            retryCount: 0,
            idempotencyKey: UUID().uuidString
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

    /// Exchange an OAuth handoff code for auth tokens.
    ///
    /// Called after `ASWebAuthenticationSession` completes. The one-time code
    /// was issued by the server's OAuth callback and is redeemed at
    /// `POST /auth/oauth/exchange`. The response format matches login/register.
    @objc public func exchangeOAuthCode(_ code: String,
                                        completion: @escaping (Bool, NSError?) -> Void) {
        let baseURL = authServerBaseURL
            ?? UserDefaults.standard.string(forKey: "InterDefaultTokenServerURL")
            ?? "http://localhost:3000"

        let body: [String: Any] = ["code": code]

        interLogInfo(InterLog.networking, "Auth: exchanging OAuth handoff code")

        performAuthHTTPRequest(url: "\(baseURL)/auth/oauth/exchange", method: "POST",
                               body: body, bearerToken: nil, retryCount: 0) { [weak self] data, httpResponse, error in
            guard let self = self else { return }

            if let error = error {
                self.completeOnMain { completion(false, error) }
                return
            }

            guard let httpResponse = httpResponse, let data = data else {
                self.completeOnMain {
                    completion(false, InterNetworkErrorCode.authFailed.error(message: "No response"))
                }
                return
            }

            if httpResponse.statusCode == 200, let authResponse = self.parseAuthResponse(data, serverURL: baseURL) {
                interLogInfo(InterLog.networking, "Auth: OAuth exchange successful")
                self.completeOnMain {
                    self.authDelegate?.authSessionDidAuthenticate(userId: authResponse.userId, tier: authResponse.tier)
                    completion(true, nil)
                }
            } else {
                let parsed = self.parseJSON(data)
                let message = parsed?["error"] as? String ?? "OAuth exchange failed (\(httpResponse.statusCode))"
                let nsError = InterNetworkErrorCode.authFailed.error(message: message)
                interLogError(InterLog.networking, "Auth: OAuth exchange failed (%{public}d)", httpResponse.statusCode)
                self.completeOnMain { completion(false, nsError) }
            }
        }
    }

    /// Outcome of a token refresh attempt.
    /// Internal-only — external callers use the `Bool` overload.
    private enum RefreshOutcome {
        /// Token refreshed successfully.
        case success
        /// Server was unreachable or returned a transient error (5xx, 429, timeout).
        /// The local session (Keychain + UserDefaults) is still intact and valid.
        case networkError
        /// The server definitively rejected the refresh token (expired, revoked,
        /// compromised). Local auth state has already been cleared.
        case invalidSession
    }

    /// Silently refresh the access token using the stored refresh token.
    ///
    /// Calls `POST /auth/refresh`. Rotates the refresh token in Keychain.
    /// On `SESSION_COMPROMISED`, clears all auth state and notifies delegate.
    @objc public func refreshAccessToken(completion: ((Bool) -> Void)?) {
        refreshAccessTokenWithOutcome { outcome in
            completion?(outcome == .success)
        }
    }

    /// Internal refresh that reports the full outcome — used by `attemptSessionRestore`
    /// to distinguish "server unreachable" from "session invalid".
    ///
    /// **Coalescing (T7):** If a refresh is already in-flight, the completion is
    /// queued and will be called with the in-flight request's outcome. This prevents
    /// concurrent 401 handlers from spawning multiple refresh calls (which would
    /// present an already-rotated refresh token → SESSION_COMPROMISED).
    private func refreshAccessTokenWithOutcome(completion: @escaping (RefreshOutcome) -> Void) {
        // Coalesce: if a refresh is already in-flight, queue this completion.
        let shouldStart: Bool = refreshCoalesceQueue.sync {
            if isRefreshInFlight {
                pendingRefreshCompletions.append(completion)
                return false
            }
            isRefreshInFlight = true
            return true
        }

        guard shouldStart else {
            interLogInfo(InterLog.networking, "Auth: refresh coalesced — waiting for in-flight request")
            return
        }
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
            drainRefreshCompletions(outcome: .invalidSession, originalCompletion: completion)
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
                DispatchQueue.main.async { completion(.networkError) }
                return
            }

            if let error = error {
                interLogError(InterLog.networking, "Auth: refresh network error (%{public}@)", error.localizedDescription)
                self.drainRefreshCompletions(outcome: .networkError, originalCompletion: completion)
                return
            }

            guard let httpResponse = httpResponse, let data = data else {
                self.drainRefreshCompletions(outcome: .networkError, originalCompletion: completion)
                return
            }

            if httpResponse.statusCode == 200,
               let json = self.parseJSON(data),
               let newAccessToken = json["accessToken"] as? String,
               let newRefreshToken = json["refreshToken"] as? String,
               let expiresIn = json["expiresIn"] as? TimeInterval {

                // Derive new values from the JWT payload using only local variables —
                // no reads of shared properties on this background thread.
                // Prefer the plain-text tier from the response body (added Phase C-UX)
                // over JWT extraction — eliminates any base64url/encoding edge cases.
                let payload = self.extractJWTPayload(from: newAccessToken)
                if payload == nil {
                    interLogError(InterLog.networking, "Auth: JWT payload extraction failed — using response body fields")
                }
                let newEmail       = payload?["email"]       as? String
                let newDisplayName = payload?["displayName"] as? String
                let newTier        = self.validatedTier((json["tier"] as? String) ?? (payload?["tier"] as? String))

                // Store the new refresh token in Keychain (upsert — no delete-first window)
                // BEFORE touching any in-memory state. If the write fails the old Keychain
                // token is still intact; abort the rotation so the proactive timer or a
                // subsequent performAuthenticatedRequest retry can try again.
                guard self.storeRefreshToken(newRefreshToken) else {
                    interLogError(InterLog.networking,
                                  "Auth: Keychain rotation failed — aborting token rotation; existing session preserved")
                    self.drainRefreshCompletions(outcome: .networkError, originalCompletion: completion)
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
                    // Update cached profile in UserDefaults for offline mode
                    if let v = newEmail       { UserDefaults.standard.set(v, forKey: Self.emailDefaultsKey) }
                    if let v = newDisplayName { UserDefaults.standard.set(v, forKey: Self.displayNameDefaultsKey) }
                    if let v = newTier        { UserDefaults.standard.set(v, forKey: Self.tierDefaultsKey) }
                }
                if Thread.isMainThread { writeWork() } else { DispatchQueue.main.async(execute: writeWork) }

                self.scheduleProactiveRefresh(expiresIn: expiresIn)

                interLogInfo(InterLog.networking, "Auth: access token refreshed (TTL=%{public}ds)", Int(expiresIn))
                // Notify delegate first, then drain all queued completions.
                self.completeOnMain {
                    self.authDelegate?.authSessionDidAuthenticate(userId: userId, tier: self.currentTier ?? "free")
                }
                self.drainRefreshCompletions(outcome: .success, originalCompletion: completion)
            } else {
                // Check error code for specific handling
                let json = self.parseJSON(data)
                let code = json?["code"] as? String

                if code == "SESSION_COMPROMISED" {
                    interLogError(InterLog.networking, "Auth: SESSION_COMPROMISED — forcing re-login")
                    self.clearAuthState()
                    self.completeOnMain {
                        self.authDelegate?.authSessionDidExpire()
                    }
                    self.drainRefreshCompletions(outcome: .invalidSession, originalCompletion: completion)
                } else if httpResponse.statusCode == 429 || httpResponse.statusCode >= 500 {
                    // Transient server errors — do NOT clear auth state.
                    // The proactive timer or next performAuthenticatedRequest retry will
                    // try again. Expiring the session here would force a needless re-login.
                    interLogError(InterLog.networking, "Auth: refresh transient failure (%{public}d) — will retry",
                                  httpResponse.statusCode)
                    self.drainRefreshCompletions(outcome: .networkError, originalCompletion: completion)
                } else {
                    interLogError(InterLog.networking, "Auth: refresh failed (%{public}d, code=%{public}@)",
                                  httpResponse.statusCode, code ?? "none")
                    self.clearAuthState()
                    self.completeOnMain {
                        self.authDelegate?.authSessionDidExpire()
                    }
                    self.drainRefreshCompletions(outcome: .invalidSession, originalCompletion: completion)
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
    ///
    /// **Network resilience (Zoom-style)**: If the server is unreachable at launch,
    /// the local session is preserved and the user is shown as "signed in (offline)"
    /// using cached profile data from UserDefaults. A background retry timer
    /// silently attempts to restore the full session every 15 seconds, and on
    /// success notifies the delegate so the UI updates seamlessly.
    ///
    /// - Returns: `.restored` on full restore, `.offlineWithPersistedSession` when
    ///   credentials exist but the server is unreachable, `.noSession` when no
    ///   stored credentials exist.
    @objc public func attemptSessionRestore(serverURL: String,
                                            completion: @escaping (InterSessionRestoreResult) -> Void) {
        // Always store the server URL so billing/plans and other public
        // endpoints are reachable even when no session exists.
        self.authServerBaseURL = serverURL

        guard let userId = UserDefaults.standard.string(forKey: Self.userIdDefaultsKey),
              loadRefreshToken() != nil else {
            interLogInfo(InterLog.networking, "Auth: no stored session to restore")
            completeOnMain { completion(.noSession) }
            return
        }

        self.currentUserId = userId

        refreshAccessTokenWithOutcome { [weak self] outcome in
            guard let self = self else { return }
            switch outcome {
            case .success:
                self.completeOnMain { completion(.restored) }

            case .networkError:
                // Server unreachable — populate in-memory profile from cached UserDefaults
                // so the UI can display the user's identity in offline mode.
                let cachedEmail       = UserDefaults.standard.string(forKey: Self.emailDefaultsKey)
                let cachedDisplayName = UserDefaults.standard.string(forKey: Self.displayNameDefaultsKey)
                let cachedTier        = UserDefaults.standard.string(forKey: Self.tierDefaultsKey)

                let loadCachedWork = {
                    self.currentEmail       = cachedEmail
                    self.currentDisplayName = cachedDisplayName
                    self.currentTier        = cachedTier
                    // isAuthenticated stays false — no valid access token exists.
                    // The UI checks hasPersistedSession to distinguish offline vs signed-out.
                }
                if Thread.isMainThread { loadCachedWork() } else { DispatchQueue.main.async(execute: loadCachedWork) }

                interLogInfo(InterLog.networking,
                             "Auth: session restore failed (server unreachable) — entering offline mode with cached profile")
                self.scheduleSessionRetry()
                self.completeOnMain { completion(.offlineWithPersistedSession) }

            case .invalidSession:
                // Server definitively rejected the token — clearAuthState() was already
                // called inside refreshAccessTokenWithOutcome. Nothing more to do.
                interLogInfo(InterLog.networking,
                             "Auth: session restore failed (invalid session) — local credentials cleared")
                self.completeOnMain { completion(.noSession) }
            }
        }
    }

    /// Whether a persisted session exists in Keychain + UserDefaults, even if
    /// the server is currently unreachable. Used by the UI to distinguish
    /// "signed in but offline" from "not signed in".
    @objc public var hasPersistedSession: Bool {
        return UserDefaults.standard.string(forKey: Self.userIdDefaultsKey) != nil
            && loadRefreshToken() != nil
    }

    // MARK: - Private: Session Retry Timer

    /// Consecutive retry attempt count for exponential backoff (T9).
    private var sessionRetryAttempt = 0

    /// Schedule a background timer that attempts to restore the session
    /// when the server becomes reachable. Uses exponential backoff (T9):
    /// 2s → 4s → 8s → 10s (capped) with ±0.5s jitter.
    /// The circuit breaker's `onHalfOpen` callback also triggers immediate
    /// probes, so the timer acts as a fallback rather than the primary driver.
    private func scheduleSessionRetry() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.sessionRetryTimer?.invalidate()
            self.sessionRetryAttempt = 0
            self.scheduleNextSessionRetryTick()
        }
    }

    /// Schedule one retry tick with backoff delay. Must be called on main thread.
    private func scheduleNextSessionRetryTick() {
        let attempt = sessionRetryAttempt
        let delay = min(2.0 * pow(2.0, Double(attempt)), 10.0)
        let jitter = Double.random(in: -0.5...0.5)
        let actualDelay = max(1.0, delay + jitter)

        sessionRetryTimer = Timer.scheduledTimer(withTimeInterval: actualDelay,
                                                  repeats: false) { [weak self] _ in
            self?.executeSessionRetryProbe(label: "timer", attempt: attempt + 1)
        }
    }

    /// Called by the circuit breaker's `onHalfOpen` callback to trigger an
    /// immediate session retry without waiting for the backoff timer.
    /// Must be called on main thread.
    private func fireImmediateSessionRetryProbe() {
        guard sessionRetryTimer != nil else { return }     // Only if we're in retry mode
        guard !isAuthenticated else { return }
        sessionRetryTimer?.invalidate()
        executeSessionRetryProbe(label: "circuit-breaker probe", attempt: sessionRetryAttempt + 1)
    }

    /// Shared retry logic used by both the timer tick and the circuit-breaker probe.
    /// Must be called on main thread.
    private func executeSessionRetryProbe(label: String, attempt: Int) {
        guard !self.isAuthenticated else {
            self.sessionRetryTimer?.invalidate()
            self.sessionRetryTimer = nil
            return
        }
        interLogInfo(InterLog.networking, "Auth: session retry attempt %{public}d (%{public}@)…",
                     attempt, label)
        self.refreshAccessTokenWithOutcome { [weak self] outcome in
            guard let self = self else { return }
            if outcome == .success {
                interLogInfo(InterLog.networking, "Auth: session retry succeeded — online mode restored")
                DispatchQueue.main.async {
                    self.sessionRetryTimer?.invalidate()
                    self.sessionRetryTimer = nil
                    self.sessionRetryAttempt = 0
                }
            } else if outcome == .invalidSession {
                interLogInfo(InterLog.networking, "Auth: session retry — session invalid, stopping retries")
                DispatchQueue.main.async {
                    self.sessionRetryTimer?.invalidate()
                    self.sessionRetryTimer = nil
                }
            } else {
                // .networkError — schedule next retry with increased backoff
                DispatchQueue.main.async {
                    self.sessionRetryAttempt += 1
                    self.scheduleNextSessionRetryTick()
                }
            }
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

        var outerTaskRef: URLSessionDataTask?
        let outerTask = authSession.dataTask(with: authedRequest) { [weak self] data, response, error in
            guard let self = self else { return }
            if let t = outerTaskRef { self.untrackTask(t) }

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
                        var retryTaskRef: URLSessionDataTask?
                        let retryTask = self.authSession.dataTask(with: retried) { [weak self] data, response, error in
                            if let t = retryTaskRef { self?.untrackTask(t) }
                            self?.completeOnMain { completion(data, response, error as NSError?) }
                        }
                        retryTaskRef = retryTask
                        self.trackTask(retryTask)
                        retryTask.resume()
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
        }

        outerTaskRef = outerTask
        trackTask(outerTask)
        outerTask.resume()
    }

    // MARK: - Phase 11: Scheduling

    /// Fetch upcoming scheduled meetings for the authenticated user.
    @objc public func fetchUpcomingMeetings(
        completion: @escaping (_ hosted: [[String: Any]]?, _ invited: [[String: Any]]?, _ error: NSError?) -> Void
    ) {
        guard let serverURL = authServerBaseURL,
              let accessToken = currentAccessToken else {
            completeOnMain { completion(nil, nil, nil) }
            return
        }

        performAuthHTTPRequest(
            url: "\(serverURL)/meetings/upcoming",
            method: "GET",
            body: nil,
            bearerToken: accessToken,
            retryCount: 0
        ) { [weak self] data, httpResponse, error in
            guard let self = self else { return }
            guard error == nil,
                  let data = data,
                  let httpResponse = httpResponse,
                  httpResponse.statusCode == 200,
                  let json = self.parseJSON(data) else {
                self.completeOnMain { completion(nil, nil, error) }
                return
            }
            let hosted  = json["hosted"]  as? [[String: Any]]
            let invited = json["invited"] as? [[String: Any]]
            self.completeOnMain { completion(hosted, invited, nil) }
        }
    }

    /// Schedule a new meeting.
    @objc public func scheduleMeeting(
        title: String,
        description: String?,
        scheduledAt: Date,
        durationMinutes: Int,
        roomType: String,
        hostTimezone: String,
        password: String?,
        lobbyEnabled: Bool,
        completion: @escaping (_ meeting: [String: Any]?, _ error: NSError?) -> Void
    ) {
        guard let serverURL = authServerBaseURL,
              let accessToken = currentAccessToken else {
            completeOnMain { completion(nil, nil) }
            return
        }

        let formatter = ISO8601DateFormatter()
        var body: [String: Any] = [
            "title": title,
            "scheduledAt": formatter.string(from: scheduledAt),
            "durationMinutes": durationMinutes,
            "roomType": roomType,
            "hostTimezone": hostTimezone,
            "lobbyEnabled": lobbyEnabled,
        ]
        if let desc = description { body["description"] = desc }
        if let pw = password { body["password"] = pw }

        performAuthHTTPRequest(
            url: "\(serverURL)/meetings/schedule",
            method: "POST",
            body: body,
            bearerToken: accessToken,
            retryCount: 0,
            idempotencyKey: UUID().uuidString
        ) { [weak self] data, httpResponse, error in
            guard let self = self else { return }
            guard error == nil,
                  let data = data,
                  let httpResponse = httpResponse,
                  httpResponse.statusCode == 201,
                  let json = self.parseJSON(data) else {
                self.completeOnMain { completion(nil, error) }
                return
            }
            self.completeOnMain { completion(json, nil) }
        }
    }

    /// Cancel a scheduled meeting.
    @objc public func cancelMeeting(
        meetingId: String,
        completion: @escaping (_ success: Bool, _ error: NSError?) -> Void
    ) {
        guard let serverURL = authServerBaseURL,
              let accessToken = currentAccessToken else {
            completeOnMain { completion(false, nil) }
            return
        }

        performAuthHTTPRequest(
            url: "\(serverURL)/meetings/\(meetingId)",
            method: "DELETE",
            body: nil,
            bearerToken: accessToken,
            retryCount: 0
        ) { [weak self] _, httpResponse, error in
            guard let self = self else { return }
            let success = error == nil && httpResponse?.statusCode == 200
            self.completeOnMain { completion(success, error) }
        }
    }

    /// Start or join a scheduled meeting.
    ///
    /// Calls `POST /meetings/:id/start` on the token server. The server registers
    /// the meeting's pre-assigned room code in Redis (if not already active) and
    /// returns a LiveKit JWT with appropriate permissions: host-level grants for
    /// the meeting host, participant-level grants for invited users.
    ///
    /// Returns the same `InterCreateRoomResponse` shape as `createRoom` so that
    /// `InterRoomController` can call `handleTokenResponse` uniformly.
    @objc public func startScheduledMeeting(
        meetingId: String,
        serverURL: String,
        identity: String,
        displayName: String,
        completion: @escaping (InterCreateRoomResponse?, NSError?) -> Void
    ) {
        guard let accessToken = currentAccessToken else {
            let error = InterNetworkErrorCode.authFailed.error(
                message: "Not authenticated — cannot start scheduled meeting"
            )
            completeOnMain { completion(nil, error) }
            return
        }

        let body: [String: Any] = [
            "identity": identity,
            "displayName": displayName
        ]

        interLogInfo(InterLog.networking, "Token: starting scheduled meeting (id=***)")

        performAuthHTTPRequest(
            url: "\(serverURL)/meetings/\(meetingId)/start",
            method: "POST",
            body: body,
            bearerToken: accessToken,
            retryCount: 0
        ) { [weak self] data, httpResponse, error in
            guard let self = self else { return }

            if let error = error {
                interLogError(InterLog.networking, "Token: /meetings/:id/start transport error: %{public}@",
                              error.localizedDescription)
                self.completeOnMain { completion(nil, error) }
                return
            }

            guard let httpResponse = httpResponse else {
                let err = InterNetworkErrorCode.tokenFetchFailed.error(message: "No response from start endpoint")
                self.completeOnMain { completion(nil, err) }
                return
            }

            if httpResponse.statusCode == 403 || httpResponse.statusCode == 404 || httpResponse.statusCode == 410 {
                let msg: String
                if httpResponse.statusCode == 404 { msg = "Meeting not found" }
                else if httpResponse.statusCode == 410 { msg = "This meeting has been cancelled" }
                else { msg = "You are not authorized to join this meeting" }
                let err = InterNetworkErrorCode.roomCodeInvalid.error(message: msg)
                interLogError(InterLog.networking, "Token: /meetings/:id/start rejected (%d)", httpResponse.statusCode)
                self.completeOnMain { completion(nil, err) }
                return
            }

            guard (200..<300).contains(httpResponse.statusCode),
                  let data = data,
                  let json = self.parseJSON(data),
                  let roomCode = json["roomCode"] as? String,
                  let roomName = json["roomName"] as? String,
                  let token = json["token"] as? String,
                  let wsURL = json["serverURL"] as? String else {
                let err = InterNetworkErrorCode.tokenFetchFailed.error(
                    message: "Malformed response from /meetings/:id/start"
                )
                interLogError(InterLog.networking, "Token: /meetings/:id/start malformed response")
                self.completeOnMain { completion(nil, err) }
                return
            }

            let responseRoomType = json["roomType"] as? String ?? "call"
            self.cacheToken(token, forRoom: roomCode, identity: identity)

            let response = InterCreateRoomResponse(
                roomCode: roomCode,
                roomName: roomName,
                token: token,
                serverURL: wsURL,
                roomType: responseRoomType
            )
            interLogInfo(InterLog.networking, "Token: scheduled meeting started (code=***)")
            self.completeOnMain { completion(response, nil) }
        }
    }

    /// Send invitations for a scheduled meeting.
    @objc public func inviteToMeeting(
        meetingId: String,
        invitees: [[String: String]],
        completion: @escaping (_ result: [String: Any]?, _ error: NSError?) -> Void
    ) {
        guard let serverURL = authServerBaseURL,
              let accessToken = currentAccessToken else {
            completeOnMain { completion(nil, nil) }
            return
        }

        performAuthHTTPRequest(
            url: "\(serverURL)/meetings/\(meetingId)/invite",
            method: "POST",
            body: ["invitees": invitees],
            bearerToken: accessToken,
            retryCount: 0,
            idempotencyKey: UUID().uuidString
        ) { [weak self] data, httpResponse, error in
            guard let self = self else { return }
            guard error == nil,
                  let data = data,
                  let httpResponse = httpResponse,
                  httpResponse.statusCode == 200,
                  let json = self.parseJSON(data) else {
                self.completeOnMain { completion(nil, error) }
                return
            }
            self.completeOnMain { completion(json, nil) }
        }
    }

    // MARK: - Calendar Sync

    /// Fetch Google + Outlook connection status.
    /// Completion called on main queue with dict: `{google: {connected, reauthRequired}, outlook: {connected, reauthRequired}}`.
    @objc public func fetchCalendarStatus(
        completion: @escaping (_ status: [String: Any]?, _ error: NSError?) -> Void
    ) {
        guard let serverURL = authServerBaseURL,
              let accessToken = currentAccessToken else {
            completeOnMain { completion(nil, nil) }
            return
        }

        guard let url = URL(string: "\(serverURL)/calendar/status") else {
            completeOnMain { completion(nil, nil) }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        var taskRef: URLSessionDataTask?
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let t = taskRef { self.untrackTask(t) }
            guard error == nil,
                  let data = data,
                  let json = self.parseJSON(data) else {
                self.completeOnMain { completion(nil, error as NSError?) }
                return
            }
            self.completeOnMain { completion(json, nil) }
        }
        taskRef = task
        trackTask(task)
        task.resume()
    }

    /// Request an OAuth connect URL for Google or Outlook calendar.
    /// `provider` is `"google"` or `"outlook"`.
    /// Completion called on main queue with the authUrl string.
    @objc public func requestCalendarConnectURL(
        provider: String,
        completion: @escaping (_ authUrl: String?, _ error: NSError?) -> Void
    ) {
        guard let serverURL = authServerBaseURL,
              let accessToken = currentAccessToken else {
            completeOnMain { completion(nil, nil) }
            return
        }

        performAuthHTTPRequest(
            url: "\(serverURL)/calendar/\(provider)/connect",
            method: "POST",
            body: [:],
            bearerToken: accessToken,
            retryCount: 0
        ) { [weak self] data, httpResponse, error in
            guard let self = self else { return }
            guard error == nil,
                  let data = data,
                  let json = self.parseJSON(data),
                  let authUrl = json["authUrl"] as? String else {
                self.completeOnMain { completion(nil, error) }
                return
            }
            self.completeOnMain { completion(authUrl, nil) }
        }
    }

    /// Disconnect Google or Outlook calendar.
    /// `provider` is `"google"` or `"outlook"`.
    @objc public func disconnectCalendar(
        provider: String,
        completion: @escaping (_ success: Bool, _ error: NSError?) -> Void
    ) {
        guard let serverURL = authServerBaseURL,
              let accessToken = currentAccessToken else {
            completeOnMain { completion(false, nil) }
            return
        }

        performAuthHTTPRequest(
            url: "\(serverURL)/calendar/\(provider)/disconnect",
            method: "POST",
            body: [:],
            bearerToken: accessToken,
            retryCount: 0
        ) { [weak self] data, httpResponse, error in
            guard let self = self else { return }
            let ok = error == nil && (httpResponse?.statusCode ?? 0) == 200
            self.completeOnMain { completion(ok, error) }
        }
    }

    /// Sync a scheduled meeting to Google or Outlook calendar.
    /// `provider` is `"google"` or `"outlook"`.
    @objc public func syncMeetingToCalendar(
        provider: String,
        meetingId: String,
        completion: @escaping (_ success: Bool, _ error: NSError?) -> Void
    ) {
        guard let serverURL = authServerBaseURL,
              let accessToken = currentAccessToken else {
            completeOnMain { completion(false, nil) }
            return
        }

        performAuthHTTPRequest(
            url: "\(serverURL)/calendar/\(provider)/sync/\(meetingId)",
            method: "POST",
            body: [:],
            bearerToken: accessToken,
            retryCount: 0,
            idempotencyKey: UUID().uuidString
        ) { [weak self] data, httpResponse, error in
            guard let self = self else { return }
            let ok = error == nil && (httpResponse?.statusCode ?? 0) == 200
            self.completeOnMain { completion(ok, error) }
        }
    }

    // MARK: - Teams

    /// Fetch all teams the current user belongs to.
    @objc public func fetchTeams(
        completion: @escaping (_ teams: [[String: Any]]?, _ error: NSError?) -> Void
    ) {
        guard let serverURL = authServerBaseURL,
              let accessToken = currentAccessToken else {
            completeOnMain { completion(nil, nil) }
            return
        }

        guard let url = URL(string: "\(serverURL)/teams") else {
            completeOnMain { completion(nil, nil) }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        var taskRef: URLSessionDataTask?
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let t = taskRef { self.untrackTask(t) }
            guard error == nil,
                  let data = data,
                  let json = self.parseJSON(data),
                  let teams = json["teams"] as? [[String: Any]] else {
                self.completeOnMain { completion(nil, error as NSError?) }
                return
            }
            self.completeOnMain { completion(teams, nil) }
        }
        taskRef = task
        trackTask(task)
        task.resume()
    }

    /// Create a new team.
    @objc public func createTeam(
        name: String,
        teamDescription: String?,
        completion: @escaping (_ team: [String: Any]?, _ error: NSError?) -> Void
    ) {
        guard let serverURL = authServerBaseURL,
              let accessToken = currentAccessToken else {
            completeOnMain { completion(nil, nil) }
            return
        }

        var body: [String: Any] = ["name": name]
        if let desc = teamDescription, !desc.isEmpty {
            body["description"] = desc
        }

        performAuthHTTPRequest(
            url: "\(serverURL)/teams",
            method: "POST",
            body: body,
            bearerToken: accessToken,
            retryCount: 0,
            idempotencyKey: UUID().uuidString
        ) { [weak self] data, httpResponse, error in
            guard let self = self else { return }
            guard error == nil,
                  let data = data,
                  let json = self.parseJSON(data),
                  let team = json["team"] as? [String: Any] else {
                self.completeOnMain { completion(nil, error) }
                return
            }
            self.completeOnMain { completion(team, nil) }
        }
    }

    /// Fetch full details for a team (members list + caller's role).
    @objc public func fetchTeamDetails(
        teamId: String,
        completion: @escaping (_ team: [String: Any]?, _ members: [[String: Any]]?, _ callerRole: String?, _ error: NSError?) -> Void
    ) {
        guard let serverURL = authServerBaseURL,
              let accessToken = currentAccessToken else {
            completeOnMain { completion(nil, nil, nil, nil) }
            return
        }

        guard let url = URL(string: "\(serverURL)/teams/\(teamId)") else {
            completeOnMain { completion(nil, nil, nil, nil) }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        var taskRef: URLSessionDataTask?
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let t = taskRef { self.untrackTask(t) }
            guard error == nil,
                  let data = data,
                  let json = self.parseJSON(data) else {
                self.completeOnMain { completion(nil, nil, nil, error as NSError?) }
                return
            }
            let team = json["team"] as? [String: Any]
            let members = json["members"] as? [[String: Any]]
            let callerRole = json["callerRole"] as? String
            self.completeOnMain { completion(team, members, callerRole, nil) }
        }
        taskRef = task
        trackTask(task)
        task.resume()
    }

    /// Invite users to a team by email.
    @objc public func inviteToTeam(
        teamId: String,
        emails: [String],
        completion: @escaping (_ success: Bool, _ error: NSError?) -> Void
    ) {
        guard let serverURL = authServerBaseURL,
              let accessToken = currentAccessToken else {
            completeOnMain { completion(false, nil) }
            return
        }

        let invitees = emails.map { ["email": $0] }
        performAuthHTTPRequest(
            url: "\(serverURL)/teams/\(teamId)/members",
            method: "POST",
            body: ["invitees": invitees],
            bearerToken: accessToken,
            retryCount: 0,
            idempotencyKey: UUID().uuidString
        ) { [weak self] data, httpResponse, error in
            guard let self = self else { return }
            let ok = error == nil && (httpResponse?.statusCode ?? 0) == 200
            self.completeOnMain { completion(ok, error) }
        }
    }

    /// Accept a pending team invitation (called by the invitee).
    @objc public func acceptTeamInvitation(
        teamId: String,
        completion: @escaping (_ success: Bool, _ error: NSError?) -> Void
    ) {
        guard let serverURL = authServerBaseURL,
              let accessToken = currentAccessToken else {
            completeOnMain { completion(false, nil) }
            return
        }

        performAuthHTTPRequest(
            url: "\(serverURL)/teams/\(teamId)/members/accept",
            method: "POST",
            body: [:],
            bearerToken: accessToken,
            retryCount: 0
        ) { [weak self] data, httpResponse, error in
            guard let self = self else { return }
            let ok = error == nil && (httpResponse?.statusCode ?? 0) == 200
            self.completeOnMain { completion(ok, error) }
        }
    }

    /// Update a team member's role. `role` must be `"admin"` or `"member"`.
    @objc public func updateTeamMemberRole(
        teamId: String,
        memberId: String,
        role: String,
        completion: @escaping (_ success: Bool, _ error: NSError?) -> Void
    ) {
        guard let serverURL = authServerBaseURL,
              let accessToken = currentAccessToken else {
            completeOnMain { completion(false, nil) }
            return
        }

        performAuthHTTPRequest(
            url: "\(serverURL)/teams/\(teamId)/members/\(memberId)",
            method: "PATCH",
            body: ["role": role],
            bearerToken: accessToken,
            retryCount: 0
        ) { [weak self] data, httpResponse, error in
            guard let self = self else { return }
            let ok = error == nil && (httpResponse?.statusCode ?? 0) == 200
            self.completeOnMain { completion(ok, error) }
        }
    }

    /// Remove a member from a team.
    @objc public func removeTeamMember(
        teamId: String,
        memberId: String,
        completion: @escaping (_ success: Bool, _ error: NSError?) -> Void
    ) {
        guard let serverURL = authServerBaseURL,
              let accessToken = currentAccessToken else {
            completeOnMain { completion(false, nil) }
            return
        }

        performAuthHTTPRequest(
            url: "\(serverURL)/teams/\(teamId)/members/\(memberId)",
            method: "DELETE",
            body: [:],
            bearerToken: accessToken,
            retryCount: 0
        ) { [weak self] data, httpResponse, error in
            guard let self = self else { return }
            let ok = error == nil && (httpResponse?.statusCode ?? 0) == 200
            self.completeOnMain { completion(ok, error) }
        }
    }

    /// Delete a team (owner only).
    @objc public func deleteTeam(
        teamId: String,
        completion: @escaping (_ success: Bool, _ error: NSError?) -> Void
    ) {
        guard let serverURL = authServerBaseURL,
              let accessToken = currentAccessToken else {
            completeOnMain { completion(false, nil) }
            return
        }

        performAuthHTTPRequest(
            url: "\(serverURL)/teams/\(teamId)",
            method: "DELETE",
            body: [:],
            bearerToken: accessToken,
            retryCount: 0
        ) { [weak self] data, httpResponse, error in
            guard let self = self else { return }
            let ok = error == nil && (httpResponse?.statusCode ?? 0) == 200
            self.completeOnMain { completion(ok, error) }
        }
    }

    // MARK: - Private: Network

    /// Perform a POST request with JSON body. Retries once on 5xx/timeout.
    /// Circuit breaker (T9): fails fast when server is confirmed unreachable.
    private func performRequest(
        url urlString: String,
        body: [String: Any],
        retryCount: Int,
        idempotencyKey: String? = nil,
        completion: @escaping (Result<Data, NSError>) -> Void
    ) {
        // T9: Circuit breaker — fail fast if server is confirmed unreachable.
        if !circuitBreaker.shouldAllow() {
            let error = InterNetworkErrorCode.serverUnreachable.error(
                message: "Server temporarily unavailable. Reconnecting…"
            )
            completion(.failure(error))
            return
        }

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

        if let key = idempotencyKey {
            request.setValue(key, forHTTPHeaderField: "X-Idempotency-Key")
        }

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

        var taskRef: URLSessionDataTask?
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let t = taskRef { self.untrackTask(t) }

            // Handle transport error (timeout, network down, etc.)
            if let error = error {
                let nsError = error as NSError
                if self.shouldRetry(statusCode: nil, nsError: nsError, retryCount: retryCount) {
                    interLogInfo(InterLog.networking, "Token: retrying after transport error (%{public}@)", nsError.localizedDescription)
                    self.performRequest(url: urlString, body: body, retryCount: retryCount + 1,
                                        idempotencyKey: idempotencyKey, completion: completion)
                    return
                }
                let wrappedError = InterNetworkErrorCode.serverUnreachable.error(
                    message: "Token server unreachable: \(nsError.localizedDescription)",
                    underlyingError: nsError
                )
                self.circuitBreaker.recordFailure()
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
                self.circuitBreaker.recordSuccess()
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
            self.circuitBreaker.recordFailure()
            completion(.failure(error))
        }

        taskRef = task
        trackTask(task)
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
                NSURLErrorCannotConnectToHost,
                NSURLErrorCannotFindHost,
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
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
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
    ///
    /// - Parameter idempotencyKey: Optional UUID string sent as `X-Idempotency-Key` header
    ///   for state-mutating requests (T1 — Two Generals' Problem).
    private func performAuthHTTPRequest(
        url urlString: String,
        method: String,
        body: [String: Any]?,
        bearerToken: String?,
        retryCount: Int,
        idempotencyKey: String? = nil,
        completion: @escaping (Data?, HTTPURLResponse?, NSError?) -> Void
    ) {
        // T9: Circuit breaker — fail fast if server is confirmed unreachable.
        if !circuitBreaker.shouldAllow() {
            completion(nil, nil, InterNetworkErrorCode.serverUnreachable.error(
                message: "Server temporarily unavailable. Reconnecting…"))
            return
        }

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

        if let key = idempotencyKey {
            request.setValue(key, forHTTPHeaderField: "X-Idempotency-Key")
        }

        var taskRef: URLSessionDataTask?
        let task = authSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let t = taskRef { self.untrackTask(t) }

            if let error = error {
                let nsError = error as NSError
                if self.shouldRetry(statusCode: nil, nsError: nsError, retryCount: retryCount) {
                    self.performAuthHTTPRequest(url: urlString, method: method, body: body,
                                                bearerToken: bearerToken, retryCount: retryCount + 1,
                                                idempotencyKey: idempotencyKey,
                                                completion: completion)
                    return
                }
                completion(nil, nil, InterNetworkErrorCode.serverUnreachable.error(
                    message: "Server unreachable: \(nsError.localizedDescription)", underlyingError: nsError))
                self.circuitBreaker.recordFailure()
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(nil, nil, InterNetworkErrorCode.authFailed.error(message: "No HTTP response"))
                return
            }

            // T9: Record success for circuit breaker on any valid HTTP response.
            // 4xx errors are client-side issues, not server failures.
            if httpResponse.statusCode < 500 {
                self.circuitBreaker.recordSuccess()
            } else {
                self.circuitBreaker.recordFailure()
            }

            completion(data, httpResponse, nil)
        }

        taskRef = task
        trackTask(task)
        task.resume()
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

        let safeTier = validatedTier(tier) ?? "free"

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
            self.currentTier = safeTier
            self.authServerBaseURL = serverURL
            self.isAuthenticated = true
            UserDefaults.standard.set(userId, forKey: Self.userIdDefaultsKey)
            UserDefaults.standard.set(email, forKey: Self.emailDefaultsKey)
            UserDefaults.standard.set(displayName, forKey: Self.displayNameDefaultsKey)
            UserDefaults.standard.set(safeTier, forKey: Self.tierDefaultsKey)
        }
        if Thread.isMainThread { writeWork() } else { DispatchQueue.main.async(execute: writeWork) }

        scheduleProactiveRefresh(expiresIn: expiresIn)

        return InterAuthResponse(userId: userId, email: email, displayName: displayName,
                                 tier: safeTier, accessToken: accessToken,
                                 refreshToken: refreshToken, expiresIn: expiresIn)
    }

    /// Decode JWT payload to extract user claims.
    private func extractJWTPayload(from token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
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
        // T9: Reset circuit breaker on auth state clear (thread-safe internally).
        circuitBreaker.reset()

        // T8: Cancel all in-flight network requests.
        cancelPendingRequests()

        let work = { [weak self] in
            guard let self = self else { return }
            self.refreshTimer?.invalidate()
            self.refreshTimer = nil
            self.sessionRetryTimer?.invalidate()
            self.sessionRetryTimer = nil
            self.currentAccessToken = nil
            self.currentUserId = nil
            self.currentEmail = nil
            self.currentDisplayName = nil
            self.currentTier = nil
            self.meetingStartTier = nil
            // authServerBaseURL is server configuration, not a credential — do not clear it.
            // Clearing it causes public endpoints (billing plans, OAuth) to fail silently
            // if the session restore fails because the server was unreachable at launch.
            self.isAuthenticated = false
            self.deleteRefreshToken()
            UserDefaults.standard.removeObject(forKey: Self.userIdDefaultsKey)
            UserDefaults.standard.removeObject(forKey: Self.emailDefaultsKey)
            UserDefaults.standard.removeObject(forKey: Self.displayNameDefaultsKey)
            UserDefaults.standard.removeObject(forKey: Self.tierDefaultsKey)
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
