// ============================================================================
// InterModerationController.swift
// inter
//
// Phase 9.2 — Client-side moderation controller.
//
// Orchestrates all Phase 9 meeting management actions:
//   • Server-authoritative: mute, mute-all, remove, lock, suspend (HTTP)
//   • DataChannel-based: disable chat, ask to unmute, force spotlight
//   • Lobby management: admit, deny, admit-all (HTTP)
//   • Password management: set, remove (HTTP)
//   • Role management: promote/demote (HTTP)
//
// OWNERSHIP:
//   Created by AppDelegate. Holds weak refs to roomController & chatController.
//   Uses InterTokenService's URLSession pattern for HTTP calls.
//
// THREADING:
//   All public methods on main queue. Completion blocks on main queue.
//   HTTP calls happen on the URLSession's delegate queue.
//
// ISOLATION INVARIANT [G8]:
//   If nil, the app works identically — just no moderation controls.
// ============================================================================

import Foundation
import os.log
import LiveKit

// MARK: - Moderation Delegate

/// Delegate protocol for moderation events received from server or DataChannel.
/// Implemented by AppDelegate to update UI.
@objc public protocol InterModerationDelegate: AnyObject {

    /// Chat has been disabled/enabled by the host.
    @objc func moderationController(_ controller: InterModerationController,
                                    chatDisabledStateChanged isDisabled: Bool)

    /// A participant is asking us to unmute.
    @objc func moderationController(_ controller: InterModerationController,
                                    receivedUnmuteRequest fromIdentity: String,
                                    displayName: String)

    /// The meeting has been locked/unlocked.
    @objc func moderationController(_ controller: InterModerationController,
                                    meetingLockStateChanged isLocked: Bool)

    /// A participant has been suspended/unsuspended.
    @objc func moderationController(_ controller: InterModerationController,
                                    participantSuspendStateChanged identity: String,
                                    isSuspended: Bool)

    /// Host is forcing a spotlight on a specific participant.
    @objc func moderationController(_ controller: InterModerationController,
                                    forceSpotlightOnParticipant identity: String)

    /// Host cleared the forced spotlight.
    @objc func moderationControllerDidClearForceSpotlight(_ controller: InterModerationController)

    /// We (local participant) have been removed from the room.
    @objc func moderationControllerLocalParticipantWasRemoved(_ controller: InterModerationController)

    /// A participant's role has changed.
    @objc func moderationController(_ controller: InterModerationController,
                                    participantRoleChanged identity: String,
                                    newRole: String)

    /// A new participant is waiting in the lobby.
    @objc optional func moderationController(_ controller: InterModerationController,
                                             lobbyParticipantJoined identity: String,
                                             displayName: String)

    /// Host has requested all participants to unmute their microphones.
    @objc optional func moderationControllerReceivedUnmuteAllRequest(_ controller: InterModerationController)

    /// Host has muted all participants' microphones (server-side).
    /// The participant should update local state and UI to reflect the muted mic.
    @objc optional func moderationControllerReceivedMuteAllRequest(_ controller: InterModerationController)

    /// A participant is requesting permission to speak (after host mute-all).
    @objc optional func moderationController(_ controller: InterModerationController,
                                             receivedSpeakRequest fromIdentity: String,
                                             displayName: String)

    /// Host has allowed us to unmute and speak.
    @objc optional func moderationControllerReceivedAllowToSpeak(_ controller: InterModerationController)
}

// MARK: - InterModerationController

@objc public class InterModerationController: NSObject {

    // MARK: - Public Properties

    /// Delegate for moderation events.
    @objc public weak var delegate: InterModerationDelegate?

    /// The local participant's role, derived from room metadata.
    @objc public private(set) dynamic var localRole: InterParticipantRole = .participant

    /// Whether chat is currently disabled by the host.
    @objc public private(set) dynamic var isChatDisabled: Bool = false

    /// Whether the meeting is currently locked.
    @objc public private(set) dynamic var isMeetingLocked: Bool = false

    /// Whether the local participant is suspended.
    @objc public private(set) dynamic var isLocalSuspended: Bool = false

    /// Whether all participants are currently muted (host-side toggle state).
    @objc public private(set) dynamic var isAllMuted: Bool = false

    /// The identity of the force-spotlighted participant (nil = no forced spotlight).
    @objc public private(set) dynamic var forceSpotlightIdentity: String = ""

