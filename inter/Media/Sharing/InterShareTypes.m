#import "InterShareTypes.h"

NSErrorDomain const InterShareErrorDomain = @"secure.inter.share";

@implementation InterShareSessionConfiguration

+ (instancetype)defaultConfiguration {
    InterShareSessionConfiguration *configuration = [[InterShareSessionConfiguration alloc] init];
    configuration.sessionKind = InterShareSessionKindNormal;
    configuration.shareMode = InterShareModeThisApp;
    configuration.recordingEnabled = YES;
    return configuration;
}

- (id)copyWithZone:(NSZone *)zone {
#pragma unused(zone)
    InterShareSessionConfiguration *copy = [[InterShareSessionConfiguration alloc] init];
    copy.sessionKind = self.sessionKind;
    copy.shareMode = self.shareMode;
    copy.recordingEnabled = self.isRecordingEnabled;
    return copy;
}

@end
