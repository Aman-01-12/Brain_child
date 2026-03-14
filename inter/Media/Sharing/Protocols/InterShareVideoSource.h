#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

#import "InterShareVideoFrame.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^InterShareVideoSourceFrameHandler)(InterShareVideoFrame *frame);
typedef void (^InterShareVideoSourceErrorHandler)(NSError *error);
typedef void (^InterShareVideoSourceAudioSampleBufferHandler)(CMSampleBufferRef sampleBuffer);

@protocol InterShareVideoSource <NSObject>

@property (atomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, copy, nullable) InterShareVideoSourceFrameHandler frameHandler;
@property (nonatomic, copy, nullable) InterShareVideoSourceErrorHandler errorHandler;
@property (nonatomic, copy, nullable) InterShareVideoSourceAudioSampleBufferHandler audioSampleBufferHandler;

- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
