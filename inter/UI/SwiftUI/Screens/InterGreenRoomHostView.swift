//
//  InterGreenRoomHostView.swift
//  inter
//
//  Obj-C ⇆ SwiftUI bridge for the green room — and the owner of its real
//  infrastructure:
//
//    • Preview capture — its own InterLocalMediaController (prepare → start →
//      attachPreviewToView:), shut down via `teardown` BEFORE the call's media
//      controller starts, so the camera is never owned by two sessions.
//    • Device switching — mic switches live (selectAudioInputDeviceWithID:,
//      which persists InterPreferredAudioDeviceID); camera persists
//      InterPreferredVideoDeviceID and restarts the preview session (the
//      controller reads the key at configure). Same keys as Settings →
//      changing a device here changes the app default.
//    • Mic level meter — taps audioSampleBufferHandler, computes RMS
//      (Float32/Int16 per ASBD), throttled to the main thread.
//    • Speaker test — AVAudioEngine source node playing a 440 Hz sine through
//      the system output.
//    • Speaker name — CoreAudio default-output-device lookup (read-only row;
//      macOS routes app output system-wide).
//    • Network check — GET {tokenServer}/health with latency measurement,
//      refreshed periodically.
//
//  AppDelegate reads the user's join choices (micOn/camOn/displayName/meeting
//  name/password) from the @objc properties when `onPrimary` fires.
//

import AppKit
import AVFoundation
import CoreAudio
import SwiftUI

@objc public enum InterGreenRoomRole: Int {
    case hostCreate = 0
    case join = 1
    case hostInterview = 2
    case scheduledStart = 3
}

@objc(InterGreenRoomHostView)
public final class InterGreenRoomHostView: NSView {

    private let viewModel: GreenRoomViewModel
    private let previewContainer = NSView()
    private var hosting: NSHostingView<GreenRoomView>!

    private var mediaController: InterLocalMediaController?
    private var meterEngineOn = false
    private var toneEngine: AVAudioEngine?
    private var networkTimer: Timer?
    private var tokenServerURL: String = ""
    private var lastMeterPush = Date.distantPast

    /// Desired join states (the preview toggles drive these).
    @objc public private(set) var micOnChoice: Bool = true
    @objc public private(set) var camOnChoice: Bool = true

    @objc public var displayNameValue: String { viewModel.displayName }
    @objc public var meetingNameValue: String { viewModel.meetingName }
    /// Empty when "Require a password" is off or the field is blank.
    @objc public var passwordValue: String {
        PreMeetingViewModel.effectivePassword(requirePassword: viewModel.requirePassword,
                                              password: viewModel.password)
    }

    /// Fired on Start Meeting / Join Now / Start Interview (after local teardown).
    @objc public var onPrimary: (() -> Void)?
    /// Fired when the window should close without connecting.
    @objc public var onCancel: (() -> Void)?
    /// Host-create only: open the full pre-meeting sheet.
    @objc public var onOpenMeetingSettings: (() -> Void)?

    @objc public init(frame frameRect: NSRect, role: InterGreenRoomRole, roomCode: String) {
        let vmRole: GreenRoomRole
        switch role {
        case .hostCreate:     vmRole = .hostCreate
        case .join:           vmRole = .join(roomCode: roomCode)
        case .scheduledStart: vmRole = .scheduledStart(roomCode: roomCode)
        case .hostInterview:  vmRole = .hostInterview
        }
        self.viewModel = GreenRoomViewModel(role: vmRole)
        super.init(frame: frameRect)
        appearance = NSAppearance(named: .darkAqua) // §7.5 fixed-dark stage surface
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        networkTimer?.invalidate()
    }

    // MARK: - Wiring

