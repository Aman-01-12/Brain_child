#import <AppKit/AppKit.h>

#import "InterShareVideoSource.h"

NS_ASSUME_NONNULL_BEGIN

@interface InterViewSnapshotVideoSource : NSObject <InterShareVideoSource>

- (instancetype)initWithCapturedView:(NSView *)capturedView NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
