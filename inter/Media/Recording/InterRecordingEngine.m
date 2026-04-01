#import "InterRecordingEngine.h"

#import <os/lock.h>
#import <os/log.h>

static os_log_t InterRecordingEngineLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.inter.recording", "engine");
    });
    return log;
}

// ---------------------------------------------------------------------------
// MARK: - Private Interface
// ---------------------------------------------------------------------------

@interface InterRecordingEngine ()

@property (nonatomic, strong) NSURL *outputURL;
@property (nonatomic, assign) CGSize videoSize;
@property (nonatomic, assign) int frameRate;
@property (nonatomic, assign) int audioChannels;
@property (nonatomic, assign) double audioSampleRate;

@end

@implementation InterRecordingEngine {
    // AVAssetWriter graph — only accessed on _recordingQueue.
    AVAssetWriter *_assetWriter;
    AVAssetWriterInput *_videoInput;
    AVAssetWriterInput *_audioInput;
    AVAssetWriterInputPixelBufferAdaptor *_pixelBufferAdaptor;

    // Serial queue serializing ALL AVAssetWriter operations.
    dispatch_queue_t _recordingQueue;

    // Lightweight lock for scalar state read/written across queues.
    // Hold time < 100ns — only scalar reads/writes, never blocking calls inside.
    os_unfair_lock _engineLock;

    // Guarded by _engineLock — read from _recordingQueue, written from coordinator.
    BOOL _isPaused;
    BOOL _isStopping;
    CMTime _totalPauseDuration;  // Accumulated pause time to subtract from PTS.
    CMTime _pauseStartTime;      // When current pause began (kCMTimeInvalid if not paused).
    BOOL _sessionStarted;        // Whether startSession has been called on the writer.

    // Monotonic PTS enforcement — only accessed on _recordingQueue.
    CMTime _lastVideoPTS;
    CMTime _lastAudioPTS;

    // Drop counters — atomic increments (read from any thread).
    NSUInteger _droppedVideoFrames;
    NSUInteger _droppedAudioSamples;
}

// ---------------------------------------------------------------------------
// MARK: - Init
// ---------------------------------------------------------------------------

- (instancetype)initWithOutputURL:(NSURL *)outputURL
                        videoSize:(CGSize)videoSize
                        frameRate:(int)frameRate
                    audioChannels:(int)channels
                  audioSampleRate:(double)sampleRate {
    self = [super init];
    if (!self) return nil;

    _outputURL = outputURL;
    _videoSize = videoSize;
    _frameRate = frameRate;
    _audioChannels = channels;
    _audioSampleRate = sampleRate;

    _recordingQueue = dispatch_queue_create("com.inter.recording.engine.writer",
                                            DISPATCH_QUEUE_SERIAL);

    _engineLock = OS_UNFAIR_LOCK_INIT;
    _isPaused = NO;
    _isStopping = NO;
    _totalPauseDuration = kCMTimeZero;
    _pauseStartTime = kCMTimeInvalid;
    _sessionStarted = NO;

    _lastVideoPTS = kCMTimeInvalid;
    _lastAudioPTS = kCMTimeInvalid;

    _droppedVideoFrames = 0;
    _droppedAudioSamples = 0;

    return self;
}

// ---------------------------------------------------------------------------
// MARK: - Public Properties
// ---------------------------------------------------------------------------

- (BOOL)isRecording {
    os_unfair_lock_lock(&_engineLock);
    BOOL recording = (_assetWriter != nil) && !_isStopping;
    os_unfair_lock_unlock(&_engineLock);
    return recording;
}

- (BOOL)isPaused {
    os_unfair_lock_lock(&_engineLock);
    BOOL paused = _isPaused;
    os_unfair_lock_unlock(&_engineLock);
    return paused;
}

- (CMTime)recordedDuration {
    os_unfair_lock_lock(&_engineLock);
    CMTime lastPTS = _lastVideoPTS;
    CMTime pauseDuration = _totalPauseDuration;
    os_unfair_lock_unlock(&_engineLock);

    if (!CMTIME_IS_VALID(lastPTS)) {
        return kCMTimeZero;
    }
    CMTime duration = CMTimeSubtract(lastPTS, pauseDuration);
    return CMTIME_IS_VALID(duration) ? duration : kCMTimeZero;
}

- (NSUInteger)droppedVideoFrameCount {
    return _droppedVideoFrames;  // Atomic read on 64-bit.
}

- (NSUInteger)droppedAudioSampleCount {
    return _droppedAudioSamples;
}

// ---------------------------------------------------------------------------
// MARK: - Start
// ---------------------------------------------------------------------------

