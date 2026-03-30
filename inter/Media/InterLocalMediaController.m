#import "InterLocalMediaController.h"

@interface InterLocalMediaController () <AVCaptureAudioDataOutputSampleBufferDelegate>
@property (atomic, assign, readwrite, getter=isConfigured) BOOL configured;
@property (atomic, assign, readwrite, getter=isRunning) BOOL running;
@property (atomic, assign, readwrite, getter=isCameraEnabled) BOOL cameraEnabled;
@property (atomic, assign, readwrite, getter=isMicrophoneEnabled) BOOL microphoneEnabled;
@property (atomic, assign, getter=isShuttingDown) BOOL shuttingDown;
+ (void)resolveAuthorizationStatusForMediaType:(AVMediaType)mediaType
                                    completion:(void (^)(AVAuthorizationStatus status))completion;
- (nullable AVCaptureDevice *)preferredAudioDevice;
- (BOOL)isLikelyProblematicAudioDevice:(AVCaptureDevice *)device;
- (void)registerDeviceAvailabilityObservers;
- (void)unregisterDeviceAvailabilityObservers;
- (void)handleCaptureDeviceAvailabilityNotification:(NSNotification *)notification;
- (void)notifyAudioInputOptionsChanged;
@end

static const void *InterLocalMediaSessionQueueKey = &InterLocalMediaSessionQueueKey;

@implementation InterLocalMediaController {
    dispatch_queue_t _sessionQueue;
    AVCaptureSession *_session;
    dispatch_queue_t _audioSampleOutputQueue;
    dispatch_queue_t _audioSampleCallbackQueue;
    NSString *_preferredAudioDeviceID;

    AVCaptureDeviceInput *_videoInput;
    AVCaptureDeviceInput *_audioInput;
    AVCaptureAudioDataOutput *_audioDataOutput;

    __weak NSView *_previewHostView;
    AVCaptureVideoPreviewLayer *_previewLayer;
    BOOL _deviceAvailabilityObserversRegistered;
}

+ (void)preflightCapturePermissionsWithCompletion:(void (^ _Nullable)(AVAuthorizationStatus videoStatus,
                                                                       AVAuthorizationStatus audioStatus))completion {
    dispatch_group_t permissionGroup = dispatch_group_create();
    __block AVAuthorizationStatus videoStatus = AVAuthorizationStatusNotDetermined;
    __block AVAuthorizationStatus audioStatus = AVAuthorizationStatusNotDetermined;

    dispatch_group_enter(permissionGroup);
    [self resolveAuthorizationStatusForMediaType:AVMediaTypeVideo completion:^(AVAuthorizationStatus status) {
        videoStatus = status;
        dispatch_group_leave(permissionGroup);
    }];

    dispatch_group_enter(permissionGroup);
    [self resolveAuthorizationStatusForMediaType:AVMediaTypeAudio completion:^(AVAuthorizationStatus status) {
        audioStatus = status;
        dispatch_group_leave(permissionGroup);
    }];

    dispatch_group_notify(permissionGroup, dispatch_get_main_queue(), ^{
        if (completion) {
            completion(videoStatus, audioStatus);
        }
    });
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    _sessionQueue = dispatch_queue_create("secure.inter.media.local.session",
                                          DISPATCH_QUEUE_SERIAL);
    _audioSampleOutputQueue = dispatch_queue_create("secure.inter.media.local.audio.output",
                                                    DISPATCH_QUEUE_SERIAL);
    _audioSampleCallbackQueue = dispatch_queue_create("secure.inter.media.local.audio.callback",
                                                      DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_sessionQueue,
                                InterLocalMediaSessionQueueKey,
                                (void *)InterLocalMediaSessionQueueKey,
                                NULL);
    _session = [[AVCaptureSession alloc] init];
    _configured = NO;
    _running = NO;
    _cameraEnabled = NO;
    _microphoneEnabled = NO;
    _shuttingDown = NO;
    [self registerDeviceAvailabilityObservers];
    return self;
}