    private func configure() {
        viewModel.onToggleMic = { [weak self] on in
            self?.micOnChoice = on
            self?.mediaController?.setMicrophoneEnabled(on, completion: nil)
        }
        viewModel.onToggleCam = { [weak self] on in
            self?.camOnChoice = on
            self?.mediaController?.setCameraEnabled(on, completion: nil)
        }
        viewModel.onSelectMic = { [weak self] id in
            // Live switch; the controller persists InterPreferredAudioDeviceID.
            self?.mediaController?.selectAudioInputDevice(withID: id.isEmpty ? nil : id,
                                                          completion: nil)
        }
        viewModel.onSelectCamera = { [weak self] id in
            guard let self else { return }
            // Persist the Settings-shared key, then restart the preview session
            // (the controller resolves the preferred camera at configure time).
            if id.isEmpty {
                UserDefaults.standard.removeObject(forKey: "InterPreferredVideoDeviceID")
            } else {
                UserDefaults.standard.set(id, forKey: "InterPreferredVideoDeviceID")
            }
            self.restartPreview()
        }
        viewModel.onPrimaryAction = { [weak self] in self?.finishAndSubmit() }
        viewModel.onJoinWithoutVideo = { [weak self] in self?.finishAndSubmit() }
        viewModel.onOpenMeetingSettings = { [weak self] in self?.onOpenMeetingSettings?() }
        viewModel.onCancel = { [weak self] in self?.onCancel?() }
        viewModel.onSetMicMetering = { [weak self] on in self?.setMicMetering(on) }
        viewModel.onStartSpeakerTest = { [weak self] in self?.startTone() }
        viewModel.onStopSpeakerTest = { [weak self] in self?.stopTone() }

        let host = NSHostingView(rootView: GreenRoomView(viewModel: viewModel,
                                                         previewContainer: previewContainer))
        host.translatesAutoresizingMaskIntoConstraints = false
        self.hosting = host
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        viewModel.speakerName = Self.defaultOutputDeviceName() ?? "System default"
    }

    // MARK: - Seeding (AppDelegate / pre-meeting sheet)

    @objc public func setDisplayName(_ name: String) {
        viewModel.displayName = name
    }

    @objc public func setMeetingName(_ name: String) {
        viewModel.meetingName = name
    }

    @objc public func setMeetingPassword(_ password: String) {
        viewModel.requirePassword = !password.isEmpty
        viewModel.password = password
    }

    @objc public func setUsingDefaultsCaption(_ caption: String) {
        viewModel.usingDefaultsCaption = caption
    }

