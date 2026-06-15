#import "InterPreMeetingPanel.h"

#if __has_include("inter-Swift.h")
#import "inter-Swift.h"
#endif

// The pre-meeting sheet is now SwiftUI (`PreMeetingView`), hosted via the
// Swift `InterPreMeetingHostView` bridge. This file keeps the shared
// `InterPreMeetingSettings` model + permission constants UNCHANGED (they are
// consumed by AppDelegate config-baking and the SwiftUI schedule screen) and
// reduces the panel class to a thin shell preserving the original public API
// and `InterPreMeetingPanelDelegate` contract, so AppDelegate's three
// presentations (first-time sheet, compact returning sheet, defaults-editor
// window) are unchanged. The former AppKit implementation (bottom-up manual
// frames, compact chip overlay, popup rows) was replaced — its behavior now
// lives in `PreMeetingViewModel` + `PreMeetingView`.

// ---------------------------------------------------------------------------
// MARK: - String constants
// ---------------------------------------------------------------------------

NSString *const InterChatPermissionsEveryone  = @"everyone";
NSString *const InterChatPermissionsHostOnly  = @"hostOnly";
NSString *const InterChatPermissionsDisabled  = @"disabled";

NSString *const InterSharingPermissionsHostOnly = @"hostOnly";
NSString *const InterSharingPermissionsEveryone = @"everyone";
NSString *const InterSharingPermissionsRequest  = @"request";

NSString *const InterSharingConflictOneAtATime    = @"oneattime";
NSString *const InterSharingConflictHostCanPreempt = @"hostCanPreempt";
NSString *const InterSharingConflictAnyCanPreempt  = @"anyCanPreempt";

// ---------------------------------------------------------------------------
// MARK: - UserDefaults keys
// ---------------------------------------------------------------------------

static NSString *const kUDMuteOnJoin          = @"InterPreMeeting_MuteOnJoin";
static NSString *const kUDCameraOffOnJoin      = @"InterPreMeeting_CameraOffOnJoin";
static NSString *const kUDLobbyEnabled         = @"InterPreMeeting_LobbyEnabled";
static NSString *const kUDJoinBeforeHost       = @"InterPreMeeting_JoinBeforeHost";
static NSString *const kUDAllowUnmuting        = @"InterPreMeeting_AllowUnmuting";
static NSString *const kUDChatPermissions      = @"InterPreMeeting_ChatPermissions";
static NSString *const kUDSharingPermissions   = @"InterPreMeeting_SharingPermissions";
static NSString *const kUDShareConflictPolicy  = @"InterPreMeeting_ShareConflictPolicy";
static NSString *const kUDAutoRecord           = @"InterPreMeeting_AutoRecord";
static NSString *const kUDAutoTranscript       = @"InterPreMeeting_AutoTranscript";
static NSString *const kUDAllowCoHostLocalRecording = @"InterPreMeeting_AllowCoHostLocalRecording";
/// Set once the host saves their meeting defaults; gates compact-vs-full panel.
static NSString *const kUDHasConfiguredDefaults = @"InterPreMeeting_HasConfiguredDefaults";

// ---------------------------------------------------------------------------
// MARK: - InterPreMeetingSettings
// ---------------------------------------------------------------------------

@implementation InterPreMeetingSettings

+ (instancetype)settingsWithDefaults {
    InterPreMeetingSettings *s = [[InterPreMeetingSettings alloc] init];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];

    s.meetingDisplayName   = @"";
    s.meetingPassword      = @"";
    s.muteOnJoin           = [ud boolForKey:kUDMuteOnJoin];
    s.cameraOffOnJoin      = [ud boolForKey:kUDCameraOffOnJoin];
    s.lobbyEnabled         = [ud boolForKey:kUDLobbyEnabled];
    s.joinBeforeHost       = [ud boolForKey:kUDJoinBeforeHost];
    // allowUnmuting defaults to YES if never saved before
    s.allowUnmuting        = ([ud objectForKey:kUDAllowUnmuting] == nil)
                             ? YES : [ud boolForKey:kUDAllowUnmuting];
    s.chatPermissions      = [ud stringForKey:kUDChatPermissions] ?: InterChatPermissionsEveryone;
    s.sharingPermissions   = [ud stringForKey:kUDSharingPermissions] ?: InterSharingPermissionsHostOnly;
    s.shareConflictPolicy  = [ud stringForKey:kUDShareConflictPolicy] ?: InterSharingConflictOneAtATime;
    s.autoRecord           = [ud boolForKey:kUDAutoRecord];
    s.autoTranscript       = [ud boolForKey:kUDAutoTranscript];
    s.allowCoHostLocalRecording = [ud boolForKey:kUDAllowCoHostLocalRecording];
    return s;
}

- (void)saveToUserDefaults {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:self.muteOnJoin         forKey:kUDMuteOnJoin];
    [ud setBool:self.cameraOffOnJoin    forKey:kUDCameraOffOnJoin];
    [ud setBool:self.lobbyEnabled       forKey:kUDLobbyEnabled];
    [ud setBool:self.joinBeforeHost     forKey:kUDJoinBeforeHost];
    [ud setBool:self.allowUnmuting      forKey:kUDAllowUnmuting];
    [ud setObject:self.chatPermissions      forKey:kUDChatPermissions];
    [ud setObject:self.sharingPermissions   forKey:kUDSharingPermissions];
    [ud setObject:self.shareConflictPolicy  forKey:kUDShareConflictPolicy];
    [ud setBool:self.autoRecord         forKey:kUDAutoRecord];
    [ud setBool:self.autoTranscript     forKey:kUDAutoTranscript];
    [ud setBool:self.allowCoHostLocalRecording forKey:kUDAllowCoHostLocalRecording];
    // Mark that defaults have been configured so future host-calls use the compact panel.
    [ud setBool:YES forKey:kUDHasConfiguredDefaults];
    [ud synchronize];
}

