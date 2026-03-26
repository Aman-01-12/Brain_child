#import "InterTrackRendererBridge.h"
#import "InterRemoteVideoLayoutManager.h"

#if __has_include("inter-Swift.h")
#import "inter-Swift.h"
#endif

@interface InterTrackRendererBridge () <InterRemoteTrackRenderer>
@property (nonatomic, weak) InterRemoteVideoLayoutManager *layoutManager;
@property (nonatomic, weak, nullable) id<InterTrackRendererPreviewObserver> previewObserver;
@end

@implementation InterTrackRendererBridge

- (instancetype)initWithLayoutManager:(InterRemoteVideoLayoutManager *)layoutManager {
    return [self initWithLayoutManager:layoutManager previewObserver:nil];
}

- (instancetype)initWithLayoutManager:(InterRemoteVideoLayoutManager *)layoutManager
                      previewObserver:(id<InterTrackRendererPreviewObserver>)previewObserver {
    self = [super init];
    if (!self) {
        return nil;
    }
    self.layoutManager = layoutManager;
    self.previewObserver = previewObserver;
    return self;
}

#pragma mark - InterRemoteTrackRenderer

- (void)didReceiveRemoteCameraFrame:(CVPixelBufferRef)pixelBuffer fromParticipant:(NSString *)participantId {
    InterRemoteVideoLayoutManager *mgr = self.layoutManager;
    if (mgr) {
        [mgr handleRemoteCameraFrame:pixelBuffer fromParticipant:participantId];
    }
    id<InterTrackRendererPreviewObserver> previewObserver = self.previewObserver;
    if ([previewObserver respondsToSelector:@selector(observeRemoteCameraFrame:fromParticipant:)]) {
        [previewObserver observeRemoteCameraFrame:pixelBuffer fromParticipant:participantId];
    }
}

- (void)didReceiveRemoteScreenShareFrame:(CVPixelBufferRef)pixelBuffer fromParticipant:(NSString *)participantId {
    InterRemoteVideoLayoutManager *mgr = self.layoutManager;
    if (mgr) {
        [mgr handleRemoteScreenShareFrame:pixelBuffer fromParticipant:participantId];
    }
    id<InterTrackRendererPreviewObserver> previewObserver = self.previewObserver;
    if ([previewObserver respondsToSelector:@selector(observeRemoteScreenShareFrame:fromParticipant:)]) {
        [previewObserver observeRemoteScreenShareFrame:pixelBuffer fromParticipant:participantId];
    }
}

- (void)remoteTrackDidMute:(InterTrackKind)kind forParticipant:(NSString *)participantId {
    dispatch_async(dispatch_get_main_queue(), ^{
        InterRemoteVideoLayoutManager *mgr = self.layoutManager;
        if (mgr) {
            [mgr handleRemoteTrackMuted:(NSUInteger)kind forParticipant:participantId];
        }
        id<InterTrackRendererPreviewObserver> previewObserver = self.previewObserver;
        if ([previewObserver respondsToSelector:@selector(observeRemoteTrackMuted:forParticipant:)]) {
            [previewObserver observeRemoteTrackMuted:(NSUInteger)kind forParticipant:participantId];
        }
    });
}

- (void)remoteTrackDidUnmute:(InterTrackKind)kind forParticipant:(NSString *)participantId {
    dispatch_async(dispatch_get_main_queue(), ^{
        InterRemoteVideoLayoutManager *mgr = self.layoutManager;
        if (mgr) {
            [mgr handleRemoteTrackUnmuted:(NSUInteger)kind forParticipant:participantId];
        }
        id<InterTrackRendererPreviewObserver> previewObserver = self.previewObserver;
        if ([previewObserver respondsToSelector:@selector(observeRemoteTrackUnmuted:forParticipant:)]) {
            [previewObserver observeRemoteTrackUnmuted:(NSUInteger)kind forParticipant:participantId];
        }
    });
}

- (void)remoteTrackDidEnd:(InterTrackKind)kind forParticipant:(NSString *)participantId {
    dispatch_async(dispatch_get_main_queue(), ^{
        InterRemoteVideoLayoutManager *mgr = self.layoutManager;
        if (mgr) {
            [mgr handleRemoteTrackEnded:(NSUInteger)kind forParticipant:participantId];
        }
        id<InterTrackRendererPreviewObserver> previewObserver = self.previewObserver;
        if ([previewObserver respondsToSelector:@selector(observeRemoteTrackEnded:forParticipant:)]) {
            [previewObserver observeRemoteTrackEnded:(NSUInteger)kind forParticipant:participantId];
        }
    });
}

- (void)remoteParticipantDidUpdateDisplayName:(NSString *)displayName forParticipant:(NSString *)participantId {
    dispatch_async(dispatch_get_main_queue(), ^{
        InterRemoteVideoLayoutManager *mgr = self.layoutManager;
        if (mgr) {
            [mgr registerDisplayName:displayName forParticipant:participantId];
        }
    });
}

@end
