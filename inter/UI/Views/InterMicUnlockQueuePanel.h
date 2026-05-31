#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class InterMicUnlockEntry;
@class InterMicUnlockQueuePanel;

@protocol InterMicUnlockQueuePanelDelegate <NSObject>
@optional
- (void)micUnlockQueuePanel:(InterMicUnlockQueuePanel *)panel didApproveParticipant:(NSString *)identity;
- (void)micUnlockQueuePanel:(InterMicUnlockQueuePanel *)panel didDenyParticipant:(NSString *)identity;
- (void)micUnlockQueuePanelDidApproveAll:(InterMicUnlockQueuePanel *)panel;
- (void)micUnlockQueuePanelDidDenyAll:(InterMicUnlockQueuePanel *)panel;
@end

@interface InterMicUnlockQueuePanel : NSView <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, weak, nullable) id<InterMicUnlockQueuePanelDelegate> delegate;
- (void)setEntries:(NSArray<InterMicUnlockEntry *> *)entries;
@property (nonatomic, readonly) BOOL isVisible;
- (void)showPanel;
- (void)hidePanel;
- (void)togglePanel;
@end

NS_ASSUME_NONNULL_END
