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
/// Hosted in a standalone movable/resizable NSWindow (Zoom-style); AppDelegate
/// toggles the WINDOW's visibility (⌘+Shift+Q or the Q&A button). The body is
/// SwiftUI (`QAView`) hosted via the Swift `InterQAHostView` bridge — this
/// class is a thin Obj-C shell preserving the delegate contract, so
/// AppDelegate's Q&A wiring is unchanged.
///
/// Features:
///   - Open / Answered tabs with live counts
///   - Submit questions (with optional anonymous toggle)
///   - Upvote questions
///   - Host actions: Highlight, Mark Answered, Dismiss (removes for everyone)
@interface InterQAPanel : NSView

@property (nonatomic, weak, nullable) id<InterQAPanelDelegate> delegate;

/// Whether the local user is the host.
@property (nonatomic, assign) BOOL isHost;

/// Update the question list. Reloads the entire display.
- (void)setQuestions:(NSArray<InterQuestionInfo *> *)questions;

/// Legacy no-op: the unread badge only ever showed on the collapsed in-window
/// strip, but visibility is now window-level (a hidden window can't show a
/// badge). Kept so AppDelegate's calls compile unchanged.
- (void)setUnreadBadge:(NSInteger)count;

@end

NS_ASSUME_NONNULL_END
