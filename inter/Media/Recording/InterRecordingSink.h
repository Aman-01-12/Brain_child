#import <Foundation/Foundation.h>

#import "InterShareSink.h"

@class InterComposedRenderer;
@class InterRecordingEngine;

NS_ASSUME_NONNULL_BEGIN

/// Recording sink that conforms to the InterShareSink protocol.
///
/// Receives screen share frames and audio samples from InterSurfaceShareController's
/// routing pipeline. Feeds video frames to InterComposedRenderer (as the screen share
/// source) and audio samples to InterRecordingEngine.
///
/// Thread safety:
///   - `appendVideoFrame:` and `appendAudioSampleBuffer:` may be called from the
///     router queue (`_routerQueue` on InterSurfaceShareController).
///   - `_sinkLock` (os_unfair_lock) guards the `_isActive` flag, matching the
///     existing InterShareSink contract.
///   - The sink MUST be started before frames flow and stopped before dealloc.
@interface InterRecordingSink : NSObject <InterShareSink>

/// The composed renderer that receives screen share frames. Set before starting.
@property (nonatomic, weak, nullable) InterComposedRenderer *composedRenderer;

/// The recording engine that receives audio sample buffers. Set before starting.
@property (nonatomic, weak, nullable) InterRecordingEngine *recordingEngine;

- (instancetype)init NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END
