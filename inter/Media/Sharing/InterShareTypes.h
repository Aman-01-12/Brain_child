#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, InterShareMode) {
    InterShareModeThisApp = 0,
    InterShareModeWindow,
    InterShareModeEntireScreen
};

typedef NS_ENUM(NSUInteger, InterShareSessionKind) {
    InterShareSessionKindInterview = 0,
    InterShareSessionKindNormal
};

FOUNDATION_EXPORT NSErrorDomain const InterShareErrorDomain;

typedef NS_ERROR_ENUM(InterShareErrorDomain, InterShareErrorCode) {
    InterShareErrorCodeInvalidConfiguration = 1001,
    InterShareErrorCodeUnsupportedMode = 1002,
    InterShareErrorCodeNotImplemented = 1003,
    InterShareErrorCodeRecordingUnavailable = 1004
};

@interface InterShareSessionConfiguration : NSObject <NSCopying>

@property (nonatomic, assign) InterShareSessionKind sessionKind;
@property (nonatomic, assign) InterShareMode shareMode;
@property (nonatomic, assign, getter=isRecordingEnabled) BOOL recordingEnabled;
@property (nonatomic, assign, getter=isNetworkPublishEnabled) BOOL networkPublishEnabled;

/// For InterShareModeWindow — the CGWindowID (as string) chosen by the user
/// in the window picker. When nil, the capture source picks the first
/// available non-own window.
@property (nonatomic, copy, nullable) NSString *selectedWindowIdentifier;

+ (instancetype)defaultConfiguration;

@end

NS_ASSUME_NONNULL_END
