// ============================================================================
// InterRoomController.swift
// inter
//
// Phase 1.9 — Central orchestrator for the LiveKit room lifecycle.
//
// Owns:
//   • LiveKit.Room instance
//   • InterLiveKitPublisher (publish local tracks)
//   • InterLiveKitSubscriber (subscribe to remote tracks)
//   • InterTokenService (JWT management)
//   • InterCallStatsCollector (diagnostics)
//
// LIFECYCLE:
//   1. AppDelegate creates InterRoomController once at launch. Outlives modes.
//   2. User action → connect(configuration:completion:)
//   3. Host: createRoom → receives room code → room.connect()
//   4. Joiner: joinRoom(roomCode) → room.connect()
//   5. Mode transitions [G4]: transitionMode() detaches sources, keeps room alive
//   6. disconnect() → unpublish, stop stats, room.disconnect()
//
// THREADING:
// All public methods are called on the main queue. Internal state transitions
// use a private serial queue. KVO properties are set on the main queue.
//
// ISOLATION INVARIANT [G8]:
// If this controller is nil or fails, the app works identically to local-only.
// AppDelegate checks `_roomController != nil` before any network operation.
// ============================================================================

import Foundation
import os.log
import LiveKit

// MARK: - Audio input device matching (pure, unit-testable)

/// Pure matcher for re-pointing the network mic. The in-app picker is AVCapture-based
/// while LiveKit enumerates CoreAudio devices, so we match by deviceId first and fall
/// back to the human-readable name. Returns nil when nothing matches (caller no-ops).
enum InterAudioInputMatcher {
    static func matchIndex(devices: [(id: String, name: String)],
                           wantID: String?, wantName: String?) -> Int? {
        if let w = wantID, !w.isEmpty, let i = devices.firstIndex(where: { $0.id == w }) {
            return i
        }
        if let w = wantName, !w.isEmpty, let i = devices.firstIndex(where: { $0.name == w }) {
            return i
        }
        return nil
    }
}

// MARK: - InterRoomController

@objc public class InterRoomController: NSObject {

    // MARK: - KVO-Observable Properties

    /// Current connection state. KVO-observable from Objective-C.
    @objc public private(set) dynamic var connectionState: InterRoomConnectionState = .disconnected

    /// Why the room last became disconnected. Read by the media-wiring layer when
    /// `connectionState` transitions to `.disconnectedWithError` to decide whether
    /// to show a generic "Connection Lost" alert or a specific host-action message
    /// (removed / meeting ended). Updated before the state change so observers see
    /// a consistent value.
    @objc public private(set) dynamic var lastDisconnectReason: InterRoomDisconnectReason = .none

    /// Participant presence state with 3-second grace period. [G6]
    @objc public private(set) dynamic var participantPresenceState: InterParticipantPresenceState = .alone

    /// Number of remote participants currently in the room.
    @objc public private(set) dynamic var remoteParticipantCount: Int = 0

    /// Identity of the current dominant/active speaker (nil if none or local).
    /// Updated by LiveKit's activeSpeakersChanged delegate. Used by the layout
    /// manager for speaker highlight effects.
    @objc public private(set) dynamic var activeSpeakerIdentity: String = ""

    /// Room code (6-char alphanumeric). Set after create or join. [G7]
    @objc public private(set) dynamic var roomCode: String = ""

    /// Room type: "call" or "interview". Set from the token server response.
    /// Used by AppDelegate to determine which mode/role to enter on join.
    @objc public private(set) dynamic var roomType: String = ""

    // MARK: - Owned Components

    /// Publisher: manages local track publishing.
    @objc public let publisher = InterLiveKitPublisher()

    /// Subscriber: manages remote track subscription.
    @objc public let subscriber = InterLiveKitSubscriber()

    /// Dedicated serial queue for LiveKit Audio Device Module (ADM) mutations.
    /// `AudioManager.shared.inputDevices` / `.inputDevice` getters and the
    /// `.inputDevice` setter are synchronous WebRTC `Thread::BlockingCall`s; running
    /// them on the main thread during an audio route change blocked the UI (video
    /// freeze) and raced CoreAudio's route-change listener. We serialize all ADM
    /// switches here so concurrent mic-switch requests cannot interleave and thrash
    /// the device module. [NW1]
    private let admQueue = DispatchQueue(label: "inter.adm", qos: .userInitiated)

    /// Token service: JWT fetch/cache/refresh.
    @objc public let tokenService = InterTokenService()

    /// Stats collector: periodic stats gathering. Created on connect, destroyed on disconnect.
    @objc public private(set) var statsCollector: InterCallStatsCollector?

    /// [Phase 8] Chat + control signal controller. Created by the caller (AppDelegate)
    /// and wired in before connect. The room controller forwards DataChannel data to it.
    @objc public weak var chatController: InterChatController?

    /// [Phase 8.5] Live-poll controller. Wired in by the caller before connect.
    @objc public weak var pollController: InterPollController?

    /// [Phase 8.6] Q&A controller. Wired in by the caller before connect.
    @objc public weak var qaController: InterQAController?

    /// [Phase 10] Recording coordinator. Wired in by the caller before connect.
    /// Room controller forwards disconnect events so recording can auto-stop.
    @objc public weak var recordingCoordinator: InterRecordingCoordinator?

    /// The local participant's identity string (ObjC-safe accessor).
    @objc public var localParticipantIdentity: String {
        return room?.localParticipant.identity?.stringValue ?? ""
    }

    /// The local participant's display name (ObjC-safe accessor).
    @objc public var localParticipantName: String {
        return room?.localParticipant.name ?? "You"
    }

    /// The server-signed `tools` entitlement for the LOCAL participant, read from
    /// this client's own LiveKit JWT metadata (R9.2). The token server derives it
    /// from the room's snapshotted host tier, so it is granted to both the
    /// interviewer and the candidate of a Hiring host's room regardless of the
    /// candidate's own tier (R7.2), and cannot be forged by a client (R9.1).
    ///
    /// Reads ONLY the local participant's metadata — never a peer's self-reported
    /// claim (R9.5). Fail-closed: returns `false` when disconnected or the flag is
    /// absent/malformed.
    @objc public var localParticipantHasToolsEntitlement: Bool {
        return InterParticipantMetadata.parseToolsEntitlement(from: room?.localParticipant.metadata)
    }

    /// Re-point LiveKit's native audio capture (the ADM/voice-processing input) to a
    /// specific input device, matched against `AudioManager.shared.inputDevices`.
    ///
    /// The in-app mic picker is built on AVCaptureDevice, whose `uniqueID` is not
    /// guaranteed to equal LiveKit's `AudioDevice.deviceId`, so we match by deviceId
    /// first and fall back to the human-readable name. `completion` is invoked with
    /// true iff a matching device was found and selected. SAFE NO-OP (logs) when
    /// nothing matches — never forces an invalid device. Skips a redundant switch to
    /// avoid thrashing the ADM.
    ///
    /// [NW1] All ADM access (the `inputDevices` enumeration, the `inputDevice` getter
    /// used for the redundant-switch check, and the `inputDevice` setter) runs on the
    /// dedicated serial `admQueue`, NEVER the calling (main) thread. `completion` is
    /// always delivered back on the main queue.
    @objc public func setNetworkAudioInput(deviceID: String?, name: String?,
                                           completion: ((Bool) -> Void)?) {
        #if os(macOS)
        admQueue.async {
            let result = InterRoomController.performNetworkAudioInputSwitch(deviceID: deviceID, name: name)
            if let completion = completion {
                DispatchQueue.main.async { completion(result) }
            }
        }
        #else
        if let completion = completion {
            DispatchQueue.main.async { completion(false) }
        }
        #endif
    }

