//
//  SettingsView.swift
//  inter
//
//  The unified Settings window (one window for every preference — replaces the
//  separate Settings / Account Settings / Meeting-Defaults windows). Visual
//  language follows the design handoff AccountPanelMock: a muted sidebar with
//  grouped tabs (ACCOUNT / MEETINGS) and a card content pane.
//
//  Per the council-approved decisions:
//    • ACCOUNT: Profile (editable name + timezone; Language shown as coming
//      soon; Sign Out), Password, Email, Sessions (+ Danger Zone), Calendar.
//    • MEETINGS: Meeting Defaults (the shared InterPreMeetingSettings store),
//      Video / Audio (DEFAULT device pickers — applied at next session start,
//      never live reconfiguration), Background (designed, disabled, honest
//      "available soon" message).
//    • PMI / 2FA / device-Security toggles are omitted (no backing features).
//

import SwiftUI
import AppKit

// MARK: - Tabs

public enum SettingsTab: String, CaseIterable, Identifiable {
    case profile = "Profile"
    case password = "Password"
    case email = "Email"
    case sessions = "Sessions"
    case calendar = "Calendar Sync"
    case meetingDefaults = "Meeting Defaults"
    case video = "Video"
    case audio = "Audio"
    case recording = "Recording"
    case background = "Background"

    public var id: String { rawValue }

    var group: String {
        switch self {
        case .profile, .password, .email, .sessions, .calendar: return "Account"
        case .meetingDefaults, .video, .audio, .recording, .background: return "Meetings"
        }
    }

    var icon: String {
        switch self {
        case .profile: return "person"
        case .password: return "key"
        case .email: return "envelope"
        case .sessions: return "display.2"
        case .calendar: return "calendar.badge.plus"
        case .meetingDefaults: return "gearshape.2"
        case .video: return "video"
        case .audio: return "mic"
        case .recording: return "record.circle"
        case .background: return "photo"
        }
    }
}

// MARK: - Root