    /// Accumulated lobby waiting participants: array of {"identity": ..., "displayName": ...}.
    /// Populated by lobbyJoin signals, pruned by admit/deny/admitAll.
    @objc public private(set) var lobbyWaitingParticipants: [[String: String]] = []

    /// Role info for the local participant (convenience wrapper).
    @objc public var localRoleInfo: InterRoleInfo {
        return InterRoleInfo(role: localRole, identity: localIdentity)
    }

    // MARK: - Private Properties

    private weak var roomController: InterRoomController?
    private var localIdentity: String = ""
    private var localDisplayName: String = ""
    private var serverURL: String = ""
    private var roomCode: String = ""
    private let session: URLSession

    // MARK: - Init

    @objc public override init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 15.0
        self.session = URLSession(configuration: config)
        super.init()
    }

    // MARK: - Attach / Detach

    /// Attach to a room controller. Call after room is connected.
    @objc public func attach(to roomController: InterRoomController,
                             identity: String,
                             displayName: String,
                             serverURL: String,
                             roomCode: String) {
        self.roomController = roomController
        self.localIdentity = identity
        self.localDisplayName = displayName
        self.serverURL = serverURL
        self.roomCode = roomCode

        // Parse local role from room controller's host status
        if roomController.isHost {
            self.localRole = .host
        } else {
            self.localRole = .participant
        }

        interLogInfo(InterLog.room, "ModerationController: attached (role=%{public}@)", localRole.stringValue)
    }

    /// Detach and reset state. Call on disconnect.
    @objc public func detach() {
        roomController = nil
        localIdentity = ""
        localDisplayName = ""
        serverURL = ""
        roomCode = ""
        localRole = .participant
        isChatDisabled = false
        isMeetingLocked = false
        isLocalSuspended = false
        isAllMuted = false
        forceSpotlightIdentity = ""
        lobbyWaitingParticipants = []
    }

    // MARK: - Role Management (9.1.3)

    /// Update local role when metadata changes (e.g. after promotion).
    @objc public func updateLocalRole(from metadata: String?) {
        let newRole = InterParticipantMetadata.parseRole(from: metadata)
        if newRole != localRole {
            let oldRole = localRole
            localRole = newRole
            interLogInfo(InterLog.room, "ModerationController: local role changed %{public}@ -> %{public}@",
                         oldRole.stringValue, newRole.stringValue)
        }
    }

    /// Promote or demote a participant. Server-authoritative.
    @objc public func promoteParticipant(identity: String,
                                         toRole newRole: InterParticipantRole,
                                         completion: @escaping (Bool, NSError?) -> Void) {
        guard InterPermissionMatrix.role(localRole, hasPermission: .canPromoteParticipants) else {
            completion(false, makeError("Insufficient permissions"))
            return
        }

        let body: [String: Any] = [
            "roomCode": roomCode,
            "callerIdentity": localIdentity,
            "targetIdentity": identity,
            "newRole": newRole.stringValue,
        ]

        performPOST(endpoint: "/room/promote", body: body) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                // Broadcast role change via DataChannel
                self.sendControlSignal(type: .roleChanged, targetIdentity: identity,
                                       extraData: ["newRole": newRole.stringValue])
                self.completeOnMain { completion(true, nil) }
            case .failure(let error):
                self.completeOnMain { completion(false, error) }
            }
        }
    }

    // MARK: - Mute Controls (9.2.1)

    /// Mute a specific participant's microphone or camera. Server-authoritative.
    @objc public func muteParticipant(identity: String,
                                      trackSource: String,
                                      completion: @escaping (Bool, NSError?) -> Void) {
        guard InterPermissionMatrix.role(localRole, hasPermission: .canMuteOthers) else {
            completion(false, makeError("Insufficient permissions"))
            return
        }

        let body: [String: Any] = [
            "roomCode": roomCode,
            "callerIdentity": localIdentity,
            "targetIdentity": identity,
            "trackSource": trackSource,
        ]

        performPOST(endpoint: "/room/mute", body: body) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                interLogInfo(InterLog.room, "ModerationController: muted %{private}@ (%{public}@)",
                             identity, trackSource)
                self.completeOnMain { completion(true, nil) }
            case .failure(let error):
                self.completeOnMain { completion(false, error) }
            }
        }
    }

    /// Mute all participants' audio. Server-authoritative.
    @objc public func muteAll(completion: @escaping (Bool, Int, NSError?) -> Void) {
        guard InterPermissionMatrix.role(localRole, hasPermission: .canMuteOthers) else {
            completion(false, 0, makeError("Insufficient permissions"))
            return
        }

        let body: [String: Any] = [
            "roomCode": roomCode,
            "callerIdentity": localIdentity,
        ]

        performPOST(endpoint: "/room/mute-all", body: body) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let data):
                let json = self.parseJSON(data)
                let count = json?["mutedCount"] as? Int ?? 0
                interLogInfo(InterLog.room, "ModerationController: muted all (%d participants)", count)
                // Broadcast DataChannel signal so participants update their local UI
                self.sendControlSignal(type: .requestMuteAll)
                self.completeOnMain {
                    self.isAllMuted = true
                    completion(true, count, nil)
                }
            case .failure(let error):
                self.completeOnMain { completion(false, 0, error) }
            }
        }
    }

    /// Request all participants to unmute their microphones via DataChannel.
    /// LiveKit does not allow server-side unmute, so we broadcast a control
    /// signal and each client unmutes locally.
    @objc public func unmuteAll(completion: @escaping (Bool, Int, NSError?) -> Void) {
        guard InterPermissionMatrix.role(localRole, hasPermission: .canMuteOthers) else {
            completion(false, 0, makeError("Insufficient permissions"))
            return
        }

        sendControlSignal(type: .requestUnmuteAll)
        interLogInfo(InterLog.room, "ModerationController: broadcast requestUnmuteAll signal")
        completeOnMain {
            self.isAllMuted = false
            completion(true, 0, nil)
        }
    }

    // MARK: - Disable Chat (9.2.2)

    /// Disable chat for all participants. DataChannel-based.
    @objc public func disableChat() {
        guard InterPermissionMatrix.role(localRole, hasPermission: .canDisableChat) else { return }
        sendControlSignal(type: .disableChat)
        completeOnMain {
            self.isChatDisabled = true
            self.delegate?.moderationController(self, chatDisabledStateChanged: true)
        }
    }

    /// Re-enable chat. DataChannel-based.
    @objc public func enableChat() {
        guard InterPermissionMatrix.role(localRole, hasPermission: .canDisableChat) else { return }
        sendControlSignal(type: .enableChat)
        completeOnMain {
            self.isChatDisabled = false
            self.delegate?.moderationController(self, chatDisabledStateChanged: false)
        }
    }

    // MARK: - Remove Participant (9.2.3)

    /// Remove a participant from the room. Server-authoritative.
    @objc public func removeParticipant(identity: String,
                                        completion: @escaping (Bool, NSError?) -> Void) {
        guard InterPermissionMatrix.role(localRole, hasPermission: .canRemoveParticipant) else {
            completion(false, makeError("Insufficient permissions"))
            return
        }

        let body: [String: Any] = [
            "roomCode": roomCode,
            "callerIdentity": localIdentity,
            "targetIdentity": identity,
        ]

        performPOST(endpoint: "/room/remove", body: body) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                // Signal after server confirms removal so the target is only
                // notified when the removal actually succeeds.
                self.sendControlSignal(type: .participantRemoved, targetIdentity: identity)
                interLogInfo(InterLog.room, "ModerationController: removed %{private}@", identity)
                self.completeOnMain { completion(true, nil) }
            case .failure(let error):
                self.completeOnMain { completion(false, error) }
            }
        }
    }

    // MARK: - Ask to Unmute (9.2.4)

    /// Send a soft unmute request to a participant via DataChannel.
    @objc public func askToUnmute(identity: String) {
        guard InterPermissionMatrix.role(localRole, hasPermission: .canAskToUnmute) else { return }
        sendControlSignal(type: .askToUnmute, targetIdentity: identity)
        interLogInfo(InterLog.room, "ModerationController: asked %{private}@ to unmute", identity)
    }

    // MARK: - Request to Speak / Allow to Speak

    /// Send a request-to-speak signal from a participant to the host.
    @objc public func requestToSpeak() {
        sendControlSignal(type: .requestToSpeak)
        interLogInfo(InterLog.room, "ModerationController: sent requestToSpeak")
    }

    /// Allow a participant to speak (unmute). Sent by host/cohost to a specific participant.
    @objc public func allowToSpeak(identity: String) {
        guard InterPermissionMatrix.role(localRole, hasPermission: .canMuteOthers) else { return }
        sendControlSignal(type: .allowToSpeak, targetIdentity: identity)
        interLogInfo(InterLog.room, "ModerationController: allowed %{private}@ to speak", identity)
    }

    // MARK: - Lock Meeting (9.2.6)

    /// Lock the meeting (prevent new joins). Server-authoritative + DataChannel broadcast.
    @objc public func lockMeeting(completion: @escaping (Bool, NSError?) -> Void) {
        guard InterPermissionMatrix.role(localRole, hasPermission: .canLockMeeting) else {
            completion(false, makeError("Insufficient permissions"))
            return
        }

        let body: [String: Any] = [
            "roomCode": roomCode,
            "callerIdentity": localIdentity,
        ]

        performPOST(endpoint: "/room/lock", body: body) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.sendControlSignal(type: .meetingLocked)
                self.completeOnMain {
                    self.isMeetingLocked = true
                    self.delegate?.moderationController(self, meetingLockStateChanged: true)
                    completion(true, nil)
                }
            case .failure(let error):
                self.completeOnMain { completion(false, error) }
            }
        }
    }

    /// Unlock the meeting. Server-authoritative + DataChannel broadcast.
    @objc public func unlockMeeting(completion: @escaping (Bool, NSError?) -> Void) {
        guard InterPermissionMatrix.role(localRole, hasPermission: .canLockMeeting) else {
            completion(false, makeError("Insufficient permissions"))
            return
        }

        let body: [String: Any] = [
            "roomCode": roomCode,
            "callerIdentity": localIdentity,
        ]

        performPOST(endpoint: "/room/unlock", body: body) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.sendControlSignal(type: .meetingUnlocked)
                self.completeOnMain {
                    self.isMeetingLocked = false
                    self.delegate?.moderationController(self, meetingLockStateChanged: false)
                    completion(true, nil)
                }
            case .failure(let error):
                self.completeOnMain { completion(false, error) }
            }
        }
    }

    // MARK: - Suspend (9.2.7)

    /// Suspend a participant. Server-authoritative + DataChannel notification.
    @objc public func suspendParticipant(identity: String,
                                         completion: @escaping (Bool, NSError?) -> Void) {
        guard InterPermissionMatrix.role(localRole, hasPermission: .canSuspendParticipant) else {
            completion(false, makeError("Insufficient permissions"))
            return
        }

        let body: [String: Any] = [
            "roomCode": roomCode,
            "callerIdentity": localIdentity,
            "targetIdentity": identity,
        ]

        performPOST(endpoint: "/room/suspend", body: body) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.sendControlSignal(type: .suspended, targetIdentity: identity)
                interLogInfo(InterLog.room, "ModerationController: suspended %{private}@", identity)
                self.completeOnMain {
                    self.delegate?.moderationController(self, participantSuspendStateChanged: identity,
                                                       isSuspended: true)
                    completion(true, nil)
                }
            case .failure(let error):
                self.completeOnMain { completion(false, error) }
            }
        }
    }

    /// Unsuspend a participant. Server-authoritative + DataChannel notification.
    @objc public func unsuspendParticipant(identity: String,
                                           completion: @escaping (Bool, NSError?) -> Void) {
        guard InterPermissionMatrix.role(localRole, hasPermission: .canSuspendParticipant) else {
            completion(false, makeError("Insufficient permissions"))
            return
        }

        let body: [String: Any] = [
            "roomCode": roomCode,
            "callerIdentity": localIdentity,
            "targetIdentity": identity,
        ]

        performPOST(endpoint: "/room/unsuspend", body: body) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.sendControlSignal(type: .unsuspended, targetIdentity: identity)
                interLogInfo(InterLog.room, "ModerationController: unsuspended %{private}@", identity)
                self.completeOnMain {
                    self.delegate?.moderationController(self, participantSuspendStateChanged: identity,
                                                       isSuspended: false)
                    completion(true, nil)
                }
            case .failure(let error):
                self.completeOnMain { completion(false, error) }
            }
        }
    }

    // MARK: - Force Spotlight (9.2.8)

    /// Force-spotlight a participant for all viewers. DataChannel-based.
    @objc public func forceSpotlight(identity: String) {
        guard InterPermissionMatrix.role(localRole, hasPermission: .canForceSpotlight) else { return }
        sendControlSignal(type: .forceSpotlight, targetIdentity: identity)
        completeOnMain {
            self.forceSpotlightIdentity = identity
            self.delegate?.moderationController(self, forceSpotlightOnParticipant: identity)
        }
    }

    /// Clear forced spotlight. DataChannel-based.
    @objc public func clearForceSpotlight() {
        guard InterPermissionMatrix.role(localRole, hasPermission: .canForceSpotlight) else { return }
        sendControlSignal(type: .clearForceSpotlight)
        completeOnMain {
            self.forceSpotlightIdentity = ""
            self.delegate?.moderationControllerDidClearForceSpotlight(self)
        }
    }

    // MARK: - Lobby Management (9.3)

    /// Admit a participant from the lobby. Server-authoritative.
    @objc public func admitFromLobby(identity: String,
                                     displayName: String,
                                     completion: @escaping (Bool, NSError?) -> Void) {
        guard InterPermissionMatrix.role(localRole, hasPermission: .canAdmitFromLobby) else {
            completion(false, makeError("Insufficient permissions"))
            return
        }

        let body: [String: Any] = [
            "roomCode": roomCode,
            "callerIdentity": localIdentity,
            "targetIdentity": identity,
            "targetDisplayName": displayName,
        ]

        performPOST(endpoint: "/room/admit", body: body) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.completeOnMain {
                    self.lobbyWaitingParticipants.removeAll { $0["identity"] == identity }
                    interLogInfo(InterLog.room, "ModerationController: admitted %{private}@ from lobby", identity)
                    completion(true, nil)
                }
            case .failure(let error):
                self.completeOnMain { completion(false, error) }
            }
        }
    }

    /// Admit all participants from the lobby. Server-authoritative.
    @objc public func admitAllFromLobby(completion: @escaping (Bool, Int, NSError?) -> Void) {
        guard InterPermissionMatrix.role(localRole, hasPermission: .canAdmitFromLobby) else {
            completion(false, 0, makeError("Insufficient permissions"))
            return
        }

        let body: [String: Any] = [
            "roomCode": roomCode,
            "callerIdentity": localIdentity,
        ]

        performPOST(endpoint: "/room/admit-all", body: body) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let data):
                let json = self.parseJSON(data)
                let count = json?["admittedCount"] as? Int ?? 0
                self.completeOnMain {
                    self.lobbyWaitingParticipants.removeAll()
                    interLogInfo(InterLog.room, "ModerationController: admitted all (%d) from lobby", count)
                    completion(true, count, nil)
                }
            case .failure(let error):
                self.completeOnMain { completion(false, 0, error) }
            }
        }
    }

    /// Deny a participant from the lobby. Server-authoritative.
    @objc public func denyFromLobby(identity: String,
                                    completion: @escaping (Bool, NSError?) -> Void) {
        guard InterPermissionMatrix.role(localRole, hasPermission: .canAdmitFromLobby) else {
            completion(false, makeError("Insufficient permissions"))
            return
        }

        let body: [String: Any] = [
            "roomCode": roomCode,
            "callerIdentity": localIdentity,
            "targetIdentity": identity,
        ]

        performPOST(endpoint: "/room/deny", body: body) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.completeOnMain {
                    self.lobbyWaitingParticipants.removeAll { $0["identity"] == identity }
                    interLogInfo(InterLog.room, "ModerationController: denied %{private}@ from lobby", identity)
                    completion(true, nil)
                }
            case .failure(let error):
                self.completeOnMain { completion(false, error) }
            }
        }
    }

    /// Enable the lobby/waiting room. Server-authoritative.
    @objc public func enableLobby(completion: @escaping (Bool, NSError?) -> Void) {
        guard InterPermissionMatrix.role(localRole, hasPermission: .canAdmitFromLobby) else {
            completion(false, makeError("Insufficient permissions"))
            return
        }

        let body: [String: Any] = [
            "roomCode": roomCode,
            "callerIdentity": localIdentity,
        ]

        performPOST(endpoint: "/room/lobby/enable", body: body) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.completeOnMain { completion(true, nil) }
            case .failure(let error):
                self.completeOnMain { completion(false, error) }
            }
        }
    }

    /// Disable the lobby/waiting room. Server-authoritative.
    @objc public func disableLobby(completion: @escaping (Bool, NSError?) -> Void) {
        guard InterPermissionMatrix.role(localRole, hasPermission: .canAdmitFromLobby) else {
            completion(false, makeError("Insufficient permissions"))
            return
        }

        let body: [String: Any] = [
            "roomCode": roomCode,
            "callerIdentity": localIdentity,
        ]

        performPOST(endpoint: "/room/lobby/disable", body: body) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.completeOnMain { completion(true, nil) }
            case .failure(let error):
                self.completeOnMain { completion(false, error) }
            }
        }
    }

    // MARK: - Password Management (9.4)

    /// Set or change the meeting password. Server-authoritative.
    @objc public func setPassword(_ password: String,
                                  completion: @escaping (Bool, NSError?) -> Void) {
        guard InterPermissionMatrix.role(localRole, hasPermission: .canManagePassword) else {
            completion(false, makeError("Insufficient permissions"))
            return
        }

        let body: [String: Any] = [
            "roomCode": roomCode,
            "callerIdentity": localIdentity,
            "password": password,
        ]

        performPOST(endpoint: "/room/password", body: body) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                interLogInfo(InterLog.room, "ModerationController: password set")
                self.completeOnMain { completion(true, nil) }
            case .failure(let error):
                self.completeOnMain { completion(false, error) }
            }
        }
    }

    /// Remove the meeting password. Server-authoritative.
    @objc public func removePassword(completion: @escaping (Bool, NSError?) -> Void) {
        guard InterPermissionMatrix.role(localRole, hasPermission: .canManagePassword) else {
            completion(false, makeError("Insufficient permissions"))
            return
        }

        let body: [String: Any] = [
            "roomCode": roomCode,
            "callerIdentity": localIdentity,
            "password": NSNull(),
        ]

        performPOST(endpoint: "/room/password", body: body) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                interLogInfo(InterLog.room, "ModerationController: password removed")
                self.completeOnMain { completion(true, nil) }
            case .failure(let error):
                self.completeOnMain { completion(false, error) }
            }
        }
    }

    // MARK: - Receive Control Signals

    /// Process an incoming control signal from the DataChannel.
    /// Called by the chat controller when it receives a Phase 9 signal type.
    public func handleControlSignal(_ signal: InterControlSignal) {
        // DataChannel callbacks arrive off-main; dispatch all state mutations
        // and delegate invocations to the main queue.
        completeOnMain { [weak self] in
            guard let self = self else { return }
            self._handleControlSignal(signal)
        }
    }

    /// Internal handler executed on the main queue.
    private func _handleControlSignal(_ signal: InterControlSignal) {
        let targetIsLocal = signal.targetIdentity == localIdentity

        switch signal.type {
        case .disableChat:
            isChatDisabled = true
            delegate?.moderationController(self, chatDisabledStateChanged: true)

        case .enableChat:
            isChatDisabled = false
            delegate?.moderationController(self, chatDisabledStateChanged: false)

        case .askToUnmute:
            if targetIsLocal {
                delegate?.moderationController(self, receivedUnmuteRequest: signal.senderIdentity,
                                               displayName: signal.senderName)
            }

        case .meetingLocked:
            isMeetingLocked = true
            delegate?.moderationController(self, meetingLockStateChanged: true)

        case .meetingUnlocked:
            isMeetingLocked = false
            delegate?.moderationController(self, meetingLockStateChanged: false)

        case .suspended:
            if targetIsLocal {
                isLocalSuspended = true
                delegate?.moderationController(self, participantSuspendStateChanged: localIdentity,
                                               isSuspended: true)
            } else if let target = signal.targetIdentity {
                delegate?.moderationController(self, participantSuspendStateChanged: target,
                                               isSuspended: true)
            }

        case .unsuspended:
            if targetIsLocal {
                isLocalSuspended = false
                delegate?.moderationController(self, participantSuspendStateChanged: localIdentity,
                                               isSuspended: false)
            } else if let target = signal.targetIdentity {
                delegate?.moderationController(self, participantSuspendStateChanged: target,
                                               isSuspended: false)
            }

        case .forceSpotlight:
            if let target = signal.targetIdentity {
                forceSpotlightIdentity = target
                delegate?.moderationController(self, forceSpotlightOnParticipant: target)
            }

        case .clearForceSpotlight:
            forceSpotlightIdentity = ""
            delegate?.moderationControllerDidClearForceSpotlight(self)

        case .participantRemoved:
            if targetIsLocal {
                delegate?.moderationControllerLocalParticipantWasRemoved(self)
            }

        case .roleChanged:
            if let target = signal.targetIdentity, let newRole = signal.extraData?["newRole"] {
                if target == localIdentity {
                    let role = InterParticipantRole.from(string: newRole)
                    localRole = role
                }
                delegate?.moderationController(self, participantRoleChanged: target, newRole: newRole)
            }

        case .lobbyJoin:
            if let target = signal.targetIdentity {
                // Track the participant so the panel can be populated on first open
                if !lobbyWaitingParticipants.contains(where: { $0["identity"] == target }) {
                    lobbyWaitingParticipants.append(["identity": target, "displayName": signal.senderName])
                }
                delegate?.moderationController?(self, lobbyParticipantJoined: target,
                                                displayName: signal.senderName)
            }

        case .requestUnmuteAll:
            interLogInfo(InterLog.room, "ModerationController: received requestUnmuteAll from %{public}@", signal.senderName)
            delegate?.moderationControllerReceivedUnmuteAllRequest?(self)

        case .requestMuteAll:
            interLogInfo(InterLog.room, "ModerationController: received requestMuteAll from %{public}@", signal.senderName)
            delegate?.moderationControllerReceivedMuteAllRequest?(self)

        case .requestToSpeak:
            interLogInfo(InterLog.room, "ModerationController: %{public}@ requests to speak", signal.senderName)
            delegate?.moderationController?(self, receivedSpeakRequest: signal.senderIdentity,
                                            displayName: signal.senderName)

        case .allowToSpeak:
            if targetIsLocal {
                interLogInfo(InterLog.room, "ModerationController: host allowed us to speak")
                delegate?.moderationControllerReceivedAllowToSpeak?(self)
            }

        default:
            break
        }
    }

    // MARK: - Private: Send Control Signal

    private func sendControlSignal(type: InterControlSignalType,
                                   targetIdentity: String? = nil,
                                   extraData: [String: String]? = nil) {
        guard let rc = roomController, rc.connectionState == .connected else { return }

        let signal = InterControlSignal(
            type: type,
            senderIdentity: localIdentity,
            senderName: localDisplayName,
            targetIdentity: targetIdentity,
            extraData: extraData
        )

        guard let data = signal.toJSONData() else {
            interLogError(InterLog.room, "ModerationController: failed to encode control signal")
            return
        }

        Task {
            do {
                let localParticipant = rc.publisher.localParticipant
                try await localParticipant?.publish(data: data, options: DataPublishOptions(
                    topic: "control",
                    reliable: true
                ))
                interLogDebug(InterLog.room, "ModerationController: sent control signal type=%d", type.rawValue)
            } catch {
                interLogError(InterLog.room, "ModerationController: control signal publish failed: %{public}@",
                              error.localizedDescription)
            }
        }
    }

    // MARK: - Private: HTTP

    private func performPOST(endpoint: String,
                              body: [String: Any],
                              completion: @escaping (Result<Data, NSError>) -> Void) {
        let urlString = "\(serverURL)\(endpoint)"
        guard let url = URL(string: urlString) else {
            completion(.failure(makeError("Invalid URL: \(urlString)")))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(makeError("Failed to serialize request body")))
            return
        }

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error as NSError))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  let data = data else {
                completion(.failure(self.makeError("No response from server")))
                return
            }

            if (200..<300).contains(httpResponse.statusCode) {
                completion(.success(data))
            } else {
                let bodyStr = String(data: data, encoding: .utf8) ?? ""
                let errorMsg = self.parseJSON(data)?["error"] as? String ?? "Server error \(httpResponse.statusCode)"
                completion(.failure(self.makeError(errorMsg)))
            }
        }
        task.resume()
    }

    private func parseJSON(_ data: Data) -> [String: Any]? {
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func makeError(_ message: String) -> NSError {
        return NSError(domain: "InterModeration", code: -1,
                       userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func completeOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}
