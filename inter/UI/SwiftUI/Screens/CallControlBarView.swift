//
//  CallControlBarView.swift
//  inter
//
//  SwiftUI in-call bottom control bar (normal mode — the interviewer runs here
//  too; only the candidate launches the secure kiosk surface). Visual language
//  follows ref_in-call: icon-over-label buttons on the fixed-dark stage,
//  unread badges, red Leave. Approved layout:
//
//    Mic(^) · Camera · Share · Chat · Poll · Q&A · Raise Hand · Record · More · Leave
//
//  Mic ^ opens the audio-input flyout (live switching — the existing media API).
//  Camera has NO ^ (live camera switching deferred; the Settings default covers
//  device choice between meetings). Share opens the unified picker (no mode
//  selector). More hosts: share permission (host), Moderation (host),
//  Requests (host/co-host, with pending badge), React (coming soon),
//  View Recordings. Stage colors are FIXED dark — never appearance-aware.
//

import SwiftUI

struct CallControlBarView: View {
    @ObservedObject var viewModel: CallControlBarViewModel

    @State private var micMenuOpen = false
    @State private var moreMenuOpen = false
    @State private var moderationMenuOpen = false
    @State private var participantsOpen = false
    @State private var roomCodeCopied = false

    var body: some View {
        VStack(spacing: 0) {
            statusStrip
            ZStack {
                // LEFT — engagement panels pinned to the leading edge
                // (mirrors Leave's placement on the right).
                HStack(spacing: InterSpacing.x2) {
                    barButton(icon: "chart.bar.fill", label: "Poll",
                              action: { viewModel.onTogglePoll?() })
                    barButton(icon: "questionmark.bubble.fill", label: "Q&A",
                              badge: CallControlBarViewModel.badgeText(viewModel.qaUnread),
                              action: { viewModel.onToggleQA?() })
                    Spacer(minLength: 0)
                }

                // CENTER — mic/cam beside chat, then the rest of the
                // constructive cluster.
                HStack(spacing: InterSpacing.x2) {
                    micCluster
                    barButton(icon: viewModel.cameraEnabled ? "video.fill" : "video.slash.fill",
                              label: viewModel.cameraLabel,
                              active: !viewModel.cameraEnabled,
                              enabled: viewModel.cameraInteractive,
                              action: { viewModel.onToggleCamera?() })
                    barButton(icon: viewModel.speakerMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                              label: viewModel.speakerLabel,
                              active: viewModel.speakerMuted,
                              action: { viewModel.onToggleSpeaker?() })
                    barButton(icon: "bubble.left.fill", label: "Chat",
                              dot: viewModel.chatUnread > 0,
                              action: { viewModel.onToggleChat?() })

                    Divider().frame(height: 28).overlay(Color.white.opacity(0.08))

                    barButton(icon: "rectangle.on.rectangle",
                              label: viewModel.shareLabel,
                              active: viewModel.sharingActive,
                              enabled: viewModel.canShare,
                              action: { viewModel.onShare?() })
                    if viewModel.interviewToolsVisible {
                        // Interviewer-collaborative-tools: Code/Board controls.
                        // Visible only when entitled (interview mode + interviewer
                        // role + tools entitlement). The peer-activity dot is
                        // awareness only — it NEVER auto-opens a tool.
                        barButton(icon: "chevron.left.forward.slash.chevron.right",
                                  label: "Code",
                                  dot: viewModel.toolBadgeActive,
                                  active: viewModel.selectedToolKind == 1,
                                  action: { viewModel.selectTool(1) })
                        barButton(icon: "pencil.and.outline",
                                  label: "Board",
                                  dot: viewModel.toolBadgeActive,
                                  active: viewModel.selectedToolKind == 2,
                                  action: { viewModel.selectTool(2) })
                    }
                    participantsButton
                    barButton(icon: viewModel.handRaised ? "hand.raised.fill" : "hand.raised",
                              label: viewModel.handRaised ? "Lower Hand" : "Raise Hand",
                              active: viewModel.handRaised,
                              action: { viewModel.onToggleRaiseHand?() })
                    if viewModel.recordingVisible {
                        barButton(icon: viewModel.recordingActive ? "record.circle.fill" : "record.circle",
                                  label: viewModel.recordingActive ? "Stop Rec" : "Record",
                                  tint: viewModel.recordingActive ? InterStatus.danger : nil,
                                  active: viewModel.recordingActive,
                                  action: { viewModel.onToggleRecording?() })
                    }
                    moreMenu
                }
                .frame(maxWidth: .infinity)

                // RIGHT — the destructive Leave isolated at the extreme edge.
                HStack(spacing: InterSpacing.x2) {
                    Spacer(minLength: 0)
                    leaveButton
                }
            }
            .padding(.horizontal, InterSpacing.x3)
            .padding(.vertical, InterSpacing.x2)
        }
        .background(Color(nsColor: InterColor.stage))
    }