    #if os(macOS)
    /// Performs the actual ADM device match + switch. MUST be called on `admQueue`
    /// (off the main thread) — every line here is a blocking WebRTC ADM call.
    private static func performNetworkAudioInputSwitch(deviceID: String?, name: String?) -> Bool {
        let devices = AudioManager.shared.inputDevices
        let tuples = devices.map { (id: $0.deviceId, name: $0.name) }
        guard let idx = InterAudioInputMatcher.matchIndex(devices: tuples,
                                                          wantID: deviceID, wantName: name) else {
            interLogInfo(InterLog.networking,
                         "RoomController: in-call mic switch found no LiveKit input device (id=%{public}@ name=%{public}@)",
                         deviceID ?? "", name ?? "")
            return false
        }
        let target = devices[idx]
        // Skip a redundant switch — re-selecting the current device would needlessly
        // restart the audio device module.
        if AudioManager.shared.inputDevice.deviceId == target.deviceId {
            return true
        }
        AudioManager.shared.inputDevice = target
        interLogInfo(InterLog.networking,
                     "RoomController: network mic switched to %{public}@", target.name)
        return true
    }
    #endif

    // NOTE: `selectedNetworkAudioInput(optionIDs:optionNames:)` (the deferred "deeper"
    // checkmark fix that read LiveKit's AudioManager.inputDevice while connected) was
    // removed. It introduced a synchronous WebRTC blocking call into the route-change
    // refresh path (UI freeze) and was reverted in full. The mic checkmark is now derived
    // solely from the AVCapture-validated -selectedAudioInputDeviceID. See spec:
    // audio-route-change-crash-fix.

    /// Whether the local participant is the host (room creator).
    @objc public var isHost: Bool {
        return configuration?.isHost ?? false
    }

    /// [Phase 9] Token server base URL (e.g. "http://localhost:3000").
    /// Exposed for the moderation controller to make HTTP calls.
    @objc public var tokenServerURL: String {
        return configuration?.tokenServerURL ?? ""
    }

    // MARK: - Active Meeting Settings (set after successful connect)

    /// Human-readable meeting name broadcast to all participants.
    @objc public private(set) dynamic var activeMeetingDisplayName: String = ""
    /// Whether all participants start muted.
    @objc public private(set) dynamic var activeMuteOnJoin: Bool = false
    /// Whether all participants start with camera off.
    @objc public private(set) dynamic var activeCameraOffOnJoin: Bool = false
    /// Whether participants can join before the host.
    @objc public private(set) dynamic var activeJoinBeforeHost: Bool = false
    /// Whether the waiting room / lobby is enabled for this meeting (host-configured).
    /// Used to initialise the in-session lobby toggle so it reflects the pre-meeting choice.
    @objc public private(set) dynamic var activeLobbyEnabled: Bool = false
    /// Whether the meeting currently has a password set (server-authoritative boolean).
    /// The plaintext is never delivered to non-setters — this only reflects whether one
    /// exists, so a rejoining host / co-host can render the password menu state correctly.
    @objc public private(set) dynamic var activeHasPassword: Bool = false
    /// Whether participants can unmute themselves.
    @objc public private(set) dynamic var activeAllowUnmuting: Bool = true
    /// Chat permission level: "everyone" | "hostOnly" | "disabled".
    @objc public private(set) dynamic var activeChatPermissions: String = "everyone"
    /// Screen sharing permission: "hostOnly" | "everyone" | "request".
    @objc public private(set) dynamic var activeSharingPermissions: String = "hostOnly"
    /// Share-conflict policy: "oneattime" | "hostCanPreempt" | "anyCanPreempt".
    @objc public private(set) dynamic var activeShareConflictPolicy: String = "oneattime"
    /// Whether cloud recording should auto-start when the host joins.
    @objc public private(set) dynamic var activeAutoRecord: Bool = false
    /// Whether AI transcription should auto-start when the host joins.
    @objc public private(set) dynamic var activeAutoTranscript: Bool = false

    // MARK: - PRESENCE MONITORING (provisional, server flag default OFF)
    //
    // Server-authoritative, read straight off the /room/join response for a
    // joiner and off the /room/create response for the creating interviewer.
    // When the master flag is off the server omits the presence keys from both,
    // so `activePresenceMonitoringArmed` stays false and every consumer — the
    // consent gate, the candidate indicator, the interviewer chip — is inert
    // with no further guard. Delete this block to remove the feature from the
    // room controller. See .agents/tasks/presence-monitoring/REMOVAL.md.

    /// Whether the server armed presence monitoring for the active room.
    @objc public private(set) dynamic var activePresenceMonitoringArmed: Bool = false
    /// Retention window the candidate was told about, in days.
    @objc public private(set) dynamic var activePresenceRetentionDays: Int = 90
    /// Server-recorded policy flag: candidate declared EU-resident.
    @objc public private(set) dynamic var activePresenceRegionEU: Bool = false
    /// Server-recorded policy flag: candidate declared under 18.
    @objc public private(set) dynamic var activePresenceUnder18: Bool = false
    /// Whether this room allows the `multiple_faces` event type at all.
    @objc public private(set) dynamic var activePresenceMultipleFacesEnabled: Bool = false
    /// Detector build identifier the server stamps on stored events.
    @objc public private(set) dynamic var activePresenceDetectorVersion: String = ""
    /// Raw thresholds JSON *string* exactly as the server stored it.
    @objc public private(set) dynamic var activePresenceThresholds: String = ""
    /// Where a candidate asks for a copy or deletion of their events.
    @objc public private(set) dynamic var activePresenceRightsContact: String = ""

    /// Whether THIS candidate granted monitoring at the consent screen. The
    /// detector may only run when this is true (checked at the single
    /// coordinator start site). Default false — a session nobody consented to
    /// never monitors.
    @objc public private(set) dynamic var activePresenceMonitoringGranted: Bool = false
    /// "pending" | "granted" | "declined". Mirrors the server's consent state.
    @objc public private(set) dynamic var activePresenceConsentState: String = "pending"

    /// The ONLY writer of the granted/state pair while a connection is being set up.
    /// Called from the consent screen's decision handler before the connect proceeds,
    /// so the start site downstream reads a settled value. The per-connection reset
    /// below is the only other writer, and it runs strictly earlier.
    @objc public func recordPresenceConsent(granted: Bool, state: String) {
        let valid = ["pending", "granted", "declined"]
        activePresenceMonitoringGranted = granted
        activePresenceConsentState = valid.contains(state) ? state : "pending"
        interLogInfo(InterLog.networking,
                     "RoomController: presence consent recorded (granted=%d, state=%{public}@)",
                     granted ? 1 : 0, activePresenceConsentState)
    }

    /// Clear the consent pair for a NEW connection.
    ///
    /// Consent is a per-ROOM fact, but this controller is created once at launch and
    /// outlives every session (AppDelegate creates it in `-applicationDidFinishLaunching`
    /// and releases it only in `-applicationWillTerminate`), so without this a candidate
    /// who granted monitoring in one interview would still read `granted == true` in the
    /// next one — and the detector's single start site would run with no consent for that
    /// session. Called synchronously at the top of BOTH public connect entry points, on
    /// the caller's (main) queue, so it is ordered strictly BEFORE the server's answer
    /// (which lands in a main-queue block from the token completion) and before the
    /// pre-connect consent gate runs.
    ///
    /// DO NOT call this from `handleTokenResponse`: that runs on the token completion's
    /// thread and its main-queue hop would land AFTER the join branch's assignment,
    /// clobbering the server's answer.
    ///
    /// The arming block is not reset here. It is assigned unconditionally by each of the
    /// four connect paths from the server's own answer — see §2.2.1 of the design note — and
    /// on the lobby-admitted path that assignment happens via `applyMeetingSettingsFromDict`
    /// BEFORE `connect(withToken:…)` is called, so resetting it here would clobber it.
    private func resetPresenceConsentForNewConnection() {
        activePresenceMonitoringGranted = false
        activePresenceConsentState = "pending"
    }

