//
//  InterAppConfig.swift
//  inter
//
//  Single source of truth for environment configuration (server endpoints).
//  GLOBAL RULE: config values & endpoints never live in UI or hardcoded call
//  sites — they come from the app's build configuration.
//
//  Resolution order (first non-empty wins):
//    1. Process environment (INTER_LIVEKIT_URL / INTER_TOKEN_URL) — set per
//       Xcode scheme for local development against a different server.
//    2. Info.plist keys (InterLiveKitServerURL / InterTokenServerURL) — the
//       packaged, per-build-configuration values (xcconfig-injectable).
//    3. Development fallback (localhost) — keeps Debug builds working before
//       any configuration exists. Release builds should always ship plist values.
//
//  Exposed to Objective-C so AppKit call sites read the same values.
//

import Foundation

@objc(InterAppConfig)
public final class InterAppConfig: NSObject {

    /// LiveKit media server URL (ws://…).
    @objc public static var liveKitServerURL: String {
        resolve(env: "INTER_LIVEKIT_URL", plist: "InterLiveKitServerURL",
                fallback: "ws://localhost:7880")
    }

    /// Token/API server base URL (http://…).
    @objc public static var tokenServerURL: String {
        resolve(env: "INTER_TOKEN_URL", plist: "InterTokenServerURL",
                fallback: "http://localhost:3000")
    }

    private static func resolve(env: String, plist: String, fallback: String) -> String {
        if let value = ProcessInfo.processInfo.environment[env],
           !value.trimmingCharacters(in: .whitespaces).isEmpty {
            return value.trimmingCharacters(in: .whitespaces)
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: plist) as? String,
           !value.trimmingCharacters(in: .whitespaces).isEmpty {
            return value.trimmingCharacters(in: .whitespaces)
        }
        return fallback
    }
}
