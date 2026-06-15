//
//  GreenRoomView.swift
//  inter
//
//  SwiftUI green room (pre-join device check). Visual language follows the
//  design handoff (ref_green-room_{dark,light}.png / GreenRoomMock.tsx): a
//  full-stage two-pane layout — live camera preview (AppKit capture preview
//  embedded via NSViewRepresentable) with a name overlay and Blur-bg button
//  on the left; AUDIO & VIDEO device rows, a device-test drawer, the SESSION
//  section and the action stack on the right.
//
//  This is a §7.5 call surface: fixed-dark stage tokens (InterColor.stage*)
//  and white/neutral text in BOTH app appearances — never theme tokens.
//
//  Role differences (live flow wins over the mock):
//    • hostCreate: SESSION = editable meeting name + opt-in password (no room
//      code exists before /room/create); CTA "Start Meeting"; Meeting Settings
//      button with "Using default settings".
//    • join: SESSION = the typed room code (mono, spaced); CTA "Join Now".
//    • hostInterview: no session fields; CTA "Start Interview".
//  Blur-bg is UI-only until the capture pipeline gains a blur stage — tapping
//  shows "not available yet" (TODO(blur-infra) in the view model).
//

import AppKit
import SwiftUI

/// Wraps the AppKit capture-preview container the bridge owns.
private struct CapturePreviewSurface: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct GreenRoomView: View {
    @ObservedObject var viewModel: GreenRoomViewModel
    /// The NSView the bridge attaches the AVCaptureSession preview layer to.
    let previewContainer: NSView

    private let panelWidth: CGFloat = 280

    var body: some View {
        HStack(spacing: 0) {
            previewPane
            rightPanel
        }
        .background(Color(nsColor: InterColor.stageSurface))
        .interResignsFocusOnBackgroundTap()
    }

    // MARK: - Left · camera preview

    private var previewPane: some View {
        ZStack {
            Color(nsColor: InterColor.stage)

            CapturePreviewSurface(view: previewContainer)
                .opacity(viewModel.camOn ? 1 : 0)

            if !viewModel.camOn {
                cameraOffState
            }

            // Name overlay (bottom scrim) — your display name, both roles.
            VStack {
                Spacer()
                nameOverlay
            }

            // Blur bg (top-right) + transient unavailable note.
            VStack {
                HStack {
                    Spacer()
                    blurButton
                }
                if let note = viewModel.unavailableNote {
                    HStack {
                        Spacer()
                        Text(note)
                            .font(InterFont.swiftUI(InterFont.Size.dense11, .medium))
                            .foregroundColor(Color(nsColor: NSColor(hex: 0xE5E5E5)))
                            .padding(.horizontal, InterSpacing.x2_5)
                            .padding(.vertical, InterSpacing.x1)
                            .background(Capsule().fill(.black.opacity(0.65)))
                            .transition(.opacity)
                    }
                }
                Spacer()
            }
            .padding(InterSpacing.x3)
            .animation(.easeInOut(duration: 0.15), value: viewModel.unavailableNote)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var cameraOffState: some View {
        Group {
            if viewModel.displayName.trimmingCharacters(in: .whitespaces).isEmpty {
                VStack(spacing: InterSpacing.x2) {
                    Image(systemName: "video.slash.fill")
                        .font(.system(size: 30, weight: .medium))
                    Text("Camera is off")
                        .font(InterFont.swiftUI(InterFont.Size.secondary))
                }
                .foregroundColor(Color(nsColor: NSColor(hex: 0x525252)))
            } else {
                Text(GreenRoomViewModel.initials(for: viewModel.displayName))
                    .font(InterFont.swiftUI(36, .semibold))
                    .foregroundColor(Color(nsColor: NSColor(hex: 0xE5E5E5)))
                    .frame(width: 96, height: 96)
                    .background(Circle().fill(Color(nsColor: NSColor(hex: 0x404040))))
            }
        }
    }

    private var nameOverlay: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Your name", text: $viewModel.displayName)
                .textFieldStyle(.plain)
                .font(InterFont.swiftUI(InterFont.Size.secondary, .semibold))
                .foregroundColor(.white)
            Rectangle()
                .fill(.white.opacity(0.30))
                .frame(height: 1)
                .padding(.top, 3)
        }
        .padding(.horizontal, InterSpacing.x4)
        .padding(.vertical, InterSpacing.x3)
        .background(
            LinearGradient(colors: [.black.opacity(0.8), .clear],
                           startPoint: .bottom, endPoint: .top)
        )
    }