- (void)dealloc {
    [self shutdown];
}

#pragma mark - Exposed Session Properties (2.1.1, 2.1.2)

- (AVCaptureSession *)captureSession {
    return _session;
}

- (dispatch_queue_t)sessionQueue {
    return _sessionQueue;
}

- (void)prepareWithCompletion:(InterLocalMediaPrepareCompletion)completion {
    if (!completion) {
        return;
    }

    if (self.isShuttingDown) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(NO, @"Local media is shutting down.");
        });
        return;
    }

    if (self.isConfigured) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(YES, nil);
        });
        return;
    }

    dispatch_group_t permissionGroup = dispatch_group_create();
    __block BOOL videoGranted = NO;
    __block BOOL audioGranted = NO;

    dispatch_group_enter(permissionGroup);
    [self requestAccessForMediaType:AVMediaTypeVideo completion:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            videoGranted = granted;
            dispatch_group_leave(permissionGroup);
        });
    }];

    dispatch_group_enter(permissionGroup);
    [self requestAccessForMediaType:AVMediaTypeAudio completion:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            audioGranted = granted;
            dispatch_group_leave(permissionGroup);
        });
    }];

    __weak typeof(self) weakSelf = self;
    dispatch_group_notify(permissionGroup, dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.isShuttingDown) {
            completion(NO, @"Local media is shutting down.");
            return;
        }

        if (!videoGranted && !audioGranted) {
            completion(NO, @"Camera and microphone access were denied.");
            return;
        }

        dispatch_queue_t queue = strongSelf->_sessionQueue;
        if (!queue) {
            completion(NO, @"Local media queue is unavailable.");
            return;
        }

        dispatch_async(queue, ^{
            __strong typeof(weakSelf) queuedSelf = weakSelf;
            if (!queuedSelf || queuedSelf.isShuttingDown) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(NO, @"Local media is shutting down.");
                });
                return;
            }

            BOOL configured = [queuedSelf configureSessionAllowingVideo:videoGranted
                                                                   audio:audioGranted];

            dispatch_async(dispatch_get_main_queue(), ^{
                if (!configured) {
                    completion(NO, @"Failed to configure local media capture session.");
                    return;
                }

                if (!videoGranted && audioGranted) {
                    completion(YES, @"Camera access denied. Audio-only mode is active.");
                    return;
                }

                if (videoGranted && !audioGranted) {
                    completion(YES, @"Microphone access denied. Video-only mode is active.");
                    return;
                }

                completion(YES, nil);
            });
        });
    });
}

- (void)start {
    dispatch_queue_t queue = _sessionQueue;
    if (!queue || self.isShuttingDown) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(queue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.isShuttingDown) {
            return;
        }

        if (!strongSelf.isConfigured || strongSelf.isRunning || !strongSelf->_session) {
            return;
        }

        [strongSelf->_session startRunning];
        strongSelf.running = strongSelf->_session.isRunning;
        dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf updatePreviewMirroringPolicyOnMainThread];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [strongSelf updatePreviewMirroringPolicyOnMainThread];
        });
    });
}

- (void)stop {
    if (self.isShuttingDown) {
        return;
    }

    dispatch_queue_t queue = _sessionQueue;
    if (!queue) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(queue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.isShuttingDown) {
            return;
        }
        [strongSelf stopSessionLocked];
    });
}