    /// Assign the presence block from a `/meetings/:id/start` (scheduled meeting) response.
    ///
    /// `/meetings/:id/start` never arms a room and returns no key beginning `presence`, so
    /// `presenceMonitoringArmed` parses false by its backward-compatible default and this
    /// reduces to the shipped defaults — which is the correct answer for a path the server
    /// never arms. It is assigned rather than skipped so a room armed earlier in the same
    /// app session cannot leak its arming state into a scheduled interview.
    func applyPresenceSettingsFromScheduledMeeting(_ response: InterCreateRoomResponse) {
        activePresenceMonitoringArmed      = response.presenceMonitoringArmed
        activePresenceRetentionDays        = 90
        activePresenceRegionEU             = false
        activePresenceUnder18              = false
        activePresenceMultipleFacesEnabled = false
        activePresenceDetectorVersion      = ""
        activePresenceThresholds           = ""
        activePresenceRightsContact        = ""
    }

    // MARK: - Meeting Settings Helpers

    /// Apply meeting settings from a dictionary (used on the lobby-admitted path where
    /// settings arrive in the polling response, not via `joinRoom`).
    /// Callable from Objective-C. Must be called on the main thread.
    @objc public func applyMeetingSettingsFromDict(_ dict: [AnyHashable: Any]) {
        activeMeetingDisplayName = dict["meetingDisplayName"] as? String ?? ""
        activeMuteOnJoin         = dict["muteOnJoin"]         as? Bool ?? false
        activeCameraOffOnJoin    = dict["cameraOffOnJoin"]    as? Bool ?? false
        activeJoinBeforeHost     = dict["joinBeforeHost"]     as? Bool ?? false
        activeAllowUnmuting      = dict["allowUnmuting"]      as? Bool ?? true
        activeChatPermissions    = dict["chatPermissions"]    as? String ?? "everyone"
        activeSharingPermissions = dict["sharingPermissions"] as? String ?? "hostOnly"
        activeShareConflictPolicy = dict["shareConflictPolicy"] as? String ?? "oneattime"
        activeAutoRecord         = dict["autoRecord"]         as? Bool ?? false
        activeAutoTranscript     = dict["autoTranscript"]     as? Bool ?? false
        activeHasPassword        = dict["hasPassword"]        as? Bool ?? false
        activeLobbyEnabled       = dict["lobbyEnabled"]       as? Bool ?? false
        // PRESENCE MONITORING (provisional). Mirrors the join-branch assignment
        // for the lobby-admitted path. An absent key means armed == false, which
        // is also exactly what a flag-off server produces.
        activePresenceMonitoringArmed      = dict["presenceMonitoringArmed"]      as? Bool ?? false
        activePresenceRetentionDays        = dict["presenceRetentionDays"]        as? Int ?? 90
        activePresenceRegionEU             = dict["presenceRegionEU"]             as? Bool ?? false
        activePresenceUnder18              = dict["presenceUnder18"]              as? Bool ?? false
        activePresenceMultipleFacesEnabled = dict["presenceMultipleFacesEnabled"] as? Bool ?? false
        activePresenceDetectorVersion      = dict["presenceDetectorVersion"]      as? String ?? ""
        activePresenceThresholds           = dict["presenceThresholds"]           as? String ?? ""
        activePresenceRightsContact        = dict["presenceRightsContact"]        as? String ?? ""
    }

    /// Update the active "meeting has a password" flag mid-session. Called after the host
    /// or a co-host successfully sets or removes the password so the moderation menu state
    /// stays in sync with the server.
    @objc public func updateHasMeetingPassword(_ hasPassword: Bool) {
        activeHasPassword = hasPassword
    }

    /// Update the active waiting-room (lobby) flag mid-session. Called after THIS client
    /// successfully toggles the lobby, and when a `.lobbyStateChanged` signal is received
    /// from another moderator, so `activeLobbyEnabled` stays the single source of truth.
    /// Being KVO-observable, this drives any open lobby panel to converge.
    @objc public func updateLobbyEnabled(_ enabled: Bool) {
        activeLobbyEnabled = enabled
    }

    /// Update the active share-conflict policy mid-meeting.
    @objc public func updateShareConflictPolicy(_ policy: String) {
        let valid = ["oneattime", "hostCanPreempt", "anyCanPreempt"]
        guard valid.contains(policy) else { return }
        activeShareConflictPolicy = policy
    }

    /// Update the active screen sharing permissions mid-meeting.
    /// Called when the host changes the mode via the control panel.
    @objc public func updateSharingPermissions(_ mode: String) {
        let valid = ["everyone", "request", "hostOnly"]
        guard valid.contains(mode) else { return }
        activeSharingPermissions = mode
    }

    // MARK: - Private Properties

    /// The LiveKit Room instance. Created fresh for each connection.
    private var room: Room?

    /// The room configuration for the current session.
    private var configuration: InterRoomConfiguration?

    /// Private serial queue for state transitions.
    private let stateQueue = DispatchQueue(label: "inter.room.state", qos: .userInitiated)

    /// Grace timer for participant-left delay. [G6]
    private var participantGraceTimer: DispatchSourceTimer?

    /// Token auto-refresh timer. Fires at ~80% of TTL to keep the session alive.
    private var tokenRefreshTimer: DispatchSourceTimer?

    /// Memory pressure source for graceful degradation under low-memory conditions.
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    /// Whether screen share was unpublished due to memory pressure (for auto-restore).
    private var screenShareSuspendedForMemory = false

    /// Debounce work item for clearing active speaker identity.
    /// Prevents green border flicker when VAD briefly sends active=false during continuous speech.
    private var activeSpeakerClearWork: DispatchWorkItem?

    /// Cooldown interval (seconds) before clearing the active speaker border.
    private let activeSpeakerClearDelay: TimeInterval = 1.0

    /// Flag to prevent double-connect.
    private(set) var isConnecting = false

    /// Connect timestamp for duration tracking.
    private var connectStartTime: CFAbsoluteTime = 0

    /// Session start timestamp (for disconnect duration logging).
    private var sessionStartTime: CFAbsoluteTime = 0

    /// Optional pre-connect consent gate. Invoked on the main queue AFTER the token and
    /// roomType are known but BEFORE any LiveKit connection is established. The gate calls
    /// `decide(true)` to proceed or `decide(false)` to abort. When nil (default), the
    /// connection proceeds immediately (unchanged behaviour).
    ///
    /// SECURITY (consent-before-connect): a declined gate means `room.connect()` is never
    /// called, so the user never gains presence, never auto-subscribes to remote media, and
    /// never enters an active recording — consent is a true precondition, not an afterthought.
    @objc public var preConnectConsentGate: ((_ roomType: String, _ isHost: Bool, _ decide: @escaping (Bool) -> Void) -> Void)?

    // MARK: - Connect

