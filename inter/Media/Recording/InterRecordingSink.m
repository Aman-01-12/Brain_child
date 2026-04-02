#import "InterRecordingSink.h"

#import "InterComposedRenderer.h"
#import "InterRecordingEngine.h"
#import "InterShareVideoFrame.h"

#import <os/lock.h>
#import <os/log.h>

static os_log_t InterRecordingSinkLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.inter.recording", "sink");
    });
    return log;
}

@implementation InterRecordingSink {
    os_unfair_lock _sinkLock;
    BOOL _isActive;
}

// ---------------------------------------------------------------------------
// MARK: - Init
// ---------------------------------------------------------------------------

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _sinkLock = OS_UNFAIR_LOCK_INIT;
    _isActive = NO;

    return self;
}

// ---------------------------------------------------------------------------
// MARK: - InterShareSink Protocol
// ---------------------------------------------------------------------------

- (BOOL)isActive {
    os_unfair_lock_lock(&_sinkLock);
    BOOL active = _isActive;
    os_unfair_lock_unlock(&_sinkLock);
    return active;
}

- (void)startWithConfiguration:(InterShareSessionConfiguration *)configuration
                    completion:(InterShareSinkStartCompletion)completion {
    os_unfair_lock_lock(&_sinkLock);
    _isActive = YES;
    os_unfair_lock_unlock(&_sinkLock);

    os_log_info(InterRecordingSinkLog(), "Recording sink started.");

    if (completion) {
        completion(YES, nil);
    }
}

- (void)appendVideoFrame:(InterShareVideoFrame *)frame {
    if (!frame) return;

    // Hold _sinkLock across both the _isActive check and the renderer update.
    // This prevents a stop racing between the check and the call, which would
    // deliver a frame to the renderer after stopWithCompletion: has already
    // cleared it.
    os_unfair_lock_lock(&_sinkLock);
    BOOL active = _isActive;
    if (active) {
        InterComposedRenderer *renderer = self.composedRenderer;
        if (renderer) {
            [renderer updateScreenShareFrame:frame.pixelBuffer];
        }
    }
    os_unfair_lock_unlock(&_sinkLock);
}

- (void)appendAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!sampleBuffer) return;

    os_unfair_lock_lock(&_sinkLock);
    BOOL active = _isActive;
    os_unfair_lock_unlock(&_sinkLock);

    if (!active) return;

    // Feed audio to the recording engine.
    InterRecordingEngine *engine = self.recordingEngine;
    if (engine) {
        [engine appendAudioSampleBuffer:sampleBuffer];
    }
}

- (void)stopWithCompletion:(dispatch_block_t)completion {
    // Set _isActive = NO and clear the renderer atomically under _sinkLock.
    // Holding the lock across both operations ensures that any concurrent
    // appendVideoFrame: that already passed the _isActive check (and is waiting
    // for the lock) will see _isActive = NO and skip its renderer update.
    os_unfair_lock_lock(&_sinkLock);
    _isActive = NO;
    InterComposedRenderer *renderer = self.composedRenderer;
    if (renderer) {
        [renderer updateScreenShareFrame:NULL];
    }
    os_unfair_lock_unlock(&_sinkLock);

    os_log_info(InterRecordingSinkLog(), "Recording sink stopped.");

    if (completion) {
        completion();
    }
}

@end
