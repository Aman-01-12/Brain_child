#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class InterRaisedHandEntry;
@class InterSpeakerQueuePanel;

/// Delegate for speaker queue host actions.
@protocol InterSpeakerQueuePanelDelegate <NSObject>
@optional
/// Host dismissed a raised hand from the queue.
- (void)speakerQueuePanel:(InterSpeakerQueuePanel *)panel didDismissParticipant:(NSString *)identity;
@end

/// [Phase 8.2.4] Host-facing raised-hand queue panel.
///
/// Shows an ordered list of participants who raised their hand.
/// Each entry displays: queue position, display name, raised time.
/// Host can dismiss entries.
@interface InterSpeakerQueuePanel : NSView <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, weak, nullable) id<InterSpeakerQueuePanelDelegate> delegate;

/// Update the queue entries. Reloads the table view.
- (void)setEntries:(NSArray<InterRaisedHandEntry *> *)entries;

/// Whether the panel is currently visible.
@property (nonatomic, readonly) BOOL isVisible;

/// Show the panel.
- (void)showPanel;

/// Hide the panel.
- (void)hidePanel;

/// Toggle visibility.
- (void)togglePanel;

@end

NS_ASSUME_NONNULL_END
