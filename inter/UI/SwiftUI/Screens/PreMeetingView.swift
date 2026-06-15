//
//  PreMeetingView.swift
//  inter
//
//  SwiftUI pre-meeting sheet. Visual language follows the design handoff
//  (ref_pre-meeting_{dark,light}.png / PreMeetingMock.tsx): a header zone on
//  muted with title + subtitle (violet "FIRST-TIME SETUP" pill on first run),
//  a scrollable body of sections — GENERAL / PARTICIPANT CONTROLS / SECURITY /
//  CHAT & SHARING / RECORDING & TRANSCRIPTION — built from check rows (custom
//  violet checkbox + optional hint), select rows (label + bordered menu), the
//  conditional password reveal, and an amber pro callout gating the recording
//  group; and a muted footer with Cancel + the violet primary CTA (⏎).
//
//  The compact (returning-host) presentation keeps the live app's behavior —
//  editable meeting name + opt-in password — and adopts the mock's summary
//  card and "Edit Settings" reveal (the legacy "Advanced ▸"). The defaults
//  editor omits the per-meeting rows entirely (legacy parity).
//
//  Hosted in windows that pin DarkAqua, so theme tokens resolve dark.
//

import SwiftUI

struct PreMeetingView: View {
    @ObservedObject var viewModel: PreMeetingViewModel
    @State private var passwordRevealed = false
    @State private var showPasswordError = false

    var body: some View {
        VStack(spacing: 0) {
            header
            body_
            footer
        }
        .background(Color(nsColor: InterColor.card))
        .interResignsFocusOnBackgroundTap()
        // A blocked submit (empty required password) lights the field's error
        // border; it clears as soon as the password becomes valid.
        .onChange(of: viewModel.passwordErrorTick) { _ in showPasswordError = true }
        .onChange(of: viewModel.passwordInvalid) { invalid in
            if !invalid { showPasswordError = false }
        }
    }

    // MARK: - Header (muted zone, title + subtitle + first-time pill)

