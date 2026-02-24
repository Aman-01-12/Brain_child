#import "InterRecordingSink.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <string.h>

#import "InterAppSettings.h"

@interface InterRecordingSink ()
@property (atomic, assign, readwrite, getter=isActive) BOOL active;
@end

@implementation InterRecordingSink {
    dispatch_queue_t _writerQueue;

    AVAssetWriter *_assetWriter;
    AVAssetWriterInput *_videoInput;
    AVAssetWriterInput *_audioInput;
    AVAssetWriterInputPixelBufferAdaptor *_pixelBufferAdaptor;

    InterShareSessionConfiguration *_configuration;
    NSURL *_outputURL;
    NSURL *_securityScopedRecordingDirectoryURL;
    BOOL _isAccessingSecurityScopedDirectory;

    Float64 _detectedAudioSampleRate;
    NSInteger _detectedAudioChannels;

    CMTime _sessionStartTime;
    BOOL _hasStartedSession;

    CMTime _lastVideoPTS;
    CMTime _lastAudioPTS;
    BOOL _hasLastVideoPTS;
    BOOL _hasLastAudioPTS;

    BOOL _isFinishing;
    uint64_t _lifecycleGeneration;
    NSUInteger _droppedOutOfOrderVideoFrameCount;
    NSUInteger _droppedOutOfOrderAudioSampleCount;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    _writerQueue = dispatch_queue_create("secure.inter.share.sink.recording.writer",
                                         DISPATCH_QUEUE_SERIAL);
    _active = NO;
    _detectedAudioSampleRate = 0;
    _detectedAudioChannels = 0;
    _hasStartedSession = NO;
    _hasLastVideoPTS = NO;
    _hasLastAudioPTS = NO;
    _isFinishing = NO;
    _isAccessingSecurityScopedDirectory = NO;
    _securityScopedRecordingDirectoryURL = nil;
    _lifecycleGeneration = 0;
    _droppedOutOfOrderVideoFrameCount = 0;
    _droppedOutOfOrderAudioSampleCount = 0;
    return self;
}

- (void)startWithConfiguration:(InterShareSessionConfiguration *)configuration
                    completion:(InterShareSinkStartCompletion)completion {
    InterShareSessionConfiguration *capturedConfiguration = [configuration copy];
    dispatch_async(_writerQueue, ^{
        self->_lifecycleGeneration += 1;
        self->_configuration = capturedConfiguration;
        [self releaseSecurityScopedDirectoryAccessLocked];
        [self resetWriterStateLocked];

        if (!capturedConfiguration.isRecordingEnabled) {
            self.active = NO;
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(NO, @"Recording is disabled for this session.");
                });
            }
            return;
        }

        NSError *directoryError = nil;
        BOOL didStartSecurityScope = NO;
        NSURL *recordingDirectoryURL = [InterAppSettings resolvedRecordingDirectoryURLStartingSecurityScope:&didStartSecurityScope
                                                                                                      error:&directoryError];
        if (!recordingDirectoryURL) {
            self.active = NO;
            self->_outputURL = nil;
            if (completion) {
                NSString *status = directoryError.localizedDescription;
                if (status.length == 0) {
                    status = @"Recording folder not configured. Open Settings and choose a recording folder.";
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(NO, status);
                });
            }
            return;
        }

        self->_securityScopedRecordingDirectoryURL = recordingDirectoryURL;
        self->_isAccessingSecurityScopedDirectory = didStartSecurityScope;
        self->_outputURL = [recordingDirectoryURL URLByAppendingPathComponent:[self nextRecordingFilename]
                                                                   isDirectory:NO];
        self.active = YES;

        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(YES, @"Recording destination is ready.");
            });
        }
    });
}