+ (BOOL)hasConfiguredDefaults {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kUDHasConfiguredDefaults];
}

- (id)copyWithZone:(NSZone *)zone {
    InterPreMeetingSettings *c = [[InterPreMeetingSettings allocWithZone:zone] init];
    c.meetingDisplayName   = [self.meetingDisplayName copy];
    c.meetingPassword      = [self.meetingPassword copy];
    c.muteOnJoin           = self.muteOnJoin;
    c.cameraOffOnJoin      = self.cameraOffOnJoin;
    c.lobbyEnabled         = self.lobbyEnabled;
    c.joinBeforeHost       = self.joinBeforeHost;
    c.allowUnmuting        = self.allowUnmuting;
    c.chatPermissions      = [self.chatPermissions copy];
    c.sharingPermissions   = [self.sharingPermissions copy];
    c.shareConflictPolicy  = [self.shareConflictPolicy copy];
    c.autoRecord           = self.autoRecord;
    c.autoTranscript       = self.autoTranscript;
    c.allowCoHostLocalRecording = self.allowCoHostLocalRecording;
    return c;
}

@end

// ---------------------------------------------------------------------------
// MARK: - InterPreMeetingPanel
// ---------------------------------------------------------------------------

@interface InterPreMeetingPanel ()
@property (nonatomic, strong) InterPreMeetingHostView *host;
@property (nonatomic, assign) BOOL compactMode;
@property (nonatomic, assign) BOOL defaultsEditorMode;
// setDisplayName:/setUserTier: may be called before a configureAsDefaultsEditor
// rebuild; replay them onto the fresh host so no state is lost.
@property (nonatomic, copy, nullable) NSString *lastDisplayName;
@property (nonatomic, copy, nullable) NSString *lastUserTier;
@end

@implementation InterPreMeetingPanel

// ---------------------------------------------------------------------------
// MARK: - Init
// ---------------------------------------------------------------------------

- (instancetype)initWithFrame:(NSRect)frame {
    return [self initWithFrame:frame compactMode:NO];
}

- (instancetype)initWithFrame:(NSRect)frame compactMode:(BOOL)compactMode {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _compactMode = compactMode;
    [self _buildHost];
    return self;
}

- (instancetype)initWithFrame:(NSRect)frame defaultsEditor:(BOOL)defaultsEditor {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _defaultsEditorMode = defaultsEditor;
    [self _buildHost];
    return self;
}

+ (CGFloat)fullPanelHeight { return 620.0; }
+ (CGFloat)compactPanelHeight { return 380.0; }

/// Legacy reconfigure-after-init path: rebuild the host in defaults-editor
/// mode (the SwiftUI mode is fixed at host creation). Prefer
/// -initWithFrame:defaultsEditor:.
- (void)configureAsDefaultsEditor {
    if (_defaultsEditorMode) return;
    _defaultsEditorMode = YES;
    _compactMode = NO;
    [self _buildHost];
}

// ---------------------------------------------------------------------------
// MARK: - Host construction
// ---------------------------------------------------------------------------

- (void)_buildHost {
    [self.host removeFromSuperview];

    InterPreMeetingHostView *host =
        [[InterPreMeetingHostView alloc] initWithFrame:self.bounds
                                           compactMode:self.compactMode
                                        defaultsEditor:self.defaultsEditorMode];
    host.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.host = host;

    __weak typeof(self) weakSelf = self;
    host.onStart = ^(InterPreMeetingSettings *settings) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.delegate preMeetingPanel:strongSelf didStartWithSettings:settings];
    };
    host.onCancel = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.delegate preMeetingPanelDidCancel:strongSelf];
    };
    host.onSaveDefaults = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf.delegate respondsToSelector:@selector(preMeetingPanelDidSaveDefaults:)]) {
            [strongSelf.delegate preMeetingPanelDidSaveDefaults:strongSelf];
        }
    };
    host.onRequestExpand = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf.delegate respondsToSelector:@selector(preMeetingPanel:didRequestExpandToHeight:)]) {
            [strongSelf.delegate preMeetingPanel:strongSelf
                        didRequestExpandToHeight:[[strongSelf class] fullPanelHeight]];
        }
    };

    [self addSubview:host];

    // Replay state set before a rebuild (configureAsDefaultsEditor path).
    if (self.lastDisplayName) [host setDisplayName:self.lastDisplayName];
    if (self.lastUserTier) [host setUserTier:self.lastUserTier];
}

// ---------------------------------------------------------------------------
// MARK: - Public API
// ---------------------------------------------------------------------------

- (void)setDisplayName:(NSString *)displayName {
    if (displayName.length == 0) return;
    self.lastDisplayName = displayName;
    [self.host setDisplayName:displayName];
}

- (void)setUserTier:(NSString *)tier {
    self.lastUserTier = tier;
    [self.host setUserTier:tier];
}

- (void)setMeetingName:(NSString *)meetingName {
    [self.host setMeetingName:meetingName ?: @""];
}

- (void)setMeetingPassword:(NSString *)meetingPassword {
    [self.host setMeetingPassword:meetingPassword ?: @""];
}

@end






