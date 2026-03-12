#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class InterRemoteVideoLayoutManager;

/// Bridges the Swift InterRemoteTrackRenderer protocol to the ObjC
/// InterRemoteVideoLayoutManager, routing decoded remote frames
/// and track events to the layout manager.
///
/// Set as subscriber.trackRenderer in ObjC:
///   self.trackRendererBridge = [[InterTrackRendererBridge alloc] initWithLayoutManager:self.remoteLayout];
///   roomController.subscriber.trackRenderer = self.trackRendererBridge;
@interface InterTrackRendererBridge : NSObject

- (instancetype)initWithLayoutManager:(InterRemoteVideoLayoutManager *)layoutManager;

@end

NS_ASSUME_NONNULL_END
