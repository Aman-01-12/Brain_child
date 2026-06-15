//
//  SettingsViewModelTests.swift
//  interTests
//
//  Tests the unified Settings window's three view models: account flows
//  (profile dirty-tracking/save, password/email gating, sessions parsing,
//  delete), meeting-defaults store round-trip, and device-preference fallback.
//

import XCTest
@testable import inter

// MARK: - Fake account transport

private final class FakeAccountTransport: InterAccountSettingsTransport {
    var profile: [String: Any] = ["email": "a@x.co", "displayName": "Aman Verma",
                                  "tier": "pro", "timezone": NSNull(), "language": NSNull()]
    var updateError: Error?
    private(set) var updates: [[String: String?]] = []
    var passwordError: Error?
    var sessionsRows: [[String: Any]] = []
    private(set) var revoked: [String] = []
    var deleteError: Error?
    private(set) var deleted = false

    func fetchProfile(completion: @escaping ([String: Any]?, Error?) -> Void) {
        completion(profile, nil)
    }
    func updateProfile(displayName: String?, timezone: String?, language: String?,
                       completion: @escaping ([String: Any]?, Error?) -> Void) {
        updates.append(["displayName": displayName, "timezone": timezone, "language": language])
        if let e = updateError { completion(nil, e); return }
        var json = profile
        if let displayName = displayName { json["displayName"] = displayName }
        if let timezone = timezone { json["timezone"] = timezone.isEmpty ? NSNull() : timezone }
        completion(json, nil)
    }
    func changePassword(current: String, new: String, completion: @escaping (Error?) -> Void) {
        completion(passwordError)
    }
    func changeEmail(password: String, newEmail: String, completion: @escaping (Error?) -> Void) {
        completion(nil)
    }
    func listSessions(completion: @escaping ([[String: Any]]?, Error?) -> Void) {
        completion(sessionsRows, nil)
    }
    func revokeSession(id: String, completion: @escaping (Error?) -> Void) {
        revoked.append(id)
        completion(nil)
    }
    func deleteAccount(password: String, completion: @escaping (Error?) -> Void) {
        if deleteError == nil { deleted = true }
        completion(deleteError)
    }
    func fetchCalendarStatus(completion: @escaping ([String: Any]?, Error?) -> Void) {
        completion(["google": ["connected": true], "outlook": ["connected": false]], nil)
    }
    func connectCalendar(provider: String, completion: @escaping (String?, Error?) -> Void) {
        completion(nil, nil)
    }
    func disconnectCalendar(provider: String, completion: @escaping (Bool, Error?) -> Void) {
        completion(true, nil)
    }
}

// MARK: - Fake device provider

private final class FakeDeviceProvider: InterDevicePreferencesProviding {
    var mics = [MediaDeviceOption(id: "mic-1", name: "USB Mic")]
    var cams = [MediaDeviceOption(id: "cam-1", name: "FaceTime HD")]
    var prefMic: String?
    var prefCam: String?

    func audioInputDevices() -> [MediaDeviceOption] { mics }
    func videoInputDevices() -> [MediaDeviceOption] { cams }
    func preferredAudioDeviceID() -> String? { prefMic }
    func preferredVideoDeviceID() -> String? { prefCam }
    func setPreferredAudioDeviceID(_ id: String?) { prefMic = id }
    func setPreferredVideoDeviceID(_ id: String?) { prefCam = id }
}

@MainActor
final class SettingsViewModelTests: XCTestCase {

    // MARK: - Account: profile

    func testProfileLoadAndDirtyTracking() async throws {
        let t = FakeAccountTransport()
        let vm = AccountSettingsViewModel(transport: t)
        vm.loadProfile()
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(vm.email, "a@x.co")
        XCTAssertEqual(vm.savedDisplayName, "Aman Verma")
        XCTAssertFalse(vm.profileDirty, "freshly loaded = clean")

        vm.displayName = "Aman V"
        XCTAssertTrue(vm.profileDirty)
        XCTAssertTrue(vm.canSaveProfile)
        vm.displayName = "   "
        XCTAssertFalse(vm.canSaveProfile, "blank name can't save")
    }

    func testSaveProfileSendsOnlyChangedFields() async throws {
        let t = FakeAccountTransport()
        let vm = AccountSettingsViewModel(transport: t)
        vm.loadProfile()
        try await Task.sleep(nanoseconds: 30_000_000)

        vm.timezone = "Asia/Kolkata"   // name unchanged
        vm.saveProfile()
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(t.updates.count, 1)
        XCTAssertNil(t.updates[0]["displayName"] ?? nil, "unchanged name not sent")
        XCTAssertEqual(t.updates[0]["timezone"] ?? nil, "Asia/Kolkata")
        XCTAssertEqual(vm.savedTimezone, "Asia/Kolkata")
        XCTAssertNotNil(vm.profileMessage)
    }

