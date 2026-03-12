#import "InterSurfaceShareController.h"

#import <mach/mach_time.h>
#import <os/log.h>

#import "InterAppSurfaceVideoSource.h"
#import "InterScreenCaptureVideoSource.h"
#import "InterRecordingSink.h"
#import "InterShareSink.h"
#import "InterShareVideoSource.h"

@interface InterSurfaceShareController ()
@property (atomic, assign, readwrite, getter=isSharing) BOOL sharing;
@property (nonatomic, strong, readwrite) InterShareSessionConfiguration *configuration;
@end

@implementation InterSurfaceShareController {
    dispatch_queue_t _routerQueue;
    id<InterShareVideoSource> _videoSource;
    NSArray<id<InterShareSink>> *_sinks;
    uint64_t _routingGeneration;
    uint64_t _activeStatusGeneration;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    _routerQueue = dispatch_queue_create("secure.inter.media.surface.share.router",
                                         DISPATCH_QUEUE_SERIAL);
    _sharing = NO;
    _configuration = [InterShareSessionConfiguration defaultConfiguration];
    _sinks = @[];
    _routingGeneration = 0;
    _activeStatusGeneration = 0;
    return self;
}

- (void)configureWithSessionKind:(InterShareSessionKind)sessionKind
                       shareMode:(InterShareMode)shareMode
                recordingEnabled:(BOOL)recordingEnabled {
    InterShareSessionConfiguration *updatedConfiguration = [self.configuration copy];
    updatedConfiguration.sessionKind = sessionKind;
    updatedConfiguration.shareMode = shareMode;
    updatedConfiguration.recordingEnabled = recordingEnabled;
    self.configuration = updatedConfiguration;
}

- (void)startSharingFromSurfaceView:(MetalSurfaceView *)surfaceView {
    if (self.isSharing) {
        return;
    }

    InterShareSessionConfiguration *configuration = [self.configuration copy];
    BOOL invalidInterviewMode =
    configuration.sessionKind == InterShareSessionKindInterview &&
    configuration.shareMode != InterShareModeThisApp;
    if (invalidInterviewMode) {
        [self emitStatusText:@"Interview mode only supports Share This App."];
        return;
    }

    id<InterShareVideoSource> videoSource = [self videoSourceForConfiguration:configuration
                                                                    surfaceView:surfaceView];
    if (!videoSource) {
        [self emitStatusText:@"Unable to start sharing source."];
        return;
    }

    NSArray<id<InterShareSink>> *sinks = [self sinksForConfiguration:configuration];

    __block uint64_t generation = 0;
    @synchronized(self) {
        if (self.sharing) {
            return;
        }

        self.sharing = YES;
        _routingGeneration += 1;
        generation = _routingGeneration;
        _activeStatusGeneration = 0;
        _videoSource = videoSource;
        _sinks = sinks;
    }

    __weak typeof(self) weakSelf = self;
    videoSource.frameHandler = ^(InterShareVideoFrame *frame) {
        [weakSelf routeVideoFrame:frame generation:generation];
    };

    videoSource.errorHandler = ^(NSError *error) {
        if (!weakSelf || ![weakSelf isGenerationActive:generation]) {
            return;
        }

        NSString *status = error.localizedDescription ?: @"Sharing source failed.";
        [weakSelf teardownSharingResourcesEmitStatus:NO];
        [weakSelf emitStatusText:status];
    };

    [self registerAudioObserverForGeneration:generation];

    for (id<InterShareSink> sink in sinks) {
        [sink startWithConfiguration:configuration completion:^(BOOL active, NSString * _Nullable statusText) {
#pragma unused(active)
            if (statusText.length > 0) {
                [weakSelf emitStatusText:statusText];
            }
        }];
    }

    if ([videoSource isKindOfClass:[InterScreenCaptureVideoSource class]]) {
        InterScreenCaptureVideoSource *screenSource = (InterScreenCaptureVideoSource *)videoSource;
        if (configuration.shareMode == InterShareModeWindow) {
            screenSource.selectedWindowIdentifier = configuration.selectedWindowIdentifier;
            [screenSource startCaptureForSelectedWindow];
        } else {
            [screenSource startCaptureForSelectedDisplay];
        }
    } else {
        [videoSource start];
    }

    [self emitStatusText:[self startingStatusTextForConfiguration:configuration]];
}

- (void)stopSharingFromSurfaceView:(MetalSurfaceView *)surfaceView {
#pragma unused(surfaceView)
    [self teardownSharingResourcesEmitStatus:YES];
}

#pragma mark - Internal

- (id<InterShareVideoSource>)videoSourceForConfiguration:(InterShareSessionConfiguration *)configuration
                                              surfaceView:(MetalSurfaceView *)surfaceView {
    switch (configuration.shareMode) {
        case InterShareModeThisApp:
            return [[InterAppSurfaceVideoSource alloc] initWithSurfaceView:surfaceView];
        case InterShareModeWindow:
        case InterShareModeEntireScreen:
            return [[InterScreenCaptureVideoSource alloc] init];
    }
}

- (NSArray<id<InterShareSink>> *)sinksForConfiguration:(InterShareSessionConfiguration *)configuration {
    NSMutableArray<id<InterShareSink>> *sinks = [NSMutableArray array];
    if (configuration.isRecordingEnabled) {
        [sinks addObject:[[InterRecordingSink alloc] init]];
    }
    // [G8] Network publish sink — added when non-nil
    id<InterShareSink> networkSink = self.networkPublishSink;
    if (networkSink) {
        [sinks addObject:networkSink];
    }
    return [sinks copy];
}