- (void)shutdown {
    if (self.isShuttingDown) {
        return;
    }

    self.shuttingDown = YES;
    [self unregisterDeviceAvailabilityObservers];
    [self detachPreviewSynchronously];

    // Perform heavy AVCaptureSession teardown OFF the main thread so the UI
    // can dismiss immediately. dispatch_async avoids the 200-500ms main-thread
    // stall that [AVCaptureSession stopRunning] causes.
    dispatch_queue_t queue = _sessionQueue;
    if (!queue) {
        // No session queue — nothing to tear down.
        self.cameraEnabled = NO;
        self.microphoneEnabled = NO;
        self.configured = NO;
        return;
    }

    dispatch_async(queue, ^{
        [self stopSessionLocked];

        if (!self->_session) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.cameraEnabled = NO;
                self.microphoneEnabled = NO;
                self.configured = NO;
            });
            return;
        }

        [self->_session beginConfiguration];
        if (self->_videoInput) {
            [self->_session removeInput:self->_videoInput];
            self->_videoInput = nil;
        }
        if (self->_audioInput) {
            [self->_session removeInput:self->_audioInput];
            self->_audioInput = nil;
        }
        [self removeAudioDataOutputLocked];
        [self->_session commitConfiguration];

        self->_session = nil;

        dispatch_async(dispatch_get_main_queue(), ^{
            self.cameraEnabled = NO;
            self.microphoneEnabled = NO;
            self.configured = NO;
            self.audioSampleBufferHandler = nil;
        });
    });
}

- (void)setCameraEnabled:(BOOL)enabled completion:(void (^ _Nullable)(BOOL success))completion {
    if (self.isShuttingDown) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO);
            });
        }
        return;
    }

    dispatch_queue_t queue = _sessionQueue;
    if (!queue) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO);
            });
        }
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(queue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.isShuttingDown || !strongSelf->_session) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(NO);
                }
            });
            return;
        }

        BOOL success = [strongSelf setVideoInputEnabledLocked:enabled];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(success);
            }
        });
    });
}

- (void)setMicrophoneEnabled:(BOOL)enabled completion:(void (^ _Nullable)(BOOL success))completion {
    if (self.isShuttingDown) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO);
            });
        }
        return;
    }

    dispatch_queue_t queue = _sessionQueue;
    if (!queue) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO);
            });
        }
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(queue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.isShuttingDown || !strongSelf->_session) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(NO);
                }
            });
            return;
        }

        BOOL success = [strongSelf setAudioInputEnabledLocked:enabled];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(success);
            }
        });
    });
}

- (NSArray<NSDictionary<NSString *,NSString *> *> *)availableAudioInputOptions {
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *options = [NSMutableArray array];
    AVCaptureDeviceDiscoverySession *discoverySession =
    [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeMicrophone]
                                                          mediaType:AVMediaTypeAudio
                                                           position:AVCaptureDevicePositionUnspecified];

    for (AVCaptureDevice *device in discoverySession.devices) {
        if ([self isLikelyProblematicAudioDevice:device]) {
            continue;
        }

        if (device.uniqueID.length == 0 || device.localizedName.length == 0) {
            continue;
        }
        [options addObject:@{
            @"id": device.uniqueID,
            @"name": device.localizedName
        }];
    }
    return [options copy];
}

- (nullable NSString *)selectedAudioInputDeviceID {
    __block NSString *selectedDeviceID = nil;
    [self performSynchronouslyOnSessionQueue:^{
        if (self->_preferredAudioDeviceID.length > 0) {
            AVCaptureDevice *preferredDevice = [AVCaptureDevice deviceWithUniqueID:self->_preferredAudioDeviceID];
            if (preferredDevice && ![self isLikelyProblematicAudioDevice:preferredDevice]) {
                selectedDeviceID = self->_preferredAudioDeviceID;
                return;
            }
        }

        if (self->_audioInput.device.uniqueID.length > 0 && ![self isLikelyProblematicAudioDevice:self->_audioInput.device]) {
            selectedDeviceID = self->_audioInput.device.uniqueID;
            return;
        }

        AVCaptureDevice *preferredDefault = [self preferredAudioDevice];
        if (preferredDefault.uniqueID.length > 0) {
            selectedDeviceID = preferredDefault.uniqueID;
            return;
        }

        AVCaptureDevice *defaultDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
        if (defaultDevice.uniqueID.length > 0 && ![self isLikelyProblematicAudioDevice:defaultDevice]) {
            selectedDeviceID = defaultDevice.uniqueID;
        }
    }];
    return selectedDeviceID;
}

