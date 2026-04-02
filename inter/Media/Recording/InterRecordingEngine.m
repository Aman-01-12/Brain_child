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
    // AVAssetWriter graph — confined to _recordingQueue exclusively.
    // Never accessed outside _recordingQueue after startRecording returns;
    // use _isActive (below) for cross-thread recording-state queries.
    AVAssetWriter *_assetWriter;
    AVAssetWriterInput *_videoInput;
    AVAssetWriterInput *_audioInput;
    AVAssetWriterInputPixelBufferAdaptor *_pixelBufferAdaptor;

    // Serial queue serializing ALL AVAssetWriter operations.
    dispatch_queue_t _recordingQueue;

    // Lightweight lock for scalar state read/written across queues.
    // Hold time < 100ns — only scalar reads/writes, never blocking calls inside.
    os_unfair_lock _engineLock;

    // Guarded by _engineLock — readable from any thread.
    BOOL _isActive;    // YES from a successful startRecording until the writer is torn down.
    BOOL _isPaused;
    BOOL _isStopping;
    CMTime _totalPauseDuration;    // Accumulated pause time to subtract from PTS.
    CMTime _pauseStartTime;        // When current pause began (kCMTimeInvalid if not paused).
    BOOL _sessionStarted;          // Whether startSession has been called on the writer.
    // Cross-thread snapshot of _lastVideoPTS for recordedDuration. _lastVideoPTS itself
    // is _recordingQueue-confined; this copy is written on _recordingQueue under
    // _engineLock so recordedDuration can read it safely from any thread.
    CMTime _lastVideoPTSSnapshot;

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
    _isActive = NO;
    _isPaused = NO;
    _isStopping = NO;
    _totalPauseDuration = kCMTimeZero;
    _pauseStartTime = kCMTimeInvalid;
    _sessionStarted = NO;

    _lastVideoPTS = kCMTimeInvalid;
    _lastAudioPTS = kCMTimeInvalid;
    _lastVideoPTSSnapshot = kCMTimeInvalid;

    _droppedVideoFrames = 0;
    _droppedAudioSamples = 0;

    return self;
}

// ---------------------------------------------------------------------------
// MARK: - Public Properties
// ---------------------------------------------------------------------------

