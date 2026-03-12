#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Connection state indicator colors for the setup panel.
typedef NS_ENUM(NSUInteger, InterConnectionIndicatorState) {
    InterConnectionIndicatorStateIdle = 0,     // Gray dot — not connected
    InterConnectionIndicatorStateConnecting,    // Yellow dot — connecting
    InterConnectionIndicatorStateConnected,     // Green dot — connected
    InterConnectionIndicatorStateError          // Red dot — connection error
};

@class InterConnectionSetupPanel;

/// Delegate protocol for handling connection actions from the setup panel.
@protocol InterConnectionSetupPanelDelegate <NSObject>

/// User tapped "Host Call" — create room and connect in normal mode.
- (void)setupPanelDidRequestHostCall:(InterConnectionSetupPanel *)panel;

/// User tapped "Host Interview" — create room and connect in interviewer mode.
- (void)setupPanelDidRequestHostInterview:(InterConnectionSetupPanel *)panel;

/// User tapped "Join" with a room code — join existing room.
- (void)setupPanelDidRequestJoin:(InterConnectionSetupPanel *)panel;

@end

/// Self-contained connection form panel with server URL, token server URL,
/// display name, room code fields, and host/join action buttons.
///
/// Reads and stores field values via NSUserDefaults for persistence across launches.
@interface InterConnectionSetupPanel : NSView

@property (nonatomic, weak, nullable) id<InterConnectionSetupPanelDelegate> delegate;

/// Current text in the Server URL field (e.g. ws://localhost:7880).
@property (nonatomic, readonly) NSString *serverURL;

/// Current text in the Token Server URL field (e.g. http://localhost:3000).
@property (nonatomic, readonly) NSString *tokenServerURL;

/// Current text in the Display Name field.
@property (nonatomic, readonly) NSString *displayName;

/// Current text in the Room Code field (uppercase, max 6 chars).
@property (nonatomic, readonly) NSString *roomCode;

/// Update the connection state indicator (dot + label).
- (void)setIndicatorState:(InterConnectionIndicatorState)state;

/// Update the status label text shown below the indicator.
- (void)setStatusText:(NSString *)text;

/// Display a room code prominently (after hosting). Pass nil to hide.
- (void)showHostedRoomCode:(nullable NSString *)code;

/// Enable or disable all action buttons (during async operations).
- (void)setActionsEnabled:(BOOL)enabled;

/// Set the room code field text programmatically.
- (void)setRoomCodeText:(NSString *)code;

@end

NS_ASSUME_NONNULL_END
