#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// ---------------------------------------------------------------------------
// MARK: - Chat permission constants
// ---------------------------------------------------------------------------

extern NSString *const InterChatPermissionsEveryone;
extern NSString *const InterChatPermissionsHostOnly;
extern NSString *const InterChatPermissionsDisabled;

// ---------------------------------------------------------------------------
// MARK: - Sharing permission constants
// ---------------------------------------------------------------------------

extern NSString *const InterSharingPermissionsHostOnly;
extern NSString *const InterSharingPermissionsEveryone;
extern NSString *const InterSharingPermissionsRequest;

// ---------------------------------------------------------------------------
// MARK: - Share-conflict policy constants
// ---------------------------------------------------------------------------
/// Nobody can start a new share until the current sharer stops (default).
extern NSString *const InterSharingConflictOneAtATime;
/// Only the host / co-host can preempt the current sharer.
extern NSString *const InterSharingConflictHostCanPreempt;
/// Any participant with share permission can preempt the current sharer.
extern NSString *const InterSharingConflictAnyCanPreempt;

// ---------------------------------------------------------------------------
// MARK: - InterPreMeetingSettings
// ---------------------------------------------------------------------------

/// Value object capturing all host-configured settings for a meeting.
/// Persisted to UserDefaults (except meetingDisplayName and meetingPassword).
@interface InterPreMeetingSettings : NSObject <NSCopying>

/// Display name for the meeting, broadcast to participants. Not persisted.
@property (nonatomic, copy)   NSString *meetingDisplayName;
/// Whether all participants (including host) start with mic muted.
@property (nonatomic, assign) BOOL muteOnJoin;
/// Whether all participants (including host) start with camera off.
@property (nonatomic, assign) BOOL cameraOffOnJoin;
/// Enable lobby / waiting room.
@property (nonatomic, assign) BOOL lobbyEnabled;
/// Meeting password. Empty string means no password. Not persisted.
@property (nonatomic, copy)   NSString *meetingPassword;
/// Allow participants to enter before the host arrives.
@property (nonatomic, assign) BOOL joinBeforeHost;
/// Allow participants to unmute themselves (default YES).
@property (nonatomic, assign) BOOL allowUnmuting;
/// Chat availability: one of the InterChatPermissions* constants.
@property (nonatomic, copy)   NSString *chatPermissions;
/// Screen sharing availability: one of the InterSharingPermissions* constants.
@property (nonatomic, copy)   NSString *sharingPermissions;
/// Share-conflict policy: one of the InterSharingConflict* constants.
/// Controls what happens when a participant tries to share while someone else is sharing.
@property (nonatomic, copy)   NSString *shareConflictPolicy;
/// Auto-start cloud recording when host joins (pro+ only).
@property (nonatomic, assign) BOOL autoRecord;
/// Auto-start AI transcription when host joins (pro+ only).
@property (nonatomic, assign) BOOL autoTranscript;
/// Allow co-hosts to record locally to their own machine (disabled by default; pro-gated; host controls).
@property (nonatomic, assign) BOOL allowCoHostLocalRecording;

/// Returns default settings pre-filled from UserDefaults.
+ (instancetype)settingsWithDefaults;

/// Persists toggle/dropdown values to UserDefaults.
/// meetingDisplayName and meetingPassword are intentionally not saved.
- (void)saveToUserDefaults;

@end

// ---------------------------------------------------------------------------
// MARK: - InterPreMeetingPanelDelegate
// ---------------------------------------------------------------------------

@class InterPreMeetingPanel;

@protocol InterPreMeetingPanelDelegate <NSObject>

/// User confirmed settings and pressed "Start Meeting".
- (void)preMeetingPanel:(InterPreMeetingPanel *)panel
  didStartWithSettings:(InterPreMeetingSettings *)settings;

/// User cancelled — dismiss and take no action.
- (void)preMeetingPanelDidCancel:(InterPreMeetingPanel *)panel;

@end

// ---------------------------------------------------------------------------
// MARK: - InterPreMeetingPanel
// ---------------------------------------------------------------------------

/// Pre-meeting settings panel that intercepts the "Host Call" action.
/// Embed this view inside a floating NSWindow created by AppDelegate.
///
/// Call -setDisplayName: and -setUserTier: before showing the window
/// so the default meeting title is correct and pro features are properly gated.
@interface InterPreMeetingPanel : NSView

@property (nonatomic, weak, nullable) id<InterPreMeetingPanelDelegate> delegate;

/// Pre-fills the "Meeting Name" field with "{name}'s Meeting".
/// Must be called before the view appears.
- (void)setDisplayName:(NSString *)displayName;

/// Gates the pro-only toggles (Auto-Record, Auto-Transcript).
/// Pass the user's tier string: "free", "pro", "pro+", or "hiring".
- (void)setUserTier:(NSString *)tier;

@end

NS_ASSUME_NONNULL_END