    // MARK: - Account: password + email gating

    func testPasswordGating() {
        let t = FakeAccountTransport()
        let vm = AccountSettingsViewModel(transport: t)
        vm.currentPassword = "old-secret"
        vm.newPassword = "short"
        vm.confirmPassword = "short"
        XCTAssertFalse(vm.canChangePassword, "8-byte minimum")
        vm.newPassword = "new-secret-pw"
        vm.confirmPassword = "different"
        XCTAssertFalse(vm.canChangePassword, "mismatch blocks")
        vm.confirmPassword = "new-secret-pw"
        XCTAssertTrue(vm.canChangePassword)
    }

    func testPasswordValidatorBounds() {
        XCTAssertFalse(AccountSettingsViewModel.isValidNewPassword("1234567"))
        XCTAssertTrue(AccountSettingsViewModel.isValidNewPassword("12345678"))
        XCTAssertFalse(AccountSettingsViewModel.isValidNewPassword(String(repeating: "x", count: 73)))
    }

    func testEmailGating() {
        let t = FakeAccountTransport()
        let vm = AccountSettingsViewModel(transport: t)
        vm.emailPassword = "pw"
        vm.newEmail = "bad-email"
        XCTAssertFalse(vm.canChangeEmail)
        vm.newEmail = "new@x.co"
        XCTAssertTrue(vm.canChangeEmail)
    }

    // MARK: - Account: sessions

    func testParseSessionsPutsCurrentFirst() {
        let rows: [[String: Any]] = [
            ["id": "s1", "clientId": "aaa", "isCurrent": false],
            ["id": "s2", "clientId": "bbb", "isCurrent": true],
            ["clientId": "no-id-dropped"],
        ]
        let sessions = AccountSettingsViewModel.parseSessions(rows)
        XCTAssertEqual(sessions.map { $0.id }, ["s2", "s1"])
        XCTAssertTrue(sessions[0].isCurrent)
    }

    func testRevokeIgnoresCurrentSession() async throws {
        let t = FakeAccountTransport()
        t.sessionsRows = [["id": "cur", "isCurrent": true], ["id": "other", "isCurrent": false]]
        let vm = AccountSettingsViewModel(transport: t)
        vm.loadSessions()
        try await Task.sleep(nanoseconds: 30_000_000)

        vm.revokeSession(vm.sessions.first { $0.isCurrent }!)
        vm.revokeSession(vm.sessions.first { !$0.isCurrent }!)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(t.revoked, ["other"], "current session is never revoked from here")
        XCTAssertEqual(vm.sessions.map { $0.id }, ["cur"])
    }

    // MARK: - Account: delete

    func testDeleteAccountFiresCallbackOnSuccess() async throws {
        let t = FakeAccountTransport()
        let vm = AccountSettingsViewModel(transport: t)
        var deletedFired = false
        vm.onAccountDeleted = { deletedFired = true }

        vm.deleteAccount()
        XCTAssertFalse(t.deleted, "empty password blocks")

        vm.deletePassword = "pw"
        vm.deleteAccount()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(t.deleted)
        XCTAssertTrue(deletedFired)
    }

    // MARK: - Meeting defaults round-trip

    func testMeetingDefaultsSaveAndReload() {
        let vm = MeetingDefaultsViewModel()
        let originalLobby = vm.lobbyEnabled
        vm.lobbyEnabled = !originalLobby
        vm.tier = "free"
        vm.save()

        let vm2 = MeetingDefaultsViewModel()
        XCTAssertEqual(vm2.lobbyEnabled, !originalLobby, "persisted to the shared store")

        // Restore to avoid polluting the dev machine's defaults.
        vm2.lobbyEnabled = originalLobby
        vm2.save()
    }

    // MARK: - Device preferences

    func testDeviceListsGetSystemDefaultAndStalePrefFallsBack() {
        let p = FakeDeviceProvider()
        p.prefMic = "gone-device"
        let vm = DevicePreferencesViewModel(provider: p)
        vm.load()

        XCTAssertEqual(vm.microphones.first?.id, "", "System default first")
        XCTAssertEqual(vm.microphones.count, 2)
        XCTAssertEqual(vm.selectedMicrophoneID, "", "stale pref falls back to system default")

        vm.selectedMicrophoneID = "mic-1"
        XCTAssertEqual(p.prefMic, "mic-1", "selection persists through the provider")
        vm.selectedMicrophoneID = ""
        XCTAssertNil(p.prefMic, "system default clears the stored pref")
    }
}