- (void)appendVideoFrame:(InterShareVideoFrame *)frame {
    if (!frame) {
        return;
    }

    dispatch_async(_writerQueue, ^{
        if (!self.isActive || self->_isFinishing || !self->_outputURL) {
            return;
        }

        CMTime pts = frame.presentationTime;
        if (self->_hasLastVideoPTS && CMTIME_COMPARE_INLINE(pts, <=, self->_lastVideoPTS)) {
            self->_droppedOutOfOrderVideoFrameCount += 1;
            return;
        }

        if (!self->_assetWriter) {
            BOOL writerReady = [self setupWriterWithFirstFrame:frame];
            if (!writerReady) {
                self.active = NO;
                return;
            }
        }

        if (!self->_hasStartedSession) {
            return;
        }

        if (!self->_videoInput || !self->_videoInput.readyForMoreMediaData) {
            return;
        }

        BOOL appended = [self->_pixelBufferAdaptor appendPixelBuffer:frame.pixelBuffer
                                                 withPresentationTime:pts];
        if (!appended) {
            return;
        }

        self->_lastVideoPTS = pts;
        self->_hasLastVideoPTS = YES;
    });
}

- (void)appendAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!sampleBuffer) {
        return;
    }

    CFRetain(sampleBuffer);
    dispatch_async(_writerQueue, ^{
        if (!self.isActive || self->_isFinishing) {
            CFRelease(sampleBuffer);
            return;
        }

        [self updateDetectedAudioFormatFromSampleBuffer:sampleBuffer];

        if (!self->_assetWriter || !self->_audioInput || !self->_hasStartedSession) {
            CFRelease(sampleBuffer);
            return;
        }

        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        if (!CMTIME_IS_VALID(pts)) {
            CFRelease(sampleBuffer);
            return;
        }

        if (CMTIME_COMPARE_INLINE(pts, <, self->_sessionStartTime)) {
            CFRelease(sampleBuffer);
            return;
        }

        if (self->_hasLastAudioPTS && CMTIME_COMPARE_INLINE(pts, <=, self->_lastAudioPTS)) {
            self->_droppedOutOfOrderAudioSampleCount += 1;
            CFRelease(sampleBuffer);
            return;
        }

        if (!self->_audioInput.readyForMoreMediaData) {
            CFRelease(sampleBuffer);
            return;
        }

        BOOL appended = [self->_audioInput appendSampleBuffer:sampleBuffer];
        if (appended) {
            self->_lastAudioPTS = pts;
            self->_hasLastAudioPTS = YES;
        }

        CFRelease(sampleBuffer);
    });
}

- (void)stopWithCompletion:(dispatch_block_t)completion {
    dispatch_async(_writerQueue, ^{
        self->_lifecycleGeneration += 1;
        self.active = NO;

        if (self->_isFinishing) {
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), completion);
            }
            return;
        }

        self->_isFinishing = YES;

        AVAssetWriter *writer = self->_assetWriter;
        AVAssetWriterInput *videoInput = self->_videoInput;
        AVAssetWriterInput *audioInput = self->_audioInput;
        NSURL *outputURL = self->_outputURL;

        if (videoInput) {
            [videoInput markAsFinished];
        }
        if (audioInput) {
            [audioInput markAsFinished];
        }

        if (!writer) {
            [self releaseSecurityScopedDirectoryAccessLocked];
            [self resetWriterStateLocked];
            self->_isFinishing = NO;
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), completion);
            }
            return;
        }

        [writer finishWritingWithCompletionHandler:^{
            dispatch_async(self->_writerQueue, ^{
                if (outputURL.path.length > 0) {
                    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0600}
                                                     ofItemAtPath:outputURL.path
                                                            error:nil];
                }

                [self releaseSecurityScopedDirectoryAccessLocked];
                [self resetWriterStateLocked];
                self->_isFinishing = NO;

                if (completion) {
                    dispatch_async(dispatch_get_main_queue(), completion);
                }
            });
        }];
    });
}

#pragma mark - Internal

