//
//  MeetingDefaultsViewModel.swift
//  inter
//
//  Data source 2 of the unified Settings window: the saved meeting defaults
//  (InterPreMeetingSettings / UserDefaults) — the SAME store the pre-meeting
//  flow and the schedule screen's inline section read. Editing here is the
//  full-list defaults editor that used to be the AppKit defaults-editor window.
//
//  Recording auto-start toggles are tier-gated (pro/hiring): shown but disabled with
//  an upgrade note for free users — matching the pre-meeting panel's gating.
//

import Foundation
import Combine

@MainActor
public final class MeetingDefaultsViewModel: ObservableObject {

    @Published public var muteOnJoin: Bool
    @Published public var cameraOffOnJoin: Bool
    @Published public var allowUnmuting: Bool
    @Published public var lobbyEnabled: Bool
    @Published public var joinBeforeHost: Bool
    @Published public var chatPermissions: String
    @Published public var sharingPermissions: String
    @Published public var shareConflictPolicy: String
    @Published public var autoRecord: Bool
    @Published public var autoTranscript: Bool
    @Published public var allowCoHostLocalRecording: Bool

    @Published public var statusMessage: String?
    /// The user's tier — gates the recording group.
    @Published public var tier: String = "free"

    public init() {
        let s = InterPreMeetingSettings.withDefaults()
        muteOnJoin = s.muteOnJoin
        cameraOffOnJoin = s.cameraOffOnJoin
        allowUnmuting = s.allowUnmuting
        lobbyEnabled = s.lobbyEnabled
        joinBeforeHost = s.joinBeforeHost
        chatPermissions = s.chatPermissions
        sharingPermissions = s.sharingPermissions
        shareConflictPolicy = s.shareConflictPolicy
        autoRecord = s.autoRecord
        autoTranscript = s.autoTranscript
        allowCoHostLocalRecording = s.allowCoHostLocalRecording
    }

    public var isPaidTier: Bool { tier == "pro" || tier == "hiring" }

    /// Persist to the shared store (also marks hasConfiguredDefaults).
    public func save() {
        let s = InterPreMeetingSettings.withDefaults()
        s.muteOnJoin = muteOnJoin
        s.cameraOffOnJoin = cameraOffOnJoin
        s.allowUnmuting = allowUnmuting
        s.lobbyEnabled = lobbyEnabled
        s.joinBeforeHost = joinBeforeHost
        s.chatPermissions = chatPermissions
        s.sharingPermissions = sharingPermissions
        s.shareConflictPolicy = shareConflictPolicy
        // Recording prefs only persist for paid tiers (free can't enable them).
        if isPaidTier {
            s.autoRecord = autoRecord
            s.autoTranscript = autoTranscript
            s.allowCoHostLocalRecording = allowCoHostLocalRecording
        }
        s.saveToUserDefaults()
        statusMessage = "Defaults saved. New meetings will use these settings."
    }

    /// Re-read from the store (e.g. when the tab re-appears after the schedule
    /// screen modified the same defaults).
    public func reload() {
        let s = InterPreMeetingSettings.withDefaults()
        muteOnJoin = s.muteOnJoin
        cameraOffOnJoin = s.cameraOffOnJoin
        allowUnmuting = s.allowUnmuting
        lobbyEnabled = s.lobbyEnabled
        joinBeforeHost = s.joinBeforeHost
        chatPermissions = s.chatPermissions
        sharingPermissions = s.sharingPermissions
        shareConflictPolicy = s.shareConflictPolicy
        autoRecord = s.autoRecord
        autoTranscript = s.autoTranscript
        allowCoHostLocalRecording = s.allowCoHostLocalRecording
        statusMessage = nil
    }
}