    @objc public func setTokenServerURL(_ url: String) {
        tokenServerURL = url
        runNetworkCheck()
        networkTimer?.invalidate()
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runNetworkCheck() }
        }
        RunLoop.main.add(timer, forMode: .common)
        networkTimer = timer
    }

    // MARK: - Preview lifecycle

    @objc public func startPreview() {
        guard mediaController == nil else { return }
        let controller = InterLocalMediaController()
        mediaController = controller
        controller.attachPreview(to: previewContainer)
        controller.prepare { [weak self] success, _ in
            DispatchQueue.main.async {
                guard let self, let controller = self.mediaController else { return }
                guard success else {
                    self.viewModel.setDeviceStates(micOn: false, camOn: false)
                    self.micOnChoice = false
                    self.camOnChoice = false
                    return
                }
                controller.start()
                // Re-apply the user's choices across restarts (camera switch).
                controller.setMicrophoneEnabled(self.micOnChoice, completion: nil)
                controller.setCameraEnabled(self.camOnChoice, completion: nil)
                self.viewModel.setDeviceStates(micOn: self.micOnChoice, camOn: self.camOnChoice)
                self.reloadDeviceLists()
                if self.viewModel.deviceTestOpen { self.setMicMetering(true) }
            }
        }
    }

    /// Stop capture + tests. MUST run before the call's media controller starts.
    @objc public func teardown() {
        setMicMetering(false)
        stopTone()
        networkTimer?.invalidate()
        networkTimer = nil
        mediaController?.detachPreview()
        mediaController?.shutdown()
        mediaController = nil
    }

    private func restartPreview() {
        setMicMetering(false)
        mediaController?.detachPreview()
        mediaController?.shutdown()
        mediaController = nil
        startPreview()
    }

    private func finishAndSubmit() {
        teardown()
        onPrimary?()
    }

    // MARK: - Device lists

    private func reloadDeviceLists() {
        let mics: [MediaDeviceOption] = (mediaController?.availableAudioInputOptions() ?? [])
            .compactMap { dict in
                guard let id = dict["id"], let name = dict["name"] else { return nil }
                return MediaDeviceOption(id: id, name: name)
            }

        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external]
        if #available(macOS 14.0, *) { types.append(.continuityCamera) }
        let cams = AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                                    mediaType: .video,
                                                    position: .unspecified)
            .devices.map { MediaDeviceOption(id: $0.uniqueID, name: $0.localizedName) }

        let selectedMic = mediaController?.selectedAudioInputDeviceID() ?? ""
        let storedCam = UserDefaults.standard.string(forKey: "InterPreferredVideoDeviceID") ?? ""
        let selectedCam = cams.contains(where: { $0.id == storedCam })
            ? storedCam
            : (cams.first?.id ?? "")

        viewModel.setDevices(microphones: mics, cameras: cams,
                             selectedMicID: selectedMic, selectedCameraID: selectedCam)
    }

    // MARK: - Mic level meter

    private func setMicMetering(_ on: Bool) {
        guard meterEngineOn != on else { return }
        meterEngineOn = on
        guard let controller = mediaController else { return }
        if on {
            controller.audioSampleBufferHandler = { [weak self] sampleBuffer in
                guard let self else { return }
                let level = Self.rmsLevel(from: sampleBuffer)
                let now = Date()
                // ~12 Hz UI updates are plenty for a level bar.
                guard now.timeIntervalSince(self.lastMeterPush) > 0.08 else { return }
                self.lastMeterPush = now
                DispatchQueue.main.async { [weak self] in
                    self?.viewModel.setMicLevel(level)
                }
            }
        } else {
            controller.audioSampleBufferHandler = nil
            DispatchQueue.main.async { [weak self] in self?.viewModel.setMicLevel(0) }
        }
    }

    /// RMS of a capture audio buffer mapped to a 0…1 meter value.
    static func rmsLevel(from sampleBuffer: CMSampleBuffer) -> Double {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        else { return 0 }

        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length,
                                          dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let data = pointer, length > 0 else { return 0 }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        var sumSquares = 0.0
        var count = 0

        if isFloat, asbd.mBitsPerChannel == 32 {
            data.withMemoryRebound(to: Float32.self, capacity: length / 4) { samples in
                count = length / 4
                for i in 0..<count { sumSquares += Double(samples[i]) * Double(samples[i]) }
            }
        } else if asbd.mBitsPerChannel == 16 {
            data.withMemoryRebound(to: Int16.self, capacity: length / 2) { samples in
                count = length / 2
                for i in 0..<count {
                    let v = Double(samples[i]) / 32768.0
                    sumSquares += v * v
                }
            }
        } else {
            return 0
        }

        guard count > 0 else { return 0 }
        let rms = (sumSquares / Double(count)).squareRoot()
        // Perceptual-ish mapping: full scale ≈ -0 dB, floor ≈ -50 dB.
        let db = 20 * log10(max(rms, 1e-7))
        return max(0, min(1, (db + 50) / 50))
    }

    // MARK: - Speaker test tone (system default output)

    private func startTone() {
        guard toneEngine == nil else { return }
        let engine = AVAudioEngine()
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        var phase = 0.0
        let increment = 2.0 * Double.pi * 440.0 / sampleRate

        let source = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                let value = Float32(sin(phase)) * 0.18
                phase += increment
                if phase > 2.0 * Double.pi { phase -= 2.0 * Double.pi }
                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float32.self)[frame] = value
                }
            }
            return noErr
        }

        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode,
                       format: AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        do {
            try engine.start()
            toneEngine = engine
            viewModel.setSpeakerTestPlaying(true)
        } catch {
            toneEngine = nil
            viewModel.setSpeakerTestPlaying(false)
        }
    }

    private func stopTone() {
        toneEngine?.stop()
        toneEngine = nil
        viewModel.setSpeakerTestPlaying(false)
    }

    // MARK: - Speaker name (CoreAudio default output)

    static func defaultOutputDeviceName() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }

        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var nameRef: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil,
                                         &nameSize, &nameRef) == noErr,
              let cfName = nameRef?.takeRetainedValue() else { return nil }
        return cfName as String
    }

    // MARK: - Network check

    private func runNetworkCheck() {
        guard !tokenServerURL.isEmpty,
              let url = URL(string: tokenServerURL)?.appendingPathComponent("health") else {
            viewModel.networkState = .unreachable
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let started = Date()
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            DispatchQueue.main.async {
                guard let self else { return }
                if error == nil, let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    self.viewModel.networkState = .reachable(latencyMillis: elapsed)
                } else {
                    self.viewModel.networkState = .unreachable
                }
            }
        }.resume()
    }
}
