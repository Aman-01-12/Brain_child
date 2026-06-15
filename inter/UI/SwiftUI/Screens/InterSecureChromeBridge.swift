//
//  InterSecureChromeBridge.swift
//  inter
//
//  AppKit↔SwiftUI bridge for the secure interviewee (candidate) window chrome.
//  Owns ONE shared view model and vends TWO hosting views (top status bar +
//  bottom control bar) that SecureWindowController places inside the existing
//  capture-protected kiosk window. No new windows are created here — every
//  SwiftUI surface lives inside the protected window, so it inherits
//  NSWindowSharingNone (paranoid #2; dropdown child panels mirror the parent's
//  sharingType via InterDropdownPanelFactory).
//
//  Conforms to InterCallMediaControlSurface so the secure window's own
//  InterMediaWiringController instance drives it exactly like it drove the
//  legacy AppKit panel.
//

import AppKit
import SwiftUI

@objc(InterSecureChromeBridge)
@MainActor
public final class InterSecureChromeBridge: NSObject, InterCallMediaControlSurface {

    private let viewModel = SecureCandidateChromeViewModel()

    /// Top status bar (Secure Interview · room code · REC · CANDIDATE · Chat).
    @objc public private(set) lazy var topBarView: NSView = {
        let host = NSHostingView(rootView: SecureCandidateTopBarView(viewModel: viewModel))
        host.translatesAutoresizingMaskIntoConstraints = true
        return host
    }()

    /// Bottom control bar (mic ^ / camera / share strip / Leave Interview).
    @objc public private(set) lazy var bottomBarView: NSView = {
        let host = NSHostingView(rootView: SecureCandidateBottomBarView(viewModel: viewModel))
        host.translatesAutoresizingMaskIntoConstraints = true
        return host
    }()

    // MARK: - Action callbacks (SecureWindowController assigns)

    @objc public var cameraToggleHandler: (() -> Void)?
    @objc public var microphoneToggleHandler: (() -> Void)?
    @objc public var audioInputSelectionChangedHandler: ((String?) -> Void)?
    /// Tool SELECTION only (paranoid #7) — receives InterInterviewToolKind raw.
    @objc public var interviewToolChangedHandler: ((Int) -> Void)?
    /// The only publish trigger.
    @objc public var shareToggleHandler: (() -> Void)?
    @objc public var chatToggleHandler: (() -> Void)?
    /// Leave Interview — must route to the controller's confirmed exit path
    /// (paranoid #5: the only escape from kiosk mode).
    @objc public var leaveHandler: (() -> Void)?

    @objc public override init() {
        super.init()
        viewModel.onToggleCamera = { [weak self] in self?.cameraToggleHandler?() }
        viewModel.onToggleMic = { [weak self] in self?.microphoneToggleHandler?() }
        viewModel.onSelectAudioInput = { [weak self] id in self?.audioInputSelectionChangedHandler?(id) }
        viewModel.onSelectTool = { [weak self] kind in
            self?.interviewToolChangedHandler?(kind)
            // Refresh the consent-clarity status line for the new selection.
            self?.refreshShareStatusFromState()
        }
        viewModel.onToggleShare = { [weak self] in self?.shareToggleHandler?() }
        viewModel.onToggleChat = { [weak self] in self?.chatToggleHandler?() }
        viewModel.onLeave = { [weak self] in self?.leaveHandler?() }
    }

    /// Drops every handler block. Call from destroySecureWindow so no block
    /// (and its captured controller) outlives the session (paranoid #8).
    @objc public func invalidateHandlers() {
        cameraToggleHandler = nil
        microphoneToggleHandler = nil
        audioInputSelectionChangedHandler = nil
        interviewToolChangedHandler = nil
        shareToggleHandler = nil
        chatToggleHandler = nil
        leaveHandler = nil
    }

    private func refreshShareStatusFromState() {
        MainActor.assumeIsolated {
            viewModel.shareStatusText = SecureCandidateChromeViewModel.shareStatus(
                toolKind: viewModel.selectedTool,
                sharing: viewModel.sharingActive,
                pending: viewModel.sharePending)
        }
    }

    // MARK: - InterCallMediaControlSurface (wiring controller drives these)

    @objc public func setCameraEnabled(_ enabled: Bool) {
        MainActor.assumeIsolated { viewModel.cameraEnabled = enabled }
    }

    @objc public func setCameraInteractive(_ interactive: Bool) {
        MainActor.assumeIsolated { viewModel.cameraInteractive = interactive }
    }

    @objc public func setCameraButtonTitle(_ title: String?) {
        MainActor.assumeIsolated { viewModel.cameraTitleOverride = title }
    }

    @objc public func setMicrophoneEnabled(_ enabled: Bool) {
        MainActor.assumeIsolated { viewModel.micEnabled = enabled }
    }

    @objc public func setMicrophoneButtonTitle(_ title: String?) {
        MainActor.assumeIsolated { viewModel.micTitleOverride = title }
    }

    @objc public func setMediaStatusText(_ text: String) {
        MainActor.assumeIsolated { viewModel.mediaStatusText = text }
    }

    @objc public func setConnectionStatusText(_ text: String) {
        MainActor.assumeIsolated { viewModel.connectionStatusText = text }
    }

    // MARK: - Legacy panel surface (SecureWindowController drives these)

    @objc public func setRoomCodeText(_ code: String?) {
        MainActor.assumeIsolated { viewModel.roomCode = code ?? "" }
    }

    @objc public func setSharingEnabled(_ active: Bool) {
        MainActor.assumeIsolated {
            viewModel.sharingActive = active
        }
        refreshShareStatusFromState()
    }

    @objc public func setShareStartPending(_ pending: Bool) {
        MainActor.assumeIsolated {
            viewModel.sharePending = pending
        }
        refreshShareStatusFromState()
    }

    /// Explicit status text wins over the derived default (the controller
    /// pushes richer copy, e.g. capture-permission failures).
    @objc public func setShareStatusText(_ text: String) {
        MainActor.assumeIsolated { viewModel.shareStatusText = text }
    }

    @objc public func setSelectedInterviewToolKind(_ kind: Int) {
        MainActor.assumeIsolated { viewModel.selectedTool = kind }
        refreshShareStatusFromState()
    }

    @objc public func setAudioInputOptions(_ options: [[String: String]], selectedDeviceID: String?) {
        MainActor.assumeIsolated {
            viewModel.audioInputs = options.compactMap { dict in
                guard let id = dict["id"], let name = dict["name"] else { return nil }
                return AudioInputOption(id: id, name: name)
            }
            viewModel.selectedAudioInputID = selectedDeviceID
        }
    }

    /// Paranoid #6: only the recording-signal path may call this.
    @objc public func setRecordingActive(_ active: Bool) {
        MainActor.assumeIsolated { viewModel.recordingActive = active }
    }

    @objc public func setChatUnread(_ count: Int) {
        MainActor.assumeIsolated { viewModel.chatUnread = count }
    }

    @objc public func setChatVisible(_ visible: Bool) {
        MainActor.assumeIsolated { viewModel.chatVisible = visible }
    }
}
