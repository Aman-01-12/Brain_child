#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Network quality level mapped from LiveKit connection quality.
typedef NS_ENUM(NSUInteger, InterNetworkQualityLevel) {
    InterNetworkQualityLevelUnknown  = 0,  // 0 bars, gray
    InterNetworkQualityLevelLost     = 1,  // 1 bar, red
    InterNetworkQualityLevelPoor     = 2,  // 2 bars, orange
    InterNetworkQualityLevelGood     = 3,  // 3 bars, yellow-green
    InterNetworkQualityLevelExcellent = 4  // 4 bars, green
};

/// Compact signal-bars view that displays network quality.
///
/// Custom `drawRect:` draws 4 vertical bars with progressive heights.
/// Filled bars count corresponds to the quality level.
/// Color coding: green (4), yellow-green (3), orange (2), red (1), gray (0).
///
/// Intrinsic size: 40×16.
@interface InterNetworkStatusView : NSView

/// Update the displayed quality level. Thread-safe on main queue.
- (void)setQualityLevel:(InterNetworkQualityLevel)level;

@end

NS_ASSUME_NONNULL_END
