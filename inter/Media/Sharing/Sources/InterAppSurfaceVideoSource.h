#import <Foundation/Foundation.h>

#import "InterShareVideoSource.h"
#import "MetalSurfaceView.h"

NS_ASSUME_NONNULL_BEGIN

@interface InterAppSurfaceVideoSource : NSObject <InterShareVideoSource>

- (instancetype)initWithSurfaceView:(MetalSurfaceView *)surfaceView NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