- (void)selectAudioInputDeviceWithID:(nullable NSString *)deviceID
                          completion:(void (^ _Nullable)(BOOL success))completion {
    dispatch_queue_t queue = _sessionQueue;
    if (!queue || self.isShuttingDown) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO);
            });
        }
        return;
    }

    NSString *normalizedID = deviceID.length > 0 ? [deviceID copy] : nil;
    if (normalizedID.length > 0) {
        AVCaptureDevice *requestedDevice = [AVCaptureDevice deviceWithUniqueID:normalizedID];
        if (!requestedDevice || [self isLikelyProblematicAudioDevice:requestedDevice]) {
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(NO);
                });
            }
            return;
        }
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(queue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.isShuttingDown || !strongSelf->_session) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(NO);
                }
            });
            return;
        }

        strongSelf->_preferredAudioDeviceID = normalizedID;
        BOOL shouldKeepMicEnabled = strongSelf.isMicrophoneEnabled;

        if (strongSelf->_audioInput) {
            [strongSelf->_session beginConfiguration];
            [strongSelf removeAudioDataOutputLocked];
            [strongSelf->_session removeInput:strongSelf->_audioInput];
            [strongSelf->_session commitConfiguration];
            strongSelf->_audioInput = nil;
        }

        BOOL success = YES;
        if (shouldKeepMicEnabled) {
            success = [strongSelf setAudioInputEnabledLocked:YES];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(success);
            }
        });
    });
}

- (void)storePreferredAudioDeviceID:(nullable NSString *)deviceID {
    dispatch_queue_t queue = _sessionQueue;
    if (!queue || self.isShuttingDown) {
        return;
    }
    NSString *normalizedID = deviceID.length > 0 ? [deviceID copy] : nil;
    dispatch_async(queue, ^{
        self->_preferredAudioDeviceID = normalizedID;
    });
}

- (void)attachPreviewToView:(NSView *)view {
    if (!view) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [view setWantsLayer:YES];

        if (!self->_previewLayer) {
            self->_previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:self->_session];
            self->_previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
            self->_previewLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
        }

        [self->_previewLayer removeFromSuperlayer];
        self->_previewLayer.frame = view.bounds;
        [view.layer addSublayer:self->_previewLayer];
        [self updatePreviewMirroringPolicyOnMainThread];
        self->_previewHostView = view;
    });
}

- (void)detachPreview {
    [self detachPreviewSynchronously];
}

#pragma mark - Internal

+ (void)resolveAuthorizationStatusForMediaType:(AVMediaType)mediaType
                                    completion:(void (^)(AVAuthorizationStatus status))completion {
    if (!completion) {
        return;
    }

    AVAuthorizationStatus currentStatus = [AVCaptureDevice authorizationStatusForMediaType:mediaType];
    if (currentStatus != AVAuthorizationStatusNotDetermined) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(currentStatus);
        });
        return;
    }

    [AVCaptureDevice requestAccessForMediaType:mediaType completionHandler:^(__unused BOOL granted) {
        AVAuthorizationStatus updatedStatus = [AVCaptureDevice authorizationStatusForMediaType:mediaType];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(updatedStatus);
        });
    }];
}

- (void)stopSynchronously {
    [self performSynchronouslyOnSessionQueue:^{
        [self stopSessionLocked];
    }];
}

- (void)stopSessionLocked {
    if (!self->_session || !self.isRunning) {
        self.running = NO;
        return;
    }

    [self->_session stopRunning];
    self.running = NO;
}

- (void)detachPreviewSynchronously {
    if ([NSThread isMainThread]) {
        [self->_previewLayer removeFromSuperlayer];
        self->_previewHostView = nil;
        return;
    }

    dispatch_sync(dispatch_get_main_queue(), ^{
        [self->_previewLayer removeFromSuperlayer];
        self->_previewHostView = nil;
    });
}

