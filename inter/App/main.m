#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"

int main(int argc, const char * argv[]) {
#pragma unused(argc)
#pragma unused(argv)
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];

        // Keep delegate alive for the full app lifetime in code-driven startup.
        static AppDelegate *delegate = nil;
        delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;

        [app run];
    }
    return 0;
}
