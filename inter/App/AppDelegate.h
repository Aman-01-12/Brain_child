#import <Cocoa/Cocoa.h>

typedef NS_ENUM(NSUInteger, InterCallMode) {
    InterCallModeNone = 0,
    InterCallModeNormal,
    InterCallModeInterview
};

typedef NS_ENUM(NSUInteger, InterInterviewRole) {
    InterInterviewRoleNone = 0,
    InterInterviewRoleInterviewer,
    InterInterviewRoleInterviewee
};

@interface AppDelegate : NSObject <NSApplicationDelegate>

@property (nonatomic, readonly) InterCallMode currentCallMode;
@property (nonatomic, readonly) InterInterviewRole currentInterviewRole;

- (void)startNormalCallMode;
- (void)createInterviewAsInterviewer;
- (void)joinInterviewAsInterviewee;
- (void)enterInterviewMode;
- (void)exitCurrentMode;
- (void)exitInterviewMode;

@end
