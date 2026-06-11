//
//  InterWindowSecurity.m
//  inter
//

#import "InterWindowSecurity.h"

BOOL InterCaptureProtectionDisabled(void) {
#if DEBUG
    static BOOL disabled = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *args = [[NSProcessInfo processInfo] arguments];
        NSDictionary<NSString *, NSString *> *env = [[NSProcessInfo processInfo] environment];
        disabled = [args containsObject:@"--disable-capture-protection"]
                || [env[@"INTER_DISABLE_CAPTURE_PROTECTION"] isEqualToString:@"1"];
        if (disabled) {
            NSLog(@"⚠️ [InterSecurity] CAPTURE PROTECTION DISABLED (DEBUG + dev flag) — app windows "
                  @"are screen-recordable. This is a TEMPORARY dev affordance for UI capture; it "
                  @"is impossible in Release builds. Do NOT use for real interviews.");
        }
    });
    return disabled;
#else
    return NO;
#endif
}

NSWindowSharingType InterWindowSharingType(void) {
    return InterCaptureProtectionDisabled() ? NSWindowSharingReadOnly : NSWindowSharingNone;
}
