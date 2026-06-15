#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class InterTokenService;

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

/// Home / launch screen. The body is SwiftUI (`HomeView`) hosted via the Swift
/// `InterHomeHostView` bridge — this class is a thin Obj-C shell preserving the
/// original delegate + property contract, so AppDelegate's host/join flows are
/// unchanged.
///
/// What changed with the SwiftUI port:
///   • Server/token URLs are NO LONGER user-editable — `serverURL` /
///     `tokenServerURL` answer from `InterAppConfig` (env → Info.plist →
///     dev fallback). Config never lives in the UI.
///   • `displayName` is the signed-in account's name; signed-out guests type a
///     name inline (persisted via the same UserDefaults key as before).
///   • The auth/billing/schedule/teams chrome that used to be loose AppKit
///     buttons around the panel now lives INSIDE the screen (avatar menu +
///     action tiles). AppDelegate assigns the action blocks below and calls
///     `refreshAuthChrome` on auth-state changes.
@interface InterConnectionSetupPanel : NSView

@property (nonatomic, weak, nullable) id<InterConnectionSetupPanelDelegate> delegate;

/// LiveKit media server URL (from build config — read-only).
@property (nonatomic, readonly) NSString *serverURL;

/// Token server URL (from build config — read-only).
@property (nonatomic, readonly) NSString *tokenServerURL;

/// Effective display name: account name when signed in, guest name otherwise.
@property (nonatomic, readonly) NSString *displayName;

/// Current text in the Room Code field (uppercase, max 6 chars).
@property (nonatomic, readonly) NSString *roomCode;

// ---------------------------------------------------------------------------
// Chrome wiring (assigned once after creation)
// ---------------------------------------------------------------------------

/// Provide the token service the screen reads auth/tier/identity from.
- (void)configureWithTokenService:(nullable InterTokenService *)tokenService;

/// Re-read auth state (signed out / signed in / offline-with-session) and
/// re-render the chrome. Call whenever auth or tier changes (replaces the
/// legacy chrome rebuild).
- (void)refreshAuthChrome;

/// Re-fetch the meeting history + today's events strip (cheap GETs; call when
/// they may have changed: scheduling, cancelling, returning from a call).
- (void)reloadMeetings;

/// Avatar account menu as a titlebar accessory (add to the setup window so it
/// sits beside the traffic lights and stays fully clickable).
- (NSTitlebarAccessoryViewController *)makeTitlebarAccessory;

/// Join a scheduled meeting from the home Today strip
/// (roomCode, meetingId, isHosted).
@property (nonatomic, copy, nullable) void (^onJoinScheduledMeeting)(NSString *roomCode, NSString *meetingId, BOOL isHosted);

@property (nonatomic, copy, nullable) void (^onSignIn)(void);
@property (nonatomic, copy, nullable) void (^onSignOut)(void);
@property (nonatomic, copy, nullable) void (^onOpenSettings)(void);
@property (nonatomic, copy, nullable) void (^onOpenAccountSettings)(void);
@property (nonatomic, copy, nullable) void (^onViewPlans)(void);
@property (nonatomic, copy, nullable) void (^onManageSubscription)(void);
@property (nonatomic, copy, nullable) void (^onOpenSchedule)(void);
@property (nonatomic, copy, nullable) void (^onOpenTeams)(void);

// ---------------------------------------------------------------------------
// Status / state (original surface)
// ---------------------------------------------------------------------------

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

/// Show or clear a "PRO" tier badge on the Host Interview button.
- (void)setHostInterviewButtonRequiresPro:(BOOL)requiresPro;

// ---------------------------------------------------------------------------
// Billing status (replaces the legacy loose billingStatusLabel + buttons)
// ---------------------------------------------------------------------------

/// Set the billing status line (e.g. "Verifying your upgrade…"). Empty hides it.
- (void)setBillingStatusText:(NSString *)text;

/// Current billing status line text (some flows read it back).
@property (nonatomic, readonly) NSString *billingStatusText;

/// Enable/disable the billing action while a purchase/poll is in flight.
- (void)setBillingActionEnabled:(BOOL)enabled;

@end

NS_ASSUME_NONNULL_END
