#import "InterTrackRendererBridge.h"
#import "InterRemoteVideoLayoutManager.h"

#if __has_include("inter-Swift.h")
#import "inter-Swift.h"
#endif

@interface InterTrackRendererBridge () <InterRemoteTrackRenderer>
@property (nonatomic, weak) InterRemoteVideoLayoutManager *layoutManager;
@end

@implementation InterTrackRendererBridge

- (instancetype)initWithLayoutManager:(InterRemoteVideoLayoutManager *)layoutManager {
    self = [super init];
    if (!self) {
        return nil;
    }
    self.layoutManager = layoutManager;
    return self;
}

#pragma mark - InterRemoteTrackRenderer

- (void)didReceiveRemoteCameraFrame:(CVPixelBufferRef)pixelBuffer fromParticipant:(NSString *)participantId {
    InterRemoteVideoLayoutManager *mgr = self.layoutManager;
    if (mgr) {
        [mgr handleRemoteCameraFrame:pixelBuffer fromParticipant:participantId];
    }
}

- (void)didReceiveRemoteScreenShareFrame:(CVPixelBufferRef)pixelBuffer fromParticipant:(NSString *)participantId {
    InterRemoteVideoLayoutManager *mgr = self.layoutManager;
    if (mgr) {
        [mgr handleRemoteScreenShareFrame:pixelBuffer fromParticipant:participantId];
    }
}

- (void)remoteTrackDidMute:(InterTrackKind)kind forParticipant:(NSString *)participantId {
    dispatch_async(dispatch_get_main_queue(), ^{
        InterRemoteVideoLayoutManager *mgr = self.layoutManager;
        if (mgr) {
            [mgr handleRemoteTrackMuted:(NSUInteger)kind forParticipant:participantId];
        }
    });
}

- (void)remoteTrackDidUnmute:(InterTrackKind)kind forParticipant:(NSString *)participantId {
    dispatch_async(dispatch_get_main_queue(), ^{
        InterRemoteVideoLayoutManager *mgr = self.layoutManager;
        if (mgr) {
            [mgr handleRemoteTrackUnmuted:(NSUInteger)kind forParticipant:participantId];
        }
    });
}

- (void)remoteTrackDidEnd:(InterTrackKind)kind forParticipant:(NSString *)participantId {
    dispatch_async(dispatch_get_main_queue(), ^{
        InterRemoteVideoLayoutManager *mgr = self.layoutManager;
        if (mgr) {
            [mgr handleRemoteTrackEnded:(NSUInteger)kind forParticipant:participantId];
        }
    });
}

@end
