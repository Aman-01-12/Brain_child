#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Delegate protocol for recording engine lifecycle events.
@protocol InterRecordingEngineDelegate <NSObject>
@optional

/// Called when a video frame is dropped (PTS not monotonic or writer not ready).
- (void)recordingEngineDidDropVideoFrame:(NSUInteger)totalDropCount;

/// Called when an audio sample is dropped.
- (void)recordingEngineDidDropAudioSample:(NSUInteger)totalDropCount;

/// Called when the engine encounters an unrecoverable AVAssetWriter error.
- (void)recordingEngineDidFailWithError:(NSError *)error;

@end

/// AVAssetWriter wrapper that encodes H.264 video + AAC audio to a single MP4 file.
///
/// Thread safety:
///   - All AVAssetWriter operations run on an internal serial `recordingQueue`.
///   - `appendVideoPixelBuffer:presentationTime:` and `appendAudioSampleBuffer:` may be
///     called from any thread — they dispatch_async to `recordingQueue`.
///   - Pause/resume/stop state is guarded by a lightweight `os_unfair_lock` (`_engineLock`).
///   - A stop drain gate ensures `finishWriting` runs after all pending appends complete.
///
/// PTS contract:
///   - Incoming PTS must be roughly monotonic per media type.
///   - Duplicate or out-of-order PTS (from thread scheduling jitter) are silently dropped
///     and counted via the drop counter / delegate.
///   - Paused intervals are subtracted from PTS so the output file is gap-free.
@interface InterRecordingEngine : NSObject

/// Whether the engine has started and not yet stopped.
@property (nonatomic, readonly) BOOL isRecording;

/// Whether recording is paused. Frames appended while paused are silently dropped.
@property (nonatomic, readonly) BOOL isPaused;

/// Elapsed recording time (excludes paused intervals).
@property (nonatomic, readonly) CMTime recordedDuration;

/// Total number of dropped video frames since recording started.
@property (nonatomic, readonly) NSUInteger droppedVideoFrameCount;

/// Total number of dropped audio samples since recording started.
@property (nonatomic, readonly) NSUInteger droppedAudioSampleCount;

/// Delegate for lifecycle and diagnostic callbacks (called on an arbitrary queue).
@property (nonatomic, weak) id<InterRecordingEngineDelegate> delegate;

/// Designated initializer.
///
/// @param outputURL      File URL for the output .mp4 file.
/// @param videoSize      Output resolution (e.g. 1920×1080).
/// @param frameRate      Target frame rate (e.g. 30).
/// @param channels       Audio channel count (1 = mono, 2 = stereo).
/// @param sampleRate     Audio sample rate in Hz (e.g. 48000.0).
- (instancetype)initWithOutputURL:(NSURL *)outputURL
                        videoSize:(CGSize)videoSize
                        frameRate:(int)frameRate
                    audioChannels:(int)channels
                  audioSampleRate:(double)sampleRate NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// Begin recording. Returns NO if the AVAssetWriter fails to start.
- (BOOL)startRecording;

/// Append a composited video frame.
///
/// May be called from any thread. Internally dispatches to `recordingQueue`.
/// The pixel buffer is retained until the append completes.
///
/// @param pixelBuffer     BGRA CVPixelBuffer (IOSurface-backed, Metal-compatible).
/// @param presentationTime  Presentation timestamp from `mach_absolute_time`-aligned clock.
- (void)appendVideoPixelBuffer:(CVPixelBufferRef)pixelBuffer
              presentationTime:(CMTime)presentationTime;

/// Append an audio sample buffer.
///
/// May be called from any thread. Internally dispatches to `recordingQueue`.
///
/// @param sampleBuffer     Audio CMSampleBuffer (PCM or AAC; AVAssetWriter handles conversion).
- (void)appendAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer;

/// Pause recording. Frames received while paused are silently dropped.
/// The pause interval is subtracted from output PTS to keep the file gap-free.
- (void)pauseRecording;

/// Resume recording after a pause.
- (void)resumeRecording;

/// Stop recording and finalize the output file.
///
/// Drains all pending appends on `recordingQueue` before calling `finishWriting`.
/// After this call returns (via the completion block), the engine cannot be restarted —
/// create a new instance for the next recording.
///
/// @param completion Called on an arbitrary queue with the output URL (or error).
- (void)stopRecordingWithCompletion:(void (^)(NSURL * _Nullable outputURL,
                                              NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
