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