    /// Connect to a LiveKit room.
    ///
    /// - If `configuration.isHost` is true, creates a new room and receives a room code.
    /// - If `configuration.isHost` is false, joins an existing room using `configuration.roomCode`.
    ///
    /// - Parameters:
    ///   - configuration: Room connection settings.
    ///   - completion: Called on main queue with optional error.
    @objc public func connect(
        configuration: InterRoomConfiguration,
        completion: @escaping (NSError?) -> Void
    ) {
        guard connectionState == .disconnected || connectionState == .disconnectedWithError else {
            interLogError(InterLog.networking, "RoomController: connect called in state %d, ignoring",
                          connectionState.rawValue)
            completion(InterNetworkErrorCode.connectionFailed.error(message: "Already connected or connecting"))
            return
        }

        guard !isConnecting else {
            interLogError(InterLog.networking, "RoomController: double-connect prevented")
            completion(InterNetworkErrorCode.connectionFailed.error(message: "Connection already in progress"))
            return
        }

        isConnecting = true
        self.configuration = configuration.copy() as? InterRoomConfiguration
        connectStartTime = CFAbsoluteTimeGetCurrent()
        // PRESENCE MONITORING (provisional, server flag default OFF). This is a NEW
        // room, so the previous room's consent is void. Placed after the two guards
        // above so a rejected double-connect cannot clear a live session's consent.
        resetPresenceConsentForNewConnection()

        setConnectionState(.connecting)

        interLogInfo(InterLog.networking, "RoomController: connecting (isHost=%d, identity=%{public}@)",
                     configuration.isHost ? 1 : 0, configuration.participantIdentity)

        // Step 1: Obtain a token from the token server
        if !configuration.scheduledMeetingId.isEmpty {
            // Scheduled meeting: /meetings/:id/start registers the room in Redis and
            // returns the appropriate host or participant token based on the caller.
            tokenService.startScheduledMeeting(
                meetingId: configuration.scheduledMeetingId,
                serverURL: configuration.tokenServerURL,
                identity: configuration.participantIdentity,
                displayName: configuration.participantName,
                password: configuration.meetingPassword,
                settingsOverride: configuration.scheduledSettingsOverride
            ) { [weak self] response, error in
                // The scheduled host is the same user who created the meeting, but the
                // client cannot know that until the server confirms it. Propagate the
                // server-authoritative isHost onto our stored configuration so
                // `roomController.isHost` (and the moderation controller's localRole,
                // derived from it in attach()) reflect host status and the host UI loads.
                if let self = self, let r = response, error == nil {
                    DispatchQueue.main.async {
                        if r.isHost { self.configuration?.isHost = true }
                        // PRESENCE MONITORING (provisional, server flag default OFF).
                        // Assigned unconditionally, exactly like the create and join
                        // branches, so a room armed earlier in the same app session
                        // cannot leak its arming state into a scheduled interview.
                        // /meetings/:id/start never arms a room and returns no presence
                        // key, so this resolves to armed == false.
                        self.applyPresenceSettingsFromScheduledMeeting(r)
                        // Apply the meeting-settings snapshot the server stored at
                        // schedule time (parity with the /room/join settings block).
                        // Without this, scheduled meetings ran on server defaults
                        // regardless of what the host configured when scheduling.
                        if let s = r.roomSettings {
                            self.activeMeetingDisplayName  = s["meetingDisplayName"] as? String ?? ""
                            self.activeMuteOnJoin          = s["muteOnJoin"] as? Bool ?? false
                            self.activeCameraOffOnJoin     = s["cameraOffOnJoin"] as? Bool ?? false
                            self.activeJoinBeforeHost      = s["joinBeforeHost"] as? Bool ?? false
                            self.activeAllowUnmuting       = s["allowUnmuting"] as? Bool ?? true
                            self.activeChatPermissions     = s["chatPermissions"] as? String ?? "everyone"
                            self.activeSharingPermissions  = s["sharingPermissions"] as? String ?? "hostOnly"
                            self.activeShareConflictPolicy = s["shareConflictPolicy"] as? String ?? "oneattime"
                            self.activeHasPassword         = s["hasPassword"] as? Bool ?? false
                            // Without this the scheduled host's lobby UI never
                            // enabled — participants waited in an invisible lobby.
                            self.activeLobbyEnabled        = s["lobbyEnabled"] as? Bool ?? false
                        }
                    }
                }
                self?.handleTokenResponse(
                    token: response?.token,
                    serverURL: response?.serverURL ?? configuration.serverURL,
                    roomCode: response?.roomCode,
                    roomType: response?.roomType ?? "call",
                    isHost: response?.isHost ?? false,
                    error: error,
                    completion: completion
                )
            }
        } else if configuration.isHost {
            tokenService.createRoom(
                serverURL: configuration.tokenServerURL,
                identity: configuration.participantIdentity,
                displayName: configuration.participantName,
                roomType: configuration.roomType.isEmpty ? "call" : configuration.roomType,
                settings: configuration.meetingSettingsDict
            ) { [weak self] response, error in
                if let self = self, error == nil {
                    // Apply host-configured settings immediately (from local config)
                    DispatchQueue.main.async {
                        self.activeMeetingDisplayName = configuration.meetingDisplayName
                        self.activeMuteOnJoin         = configuration.muteOnJoin
                        self.activeCameraOffOnJoin    = configuration.cameraOffOnJoin
                        self.activeJoinBeforeHost     = configuration.joinBeforeHost
                        self.activeLobbyEnabled       = configuration.lobbyEnabled
                        self.activeAllowUnmuting      = configuration.allowUnmuting
                        self.activeChatPermissions    = configuration.chatPermissions
                        self.activeSharingPermissions = configuration.sharingPermissions
                        self.activeAutoRecord         = configuration.autoRecord
                        self.activeAutoTranscript     = configuration.autoTranscript
                        self.activeHasPassword        = !configuration.meetingPassword.isEmpty
                        // PRESENCE MONITORING (provisional, server flag default OFF).
                        // The SERVER's arming answer, echoed on /room/create and
                        // absent unless the room was really armed — never the host's
                        // own request. Assigned unconditionally so a previously armed
                        // room cannot leak its state into the next room this app
                        // session creates.
                        self.activePresenceMonitoringArmed =
                            response?.presenceMonitoringArmed ?? false
                        self.activePresenceRegionEU   = configuration.candidateRegionEU
                        self.activePresenceUnder18    = configuration.candidateUnder18
                    }
                }
                self?.handleTokenResponse(
                    token: response?.token,
                    serverURL: response?.serverURL ?? configuration.serverURL,
                    roomCode: response?.roomCode,
                    roomType: response?.roomType ?? "call",
                    isHost: true,
                    error: error,
                    completion: completion
                )
            }
        } else {
            tokenService.joinRoom(
                serverURL: configuration.tokenServerURL,
                roomCode: configuration.roomCode,
                identity: configuration.participantIdentity,
                displayName: configuration.participantName,
                password: configuration.meetingPassword
            ) { [weak self] response, error in
                if let self = self, let r = response, error == nil {
                    // Apply server-returned meeting settings for participants
                    DispatchQueue.main.async {
                        self.activeMeetingDisplayName  = r.meetingDisplayName
                        self.activeMuteOnJoin          = r.muteOnJoin
                        self.activeCameraOffOnJoin     = r.cameraOffOnJoin
                        self.activeJoinBeforeHost      = r.joinBeforeHost
                        self.activeAllowUnmuting       = r.allowUnmuting
                        self.activeChatPermissions     = r.chatPermissions
                        self.activeSharingPermissions  = r.sharingPermissions
                        self.activeShareConflictPolicy = r.shareConflictPolicy
                        self.activeAutoRecord          = r.autoRecord
                        self.activeAutoTranscript      = r.autoTranscript
                        self.activeHasPassword         = r.hasPassword
                        // Reflect the server-authoritative lobby state so a joiner who is
                        // (or is promoted to) a moderator renders the in-call lobby toggle
                        // correctly and toggles it from the right baseline.
                        self.activeLobbyEnabled        = r.lobbyEnabled
                        // PRESENCE MONITORING (provisional, server flag default OFF).
                        // Assigned HERE — inside the same main-queue block the
                        // activeLobbyEnabled assignment relies on — so the
                        // pre-connect consent gate observes a settled value. The
                        // server omits the block entirely when the flag is off, so
                        // `armed` is then false and the legacy NSAlert path runs.
                        self.activePresenceMonitoringArmed      = r.presenceMonitoringArmed
                        self.activePresenceRetentionDays        = r.presenceRetentionDays
                        self.activePresenceRegionEU             = r.presenceRegionEU
                        self.activePresenceUnder18              = r.presenceUnder18
                        self.activePresenceMultipleFacesEnabled = r.presenceMultipleFacesEnabled
                        self.activePresenceDetectorVersion      = r.presenceDetectorVersion
                        self.activePresenceThresholds           = r.presenceThresholds
                        self.activePresenceRightsContact        = r.presenceRightsContact
                        // The server restores host status when the original host
                        // rejoins (matched by authenticated userId). Reflect it so the
                        // returning host's client shows host UI again.
                        if r.isHost { self.configuration?.isHost = true }
                    }
                }
                self?.handleTokenResponse(
                    token: response?.token,
                    serverURL: response?.serverURL ?? configuration.serverURL,
                    roomCode: configuration.roomCode,
                    roomType: response?.roomType ?? "call",
                    isHost: response?.isHost ?? false,
                    error: error,
                    completion: completion
                )
            }
        }
    }

