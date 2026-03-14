#import "InterAppSurfaceVideoSource.h"

#import <os/lock.h>

#import "InterShareTypes.h"

@interface InterAppSurfaceVideoSource ()
@property (atomic, assign, readwrite, getter=isRunning) BOOL running;
@end

@implementation InterAppSurfaceVideoSource {
    __weak MetalSurfaceView *_surfaceView;
    dispatch_queue_t _frameDispatchQueue;
    os_unfair_lock _stateLock;
    uint64_t _generation;
    InterShareVideoSourceFrameHandler _frameHandler;
    InterShareVideoSourceErrorHandler _errorHandler;
    InterShareVideoSourceAudioSampleBufferHandler _audioSampleBufferHandler;
}

@synthesize frameHandler = _frameHandler;
@synthesize errorHandler = _errorHandler;
@synthesize audioSampleBufferHandler = _audioSampleBufferHandler;

- (instancetype)initWithSurfaceView:(MetalSurfaceView *)surfaceView {
    self = [super init];
    if (!self) {
        return nil;
    }

    _surfaceView = surfaceView;
    _frameDispatchQueue = dispatch_queue_create("secure.inter.share.source.appsurface.frames",
                                                DISPATCH_QUEUE_SERIAL);
    _stateLock = OS_UNFAIR_LOCK_INIT;
    _generation = 0;
    _running = NO;
    return self;
}

- (void)start {
    __block uint64_t currentGeneration = 0;
    os_unfair_lock_lock(&_stateLock);
    if (self.running) {
        os_unfair_lock_unlock(&_stateLock);
        return;
    }

    self.running = YES;
    _generation += 1;
    currentGeneration = _generation;
    os_unfair_lock_unlock(&_stateLock);

    MetalSurfaceView *surfaceView = _surfaceView;
    if (!surfaceView) {
        os_unfair_lock_lock(&_stateLock);
        self.running = NO;
        _generation += 1;
        os_unfair_lock_unlock(&_stateLock);

        InterShareVideoSourceErrorHandler errorHandler = self.errorHandler;
        if (errorHandler) {
            NSError *error = [NSError errorWithDomain:InterShareErrorDomain
                                                 code:InterShareErrorCodeInvalidConfiguration
                                             userInfo:@{NSLocalizedDescriptionKey: @"App surface is unavailable."}];
            errorHandler(error);
        }
        return;
    }

    __weak typeof(self) weakSelf = self;
    surfaceView.frameEgressHandler = ^(CVPixelBufferRef pixelBuffer) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !pixelBuffer) {
            return;
        }

        // The producer releases this buffer after the callback returns.
        // Retain before async handoff to keep a valid lifetime on our queue.
        CVPixelBufferRetain(pixelBuffer);
        dispatch_async(strongSelf->_frameDispatchQueue, ^{
            os_unfair_lock_lock(&strongSelf->_stateLock);
            BOOL isValid = strongSelf.running && strongSelf->_generation == currentGeneration;
            os_unfair_lock_unlock(&strongSelf->_stateLock);
            if (!isValid) {
                CVPixelBufferRelease(pixelBuffer);
                return;
            }

            CMTime presentationTime = CMClockGetTime(CMClockGetHostTimeClock());
            InterShareVideoFrame *frame = [[InterShareVideoFrame alloc] initWithPixelBuffer:pixelBuffer
                                                                            presentationTime:presentationTime];
            CVPixelBufferRelease(pixelBuffer);
            InterShareVideoSourceFrameHandler frameHandler = strongSelf.frameHandler;
            if (frameHandler) {
                frameHandler(frame);
            }
        });
    };
}

- (void)stop {
    os_unfair_lock_lock(&_stateLock);
    if (!self.running) {
        os_unfair_lock_unlock(&_stateLock);
        return;
    }

    self.running = NO;
    _generation += 1;
    os_unfair_lock_unlock(&_stateLock);

    MetalSurfaceView *surfaceView = _surfaceView;
    if (surfaceView) {
        surfaceView.frameEgressHandler = nil;
    }
}

@end
