#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^InterLocalMediaPrepareCompletion)(BOOL success, NSString * _Nullable failureReason);
typedef void (^InterLocalMediaAudioSampleBufferHandler)(CMSampleBufferRef sampleBuffer);

@interface InterLocalMediaController : NSObject

@property (atomic, readonly, getter=isConfigured) BOOL configured;
@property (atomic, readonly, getter=isRunning) BOOL running;
@property (atomic, readonly, getter=isCameraEnabled) BOOL cameraEnabled;
@property (atomic, readonly, getter=isMicrophoneEnabled) BOOL microphoneEnabled;
@property (nonatomic, copy, nullable) InterLocalMediaAudioSampleBufferHandler audioSampleBufferHandler;

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

- (void)attachPreviewToView:(NSView *)view;
- (void)detachPreview;

@end

NS_ASSUME_NONNULL_END
