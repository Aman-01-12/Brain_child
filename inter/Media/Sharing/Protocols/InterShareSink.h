#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

#import "InterShareTypes.h"
#import "InterShareVideoFrame.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^InterShareSinkStartCompletion)(BOOL active, NSString * _Nullable statusText);

@protocol InterShareSink <NSObject>

@property (atomic, readonly, getter=isActive) BOOL active;

- (void)startWithConfiguration:(InterShareSessionConfiguration *)configuration
                    completion:(InterShareSinkStartCompletion)completion;

- (void)appendVideoFrame:(InterShareVideoFrame *)frame;
- (void)appendAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer;

- (void)stopWithCompletion:(dispatch_block_t _Nullable)completion;

@end

NS_ASSUME_NONNULL_END
