#import <Foundation/Foundation.h>

#import "MetalSurfaceView.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^InterSurfaceShareStatusHandler)(NSString *statusText);

@interface InterSurfaceShareController : NSObject

@property (atomic, readonly, getter=isSharing) BOOL sharing;
@property (nonatomic, copy, nullable) InterSurfaceShareStatusHandler statusHandler;

- (void)startSharingFromSurfaceView:(MetalSurfaceView *)surfaceView;
- (void)stopSharingFromSurfaceView:(nullable MetalSurfaceView *)surfaceView;

@end

NS_ASSUME_NONNULL_END
