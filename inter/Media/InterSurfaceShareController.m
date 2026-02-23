#import "InterSurfaceShareController.h"

#import <QuartzCore/QuartzCore.h>

@interface InterSurfaceShareController ()
@property (atomic, assign, readwrite, getter=isSharing) BOOL sharing;
@end

@implementation InterSurfaceShareController {
    dispatch_queue_t _metricsQueue;
    uint64_t _framesInWindow;
    CFTimeInterval _windowStartSeconds;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    _metricsQueue = dispatch_queue_create("secure.inter.media.surface.share.metrics",
                                          DISPATCH_QUEUE_SERIAL);
    _sharing = NO;
    return self;
}

- (void)startSharingFromSurfaceView:(MetalSurfaceView *)surfaceView {
    if (!surfaceView || self.isSharing) {
        return;
    }

    self.sharing = YES;
    dispatch_async(_metricsQueue, ^{
        self->_framesInWindow = 0;
        self->_windowStartSeconds = CACurrentMediaTime();
    });

    __weak typeof(self) weakSelf = self;
    surfaceView.frameEgressHandler = ^(CVPixelBufferRef pixelBuffer) {
        [weakSelf handleEgressPixelBuffer:pixelBuffer];
    };

    [self emitStatusText:@"Secure surface share is active."];
}

- (void)stopSharingFromSurfaceView:(MetalSurfaceView *)surfaceView {
    if (!self.isSharing) {
        return;
    }

    self.sharing = NO;
    if (surfaceView) {
        surfaceView.frameEgressHandler = nil;
    }

    dispatch_async(_metricsQueue, ^{
        self->_framesInWindow = 0;
        self->_windowStartSeconds = 0;
    });

    [self emitStatusText:@"Secure surface share is off."];
}

#pragma mark - Internal

- (void)handleEgressPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer || !self.isSharing) {
        return;
    }

    size_t frameWidth = CVPixelBufferGetWidth(pixelBuffer);
    size_t frameHeight = CVPixelBufferGetHeight(pixelBuffer);

    dispatch_async(_metricsQueue, ^{
        if (!self.isSharing) {
            return;
        }

        CFTimeInterval nowSeconds = CACurrentMediaTime();
        if (self->_windowStartSeconds <= 0) {
            self->_windowStartSeconds = nowSeconds;
        }

        self->_framesInWindow += 1;
        CFTimeInterval windowDuration = nowSeconds - self->_windowStartSeconds;
        if (windowDuration < 0.50) {
            return;
        }

        double fps = (double)self->_framesInWindow / windowDuration;
        self->_framesInWindow = 0;
        self->_windowStartSeconds = nowSeconds;

        NSString *statusText =
        [NSString stringWithFormat:@"Sharing %zux%zu at %.1f fps",
                                   frameWidth,
                                   frameHeight,
                                   fps];
        [self emitStatusText:statusText];
    });
}

- (void)emitStatusText:(NSString *)text {
    if (!text.length) {
        return;
    }

    InterSurfaceShareStatusHandler handler = self.statusHandler;
    if (!handler) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        handler(text);
    });
}

@end
