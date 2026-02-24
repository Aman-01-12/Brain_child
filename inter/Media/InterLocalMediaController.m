#import "InterLocalMediaController.h"

@interface InterLocalMediaController () <AVCaptureAudioDataOutputSampleBufferDelegate>
@property (atomic, assign, readwrite, getter=isConfigured) BOOL configured;
@property (atomic, assign, readwrite, getter=isRunning) BOOL running;
@property (atomic, assign, readwrite, getter=isCameraEnabled) BOOL cameraEnabled;
@property (atomic, assign, readwrite, getter=isMicrophoneEnabled) BOOL microphoneEnabled;
@property (atomic, assign, getter=isShuttingDown) BOOL shuttingDown;
+ (void)resolveAuthorizationStatusForMediaType:(AVMediaType)mediaType
                                    completion:(void (^)(AVAuthorizationStatus status))completion;
@end

static const void *InterLocalMediaSessionQueueKey = &InterLocalMediaSessionQueueKey;

@implementation InterLocalMediaController {
    dispatch_queue_t _sessionQueue;
    AVCaptureSession *_session;
    dispatch_queue_t _audioSampleOutputQueue;
    dispatch_queue_t _audioSampleCallbackQueue;

    AVCaptureDeviceInput *_videoInput;
    AVCaptureDeviceInput *_audioInput;
    AVCaptureAudioDataOutput *_audioDataOutput;

    __weak NSView *_previewHostView;
    AVCaptureVideoPreviewLayer *_previewLayer;
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
    return self;
}

- (void)dealloc {
    [self shutdown];
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
    [self detachPreviewSynchronously];
    [self performSynchronouslyOnSessionQueue:^{
        [self stopSessionLocked];

        if (!self->_session) {
            self.cameraEnabled = NO;
            self.microphoneEnabled = NO;
            self.configured = NO;
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

        self.cameraEnabled = NO;
        self.microphoneEnabled = NO;
        self.configured = NO;
        self->_session = nil;
        self.audioSampleBufferHandler = nil;
    }];
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

        AVCaptureDevice *audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
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

@end
