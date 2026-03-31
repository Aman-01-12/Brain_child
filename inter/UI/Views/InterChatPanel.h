#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class InterChatMessageInfo;
@class InterChatPanel;

/// Delegate for chat panel actions (send, toggle, export).
@protocol InterChatPanelDelegate <NSObject>
@optional
/// User submitted a message via the input field.
- (void)chatPanel:(InterChatPanel *)panel didSubmitMessage:(NSString *)text;
/// User requested to export the chat transcript.
- (void)chatPanelDidRequestExport:(InterChatPanel *)panel;
/// User selected a participant for DM. Pass nil to switch back to public.
- (void)chatPanel:(InterChatPanel *)panel didSelectRecipient:(nullable NSString *)recipientIdentity;
@end

/// [Phase 8.1.3] In-meeting chat panel.
///
/// Slide-in panel from the right edge. Contains:
///   - Message list (NSScrollView + NSTableView)
///   - Recipient selector (Everyone / specific participant)
///   - Text input field + send button
///   - Unread badge
///   - Dark theme matching the app
///
/// Toggle visibility with ⌘+Shift+C or the chat button.
@interface InterChatPanel : NSView <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate>

@property (nonatomic, weak, nullable) id<InterChatPanelDelegate> delegate;

/// Add a message to the display list and scroll to bottom.
- (void)appendMessage:(InterChatMessageInfo *)message;

/// Update the unread badge count (shown when panel is collapsed).
- (void)setUnreadBadge:(NSInteger)count;

/// Set the list of available DM recipients (participant identities + names).
/// Pass nil or empty to disable DM selector.
- (void)setParticipantList:(nullable NSArray<NSDictionary<NSString *, NSString *> *> *)participants;

/// Whether the panel is currently expanded (visible).
@property (nonatomic, readonly) BOOL isExpanded;

/// Toggle the panel open/closed with animation.
- (void)togglePanel;

/// Expand the panel (no-op if already expanded).
- (void)expandPanel;

/// Collapse the panel (no-op if already collapsed).
- (void)collapsePanel;

/// Enable or disable the chat input field (Phase 9 — moderation).
- (void)setChatInputEnabled:(BOOL)enabled;

/// Display a system message in the chat panel (Phase 9 — moderation).
- (void)displaySystemMessage:(NSString *)text;

@end

NS_ASSUME_NONNULL_END