    private var blurButton: some View {
        Button(action: { viewModel.blurBackgroundTapped() }) {
            Text("Blur bg")
                .font(InterFont.swiftUI(InterFont.Size.dense11, .medium))
                .foregroundColor(Color(nsColor: NSColor(hex: 0xD4D4D4)))
                .padding(.horizontal, InterSpacing.x2_5)
                .padding(.vertical, InterSpacing.x1)
                .background(RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                    .fill(.black.opacity(0.5)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .help("Background blur isn't available yet")
    }

    // MARK: - Right · device panel

    private var rightPanel: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: InterSpacing.x2) {
                    HStack {
                        panelHeading("Audio & Video")
                        Spacer(minLength: 0)
                        encryptedPill
                    }
                    .padding(.bottom, InterSpacing.x1)

                    deviceRow(icon: viewModel.micOn ? "mic.fill" : "mic.slash.fill",
                              label: "Microphone",
                              device: GreenRoomViewModel.deviceName(for: viewModel.selectedMicID,
                                                                    in: viewModel.microphones),
                              on: viewModel.micOn,
                              onToggle: { viewModel.toggleMic() },
                              changeMenu: AnyView(deviceMenu(devices: viewModel.microphones,
                                                             selected: viewModel.selectedMicID,
                                                             onSelect: { viewModel.selectMic($0) })))

                    deviceRow(icon: viewModel.camOn ? "video.fill" : "video.slash.fill",
                              label: "Camera",
                              device: GreenRoomViewModel.deviceName(for: viewModel.selectedCameraID,
                                                                    in: viewModel.cameras),
                              on: viewModel.camOn,
                              onToggle: { viewModel.toggleCam() },
                              changeMenu: AnyView(deviceMenu(devices: viewModel.cameras,
                                                             selected: viewModel.selectedCameraID,
                                                             onSelect: { viewModel.selectCamera($0) })))

                    // Speaker — system-routed output; read-only (no Change).
                    deviceRow(icon: "speaker.wave.2.fill",
                              label: "Speaker",
                              device: viewModel.speakerName,
                              on: true, onToggle: nil,
                              changeMenu: nil)

                    deviceTestSection

                    Divider().overlay(.white.opacity(0.05))
                        .padding(.vertical, InterSpacing.x1)

                    panelHeading("Session")
                    sessionSection
                    networkRow
                }
                .padding(InterSpacing.x4)
            }

            actionFooter
        }
        .frame(width: panelWidth)
        .background(Color(nsColor: InterColor.stageSurface))
        .overlay(Rectangle().fill(.white.opacity(0.05)).frame(width: 1), alignment: .leading)
    }

    private func panelHeading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(InterFont.swiftUI(InterFont.Size.dense11, .semibold))
            .tracking(0.8)
            .foregroundColor(Color(nsColor: NSColor(hex: 0x737373)))
    }

    private var encryptedPill: some View {
        HStack(spacing: InterSpacing.x1) {
            Image(systemName: "shield.fill")
                .font(.system(size: 9, weight: .semibold))
            Text("Encrypted")
                .font(InterFont.swiftUI(InterFont.Size.dense10, .semibold))
        }
        .foregroundColor(Color(nsColor: InterStatus.success))
        .padding(.horizontal, InterSpacing.x1_5)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
            .fill(Color(nsColor: InterStatus.success).opacity(0.10)))
        .help("Media is transport-encrypted (TLS + SRTP)")
    }

    // MARK: Device rows

    @ViewBuilder
    private func deviceMenu(devices: [MediaDeviceOption], selected: String,
                            onSelect: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(devices) { device in
                Button(action: { onSelect(device.id) }) {
                    if device.id == selected {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
        } label: {
            HStack(spacing: InterSpacing.x1) {
                Text("Change")
                    .font(InterFont.swiftUI(InterFont.Size.dense11))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundColor(Color(nsColor: NSColor(hex: 0xA3A3A3)))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .handCursor()
    }

    private func deviceRow(icon: String, label: String, device: String, on: Bool,
                           onToggle: (() -> Void)?,
                           changeMenu: AnyView?) -> some View {
        HStack(spacing: InterSpacing.x3) {
            // On/off circle — red when off; static when not toggleable.
            Group {
                if let onToggle {
                    Button(action: onToggle) {
                        deviceCircle(icon: icon, on: on)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .handCursor()
                    .help(on ? "Turn off" : "Turn on")
                } else {
                    deviceCircle(icon: icon, on: on)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(InterFont.swiftUI(InterFont.Size.dense11))
                    .foregroundColor(Color(nsColor: NSColor(hex: 0x737373)))
                Text(device)
                    .font(InterFont.swiftUI(InterFont.Size.caption))
                    .foregroundColor(Color(nsColor: NSColor(hex: 0xE5E5E5)))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let changeMenu {
                changeMenu
            }
        }
        .padding(.horizontal, InterSpacing.x3)
        .padding(.vertical, InterSpacing.x2_5)
        .background(RoundedRectangle(cornerRadius: InterRadius.lg, style: .continuous)
            .fill(.white.opacity(0.06)))
    }

    private func deviceCircle(icon: String, on: Bool) -> some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white)
            .frame(width: 36, height: 36)
            .background(Circle().fill(on
                ? Color(nsColor: InterColor.stageElevated)
                : Color(nsColor: InterStatus.danger)))
    }

    // MARK: Device test drawer

    private var deviceTestSection: some View {
        VStack(alignment: .leading, spacing: InterSpacing.x2) {
            Button(action: { viewModel.toggleDeviceTest() }) {
                Text(viewModel.deviceTestOpen ? "Done testing" : "Test speaker & microphone…")
                    .font(InterFont.swiftUI(InterFont.Size.dense11))
                    .foregroundColor(Color(nsColor: InterColor.primary))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()

            if viewModel.deviceTestOpen {
                VStack(alignment: .leading, spacing: InterSpacing.x2) {
                    // Mic level meter — speak and watch the bar.
                    HStack(spacing: InterSpacing.x2) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color(nsColor: NSColor(hex: 0xA3A3A3)))
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.10))
                                Capsule()
                                    .fill(Color(nsColor: InterStatus.success))
                                    .frame(width: max(2, geo.size.width * viewModel.micLevel))
                                    .animation(.linear(duration: 0.08), value: viewModel.micLevel)
                            }
                        }
                        .frame(height: 6)
                    }
                    Text("Speak — the bar should move.")
                        .font(InterFont.swiftUI(InterFont.Size.dense10))
                        .foregroundColor(Color(nsColor: NSColor(hex: 0x737373)))

                    Button(action: { viewModel.toggleSpeakerTest() }) {
                        HStack(spacing: InterSpacing.x1_5) {
                            Image(systemName: viewModel.speakerTestPlaying ? "stop.fill" : "play.fill")
                                .font(.system(size: 9, weight: .semibold))
                            Text(viewModel.speakerTestPlaying ? "Stop test sound" : "Play test sound")
                                .font(InterFont.swiftUI(InterFont.Size.dense11, .semibold))
                        }
                        .foregroundColor(Color(nsColor: NSColor(hex: 0xE5E5E5)))
                        .padding(.horizontal, InterSpacing.x2_5)
                        .padding(.vertical, InterSpacing.x1)
                        .background(RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                            .fill(.white.opacity(0.10)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .handCursor()
                }
                .padding(InterSpacing.x3)
                .background(RoundedRectangle(cornerRadius: InterRadius.lg, style: .continuous)
                    .fill(.white.opacity(0.04)))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: viewModel.deviceTestOpen)
    }

    // MARK: Session section (role-dependent)

    @ViewBuilder
    private var sessionSection: some View {
        switch viewModel.role {
        case .join(let code), .scheduledStart(let code):
            Text(GreenRoomViewModel.spacedCode(code))
                .font(.system(size: 14, design: .monospaced))
                .tracking(2)
                .foregroundColor(Color(nsColor: NSColor(hex: 0xE5E5E5)))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, InterSpacing.x3)
                .padding(.vertical, InterSpacing.x2)
                .background(RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                    .fill(.white.opacity(0.06)))

        case .hostCreate:
            VStack(alignment: .leading, spacing: InterSpacing.x2) {
                stageField("Meeting name", text: $viewModel.meetingName)
                Toggle(isOn: $viewModel.requirePassword) {
                    Text("Require a password")
                        .font(InterFont.swiftUI(InterFont.Size.caption))
                        .foregroundColor(Color(nsColor: NSColor(hex: 0xD4D4D4)))
                }
                .toggleStyle(.checkbox)
                .handCursor()
                if viewModel.requirePassword {
                    stageField("Meeting password", text: $viewModel.password,
                               secure: true, error: viewModel.passwordInvalid)
                }
            }

        case .hostInterview:
            Text("Interview session — configured on connect.")
                .font(InterFont.swiftUI(InterFont.Size.dense11))
                .foregroundColor(Color(nsColor: NSColor(hex: 0x737373)))
        }
    }

    private func stageField(_ placeholder: String, text: Binding<String>,
                            secure: Bool = false, error: Bool = false) -> some View {
        Group {
            if secure {
                SecureField(placeholder, text: text)
            } else {
                TextField(placeholder, text: text)
            }
        }
        .textFieldStyle(.plain)
        .font(InterFont.swiftUI(InterFont.Size.caption))
        .foregroundColor(Color(nsColor: NSColor(hex: 0xE5E5E5)))
        .padding(.horizontal, InterSpacing.x3)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
            .fill(.white.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                .strokeBorder(error
                    ? Color(nsColor: InterStatus.danger)
                    : .white.opacity(0.10), lineWidth: 1)))
    }

    private var networkRow: some View {
        HStack(spacing: InterSpacing.x2) {
            Circle()
                .fill(networkDotColor)
                .frame(width: 8, height: 8)
            Text(viewModel.networkCaption)
                .font(InterFont.swiftUI(InterFont.Size.dense11))
                .foregroundColor(Color(nsColor: NSColor(hex: 0xA3A3A3)))
        }
        .padding(.top, InterSpacing.x1)
    }

    private var networkDotColor: Color {
        switch viewModel.networkState {
        case .checking:                 return Color(nsColor: NSColor(hex: 0x737373))
        case .reachable(let ms):        return ms < 400
            ? Color(nsColor: InterStatus.success)
            : Color(nsColor: InterStatus.warning)
        case .unreachable:              return Color(nsColor: InterStatus.danger)
        }
    }

    // MARK: Action footer

    private var actionFooter: some View {
        VStack(spacing: InterSpacing.x2) {
            if viewModel.showsMeetingSettings {
                Button(action: { viewModel.openMeetingSettings() }) {
                    VStack(spacing: 1) {
                        HStack(spacing: InterSpacing.x1_5) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Meeting Settings")
                                .font(InterFont.swiftUI(InterFont.Size.dense11, .semibold))
                        }
                        .foregroundColor(Color(nsColor: NSColor(hex: 0xA3A3A3)))
                        Text(viewModel.usingDefaultsCaption)
                            .font(InterFont.swiftUI(InterFont.Size.dense10))
                            .foregroundColor(Color(nsColor: NSColor(hex: 0x737373)))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: InterRadius.lg, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .handCursor()
            }

            Button(action: { viewModel.submitPrimary() }) {
                Text(viewModel.primaryTitle)
                    .font(InterFont.swiftUI(InterFont.Size.secondary, .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: InterControl.primaryHeight)
                    .background(RoundedRectangle(cornerRadius: InterRadius.lg, style: .continuous)
                        .fill(Color(nsColor: InterColor.primary)
                            .opacity(viewModel.canSubmit ? 1 : 0.5)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()
            .disabled(!viewModel.canSubmit)
            .keyboardShortcut(.defaultAction)

            Button(action: { viewModel.joinWithoutVideo() }) {
                Text(viewModel.withoutVideoTitle)
                    .font(InterFont.swiftUI(InterFont.Size.dense11))
                    .foregroundColor(Color(nsColor: NSColor(hex: 0x737373)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()
            .disabled(!viewModel.canSubmit)
        }
        .padding(InterSpacing.x4)
        .overlay(Rectangle().fill(.white.opacity(0.05)).frame(height: 1), alignment: .top)
    }
}
