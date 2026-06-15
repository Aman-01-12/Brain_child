//
//  AccountSettingsViewModel.swift
//  inter
//
//  Data source 1 of the unified Settings window: everything backed by the auth
//  server — profile (name/email/tier/timezone/language), password change,
//  email change, active sessions (+ revoke), account deletion, and calendar
//  sync status/connect/disconnect.
//
//  All server I/O flows through an injectable `InterAccountSettingsTransport`
//  seam so the logic is unit-testable without a live server. The concrete
//  transport (the bridge) forwards to InterTokenService.
//

import Foundation
import Combine
import AppKit

/// The auth-server surface the ACCOUNT tabs depend on.
public protocol InterAccountSettingsTransport: AnyObject {
    func fetchProfile(completion: @escaping ([String: Any]?, Error?) -> Void)
    func updateProfile(displayName: String?, timezone: String?, language: String?,
                       completion: @escaping ([String: Any]?, Error?) -> Void)
    func changePassword(current: String, new: String, completion: @escaping (Error?) -> Void)
    func changeEmail(password: String, newEmail: String, completion: @escaping (Error?) -> Void)
    func listSessions(completion: @escaping ([[String: Any]]?, Error?) -> Void)
    func revokeSession(id: String, completion: @escaping (Error?) -> Void)
    func deleteAccount(password: String, completion: @escaping (Error?) -> Void)
    func fetchCalendarStatus(completion: @escaping ([String: Any]?, Error?) -> Void)
    func connectCalendar(provider: String, completion: @escaping (String?, Error?) -> Void)
    func disconnectCalendar(provider: String, completion: @escaping (Bool, Error?) -> Void)
}

/// One active-session row.
public struct AccountSession: Equatable, Identifiable {
    public let id: String
    public let clientId: String
    public let createdAt: String
    public let lastUsedAt: String
    public let isCurrent: Bool
}

@MainActor
public final class AccountSettingsViewModel: ObservableObject {

    // MARK: - Auth gate

    /// When false the ACCOUNT tabs render the sign-in gate and server loads are
    /// skipped (signed-out users keep the local MEETINGS tabs only).
    @Published public var isAuthenticated = true

    // MARK: - Profile

    @Published public private(set) var email: String = ""
    @Published public private(set) var tier: String = "free"
    @Published public var displayName: String = ""
    @Published public private(set) var savedDisplayName: String = ""
    @Published public var timezone: String = ""           // "" = system default
    @Published public private(set) var savedTimezone: String = ""
    @Published public private(set) var profileLoaded = false
    @Published public private(set) var isSavingProfile = false
    @Published public var profileMessage: String?
    @Published public var profileError: String?

    // MARK: - Password / Email forms

    @Published public var currentPassword = ""
    @Published public var newPassword = ""
    @Published public var confirmPassword = ""
    @Published public private(set) var isChangingPassword = false
    @Published public var passwordMessage: String?
    @Published public var passwordError: String?

    @Published public var emailPassword = ""
    @Published public var newEmail = ""
    @Published public private(set) var isChangingEmail = false
    @Published public var emailMessage: String?
    @Published public var emailError: String?

    // MARK: - Sessions + danger zone

    @Published public private(set) var sessions: [AccountSession] = []
    @Published public private(set) var sessionsLoading = false
    @Published public var sessionsError: String?
    @Published public var deletePassword = ""
    @Published public private(set) var isDeletingAccount = false
    @Published public var deleteError: String?

    // MARK: - Calendar sync

    @Published public private(set) var googleConnected: Bool?
    @Published public private(set) var outlookConnected: Bool?
    @Published public private(set) var calendarBusy = false
    @Published public var calendarError: String?

    /// Fired after the server confirms account deletion — host dismisses + signs out.
    public var onAccountDeleted: (() -> Void)?
    /// Fired after a successful name save (host may want to refresh other UI).
    public var onProfileSaved: (() -> Void)?

    private let transport: InterAccountSettingsTransport

    public init(transport: InterAccountSettingsTransport) {
        self.transport = transport
    }

    // MARK: - Loads

    public func load() {
        guard isAuthenticated else { return }
        loadProfile()
        loadSessions()
        loadCalendarStatus()
    }

