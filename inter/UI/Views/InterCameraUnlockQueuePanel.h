#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class InterCameraUnlockEntry;
@class InterCameraUnlockQueuePanel;

@protocol InterCameraUnlockQueuePanelDelegate <NSObject>
@optional
- (void)cameraUnlockQueuePanel:(InterCameraUnlockQueuePanel *)panel didApproveParticipant:(NSString *)identity;
- (void)cameraUnlockQueuePanel:(InterCameraUnlockQueuePanel *)panel didDenyParticipant:(NSString *)identity;
- (void)cameraUnlockQueuePanelDidApproveAll:(InterCameraUnlockQueuePanel *)panel;
- (void)cameraUnlockQueuePanelDidDenyAll:(InterCameraUnlockQueuePanel *)panel;
@end

@interface InterCameraUnlockQueuePanel : NSView <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, weak, nullable) id<InterCameraUnlockQueuePanelDelegate> delegate;
- (void)setEntries:(NSArray<InterCameraUnlockEntry *> *)entries;
@property (nonatomic, readonly) BOOL isVisible;
- (void)showPanel;
- (void)hidePanel;
- (void)togglePanel;
@end

NS_ASSUME_NONNULL_END