- (void)registerAudioObserverForGeneration:(uint64_t)generation {
    InterSurfaceShareAudioSampleObserverRegistrationBlock registrationBlock = self.audioSampleObserverRegistrationBlock;
    if (!registrationBlock) {
        return;
    }

    dispatch_queue_t routerQueue = _routerQueue;
    __weak typeof(self) weakSelf = self;
    registrationBlock(^(CMSampleBufferRef sampleBuffer) {
        if (!sampleBuffer) {
            return;
        }

        CFRetain(sampleBuffer);
        dispatch_async(routerQueue, ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || ![strongSelf isGenerationActive:generation]) {
                CFRelease(sampleBuffer);
                return;
            }

            NSArray<id<InterShareSink>> *sinks = [strongSelf currentSinksSnapshot];
            for (id<InterShareSink> sink in sinks) {
                [sink appendAudioSampleBuffer:sampleBuffer];
            }
            CFRelease(sampleBuffer);
        });
    });
}

- (void)routeVideoFrame:(InterShareVideoFrame *)frame generation:(uint64_t)generation {
    if (!frame) {
        return;
    }

    dispatch_async(_routerQueue, ^{
        if (![self isGenerationActive:generation]) {
            return;
        }

        BOOL shouldEmitActiveStatus = NO;
        InterShareSessionConfiguration *configurationSnapshot = nil;
        @synchronized(self) {
            if (_activeStatusGeneration != generation) {
                _activeStatusGeneration = generation;
                shouldEmitActiveStatus = YES;
                configurationSnapshot = [self.configuration copy];
            }
        }
        if (shouldEmitActiveStatus && configurationSnapshot) {
            [self emitStatusText:[self activeStatusTextForConfiguration:configurationSnapshot]];
        }

        NSArray<id<InterShareSink>> *sinks = [self currentSinksSnapshot];
#if DEBUG
        uint64_t routeStart = mach_absolute_time();
#endif
        for (id<InterShareSink> sink in sinks) {
            [sink appendVideoFrame:frame];
        }
#if DEBUG
        // [G5] Debug timing check: total routing time should be < 5ms.
        // Use os_log instead of NSAssert — occasional scheduling jitter, thread
        // preemption, or IOSurface kernel calls can cause transient spikes that
        // are NOT indicative of a broken sink contract. A crash here masks the
        // real production experience.
        uint64_t routeEnd = mach_absolute_time();
        mach_timebase_info_data_t info;
        mach_timebase_info(&info);
        double elapsedMs = (double)(routeEnd - routeStart) * (double)info.numer / (double)info.denom / 1e6;
        if (elapsedMs > 5.0) {
            os_log_fault(OS_LOG_DEFAULT,
                         "[G5] Router queue frame routing took %.2fms (>5ms limit) — "
                         "check sink appendVideoFrame: implementations for blocking work",
                         elapsedMs);
        }
#endif
    });
}

- (NSArray<id<InterShareSink>> *)currentSinksSnapshot {
    @synchronized(self) {
        return [_sinks copy];
    }
}

- (BOOL)isGenerationActive:(uint64_t)generation {
    @synchronized(self) {
        return self.sharing && _routingGeneration == generation;
    }
}

- (void)teardownSharingResourcesEmitStatus:(BOOL)emitStatus {
    id<InterShareVideoSource> videoSource = nil;
    NSArray<id<InterShareSink>> *sinks = nil;
    InterSurfaceShareAudioSampleObserverRegistrationBlock registrationBlock = nil;

    @synchronized(self) {
        if (!self.sharing && _videoSource == nil && _sinks.count == 0) {
            return;
        }

        self.sharing = NO;
        _routingGeneration += 1;
        _activeStatusGeneration = 0;

        videoSource = _videoSource;
        sinks = [_sinks copy];
        registrationBlock = self.audioSampleObserverRegistrationBlock;

        _videoSource = nil;
        _sinks = @[];
    }

    if (videoSource) {
        [videoSource stop];
        videoSource.frameHandler = nil;
        videoSource.errorHandler = nil;
    }

    if (registrationBlock) {
        registrationBlock(nil);
    }

    dispatch_group_t stopGroup = dispatch_group_create();
    for (id<InterShareSink> sink in sinks) {
        dispatch_group_enter(stopGroup);
        [sink stopWithCompletion:^{
            dispatch_group_leave(stopGroup);
        }];
    }

    if (!emitStatus) {
        return;
    }

    dispatch_group_notify(stopGroup, dispatch_get_main_queue(), ^{
        [self emitStatusText:@"Secure surface share is off."];
    });
}

- (NSString *)activeStatusTextForConfiguration:(InterShareSessionConfiguration *)configuration {
    NSString *sourceLabel = [self sourceLabelForShareMode:configuration.shareMode];
    if (configuration.isRecordingEnabled) {
        return [NSString stringWithFormat:@"%@ share is active. Recording destination is ready.",
                                          sourceLabel];
    }

    return [NSString stringWithFormat:@"%@ share is active.", sourceLabel];
}

- (NSString *)startingStatusTextForConfiguration:(InterShareSessionConfiguration *)configuration {
    NSString *sourceLabel = [self sourceLabelForShareMode:configuration.shareMode];
    if (configuration.isRecordingEnabled) {
        return [NSString stringWithFormat:@"Starting %@ share. Recording destination is being prepared.",
                                          sourceLabel.lowercaseString];
    }

    return [NSString stringWithFormat:@"Starting %@ share.", sourceLabel.lowercaseString];
}

- (NSString *)sourceLabelForShareMode:(InterShareMode)shareMode {
    switch (shareMode) {
        case InterShareModeWindow:
            return @"Window";
        case InterShareModeEntireScreen:
            return @"Entire Screen";
        case InterShareModeThisApp:
        default:
            return @"This App";
    }
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
