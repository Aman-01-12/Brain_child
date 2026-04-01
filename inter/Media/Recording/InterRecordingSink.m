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

    os_unfair_lock_lock(&_sinkLock);
    BOOL active = _isActive;
    os_unfair_lock_unlock(&_sinkLock);

    if (!active) return;

    // Feed the screen share frame to the composed renderer.
    InterComposedRenderer *renderer = self.composedRenderer;
    if (renderer) {
        [renderer updateScreenShareFrame:frame.pixelBuffer];
    }
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
    os_unfair_lock_lock(&_sinkLock);
    _isActive = NO;
    os_unfair_lock_unlock(&_sinkLock);

    os_log_info(InterRecordingSinkLog(), "Recording sink stopped.");

    // Clear the screen share source on the renderer so layout recalculates.
    InterComposedRenderer *renderer = self.composedRenderer;
    if (renderer) {
        [renderer updateScreenShareFrame:NULL];
    }

    if (completion) {
        completion();
    }
}

@end