- (void)performSynchronouslyOnSessionQueue:(dispatch_block_t)block {
    if (!block) {
        return;
    }

    if (!_sessionQueue) {
        block();
        return;
    }

    if (dispatch_get_specific(InterLocalMediaSessionQueueKey) == InterLocalMediaSessionQueueKey) {
        block();
        return;
    }

    dispatch_sync(_sessionQueue, block);
}

- (void)requestAccessForMediaType:(AVMediaType)mediaType completion:(void (^)(BOOL granted))completion {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:mediaType];
    switch (status) {
        case AVAuthorizationStatusAuthorized:
            completion(YES);
            return;
        case AVAuthorizationStatusDenied:
        case AVAuthorizationStatusRestricted:
            completion(NO);
            return;
        case AVAuthorizationStatusNotDetermined: {
            [AVCaptureDevice requestAccessForMediaType:mediaType completionHandler:^(BOOL granted) {
                completion(granted);
            }];
            return;
        }
    }
}

- (BOOL)configureSessionAllowingVideo:(BOOL)allowVideo audio:(BOOL)allowAudio {
    if (self.isShuttingDown || !_session) {
        return NO;
    }

    if (self.isConfigured) {
        return YES;
    }

    [_session beginConfiguration];

    if ([_session canSetSessionPreset:AVCaptureSessionPreset1280x720]) {
        _session.sessionPreset = AVCaptureSessionPreset1280x720;
    }

    BOOL addedAnyInput = NO;
    if (allowVideo) {
        addedAnyInput |= [self setVideoInputEnabledLocked:YES];
    }
    if (allowAudio) {
        addedAnyInput |= [self setAudioInputEnabledLocked:YES];
        if (self.isMicrophoneEnabled) {
            [self ensureAudioDataOutputLocked];
        }
    }

    [_session commitConfiguration];

    self.configured = addedAnyInput;
    return addedAnyInput;
}

- (BOOL)setVideoInputEnabledLocked:(BOOL)enabled {
    if (self.isShuttingDown || !_session) {
        self.cameraEnabled = NO;
        return NO;
    }

    if (enabled) {
        if (_videoInput != nil) {
            self.cameraEnabled = YES;
            return YES;
        }

        AVCaptureDevice *videoDevice = [self preferredVideoDevice];
        if (!videoDevice) {
            self.cameraEnabled = NO;
            return NO;
        }

        NSError *error = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice
                                                                             error:&error];
        if (!input || error) {
            self.cameraEnabled = NO;
            return NO;
        }

        [_session beginConfiguration];
        BOOL canAdd = [_session canAddInput:input];
        if (canAdd) {
            [_session addInput:input];
            _videoInput = input;
        }
        [_session commitConfiguration];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updatePreviewMirroringPolicyOnMainThread];
        });

        self.cameraEnabled = canAdd;
        return canAdd;
    }

    if (_videoInput != nil) {
        [_session beginConfiguration];
        [_session removeInput:_videoInput];
        [_session commitConfiguration];
        _videoInput = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updatePreviewMirroringPolicyOnMainThread];
        });
    }

    self.cameraEnabled = NO;
    return YES;
}

- (void)updatePreviewMirroringPolicyOnMainThread {
    if (!self->_previewLayer) {
        return;
    }

    AVCaptureDevicePosition cameraPosition = AVCaptureDevicePositionUnspecified;
    if (self->_videoInput.device) {
        cameraPosition = self->_videoInput.device.position;
    }

    BOOL shouldFlipDisplay = (cameraPosition != AVCaptureDevicePositionBack);

    // UI-only fix: leave capture stream behavior unchanged and flip only displayed preview.
    if (shouldFlipDisplay) {
        self->_previewLayer.affineTransform = CGAffineTransformMakeScale(-1.0, 1.0);
    } else {
        self->_previewLayer.affineTransform = CGAffineTransformIdentity;
    }
}

