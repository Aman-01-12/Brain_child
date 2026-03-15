#import "InterSurfaceShareController.h"

#import <mach/mach_time.h>
#import <os/log.h>

#import "InterAppSurfaceVideoSource.h"
#import "InterScreenCaptureVideoSource.h"
#import "InterShareSink.h"
#import "InterShareVideoSource.h"
#import "InterViewSnapshotVideoSource.h"

@interface InterSurfaceShareController ()
@property (atomic, assign, readwrite, getter=isSharing) BOOL sharing;
@property (atomic, assign, readwrite, getter=isStartPending) BOOL startPending;
@property (nonatomic, strong, readwrite) InterShareSessionConfiguration *configuration;
@end

@implementation InterSurfaceShareController {
    dispatch_queue_t _routerQueue;
    id<InterShareVideoSource> _videoSource;
    NSArray<id<InterShareSink>> *_sinks;
    uint64_t _routingGeneration;
    uint64_t _activeStatusGeneration;
    NSUInteger _slowRouteStreak;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    _routerQueue = dispatch_queue_create("secure.inter.media.surface.share.router",
                                         DISPATCH_QUEUE_SERIAL);
    _sharing = NO;
    _startPending = NO;
    _configuration = [InterShareSessionConfiguration defaultConfiguration];
    _sinks = @[];
    _routingGeneration = 0;
    _activeStatusGeneration = 0;
    _slowRouteStreak = 0;
    return self;
}

- (void)configureWithSessionKind:(InterShareSessionKind)sessionKind
                       shareMode:(InterShareMode)shareMode {
    InterShareSessionConfiguration *updatedConfiguration = [self.configuration copy];
    updatedConfiguration.sessionKind = sessionKind;
    updatedConfiguration.shareMode = shareMode;
    self.configuration = updatedConfiguration;
}

- (void)setShareSystemAudioEnabled:(BOOL)enabled {
    InterShareSessionConfiguration *updatedConfiguration = [self.configuration copy];
    updatedConfiguration.shareSystemAudioEnabled = enabled;
    self.configuration = updatedConfiguration;
}