    /// Connect directly with an existing token (used after lobby admission).
    ///
    /// Bypasses the token-server fetch since the token was already obtained
    /// during the lobby admission flow.
    @objc public func connect(
        withToken token: String,
        serverURL: String,
        configuration: InterRoomConfiguration,
        completion: @escaping (NSError?) -> Void
    ) {
        guard connectionState == .disconnected || connectionState == .disconnectedWithError else {
            completion(InterNetworkErrorCode.connectionFailed.error(message: "Already connected or connecting"))
            return
        }
        guard !isConnecting else {
            completion(InterNetworkErrorCode.connectionFailed.error(message: "Connection already in progress"))
            return
        }

        isConnecting = true
        self.configuration = configuration.copy() as? InterRoomConfiguration
        connectStartTime = CFAbsoluteTimeGetCurrent()
        // PRESENCE MONITORING (provisional, server flag default OFF). New room, so the
        // previous room's consent is void. Only the consent pair is reset here: the
        // caller has already applied this room's settings dict (and with it the arming
        // block) via -applyMeetingSettingsFromDict, and that dict carries no consent.
        resetPresenceConsentForNewConnection()
        setConnectionState(.connecting)

        interLogInfo(InterLog.networking, "RoomController: connecting with existing token (lobby admitted, identity=%{public}@)",
                     configuration.participantIdentity)

        handleTokenResponse(
            token: token,
            serverURL: serverURL,
            roomCode: configuration.roomCode,
            roomType: configuration.roomType.isEmpty ? "call" : configuration.roomType,
            isHost: configuration.isHost,
            error: nil,
            completion: completion
        )
    }

    /// Handle the token server response and connect to the LiveKit room.
    private func handleTokenResponse(
        token: String?,
        serverURL: String,
        roomCode: String?,
        roomType: String,
        isHost: Bool,
        error: NSError?,
        completion: @escaping (NSError?) -> Void
    ) {
        if let error = error {
            interLogError(InterLog.networking, "RoomController: token fetch failed: %{public}@",
                          error.localizedDescription)
            isConnecting = false
            // Expected join rejections (bad/expired code, password required/incorrect,
            // lobby waiting, locked, full, banned, host-not-present) are NOT connection
            // failures. Mapping them to .disconnected prevents the media wiring
            // controller from layering the mid-call "Connection Lost" alert on top of
            // the specific, inline message the setup panel already displays.
            let isExpectedRejection = error.domain == InterNetworkErrorDomain
                && (InterNetworkErrorCode(rawValue: error.code)?.isExpectedJoinRejection ?? false)
            setConnectionState(isExpectedRejection ? .disconnected : .disconnectedWithError)
            completion(error)
            return
        }

        guard let token = token else {
            interLogError(InterLog.networking, "RoomController: token is nil but no error")
            isConnecting = false
            setConnectionState(.disconnectedWithError)
            completion(InterNetworkErrorCode.tokenFetchFailed.error(message: "Token was nil"))
            return
        }

        // Store room code and room type on main queue (synchronous if already on main,
        // otherwise dispatched before the async connect begins).
        if let code = roomCode, !code.isEmpty {
            DispatchQueue.main.async {
                self.roomCode = code
            }
        }
        // roomType must be set before the connect completion fires so AppDelegate
        // can read it — use sync dispatch if off main, direct assignment if on main.
        if Thread.isMainThread {
            self.roomType = roomType
        } else {
            DispatchQueue.main.sync {
                self.roomType = roomType
            }
        }

        // PRE-CONNECT CONSENT GATE: give the caller a chance to confirm BEFORE any LiveKit
        // connection. A declined gate means we never connect — no presence, no autoSubscribe,
        // no recording exposure. `isHost` is the server-authoritative value (threaded in by
        // the caller), so a returning interview host correctly bypasses the interviewee gate.
        if let gate = self.preConnectConsentGate {
            let proceed: (Bool) -> Void = { [weak self] accepted in
                guard let self = self else { return }
                if accepted {
                    self.performLiveKitConnect(serverURL: serverURL, token: token, completion: completion)
                } else {
                    self.handleConsentDeclined(completion: completion)
                }
            }
            DispatchQueue.main.async {
                gate(roomType, isHost, proceed)
            }
            return
        }

        // No gate installed — connect immediately (unchanged behaviour).
        performLiveKitConnect(serverURL: serverURL, token: token, completion: completion)
    }

    /// Abort a connection the user declined at the pre-connect gate. Releases the
    /// server-side slot reserved by token issuance (the user never actually connected to
    /// LiveKit), resets connect state, and reports a clean `.consentDeclined` rejection so
    /// the UI shows a normal "declined" message rather than a connection error.
    private func handleConsentDeclined(completion: @escaping (NSError?) -> Void) {
        interLogInfo(InterLog.networking, "RoomController: connection declined at consent gate — releasing slot")
        let code = self.roomCode.isEmpty ? (self.configuration?.roomCode ?? "") : self.roomCode
        if let config = self.configuration, !code.isEmpty {
            tokenService.leaveRoom(
                serverURL: config.tokenServerURL,
                roomCode: code,
                identity: config.participantIdentity
            )
        }
        isConnecting = false
        setConnectionState(.disconnected)
        let err = InterNetworkErrorCode.consentDeclined.error(message: "Interview session declined")
        DispatchQueue.main.async { completion(err) }
    }