    // MARK: - Status strip (connection · room code · media/share status)

    @ViewBuilder private var statusStrip: some View {
        let hasContent = !viewModel.connectionStatusText.isEmpty
            || !viewModel.roomCode.isEmpty
            || !viewModel.mediaStatusText.isEmpty
            || !viewModel.shareStatusText.isEmpty
            || viewModel.networkQuality > 0
            || viewModel.showReactComingSoon
        if hasContent {
            HStack(spacing: InterSpacing.x3) {
                if viewModel.networkQuality > 0 {
                    NetworkSignalBars(level: viewModel.networkQuality)
                        .help("Network quality")
                }
                if !viewModel.connectionStatusText.isEmpty {
                    Text(viewModel.connectionStatusText)
                        .font(InterFont.swiftUI(10, .medium))
                        .foregroundColor(.white.opacity(0.55))
                }
                if !viewModel.roomCode.isEmpty {
                    roomCodeChip
                }
                if viewModel.showReactComingSoon {
                    Text("Reactions aren't available yet.")
                        .font(InterFont.swiftUI(10, .medium))
                        .foregroundColor(Color(nsColor: InterStatus.warning))
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
                if !viewModel.mediaStatusText.isEmpty {
                    Text(viewModel.mediaStatusText)
                        .font(InterFont.swiftUI(10))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                }
                if !viewModel.shareStatusText.isEmpty {
                    Text(viewModel.shareStatusText)
                        .font(InterFont.swiftUI(10))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, InterSpacing.x3)
            .padding(.top, InterSpacing.x1_5)
        }
    }

    // MARK: - Room code chip (code + copy button)

    private var roomCodeChip: some View {
        HStack(spacing: InterSpacing.x1) {
            Text(viewModel.roomCode)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1)
                .foregroundColor(.white.opacity(0.7))
            Button(action: copyRoomCode) {
                Image(systemName: roomCodeCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(roomCodeCopied
                                     ? Color(nsColor: InterStatus.success)
                                     : .white.opacity(0.65))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()
            .help(roomCodeCopied ? "Copied" : "Copy room code")
        }
        .padding(.horizontal, InterSpacing.x1_5)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: InterRadius.sm)
            .fill(Color.white.opacity(0.08)))
    }

    private func copyRoomCode() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(viewModel.roomCode, forType: .string)
        roomCodeCopied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            roomCodeCopied = false
        }
    }

    // MARK: - Mic cluster (button + ^ flyout)

    private var micCluster: some View {
        HStack(spacing: 0) {
            barButton(icon: viewModel.micEnabled ? "mic.fill" : "mic.slash.fill",
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

    // MARK: - Participants panel

    private var participantsButton: some View {
        barButton(icon: "person.2",
                  label: "Participants",
                  badge: CallControlBarViewModel.badgeText(viewModel.participants.count),
                  action: {
            viewModel.onParticipantsWillOpen?()   // pull a fresh list
            participantsOpen.toggle()
        })
        .interDropdown(isPresented: $participantsOpen, alignment: .center, opensUpward: true) {
            InterMenuContainer(minWidth: 260, stage: true) {
                InterMenuSectionLabel(text: "Participants (\(viewModel.participants.count))", stage: true)
                if viewModel.participants.isEmpty {
                    InterMenuRow(title: "No one else is here yet", enabled: false,
                                 stage: true, action: {})
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(viewModel.participants) { participant in
                                ParticipantRow(participant: participant,
                                               canModerate: viewModel.moderationVisible,
                                               onMute: { viewModel.onMuteParticipant?(participant.id) },
                                               onUnmute: { viewModel.onUnmuteParticipant?(participant.id) })
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                }
            }
        }
    }

    // MARK: - More menu

    private var moreMenu: some View {
        Button(action: { moreMenuOpen.toggle() }) {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 22, height: 18)
                    if let badge = CallControlBarViewModel.badgeText(viewModel.moreBadgeCount) {
                        Text(badge)
                            .font(InterFont.swiftUI(8, .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 13, minHeight: 13)
                            .background(Circle().fill(Color(nsColor: InterColor.primary)))
                            .offset(x: 8, y: -6)
                    }
                }
                Text("More")
                    .font(InterFont.swiftUI(10, .medium))
            }
            .foregroundColor(.white.opacity(0.85))
            .frame(width: 64, height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .help("More")
        .interDropdown(isPresented: $moreMenuOpen, alignment: .trailing, opensUpward: true) {
            InterMenuContainer(minWidth: 240, stage: true) {
                // Most-used host actions first; everything heavier lives in
                // the Moderation panel.
                if viewModel.moderationVisible {
                    InterMenuRow(title: viewModel.allMuted ? "Unmute All" : "Mute All Mics",
                                 icon: viewModel.allMuted ? "speaker.wave.2" : "mic.slash",
                                 stage: true,
                                 action: {
                        moreMenuOpen = false
                        viewModel.onToggleMuteAll?()
                    })
                    InterMenuRow(title: viewModel.allCamerasOff ? "Allow All Cameras" : "Turn Off All Cameras",
                                 icon: viewModel.allCamerasOff ? "video" : "video.slash",
                                 stage: true,
                                 action: {
                        moreMenuOpen = false
                        viewModel.onToggleAllCameras?()
                    })
                    InterMenuSeparator(stage: true)
                }
                if viewModel.requestsVisible {
                    InterMenuRow(title: viewModel.pendingRequestCount > 0
                                    ? "Requests (\(viewModel.pendingRequestCount))"
                                    : "Requests",
                                 icon: "person.crop.circle.badge.questionmark",
                                 stage: true,
                                 action: {
                        moreMenuOpen = false
                        viewModel.onOpenRequests?()
                    })
                }
                if viewModel.lobbyVisible {
                    InterMenuRow(title: viewModel.lobbyWaitingCount > 0
                                    ? "Waiting Room (\(viewModel.lobbyWaitingCount))…"
                                    : "Waiting Room…",
                                 icon: "door.left.hand.closed",
                                 stage: true,
                                 action: {
                        moreMenuOpen = false
                        viewModel.onOpenLobby?()
                    })
                }
                if viewModel.moderationVisible {
                    InterMenuRow(title: "Moderation…", icon: "shield.lefthalf.filled",
                                 stage: true,
                                 action: {
                        moreMenuOpen = false
                        viewModel.onModerationWillOpen?()   // pull fresh state
                        moderationMenuOpen = true
                    })
                }
                InterMenuSeparator(stage: true)
                if viewModel.renameVisible {
                    InterMenuRow(title: "Change My Name…", icon: "pencil",
                                 stage: true,
                                 action: {
                        moreMenuOpen = false
                        viewModel.onRename?()
                    })
                }
                InterMenuRow(title: "React", icon: "face.smiling", stage: true,
                             action: {
                    moreMenuOpen = false
                    viewModel.react()
                })
                if viewModel.viewRecordingsVisible {
                    InterMenuRow(title: "View Recordings…", icon: "film", stage: true,
                                 action: {
                        moreMenuOpen = false
                        viewModel.onViewRecordings?()
                    })
                }
            }
        }
        .interDropdown(isPresented: $moderationMenuOpen, alignment: .trailing, opensUpward: true) {
            moderationMenu
        }
    }

    // MARK: - Moderation menu (host/co-host — replaces the legacy NSMenu)

    private var moderationMenu: some View {
        InterMenuContainer(minWidth: 250, stage: true) {
            if viewModel.renameVisible || viewModel.moderationVisible {
                InterMenuRow(title: "Change My Name…", icon: "pencil", stage: true,
                             action: {
                    moderationMenuOpen = false
                    viewModel.onRename?()
                })
                InterMenuSeparator(stage: true)
            }
            InterMenuRow(title: "Stop All Screen Shares", icon: "rectangle.on.rectangle.slash",
                         stage: true,
                         action: {
                moderationMenuOpen = false
                viewModel.onStopAllShares?()
            })
            InterMenuRow(title: viewModel.chatDisabled ? "Enable Chat" : "Disable Chat",
                         icon: viewModel.chatDisabled ? "bubble.left" : "bubble.left.slash",
                         stage: true,
                         action: {
                moderationMenuOpen = false
                viewModel.onToggleChatDisabled?()
            })
            if viewModel.isHostRole {
                InterMenuRow(title: viewModel.coHostRecordingAllowed
                                ? "Disallow Co-Host Local Recording"
                                : "Allow Co-Host Local Recording",
                             icon: "record.circle",
                             stage: true,
                             action: {
                    moderationMenuOpen = false
                    viewModel.onToggleCoHostRecording?()
                })
            }
            InterMenuRow(title: viewModel.meetingLocked ? "Unlock Meeting" : "Lock Meeting",
                         icon: viewModel.meetingLocked ? "lock.open" : "lock",
                         stage: true,
                         action: {
                moderationMenuOpen = false
                viewModel.onToggleLock?()
            })

            InterMenuSeparator(stage: true)
            InterMenuSectionLabel(text: "Meeting Password", stage: true)
            if viewModel.hasMeetingPassword {
                if viewModel.hasPlaintextPassword {
                    InterMenuRow(title: "View / Copy Password", icon: "eye", stage: true,
                                 action: {
                        moderationMenuOpen = false
                        viewModel.onPasswordView?()
                    })
                }
                InterMenuRow(title: "Change Password…", icon: "key", stage: true,
                             action: {
                    moderationMenuOpen = false
                    viewModel.onPasswordChange?()
                })
                InterMenuRow(title: "Remove Password", icon: "key.slash", stage: true,
                             action: {
                    moderationMenuOpen = false
                    viewModel.onPasswordRemove?()
                })
            } else {
                InterMenuRow(title: "Set Password…", icon: "key", stage: true,
                             action: {
                    moderationMenuOpen = false
                    viewModel.onPasswordChange?()
                })
            }

            if let mode = viewModel.sharePermissionMode {
                InterMenuSeparator(stage: true)
                InterMenuSectionLabel(text: "Who can share", stage: true)
                ForEach(CallControlBarViewModel.sharePermissionModes, id: \.self) { value in
                    InterMenuRow(title: CallControlBarViewModel.sharePermissionLabel(value),
                                 checked: mode == value,
                                 enabled: viewModel.sharePermissionEnabled,
                                 stage: true,
                                 action: {
                        viewModel.onSharePermissionChange?(value)
                        moderationMenuOpen = false
                    })
                }
            }

            InterMenuSeparator(stage: true)
            InterMenuSectionLabel(text: "Share takeover", stage: true)
            ForEach(CallControlBarViewModel.shareConflictModes, id: \.self) { policy in
                InterMenuRow(title: CallControlBarViewModel.shareConflictLabel(policy),
                             checked: viewModel.shareConflictPolicy == policy,
                             stage: true,
                             action: {
                    viewModel.onShareConflictChange?(policy)
                    moderationMenuOpen = false
                })
            }
        }
    }

    private var leaveButton: some View {
        Button(action: { viewModel.onLeave?() }) {
            HStack(spacing: InterSpacing.x1_5) {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text("Leave")
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
        .help("Leave the call")
    }

    // MARK: - One bar button

    private func barButton(icon: String, label: String, badge: String? = nil,
                           dot: Bool = false,
                           tint: NSColor? = nil, active: Bool = false,
                           enabled: Bool = true,
                           action: @escaping () -> Void) -> some View {
        CallBarButton(icon: icon, label: label, badge: badge, dot: dot, tint: tint,
                      active: active, enabled: enabled, action: action)
    }
}

// MARK: - Bar button (hover-aware)

private struct CallBarButton: View {
    let icon: String
    let label: String
    var badge: String? = nil
    var dot: Bool = false
    var tint: NSColor? = nil
    var active: Bool = false
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 22, height: 18)
                    if let badge = badge {
                        Text(badge)
                            .font(InterFont.swiftUI(8, .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 13, minHeight: 13)
                            .background(Circle().fill(Color(nsColor: InterColor.primary)))
                            .offset(x: 8, y: -6)
                    } else if dot {
                        // Presence-only unread indicator (no count) — e.g. new chat.
                        Circle()
                            .fill(Color(nsColor: InterColor.primary))
                            .frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(Color(nsColor: InterColor.stage), lineWidth: 1.5))
                            .offset(x: 7, y: -5)
                    }
                }
                Text(label)
                    .font(InterFont.swiftUI(10, .medium))
                    .lineLimit(1)
            }
            .foregroundColor(buttonColor)
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

    private var buttonColor: Color {
        if let tint = tint { return Color(nsColor: tint) }
        return .white.opacity(active || hovering ? 1 : 0.85)
    }
}

// MARK: - Participant row (hover reveals the host mute control)

private struct ParticipantRow: View {
    let participant: CallParticipant
    let canModerate: Bool
    let onMute: () -> Void
    let onUnmute: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: InterSpacing.x2) {
            Circle()
                .fill(Color(nsColor: InterColor.primary).opacity(0.25))
                .frame(width: 24, height: 24)
                .overlay(Text(HomeViewModel.initials(from: participant.name))
                    .font(InterFont.swiftUI(9, .bold))
                    .foregroundColor(.white))
            Text(participant.name)
                .font(InterFont.swiftUI(13))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: InterSpacing.x2)
            if canModerate {
                // Always-visible mute toggle (no hover needed). Reflects + routes to
                // the host's direct mute/unmute per the tile state matrix: muted →
                // unmute (lift host block), live → mute.
                Button(action: { participant.isHostMuted ? onUnmute() : onMute() }) {
                    Image(systemName: participant.isHostMuted ? "mic.slash.fill" : "mic")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(participant.isHostMuted
                                         ? Color(nsColor: InterStatus.danger)
                                         : .white.opacity(0.85))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0.0)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .handCursor()
                .help(participant.isHostMuted ? "Unmute their microphone" : "Mute their microphone")
            } else if participant.isHostMuted {
                // Non-moderators see a read-only muted indicator.
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                    .help("Muted by host")
            }
        }
        .padding(.horizontal, InterSpacing.x2_5)
        .padding(.vertical, InterSpacing.x1_5)
        // Make the WHOLE row the hover target (avatar + name + the empty middle +
        // trailing). Without this, SwiftUI only hit-tests the non-empty subviews,
        // so the highlight only appeared when hovering exactly over the name.
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: InterRadius.md, style: .continuous)
                .fill(hovering ? Color.white.opacity(0.06) : .clear)
        )
        .onHover { hovering = $0 }
    }
}

// MARK: - Network signal bars (re-homed from the removed self-preview PiP)

/// Four progressive vertical bars mirroring the AppKit `InterNetworkStatusView`.
/// `level` is an InterNetworkQualityLevel raw value: 0 unknown (gray),
/// 1 lost (red), 2 poor (orange), 3 good (yellow-green), 4 excellent (green).
private struct NetworkSignalBars: View {
    let level: Int

    private static let barCount = 4

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(index < level ? fillColor : Color.white.opacity(0.18))
                    .frame(width: 3, height: 4 + CGFloat(index) * 3)
            }
        }
        .frame(height: 13, alignment: .bottom)
        .accessibilityLabel("Network quality \(level) of \(Self.barCount)")
    }

    private var fillColor: Color {
        switch level {
        case 4: return Color(nsColor: .systemGreen)
        case 3: return Color(red: 0.6, green: 0.8, blue: 0.2)
        case 2: return Color(nsColor: .systemOrange)
        case 1: return Color(nsColor: .systemRed)
        default: return Color.white.opacity(0.3)
        }
    }
}
