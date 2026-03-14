#import <Cocoa/Cocoa.h>
#import <CoreVideo/CoreVideo.h>

#import "MetalRenderEngine.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^MetalSurfaceFrameEgressHandler)(CVPixelBufferRef pixelBuffer);

@interface MetalSurfaceView : NSView

@property (nonatomic, copy, nullable) MetalSurfaceFrameEgressHandler frameEgressHandler;

/// Stops the display link and clears capture callbacks before the view is
/// removed from the hierarchy. Callers use this during window teardown so the
/// display-link thread cannot race against deallocation or window removal.
- (void)shutdownRenderingSynchronously;

@end

NS_ASSUME_NONNULL_END
