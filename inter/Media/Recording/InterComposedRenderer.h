#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/// Layout mode for the composed recording output.
///
/// The layout is automatically recomputed whenever a video source is
/// added, removed, or changes (e.g., screen share starts/stops mid-call).
/// See §5 of recording_architecture.md for the full layout decision table.
typedef NS_ENUM(NSInteger, InterComposedLayout) {
    /// No video sources available — dark background + "Recording..." text.
    InterComposedLayoutIdle = 0,
    /// Single camera, no screen share — fullscreen.
    InterComposedLayoutCameraOnlyFull,
    /// Two cameras, no screen share — 50/50 side-by-side split.
    InterComposedLayoutCameraSideBySide,
    /// Screen share (main) + active speaker camera PiP (bottom-right).
    InterComposedLayoutScreenSharePiP,
    /// Screen share only — no active speaker camera available.
    InterComposedLayoutScreenShareOnly,
};

/// Delegate notified of layout changes (for logging / UI indicators).
@protocol InterComposedRendererDelegate <NSObject>
@optional
- (void)composedRenderer:(id)renderer didChangeLayout:(InterComposedLayout)newLayout;
@end

/// Metal offscreen compositor that combines multiple video sources into a single
/// 1920×1080 (or configurable) CVPixelBuffer suitable for AVAssetWriter.
///
/// Thread safety:
///   - Frame updates (`updateScreenShareFrame:`, `updateActiveSpeakerFrame:identity:`, etc.)
///     may be called from **any** thread.
///   - `renderComposedFrame` must be called from a single serial queue (the render timer queue).
///   - All mutable frame state is guarded by `_frameLock` (os_unfair_lock).
///   - Metal rendering happens **outside** the lock on retained copies (snapshot-under-lock).
///   - CVPixelBuffer pool uses triple-buffering with GPU completion fencing.
///
/// This matches the existing patterns in InterRemoteVideoView (os_unfair_lock +
/// pendingPixelBuffer) and InterSurfaceShareController (_stateLock + sink snapshot).
@interface InterComposedRenderer : NSObject

/// Current layout (read-only). KVO-observable. Updated on every frame source change.
@property (nonatomic, readonly) InterComposedLayout currentLayout;

/// Whether the watermark overlay is rendered (Free tier only).
@property (nonatomic) BOOL watermarkEnabled;

/// Delegate for layout change notifications.
@property (nonatomic, weak) id<InterComposedRendererDelegate> delegate;

/// Designated initializer.
///
/// @param device        Metal device (from MetalRenderEngine.sharedEngine.device).
/// @param commandQueue  Metal command queue (from MetalRenderEngine.sharedEngine.commandQueue).
/// @param outputSize    Output resolution (e.g. {1920, 1080}).
- (instancetype)initWithDevice:(id<MTLDevice>)device
                  commandQueue:(id<MTLCommandQueue>)commandQueue
                    outputSize:(CGSize)outputSize NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// Update the screen share pixel buffer. Thread-safe — may be called from any thread.
/// Passing NULL clears the screen share source and triggers layout recalculation.
- (void)updateScreenShareFrame:(CVPixelBufferRef _Nullable)pixelBuffer;

/// Update the active speaker (primary) camera frame. Thread-safe.
/// @param pixelBuffer  Latest camera frame (NULL to clear).
/// @param identity     Participant identity for name overlay / placeholder.
- (void)updateActiveSpeakerFrame:(CVPixelBufferRef _Nullable)pixelBuffer
                        identity:(NSString * _Nullable)identity;

/// Update a secondary speaker camera frame (for side-by-side layout). Thread-safe.
/// @param pixelBuffer  Latest camera frame (NULL to clear).
/// @param identity     Participant identity.
- (void)updateSecondarySpeakerFrame:(CVPixelBufferRef _Nullable)pixelBuffer
                           identity:(NSString * _Nullable)identity;

/// Generate (or return cached) placeholder frame for an audio-only participant.
/// Thread-safe — caches per identity. Dark background with the participant's name.
- (CVPixelBufferRef _Nonnull)placeholderFrameForIdentity:(NSString *)identity;

/// Render one composed frame from the current video sources.
///
/// Returns an IOSurface-backed CVPixelBuffer from the internal triple-buffer pool.
/// The GPU has completed rendering before this method returns (waitUntilCompleted).
///
/// Must be called from the render timer serial queue only.
- (CVPixelBufferRef _Nullable)renderComposedFrame;

/// Release all Metal resources and pixel buffer pool. Called during teardown.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
