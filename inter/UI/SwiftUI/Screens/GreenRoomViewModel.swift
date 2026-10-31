//
//  GreenRoomViewModel.swift
//  inter
//
//  Drives the SwiftUI green room (pre-join device check). One screen, three
//  flow roles:
//    • hostCreate    — after pre-meeting settings; SESSION shows editable
//                      meeting name + opt-in password; CTA "Start Meeting";
//                      "Meeting Settings" button re-opens the full sheet.
//    • join          — joiner typed a room code; SESSION shows the code (mono);
//                      CTA "Join Now".
//    • hostInterview — interviewer fast path; no meeting-name/password (the
//                      interview room is configured server-side); CTA
//                      "Start Interview".
//
//  Device rows persist to the SAME preference keys the Settings window uses
//  (InterPreferredAudioDeviceID / InterPreferredVideoDeviceID via the
//  injected provider), so "change device here" = "change the default".
//  Speaker output is system-routed on macOS — shown read-only (no Change).
//
//  Join-state rule (host-enforcement OR user-choice): the mic/cam toggles and
//  "Join without video" only ever turn local devices OFF beyond what the host
//  enforces — they can never override muteOnJoin / cameraOffOnJoin.
//

import Foundation
import Combine

/// Which flow opened the green room.
public enum GreenRoomRole: Equatable {
    case hostCreate
    case join(roomCode: String)
    /// Starting a meeting the user scheduled earlier — the room already exists
    /// server-side with a schedule-time settings snapshot. The host MAY still open
    /// Meeting Settings here to override that snapshot at start (the server applies
    /// the green-room edit over the snapshot); invitees cannot.
    case scheduledStart(roomCode: String)
    case hostInterview
}

/// Network reachability of the token server (pre-call "can I even connect").
public enum GreenRoomNetworkState: Equatable {
    case checking
    case reachable(latencyMillis: Int)
    case unreachable
}

@MainActor
public final class GreenRoomViewModel: ObservableObject {

    // MARK: - Role

    public let role: GreenRoomRole

    // MARK: - Identity / session fields

    @Published public var displayName: String = ""
    /// Host-create only: per-meeting name + opt-in password (seeded from the
    /// pre-meeting sheet or saved defaults; editable here).
    @Published public var meetingName: String = ""
    @Published public var requirePassword: Bool = false {
        didSet { if !requirePassword { password = "" } }
    }
    @Published public var password: String = ""

    // MARK: - Local device state (preview)

    @Published public private(set) var micOn: Bool = true
    @Published public private(set) var camOn: Bool = true
    @Published public private(set) var microphones: [MediaDeviceOption] = []
    @Published public private(set) var cameras: [MediaDeviceOption] = []
    @Published public private(set) var selectedMicID: String = ""
    @Published public private(set) var selectedCameraID: String = ""
    /// Read-only system output device name (no per-app routing on macOS).
    @Published public var speakerName: String = "System default"

    // MARK: - Status

    @Published public var networkState: GreenRoomNetworkState = .checking
    /// Live mic input level 0…1 while the level meter runs (device test).
    @Published public var micLevel: Double = 0
    /// Whether the speaker test tone is currently playing.
    @Published public var speakerTestPlaying: Bool = false
    /// Whether the device test drawer is open.
    @Published public var deviceTestOpen: Bool = false
    /// Transient note for unavailable features ("Background blur isn't available yet.").
    @Published public private(set) var unavailableNote: String?

    /// Host defaults summary shown under the Meeting Settings button.
    @Published public var usingDefaultsCaption: String = "Using default settings"

    // MARK: - PRESENCE MONITORING (provisional, server flag default OFF)
    //
    // Interviewer-only, and UX ONLY: the server re-derives arming from the master
    // flag, the room type, the host's snapshotted tier and these two declarations,
    // and forces monitoring OFF for an EU-resident or under-18 candidate whatever
    // this screen says. No `users` column records region or date of birth, so the
    // interviewer declares it per room (research memo §7.9 items 7 and 8); asking
    // the CANDIDATE to self-declare a protected characteristic to the system that
    // is about to monitor them would be worse. Delete this block and the rows in
    // GreenRoomView to remove the toggles.
    // See .agents/tasks/presence-monitoring/REMOVAL.md.

