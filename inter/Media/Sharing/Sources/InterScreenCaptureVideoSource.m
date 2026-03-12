#import "InterScreenCaptureVideoSource.h"

#import <CoreGraphics/CoreGraphics.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <os/lock.h>
#import <stdlib.h>

#import "InterShareTypes.h"

typedef NS_ENUM(NSUInteger, InterScreenCaptureSelectionMode) {
    InterScreenCaptureSelectionModeDisplay = 0,
    InterScreenCaptureSelectionModeWindow
};

@interface InterScreenCaptureVideoSource () <SCStreamDelegate, SCStreamOutput>
@property (atomic, assign, readwrite, getter=isRunning) BOOL running;
@end

@implementation InterScreenCaptureVideoSource {
    dispatch_queue_t _controlQueue;
    dispatch_queue_t _sampleQueue;
    os_unfair_lock _stateLock;

    uint64_t _generation;
    BOOL _starting;
    SCStream *_stream;
    CMTime _lastEmittedPresentationTime;
    BOOL _hasLastEmittedPresentationTime;

    NSArray<NSString *> *_cachedDisplayIdentifiers;
    NSArray<NSString *> *_cachedWindowIdentifiers;

    /// State for waiting on permission grant after user is sent to System Settings.
    BOOL _waitingForPermissionGrant;
    InterScreenCaptureSelectionMode _pendingSelectionMode;
    uint64_t _pendingGeneration;
    id _appDidBecomeActiveObserver;
}

@synthesize frameHandler = _frameHandler;
@synthesize errorHandler = _errorHandler;

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    _controlQueue = dispatch_queue_create("secure.inter.share.source.screencapture.control",
                                          DISPATCH_QUEUE_SERIAL);
    _sampleQueue = dispatch_queue_create("secure.inter.share.source.screencapture.samples",
                                         DISPATCH_QUEUE_SERIAL);
    _stateLock = OS_UNFAIR_LOCK_INIT;
    _generation = 0;
    _starting = NO;
    _running = NO;
    _stream = nil;
    _lastEmittedPresentationTime = kCMTimeInvalid;
    _hasLastEmittedPresentationTime = NO;
    _cachedDisplayIdentifiers = @[];
    _cachedWindowIdentifiers = @[];
    _waitingForPermissionGrant = NO;
    _pendingGeneration = 0;
    _appDidBecomeActiveObserver = nil;
    return self;
}

- (void)dealloc {
    if (_appDidBecomeActiveObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_appDidBecomeActiveObserver];
        _appDidBecomeActiveObserver = nil;
    }
}

+ (BOOL)preflightScreenCaptureAccess {
    return CGPreflightScreenCaptureAccess();
}

+ (BOOL)requestScreenCaptureAccessIfNeeded {
    if ([self preflightScreenCaptureAccess]) {
        return YES;
    }

    return CGRequestScreenCaptureAccess();
}

- (NSArray<NSString *> *)availableDisplayIdentifiers {
    os_unfair_lock_lock(&_stateLock);
    NSArray<NSString *> *identifiers = [_cachedDisplayIdentifiers copy];
    os_unfair_lock_unlock(&_stateLock);
    return identifiers;
}

- (NSArray<NSString *> *)availableWindowIdentifiers {
    os_unfair_lock_lock(&_stateLock);
    NSArray<NSString *> *identifiers = [_cachedWindowIdentifiers copy];
    os_unfair_lock_unlock(&_stateLock);
    return identifiers;
}

- (void)start {
    [self startCaptureForSelectedDisplay];
}

- (void)startCaptureForSelectedDisplay {
    [self startCaptureWithSelectionMode:InterScreenCaptureSelectionModeDisplay];
}

- (void)startCaptureForSelectedWindow {
    [self startCaptureWithSelectionMode:InterScreenCaptureSelectionModeWindow];
}