- (BOOL)setupWriterWithFirstFrame:(InterShareVideoFrame *)frame {
    if (!frame.pixelBuffer || !_outputURL) {
        return NO;
    }

    NSError *writerError = nil;
    _assetWriter = [AVAssetWriter assetWriterWithURL:_outputURL
                                            fileType:AVFileTypeMPEG4
                                               error:&writerError];
    if (!_assetWriter || writerError) {
        return NO;
    }

    size_t frameWidth = CVPixelBufferGetWidth(frame.pixelBuffer);
    size_t frameHeight = CVPixelBufferGetHeight(frame.pixelBuffer);
    if (frameWidth == 0 || frameHeight == 0) {
        return NO;
    }

    NSDictionary *videoSettings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(frameWidth),
        AVVideoHeightKey: @(frameHeight),
        AVVideoCompressionPropertiesKey: @{
            AVVideoAverageBitRateKey: @6000000,
            AVVideoMaxKeyFrameIntervalKey: @30,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        }
    };

    _videoInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo
                                                  outputSettings:videoSettings];
    _videoInput.expectsMediaDataInRealTime = YES;

    NSDictionary *sourcePixelBufferAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(frameWidth),
        (id)kCVPixelBufferHeightKey: @(frameHeight)
    };

    _pixelBufferAdaptor = [[AVAssetWriterInputPixelBufferAdaptor alloc] initWithAssetWriterInput:_videoInput
                                                                      sourcePixelBufferAttributes:sourcePixelBufferAttributes];

    if ([_assetWriter canAddInput:_videoInput]) {
        [_assetWriter addInput:_videoInput];
    } else {
        return NO;
    }

    NSDictionary *audioSettings = [self resolvedAudioOutputSettings];
    _audioInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio
                                                  outputSettings:audioSettings];
    _audioInput.expectsMediaDataInRealTime = YES;

    if ([_assetWriter canAddInput:_audioInput]) {
        [_assetWriter addInput:_audioInput];
    } else {
        _audioInput = nil;
    }

    if (![_assetWriter startWriting]) {
        return NO;
    }

    _sessionStartTime = frame.presentationTime;
    [_assetWriter startSessionAtSourceTime:_sessionStartTime];
    _hasStartedSession = YES;

    return YES;
}

- (NSDictionary *)resolvedAudioOutputSettings {
    Float64 sampleRate = _detectedAudioSampleRate > 0 ? _detectedAudioSampleRate : 48000.0;
    NSInteger channels = _detectedAudioChannels > 0 ? _detectedAudioChannels : 1;

    AudioChannelLayout channelLayout;
    memset(&channelLayout, 0, sizeof(channelLayout));
    channelLayout.mChannelLayoutTag = (channels == 1)
    ? kAudioChannelLayoutTag_Mono
    : kAudioChannelLayoutTag_Stereo;

    NSData *channelLayoutData = [NSData dataWithBytes:&channelLayout
                                               length:sizeof(channelLayout)];

    return @{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVSampleRateKey: @(sampleRate),
        AVNumberOfChannelsKey: @(channels),
        AVEncoderBitRateKey: @128000,
        AVChannelLayoutKey: channelLayoutData
    };
}

- (void)updateDetectedAudioFormatFromSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (_detectedAudioSampleRate > 0 && _detectedAudioChannels > 0) {
        return;
    }

    CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!formatDescription) {
        return;
    }

    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription);
    if (!asbd) {
        return;
    }

    if (_detectedAudioSampleRate <= 0 && asbd->mSampleRate > 0) {
        _detectedAudioSampleRate = asbd->mSampleRate;
    }

    if (_detectedAudioChannels <= 0 && asbd->mChannelsPerFrame > 0) {
        _detectedAudioChannels = asbd->mChannelsPerFrame;
    }
}

- (void)resetWriterStateLocked {
    _assetWriter = nil;
    _videoInput = nil;
    _audioInput = nil;
    _pixelBufferAdaptor = nil;
    _outputURL = nil;

    _detectedAudioSampleRate = 0;
    _detectedAudioChannels = 0;

    _hasStartedSession = NO;
    _sessionStartTime = kCMTimeInvalid;
    _lastVideoPTS = kCMTimeInvalid;
    _lastAudioPTS = kCMTimeInvalid;
    _hasLastVideoPTS = NO;
    _hasLastAudioPTS = NO;
    _droppedOutOfOrderVideoFrameCount = 0;
    _droppedOutOfOrderAudioSampleCount = 0;
}

- (NSString *)nextRecordingFilename {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone localTimeZone];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";

    NSString *timestamp = [formatter stringFromDate:[NSDate date]];
    return [NSString stringWithFormat:@"SecureCall-%@.mp4", timestamp];
}

- (void)releaseSecurityScopedDirectoryAccessLocked {
    if (_isAccessingSecurityScopedDirectory && _securityScopedRecordingDirectoryURL) {
        [_securityScopedRecordingDirectoryURL stopAccessingSecurityScopedResource];
    }
    _isAccessingSecurityScopedDirectory = NO;
    _securityScopedRecordingDirectoryURL = nil;
}

@end
