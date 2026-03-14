#import <Foundation/Foundation.h>

#import "InterShareVideoSource.h"

NS_ASSUME_NONNULL_BEGIN

@interface InterScreenCaptureVideoSource : NSObject <InterShareVideoSource>

@property (nonatomic, copy, nullable) NSString *selectedDisplayIdentifier;
@property (nonatomic, copy, nullable) NSString *selectedWindowIdentifier;
@property (nonatomic, assign, getter=isCaptureSystemAudioEnabled) BOOL captureSystemAudioEnabled;

+ (BOOL)preflightScreenCaptureAccess;
+ (BOOL)requestScreenCaptureAccessIfNeeded;

- (NSArray<NSString *> *)availableDisplayIdentifiers;
- (NSArray<NSString *> *)availableWindowIdentifiers;

- (void)startCaptureForSelectedDisplay;
- (void)startCaptureForSelectedWindow;

@end

NS_ASSUME_NONNULL_END