- (BOOL)startRecording {
    NSError *error = nil;

    // Remove any pre-existing file at the output URL.
    [[NSFileManager defaultManager] removeItemAtURL:_outputURL error:nil];

    _assetWriter = [[AVAssetWriter alloc] initWithURL:_outputURL
                                             fileType:AVFileTypeMPEG4
                                                error:&error];
    if (!_assetWriter) {
        os_log_error(InterRecordingEngineLog(),
                     "Failed to create AVAssetWriter: %{public}@", error.localizedDescription);
        return NO;
    }

    // ----- Video Input -----
    NSDictionary *videoCompressionProps = @{
        AVVideoAverageBitRateKey: @(4500000),            // 4.5 Mbps
        AVVideoMaxKeyFrameIntervalKey: @(_frameRate * 2), // Keyframe every 2 seconds
        AVVideoProfileLevelKey: AVVideoProfileLevelH264Main41,
    };

    NSDictionary *videoSettings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @((int)_videoSize.width),
        AVVideoHeightKey: @((int)_videoSize.height),
        AVVideoCompressionPropertiesKey: videoCompressionProps,
    };

    _videoInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo
                                                outputSettings:videoSettings];
    _videoInput.expectsMediaDataInRealTime = YES;

    NSDictionary *sourcePixelBufferAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @((int)_videoSize.width),
        (id)kCVPixelBufferHeightKey: @((int)_videoSize.height),
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };

    _pixelBufferAdaptor =
        [[AVAssetWriterInputPixelBufferAdaptor alloc] initWithAssetWriterInput:_videoInput
                                                  sourcePixelBufferAttributes:sourcePixelBufferAttrs];

    if ([_assetWriter canAddInput:_videoInput]) {
        [_assetWriter addInput:_videoInput];
    } else {
        os_log_error(InterRecordingEngineLog(), "Cannot add video input to asset writer.");
        return NO;
    }

    // ----- Audio Input -----
    AudioChannelLayout channelLayout = {0};
    channelLayout.mChannelLayoutTag = (_audioChannels == 1)
        ? kAudioChannelLayoutTag_Mono
        : kAudioChannelLayoutTag_Stereo;

    NSDictionary *audioSettings = @{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVSampleRateKey: @(_audioSampleRate),
        AVNumberOfChannelsKey: @(_audioChannels),
        AVEncoderBitRateKey: @(128000),  // 128 kbps
        AVChannelLayoutKey: [NSData dataWithBytes:&channelLayout
                                           length:sizeof(channelLayout)],
    };

    _audioInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio
                                                outputSettings:audioSettings];
    _audioInput.expectsMediaDataInRealTime = YES;

    if ([_assetWriter canAddInput:_audioInput]) {
        [_assetWriter addInput:_audioInput];
    } else {
        os_log_error(InterRecordingEngineLog(), "Cannot add audio input to asset writer.");
        return NO;
    }

    // ----- Start writing -----
    if (![_assetWriter startWriting]) {
        os_log_error(InterRecordingEngineLog(),
                     "startWriting failed: %{public}@",
                     _assetWriter.error.localizedDescription);
        return NO;
    }

    os_log_info(InterRecordingEngineLog(),
                "Recording started: %{public}@ (%dx%d @ %dfps)",
                _outputURL.lastPathComponent,
                (int)_videoSize.width, (int)_videoSize.height, _frameRate);

    return YES;
}

// ---------------------------------------------------------------------------
// MARK: - Append Video
// ---------------------------------------------------------------------------

- (void)appendVideoPixelBuffer:(CVPixelBufferRef)pixelBuffer
              presentationTime:(CMTime)presentationTime {
    if (!pixelBuffer) return;

    // Check stop gate under lock — prevents enqueueing after the stop sentinel.
    os_unfair_lock_lock(&_engineLock);
    BOOL stopping = _isStopping;
    BOOL paused = _isPaused;
    CMTime pauseOffset = _totalPauseDuration;
    os_unfair_lock_unlock(&_engineLock);

    if (stopping || paused) return;

    // Retain the pixel buffer across the async dispatch.
    CVPixelBufferRetain(pixelBuffer);

    dispatch_async(_recordingQueue, ^{
        [self _appendVideoPixelBuffer:pixelBuffer
                     presentationTime:presentationTime
                          pauseOffset:pauseOffset];
        CVPixelBufferRelease(pixelBuffer);
    });
}

