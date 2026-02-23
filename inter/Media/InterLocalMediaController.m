#import "InterLocalMediaController.h"

@interface InterLocalMediaController ()
@property (atomic, assign, readwrite, getter=isConfigured) BOOL configured;
@property (atomic, assign, readwrite, getter=isRunning) BOOL running;
@property (atomic, assign, readwrite, getter=isCameraEnabled) BOOL cameraEnabled;
@property (atomic, assign, readwrite, getter=isMicrophoneEnabled) BOOL microphoneEnabled;
@property (atomic, assign, getter=isShuttingDown) BOOL shuttingDown;
@end

static const void *InterLocalMediaSessionQueueKey = &InterLocalMediaSessionQueueKey;

@implementation InterLocalMediaController {
    dispatch_queue_t _sessionQueue;
    AVCaptureSession *_session;

    AVCaptureDeviceInput *_videoInput;
    AVCaptureDeviceInput *_audioInput;

    __weak NSView *_previewHostView;
    AVCaptureVideoPreviewLayer *_previewLayer;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    _sessionQueue = dispatch_queue_create("secure.inter.media.local.session",
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
        [self->_session commitConfiguration];

        self.cameraEnabled = NO;
        self.microphoneEnabled = NO;
        self.configured = NO;
        self->_session = nil;
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
        self->_previewHostView = view;
    });
}

- (void)detachPreview {
    [self detachPreviewSynchronously];
}

#pragma mark - Internal

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

        self.cameraEnabled = canAdd;
        return canAdd;
    }

    if (_videoInput != nil) {
        [_session beginConfiguration];
        [_session removeInput:_videoInput];
        [_session commitConfiguration];
        _videoInput = nil;
    }

    self.cameraEnabled = NO;
    return YES;
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
        }
        [_session commitConfiguration];

        self.microphoneEnabled = canAdd;
        return canAdd;
    }

    if (_audioInput != nil) {
        [_session beginConfiguration];
        [_session removeInput:_audioInput];
        [_session commitConfiguration];
        _audioInput = nil;
    }

    self.microphoneEnabled = NO;
    return YES;
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
