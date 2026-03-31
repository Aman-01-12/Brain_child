#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class InterPollInfo;
@class InterPollPanel;

/// Delegate for poll panel actions.
@protocol InterPollPanelDelegate <NSObject>
@optional
/// Host launched a new poll.
- (void)pollPanel:(InterPollPanel *)panel
  didLaunchPollWithQuestion:(NSString *)question
                    options:(NSArray<NSString *> *)options
                isAnonymous:(BOOL)isAnonymous
           allowMultiSelect:(BOOL)allowMultiSelect;

/// Host ended the current poll.
- (void)pollPanelDidEndPoll:(InterPollPanel *)panel;

/// Host requested to share live results with all participants.
- (void)pollPanelDidRequestShareResults:(InterPollPanel *)panel;

/// Participant submitted a vote with the given option indices.
- (void)pollPanel:(InterPollPanel *)panel didSubmitVoteWithIndices:(NSArray<NSNumber *> *)indices;
@end

/// [Phase 8.5] In-meeting poll panel.
///
/// Dual-mode panel:
///   - **Host view**: Create poll form (question + options + toggles) → Launch → Live results → End
///   - **Participant view**: Vote on active poll → See results after voting/ending
///
/// Hosted in a standalone movable/resizable NSWindow (Zoom-style).
/// State is preserved when window is hidden/shown via toggle button.
@interface InterPollPanel : NSView <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, weak, nullable) id<InterPollPanelDelegate> delegate;

/// Whether the local user is the host (determines which UI mode is shown).
@property (nonatomic, assign) BOOL isHost;

/// Display a newly launched poll (voting UI for participants, live results for host).
- (void)showActivePoll:(InterPollInfo *)poll;

/// Update the results display (live or final).
- (void)updateResults:(InterPollInfo *)poll;

/// Show the poll-ended state with final results.
- (void)showEndedPoll:(InterPollInfo *)poll;

/// Reset to the create-poll form (host) or empty state (participant).
- (void)resetToCreateForm;

/// Whether the panel is currently expanded (visible).
@property (nonatomic, readonly) BOOL isExpanded;

/// Toggle the panel open/closed with animation.
- (void)togglePanel;

/// Expand the panel (no-op if already expanded).
- (void)expandPanel;

/// Collapse the panel (no-op if already collapsed).
- (void)collapsePanel;

@end

NS_ASSUME_NONNULL_END