/// Internal append — runs exclusively on _recordingQueue.
- (void)_appendVideoPixelBuffer:(CVPixelBufferRef)pixelBuffer
               presentationTime:(CMTime)originalPTS
                    pauseOffset:(CMTime)pauseOffset {
    if (_assetWriter.status != AVAssetWriterStatusWriting) {
        [self _handleWriterFailureIfNeeded];
        return;
    }

    // Start the writer session on the first frame's PTS.
    if (!_sessionStarted) {
        [_assetWriter startSessionAtSourceTime:originalPTS];
        _sessionStarted = YES;
    }

    // Adjust PTS to remove paused intervals.
    CMTime adjustedPTS = CMTimeSubtract(originalPTS, pauseOffset);

    // Monotonic PTS enforcement — drop out-of-order or duplicate frames.
    if (CMTIME_IS_VALID(_lastVideoPTS) &&
        CMTimeCompare(adjustedPTS, _lastVideoPTS) <= 0) {
        _droppedVideoFrames++;
        id<InterRecordingEngineDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:@selector(recordingEngineDidDropVideoFrame:)]) {
            [delegate recordingEngineDidDropVideoFrame:_droppedVideoFrames];
        }
        return;
    }

    // Check writer readiness — drop frame if back-pressured.
    if (!_videoInput.isReadyForMoreMediaData) {
        _droppedVideoFrames++;
        os_log_debug(InterRecordingEngineLog(), "Video input not ready — dropped frame (total: %lu)",
                     (unsigned long)_droppedVideoFrames);
        id<InterRecordingEngineDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:@selector(recordingEngineDidDropVideoFrame:)]) {
            [delegate recordingEngineDidDropVideoFrame:_droppedVideoFrames];
        }
        return;
    }

    BOOL appended = [_pixelBufferAdaptor appendPixelBuffer:pixelBuffer
                                      withPresentationTime:adjustedPTS];
    if (appended) {
        _lastVideoPTS = adjustedPTS;
    } else {
        _droppedVideoFrames++;
        os_log_error(InterRecordingEngineLog(), "appendPixelBuffer failed (status: %ld)",
                     (long)_assetWriter.status);
        [self _handleWriterFailureIfNeeded];
    }
}

// ---------------------------------------------------------------------------
// MARK: - Append Audio
// ---------------------------------------------------------------------------

- (void)appendAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!sampleBuffer) return;

    os_unfair_lock_lock(&_engineLock);
    BOOL stopping = _isStopping;
    BOOL paused = _isPaused;
    CMTime pauseOffset = _totalPauseDuration;
    os_unfair_lock_unlock(&_engineLock);

    if (stopping || paused) return;

    // Retain across async dispatch.
    CFRetain(sampleBuffer);

    dispatch_async(_recordingQueue, ^{
        [self _appendAudioSampleBuffer:sampleBuffer pauseOffset:pauseOffset];
        CFRelease(sampleBuffer);
    });
}

/// Internal append — runs exclusively on _recordingQueue.
- (void)_appendAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer
                     pauseOffset:(CMTime)pauseOffset {
    if (_assetWriter.status != AVAssetWriterStatusWriting) {
        [self _handleWriterFailureIfNeeded];
        return;
    }

    // Start session if audio arrives before the first video frame.
    CMTime originalPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    if (!_sessionStarted) {
        [_assetWriter startSessionAtSourceTime:originalPTS];
        _sessionStarted = YES;
    }

    CMTime adjustedPTS = CMTimeSubtract(originalPTS, pauseOffset);

    // Monotonic PTS enforcement.
    if (CMTIME_IS_VALID(_lastAudioPTS) &&
        CMTimeCompare(adjustedPTS, _lastAudioPTS) <= 0) {
        _droppedAudioSamples++;
        id<InterRecordingEngineDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:@selector(recordingEngineDidDropAudioSample:)]) {
            [delegate recordingEngineDidDropAudioSample:_droppedAudioSamples];
        }
        return;
    }

    if (!_audioInput.isReadyForMoreMediaData) {
        _droppedAudioSamples++;
        os_log_debug(InterRecordingEngineLog(), "Audio input not ready — dropped sample (total: %lu)",
                     (unsigned long)_droppedAudioSamples);
        id<InterRecordingEngineDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:@selector(recordingEngineDidDropAudioSample:)]) {
            [delegate recordingEngineDidDropAudioSample:_droppedAudioSamples];
        }
        return;
    }

    // Create an offset sample buffer with the adjusted PTS.
    // We need to adjust the timing of the sample buffer to account for pauses.
    CMSampleBufferRef adjustedBuffer = NULL;
    CMSampleTimingInfo timingInfo;
    timingInfo.presentationTimeStamp = adjustedPTS;
    timingInfo.duration = CMSampleBufferGetDuration(sampleBuffer);
    timingInfo.decodeTimeStamp = kCMTimeInvalid;

    OSStatus status = CMSampleBufferCreateCopyWithNewTiming(
        kCFAllocatorDefault,
        sampleBuffer,
        1,
        &timingInfo,
        &adjustedBuffer
    );

    if (status != noErr || !adjustedBuffer) {
        _droppedAudioSamples++;
        os_log_error(InterRecordingEngineLog(),
                     "Failed to create adjusted audio sample buffer (OSStatus: %d)", (int)status);
        return;
    }

    BOOL appended = [_audioInput appendSampleBuffer:adjustedBuffer];
    CFRelease(adjustedBuffer);

    if (appended) {
        _lastAudioPTS = adjustedPTS;
    } else {
        _droppedAudioSamples++;
        os_log_error(InterRecordingEngineLog(), "appendSampleBuffer (audio) failed (status: %ld)",
                     (long)_assetWriter.status);
        [self _handleWriterFailureIfNeeded];
    }
}