    /// Create the LiveKit Room and connect. Extracted from `handleTokenResponse` so the
    /// pre-connect consent gate can defer (or veto) the actual connection.
    private func performLiveKitConnect(serverURL: String, token: String, completion: @escaping (NSError?) -> Void) {
        // Step 2: Create and connect the LiveKit Room
        let connectOptions = ConnectOptions(
            autoSubscribe: true,
            reconnectAttempts: 3,
            reconnectAttemptDelay: 2.0
        )

        // Phase 7.2.1: Enable adaptive streaming — LiveKit automatically adjusts
        // video resolution/framerate based on subscriber viewport size.
        let roomOptions = RoomOptions(
            adaptiveStream: true,
            dynacast: true
        )

        let newRoom = Room(delegate: self, connectOptions: connectOptions, roomOptions: roomOptions)

        // Clean up previous room if any (e.g. retry after error)
        if let oldRoom = self.room {
            self.subscriber.detach()
            oldRoom.remove(delegate: self)
        }

        self.room = newRoom
        self.publisher.localParticipant = newRoom.localParticipant
        self.subscriber.attach(to: newRoom)

        // Async connect
        Task {
            do {
                try await newRoom.connect(url: serverURL, token: token)

                let latencyMs = Int((CFAbsoluteTimeGetCurrent() - self.connectStartTime) * 1000)
                interLogInfo(InterLog.networking, "RoomController: connected (latency=%dms)", latencyMs)

                self.sessionStartTime = CFAbsoluteTimeGetCurrent()
                self.isConnecting = false
                self.setConnectionState(.connected)

                // Update publisher reference (in case localParticipant changed after connect)
                self.publisher.localParticipant = newRoom.localParticipant

                // Create stats collector
                let collector = InterCallStatsCollector()
                collector.start(room: newRoom)
                self.statsCollector = collector

                // Schedule token auto-refresh [4.5.4]
                self.scheduleTokenRefresh()

                // Start memory pressure monitor
                self.startMemoryPressureMonitor()

                // Update participant count
                self.updateParticipantPresence()

                DispatchQueue.main.async {
                    completion(nil)
                }
            } catch {
                let latencyMs = Int((CFAbsoluteTimeGetCurrent() - self.connectStartTime) * 1000)

                // Extract LiveKit error details when available for diagnostics
                let detail: String
                if let lkError = error as? NSError,
                   lkError.domain == "io.livekit.swift-sdk" {
                    let underlying = lkError.userInfo[NSUnderlyingErrorKey] as? NSError
                    detail = "code=\(lkError.code) desc=\(lkError.localizedDescription)"
                        + (underlying.map { " underlying=\($0.localizedDescription)" } ?? "")
                } else {
                    detail = error.localizedDescription
                }

                interLogError(InterLog.networking, "RoomController: connect failed after %dms: %{public}@",
                              latencyMs, detail)

                self.isConnecting = false
                self.setConnectionState(.disconnectedWithError)

                let nsError = InterNetworkErrorCode.connectionFailed.error(
                    message: "Room connect failed",
                    underlyingError: error
                )
                DispatchQueue.main.async {
                    completion(nsError)
                }
            }
        }
    }

    // MARK: - Disconnect

    /// Disconnect from the room. Unpublishes all tracks and cleans up.
    @objc public func disconnect() {
        disconnect(reason: "user initiated")
    }

    private func disconnect(reason: String) {
        guard connectionState != .disconnected else { return }

        interLogInfo(InterLog.networking, "RoomController: disconnecting (reason=%{public}@)", reason)

        // Notify the server so the participant count is updated immediately
        if let config = configuration, !config.roomCode.isEmpty {
            let identity = room?.localParticipant.identity?.stringValue ?? config.participantIdentity
            tokenService.leaveRoom(
                serverURL: config.tokenServerURL,
                roomCode: config.roomCode,
                identity: identity
            )
        }

        // Stop stats collector and export data
        if let collector = statsCollector {
            if let jsonData = collector.exportToJSON() {
                let byteCount = jsonData.count
                interLogInfo(InterLog.networking, "RoomController: exported %d bytes of call stats JSON", byteCount)
                // Store in a well-known location for later retrieval / debugging
                if let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyyMMdd_HHmmss"
                    let filename = "inter_call_stats_\(formatter.string(from: Date())).json"
                    let fileURL = cachesDir.appendingPathComponent(filename)
                    do {
                        try jsonData.write(to: fileURL)
                        interLogInfo(InterLog.networking, "RoomController: stats saved to %{public}@", fileURL.path)
                    } catch {
                        interLogError(InterLog.networking, "RoomController: failed to write stats: %{public}@",
                                      error.localizedDescription)
                    }
                }
            }
            collector.stop()
        }
        statsCollector = nil

        // Unpublish all tracks (fire-and-forget)
        publisher.unpublishAll(captureSession: nil, sessionQueue: nil)
        publisher.localParticipant = nil

        // Detach subscriber
        subscriber.detach()

        // Cancel grace timer
        cancelGraceTimer()

        // Cancel token refresh timer
        cancelTokenRefreshTimer()

        // Stop memory pressure monitor
        stopMemoryPressureMonitor()

        // Disconnect room
        if let room = room {
            Task {
                await room.disconnect()
            }
        }
        room = nil

        // Log session duration
        if sessionStartTime > 0 {
            let durationSecs = Int(CFAbsoluteTimeGetCurrent() - sessionStartTime)
            interLogInfo(InterLog.networking, "RoomController: session duration=%ds", durationSecs)
        }

        // Reset state
        configuration = nil
        isConnecting = false
        sessionStartTime = 0
        connectStartTime = 0

        // Drop all session rename overrides — the next meeting starts from attested names.
        clearAllSessionDisplayNames()

        setConnectionState(.disconnected)

