#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// A compact "● REC 00:05:23" indicator view for display during active recording.
///
/// Shows a pulsing red dot, "REC" label, and elapsed-time counter.
/// Designed to be placed in the top-right area of the meeting window
/// (next to the existing network status view).
///
/// Thread safety: all methods must be called on the main thread.
@interface InterRecordingIndicatorView : NSView

/// Whether the indicator is visible and animating. Default is NO.
@property (nonatomic, getter=isIndicatorActive) BOOL indicatorActive;

/// Whether recording is paused (shows "PAUSED" instead of pulsing dot).
@property (nonatomic, getter=isIndicatorPaused) BOOL indicatorPaused;

/// Update the elapsed time display.
/// @param duration  Elapsed recording time in seconds (excluding paused intervals).
- (void)setElapsedDuration:(NSTimeInterval)duration;

@end

NS_ASSUME_NONNULL_END
