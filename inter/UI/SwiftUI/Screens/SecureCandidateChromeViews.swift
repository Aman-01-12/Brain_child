//
//  SecureCandidateChromeViews.swift
//  inter
//
//  SwiftUI chrome for the secure interviewee (candidate) window — top status
//  bar and bottom control bar, per the secure-candidate mock. Stage FIXED-dark
//  tokens only (in-call surfaces are never appearance-aware). The stage view,
//  tool host (capture surface), and chat overlay remain AppKit.
//
//  Deliberate mock deviations (approved paranoid findings):
//   • No "E2E Encrypted" badge (#3 — transport encryption only; a stronger
//     claim would be false). The shield + "Secure Interview" reflects the
//     capture-protected kiosk that DOES exist.
//   • The share strip is selection-only; the explicit Share button is the only
//     publish trigger (#7).
//

import SwiftUI

// MARK: - Top status bar

struct SecureCandidateTopBarView: View {
    @ObservedObject var viewModel: SecureCandidateChromeViewModel

    var body: some View {
        HStack(spacing: InterSpacing.x3) {
            HStack(spacing: InterSpacing.x2) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(nsColor: InterColor.primary))
                Text("Secure Interview")
                    .font(InterFont.swiftUI(13, .semibold))
                    .foregroundColor(.white.opacity(0.92))
            }
            if !viewModel.roomCode.isEmpty {
                Text(viewModel.roomCode)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(1)
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, InterSpacing.x2)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: InterRadius.sm)
                        .fill(Color.white.opacity(0.08)))
            }
            if !viewModel.connectionStatusText.isEmpty {
                Text(viewModel.connectionStatusText)
                    .font(InterFont.swiftUI(11))
                    .foregroundColor(.white.opacity(0.5))
            }

            Spacer(minLength: InterSpacing.x3)

            if viewModel.recordingActive {
                recordingBadge
            }
            candidateBadge
            chatButton
        }
        .padding(.horizontal, InterSpacing.x4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: InterColor.stage))
    }

    /// REC — visible to the candidate whenever recording is signalled (#6:
    /// consent integrity; state comes only from the signal path).
    private var recordingBadge: some View {
        HStack(spacing: InterSpacing.x1) {
            Circle()
                .fill(Color(nsColor: InterStatus.danger))
                .frame(width: 7, height: 7)
            Text("REC")
                .font(InterFont.swiftUI(10, .bold))
                .tracking(0.8)
                .foregroundColor(Color(nsColor: InterStatus.danger))
        }
        .padding(.horizontal, InterSpacing.x2)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color(nsColor: InterStatus.danger).opacity(0.14)))
        .accessibilityLabel("Recording in progress")
    }

    private var candidateBadge: some View {
        Text("CANDIDATE")
            .font(InterFont.swiftUI(9, .bold))
            .tracking(1.0)
            .foregroundColor(Color(nsColor: InterColor.primary))
            .padding(.horizontal, InterSpacing.x2)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color(nsColor: InterColor.primary).opacity(0.16)))
    }

    private var chatButton: some View {
        Button(action: { viewModel.onToggleChat?() }) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: viewModel.chatVisible
                      ? "bubble.left.and.bubble.right.fill"
                      : "bubble.left.and.bubble.right")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(viewModel.chatVisible
                                     ? Color(nsColor: InterColor.primary)
                                     : .white.opacity(0.85))
                    .frame(width: 30, height: 26)
                if let badge = CallControlBarViewModel.badgeText(viewModel.chatUnread) {
                    Text(badge)
                        .font(InterFont.swiftUI(8, .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 13, minHeight: 13)
                        .background(Circle().fill(Color(nsColor: InterColor.primary)))
                        .offset(x: 5, y: -4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .help("Toggle chat (⌘⇧C)")
        .keyboardShortcut("c", modifiers: [.command, .shift])
    }
}

// MARK: - Bottom control bar

struct SecureCandidateBottomBarView: View {
    @ObservedObject var viewModel: SecureCandidateChromeViewModel

    @State private var micMenuOpen = false

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.mediaStatusText.isEmpty || !viewModel.shareStatusText.isEmpty {
                statusStrip
            }
            ZStack {
                // CENTER — media controls + the share cluster.
                HStack(spacing: InterSpacing.x2) {
                    micCluster
                    SecureBarButton(icon: viewModel.cameraEnabled ? "video.fill" : "video.slash.fill",
                                    label: viewModel.cameraLabel,
                                    active: !viewModel.cameraEnabled,
                                    enabled: viewModel.cameraInteractive,
                                    action: { viewModel.onToggleCamera?() })

                    Divider().frame(height: 28).overlay(Color.white.opacity(0.08))

                    shareCluster
                }
                .frame(maxWidth: .infinity)

                // RIGHT — destructive Leave isolated at the extreme edge
                // (#5: this is the candidate's only escape from kiosk mode;
                // it routes through the controller's confirmation alert).
                HStack {
                    Spacer(minLength: 0)
                    leaveButton
                }
            }
            .padding(.horizontal, InterSpacing.x3)
            .padding(.vertical, InterSpacing.x2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: InterColor.stage))
    }

    private var statusStrip: some View {
        HStack(spacing: InterSpacing.x3) {
            if !viewModel.mediaStatusText.isEmpty {
                Text(viewModel.mediaStatusText)
                    .font(InterFont.swiftUI(10))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !viewModel.shareStatusText.isEmpty {
                Text(viewModel.shareStatusText)
                    .font(InterFont.swiftUI(10))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, InterSpacing.x3)
        .padding(.top, InterSpacing.x1)
    }

    private var micCluster: some View {
        HStack(spacing: 0) {
            SecureBarButton(icon: viewModel.micEnabled ? "mic.fill" : "mic.slash.fill",
                            label: viewModel.micLabel,
                            active: !viewModel.micEnabled,
                            action: { viewModel.onToggleMic?() })
            Button(action: { micMenuOpen.toggle() }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 18, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()
            .help("Select a microphone")
            .interDropdown(isPresented: $micMenuOpen, alignment: .leading, opensUpward: true) {
                InterMenuContainer(minWidth: 220, stage: true) {
                    InterMenuSectionLabel(text: "Microphone", stage: true)
                    if viewModel.audioInputs.isEmpty {
                        InterMenuRow(title: "No microphones found", enabled: false,
                                     stage: true, action: {})
                    } else {
                        ForEach(viewModel.audioInputs) { device in
                            InterMenuRow(title: device.name,
                                         checked: viewModel.selectedAudioInputID == device.id,
                                         stage: true,
                                         action: {
                                viewModel.selectAudioInput(device.id)
                                micMenuOpen = false
                            })
                        }
                    }
                }
            }
        }
    }

    /// SHARE strip: segmented tool SELECTION + the explicit Share button (#7).
    private var shareCluster: some View {
        HStack(spacing: InterSpacing.x2_5) {
            Text("SHARE")
                .font(InterFont.swiftUI(9, .bold))
                .tracking(1.0)
                .foregroundColor(.white.opacity(0.45))

            HStack(spacing: 2) {
                ForEach(SecureCandidateChromeViewModel.toolSegments, id: \.kind) { segment in
                    toolSegment(kind: segment.kind, label: segment.label)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                .fill(Color.white.opacity(0.06)))

            shareToggleButton
        }
    }

    private func toolSegment(kind: Int, label: String) -> some View {
        let active = viewModel.selectedTool == kind
        return Button(action: { viewModel.selectTool(kind) }) {
            Text(label)
                .font(InterFont.swiftUI(11, .semibold))
                .foregroundColor(active ? .white : .white.opacity(0.6))
                .padding(.horizontal, InterSpacing.x2_5)
                .padding(.vertical, InterSpacing.x1)
                .background(
                    RoundedRectangle(cornerRadius: InterRadius.sm, style: .continuous)
                        .fill(active ? Color(nsColor: InterColor.primary) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .help(kind == 0 ? "No tool selected" : "Select \(SecureCandidateChromeViewModel.toolName(kind)) (does not start sharing)")
    }

    private var shareToggleButton: some View {
        Button(action: { viewModel.onToggleShare?() }) {
            HStack(spacing: InterSpacing.x1_5) {
                Image(systemName: viewModel.sharingActive
                      ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle")
                    .font(.system(size: 11, weight: .semibold))
                Text(viewModel.shareButtonLabel)
                    .font(InterFont.swiftUI(12, .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, InterSpacing.x3)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                    .fill(viewModel.sharingActive
                          ? Color(nsColor: InterStatus.danger).opacity(0.85)
                          : Color(nsColor: InterColor.primary))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .disabled(!viewModel.canToggleShare)
        .opacity(viewModel.canToggleShare ? 1 : 0.5)
        .help(viewModel.sharingActive
              ? "Stop sharing the tool surface"
              : "Publish the selected tool surface to the interviewer")
    }

    private var leaveButton: some View {
        Button(action: { viewModel.onLeave?() }) {
            HStack(spacing: InterSpacing.x1_5) {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text("Leave Interview")
                    .font(InterFont.swiftUI(13, .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, InterSpacing.x4)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: InterRadius.lg, style: .continuous)
                .fill(Color(nsColor: InterStatus.danger)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .help("End the interview session")
    }
}

// MARK: - Bar button (hover-aware; mirrors the normal bar's CallBarButton)

private struct SecureBarButton: View {
    let icon: String
    let label: String
    var active: Bool = false
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 22, height: 18)
                Text(label)
                    .font(InterFont.swiftUI(10, .medium))
                    .lineLimit(1)
            }
            .foregroundColor(.white.opacity(active || hovering ? 1 : 0.85))
            .frame(minWidth: 64)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                    .fill(active ? Color.white.opacity(0.10)
                          : hovering && enabled ? Color.white.opacity(0.06)
                          : .clear)
            )
            .scaleEffect(hovering && enabled ? 1.03 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .onHover { hovering = $0 }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .help(label)
    }
}
