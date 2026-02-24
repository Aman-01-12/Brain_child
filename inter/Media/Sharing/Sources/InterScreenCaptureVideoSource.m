#import "InterScreenCaptureVideoSource.h"

#import <CoreGraphics/CoreGraphics.h>

#import "InterShareTypes.h"

@implementation InterScreenCaptureVideoSource {
    BOOL _running;
    InterShareVideoSourceFrameHandler _frameHandler;
    InterShareVideoSourceErrorHandler _errorHandler;
}

@synthesize frameHandler = _frameHandler;
@synthesize errorHandler = _errorHandler;

+ (BOOL)preflightScreenCaptureAccess {
    if (@available(macOS 10.15, *)) {
        return CGPreflightScreenCaptureAccess();
    }
    return NO;
}

+ (BOOL)requestScreenCaptureAccessIfNeeded {
    if (@available(macOS 10.15, *)) {
        if (CGPreflightScreenCaptureAccess()) {
            return YES;
        }
        return CGRequestScreenCaptureAccess();
    }
    return NO;
}

- (BOOL)isRunning {
    return _running;
}

- (NSArray<NSString *> *)availableDisplayIdentifiers {
    CGDirectDisplayID displays[64];
    uint32_t displayCount = 0;
    CGError error = CGGetOnlineDisplayList((uint32_t)(sizeof(displays) / sizeof(displays[0])),
                                           displays,
                                           &displayCount);
    if (error != kCGErrorSuccess || displayCount == 0) {
        return @[];
    }

    NSMutableArray<NSString *> *identifiers = [NSMutableArray arrayWithCapacity:displayCount];
    for (uint32_t index = 0; index < displayCount; index += 1) {
        [identifiers addObject:[NSString stringWithFormat:@"%u", displays[index]]];
    }
    return [identifiers copy];
}

- (NSArray<NSString *> *)availableWindowIdentifiers {
    CFArrayRef windowInfoRef = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly |
                                                           kCGWindowListExcludeDesktopElements,
                                                           kCGNullWindowID);
    if (!windowInfoRef) {
        return @[];
    }

    NSArray<NSDictionary *> *windowInfoList = CFBridgingRelease(windowInfoRef);
    NSMutableOrderedSet<NSString *> *identifiers = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *windowInfo in windowInfoList) {
        NSNumber *windowLayer = windowInfo[(id)kCGWindowLayer];
        if (windowLayer && windowLayer.integerValue != 0) {
            continue;
        }

        NSNumber *windowNumber = windowInfo[(id)kCGWindowNumber];
        if (!windowNumber) {
            continue;
        }

        [identifiers addObject:windowNumber.stringValue];
    }

    return identifiers.array;
}

- (void)start {
    [self startWithNotImplementedError];
}

- (void)startCaptureForSelectedDisplay {
    if (self.selectedDisplayIdentifier.length == 0) {
        InterShareVideoSourceErrorHandler errorHandler = self.errorHandler;
        if (errorHandler) {
            NSError *error = [NSError errorWithDomain:InterShareErrorDomain
                                                 code:InterShareErrorCodeInvalidConfiguration
                                             userInfo:@{NSLocalizedDescriptionKey: @"No display selected for capture."}];
            errorHandler(error);
        }
        return;
    }
    [self startWithNotImplementedError];
}

- (void)startCaptureForSelectedWindow {
    if (self.selectedWindowIdentifier.length == 0) {
        InterShareVideoSourceErrorHandler errorHandler = self.errorHandler;
        if (errorHandler) {
            NSError *error = [NSError errorWithDomain:InterShareErrorDomain
                                                 code:InterShareErrorCodeInvalidConfiguration
                                             userInfo:@{NSLocalizedDescriptionKey: @"No window selected for capture."}];
            errorHandler(error);
        }
        return;
    }
    [self startWithNotImplementedError];
}

- (void)startWithNotImplementedError {
    _running = NO;
    InterShareVideoSourceErrorHandler errorHandler = self.errorHandler;
    if (!errorHandler) {
        return;
    }

    NSError *error = [NSError errorWithDomain:InterShareErrorDomain
                                         code:InterShareErrorCodeNotImplemented
                                     userInfo:@{NSLocalizedDescriptionKey: @"Window and full-screen sharing will be enabled in the next ScreenCaptureKit phase."}];
    errorHandler(error);
}

- (void)stop {
    _running = NO;
}

@end