    private var header: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x2) {
            if viewModel.mode == .fullSetup {
                HStack(spacing: InterSpacing.x2) {
                    HStack(spacing: InterSpacing.x1) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 8, weight: .bold))
                        Text("FIRST-TIME SETUP")
                            .font(InterFont.swiftUI(InterFont.Size.dense10, .bold))
                            .tracking(1.2)
                    }
                    .foregroundColor(Color(nsColor: InterColor.primary))
                    .padding(.horizontal, InterSpacing.x2)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color(nsColor: InterColor.primary).opacity(0.16)))
                    Text("These become your saved defaults.")
                        .font(InterFont.swiftUI(InterFont.Size.dense11))
                        .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.titleText)
                    .font(InterFont.swiftUI(16, .semibold))
                    .foregroundColor(Color(nsColor: InterColor.foreground))
                Text(subtitleText)
                    .font(InterFont.swiftUI(InterFont.Size.caption))
                    .foregroundColor(Color(nsColor: InterColor.mutedForeground))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, InterSpacing.x6)
        .padding(.vertical, InterSpacing.x5)
        .background(Color(nsColor: InterColor.muted))
        .overlay(Rectangle().fill(Color(nsColor: InterColor.border)).frame(height: 1),
                 alignment: .bottom)
    }

    private var subtitleText: String {
        switch viewModel.mode {
        case .fullSetup:
            return "Configure once — the next time you start a meeting these will apply automatically."
        case .compact:
            return "Settings from your last session will be applied."
        case .defaultsEditor:
            return "Used by future meetings you host or schedule."
        }
    }

    // MARK: - Body (compact summary or full sections)

    @ViewBuilder
    private var body_: some View {
        if viewModel.showsCompactSummary {
            compactBody
        } else {
            fullBody
        }
    }

    // MARK: Compact (returning host)

    private var compactBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: InterSpacing.x4) {
                VStack(alignment: .leading, spacing: InterSpacing.x1_5) {
                    fieldLabel("Meeting name")
                    InterInputField(placeholder: "Meeting name", text: $viewModel.meetingName)
                }

                checkRow("Require meeting password", isOn: $viewModel.requirePassword)
                if viewModel.requirePassword {
                    passwordField
                        .padding(.leading, 16 + InterSpacing.x3) // align under the checkbox label (pl-7)
                }

                summaryCard

                Text("These were saved from your previous session. Go to Settings → Meeting Defaults to update them.")
                    .font(InterFont.swiftUI(InterFont.Size.caption))
                    .foregroundColor(Color(nsColor: InterColor.mutedForeground))
            }
            .padding(.horizontal, InterSpacing.x6)
            .padding(.vertical, InterSpacing.x5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var summaryCard: some View {
        VStack(spacing: InterSpacing.x2) {
            ForEach(viewModel.summaryRows, id: \.label) { row in
                HStack {
                    Text(row.label)
                        .font(InterFont.swiftUI(InterFont.Size.secondary))
                        .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                    Spacer(minLength: InterSpacing.x4)
                    Text(row.value)
                        .font(InterFont.swiftUI(InterFont.Size.secondary, .medium))
                        .foregroundColor(row.positive
                            ? Color(nsColor: InterStatus.success)
                            : Color(nsColor: InterColor.foreground))
                }
            }
        }
        .padding(InterSpacing.x4)
        .background(
            RoundedRectangle(cornerRadius: InterRadius.xl, style: .continuous)
                .fill(Color(nsColor: InterColor.muted))
                .overlay(RoundedRectangle(cornerRadius: InterRadius.xl, style: .continuous)
                    .strokeBorder(Color(nsColor: InterColor.border), lineWidth: 1))
        )
    }

    // MARK: Full sections

    private var fullBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if viewModel.showsPerMeetingFields {
                    sectionLabel("General", systemImage: nil)
                    VStack(alignment: .leading, spacing: InterSpacing.x1_5) {
                        fieldLabel("Meeting name")
                        InterInputField(placeholder: "Meeting name", text: $viewModel.meetingName)
                    }
                    .padding(.bottom, InterSpacing.x2)
                    sectionDivider
                }

                sectionLabel("Participant Controls", systemImage: "mic")
                checkRow("Mute mic after joining", isOn: $viewModel.muteOnJoin)
                checkRow("Turn off camera after joining", isOn: $viewModel.cameraOffOnJoin)
                checkRow("Allow unmuting",
                         hint: "Participants can unmute themselves without host permission.",
                         isOn: $viewModel.allowUnmuting)
                sectionDivider

                sectionLabel("Security", systemImage: "lock")
                checkRow("Enable waiting room (Lobby)",
                         hint: "Participants must be admitted by the host.",
                         isOn: $viewModel.lobbyEnabled)
                if viewModel.showsPerMeetingFields {
                    checkRow("Require meeting password", isOn: $viewModel.requirePassword)
                    if viewModel.requirePassword {
                        passwordField
                            .padding(.leading, 16 + InterSpacing.x3) // align under the checkbox label (pl-7)
                            .padding(.bottom, InterSpacing.x1)
                    }
                }
                checkRow("Allow participants to join before host", isOn: $viewModel.joinBeforeHost)
                sectionDivider

                sectionLabel("Chat & Sharing", systemImage: "message")
                selectRow("Chat permissions", selection: $viewModel.chatPermissions, options: [
                    (InterChatPermissionsEveryone, "Everyone"),
                    (InterChatPermissionsHostOnly, "Host Only"),
                    (InterChatPermissionsDisabled, "Disabled"),
                ])
                selectRow("Screen sharing", selection: $viewModel.sharingPermissions, options: [
                    (InterSharingPermissionsHostOnly, "Host Only"),
                    (InterSharingPermissionsEveryone, "Everyone"),
                    (InterSharingPermissionsRequest, "Request to Share"),
                ])
                selectRow("Share takeover", selection: $viewModel.shareConflictPolicy, options: [
                    (InterSharingConflictOneAtATime, "One at a Time"),
                    (InterSharingConflictHostCanPreempt, "Host Can Take Over"),
                    (InterSharingConflictAnyCanPreempt, "Anyone Can Take Over"),
                ])
                sectionDivider

                sectionLabel("Recording & Transcription", systemImage: "cloud")
                if !viewModel.isPro {
                    proCallout
                        .padding(.bottom, InterSpacing.x2)
                }
                Group {
                    checkRow("Auto-record to cloud", isOn: $viewModel.autoRecord)
                    checkRow("Auto-transcript", isOn: $viewModel.autoTranscript)
                    checkRow("Allow co-host local recording", isOn: $viewModel.allowCoHostLocalRecording)
                }
                .disabled(!viewModel.isPro)
                .opacity(viewModel.isPro ? 1 : 0.5)
            }
            .padding(.horizontal, InterSpacing.x6)
            .padding(.vertical, InterSpacing.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer (Cancel + primary CTA with ⏎ hint)

    private var footer: some View {
        HStack(spacing: InterSpacing.x3) {
            if viewModel.showsCompactSummary {
                InterButton("Edit Settings", variant: .secondary, size: .medium,
                            action: { viewModel.expandAdvanced() })
            }
            Spacer(minLength: 0)
            Button(action: { viewModel.cancel() }) {
                Text(viewModel.cancelTitle)
                    .font(InterFont.swiftUI(InterFont.Size.secondary, .medium))
                    .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                    .padding(.horizontal, InterSpacing.x4)
                    .frame(height: InterControl.secondaryHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()
            .keyboardShortcut(.cancelAction)

            Button(action: { viewModel.submit() }) {
                HStack(spacing: InterSpacing.x2) {
                    Text(viewModel.submitTitle)
                        .font(InterFont.swiftUI(InterFont.Size.secondary, .semibold))
                    Text("⏎")
                        .font(InterFont.swiftUI(InterFont.Size.dense10, .medium))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(.white.opacity(0.22)))
                }
                .foregroundColor(.white)
                .padding(.horizontal, InterSpacing.x5)
                .frame(height: InterControl.secondaryHeight)
                .background(RoundedRectangle(cornerRadius: InterRadius.lg, style: .continuous)
                    .fill(Color(nsColor: InterColor.primary)
                        .opacity(viewModel.passwordInvalid ? 0.5 : 1)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()
            .keyboardShortcut(.defaultAction) // ⏎ starts (inventory: "Start Meeting (⏎)")
        }
        .padding(.horizontal, InterSpacing.x6)
        .padding(.vertical, InterSpacing.x4)
        .background(Color(nsColor: InterColor.muted))
        .overlay(Rectangle().fill(Color(nsColor: InterColor.border)).frame(height: 1),
                 alignment: .top)
    }

    // MARK: - Pieces

    private var passwordField: some View {
        InterSecureInputField(placeholder: "Meeting password",
                              text: $viewModel.password,
                              isRevealed: passwordRevealed,
                              hasError: showPasswordError && viewModel.passwordInvalid,
                              onToggleReveal: { passwordRevealed.toggle() })
    }

    private var proCallout: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("✦ Requires Pro or Pro+ subscription")
                .font(InterFont.swiftUI(InterFont.Size.caption, .semibold))
                .foregroundColor(Color(nsColor: InterStatus.warning))
            Text("Upgrade to unlock cloud recording and transcription.")
                .font(InterFont.swiftUI(InterFont.Size.dense11))
                .foregroundColor(Color(nsColor: InterStatus.warning).opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(InterSpacing.x3)
        .background(
            RoundedRectangle(cornerRadius: InterRadius.xl, style: .continuous)
                .fill(Color(nsColor: InterStatus.warning).opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: InterRadius.xl, style: .continuous)
                    .strokeBorder(Color(nsColor: InterStatus.warning).opacity(0.30), lineWidth: 1))
        )
    }

    private func sectionLabel(_ title: String, systemImage: String?) -> some View {
        HStack(spacing: InterSpacing.x1_5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(title.uppercased())
                .font(InterFont.swiftUI(InterFont.Size.dense10, .bold))
                .tracking(1.5)
        }
        .foregroundColor(Color(nsColor: InterColor.mutedForeground))
        .padding(.top, InterSpacing.x1)
        .padding(.bottom, InterSpacing.x1_5)
    }

    private var sectionDivider: some View {
        Divider()
            .overlay(Color(nsColor: InterColor.border))
            .padding(.vertical, InterSpacing.x3)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(InterFont.swiftUI(InterFont.Size.caption, .medium))
            .foregroundColor(Color(nsColor: InterColor.mutedForeground))
    }

    /// Mock CheckRow: custom 16pt checkbox (violet when on) + label + optional hint.
    private func checkRow(_ label: String, hint: String? = nil,
                          isOn: Binding<Bool>) -> some View {
        Button(action: { isOn.wrappedValue.toggle() }) {
            HStack(alignment: .top, spacing: InterSpacing.x3) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isOn.wrappedValue ? Color(nsColor: InterColor.primary) : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(isOn.wrappedValue
                            ? Color(nsColor: InterColor.primary)
                            : Color(nsColor: InterColor.border), lineWidth: 1))
                    .overlay {
                        if isOn.wrappedValue {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(width: 16, height: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(InterFont.swiftUI(InterFont.Size.secondary))
                        .foregroundColor(Color(nsColor: InterColor.foreground))
                    if let hint {
                        Text(hint)
                            .font(InterFont.swiftUI(InterFont.Size.caption))
                            .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, InterSpacing.x2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .animation(.easeInOut(duration: 0.12), value: isOn.wrappedValue)
    }

    /// Mock SelectRow: label left + bordered menu right.
    private func selectRow(_ label: String, selection: Binding<String>,
                           options: [(key: String, title: String)]) -> some View {
        HStack {
            Text(label)
                .font(InterFont.swiftUI(InterFont.Size.secondary))
                .foregroundColor(Color(nsColor: InterColor.foreground))
            Spacer(minLength: InterSpacing.x4)
            Menu {
                ForEach(options, id: \.key) { option in
                    Button(option.title) { selection.wrappedValue = option.key }
                }
            } label: {
                HStack(spacing: InterSpacing.x1_5) {
                    Text(options.first(where: { $0.key == selection.wrappedValue })?.title
                         ?? options.first?.title ?? "")
                        .font(InterFont.swiftUI(InterFont.Size.secondary))
                        .foregroundColor(Color(nsColor: InterColor.foreground))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color(nsColor: InterColor.mutedForeground))
                }
                .padding(.horizontal, InterSpacing.x3)
                .frame(height: InterControl.compactHeight)
                .background(RoundedRectangle(cornerRadius: InterRadius.lg, style: .continuous)
                    .fill(Color(nsColor: InterColor.card))
                    .overlay(RoundedRectangle(cornerRadius: InterRadius.lg, style: .continuous)
                        .strokeBorder(Color(nsColor: InterColor.border), lineWidth: 1)))
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .handCursor()
        }
        .padding(.vertical, InterSpacing.x2)
    }
}
