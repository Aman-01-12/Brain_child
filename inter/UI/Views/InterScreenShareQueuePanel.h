#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class InterScreenShareEntry;
@class InterScreenShareQueuePanel;

@protocol InterScreenShareQueuePanelDelegate <NSObject>
@optional
- (void)screenShareQueuePanel:(InterScreenShareQueuePanel *)panel didApproveParticipant:(NSString *)identity;
- (void)screenShareQueuePanel:(InterScreenShareQueuePanel *)panel didDenyParticipant:(NSString *)identity;
- (void)screenShareQueuePanelDidApproveAll:(InterScreenShareQueuePanel *)panel;
- (void)screenShareQueuePanelDidDenyAll:(InterScreenShareQueuePanel *)panel;
@end

@interface InterScreenShareQueuePanel : NSView <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, weak, nullable) id<InterScreenShareQueuePanelDelegate> delegate;
- (void)setEntries:(NSArray<InterScreenShareEntry *> *)entries;
@property (nonatomic, readonly) BOOL isVisible;
- (void)showPanel;
- (void)hidePanel;
- (void)togglePanel;
@end

NS_ASSUME_NONNULL_END
