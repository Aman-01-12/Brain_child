// ============================================================================
// InterMediaWiringController.h
// inter
//
// Shared controller that consolidates media/network wiring logic previously
// duplicated between AppDelegate.m and SecureWindowController.m.
//
// Owns:
//   - KVO observation of InterRoomController (connection + presence state)
//   - G2 two-phase camera/mic toggle state machines
//   - Network publish wiring (camera + mic + screen share sink)
//   - Connection state → UI label + quality bar mapping
//   - Participant presence state → overlay state mapping
//   - Diagnostic triple-click → clipboard
//
// This class is parameterised on weak references to the relevant UI and media
// objects. Both the normal-call path and the secure-interview path create an
// instance, wire the properties, and delegate all shared wiring logic here.
// ============================================================================

#import <Foundation/Foundation.h>
#import "InterNetworkStatusView.h"

@class InterLocalMediaController;
@class InterLocalCallControlPanel;
@class InterRoomController;
@class InterRemoteVideoLayoutManager;
@class InterNetworkStatusView;
@class InterSurfaceShareController;
@class MetalSurfaceView;

NS_ASSUME_NONNULL_BEGIN

// ---------------------------------------------------------------------------
// Delegate — receives callbacks for mode-specific actions that the shared
// controller cannot handle itself (e.g. exit call, update workspace layout).
// ---------------------------------------------------------------------------
@protocol InterMediaWiringDelegate <NSObject>
@optional
/// Called whenever connection state changes, after common UI updates are applied.
/// The state parameter is an InterRoomConnectionState raw value.
- (void)mediaWiringControllerDidChangeConnectionState:(NSInteger)state;
/// Called whenever participant presence state changes, after common UI updates.
/// The state parameter is an InterParticipantPresenceState raw value.
- (void)mediaWiringControllerDidChangePresenceState:(NSInteger)state;
/// Called when the user taps "Retry" after a reconnection timeout or error.
/// The delegate should disconnect and reconnect using stored configuration.
- (void)mediaWiringControllerDidRequestReconnect;
/// Called when the user taps "Continue Offline" after a reconnection timeout.
/// The delegate should nil out the room controller and continue locally.
- (void)mediaWiringControllerDidRequestContinueOffline;
@end

// ---------------------------------------------------------------------------
// InterMediaWiringController
// ---------------------------------------------------------------------------
@interface InterMediaWiringController : NSObject

/// All dependencies are weak to avoid retain cycles.
@property (nonatomic, weak, nullable) InterLocalMediaController *mediaController;
@property (nonatomic, weak, nullable) InterLocalCallControlPanel *controlPanel;
@property (nonatomic, weak, nullable) InterRoomController *roomController;
@property (nonatomic, weak, nullable) InterRemoteVideoLayoutManager *remoteLayout;
@property (nonatomic, weak, nullable) InterNetworkStatusView *networkStatusView;
@property (nonatomic, weak, nullable) InterSurfaceShareController *surfaceShareController;
@property (nonatomic, weak, nullable) MetalSurfaceView *renderView;

/// Delegate for mode-specific actions.
@property (nonatomic, weak, nullable) id<InterMediaWiringDelegate> delegate;

/// Block that returns a summary string for the current media state.
/// The caller provides this because the exact wording differs between modes.
@property (nonatomic, copy, nullable) NSString *(^mediaStateSummaryBlock)(void);

// -- G2 Two-Phase Toggles --------------------------------------------------

/// Two-phase camera toggle: [G2] mute track FIRST → stop device (disable);
/// start device FIRST → wait for frame → unmute track (enable).
- (void)twoPhaseToggleCamera;

/// Two-phase microphone toggle: same G2 ordering as camera.
- (void)twoPhaseToggleMicrophone;

/// Whether the microphone track is currently muted at the network level
/// (while connected). Used to avoid AVCaptureSession modifications that
/// interrupt the camera preview.
@property (nonatomic, readonly) BOOL isMicNetworkMuted;

/// Global Mute All (requestMuteAll signal).
/// Sets globalMuteActive=YES. NEVER sets hostMuted — Mute All is a global flag,
/// not a per-participant one. Participant sees "✋ Raise Hand to Speak".
- (void)applyRemoteMicMute;

/// Per-tile host mute (requestMuteOne signal).
/// Sets hostMuted=YES. NEVER sets globalMuteActive — this is an individual
/// action independent of any global mute session. Participant sees "Muted by
/// host" with the button disabled (no raise-hand gate).
- (void)applyRemoteMicMuteOne;