- (void)startCaptureWithSelectionMode:(InterScreenCaptureSelectionMode)selectionMode {
    dispatch_async(_controlQueue, ^{
        uint64_t generation = 0;
        os_unfair_lock_lock(&self->_stateLock);
        if (self.running || self->_starting) {
            os_unfair_lock_unlock(&self->_stateLock);
            return;
        }

        self->_starting = YES;
        self->_generation += 1;
        self->_lastEmittedPresentationTime = kCMTimeInvalid;
        self->_hasLastEmittedPresentationTime = NO;
        generation = self->_generation;
        os_unfair_lock_unlock(&self->_stateLock);

        if (@available(macOS 13.0, *)) {
            BOOL hasScreenCaptureAccess = [InterScreenCaptureVideoSource preflightScreenCaptureAccess];
            if (!hasScreenCaptureAccess) {
                // CGRequestScreenCaptureAccess() opens System Settings and returns NO
                // immediately — it does NOT block until the user grants permission.
                // Instead of failing right away, we observe app-became-active to
                // re-check permission when the user returns from Settings.
                (void)[InterScreenCaptureVideoSource requestScreenCaptureAccessIfNeeded];

                // Re-check immediately in case permission was already cached
                hasScreenCaptureAccess = [InterScreenCaptureVideoSource preflightScreenCaptureAccess];
                if (!hasScreenCaptureAccess) {
                    // Permission not yet granted — wait for user to come back from Settings
                    [self waitForPermissionGrantWithSelectionMode:selectionMode generation:generation];
                    return;
                }
            }

            [SCShareableContent getShareableContentExcludingDesktopWindows:YES
                                                      onScreenWindowsOnly:YES
                                                         completionHandler:^(SCShareableContent * _Nullable content,
                                                                             NSError * _Nullable error) {
                dispatch_async(self->_controlQueue, ^{
                    [self handleShareableContent:content
                                           error:error
                                   selectionMode:selectionMode
                                      generation:generation];
                });
            }];
            return;
        }

        [self failStartForGeneration:generation
                                code:InterShareErrorCodeUnsupportedMode
                         description:@"Screen capture requires macOS 13 or later."
                     underlyingError:nil];
    });
}

- (void)stop {
    dispatch_async(_controlQueue, ^{
        // Cancel any pending permission wait
        [self cancelPermissionWait];

        SCStream *streamToStop = nil;

        os_unfair_lock_lock(&self->_stateLock);
        BOOL hadState = self.running || self->_starting || self->_stream != nil;
        if (!hadState) {
            os_unfair_lock_unlock(&self->_stateLock);
            return;
        }

        self->_generation += 1;
        self.running = NO;
        self->_starting = NO;
        self->_lastEmittedPresentationTime = kCMTimeInvalid;
        self->_hasLastEmittedPresentationTime = NO;
        streamToStop = self->_stream;
        self->_stream = nil;
        os_unfair_lock_unlock(&self->_stateLock);

        [self stopStream:streamToStop];
    });
}

#pragma mark - Permission Wait

/// When CGRequestScreenCaptureAccess() sends the user to System Settings, this
/// method registers an observer for NSApplicationDidBecomeActiveNotification.
/// When the user returns, we re-check permission and either proceed or fail.
- (void)waitForPermissionGrantWithSelectionMode:(InterScreenCaptureSelectionMode)selectionMode
                                     generation:(uint64_t)generation {
    os_unfair_lock_lock(&_stateLock);
    _waitingForPermissionGrant = YES;
    _pendingSelectionMode = selectionMode;
    _pendingGeneration = generation;
    os_unfair_lock_unlock(&_stateLock);

    __weak typeof(self) weakSelf = self;
    _appDidBecomeActiveObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
#pragma unused(note)
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            dispatch_async(strongSelf->_controlQueue, ^{
                [strongSelf handleReturnFromSettingsForGeneration:generation
                                                   selectionMode:selectionMode];
            });
        }];
}

