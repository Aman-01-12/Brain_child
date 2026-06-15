#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class InterSchedulePanel;

/// Model representing a scheduled meeting in the upcoming list.
@interface InterScheduledMeeting : NSObject
@property (nonatomic, copy) NSString *meetingId;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *meetingDescription;
@property (nonatomic, strong) NSDate *scheduledAt;
@property (nonatomic, assign) NSInteger durationMinutes;
@property (nonatomic, copy) NSString *roomType;
@property (nonatomic, copy, nullable) NSString *roomCode;
@property (nonatomic, assign) BOOL lobbyEnabled;
@property (nonatomic, copy) NSString *hostTimezone;
@property (nonatomic, copy) NSString *status;
@property (nonatomic, assign) NSInteger inviteeCount;
@end

/// Delegate protocol for schedule panel actions.
@protocol InterSchedulePanelDelegate <NSObject>
@optional

/// User submitted a new meeting schedule.
- (void)schedulePanel:(InterSchedulePanel *)panel
    didScheduleMeetingWithTitle:(NSString *)title
                    description:(nullable NSString *)description
                    scheduledAt:(NSDate *)scheduledAt
                durationMinutes:(NSInteger)duration
                       roomType:(NSString *)roomType
                   hostTimezone:(NSString *)timezone
                       password:(nullable NSString *)password
                   lobbyEnabled:(BOOL)lobbyEnabled
               inviteeEmails:(NSArray<NSString *> *)emails;

/// User wants to cancel a scheduled meeting.
- (void)schedulePanel:(InterSchedulePanel *)panel didRequestCancel:(NSString *)meetingId;

/// User wants to join a scheduled meeting now.
- (void)schedulePanel:(InterSchedulePanel *)panel didRequestJoin:(NSString *)roomCode meetingId:(NSString *)meetingId;

/// User wants to invite people to a meeting.
- (void)schedulePanel:(InterSchedulePanel *)panel
    didRequestInviteForMeeting:(NSString *)meetingId
                        emails:(NSArray<NSString *> *)emails;

@end

/// [Phase 11] Schedule meeting panel.
///
/// Two panes: month calendar + Hosted/Invited upcoming list (left) and the
/// schedule form (right). Below the schedule-specific fields the form embeds a
/// "Meeting settings" section backed by the SAME saved defaults the
/// pre-meeting flow uses (full list on first use; quick three + Advanced ▸
/// once defaults exist). The body is SwiftUI (`ScheduleView`) hosted via the
/// Swift `InterScheduleHostView` bridge — this class is a thin Obj-C shell
/// preserving the delegate contract, so AppDelegate's wiring is unchanged.
@interface InterSchedulePanel : NSView

@property (nonatomic, weak, nullable) id<InterSchedulePanelDelegate> delegate;

/// Set the upcoming meetings list (hosted by this user).
- (void)setUpcomingMeetings:(NSArray<InterScheduledMeeting *> *)meetings;

/// Set the meetings this user is invited to.
- (void)setInvitedMeetings:(NSArray<InterScheduledMeeting *> *)meetings;

/// Reset the schedule form to defaults.
- (void)resetForm;

/// Show a brief status message (e.g. "Meeting scheduled!" or error text).
- (void)setStatusText:(NSString *)text;

/// Show/hide the submitting state on the Schedule CTA (replaces the legacy
/// `scheduleButton.enabled` poking).
- (void)setSubmitting:(BOOL)submitting;

@end

NS_ASSUME_NONNULL_END
