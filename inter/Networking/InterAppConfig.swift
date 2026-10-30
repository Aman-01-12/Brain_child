//
//  InterAppConfig.swift
//  inter
//
//  Single source of truth for environment configuration (server endpoints).
//  GLOBAL RULE: config values & endpoints never live in UI or hardcoded call
//  sites — they come from the app's build configuration.
//
//  Resolution order (first non-blank wins):
//    1. Process environment (INTER_LIVEKIT_URL / INTER_TOKEN_URL) — set per
//       Xcode scheme, or exported before a terminal launch, for local
//       development against a different server.
//    2. UserDefaults override (`InterTokenServerURLOverride`, legacy
//       `InterDefaultTokenServerURL`) — set without rebuilding, e.g. to point a
//       second Mac at the host Mac's LAN IP for two-device testing:
//         defaults write Secure.inter InterTokenServerURLOverride "http://192.168.1.5:3000"
//    3. Info.plist keys (InterLiveKitServerURL / InterTokenServerURL) — the
//       packaged, per-build-configuration values (xcconfig-injectable).
//    4. Development fallback (localhost) — keeps Debug builds working before
//       any configuration exists. Release builds should always ship plist values.
//
//  NOTE ON THE LIVEKIT URL: `liveKitServerURL` is only a pre-connect placeholder.
//  The URL the client actually connects to is the `serverURL` the token server
//  returns from /room/create, /room/join, /meetings/:id/start and the lobby
//  admission poll — so moving to cloud LiveKit is a token-server .env change
//  (LIVEKIT_SERVER_URL) and needs no client rebuild. Deliberately NOT
//  UserDefaults-overridable: a client-side override of the media URL could only
//  ever disagree with the server-issued token.
//
//  Exposed to Objective-C so AppKit call sites read the same values.
//

import Foundation

@objc(InterAppConfig)
public final class InterAppConfig: NSObject {

    /// UserDefaults key that overrides the packaged token-server URL.
    /// `defaults write Secure.inter InterTokenServerURLOverride "http://<lan-ip>:3000"`
    @objc public static let tokenServerURLOverrideKey = "InterTokenServerURLOverride"

    /// Pre-dating override key, still honoured so existing machines keep working.
    static let legacyTokenServerURLKey = "InterDefaultTokenServerURL"

    /// LiveKit media server URL (ws://…). Placeholder only — see the note above.
    @objc public static var liveKitServerURL: String {
        resolve(env: "INTER_LIVEKIT_URL", defaultsKeys: [],
                plist: "InterLiveKitServerURL", fallback: "ws://localhost:7880")
    }

    /// Token/API server base URL (http://…). Every token-server call resolves here.
    @objc public static var tokenServerURL: String {
        resolve(env: "INTER_TOKEN_URL",
                defaultsKeys: [tokenServerURLOverrideKey, legacyTokenServerURLKey],
                plist: "InterTokenServerURL", fallback: "http://localhost:3000")
    }

    /// Log the resolved endpoints once at startup so the operator can confirm which
    /// server this launch is talking to (critical when a second device is pointed at
    /// a LAN IP). Neither value is a secret — no credentials are logged.
    @objc public static func logResolvedEndpoints() {
        interLogInfo(InterLog.networking,
                     "Config: tokenServer=%{public}@ liveKitPlaceholder=%{public}@ (the LiveKit URL used to connect is the one the token server returns)",
                     tokenServerURL, liveKitServerURL)
    }

    /// True if `urlString` would send credentials over cleartext to a NON-loopback host
    /// (http/ws to a remote). Loopback (localhost/127.0.0.1/::1) is allowed for local dev.
    /// Used to warn when Bearer tokens would leave the machine unencrypted.
    @objc public static func isInsecureRemote(_ urlString: String) -> Bool {
        guard let u = URL(string: urlString), let scheme = u.scheme?.lowercased() else { return false }
        let host = (u.host ?? "").lowercased()
        let isLoopback = (host == "localhost" || host == "127.0.0.1" || host == "::1")
        let isCleartext = (scheme == "http" || scheme == "ws")
        return isCleartext && !isLoopback
    }

    /// Resolve one endpoint through the documented precedence. The `environment`,
    /// `defaults` and `bundle` parameters exist so the precedence is testable without
    /// mutating the real process environment or the standard defaults domain; production
    /// call sites use the defaults and are unaffected.
    static func resolve(env: String,
                        defaultsKeys: [String],
                        plist: String,
                        fallback: String,
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        defaults: UserDefaults = .standard,
                        bundle: Bundle = .main) -> String {
        var candidates: [String?] = [environment[env]]
        candidates.append(contentsOf: defaultsKeys.map { defaults.string(forKey: $0) })
        candidates.append(bundle.object(forInfoDictionaryKey: plist) as? String)

        for candidate in candidates {
            guard let value = candidate?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { continue }
            return value
        }
        return fallback
    }
}