- (void)handleReturnFromSettingsForGeneration:(uint64_t)generation
                                selectionMode:(InterScreenCaptureSelectionMode)selectionMode {
    [self cancelPermissionWait];

    // Check the generation is still current
    os_unfair_lock_lock(&_stateLock);
    BOOL isCurrent = (_starting && _generation == generation);
    os_unfair_lock_unlock(&_stateLock);
    if (!isCurrent) return;

    BOOL hasAccess = [InterScreenCaptureVideoSource preflightScreenCaptureAccess];
    if (!hasAccess) {
        [self failStartForGeneration:generation
                                code:InterShareErrorCodeInvalidConfiguration
                         description:@"Screen recording permission is required. Enable it in System Settings > Privacy & Security."
                     underlyingError:nil];
        return;
    }

    // Permission granted — continue the normal capture start flow
    if (@available(macOS 13.0, *)) {
        [SCShareableContent getShareableContentExcludingDesktopWindows:YES
                                                  onScreenWindowsOnly:YES
                                                     completionHandler:^(SCShareableContent * _Nullable content,
                                                                         NSError * _Nullable error) {
            dispatch_async(self->_controlQueue, ^{
                [self handleShareableContent:content
                                       error:error
                               selectionMode:selectionMode
                                  generation:generation];
            });
        }];
    }
}

- (void)cancelPermissionWait {
    os_unfair_lock_lock(&_stateLock);
    _waitingForPermissionGrant = NO;
    os_unfair_lock_unlock(&_stateLock);

    if (_appDidBecomeActiveObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_appDidBecomeActiveObserver];
        _appDidBecomeActiveObserver = nil;
    }
}

#pragma mark - Internal

- (void)handleShareableContent:(SCShareableContent *)content
                         error:(NSError *)error
                 selectionMode:(InterScreenCaptureSelectionMode)selectionMode
                    generation:(uint64_t)generation API_AVAILABLE(macos(13.0)) {
    if (![self isStartGenerationActive:generation]) {
        return;
    }

    if (!content || error) {
        [self failStartForGeneration:generation
                                code:InterShareErrorCodeInvalidConfiguration
                         description:@"Unable to enumerate shareable displays/windows."
                     underlyingError:error];
        return;
    }

    [self updateCachedIdentifiersFromContent:content];

    NSError *filterError = nil;
    SCContentFilter *filter = [self contentFilterForSelectionMode:selectionMode
                                                           content:content
                                                             error:&filterError];
    if (!filter) {
        [self failStartForGeneration:generation
                                code:InterShareErrorCodeInvalidConfiguration
                         description:@"No valid share target is available."
                     underlyingError:filterError];
        return;
    }

    SCStreamConfiguration *configuration = [self streamConfigurationForSelectionMode:selectionMode
                                                                              content:content
                                                                               filter:filter];
    SCStream *stream = [[SCStream alloc] initWithFilter:filter
                                          configuration:configuration
                                               delegate:self];
    if (!stream) {
        [self failStartForGeneration:generation
                                code:InterShareErrorCodeInvalidConfiguration
                         description:@"Unable to create a screen capture stream."
                     underlyingError:nil];
        return;
    }

    NSError *outputError = nil;
    BOOL outputAdded = [stream addStreamOutput:self
                                          type:SCStreamOutputTypeScreen
                             sampleHandlerQueue:_sampleQueue
                                          error:&outputError];
    if (!outputAdded) {
        [self failStartForGeneration:generation
                                code:InterShareErrorCodeInvalidConfiguration
                         description:@"Unable to add the screen output to the capture stream."
                     underlyingError:outputError];
        return;
    }

    os_unfair_lock_lock(&_stateLock);
    BOOL generationStillActive = (_starting && _generation == generation);
    if (generationStillActive) {
        _stream = stream;
    }
    os_unfair_lock_unlock(&_stateLock);

    if (!generationStillActive) {
        [self stopStream:stream];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [stream startCaptureWithCompletionHandler:^(NSError * _Nullable startError) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        dispatch_async(strongSelf->_controlQueue, ^{
            if (startError) {
                [strongSelf failStartForGeneration:generation
                                              code:InterShareErrorCodeInvalidConfiguration
                                       description:@"Failed to start screen capture."
                                   underlyingError:startError];
                return;
            }

            os_unfair_lock_lock(&strongSelf->_stateLock);
            BOOL isCurrent = (strongSelf->_generation == generation &&
                              strongSelf->_starting &&
                              strongSelf->_stream == stream);
            if (isCurrent) {
                strongSelf->_starting = NO;
                strongSelf.running = YES;
            }
            os_unfair_lock_unlock(&strongSelf->_stateLock);

            if (!isCurrent) {
                [strongSelf stopStream:stream];
            }
        });
    }];
}