struct SettingsView: View {
    @ObservedObject var account: AccountSettingsViewModel
    @ObservedObject var defaults: MeetingDefaultsViewModel
    @ObservedObject var devices: DevicePreferencesViewModel
    @Binding var tab: SettingsTab
    var onSignOut: () -> Void
    var onSignIn: () -> Void = {}
    var onSignUp: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Color(nsColor: InterColor.border))
            content
        }
        .background(Color(nsColor: InterColor.card))
        .ignoresSafeArea(.container, edges: .top) // seamless chrome
        .interResignsFocusOnBackgroundTap()
        .onAppear {
            account.load()
            devices.load()
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Identity header (signed-out shows an honest "Not signed in" state).
            HStack(spacing: InterSpacing.x2_5) {
                Circle()
                    .fill(account.isAuthenticated
                        ? Color(nsColor: InterColor.primary)
                        : Color(nsColor: InterColor.secondary))
                    .frame(width: 34, height: 34)
                    .overlay(Group {
                        if account.isAuthenticated {
                            Text(HomeViewModel.initials(from: account.savedDisplayName))
                                .font(InterFont.swiftUI(12, .bold))
                                .foregroundColor(.white)
                        } else {
                            Image(systemName: "person.fill")
                                .font(.system(size: 14))
                                .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                        }
                    })
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.isAuthenticated
                         ? (account.savedDisplayName.isEmpty ? "Account" : account.savedDisplayName)
                         : "Not signed in")
                        .font(InterFont.swiftUI(12, .semibold))
                        .foregroundColor(Color(nsColor: InterColor.foreground))
                        .lineLimit(1)
                    Text(account.isAuthenticated ? account.email : "Meeting settings only")
                        .font(InterFont.swiftUI(10))
                        .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.horizontal, InterSpacing.x4)
            .padding(.bottom, InterSpacing.x3)
            .interTitlebarInset()

            ScrollView {
                VStack(alignment: .leading, spacing: InterSpacing.x3) {
                    ForEach(["Account", "Meetings"], id: \.self) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.uppercased())
                                .font(InterFont.swiftUI(9, .bold))
                                .tracking(1.2)
                                .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                                .padding(.horizontal, InterSpacing.x2)
                                .padding(.vertical, InterSpacing.x1)
                            ForEach(SettingsTab.allCases.filter { $0.group == group }) { item in
                                tabButton(item)
                            }
                        }
                    }
                }
                .padding(InterSpacing.x2)
            }
        }
        .frame(width: 192)
        .background(Color(nsColor: InterColor.muted))
    }

    private func tabButton(_ item: SettingsTab) -> some View {
        let active = tab == item
        return Button(action: { tab = item }) {
            HStack(spacing: InterSpacing.x2) {
                Image(systemName: item.icon)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 14)
                Text(item.rawValue)
                    .font(InterFont.swiftUI(12, active ? .semibold : .medium))
                Spacer(minLength: 0)
            }
            .foregroundColor(active
                ? Color(nsColor: InterColor.primary)
                : Color(nsColor: InterColor.mutedForeground))
            .padding(.horizontal, InterSpacing.x2_5)
            .padding(.vertical, InterSpacing.x1_5 + 1)
            .background(
                RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                    .fill(active ? Color(nsColor: InterColor.card) : .clear)
                    .overlay(RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                        .strokeBorder(active ? Color(nsColor: InterColor.border) : .clear, lineWidth: 1))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
    }

    // MARK: Content

    private var content: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tab.rawValue)
                    .font(InterFont.swiftUI(14, .semibold))
                    .foregroundColor(Color(nsColor: InterColor.cardForeground))
                Spacer()
            }
            .padding(.horizontal, InterSpacing.x5)
            .frame(height: 44)
            .interTitlebarInset()

            ScrollView {
                Group {
                    if tab.group == "Account" && !account.isAuthenticated {
                        signedOutGate
                    } else {
                        switch tab {
                        case .profile: profileTab
                        case .password: passwordTab
                        case .email: emailTab
                        case .sessions: sessionsTab
                        case .calendar: calendarTab
                        case .meetingDefaults: meetingDefaultsTab
                        case .video: videoTab
                        case .audio: audioTab
                        case .recording: recordingTab
                        case .background: backgroundTab
                        }
                    }
                }
                .padding(InterSpacing.x5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Signed-out gate (account features require auth)

    private var signedOutGate: some View {
        HStack {
            Spacer()
            VStack(spacing: InterSpacing.x3) {
                RoundedRectangle(cornerRadius: InterRadius.xl, style: .continuous)
                    .fill(Color(nsColor: InterColor.primary))
                    .frame(width: 56, height: 56)
                    .overlay(Image(systemName: "person.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white))
                    .padding(.bottom, InterSpacing.x1)
                (Text("Sign in").font(InterFont.swiftUI(13, .semibold))
                    .foregroundColor(Color(nsColor: InterColor.primary))
                 + Text(" to manage your profile, password,\nsessions, and calendar sync")
                    .font(InterFont.swiftUI(13, .semibold))
                    .foregroundColor(Color(nsColor: InterColor.foreground)))
                    .multilineTextAlignment(.center)
                VStack(spacing: InterSpacing.x2) {
                    InterButton("Sign In", variant: .primary, size: .medium,
                                fullWidth: true, action: onSignIn)
                    InterButton("Sign Up", variant: .secondary, size: .medium,
                                fullWidth: true, action: onSignUp)
                }
                .frame(width: 220)
                .padding(.top, InterSpacing.x2)
            }
            .padding(.top, InterSpacing.x8)
            Spacer()
        }
    }

    // MARK: - Profile

    private var profileTab: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x4) {
            HStack(spacing: InterSpacing.x4) {
                Circle()
                    .fill(Color(nsColor: InterColor.primary))
                    .frame(width: 56, height: 56)
                    .overlay(Text(HomeViewModel.initials(from: account.savedDisplayName))
                        .font(InterFont.swiftUI(20, .bold))
                        .foregroundColor(.white))
                VStack(alignment: .leading, spacing: InterSpacing.x1) {
                    Text(account.email)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                    Text("Plan: \(account.tier.capitalized)")
                        .font(InterFont.swiftUI(10, .semibold))
                        .foregroundColor(Color(nsColor: InterColor.primary))
                        .padding(.horizontal, InterSpacing.x2)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(nsColor: InterColor.primary).opacity(0.14)))
                }
            }

            field("Display name") {
                InterInputField(placeholder: "Your name", text: $account.displayName)
            }

            field("Timezone") {
                InterSelect(selection: $account.timezone, options: timezoneSelectOptions)
            }
            Text("Used as your default timezone when scheduling meetings.")
                .font(InterFont.swiftUI(10))
                .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                .padding(.top, -InterSpacing.x2)

            field("Language") {
                HStack(spacing: InterSpacing.x2) {
                    Text("English (US)")
                        .font(InterFont.swiftUI(InterFont.Size.secondary))
                        .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                    Text("More languages coming soon")
                        .font(InterFont.swiftUI(10, .medium))
                        .foregroundColor(Color(nsColor: InterStatus.warning))
                        .padding(.horizontal, InterSpacing.x1_5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(nsColor: InterStatus.warning).opacity(0.12)))
                }
            }

            if let msg = account.profileMessage { InterBanner(msg, variant: .success) }
            if let err = account.profileError { InterBanner(err, variant: .error) }

            HStack {
                InterButton("Sign Out", variant: .secondary, size: .medium, action: onSignOut)
                Spacer()
                InterButton("Save changes", variant: .primary, size: .medium,
                            isLoading: account.isSavingProfile,
                            enabled: account.canSaveProfile,
                            action: { account.saveProfile() })
            }
            .padding(.top, InterSpacing.x2)
        }
        .frame(maxWidth: 460, alignment: .leading)
    }

    // MARK: - Password

    private var passwordTab: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x3) {
            field("Current password") {
                SettingsSecureField(placeholder: "Current password", text: $account.currentPassword)
            }
            field("New password (8–72 characters)") {
                SettingsSecureField(placeholder: "New password", text: $account.newPassword)
            }
            field("Confirm new password") {
                SettingsSecureField(placeholder: "Confirm new password", text: $account.confirmPassword,
                                    hasError: !account.confirmPassword.isEmpty
                                        && account.newPassword != account.confirmPassword)
            }

            if let msg = account.passwordMessage { InterBanner(msg, variant: .success) }
            if let err = account.passwordError { InterBanner(err, variant: .error) }

            InterButton("Change Password", variant: .primary, size: .medium,
                        isLoading: account.isChangingPassword,
                        loadingTitle: "Saving…",
                        enabled: account.canChangePassword,
                        action: { account.changePassword() })
        }
        .frame(maxWidth: 380, alignment: .leading)
    }

    // MARK: - Email

    private var emailTab: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x3) {
            field("Confirm your current password") {
                SettingsSecureField(placeholder: "Current password", text: $account.emailPassword)
            }
            field("New email address") {
                InterInputField(placeholder: "new@example.com", text: $account.newEmail)
            }

            if let msg = account.emailMessage { InterBanner(msg, variant: .success) }
            if let err = account.emailError { InterBanner(err, variant: .error) }

            InterButton("Send Verification", variant: .primary, size: .medium,
                        isLoading: account.isChangingEmail,
                        loadingTitle: "Sending…",
                        enabled: account.canChangeEmail,
                        action: { account.changeEmail() })
        }
        .frame(maxWidth: 380, alignment: .leading)
    }

    // MARK: - Sessions (+ Danger Zone)

    private var sessionsTab: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x4) {
            InterButton("Refresh", systemImage: "arrow.clockwise", variant: .secondary, size: .compact,
                        action: { account.loadSessions() })

            if account.sessionsLoading {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    .padding(.vertical, InterSpacing.x4)
            } else if account.sessions.isEmpty {
                Text("No active sessions found.")
                    .font(InterFont.swiftUI(12))
                    .foregroundColor(Color(nsColor: InterColor.mutedForeground))
            } else {
                // Flat list — hairline dividers, no box-in-box.
                VStack(spacing: 0) {
                    ForEach(account.sessions) { session in
                        sessionRow(session)
                        if session.id != account.sessions.last?.id {
                            Divider().overlay(Color(nsColor: InterColor.border).opacity(0.6))
                                .padding(.leading, InterSpacing.x3)
                        }
                    }
                }
            }

            if let err = account.sessionsError { InterBanner(err, variant: .error) }

            dangerZone
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private func sessionRow(_ session: AccountSession) -> some View {
        HStack(spacing: InterSpacing.x3) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 13))
                .foregroundColor(Color(nsColor: InterColor.mutedForeground))
            VStack(alignment: .leading, spacing: 1) {
                Text(String(session.clientId.prefix(8)))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(nsColor: InterColor.foreground))
                Text("Started \(session.createdAt) · Last used \(session.lastUsedAt)")
                    .font(InterFont.swiftUI(10))
                    .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                    .lineLimit(1)
            }
            Spacer(minLength: InterSpacing.x2)
            if session.isCurrent {
                Text("This Device")
                    .font(InterFont.swiftUI(10, .semibold))
                    .foregroundColor(Color(nsColor: InterStatus.success))
                    .padding(.horizontal, InterSpacing.x2)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color(nsColor: InterStatus.success).opacity(0.12)))
            } else {
                Button(action: { account.revokeSession(session) }) {
                    Text("Revoke")
                        .font(InterFont.swiftUI(11, .semibold))
                        .foregroundColor(Color(nsColor: InterStatus.danger))
                        .padding(.horizontal, InterSpacing.x2)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                            .strokeBorder(Color(nsColor: InterStatus.danger).opacity(0.4), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .handCursor()
            }
        }
        .padding(.horizontal, InterSpacing.x3)
        .padding(.vertical, InterSpacing.x2_5)
    }

    private var dangerZone: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x2) {
            HStack(spacing: InterSpacing.x1_5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                Text("Danger Zone")
                    .font(InterFont.swiftUI(13, .semibold))
            }
            .foregroundColor(Color(nsColor: InterStatus.danger))

            Text("Permanently deletes your account and all data. This cannot be undone.")
                .font(InterFont.swiftUI(11))
                .foregroundColor(Color(nsColor: InterStatus.danger).opacity(0.85))

            SettingsSecureField(placeholder: "Confirm with your password", text: $account.deletePassword)

            if let err = account.deleteError { InterBanner(err, variant: .error) }

            InterButton("Delete Account…", variant: .dangerOutline, size: .compact,
                        isLoading: account.isDeletingAccount,
                        enabled: account.canDeleteAccount,
                        action: { account.deleteAccount() })
        }
        .padding(InterSpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: InterRadius.xl, style: .continuous)
                .fill(Color(nsColor: InterStatus.danger).opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: InterRadius.xl, style: .continuous)
                    .strokeBorder(Color(nsColor: InterStatus.danger).opacity(0.3), lineWidth: 1))
        )
    }

    // MARK: - Calendar Sync

    private var calendarTab: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x2) {
            Text("Connect a calendar so scheduled meetings sync automatically.")
                .font(InterFont.swiftUI(12))
                .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                .padding(.bottom, InterSpacing.x1)

            // Flat rows + divider — one surface.
            calendarRow("Google Calendar", connected: account.googleConnected, provider: "google")
            Divider().overlay(Color(nsColor: InterColor.border).opacity(0.6))
                .padding(.leading, 30)
            calendarRow("Outlook Calendar", connected: account.outlookConnected, provider: "outlook")

            if let err = account.calendarError { InterBanner(err, variant: .error) }
        }
        .frame(maxWidth: 460, alignment: .leading)
    }

    private func calendarRow(_ title: String, connected: Bool?, provider: String) -> some View {
        HStack(spacing: InterSpacing.x3) {
            Image(systemName: "calendar")
                .font(.system(size: 14))
                .foregroundColor(Color(nsColor: InterColor.primary))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(InterFont.swiftUI(13, .medium))
                    .foregroundColor(Color(nsColor: InterColor.foreground))
                Text(connected == nil ? "Checking…" : (connected! ? "Connected" : "Not connected"))
                    .font(InterFont.swiftUI(10))
                    .foregroundColor(connected == true
                        ? Color(nsColor: InterStatus.success)
                        : Color(nsColor: InterColor.mutedForeground))
            }
            Spacer(minLength: InterSpacing.x2)
            InterButton(connected == true ? "Disconnect" : "Connect",
                        variant: connected == true ? .secondary : .primary,
                        size: .compact,
                        enabled: connected != nil && !account.calendarBusy,
                        action: { account.toggleCalendar(provider: provider, isConnected: connected == true) })
        }
        .padding(.vertical, InterSpacing.x2_5)
    }

    // MARK: - Meeting Defaults

    private var meetingDefaultsTab: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x2) {
            Text("These settings become the defaults for every new meeting. You can still adjust them per-meeting when starting or scheduling.")
                .font(InterFont.swiftUI(11))
                .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                .padding(.bottom, InterSpacing.x1)

            sectionLabel("Participants")
            toggleRow("Mute mic after joining", subtitle: "Everyone joins with their mic off.",
                      isOn: $defaults.muteOnJoin)
            toggleRow("Turn off camera after joining", subtitle: "Everyone joins with their camera off.",
                      isOn: $defaults.cameraOffOnJoin)
            toggleRow("Allow unmuting", subtitle: "Participants can unmute without host permission.",
                      isOn: $defaults.allowUnmuting)

            sectionLabel("Security")
            toggleRow("Enable waiting room (Lobby)", subtitle: "Participants must be admitted by the host.",
                      isOn: $defaults.lobbyEnabled)
            toggleRow("Allow join before host", subtitle: "Participants can enter before you arrive.",
                      isOn: $defaults.joinBeforeHost)

            sectionLabel("Chat & Sharing")
            pickerRow("Chat permissions", selection: $defaults.chatPermissions, options: [
                (InterChatPermissionsEveryone, "Everyone"),
                (InterChatPermissionsHostOnly, "Host Only"),
                (InterChatPermissionsDisabled, "Disabled"),
            ])
            pickerRow("Screen sharing", selection: $defaults.sharingPermissions, options: [
                (InterSharingPermissionsHostOnly, "Host Only"),
                (InterSharingPermissionsEveryone, "Everyone"),
                (InterSharingPermissionsRequest, "Request to Share"),
            ])
            pickerRow("Share takeover", selection: $defaults.shareConflictPolicy, options: [
                (InterSharingConflictOneAtATime, "One at a time"),
                (InterSharingConflictHostCanPreempt, "Host can take over"),
                (InterSharingConflictAnyCanPreempt, "Anyone can take over"),
            ])

            sectionLabel("Recording (Pro)")
            if !defaults.isPaidTier {
                Text("✦ Requires a Pro or Hiring subscription")
                    .font(InterFont.swiftUI(11))
                    .foregroundColor(Color(nsColor: InterStatus.warning))
                    .padding(.horizontal, InterSpacing.x3)
                    .padding(.vertical, InterSpacing.x2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                        .fill(Color(nsColor: InterStatus.warning).opacity(0.10)))
            }
            Group {
                toggleRow("Auto-record to cloud", subtitle: "Start cloud recording when you join.",
                          isOn: $defaults.autoRecord, enabled: defaults.isPaidTier)
                toggleRow("Auto-transcript", subtitle: "Start AI transcription when you join.",
                          isOn: $defaults.autoTranscript, enabled: defaults.isPaidTier)
                toggleRow("Allow co-host local recording", subtitle: "Co-hosts may record to their own machine.",
                          isOn: $defaults.allowCoHostLocalRecording, enabled: defaults.isPaidTier)
            }
            .opacity(defaults.isPaidTier ? 1 : 0.55)

            if let msg = defaults.statusMessage { InterBanner(msg, variant: .success) }

            HStack {
                Spacer()
                InterButton("Save defaults", variant: .primary, size: .medium,
                            action: { defaults.save() })
            }
            .padding(.top, InterSpacing.x2)
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    // MARK: - Video / Audio / Background

    private var videoTab: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x3) {
            field("Camera") {
                InterSelect(selection: $devices.selectedCameraID,
                            options: devices.cameras.map { ($0.id, $0.name) })
            }
            Text("Your default camera. Applies the next time a meeting starts — switching devices during a call happens from the in-call controls.")
                .font(InterFont.swiftUI(11))
                .foregroundColor(Color(nsColor: InterColor.mutedForeground))
        }
        .frame(maxWidth: 420, alignment: .leading)
    }

    private var audioTab: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x3) {
            field("Microphone") {
                InterSelect(selection: $devices.selectedMicrophoneID,
                            options: devices.microphones.map { ($0.id, $0.name) })
            }
            field("Speaker") {
                Text("System default — change it in macOS Sound settings")
                    .font(InterFont.swiftUI(InterFont.Size.secondary))
                    .foregroundColor(Color(nsColor: InterColor.mutedForeground))
            }
            Text("Your default microphone. Applies the next time a meeting starts — switching devices during a call happens from the in-call controls.")
                .font(InterFont.swiftUI(11))
                .foregroundColor(Color(nsColor: InterColor.mutedForeground))
        }
        .frame(maxWidth: 420, alignment: .leading)
    }

    private var backgroundTab: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x3) {
            Text("Choose a virtual background or blur.")
                .font(InterFont.swiftUI(12))
                .foregroundColor(Color(nsColor: InterColor.mutedForeground))
            HStack(spacing: InterSpacing.x2) {
                ForEach(["None", "Blur", "Office", "Nature"], id: \.self) { name in
                    RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                        .fill(Color(nsColor: InterColor.secondary))
                        .frame(width: 96, height: 54)
                        .overlay(Text(name)
                            .font(InterFont.swiftUI(11, .medium))
                            .foregroundColor(Color(nsColor: InterColor.mutedForeground)))
                }
            }
            .opacity(0.55)
            InterBanner("Virtual backgrounds will be available soon.", variant: .info)
        }
        .frame(maxWidth: 460, alignment: .leading)
    }

    // MARK: - Recording

    private var recordingTab: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x3) {
            field("Save local recordings to") {
                HStack(spacing: InterSpacing.x2) {
                    HStack(spacing: InterSpacing.x2) {
                        Image(systemName: "folder")
                            .font(.system(size: 12))
                            .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                        Text(devices.recordingDirectoryPath
                                .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Color(nsColor: InterColor.foreground))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .interFieldChrome(isFocused: false)
                    InterButton("Choose…", variant: .secondary, size: .medium,
                                action: { chooseRecordingFolder() })
                }
            }
            if devices.recordingDirectoryIsCustom {
                Button(action: { devices.resetRecordingDirectory() }) {
                    Text("Reset to default (~/Documents/Inter Recordings)")
                        .font(InterFont.swiftUI(11, .medium))
                        .foregroundColor(Color(nsColor: InterColor.primary))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .handCursor()
            }
            Text("Where local recordings are saved. Cloud recordings are stored in your account and managed from View Recordings.")
                .font(InterFont.swiftUI(11))
                .foregroundColor(Color(nsColor: InterColor.mutedForeground))
        }
        .frame(maxWidth: 480, alignment: .leading)
    }

    private func chooseRecordingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder for local recordings"
        if panel.runModal() == .OK, let url = panel.url {
            devices.setRecordingDirectory(url)
        }
    }

    // MARK: - Shared bits

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: InterSpacing.x1_5) {
            Text(label)
                .font(InterFont.swiftUI(12, .semibold))
                .foregroundColor(Color(nsColor: InterColor.foreground))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(InterFont.swiftUI(9, .bold))
            .tracking(1.2)
            .foregroundColor(Color(nsColor: InterColor.mutedForeground))
            .padding(.top, InterSpacing.x2)
    }

    private func toggleRow(_ title: String, subtitle: String, isOn: Binding<Bool>,
                           enabled: Bool = true) -> some View {
        HStack(alignment: .center, spacing: InterSpacing.x3) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(InterFont.swiftUI(13))
                    .foregroundColor(Color(nsColor: InterColor.foreground))
                Text(subtitle)
                    .font(InterFont.swiftUI(10))
                    .foregroundColor(Color(nsColor: InterColor.mutedForeground))
            }
            Spacer(minLength: InterSpacing.x2)
            InterToggle(isOn: isOn, enabled: enabled)
        }
        .padding(.vertical, InterSpacing.x2)
    }

    private func pickerRow(_ title: String, selection: Binding<String>,
                           options: [(value: String, label: String)]) -> some View {
        HStack(spacing: InterSpacing.x3) {
            Text(title)
                .font(InterFont.swiftUI(13))
                .foregroundColor(Color(nsColor: InterColor.foreground))
            Spacer(minLength: InterSpacing.x2)
            InterSelect(selection: selection, options: options, fillWidth: false)
        }
        .padding(.vertical, InterSpacing.x2)
    }

    /// "System default (…)" + every IANA timezone for the profile select.
    private var timezoneSelectOptions: [(value: String, label: String)] {
        [("", AccountSettingsViewModel.timezoneLabel(""))]
            + AccountSettingsViewModel.timezoneOptions.map { ($0, $0) }
    }
}

// MARK: - Secure field with internal reveal state

private struct SettingsSecureField: View {
    let placeholder: String
    @Binding var text: String
    var hasError: Bool = false
    @State private var revealed = false

    var body: some View {
        InterSecureInputField(
            placeholder: placeholder,
            text: $text,
            isRevealed: revealed,
            hasError: hasError,
            onToggleReveal: { revealed.toggle() }
        )
    }
}