        DispatchQueue.main.async {
            self.remoteParticipantCount = 0
            self.participantPresenceState = .alone
            self.activeSpeakerClearWork?.cancel()
            self.activeSpeakerClearWork = nil
            self.activeSpeakerIdentity = ""
            self.roomCode = ""
            self.roomType = ""
        }
    }

    // MARK: - G4: Mode Transition

    /// Transition between call modes (Normal ↔ Secure).
    /// Unpublishes all tracks and detaches sources, but keeps the room connected.
    /// The subscriber stays active so remote frames continue flowing.
    ///
    /// After completion, the caller re-attaches sources and re-publishes.
    @objc public func transitionMode(completion: @escaping () -> Void) {
        guard connectionState == .connected || connectionState == .reconnecting else {
            interLogInfo(InterLog.networking, "RoomController: transitionMode — not connected, skipping")
            completion()
            return
        }

        interLogInfo(InterLog.networking, "RoomController: mode transition — detaching sources")

        // Unpublish all tracks, then detach sources
        publisher.unpublishAll(captureSession: nil, sessionQueue: nil) { [weak self] in
            self?.publisher.detachAllSources()
            interLogInfo(InterLog.networking, "RoomController: mode transition complete — ready for re-attach")
            completion()
        }
    }

    // MARK: - Token Refresh

    /// Schedule a timer to refresh the token at ~80% of its TTL.
    /// Called after connect and after each successful refresh.
    private func scheduleTokenRefresh() {
        cancelTokenRefreshTimer()

        guard let config = configuration else { return }
        let code = roomCode.isEmpty ? config.roomCode : roomCode
        let ttl = tokenService.cachedTokenTTL(forRoom: code, identity: config.participantIdentity)

        // If TTL is unknown or already expired, try refreshing in 60 seconds
        let interval: TimeInterval
        if ttl > 60 {
            // Fire at 80% of remaining TTL (e.g. 5-minute token → refresh at 4 minutes)
            interval = ttl * 0.8
        } else if ttl > 0 {
            // Less than 60s — refresh immediately
            interval = 1.0
        } else {
            // Unknown TTL — default to 4 minutes (typical LiveKit token is 5-10 min)
            interval = 240.0
        }

        interLogInfo(InterLog.networking, "RoomController: scheduling token refresh in %ds (TTL=%.0fs)",
                     Int(interval), ttl)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval)
        timer.setEventHandler { [weak self] in
            self?.refreshToken()
        }
        timer.resume()
        tokenRefreshTimer = timer
    }

    private func cancelTokenRefreshTimer() {
        tokenRefreshTimer?.cancel()
        tokenRefreshTimer = nil
    }

    /// Refresh the authentication token. Called when token is about to expire.
    private func refreshToken() {
        guard let config = configuration, connectionState == .connected else { return }

        let code = roomCode.isEmpty ? config.roomCode : roomCode

        interLogInfo(InterLog.networking, "RoomController: refreshing token")

        tokenService.refreshToken(
            serverURL: config.tokenServerURL,
            roomCode: code,
            identity: config.participantIdentity
        ) { [weak self] token, error in
            if let error = error {
                interLogError(InterLog.networking, "RoomController: token refresh failed: %{public}@",
                              error.localizedDescription)
                // Don't disconnect — the SDK will handle token expiry via reconnection.
                // Schedule a retry in 30 seconds
                self?.scheduleTokenRefreshRetry()
                return
            }

            guard let token = token else { return }

            interLogInfo(InterLog.networking, "RoomController: token refreshed successfully")

            // Note: LiveKit SDK currently doesn't expose a public API to update the token
            // on an existing room connection. The token will be used on the next reconnect.
            // For now, we store it in the token service cache.
            _ = token

            // Reschedule refresh based on the new token's TTL
            self?.scheduleTokenRefresh()
        }
    }

    /// Schedule a short retry after a failed refresh attempt.
    private func scheduleTokenRefreshRetry() {
        cancelTokenRefreshTimer()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30.0)
        timer.setEventHandler { [weak self] in
            self?.refreshToken()
        }
        timer.resume()
        tokenRefreshTimer = timer

        interLogInfo(InterLog.networking, "RoomController: token refresh retry scheduled in 30s")
    }

    // MARK: - Memory Pressure Response

    /// Start monitoring system memory pressure.
    /// On `.warning`: log but keep going (screen share stays up).
    /// On `.critical`: unpublish screen share to free memory.
    private func startMemoryPressureMonitor() {
        stopMemoryPressureMonitor()

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let event = source.data
            if event.contains(.critical) {
                self.handleMemoryPressureCritical()
            } else if event.contains(.warning) {
                self.handleMemoryPressureWarning()
            }
        }
        source.resume()
        memoryPressureSource = source
        interLogInfo(InterLog.networking, "RoomController: memory pressure monitor started")
    }

    private func stopMemoryPressureMonitor() {
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        screenShareSuspendedForMemory = false
    }

    private func handleMemoryPressureWarning() {
        interLogInfo(InterLog.networking, "RoomController: memory pressure WARNING — monitoring")
        // Log a diagnostic note; screen share stays active.
        // The system may reclaim memory from other processes first.
    }

    private func handleMemoryPressureCritical() {
        interLogError(InterLog.networking, "RoomController: memory pressure CRITICAL — unpublishing screen share")

        guard publisher.screenSharePublication != nil else { return }
        screenShareSuspendedForMemory = true
        publisher.unpublishScreenShare {
            interLogInfo(InterLog.networking, "RoomController: screen share unpublished (memory pressure)")
        }
    }

    // MARK: - State Management

    private func setConnectionState(_ newState: InterRoomConnectionState) {
        DispatchQueue.main.async {
            let oldState = self.connectionState
            guard oldState != newState else { return }
            // A fresh connect attempt clears any stale disconnect reason.
            if newState == .connecting { self.lastDisconnectReason = .none }
            self.connectionState = newState
            interLogInfo(InterLog.networking, "RoomController: state %d → %d", oldState.rawValue, newState.rawValue)
        }
    }

    // MARK: - G6: Participant Presence

    private func updateParticipantPresence() {
        guard let room = room else { return }

        let count = room.remoteParticipants.count

        DispatchQueue.main.async {
            self.remoteParticipantCount = count

            if count > 0 {
                // Cancel any pending grace timer — participant(s) present
                self.cancelGraceTimer()
                self.participantPresenceState = .participantJoined
            } else if self.participantPresenceState == .participantJoined {
                // Start 3-second grace timer before surfacing .participantLeft
                self.startGraceTimer()
            }
            // If already .alone, stay .alone
        }
    }

    private func startGraceTimer() {
        cancelGraceTimer()

        interLogInfo(InterLog.networking, "RoomController: participant left — starting 3s grace timer")

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 3.0)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            // Double-check: participant might have reconnected during grace period
            if self.remoteParticipantCount == 0 {
                self.participantPresenceState = .participantLeft
                interLogInfo(InterLog.networking, "RoomController: grace timer expired — participant left")
            }
        }
        timer.resume()
        participantGraceTimer = timer
    }

    private func cancelGraceTimer() {
        participantGraceTimer?.cancel()
        participantGraceTimer = nil
    }

    // MARK: - Phase 8: Participant List for DM Selector

    /// Returns an array of dictionaries with "identity" and "name" keys
    /// for each remote participant currently in the room.
    @objc public func remoteParticipantList() -> [[String: String]] {
        guard let room = room else { return [] }
        return room.remoteParticipants.values.map { participant in
            [
                "identity": participant.identity?.stringValue ?? "",
                "name": participant.name ?? participant.identity?.stringValue ?? "Unknown"
            ]
        }
    }

    /// Returns the display name for a remote participant by their identity.
    /// Returns an empty string if the identity is not found in the room.
    @objc public func displayNameForParticipantIdentity(_ identity: String) -> String {
        guard let room = room else { return "" }
        let participant = room.remoteParticipants.values.first {
            $0.identity?.stringValue == identity
        }
        return participant?.name ?? participant?.identity?.stringValue ?? ""
    }

    // MARK: - Session display-name overrides

    /// Session-only display-name overrides (identity → name), set when a participant is
    /// renamed — by a host or by themselves — via the `.renameParticipant` control signal.
    /// This is the single authority for a participant's *effective* name: chat, tiles, and
    /// notifications all resolve through `effectiveDisplayName(for:)`. Ephemeral — cleared
    /// when the participant leaves or the session resets, so a rejoining participant
    /// reverts to their attested (server-stamped) join name. Guarded by a lock because the
    /// rename-accept write and the chat-receive read can arrive on different queues.
    private var sessionDisplayNames: [String: String] = [:]
    private let sessionDisplayNamesLock = NSLock()

    /// Set or update the session display-name override for a participant.
    @objc public func setSessionDisplayName(_ name: String, forIdentity identity: String) {
        guard !identity.isEmpty, !name.isEmpty else { return }
        sessionDisplayNamesLock.lock()
        sessionDisplayNames[identity] = name
        sessionDisplayNamesLock.unlock()
    }

    /// Remove a participant's session display-name override (e.g. when they leave the room).
    @objc public func clearSessionDisplayName(forIdentity identity: String) {
        sessionDisplayNamesLock.lock()
        sessionDisplayNames.removeValue(forKey: identity)
        sessionDisplayNamesLock.unlock()
    }

    /// Clear every session display-name override. Call on disconnect/teardown.
    @objc public func clearAllSessionDisplayNames() {
        sessionDisplayNamesLock.lock()
        sessionDisplayNames.removeAll()
        sessionDisplayNamesLock.unlock()
    }

    /// The effective display name for a participant: a session rename override if one
    /// exists, otherwise the attested (server-stamped) LiveKit name. Returns "" if unknown.
    /// This is the single source of truth for how a participant's name is shown.
    @objc public func effectiveDisplayName(for identity: String) -> String {
        sessionDisplayNamesLock.lock()
        let override = sessionDisplayNames[identity]
        sessionDisplayNamesLock.unlock()
        if let override = override, !override.isEmpty { return override }
        return displayNameForParticipantIdentity(identity)
    }

    /// Returns the role of a remote participant by reading their LiveKit metadata.
    /// Falls back to `.participant` if the identity is not found or has no role metadata.
    @objc public func role(forParticipantIdentity identity: String) -> InterParticipantRole {
        guard let room = room else { return .participant }
        let participant = room.remoteParticipants.values.first {
            $0.identity?.stringValue == identity
        }
        return InterParticipantMetadata.parseRole(from: participant?.metadata)
    }
}

