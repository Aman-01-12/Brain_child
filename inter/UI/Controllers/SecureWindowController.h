#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class InterRoomController;
@class InterChatController;

@interface SecureWindowController : NSObject

@property (nonatomic, strong, nullable) NSWindow *secureWindow;
@property (nonatomic, copy, nullable) dispatch_block_t exitSessionHandler;

/// [2.6.1] Weak reference to room controller for network wiring.
/// Set by AppDelegate before createSecureWindow is called.
@property (nonatomic, weak, nullable) InterRoomController *roomController;

/// [Green room] Start with the mic / camera disabled (candidate turned them
/// off in the pre-join green room). Set BEFORE -createSecureWindow; applied
/// once after the capture session starts. Interview rooms have no host
/// muteOnJoin/cameraOffOnJoin (no pre-meeting), so only these user choices
/// shape the initial device state.
@property (nonatomic, assign) BOOL startWithMicrophoneOff;
@property (nonatomic, assign) BOOL startWithCameraOff;

/// Chat controller for in-session messaging. Set by AppDelegate after attach.
@property (nonatomic, weak, nullable) InterChatController *chatController;

- (void)createSecureWindow;
- (void)destroySecureWindow;

/// Show/hide the persistent "REC" badge in the secure interview window so the
/// interviewee always knows the session is being recorded (F2). Safe to call before
/// the window exists (the desired state is applied when the window is created).
- (void)setRecordingIndicatorActive:(BOOL)active;

/// PRESENCE MONITORING (provisional, server flag default OFF).
/// Drive the persistent, non-dismissible presence chip in the candidate's
/// chrome: 0 absent (no chip), 1 monitoring on, 2 monitoring off,
/// 3 paused because the camera is off. Safe to call before the window exists —
/// the desired state is stored and applied when the chrome is attached, exactly
/// like -setRecordingIndicatorActive:. The presence coordinator (Phase 1) is the
/// only writer. Delete this declaration and its implementation to remove the
/// indicator. See .agents/tasks/presence-monitoring/REMOVAL.md.
- (void)setPresenceMonitoringState:(NSInteger)state;

/// Immediately hide the secure window without tearing down room/media objects.
- (void)hideSecureWindow;

@end

NS_ASSUME_NONNULL_END
