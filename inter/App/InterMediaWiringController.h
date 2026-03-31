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

/// Apply a remote (server-side / host-initiated) mic mute. Updates local state
/// and control panel UI to reflect that the mic has been muted externally.
- (void)applyRemoteMicMute;

/// Host allowed this participant to speak. Unmutes the mic track but keeps
/// isHostMuted=YES so if the participant turns mic off again they go back
/// to "raise hand" mode.
- (void)applyAllowToSpeak;

/// Host pressed "Unmute All". Clears isHostMuted so participants can freely
/// toggle their mic. Does NOT auto-unmute — participants choose when to turn on.
- (void)applyUnmuteAll;

/// Whether the mic is locked by the host (hard mute). When YES, the
/// participant cannot unmute from the UI — they must raise hand to speak.
@property (nonatomic, readonly) BOOL isHostMuted;

/// Whether the host has temporarily allowed the participant to speak.
/// Only meaningful when isHostMuted=YES. Cleared when participant turns
/// mic off or when host unmutes all.
@property (nonatomic, readonly) BOOL isAllowedToSpeak;

/// Revoke the one-time speak permission and put the mic button back to
/// "raise hand" mode. Called when participant turns mic off while isHostMuted.
- (void)revokeAllowToSpeak;

// -- Simple Device Toggles -------------------------------------------------

/// Toggle camera on/off (local device only, no G2 network coordination).
- (void)toggleCamera;

/// Toggle microphone on/off (local device only, no G2 network coordination).
- (void)toggleMicrophone;

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
