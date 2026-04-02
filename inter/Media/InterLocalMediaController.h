#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^InterLocalMediaPrepareCompletion)(BOOL success, NSString * _Nullable failureReason);
typedef void (^InterLocalMediaAudioSampleBufferHandler)(CMSampleBufferRef sampleBuffer);
typedef void (^InterLocalMediaVideoFrameObserver)(CVPixelBufferRef pixelBuffer);

@interface InterLocalMediaController : NSObject

@property (atomic, readonly, getter=isConfigured) BOOL configured;
@property (atomic, readonly, getter=isRunning) BOOL running;
@property (atomic, readonly, getter=isCameraEnabled) BOOL cameraEnabled;
@property (atomic, readonly, getter=isMicrophoneEnabled) BOOL microphoneEnabled;
@property (nonatomic, copy, nullable) InterLocalMediaAudioSampleBufferHandler audioSampleBufferHandler;
@property (nonatomic, copy, nullable) dispatch_block_t audioInputOptionsChangedHandler;

/// [Phase 10] Observer block for local camera video frames (CVPixelBuffer).
/// When non-nil, an AVCaptureVideoDataOutput is added to the capture session
/// to deliver BGRA pixel buffers. Used by the recording coordinator when the
/// local user is the active speaker (camera PiP in composed recording).
/// Set to nil to stop video frame delivery and remove the data output.
/// Atomic: written on _sessionQueue, read on _videoFrameOutputQueue.
@property (atomic, copy, nullable) InterLocalMediaVideoFrameObserver recordingFrameObserver;

/// The underlying AVCaptureSession. Callers MUST use sessionQueue for all
/// session-related work. Callers MUST NOT call startRunning/stopRunning.
@property (nonatomic, readonly, nullable) AVCaptureSession *captureSession;

/// The serial dispatch queue that guards the capture session.
/// All external interaction with captureSession MUST be dispatched on this queue.
@property (nonatomic, readonly, nullable) dispatch_queue_t sessionQueue;

+ (void)preflightCapturePermissionsWithCompletion:(void (^ _Nullable)(AVAuthorizationStatus videoStatus,
                                                                      AVAuthorizationStatus audioStatus))completion;

- (void)prepareWithCompletion:(InterLocalMediaPrepareCompletion)completion;
- (void)start;
- (void)stop;
- (void)shutdown;

- (void)setCameraEnabled:(BOOL)enabled completion:(void (^ _Nullable)(BOOL success))completion;
- (void)setMicrophoneEnabled:(BOOL)enabled completion:(void (^ _Nullable)(BOOL success))completion;

/// Returns available audio input devices as dictionaries: { "id", "name" }.
- (NSArray<NSDictionary<NSString *, NSString *> *> *)availableAudioInputOptions;

/// Currently selected (or preferred) audio input device ID.
- (nullable NSString *)selectedAudioInputDeviceID;

/// Explicitly select an audio input device by unique ID.
- (void)selectAudioInputDeviceWithID:(nullable NSString *)deviceID
                          completion:(void (^ _Nullable)(BOOL success))completion;

/// Store a preferred audio device ID without reconfiguring the capture session.
/// Use this when the session is actively capturing video and you want to avoid
/// the momentary interruption caused by beginConfiguration/commitConfiguration.
/// The stored preference will be applied on the next selectAudioInputDeviceWithID:
/// call or session reconfiguration.
- (void)storePreferredAudioDeviceID:(nullable NSString *)deviceID;

- (void)attachPreviewToView:(NSView *)view;
- (void)detachPreview;

@end

NS_ASSUME_NONNULL_END