- (SCContentFilter *)contentFilterForSelectionMode:(InterScreenCaptureSelectionMode)selectionMode
                                           content:(SCShareableContent *)content
                                             error:(NSError * _Nullable __autoreleasing *)error API_AVAILABLE(macos(13.0)) {
    if (selectionMode == InterScreenCaptureSelectionModeWindow) {
        SCWindow *window = [self selectedWindowFromContent:content];
        if (!window) {
            if (error) {
                *error = [NSError errorWithDomain:InterShareErrorDomain
                                              code:InterShareErrorCodeInvalidConfiguration
                                          userInfo:@{NSLocalizedDescriptionKey: @"No shareable window was found."}];
            }
            return nil;
        }
        return [[SCContentFilter alloc] initWithDesktopIndependentWindow:window];
    }

    SCDisplay *display = [self selectedDisplayFromContent:content];
    if (!display) {
        if (error) {
            *error = [NSError errorWithDomain:InterShareErrorDomain
                                          code:InterShareErrorCodeInvalidConfiguration
                                      userInfo:@{NSLocalizedDescriptionKey: @"No shareable display was found."}];
        }
        return nil;
    }

    NSArray<SCRunningApplication *> *excludedApplications = [self ownRunningApplicationsFromContent:content];
    if (excludedApplications.count > 0) {
        return [[SCContentFilter alloc] initWithDisplay:display
                                  excludingApplications:excludedApplications
                                       exceptingWindows:@[]];
    }

    return [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
}

- (SCStreamConfiguration *)streamConfigurationForSelectionMode:(InterScreenCaptureSelectionMode)selectionMode
                                                        content:(SCShareableContent *)content
                                                         filter:(SCContentFilter *)filter API_AVAILABLE(macos(13.0)) {
#pragma unused(filter)
    SCStreamConfiguration *configuration = [[SCStreamConfiguration alloc] init];
    configuration.pixelFormat = kCVPixelFormatType_32BGRA;
    configuration.minimumFrameInterval = CMTimeMake(1, 30);
    configuration.queueDepth = 3;
    configuration.showsCursor = YES;
    configuration.capturesAudio = NO;

    size_t width = 0;
    size_t height = 0;
    if (selectionMode == InterScreenCaptureSelectionModeWindow) {
        SCWindow *window = [self selectedWindowFromContent:content];
        if (window) {
            CGRect frame = window.frame;
            width = (size_t)MAX(1.0, CGRectGetWidth(frame));
            height = (size_t)MAX(1.0, CGRectGetHeight(frame));
        }
    } else {
        SCDisplay *display = [self selectedDisplayFromContent:content];
        if (display) {
            CGRect bounds = CGDisplayBounds(display.displayID);
            width = (size_t)MAX(1.0, CGRectGetWidth(bounds));
            height = (size_t)MAX(1.0, CGRectGetHeight(bounds));
        }
    }

    if (width == 0 || height == 0) {
        width = 1920;
        height = 1080;
    }

    configuration.width = width;
    configuration.height = height;
    return configuration;
}

- (SCDisplay *)selectedDisplayFromContent:(SCShareableContent *)content API_AVAILABLE(macos(13.0)) {
    if (content.displays.count == 0) {
        return nil;
    }

    CGDirectDisplayID selectedDisplayID = 0;
    if (self.selectedDisplayIdentifier.length > 0) {
        selectedDisplayID = (CGDirectDisplayID)strtoul(self.selectedDisplayIdentifier.UTF8String, NULL, 10);
    }

    CGDirectDisplayID preferredDisplayID = selectedDisplayID != 0 ? selectedDisplayID : CGMainDisplayID();
    for (SCDisplay *display in content.displays) {
        if (display.displayID == preferredDisplayID) {
            return display;
        }
    }

    return content.displays.firstObject;
}

- (SCWindow *)selectedWindowFromContent:(SCShareableContent *)content API_AVAILABLE(macos(13.0)) {
    if (content.windows.count == 0) {
        return nil;
    }

    CGWindowID selectedWindowID = 0;
    if (self.selectedWindowIdentifier.length > 0) {
        selectedWindowID = (CGWindowID)strtoul(self.selectedWindowIdentifier.UTF8String, NULL, 10);
    }

    NSMutableArray<SCWindow *> *candidates = [NSMutableArray array];
    for (SCWindow *window in content.windows) {
        if (!window.isOnScreen || window.windowLayer != 0) {
            continue;
        }

        [candidates addObject:window];
    }
    if (candidates.count == 0) {
        [candidates addObjectsFromArray:content.windows];
    }

    if (selectedWindowID != 0) {
        for (SCWindow *window in candidates) {
            if (window.windowID == selectedWindowID) {
                return window;
            }
        }
    }

    NSString *ourBundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    for (SCWindow *window in candidates) {
        NSString *ownerBundleIdentifier = window.owningApplication.bundleIdentifier;
        if (ourBundleIdentifier.length > 0 &&
            ownerBundleIdentifier.length > 0 &&
            [ownerBundleIdentifier isEqualToString:ourBundleIdentifier]) {
            continue;
        }
        return window;
    }

    return candidates.firstObject;
}

- (void)updateCachedIdentifiersFromContent:(SCShareableContent *)content API_AVAILABLE(macos(13.0)) {
    NSMutableArray<NSString *> *displayIdentifiers = [NSMutableArray arrayWithCapacity:content.displays.count];
    for (SCDisplay *display in content.displays) {
        [displayIdentifiers addObject:[NSString stringWithFormat:@"%u", display.displayID]];
    }

    NSMutableArray<NSString *> *windowIdentifiers = [NSMutableArray arrayWithCapacity:content.windows.count];
    for (SCWindow *window in content.windows) {
        [windowIdentifiers addObject:[NSString stringWithFormat:@"%u", window.windowID]];
    }

    os_unfair_lock_lock(&_stateLock);
    _cachedDisplayIdentifiers = [displayIdentifiers copy];
    _cachedWindowIdentifiers = [windowIdentifiers copy];
    os_unfair_lock_unlock(&_stateLock);
}

- (NSArray<SCRunningApplication *> *)ownRunningApplicationsFromContent:(SCShareableContent *)content API_AVAILABLE(macos(13.0)) {
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    if (bundleIdentifier.length == 0) {
        return @[];
    }

    pid_t currentPID = [NSProcessInfo processInfo].processIdentifier;
    NSMutableArray<SCRunningApplication *> *ownedApplications = [NSMutableArray array];
    for (SCRunningApplication *application in content.applications) {
        if ([application.bundleIdentifier isEqualToString:bundleIdentifier] ||
            application.processID == currentPID) {
            [ownedApplications addObject:application];
        }
    }

    return [ownedApplications copy];
}

- (BOOL)isStartGenerationActive:(uint64_t)generation {
    os_unfair_lock_lock(&_stateLock);
    BOOL active = (_starting && _generation == generation);
    os_unfair_lock_unlock(&_stateLock);
    return active;
}

- (void)failStartForGeneration:(uint64_t)generation
                          code:(InterShareErrorCode)code
                   description:(NSString *)description
               underlyingError:(NSError * _Nullable)underlyingError {
    SCStream *streamToStop = nil;
    BOOL shouldNotify = NO;

    os_unfair_lock_lock(&_stateLock);
    BOOL isCurrent = (_generation == generation);
    if (isCurrent) {
        streamToStop = _stream;
        _stream = nil;
        _starting = NO;
        self.running = NO;
        _lastEmittedPresentationTime = kCMTimeInvalid;
        _hasLastEmittedPresentationTime = NO;
        shouldNotify = YES;
    }
    os_unfair_lock_unlock(&_stateLock);

    if (streamToStop) {
        [self stopStream:streamToStop];
    }

    if (!shouldNotify) {
        return;
    }

    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    if (description.length > 0) {
        userInfo[NSLocalizedDescriptionKey] = description;
    }
    if (underlyingError) {
        userInfo[NSUnderlyingErrorKey] = underlyingError;
    }

    NSError *error = [NSError errorWithDomain:InterShareErrorDomain
                                         code:code
                                     userInfo:userInfo];
    InterShareVideoSourceErrorHandler errorHandler = self.errorHandler;
    if (errorHandler) {
        errorHandler(error);
    }
}

- (void)stopStream:(SCStream *)stream API_AVAILABLE(macos(13.0)) {
    if (!stream) {
        return;
    }

    NSError *removeError = nil;
    [stream removeStreamOutput:self type:SCStreamOutputTypeScreen error:&removeError];
#pragma unused(removeError)
    [stream stopCaptureWithCompletionHandler:^(__unused NSError * _Nullable stopError) {
    }];
}

- (BOOL)isCompleteFrameSampleBuffer:(CMSampleBufferRef)sampleBuffer API_AVAILABLE(macos(13.0)) {
    CFArrayRef attachmentArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (!attachmentArray || CFArrayGetCount(attachmentArray) == 0) {
        return YES;
    }

    CFDictionaryRef firstAttachment = CFArrayGetValueAtIndex(attachmentArray, 0);
    if (!firstAttachment) {
        return YES;
    }

    CFTypeRef statusValue = CFDictionaryGetValue(firstAttachment,
                                                 (__bridge const void *)SCStreamFrameInfoStatus);
    if (!statusValue || CFGetTypeID(statusValue) != CFNumberGetTypeID()) {
        return YES;
    }

    SCFrameStatus frameStatus = (SCFrameStatus)[(__bridge NSNumber *)statusValue integerValue];
    return frameStatus == SCFrameStatusComplete;
}

#pragma mark - SCStreamDelegate

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error API_AVAILABLE(macos(13.0)) {
    dispatch_async(_controlQueue, ^{
        BOOL shouldNotify = NO;
        os_unfair_lock_lock(&self->_stateLock);
        if (self->_stream == stream) {
            self->_stream = nil;
            self->_starting = NO;
            self.running = NO;
            self->_generation += 1;
            self->_lastEmittedPresentationTime = kCMTimeInvalid;
            self->_hasLastEmittedPresentationTime = NO;
            shouldNotify = YES;
        }
        os_unfair_lock_unlock(&self->_stateLock);

        if (shouldNotify && error) {
            InterShareVideoSourceErrorHandler errorHandler = self.errorHandler;
            if (errorHandler) {
                NSError *wrappedError = [NSError errorWithDomain:InterShareErrorDomain
                                                             code:InterShareErrorCodeInvalidConfiguration
                                                         userInfo:@{
                    NSLocalizedDescriptionKey: @"Screen capture stopped unexpectedly.",
                    NSUnderlyingErrorKey: error
                }];
                errorHandler(wrappedError);
            }
        }
    });
}

#pragma mark - SCStreamOutput

- (void)stream:(SCStream *)stream
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
        ofType:(SCStreamOutputType)type API_AVAILABLE(macos(13.0)) {
    if (type != SCStreamOutputTypeScreen || !sampleBuffer) {
        return;
    }

    os_unfair_lock_lock(&_stateLock);
    BOOL shouldProcess = (self.running && _stream == stream);
    os_unfair_lock_unlock(&_stateLock);
    if (!shouldProcess) {
        return;
    }

    if (!CMSampleBufferIsValid(sampleBuffer) ||
        !CMSampleBufferDataIsReady(sampleBuffer) ||
        ![self isCompleteFrameSampleBuffer:sampleBuffer]) {
        return;
    }

    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) {
        return;
    }

    CMTime presentationTime = CMClockGetTime(CMClockGetHostTimeClock());
    os_unfair_lock_lock(&_stateLock);
    if (_hasLastEmittedPresentationTime &&
        CMTIME_COMPARE_INLINE(presentationTime, <=, _lastEmittedPresentationTime)) {
        presentationTime = CMTimeAdd(_lastEmittedPresentationTime, CMTimeMake(1, 1000));
    }
    _lastEmittedPresentationTime = presentationTime;
    _hasLastEmittedPresentationTime = YES;
    os_unfair_lock_unlock(&_stateLock);

    InterShareVideoFrame *frame = [[InterShareVideoFrame alloc] initWithPixelBuffer:pixelBuffer
                                                                    presentationTime:presentationTime];
    InterShareVideoSourceFrameHandler frameHandler = self.frameHandler;
    if (frameHandler) {
        frameHandler(frame);
    }
}

@end