    /// Interviewer asks for presence monitoring in this interview room.
    @Published public var presenceMonitoring: Bool = false
    /// Interviewer declares the candidate as EU-resident.
    @Published public var candidateRegionEU: Bool = false
    /// Interviewer declares the candidate as under 18.
    @Published public var candidateUnder18: Bool = false

    /// Shown only on the interviewer's own pre-interview screen. Deliberately not
    /// gated on the master flag: the green room renders before the room exists, so
    /// there is no server answer to read yet, and probing for one would add a third
    /// reader of `PRESENCE_MONITORING_ENABLED`. The box is therefore a request, the
    /// caption below says so, and with the flag off the server simply never arms
    /// the room — nothing is recorded and no surface starts.
    public var showsPresenceControls: Bool { role == .hostInterview }

    /// What ticking the box actually means, stated plainly, so the interviewer is
    /// never surprised by the server overriding the toggle. The ticked wording
    /// must NOT promise that the candidate will be asked: this screen renders
    /// before the room exists, so it cannot know whether the server will arm the
    /// room, and with the master flag off the candidate is never asked at all.
    public var presenceCaption: String {
        Self.presenceCaption(monitoring: presenceMonitoring,
                             regionEU: candidateRegionEU,
                             under18: candidateUnder18)
    }

    public nonisolated static func presenceCaption(monitoring: Bool,
                                                   regionEU: Bool,
                                                   under18: Bool) -> String {
        guard monitoring else {
            return "Nothing about what the candidate's camera sees will be recorded."
        }
        if regionEU || under18 {
            return "Monitoring stays off for this candidate by policy, and they are "
                + "not offered it. You can still run the interview normally."
        }
        return "This is a request for this room, not a guarantee. Nothing is "
            + "recorded unless the candidate agrees, and they can join with "
            + "monitoring off. No decision is automated."
    }

    // MARK: - Callbacks (wired by the bridge)

    public var onToggleMic: ((Bool) -> Void)?
    public var onToggleCam: ((Bool) -> Void)?
    public var onSelectMic: ((String) -> Void)?
    public var onSelectCamera: ((String) -> Void)?
    public var onPrimaryAction: (() -> Void)?     // Start Meeting / Join Now
    public var onJoinWithoutVideo: (() -> Void)?
    public var onOpenMeetingSettings: (() -> Void)?
    public var onCancel: (() -> Void)?
    public var onStartSpeakerTest: (() -> Void)?
    public var onStopSpeakerTest: (() -> Void)?
    public var onSetMicMetering: ((Bool) -> Void)?

    private var noteDismissTask: Task<Void, Never>?

    public init(role: GreenRoomRole) {
        self.role = role
    }

    // MARK: - Inputs from the bridge

    public func setDevices(microphones: [MediaDeviceOption], cameras: [MediaDeviceOption],
                           selectedMicID: String, selectedCameraID: String) {
        self.microphones = microphones
        self.cameras = cameras
        self.selectedMicID = selectedMicID
        self.selectedCameraID = selectedCameraID
    }

    public func setDeviceStates(micOn: Bool, camOn: Bool) {
        self.micOn = micOn
        self.camOn = camOn
    }

    public func setMicLevel(_ level: Double) {
        micLevel = max(0, min(1, level))
    }

    public func setSpeakerTestPlaying(_ playing: Bool) {
        speakerTestPlaying = playing
    }

    // MARK: - Derived

    public var isHostCreate: Bool { role == .hostCreate }

    public var roomCode: String? {
        switch role {
        case .join(let code), .scheduledStart(let code): return code
        default: return nil
        }
    }

    public var primaryTitle: String {
        switch role {
        case .hostCreate:     return "Start Meeting"
        case .join:           return "Join Now"
        case .scheduledStart: return "Start Meeting"
        case .hostInterview:  return "Start Interview"
        }
    }

    /// The quiet "… without video" action under the primary CTA.
    public var withoutVideoTitle: String {
        switch role {
        case .hostCreate, .scheduledStart, .hostInterview: return "Start without video"
        case .join:                                        return "Join without video"
        }
    }

