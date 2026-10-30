//
//  InterAppConfigTests.swift
//  interTests
//
//  Pins the endpoint resolution precedence that makes the cloud/LAN switchover a
//  configuration change rather than a code change:
//    process environment → UserDefaults override → Info.plist → localhost fallback.
//
//  The environment, defaults domain and bundle are injected, so these tests never
//  mutate the real process environment or the standard defaults domain.
//
import XCTest
@testable import inter

final class InterAppConfigTests: XCTestCase {

    private let overrideKey = InterAppConfig.tokenServerURLOverrideKey
    private let legacyKey = InterAppConfig.legacyTokenServerURLKey
    private let plistKey = "InterTokenServerURL"
    private let envKey = "INTER_TOKEN_URL"
    private let fallback = "http://localhost:3000"

    /// A defaults domain private to each test — never the standard domain.
    private func makeDefaults(_ values: [String: String]) -> UserDefaults {
        let suite = "InterAppConfigTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        for (key, value) in values { defaults.set(value, forKey: key) }
        return defaults
    }

    private func resolveTokenServer(env: [String: String] = [:],
                                    defaults: [String: String] = [:]) -> String {
        InterAppConfig.resolve(env: envKey,
                               defaultsKeys: [overrideKey, legacyKey],
                               plist: plistKey,
                               fallback: fallback,
                               environment: env,
                               defaults: makeDefaults(defaults),
                               // The test bundle carries none of the Inter* keys, so
                               // the plist layer is absent unless a test supplies it.
                               bundle: Bundle(for: InterAppConfigTests.self))
    }

    // MARK: - Precedence

    func testEnvironmentWinsOverEverything() {
        let resolved = resolveTokenServer(
            env: [envKey: "http://env.example:3000"],
            defaults: [overrideKey: "http://override.example:3000",
                       legacyKey: "http://legacy.example:3000"])
        XCTAssertEqual(resolved, "http://env.example:3000")
    }

    func testUserDefaultsOverrideWinsWhenNoEnvironment() {
        let resolved = resolveTokenServer(
            defaults: [overrideKey: "http://192.168.1.5:3000",
                       legacyKey: "http://legacy.example:3000"])
        XCTAssertEqual(resolved, "http://192.168.1.5:3000",
                       "the documented `defaults write` override must beat the legacy key")
    }

    func testLegacyDefaultsKeyStillHonouredWhenNewKeyAbsent() {
        let resolved = resolveTokenServer(defaults: [legacyKey: "http://legacy.example:3000"])
        XCTAssertEqual(resolved, "http://legacy.example:3000",
                       "machines already carrying the pre-existing key must keep working")
    }

    func testInfoPlistValueUsedWhenNoEnvironmentOrOverride() {
        // Simulate the packaged plist layer by resolving against a plist key the test
        // bundle does define; CFBundleIdentifier is always present.
        let resolved = InterAppConfig.resolve(env: envKey,
                                              defaultsKeys: [overrideKey],
                                              plist: "CFBundleIdentifier",
                                              fallback: fallback,
                                              environment: [:],
                                              defaults: makeDefaults([:]),
                                              bundle: Bundle(for: InterAppConfigTests.self))
        XCTAssertFalse(resolved.isEmpty)
        XCTAssertNotEqual(resolved, fallback, "a present plist value must beat the fallback")
    }

    func testFallbackWhenNothingConfigured() {
        XCTAssertEqual(resolveTokenServer(), fallback,
                       "no env, no override, no plist key ⇒ local dev default is unchanged")
    }

    // MARK: - Blank handling

    func testBlankValuesAreSkipped() {
        let resolved = resolveTokenServer(env: [envKey: "   "],
                                          defaults: [overrideKey: "",
                                                     legacyKey: "http://legacy.example:3000"])
        XCTAssertEqual(resolved, "http://legacy.example:3000",
                       "whitespace-only and empty values must not shadow a real one")
    }

    func testResolvedValueIsTrimmed() {
        let resolved = resolveTokenServer(defaults: [overrideKey: "  http://192.168.1.5:3000 "])
        XCTAssertEqual(resolved, "http://192.168.1.5:3000")
    }

    // MARK: - Local-dev default is unchanged

    func testLiveKitPlaceholderFallsBackToLocalDevURL() {
        let resolved = InterAppConfig.resolve(env: "INTER_LIVEKIT_URL",
                                              defaultsKeys: [],
                                              plist: "InterLiveKitServerURL",
                                              fallback: "ws://localhost:7880",
                                              environment: [:],
                                              defaults: makeDefaults([:]),
                                              bundle: Bundle(for: InterAppConfigTests.self))
        XCTAssertEqual(resolved, "ws://localhost:7880")
    }

    /// The media URL is deliberately not UserDefaults-overridable: the client connects
    /// to the `serverURL` the token server returns, so a client-side override could only
    /// ever disagree with the server-issued token.
    func testLiveKitURLIgnoresUserDefaults() {
        let resolved = InterAppConfig.resolve(env: "INTER_LIVEKIT_URL",
                                              defaultsKeys: [],
                                              plist: "InterLiveKitServerURL",
                                              fallback: "ws://localhost:7880",
                                              environment: [:],
                                              defaults: makeDefaults([
                                                  "InterLiveKitServerURLOverride": "wss://evil.example"
                                              ]),
                                              bundle: Bundle(for: InterAppConfigTests.self))
        XCTAssertEqual(resolved, "ws://localhost:7880")
    }

    // MARK: - Cleartext-to-remote detection (cloud readiness)

    func testCloudSchemesAreNotFlaggedInsecure() {
        XCTAssertFalse(InterAppConfig.isInsecureRemote("wss://myproject.livekit.cloud"))
        XCTAssertFalse(InterAppConfig.isInsecureRemote("https://api.example.com"))
    }

    func testLoopbackCleartextIsAllowedButLANCleartextIsFlagged() {
        XCTAssertFalse(InterAppConfig.isInsecureRemote("http://localhost:3000"))
        XCTAssertFalse(InterAppConfig.isInsecureRemote("ws://127.0.0.1:7880"))
        XCTAssertTrue(InterAppConfig.isInsecureRemote("http://192.168.1.5:3000"),
                      "LAN cleartext is usable for dev but must still be reported as insecure")
    }
}