// MARK: - RoomDelegate

extension InterRoomController: RoomDelegate {

    // MARK: Connection Events

    public nonisolated func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        // Map LiveKit ConnectionState to our InterRoomConnectionState
        let mapped: InterRoomConnectionState
        switch connectionState {
        case .disconnected:
            mapped = .disconnected
        case .connecting:
            mapped = .connecting
        case .reconnecting:
            mapped = .reconnecting
        case .connected:
            mapped = .connected
        @unknown default:
            mapped = .disconnected
        }

        interLogInfo(InterLog.networking, "RoomController: LiveKit connectionState → %d", mapped.rawValue)
        self.setConnectionState(mapped)
    }

    public nonisolated func roomDidConnect(_ room: Room) {
        interLogInfo(InterLog.networking, "RoomController: roomDidConnect")
        self.setConnectionState(.connected)
    }

    public nonisolated func roomIsReconnecting(_ room: Room) {
        interLogInfo(InterLog.networking, "RoomController: roomIsReconnecting")
        self.setConnectionState(.reconnecting)
    }

    public nonisolated func roomDidReconnect(_ room: Room) {
        interLogInfo(InterLog.networking, "RoomController: roomDidReconnect")
        self.setConnectionState(.connected)
        self.updateParticipantPresence()
        // Re-schedule token refresh after reconnect (the old token may have been used)
        DispatchQueue.main.async {
            self.scheduleTokenRefresh()
        }
    }

    public nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        // Classify the disconnect so the UI can show the right thing. A host-driven
        // removal or meeting-end is intentional — it must NOT surface as a generic
        // "Connection Lost" alert.
        let reason: InterRoomDisconnectReason
        if let error = error {
            switch error.type {
            case .participantRemoved: reason = .removedByHost
            case .roomDeleted:        reason = .roomEnded
            default:                  reason = .error
            }
        } else {
            reason = .clientInitiated
        }
        // Publish the reason on main BEFORE the state change so the connectionState
        // observer reads the up-to-date value (both hops are FIFO on the main queue).
        DispatchQueue.main.async { self.lastDisconnectReason = reason }

        if error != nil {
            interLogError(InterLog.networking, "RoomController: disconnected with error (reason=%d): %{public}@",
                          reason.rawValue, error?.localizedDescription ?? "")
            self.setConnectionState(.disconnectedWithError)
        } else {
            interLogInfo(InterLog.networking, "RoomController: disconnected cleanly")
            self.setConnectionState(.disconnected)
        }

        // [Phase 10] Auto-stop recording on room disconnect.
        // configuration and roomCode are main-thread-owned properties; read them
        // inside the main.async block so all accesses are properly serialised.
        // If disconnect(reason:) already ran and cleared configuration before this
        // block executes, the coordinator receives nil — that is safe, because a
        // user-initiated disconnect will have already stopped the recording.
        DispatchQueue.main.async {
            let serverURL = self.configuration?.tokenServerURL
            let code = self.roomCode.isEmpty ? nil : self.roomCode
            let identity = self.configuration?.participantIdentity
            self.recordingCoordinator?.handleRoomDisconnect(
                serverURL: serverURL,
                roomCode: code,
                callerIdentity: identity
            )
        }
    }

    // MARK: Participant Events [G6]

    public nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        interLogInfo(InterLog.networking, "RoomController: participant connected: %{public}@",
                     participant.identity?.stringValue ?? "(unknown)")
        self.updateParticipantPresence()
    }

    public nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        interLogInfo(InterLog.networking, "RoomController: participant disconnected: %{public}@",
                     participant.identity?.stringValue ?? "(unknown)")
        // Drop any session rename override so the map stays bounded and a future joiner
        // reusing the identity cannot inherit a stale name.
        if let id = participant.identity?.stringValue {
            self.clearSessionDisplayName(forIdentity: id)
        }
        self.updateParticipantPresence()
    }

    // MARK: Participant Metadata [role reconciliation]

    /// A participant's metadata changed. For the LOCAL participant this carries an
    /// authoritative role update — the server stamps `{role:...}` into LiveKit metadata
    /// on promotion/demotion. Reconcile the local role here so moderation UI recovers
    /// even when the one-shot `.roleChanged` DataChannel signal was missed (reconnect,
    /// late join). Remote participants' roles are read on demand by the tile layer.
    public nonisolated func room(_ room: Room, participant: Participant, didUpdateMetadata metadata: String?) {
        guard participant is LocalParticipant else { return }
        DispatchQueue.main.async {
            self.chatController?.moderationController?.updateLocalRole(from: metadata)
        }
    }

    // MARK: Active Speakers

    public nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        // Find the loudest remote participant (first in the sorted list that isn't local)
        let remoteSpeaker = participants.first { $0 is RemoteParticipant }
        let identity = remoteSpeaker?.identity?.stringValue ?? ""

        DispatchQueue.main.async {
            // [Phase 10] Forward active speaker change to recording coordinator.
            // Must run on the main thread — weak reference reads and the coordinator's
            // own threading contract both require main-queue access here.
            self.recordingCoordinator?.activeSpeakerDidChange(identity)

            // Cancel any pending "clear speaker" timer.
            self.activeSpeakerClearWork?.cancel()
            self.activeSpeakerClearWork = nil

            if !identity.isEmpty {
                // Active remote speaker detected — update immediately.
                if self.activeSpeakerIdentity != identity {
                    self.activeSpeakerIdentity = identity
                    interLogInfo(InterLog.networking, "RoomController: active speaker → %{public}@", identity)
                }
            } else {
                // No remote speaker right now. Debounce the clear so brief VAD
                // dips (breaths, pauses between words) don't flicker the border.
                guard !self.activeSpeakerIdentity.isEmpty else { return }

                let work = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.activeSpeakerIdentity = ""
                    self.activeSpeakerClearWork = nil
                    interLogInfo(InterLog.networking, "RoomController: active speaker → (none) [debounced]")
                }
                self.activeSpeakerClearWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + self.activeSpeakerClearDelay, execute: work)
            }
        }
    }

    // MARK: DataChannel [Phase 8]

    public nonisolated func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        let senderIdentity = participant?.identity?.stringValue
        interLogDebug(InterLog.room, "RoomController: received data (%d bytes) on topic '%{public}@' from %{public}@",
                      data.count, topic, senderIdentity ?? "server")

        DispatchQueue.main.async {
            switch topic {
            case "poll":
                self.pollController?.handleReceivedData(data, senderIdentity: senderIdentity)
            case "qa":
                self.qaController?.handleReceivedData(data, senderIdentity: senderIdentity)
            default:
                self.chatController?.handleReceivedData(data, topic: topic, participant: senderIdentity)
            }
        }
    }
}