- (void)startSharingFromSurfaceView:(MetalSurfaceView *)surfaceView {
    if (self.isSharing || self.isStartPending) {
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

    if ([videoSource isKindOfClass:[InterScreenCaptureVideoSource class]]) {
        InterScreenCaptureVideoSource *screenSource = (InterScreenCaptureVideoSource *)videoSource;
        BOOL shouldCaptureSystemAudio = configuration.isShareSystemAudioEnabled &&
        configuration.shareMode != InterShareModeThisApp;
        screenSource.captureSystemAudioEnabled = shouldCaptureSystemAudio;
    }

    NSArray<id<InterShareSink>> *sinks = [self sinksForConfiguration:configuration];

    __block uint64_t generation = 0;
    @synchronized(self) {
        if (self.sharing || self.startPending) {
            return;
        }

        self.startPending = YES;
        self.sharing = NO;
        _routingGeneration += 1;
        generation = _routingGeneration;
        _activeStatusGeneration = 0;
        _videoSource = videoSource;
        _sinks = sinks;
    }

    [self emitStatusText:[self startingStatusTextForConfiguration:configuration]];

    __weak typeof(self) weakSelf = self;
    videoSource.frameHandler = ^(InterShareVideoFrame *frame) {
        [weakSelf routeVideoFrame:frame generation:generation];
    };

    videoSource.errorHandler = ^(NSError *error) {
        if (!weakSelf || ![weakSelf isGenerationCurrent:generation includePending:YES]) {
            return;
        }

        NSString *status = error.localizedDescription ?: @"Sharing source failed.";
        [weakSelf teardownSharingResourcesEmitStatus:NO];
        [weakSelf emitStatusText:status];
    };

    BOOL shouldUseSystemAudioPath = configuration.isShareSystemAudioEnabled &&
    [videoSource isKindOfClass:[InterScreenCaptureVideoSource class]];
    if (shouldUseSystemAudioPath) {
        [self registerVideoSourceAudioObserverForGeneration:generation source:videoSource];
    } else {
        [self registerAudioObserverForGeneration:generation];
    }

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
}

- (void)stopSharingFromSurfaceView:(MetalSurfaceView *)surfaceView {
#pragma unused(surfaceView)
    [self teardownSharingResourcesEmitStatus:YES];
}

#pragma mark - Internal

- (id<InterShareVideoSource>)videoSourceForConfiguration:(InterShareSessionConfiguration *)configuration
                                              surfaceView:(MetalSurfaceView *)surfaceView {
    id<InterShareVideoSource> injectedSource = self.customVideoSource;
    if (injectedSource && configuration.shareMode == InterShareModeThisApp) {
        return injectedSource;
    }

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
            if (!strongSelf || ![strongSelf isGenerationCurrent:generation includePending:YES]) {
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

- (void)registerVideoSourceAudioObserverForGeneration:(uint64_t)generation
                                               source:(id<InterShareVideoSource>)videoSource {
    dispatch_queue_t routerQueue = _routerQueue;
    __weak typeof(self) weakSelf = self;
    videoSource.audioSampleBufferHandler = ^(CMSampleBufferRef sampleBuffer) {
        if (!sampleBuffer) {
            return;
        }

        CFRetain(sampleBuffer);
        dispatch_async(routerQueue, ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || ![strongSelf isGenerationCurrent:generation includePending:YES]) {
                CFRelease(sampleBuffer);
                return;
            }

            NSArray<id<InterShareSink>> *sinks = [strongSelf currentSinksSnapshot];
            for (id<InterShareSink> sink in sinks) {
                [sink appendAudioSampleBuffer:sampleBuffer];
            }
            CFRelease(sampleBuffer);
        });
    };
}

- (void)routeVideoFrame:(InterShareVideoFrame *)frame generation:(uint64_t)generation {
    if (!frame) {
        return;
    }

    dispatch_async(_routerQueue, ^{
        BOOL generationCurrent = NO;
        BOOL shouldEmitActiveStatus = NO;
        InterShareSessionConfiguration *configurationSnapshot = nil;
        @synchronized(self) {
            generationCurrent = ((self.sharing || self.startPending) && _routingGeneration == generation);
            if (!generationCurrent) {
                return;
            }

            if (self.startPending) {
                self.startPending = NO;
                self.sharing = YES;
            }

            if (self->_activeStatusGeneration != generation) {
                self->_activeStatusGeneration = generation;
                shouldEmitActiveStatus = YES;
                configurationSnapshot = [self.configuration copy];
            }
        }

        if (!generationCurrent) {
            return;
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
            self->_slowRouteStreak += 1;
            BOOL isSevereSpike = elapsedMs > 20.0;
            BOOL isSustained = self->_slowRouteStreak >= 3;
            if (isSevereSpike || isSustained) {
                os_log_fault(OS_LOG_DEFAULT,
                             "[G5] Router queue frame routing took %.2fms (>5ms), streak=%lu — "
                             "check sink appendVideoFrame: implementations for blocking work",
                             elapsedMs,
                             (unsigned long)self->_slowRouteStreak);
            } else {
                os_log_debug(OS_LOG_DEFAULT,
                             "[G5] Transient slow router frame: %.2fms (streak=%lu)",
                             elapsedMs,
                             (unsigned long)self->_slowRouteStreak);
            }
        } else {
            self->_slowRouteStreak = 0;
        }
#endif
    });
}

- (NSArray<id<InterShareSink>> *)currentSinksSnapshot {
    @synchronized(self) {
        return [_sinks copy];
    }
}

- (BOOL)isGenerationCurrent:(uint64_t)generation includePending:(BOOL)includePending {
    @synchronized(self) {
        BOOL isCurrentGeneration = (_routingGeneration == generation);
        if (!isCurrentGeneration) {
            return NO;
        }

        if (self.sharing) {
            return YES;
        }

        return includePending && self.startPending;
    }
}

- (void)teardownSharingResourcesEmitStatus:(BOOL)emitStatus {
    id<InterShareVideoSource> videoSource = nil;
    NSArray<id<InterShareSink>> *sinks = nil;
    InterSurfaceShareAudioSampleObserverRegistrationBlock registrationBlock = nil;
    InterShareSessionConfiguration *configurationSnapshot = nil;
    BOOL usedCustomVideoSource = NO;

    @synchronized(self) {
        if (!self.sharing && !self.startPending && _videoSource == nil && _sinks.count == 0) {
            return;
        }

        self.sharing = NO;
        self.startPending = NO;
        _routingGeneration += 1;
        _activeStatusGeneration = 0;

        videoSource = _videoSource;
        sinks = [_sinks copy];
        registrationBlock = self.audioSampleObserverRegistrationBlock;
        configurationSnapshot = [self.configuration copy];
        usedCustomVideoSource = (_videoSource != nil && _videoSource == self.customVideoSource);

        _videoSource = nil;
        _sinks = @[];
    }

    if (videoSource) {
        [videoSource stop];
        videoSource.frameHandler = nil;
        videoSource.errorHandler = nil;
        videoSource.audioSampleBufferHandler = nil;
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
        if (usedCustomVideoSource && configurationSnapshot.sessionKind == InterShareSessionKindInterview) {
            [self emitStatusText:@"Secure tool share is off."];
            return;
        }

        [self emitStatusText:@"Secure surface share is off."];
    });
}

- (NSString *)activeStatusTextForConfiguration:(InterShareSessionConfiguration *)configuration {
    if (configuration.sessionKind == InterShareSessionKindInterview && self.customVideoSource) {
        return @"Secure tool share is active.";
    }

    NSString *sourceLabel = [self sourceLabelForShareMode:configuration.shareMode];
    return [NSString stringWithFormat:@"%@ share is active.", sourceLabel];
}

- (NSString *)startingStatusTextForConfiguration:(InterShareSessionConfiguration *)configuration {
    if (configuration.sessionKind == InterShareSessionKindInterview && self.customVideoSource) {
        return @"Starting secure tool share.";
    }

    NSString *sourceLabel = [self sourceLabelForShareMode:configuration.shareMode];
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