    /// Meeting Settings button: host-create AND the scheduled host's start path
    /// (edits override the schedule-time snapshot when saved).
    public var showsMeetingSettings: Bool {
        if isHostCreate { return true }
        if case .scheduledStart = role { return true }
        return false
    }

    /// The empty-required-password block, same rule as the pre-meeting sheet.
    public var passwordInvalid: Bool {
        isHostCreate && requirePassword
            && password.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var canSubmit: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty && !passwordInvalid
    }

    public var networkCaption: String {
        switch networkState {
        case .checking:                return "Checking network…"
        case .reachable(let ms):       return ms < 120 ? "Network quality: Excellent"
                                            : ms < 400 ? "Network quality: Good"
                                            : "Network quality: Poor"
        case .unreachable:             return "Server unreachable"
        }
    }

    // MARK: - Actions

    public func toggleMic() {
        micOn.toggle()
        onToggleMic?(micOn)
    }

    public func toggleCam() {
        camOn.toggle()
        onToggleCam?(camOn)
    }

    public func selectMic(_ id: String) {
        guard id != selectedMicID else { return }
        selectedMicID = id
        onSelectMic?(id)
    }

    public func selectCamera(_ id: String) {
        guard id != selectedCameraID else { return }
        selectedCameraID = id
        onSelectCamera?(id)
    }

    public func submitPrimary() {
        guard canSubmit else { return }
        onPrimaryAction?()
    }

    /// "Join without video": camera off locally, then the normal primary path.
    public func joinWithoutVideo() {
        guard canSubmit else { return }
        if camOn {
            camOn = false
            onToggleCam?(false)
        }
        onJoinWithoutVideo?()
    }

    public func openMeetingSettings() {
        guard showsMeetingSettings else { return }
        onOpenMeetingSettings?()
    }

    public func cancel() {
        onCancel?()
    }

    public func toggleDeviceTest() {
        deviceTestOpen.toggle()
        onSetMicMetering?(deviceTestOpen)
        if !deviceTestOpen, speakerTestPlaying {
            onStopSpeakerTest?()
        }
    }

    public func toggleSpeakerTest() {
        if speakerTestPlaying {
            onStopSpeakerTest?()
        } else {
            onStartSpeakerTest?()
        }
    }

    /// Blur background: UI present, capture-pipeline infra NOT built yet.
    /// TODO(blur-infra): replace with a real background-blur toggle once the
    /// capture pipeline gains a blur stage; see migration notes.
    public func blurBackgroundTapped() {
        showUnavailableNote("Background blur isn't available yet.")
    }

    private func showUnavailableNote(_ text: String) {
        noteDismissTask?.cancel()
        unavailableNote = text
        noteDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if !Task.isCancelled { self?.unavailableNote = nil }
        }
    }

    // MARK: - Pure helpers (unit-tested)

    /// Final local device state on join: host enforcement wins; otherwise the
    /// user's green-room choice applies. Returns true = device ON.
    public nonisolated static func effectiveDeviceOn(hostForcesOff: Bool, userWantsOn: Bool) -> Bool {
        hostForcesOff ? false : userWantsOn
    }

    /// "AM" initials for the camera-off avatar (first + last word, uppercased).
    public nonisolated static func initials(for name: String) -> String {
        let words = name.split(separator: " ").filter { !$0.isEmpty }
        guard let first = words.first?.first else { return "?" }
        if words.count > 1, let last = words.last?.first {
            return String(first).uppercased() + String(last).uppercased()
        }
        return String(first).uppercased()
    }

    /// Display name for a device id within a list ("System default" for "").
    public nonisolated static func deviceName(for id: String, in devices: [MediaDeviceOption]) -> String {
        devices.first(where: { $0.id == id })?.name ?? "System default"
    }

    /// Spaced-out room code for the mono SESSION chip ("A92K1Z" → "A 9 2 K 1 Z").
    public nonisolated static func spacedCode(_ code: String) -> String {
        code.uppercased().map(String.init).joined(separator: " ")
    }
}