- (BOOL)setAudioInputEnabledLocked:(BOOL)enabled {
    if (self.isShuttingDown || !_session) {
        self.microphoneEnabled = NO;
        return NO;
    }

    if (enabled) {
        if (_audioInput != nil) {
            self.microphoneEnabled = YES;
            return YES;
        }

        AVCaptureDevice *audioDevice = nil;
        if (_preferredAudioDeviceID.length > 0) {
            AVCaptureDevice *candidate = [AVCaptureDevice deviceWithUniqueID:_preferredAudioDeviceID];
            if (candidate && ![self isLikelyProblematicAudioDevice:candidate]) {
                audioDevice = candidate;
            }
        }
        if (!audioDevice) {
            audioDevice = [self preferredAudioDevice];
        }
        if (!audioDevice) {
            self.microphoneEnabled = NO;
            return NO;
        }

        NSError *error = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:audioDevice
                                                                             error:&error];
        if (!input || error) {
            self.microphoneEnabled = NO;
            return NO;
        }

        [_session beginConfiguration];
        BOOL canAdd = [_session canAddInput:input];
        if (canAdd) {
            [_session addInput:input];
            _audioInput = input;
            [self ensureAudioDataOutputLocked];
        }
        [_session commitConfiguration];

        self.microphoneEnabled = canAdd;
        return canAdd;
    }

    if (_audioInput != nil) {
        [_session beginConfiguration];
        [self removeAudioDataOutputLocked];
        [_session removeInput:_audioInput];
        [_session commitConfiguration];
        _audioInput = nil;
    }

    self.microphoneEnabled = NO;
    return YES;
}

- (void)ensureAudioDataOutputLocked {
    if (self.isShuttingDown || !_session || !_audioInput) {
        return;
    }

    if (_audioDataOutput != nil) {
        return;
    }

    AVCaptureAudioDataOutput *audioDataOutput = [[AVCaptureAudioDataOutput alloc] init];
    if (![_session canAddOutput:audioDataOutput]) {
        return;
    }

    [_session addOutput:audioDataOutput];
    [audioDataOutput setSampleBufferDelegate:self queue:_audioSampleOutputQueue];
    _audioDataOutput = audioDataOutput;
}

- (void)removeAudioDataOutputLocked {
    if (!_audioDataOutput || !_session) {
        return;
    }

    [_audioDataOutput setSampleBufferDelegate:nil queue:NULL];
    if ([_session.outputs containsObject:_audioDataOutput]) {
        [_session removeOutput:_audioDataOutput];
    }
    _audioDataOutput = nil;
}

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
#pragma unused(connection)
    if (output != _audioDataOutput || !sampleBuffer || self.isShuttingDown) {
        return;
    }

    InterLocalMediaAudioSampleBufferHandler sampleHandler = self.audioSampleBufferHandler;
    if (!sampleHandler) {
        return;
    }

    CFRetain(sampleBuffer);
    __weak typeof(self) weakSelf = self;
    dispatch_async(_audioSampleCallbackQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.isShuttingDown) {
            CFRelease(sampleBuffer);
            return;
        }

        InterLocalMediaAudioSampleBufferHandler callback = strongSelf.audioSampleBufferHandler;
        if (callback) {
            callback(sampleBuffer);
        }

        CFRelease(sampleBuffer);
    });
}

