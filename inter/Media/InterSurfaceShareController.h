#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

#import "InterShareTypes.h"
#import "InterShareSink.h"
#import "MetalSurfaceView.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^InterSurfaceShareStatusHandler)(NSString *statusText);
typedef void (^InterSurfaceShareAudioSampleHandler)(CMSampleBufferRef sampleBuffer);
typedef void (^InterSurfaceShareAudioSampleObserverRegistrationBlock)(InterSurfaceShareAudioSampleHandler _Nullable handler);

@interface InterSurfaceShareController : NSObject

@property (atomic, readonly, getter=isSharing) BOOL sharing;
@property (nonatomic, copy, nullable) InterSurfaceShareStatusHandler statusHandler;
@property (nonatomic, copy, nullable) InterSurfaceShareAudioSampleObserverRegistrationBlock audioSampleObserverRegistrationBlock;
@property (nonatomic, readonly) InterShareSessionConfiguration *configuration;

/// [G8] Optional network publish sink. When non-nil, frames are routed to it
/// alongside local sinks. Setting this to nil removes it from routing.
@property (nonatomic, strong, nullable) id<InterShareSink> networkPublishSink;

- (void)configureWithSessionKind:(InterShareSessionKind)sessionKind
                       shareMode:(InterShareMode)shareMode;

- (void)startSharingFromSurfaceView:(MetalSurfaceView *)surfaceView;
- (void)stopSharingFromSurfaceView:(nullable MetalSurfaceView *)surfaceView;

@end

NS_ASSUME_NONNULL_END