    public func loadProfile() {
        transport.fetchProfile { [weak self] json, _ in
            Task { @MainActor in
                guard let self = self, let json = json else { return }
                self.email = json["email"] as? String ?? self.email
                self.tier = json["tier"] as? String ?? self.tier
                let name = json["displayName"] as? String ?? ""
                self.displayName = name
                self.savedDisplayName = name
                let tz = (json["timezone"] as? String) ?? ""
                self.timezone = tz
                self.savedTimezone = tz
                self.profileLoaded = true
                // Cache for the scheduling default (the consumer wire).
                AccountSettingsViewModel.cacheTimezonePreference(tz)
            }
        }
    }

    // MARK: - Profile save

    public var profileDirty: Bool {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines) != savedDisplayName
            || timezone != savedTimezone
    }

    public var canSaveProfile: Bool {
        !isSavingProfile && profileDirty
            && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func saveProfile() {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSaveProfile else { return }
        isSavingProfile = true
        profileError = nil
        profileMessage = nil

        let nameArg = trimmedName != savedDisplayName ? trimmedName : nil
        let tzArg = timezone != savedTimezone ? timezone : nil   // "" clears → server NULL

        transport.updateProfile(displayName: nameArg, timezone: tzArg, language: nil) { [weak self] json, error in
            Task { @MainActor in
                guard let self = self else { return }
                self.isSavingProfile = false
                if let error = error {
                    self.profileError = error.localizedDescription
                    return
                }
                let name = (json?["displayName"] as? String) ?? trimmedName
                self.savedDisplayName = name
                self.displayName = name
                let tz = (json?["timezone"] as? String) ?? ""
                self.savedTimezone = tz
                self.timezone = tz
                AccountSettingsViewModel.cacheTimezonePreference(tz)
                self.profileMessage = "Profile updated."
                self.onProfileSaved?()
            }
        }
    }

    // MARK: - Password change

    public var canChangePassword: Bool {
        !isChangingPassword
            && !currentPassword.isEmpty
            && AccountSettingsViewModel.isValidNewPassword(newPassword)
            && newPassword == confirmPassword
    }

    public func changePassword() {
        guard canChangePassword else {
            if !newPassword.isEmpty && newPassword != confirmPassword {
                passwordError = "Passwords don't match."
            }
            return
        }
        isChangingPassword = true
        passwordError = nil
        passwordMessage = nil
        transport.changePassword(current: currentPassword, new: newPassword) { [weak self] error in
            Task { @MainActor in
                guard let self = self else { return }
                self.isChangingPassword = false
                if let error = error {
                    self.passwordError = error.localizedDescription
                } else {
                    self.passwordMessage = "Password updated. Other sessions were signed out."
                    self.currentPassword = ""
                    self.newPassword = ""
                    self.confirmPassword = ""
                    self.loadSessions()
                }
            }
        }
    }

    // MARK: - Email change

    public var canChangeEmail: Bool {
        !isChangingEmail && !emailPassword.isEmpty
            && AccountSettingsViewModel.isPlausibleEmail(newEmail)
    }

    public func changeEmail() {
        guard canChangeEmail else { return }
        isChangingEmail = true
        emailError = nil
        emailMessage = nil
        transport.changeEmail(password: emailPassword, newEmail: newEmail.trimmingCharacters(in: .whitespaces)) { [weak self] error in
            Task { @MainActor in
                guard let self = self else { return }
                self.isChangingEmail = false
                if let error = error {
                    self.emailError = error.localizedDescription
                } else {
                    self.emailMessage = "Verification email sent to \(self.newEmail). The change applies once you click the link."
                    self.emailPassword = ""
                    self.newEmail = ""
                }
            }
        }
    }

    // MARK: - Sessions

    public func loadSessions() {
        sessionsLoading = true
        sessionsError = nil
        transport.listSessions { [weak self] rows, error in
            Task { @MainActor in
                guard let self = self else { return }
                self.sessionsLoading = false
                if let error = error {
                    self.sessionsError = error.localizedDescription
                    return
                }
                self.sessions = AccountSettingsViewModel.parseSessions(rows ?? [])
            }
        }
    }

    public func revokeSession(_ session: AccountSession) {
        guard !session.isCurrent else { return }
        transport.revokeSession(id: session.id) { [weak self] error in
            Task { @MainActor in
                guard let self = self else { return }
                if let error = error {
                    self.sessionsError = error.localizedDescription
                } else {
                    self.sessions.removeAll { $0.id == session.id }
                }
            }
        }
    }

    // MARK: - Danger zone

    public var canDeleteAccount: Bool {
        !isDeletingAccount && !deletePassword.isEmpty
    }

    public func deleteAccount() {
        guard canDeleteAccount else { return }
        isDeletingAccount = true
        deleteError = nil
        transport.deleteAccount(password: deletePassword) { [weak self] error in
            Task { @MainActor in
                guard let self = self else { return }
                self.isDeletingAccount = false
                if let error = error {
                    self.deleteError = error.localizedDescription
                } else {
                    self.onAccountDeleted?()
                }
            }
        }
    }

    // MARK: - Calendar sync

    public func loadCalendarStatus() {
        transport.fetchCalendarStatus { [weak self] status, _ in
            Task { @MainActor in
                guard let self = self, let status = status else { return }
                self.googleConnected = ((status["google"] as? [String: Any])?["connected"] as? Bool) ?? false
                self.outlookConnected = ((status["outlook"] as? [String: Any])?["connected"] as? Bool) ?? false
            }
        }
    }

    public func toggleCalendar(provider: String, isConnected: Bool) {
        calendarBusy = true
        calendarError = nil
        if isConnected {
            transport.disconnectCalendar(provider: provider) { [weak self] _, error in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.calendarBusy = false
                    if let error = error { self.calendarError = error.localizedDescription }
                    self.loadCalendarStatus()
                }
            }
        } else {
            transport.connectCalendar(provider: provider) { [weak self] url, error in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.calendarBusy = false
                    if let error = error {
                        self.calendarError = error.localizedDescription
                    } else if let urlString = url, let u = URL(string: urlString) {
                        NSWorkspace.shared.open(u)
                    }
                }
            }
        }
    }

    // MARK: - Pure helpers (unit-tested)

    /// Server rule: 8–72 bytes.
    public nonisolated static func isValidNewPassword(_ pw: String) -> Bool {
        let bytes = pw.utf8.count
        return bytes >= 8 && bytes <= 72
    }

    public nonisolated static func isPlausibleEmail(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 3, s.count <= 254 else { return false }
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".") && !domain.contains(" ")
    }

    /// Decode GET /auth/sessions rows; current session first.
    public nonisolated static func parseSessions(_ rows: [[String: Any]]) -> [AccountSession] {
        let sessions = rows.compactMap { dict -> AccountSession? in
            guard let id = dict["id"] as? String else { return nil }
            return AccountSession(
                id: id,
                clientId: dict["clientId"] as? String ?? "unknown",
                createdAt: dict["createdAt"] as? String ?? "",
                lastUsedAt: dict["lastUsedAt"] as? String ?? "",
                isCurrent: dict["isCurrent"] as? Bool ?? false
            )
        }
        return sessions.sorted { $0.isCurrent && !$1.isCurrent }
    }

    /// All IANA timezone identifiers, system-default first ("" sentinel).
    public nonisolated static var timezoneOptions: [String] {
        TimeZone.knownTimeZoneIdentifiers.sorted()
    }

    /// Display label for a stored timezone ("" → "System default (…)" ).
    public nonisolated static func timezoneLabel(_ stored: String) -> String {
        stored.isEmpty ? "System default (\(TimeZone.current.identifier))" : stored
    }

    /// UserDefaults cache the scheduling screen reads as its default host
    /// timezone (the consumer wire that keeps the picker honest).
    public static let timezoneDefaultsKey = "InterUserTimezonePreference"

    public nonisolated static func cacheTimezonePreference(_ tz: String) {
        if tz.isEmpty {
            UserDefaults.standard.removeObject(forKey: timezoneDefaultsKey)
        } else {
            UserDefaults.standard.set(tz, forKey: timezoneDefaultsKey)
        }
    }
}