/// Host granted speak permission (allowToSpeak signal) — received during a Mute
/// All session. Sets speakPermissionGranted=YES and clears hostMuted. Does NOT
/// auto-unmute. Participant sees "🎙 Click to Unmute" and must tap themselves.
/// Per mic_mute_unmute.md §11.2: never auto-unmute.
- (void)applyAllowToSpeak;

/// Global Unmute All (requestUnmuteAll signal).
/// Clears globalMuteActive and speakPermissionGranted. Does NOT clear hostMuted
/// (individual per-tile mutes persist after Unmute All, per §8.1). Does NOT
/// auto-unmute the track — participants choose when to turn their mic on.
- (void)applyUnmuteAll;

/// Per-tile host unmute (requestUnmuteOne signal).
/// Clears hostMuted and force-unmutes the LiveKit track so the mic is
/// immediately active. Used only when no global Mute All is in effect.
- (void)applyRemoteMicUnmute;

/// Whether the host explicitly muted this participant via the tile menu
/// (requestMuteOne). Set ONLY by applyRemoteMicMuteOne. Never set by Mute All.
/// When YES, participant sees "Muted by host" and the button is disabled.
@property (nonatomic, readonly) BOOL hostMuted;

/// Whether a global Mute All is currently active for this room.
/// Set ONLY by applyRemoteMicMute. Cleared by applyUnmuteAll.
/// When YES without speakPermissionGranted, participant sees raise-hand gate.
@property (nonatomic, readonly) BOOL globalMuteActive;

/// Whether the host has granted this participant permission to speak during a
/// Mute All session. Set by applyAllowToSpeak. Cleared when globalMuteActive
/// is lifted. ONE-TIME USE: cleared on self-mute while globalMuteActive
/// so the participant must raise hand again (Bug 1 fix, §8.2 revised).
@property (nonatomic, readonly) BOOL speakPermissionGranted;

/// Monotonically increasing sequence number incremented on every authoritative
/// state change (each apply* method call). Async completion blocks capture the
/// sequence number before the async call and discard their update if the
/// number has advanced (preventing stale async callbacks from overwriting
/// fresher state — Bug 2 fix).
@property (nonatomic, readonly) NSInteger stateSequenceNumber;

// -- Simple Device Toggles -------------------------------------------------

/// Toggle camera on/off (local device only, no G2 network coordination).
- (void)toggleCamera;

/// Toggle microphone on/off (local device only, no G2 network coordination).
- (void)toggleMicrophone;

// -- Host Camera Lock ------------------------------------------------------

/// Whether the host has locked this local participant's camera off.
/// When YES the camera button title is replaced with "Camera Locked".
@property (nonatomic, assign) BOOL isHostCameraLocked;

/// Apply a host-initiated camera mute for this participant.
/// Disables camera, sets isHostCameraLocked = YES.
- (void)applyHostCameraMuteForParticipant;

/// Apply a host-initiated camera lift for this participant (undo lock).
/// Re-enables camera, sets isHostCameraLocked = NO.
- (void)applyHostCameraLiftForParticipant;

/// Apply a host-initiated camera mute for ALL participants.
- (void)applyHostCameraMuteForAll;

/// Lift the host camera lock for ALL participants.
- (void)applyHostCameraLiftForAll;

// -- Network Wiring --------------------------------------------------------

/// Publish camera and microphone tracks to LiveKit if room is connected.
- (void)wireNetworkPublish;

/// Create a screen share sink from the publisher and set it on the given controller.
- (void)wireNetworkSinkOnSurfaceShareController:(InterSurfaceShareController *)controller;

// -- KVO Lifecycle ---------------------------------------------------------

/// Start observing connectionState and participantPresenceState on roomController.
- (void)setupRoomControllerKVO;

/// Remove KVO observers. Safe to call even if KVO was never set up.
- (void)teardownRoomControllerKVO;

// -- Diagnostics -----------------------------------------------------------

/// Copy diagnostic stats to the clipboard and flash "Diagnostic copied!" on the control panel.
- (void)handleDiagnosticTripleClick;

// -- Utility ---------------------------------------------------------------

/// Map a connection state (InterRoomConnectionState) to its display label.
+ (NSString *)connectionLabelForState:(NSInteger)state;

/// Map a connection state (InterRoomConnectionState) to a network quality level.
+ (InterNetworkQualityLevel)qualityLevelForConnectionState:(NSInteger)state;

@end

NS_ASSUME_NONNULL_END
