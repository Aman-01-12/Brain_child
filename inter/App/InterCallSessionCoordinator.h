#import <Foundation/Foundation.h>

#import "AppDelegate.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, InterCallSessionPhase) {
    InterCallSessionPhaseIdle = 0,
    InterCallSessionPhaseEntering,
    InterCallSessionPhaseActive,
    InterCallSessionPhaseExiting
};

@interface InterCallSessionCoordinator : NSObject

@property (nonatomic, readonly) InterCallSessionPhase phase;
@property (nonatomic, readonly) InterCallMode currentCallMode;
@property (nonatomic, readonly) InterInterviewRole currentInterviewRole;

- (BOOL)beginEnteringMode:(InterCallMode)mode role:(InterInterviewRole)role;
- (void)markActive;
- (BOOL)beginExit;
- (void)finishExit;
- (void)cancelExitIfNeeded;

@end

NS_ASSUME_NONNULL_END
