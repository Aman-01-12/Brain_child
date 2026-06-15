#import "InterSchedulePanel.h"

#if __has_include("inter-Swift.h")
#import "inter-Swift.h"
#endif

// The schedule screen is now SwiftUI (`ScheduleView`), hosted via the Swift
// `InterScheduleHostView` bridge. This class is a thin Obj-C shell that
// preserves the original public API and the `InterSchedulePanelDelegate`
// contract, so `AppDelegate` (which owns the scheduling/calendar wiring) is
// unchanged. The former AppKit implementation (calendar grid, form fields,
// table view) was replaced — its behavior now lives in `ScheduleViewModel` +
// `ScheduleView`, including the inline Meeting-settings section that shares
// the pre-meeting flow's saved defaults.

@implementation InterScheduledMeeting
@end

@interface InterSchedulePanel ()
@property (nonatomic, strong) InterScheduleHostView *host;
@end

@implementation InterSchedulePanel

#pragma mark - Lifecycle

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;
    [self buildScheduleHost];
    return self;
}

- (void)buildScheduleHost {
    self.host = [[InterScheduleHostView alloc] initWithFrame:self.bounds];
    self.host.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    __weak typeof(self) weakSelf = self;
    self.host.onSchedule = ^(NSString *title, NSDate *scheduledAt, NSInteger duration,
                             NSString *roomType, NSString *timezone, NSString *_Nullable password,
                             BOOL lobbyEnabled, NSArray<NSString *> *emails) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf.delegate respondsToSelector:
                @selector(schedulePanel:didScheduleMeetingWithTitle:description:scheduledAt:
                          durationMinutes:roomType:hostTimezone:password:lobbyEnabled:inviteeEmails:)]) {
            [strongSelf.delegate schedulePanel:strongSelf
                   didScheduleMeetingWithTitle:title
                                   description:nil
                                   scheduledAt:scheduledAt
                               durationMinutes:duration
                                      roomType:roomType
                                  hostTimezone:timezone
                                      password:password
                                  lobbyEnabled:lobbyEnabled
                                 inviteeEmails:emails];
        }
    };
    self.host.onCancelMeeting = ^(NSString *meetingId) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf.delegate respondsToSelector:@selector(schedulePanel:didRequestCancel:)]) {
            [strongSelf.delegate schedulePanel:strongSelf didRequestCancel:meetingId];
        }
    };
    self.host.onJoin = ^(NSString *roomCode, NSString *meetingId) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf.delegate respondsToSelector:@selector(schedulePanel:didRequestJoin:meetingId:)]) {
            [strongSelf.delegate schedulePanel:strongSelf didRequestJoin:roomCode meetingId:meetingId];
        }
    };

    [self addSubview:self.host];
}

#pragma mark - Public API

- (void)setUpcomingMeetings:(NSArray<InterScheduledMeeting *> *)meetings {
    [self.host setUpcomingMeetings:meetings ?: @[]];
}

- (void)setInvitedMeetings:(NSArray<InterScheduledMeeting *> *)meetings {
    [self.host setInvitedMeetings:meetings ?: @[]];
}

- (void)resetForm {
    [self.host resetForm];
}

- (void)setStatusText:(NSString *)text {
    [self.host setStatusText:text ?: @""];
}

- (void)setSubmitting:(BOOL)submitting {
    [self.host setSubmitting:submitting];
}

@end
