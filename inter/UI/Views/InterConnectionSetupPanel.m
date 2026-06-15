#import "InterConnectionSetupPanel.h"

#if __has_include("inter-Swift.h")
#import "inter-Swift.h"
#endif

// The home / launch screen is now SwiftUI (`HomeView`), hosted via the Swift
// `InterHomeHostView` bridge. This class is a thin Obj-C shell that preserves
// the original public API and the `InterConnectionSetupPanelDelegate` contract,
// so AppDelegate's host/join flows are unchanged. The former AppKit
// implementation (URL/name/code fields, indicator dot, action buttons) was
// replaced — its behavior now lives in `HomeViewModel` + `HomeView`, and the
// loose chrome buttons AppDelegate used to build around the panel are now the
// screen's own avatar menu + tiles (wired through the block properties).

@interface InterConnectionSetupPanel ()
@property (nonatomic, strong) InterHomeHostView *host;
@end

@implementation InterConnectionSetupPanel

#pragma mark - Lifecycle

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;
    [self buildHomeHost];
    return self;
}

- (void)buildHomeHost {
    self.host = [[InterHomeHostView alloc] initWithFrame:self.bounds];
    self.host.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    __weak typeof(self) weakSelf = self;
    self.host.onHostCall = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.delegate setupPanelDidRequestHostCall:strongSelf];
    };
    self.host.onHostInterview = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.delegate setupPanelDidRequestHostInterview:strongSelf];
    };
    self.host.onJoin = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.delegate setupPanelDidRequestJoin:strongSelf];
    };

    // Chrome blocks forward to the shell's own block properties so AppDelegate
    // can assign them without knowing about the Swift bridge type.
    self.host.onSignIn = ^{ typeof(weakSelf) s = weakSelf; if (s.onSignIn) s.onSignIn(); };
    self.host.onSignOut = ^{ typeof(weakSelf) s = weakSelf; if (s.onSignOut) s.onSignOut(); };
    self.host.onOpenSettings = ^{ typeof(weakSelf) s = weakSelf; if (s.onOpenSettings) s.onOpenSettings(); };
    self.host.onOpenAccountSettings = ^{ typeof(weakSelf) s = weakSelf; if (s.onOpenAccountSettings) s.onOpenAccountSettings(); };
    self.host.onViewPlans = ^{ typeof(weakSelf) s = weakSelf; if (s.onViewPlans) s.onViewPlans(); };
    self.host.onManageSubscription = ^{ typeof(weakSelf) s = weakSelf; if (s.onManageSubscription) s.onManageSubscription(); };
    self.host.onOpenSchedule = ^{ typeof(weakSelf) s = weakSelf; if (s.onOpenSchedule) s.onOpenSchedule(); };
    self.host.onOpenTeams = ^{ typeof(weakSelf) s = weakSelf; if (s.onOpenTeams) s.onOpenTeams(); };
    self.host.onJoinScheduledMeeting = ^(NSString *roomCode, NSString *meetingId, BOOL isHosted) {
        typeof(weakSelf) s = weakSelf;
        if (s.onJoinScheduledMeeting) s.onJoinScheduledMeeting(roomCode, meetingId, isHosted);
    };

    [self addSubview:self.host];
}

#pragma mark - Accessors (legacy surface)

- (NSString *)serverURL {
    return self.host.serverURL;
}

- (NSString *)tokenServerURL {
    return self.host.tokenServerURL;
}

- (NSString *)displayName {
    return self.host.displayName;
}

- (NSString *)roomCode {
    return self.host.roomCode;
}

#pragma mark - Chrome wiring

- (void)configureWithTokenService:(InterTokenService *)tokenService {
    [self.host configureWithTokenService:tokenService];
}

- (void)refreshAuthChrome {
    [self.host refreshAuthChrome];
}

- (void)reloadMeetings {
    [self.host reloadMeetings];
}

- (NSTitlebarAccessoryViewController *)makeTitlebarAccessory {
    return [self.host makeTitlebarAccessory];
}

#pragma mark - Status / state

- (void)setIndicatorState:(InterConnectionIndicatorState)state {
    [self.host setIndicatorState:(NSInteger)state];
}

- (void)setStatusText:(NSString *)text {
    [self.host setStatusText:text ?: @""];
}

- (void)showHostedRoomCode:(NSString *)code {
    [self.host showHostedRoomCode:code];
}

- (void)setActionsEnabled:(BOOL)enabled {
    [self.host setActionsEnabled:enabled];
}

- (void)setRoomCodeText:(NSString *)code {
    [self.host setRoomCodeText:code ?: @""];
}

- (void)setHostInterviewButtonRequiresPro:(BOOL)requiresPro {
    [self.host setHostInterviewButtonRequiresPro:requiresPro];
}

#pragma mark - Billing status

- (void)setBillingStatusText:(NSString *)text {
    [self.host setBillingStatusText:text ?: @""];
}

- (NSString *)billingStatusText {
    return self.host.billingStatusText;
}

- (void)setBillingActionEnabled:(BOOL)enabled {
    [self.host setBillingActionEnabled:enabled];
}

@end
