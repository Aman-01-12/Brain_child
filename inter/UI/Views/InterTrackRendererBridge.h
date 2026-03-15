#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class InterRemoteVideoLayoutManager;

@protocol InterTrackRendererPreviewObserver <NSObject>
@optional
- (void)observeRemoteCameraFrame:(CVPixelBufferRef)pixelBuffer fromParticipant:(NSString *)participantId;
- (void)observeRemoteScreenShareFrame:(CVPixelBufferRef)pixelBuffer fromParticipant:(NSString *)participantId;
- (void)observeRemoteTrackMuted:(NSUInteger)kind forParticipant:(NSString *)participantId;
- (void)observeRemoteTrackUnmuted:(NSUInteger)kind forParticipant:(NSString *)participantId;
- (void)observeRemoteTrackEnded:(NSUInteger)kind forParticipant:(NSString *)participantId;
@end

/// Bridges the Swift InterRemoteTrackRenderer protocol to the ObjC
/// InterRemoteVideoLayoutManager, routing decoded remote frames
/// and track events to the layout manager.
///
/// Set as subscriber.trackRenderer in ObjC:
///   self.trackRendererBridge = [[InterTrackRendererBridge alloc] initWithLayoutManager:self.remoteLayout];
///   roomController.subscriber.trackRenderer = (id<InterRemoteTrackRenderer>)self.trackRendererBridge;
@interface InterTrackRendererBridge : NSObject

- (instancetype)initWithLayoutManager:(InterRemoteVideoLayoutManager *)layoutManager;
- (instancetype)initWithLayoutManager:(InterRemoteVideoLayoutManager *)layoutManager
                      previewObserver:(id<InterTrackRendererPreviewObserver> _Nullable)previewObserver;

@end

NS_ASSUME_NONNULL_END