- (AVCaptureDevice *)preferredVideoDevice {
    NSMutableArray<AVCaptureDeviceType> *deviceTypes = [NSMutableArray arrayWithArray:@[
        AVCaptureDeviceTypeBuiltInWideAngleCamera,
        AVCaptureDeviceTypeExternal
    ]];
    if (@available(macOS 14.0, *)) {
        [deviceTypes addObject:AVCaptureDeviceTypeContinuityCamera];
    }

    AVCaptureDeviceDiscoverySession *discoverySession =
    [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:deviceTypes
                                                          mediaType:AVMediaTypeVideo
                                                           position:AVCaptureDevicePositionUnspecified];

    AVCaptureDevice *fallbackDevice = nil;

    for (AVCaptureDevice *device in discoverySession.devices) {
        if (!fallbackDevice) {
            fallbackDevice = device;
        }

        BOOL isDeskView = NO;
        if (@available(macOS 13.0, *)) {
            isDeskView = [device.deviceType isEqualToString:AVCaptureDeviceTypeDeskViewCamera];
        }
        if (isDeskView) {
            continue;
        }

        if (device.position == AVCaptureDevicePositionFront) {
            return device;
        }
    }

    if (fallbackDevice) {
        return fallbackDevice;
    }

    return [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
}

- (nullable AVCaptureDevice *)preferredAudioDevice {
    AVCaptureDevice *defaultDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    if (defaultDevice && ![self isLikelyProblematicAudioDevice:defaultDevice]) {
        return defaultDevice;
    }

    AVCaptureDeviceDiscoverySession *discoverySession =
    [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeMicrophone]
                                                          mediaType:AVMediaTypeAudio
                                                           position:AVCaptureDevicePositionUnspecified];

    for (AVCaptureDevice *device in discoverySession.devices) {
        if (![self isLikelyProblematicAudioDevice:device]) {
            if (defaultDevice) {
                NSLog(@"[G8] Switching audio input from potentially unstable device '%@' to '%@'",
                      defaultDevice.localizedName,
                      device.localizedName);
            }
            return device;
        }
    }

    return defaultDevice;
}

- (BOOL)isLikelyProblematicAudioDevice:(AVCaptureDevice *)device {
    if (!device) {
        return NO;
    }

    NSString *name = device.localizedName.lowercaseString;
    NSString *uniqueID = device.uniqueID.lowercaseString;
    static NSArray<NSString *> *problematicTokens;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        problematicTokens = @[
            @"aggregate",
            @"multi-output",
            @"blackhole",
            @"loopback",
            @"soundflower",
            @"zoom",
            @"virtual",
            @"vpau",
            @"cadefaultdeviceaggregate"
        ];
    });

    for (NSString *token in problematicTokens) {
        if ([name containsString:token] || [uniqueID containsString:token]) {
            return YES;
        }
    }

    return NO;
}

- (void)registerDeviceAvailabilityObservers {
    if (_deviceAvailabilityObserversRegistered) {
        return;
    }

    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
    [notificationCenter addObserver:self
                           selector:@selector(handleCaptureDeviceAvailabilityNotification:)
                               name:AVCaptureDeviceWasConnectedNotification
                             object:nil];
    [notificationCenter addObserver:self
                           selector:@selector(handleCaptureDeviceAvailabilityNotification:)
                               name:AVCaptureDeviceWasDisconnectedNotification
                             object:nil];
    _deviceAvailabilityObserversRegistered = YES;
}

- (void)unregisterDeviceAvailabilityObservers {
    if (!_deviceAvailabilityObserversRegistered) {
        return;
    }

    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
    [notificationCenter removeObserver:self
                                  name:AVCaptureDeviceWasConnectedNotification
                                object:nil];
    [notificationCenter removeObserver:self
                                  name:AVCaptureDeviceWasDisconnectedNotification
                                object:nil];
    _deviceAvailabilityObserversRegistered = NO;
}

- (void)handleCaptureDeviceAvailabilityNotification:(NSNotification *)notification {
    if (self.isShuttingDown) {
        return;
    }

    id object = notification.object;
    if (object && ![object isKindOfClass:[AVCaptureDevice class]]) {
        return;
    }

    AVCaptureDevice *device = (AVCaptureDevice *)object;
    if (device && ![device hasMediaType:AVMediaTypeAudio]) {
        return;
    }

    // Hardware discovery should update the picker even when the microphone is
    // currently off. Callers re-enumerate through the public options API.
    [self notifyAudioInputOptionsChanged];
}

- (void)notifyAudioInputOptionsChanged {
    dispatch_block_t handler = self.audioInputOptionsChangedHandler;
    if (!handler) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.isShuttingDown) {
            return;
        }

        dispatch_block_t currentHandler = self.audioInputOptionsChangedHandler;
        if (currentHandler) {
            currentHandler();
        }
    });
}

@end