- (BOOL)isRecording {
    // _assetWriter is _recordingQueue-confined; use the lock-guarded _isActive flag
    // so this getter is safe to call from any thread without crossing that boundary.
    os_unfair_lock_lock(&_engineLock);
    BOOL recording = _isActive && !_isStopping;
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
    // _lastVideoPTS is _recordingQueue-confined; read the lock-guarded snapshot instead.
    CMTime lastPTS = _lastVideoPTSSnapshot;
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
    __block BOOL success = NO;

    // All writer-graph construction runs synchronously on _recordingQueue.
    // This ensures _assetWriter, _videoInput, _audioInput, and _pixelBufferAdaptor
    // are fully initialised and committed to the queue before any append block
    // dispatched concurrently can run — eliminating the data race between setup
    // (historically on the caller thread) and the ivar reads inside the append methods.
    dispatch_sync(_recordingQueue, ^{
        NSError *error = nil;

        // Cleanup helper — called at every failure path to leave ivars in a
        // consistent nil/reset state so a subsequent startRecording call sees
        // a clean writer graph rather than stale partially-constructed objects.
        // If the writer has already called startWriting, cancelWriting is issued
        // so AVFoundation can release its internal resources before we nil it.
        void (^cleanupWriterGraph)(void) = ^{
            if (self->_assetWriter) {
                if (self->_assetWriter.status == AVAssetWriterStatusWriting) {
                    [self->_assetWriter cancelWriting];
                }
                self->_assetWriter = nil;
            }
            self->_videoInput          = nil;
            self->_audioInput          = nil;
            self->_pixelBufferAdaptor  = nil;
            self->_sessionStarted      = NO;
            os_unfair_lock_lock(&self->_engineLock);
            self->_isActive = NO;
            os_unfair_lock_unlock(&self->_engineLock);
        };

        // Remove any pre-existing file at the output URL.
        [[NSFileManager defaultManager] removeItemAtURL:self->_outputURL error:nil];

        self->_assetWriter = [[AVAssetWriter alloc] initWithURL:self->_outputURL
                                                       fileType:AVFileTypeMPEG4
                                                          error:&error];
        if (!self->_assetWriter) {
            os_log_error(InterRecordingEngineLog(),
                         "Failed to create AVAssetWriter: %{public}@", error.localizedDescription);
            cleanupWriterGraph();
            return;
        }

        // [Gap #7] Move the moov atom to the front of the file for faster playback start.
        self->_assetWriter.shouldOptimizeForNetworkUse = YES;

        // ----- Video Input -----
        NSDictionary *videoCompressionProps = @{
            AVVideoAverageBitRateKey: @(4500000),            // 4.5 Mbps
            AVVideoMaxKeyFrameIntervalKey: @(self->_frameRate * 2), // Keyframe every 2 seconds
            AVVideoProfileLevelKey: AVVideoProfileLevelH264Main41,
        };

        NSDictionary *videoSettings = @{
            AVVideoCodecKey: AVVideoCodecTypeH264,
            AVVideoWidthKey: @((int)self->_videoSize.width),
            AVVideoHeightKey: @((int)self->_videoSize.height),
            AVVideoCompressionPropertiesKey: videoCompressionProps,
        };

        self->_videoInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo
                                                          outputSettings:videoSettings];
        self->_videoInput.expectsMediaDataInRealTime = YES;

        NSDictionary *sourcePixelBufferAttrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @((int)self->_videoSize.width),
            (id)kCVPixelBufferHeightKey: @((int)self->_videoSize.height),
            (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        };

        self->_pixelBufferAdaptor =
            [[AVAssetWriterInputPixelBufferAdaptor alloc] initWithAssetWriterInput:self->_videoInput
                                                      sourcePixelBufferAttributes:sourcePixelBufferAttrs];

        if ([self->_assetWriter canAddInput:self->_videoInput]) {
            [self->_assetWriter addInput:self->_videoInput];
        } else {
            os_log_error(InterRecordingEngineLog(), "Cannot add video input to asset writer.");
            cleanupWriterGraph();
            return;
        }

        // ----- Audio Input -----
        AudioChannelLayout channelLayout = {0};
        channelLayout.mChannelLayoutTag = (self->_audioChannels == 1)
            ? kAudioChannelLayoutTag_Mono
            : kAudioChannelLayoutTag_Stereo;

        NSDictionary *audioSettings = @{
            AVFormatIDKey: @(kAudioFormatMPEG4AAC),
            AVSampleRateKey: @(self->_audioSampleRate),
            AVNumberOfChannelsKey: @(self->_audioChannels),
            AVEncoderBitRateKey: @(128000),  // 128 kbps
            AVChannelLayoutKey: [NSData dataWithBytes:&channelLayout
                                               length:sizeof(channelLayout)],
        };

        self->_audioInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio
                                                          outputSettings:audioSettings];
        self->_audioInput.expectsMediaDataInRealTime = YES;

        if ([self->_assetWriter canAddInput:self->_audioInput]) {
            [self->_assetWriter addInput:self->_audioInput];
        } else {
            os_log_error(InterRecordingEngineLog(), "Cannot add audio input to asset writer.");
            cleanupWriterGraph();
            return;
        }

        // ----- Start writing -----
        if (![self->_assetWriter startWriting]) {
            os_log_error(InterRecordingEngineLog(),
                         "startWriting failed: %{public}@",
                         self->_assetWriter.error.localizedDescription);
            cleanupWriterGraph();
            return;
        }

        // Signal to cross-thread callers (e.g. isRecording) that the writer is live.
        // Set inside the sync block so _isActive flips only after the entire writer
        // graph is committed to _recordingQueue.
        os_unfair_lock_lock(&self->_engineLock);
        self->_isActive = YES;
        os_unfair_lock_unlock(&self->_engineLock);

        success = YES;
    });

    if (success) {
        os_log_info(InterRecordingEngineLog(),
                    "Recording started: %{public}@ (%dx%d @ %dfps)",
                    _outputURL.lastPathComponent,
                    (int)_videoSize.width, (int)_videoSize.height, _frameRate);
    }

    return success;
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
        // Mirror to the lock-guarded snapshot so recordedDuration can read from any thread.
        os_unfair_lock_lock(&_engineLock);
        _lastVideoPTSSnapshot = adjustedPTS;
        os_unfair_lock_unlock(&_engineLock);
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
        id<InterRecordingEngineDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:@selector(recordingEngineDidDropAudioSample:)]) {
            [delegate recordingEngineDidDropAudioSample:_droppedAudioSamples];
        }
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

                // Clear _isActive before invoking the completion so that any
                // isRecording call made from within completion sees NO.
                os_unfair_lock_lock(&self->_engineLock);
                self->_isActive = NO;
                os_unfair_lock_unlock(&self->_engineLock);

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
            os_unfair_lock_lock(&self->_engineLock);
            self->_isActive = NO;
            os_unfair_lock_unlock(&self->_engineLock);
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
        // Mark not-active so isRecording returns NO even before stopRecording is called.
        os_unfair_lock_lock(&_engineLock);
        _isActive = NO;
        os_unfair_lock_unlock(&_engineLock);
        id<InterRecordingEngineDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:@selector(recordingEngineDidFailWithError:)]) {
            [delegate recordingEngineDidFailWithError:error];
        }
    }
}

@end