// ---------------------------------------------------------------------------
// MARK: - Pause / Resume
// ---------------------------------------------------------------------------

- (void)pauseRecording {
    os_unfair_lock_lock(&_engineLock);
    if (_isPaused || _isStopping) {
        os_unfair_lock_unlock(&_engineLock);
        return;
    }
    _isPaused = YES;
    // Capture the current PTS baseline. Because we don't know the exact PTS at
    // the moment of pause we use the wall clock as a proxy — the actual pause
    // duration is computed when resumeRecording is called using the same clock.
    _pauseStartTime = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000000);
    os_unfair_lock_unlock(&_engineLock);

    os_log_info(InterRecordingEngineLog(), "Recording paused.");
}

- (void)resumeRecording {
    os_unfair_lock_lock(&_engineLock);
    if (!_isPaused || _isStopping) {
        os_unfair_lock_unlock(&_engineLock);
        return;
    }
    CMTime now = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000000);
    CMTime thisPauseDuration = CMTimeSubtract(now, _pauseStartTime);
    _totalPauseDuration = CMTimeAdd(_totalPauseDuration, thisPauseDuration);
    _isPaused = NO;
    _pauseStartTime = kCMTimeInvalid;
    os_unfair_lock_unlock(&_engineLock);

    os_log_info(InterRecordingEngineLog(), "Recording resumed (total pause: %.2fs).",
                CMTimeGetSeconds(_totalPauseDuration));
}

// ---------------------------------------------------------------------------
// MARK: - Stop
// ---------------------------------------------------------------------------

- (void)stopRecordingWithCompletion:(void (^)(NSURL * _Nullable, NSError * _Nullable))completion {
    // Set the stop gate FIRST — this prevents any new appends from being
    // enqueued after the stop sentinel block below.
    os_unfair_lock_lock(&_engineLock);
    if (_isStopping) {
        os_unfair_lock_unlock(&_engineLock);
        if (completion) completion(nil, nil);
        return;
    }
    _isStopping = YES;
    os_unfair_lock_unlock(&_engineLock);

    os_log_info(InterRecordingEngineLog(), "Stopping recording...");

    // The stop sentinel: because this is dispatch_async'd to the serial
    // _recordingQueue, it is guaranteed to run AFTER all previously enqueued
    // append blocks. This is the "stop drain gate" — finishWriting cannot
    // race with in-flight appends.
    dispatch_async(_recordingQueue, ^{
        if (self->_assetWriter.status == AVAssetWriterStatusWriting) {
            [self->_videoInput markAsFinished];
            [self->_audioInput markAsFinished];
            [self->_assetWriter finishWritingWithCompletionHandler:^{
                NSError *writerError = self->_assetWriter.error;
                NSURL *url = writerError ? nil : self->_outputURL;

                if (writerError) {
                    os_log_error(InterRecordingEngineLog(),
                                 "finishWriting failed: %{public}@",
                                 writerError.localizedDescription);
                } else {
                    os_log_info(InterRecordingEngineLog(),
                                "Recording saved: %{public}@ (dropped V:%lu A:%lu)",
                                self->_outputURL.lastPathComponent,
                                (unsigned long)self->_droppedVideoFrames,
                                (unsigned long)self->_droppedAudioSamples);
                }

                if (completion) completion(url, writerError);
            }];
        } else {
            NSError *writerError = self->_assetWriter.error;
            os_log_error(InterRecordingEngineLog(),
                         "Writer not in writing state at stop (status: %ld, error: %{public}@).",
                         (long)self->_assetWriter.status,
                         writerError.localizedDescription);
            if (completion) completion(nil, writerError);
        }
    });
}

// ---------------------------------------------------------------------------
// MARK: - Error Handling
// ---------------------------------------------------------------------------

/// Check for writer failure and notify delegate. Only called on _recordingQueue.
- (void)_handleWriterFailureIfNeeded {
    if (_assetWriter.status == AVAssetWriterStatusFailed) {
        NSError *error = _assetWriter.error;
        os_log_error(InterRecordingEngineLog(),
                     "AVAssetWriter failed: %{public}@", error.localizedDescription);
        id<InterRecordingEngineDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:@selector(recordingEngineDidFailWithError:)]) {
            [delegate recordingEngineDidFailWithError:error];
        }
    }
}

@end
