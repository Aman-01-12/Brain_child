#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class InterQuestionInfo;
@class InterQAPanel;

/// Delegate for Q&A panel actions.
@protocol InterQAPanelDelegate <NSObject>
@optional
/// Participant submitted a new question.
- (void)qaPanel:(InterQAPanel *)panel didSubmitQuestion:(NSString *)text isAnonymous:(BOOL)isAnonymous;
/// Participant upvoted a question.
- (void)qaPanel:(InterQAPanel *)panel didUpvoteQuestion:(NSString *)questionId;
/// Host marked a question as answered.
- (void)qaPanel:(InterQAPanel *)panel didMarkAnswered:(NSString *)questionId;
/// Host highlighted a question.
- (void)qaPanel:(InterQAPanel *)panel didHighlightQuestion:(NSString *)questionId;
/// Host dismissed a question.
- (void)qaPanel:(InterQAPanel *)panel didDismissQuestion:(NSString *)questionId;
@end

/// [Phase 8.6] In-meeting Q&A panel.
///
/// Hosted in a standalone movable/resizable NSWindow (Zoom-style).
/// Displays questions sorted by upvote count (highlighted first).
/// State is preserved when window is hidden/shown via toggle button.
///
/// Features:
///   - Submit questions (with optional anonymous toggle)
///   - Upvote questions from other participants
///   - Host actions: Highlight, Mark Answered, Dismiss
///
/// Toggle visibility with ⌘+Shift+Q or the Q&A button.
@interface InterQAPanel : NSView <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, weak, nullable) id<InterQAPanelDelegate> delegate;

/// Whether the local user is the host.
@property (nonatomic, assign) BOOL isHost;

/// Update the question list. Reloads the entire display.
- (void)setQuestions:(NSArray<InterQuestionInfo *> *)questions;

/// Set the unread badge count (shown when panel is collapsed).
- (void)setUnreadBadge:(NSInteger)count;

/// Whether the panel is currently expanded (visible).
@property (nonatomic, readonly) BOOL isExpanded;

/// Toggle the panel open/closed with animation.
- (void)togglePanel;

/// Expand the panel.
- (void)expandPanel;

/// Collapse the panel.
- (void)collapsePanel;

@end

NS_ASSUME_NONNULL_END
