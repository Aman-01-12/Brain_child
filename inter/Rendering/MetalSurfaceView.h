#import <Cocoa/Cocoa.h>
#import <CoreVideo/CoreVideo.h>

#import "MetalRenderEngine.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^MetalSurfaceFrameEgressHandler)(CVPixelBufferRef pixelBuffer);

@interface MetalSurfaceView : NSView

@property (nonatomic, copy, nullable) MetalSurfaceFrameEgressHandler frameEgressHandler;

@end

NS_ASSUME_NONNULL_END
