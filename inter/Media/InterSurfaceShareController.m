#import "InterSurfaceShareController.h"

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
    if (!surfaceView || self.isSharing) {
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

    if (configuration.shareMode != InterShareModeThisApp) {
        [self emitStatusText:@"Window and full-screen sharing will be enabled in the next ScreenCaptureKit phase."];
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
        _videoSource = videoSource;
        _sinks = sinks;
    }

    __weak typeof(self) weakSelf = self;
    videoSource.frameHandler = ^(InterShareVideoFrame *frame) {
        [weakSelf routeVideoFrame:frame generation:generation];
    };

    videoSource.errorHandler = ^(NSError *error) {
        NSString *status = error.localizedDescription ?: @"Sharing source failed.";
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

    [videoSource start];

    if (!videoSource.isRunning) {
        [self teardownSharingResourcesEmitStatus:NO];
        return;
    }

    [self emitStatusText:[self activeStatusTextForConfiguration:configuration]];
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

        NSArray<id<InterShareSink>> *sinks = [self currentSinksSnapshot];
        for (id<InterShareSink> sink in sinks) {
            [sink appendVideoFrame:frame];
        }
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
    if (configuration.shareMode != InterShareModeThisApp) {
        return @"Window and full-screen sharing will be enabled in the next ScreenCaptureKit phase.";
    }

    if (configuration.isRecordingEnabled) {
        return @"Secure surface share is active. Recording setup in progress.";
    }

    return @"Secure surface share is active.";
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
