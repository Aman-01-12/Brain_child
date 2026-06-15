//
//  DevicePreferencesViewModel.swift
//  inter
//
//  Data source 3 of the unified Settings window: media device DEFAULTS.
//  Settings here choose the devices used at the NEXT session start — there is
//  deliberately no live capture-pipeline reconfiguration from this window
//  (in-call device switching stays in the in-call UI).
//
//    • Microphone — real device list via an injectable provider seam (the
//      bridge forwards to InterLocalMediaController / AVFoundation discovery).
//      Preference persists via the same key the media controller honors.
//    • Camera — device list via discovery; preference stored for the capture
//      session to apply on next start. "System default" when unset.
//    • Speaker — macOS routes output via the system; shown as a read-only
//      "System default" row (no per-app output API without heavier plumbing).
//

import Foundation
import Combine

public struct MediaDeviceOption: Equatable, Identifiable {
    public let id: String     // uniqueID, "" = system default sentinel
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Device discovery + preference store seam (bridge implements with AVFoundation).
public protocol InterDevicePreferencesProviding: AnyObject {
    func audioInputDevices() -> [MediaDeviceOption]
    func videoInputDevices() -> [MediaDeviceOption]
    func preferredAudioDeviceID() -> String?
    func preferredVideoDeviceID() -> String?
    func setPreferredAudioDeviceID(_ id: String?)
    func setPreferredVideoDeviceID(_ id: String?)
}

@MainActor
public final class DevicePreferencesViewModel: ObservableObject {

    @Published public private(set) var microphones: [MediaDeviceOption] = []
    @Published public private(set) var cameras: [MediaDeviceOption] = []
    @Published public var selectedMicrophoneID: String = "" {
        didSet {
            guard oldValue != selectedMicrophoneID else { return }
            provider.setPreferredAudioDeviceID(selectedMicrophoneID.isEmpty ? nil : selectedMicrophoneID)
        }
    }
    @Published public var selectedCameraID: String = "" {
        didSet {
            guard oldValue != selectedCameraID else { return }
            provider.setPreferredVideoDeviceID(selectedCameraID.isEmpty ? nil : selectedCameraID)
        }
    }

    /// Display path of the local-recordings folder (resolved default or custom).
    @Published public private(set) var recordingDirectoryPath: String = ""
    /// Whether a custom folder is set (enables "Reset to default").
    @Published public private(set) var recordingDirectoryIsCustom = false

    private let provider: InterDevicePreferencesProviding

    public init(provider: InterDevicePreferencesProviding) {
        self.provider = provider
    }

    public func load() {
        microphones = DevicePreferencesViewModel.withSystemDefault(provider.audioInputDevices())
        cameras = DevicePreferencesViewModel.withSystemDefault(provider.videoInputDevices())
        // Stale preference (device unplugged) falls back to system default.
        let mic = provider.preferredAudioDeviceID() ?? ""
        selectedMicrophoneID = microphones.contains(where: { $0.id == mic }) ? mic : ""
        let cam = provider.preferredVideoDeviceID() ?? ""
        selectedCameraID = cameras.contains(where: { $0.id == cam }) ? cam : ""
        reloadRecordingDirectory()
    }

    // MARK: - Recording location

    private func reloadRecordingDirectory() {
        recordingDirectoryPath = InterRecordingCoordinator.recordingsDirectory().path
        let stored = UserDefaults.standard.string(
            forKey: InterRecordingCoordinator.recordingsDirectoryDefaultsKey) ?? ""
        recordingDirectoryIsCustom = !stored.isEmpty
    }

    public func setRecordingDirectory(_ url: URL) {
        UserDefaults.standard.set(url.path,
            forKey: InterRecordingCoordinator.recordingsDirectoryDefaultsKey)
        reloadRecordingDirectory()
    }

    public func resetRecordingDirectory() {
        UserDefaults.standard.removeObject(
            forKey: InterRecordingCoordinator.recordingsDirectoryDefaultsKey)
        reloadRecordingDirectory()
    }

    // MARK: - Pure helpers (unit-tested)

    /// Prepend the "" System-default option to a device list.
    public nonisolated static func withSystemDefault(_ devices: [MediaDeviceOption]) -> [MediaDeviceOption] {
        [MediaDeviceOption(id: "", name: "System default")] + devices
    }
}
