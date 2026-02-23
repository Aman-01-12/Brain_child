#import "SecureWindowController.h"
#import "AppDelegate.h"
#import "MetalSurfaceView.h"
#import "SecureWindow.h"


@interface SecureWindowController ()
@property (nonatomic, strong) MetalSurfaceView *renderView;
@end

@implementation SecureWindowController

- (void)createSecureWindow {

    NSScreen *screen = [NSScreen mainScreen];
    if (!screen) {
        return;
    }

    self.secureWindow =
    [[SecureWindow alloc] initWithContentRect:screen.frame
                                styleMask:NSWindowStyleMaskBorderless
                                  backing:NSBackingStoreBuffered
                                    defer:NO];

    [self.secureWindow setLevel:NSScreenSaverWindowLevel];
    [self.secureWindow setOpaque:YES];
    [self.secureWindow setBackgroundColor:[NSColor grayColor]];
    [self.secureWindow setSharingType:NSWindowSharingNone];
    [self.secureWindow setMovable:NO];
    [self.secureWindow setReleasedWhenClosed:NO];
    [self.secureWindow setHidesOnDeactivate:NO];

    NSRect contentFrame = NSMakeRect(0, 0, screen.frame.size.width, screen.frame.size.height);
    NSView *view = [[NSView alloc] initWithFrame:contentFrame];
    [view setWantsLayer:YES];
    [self.secureWindow setContentView:view];

    self.renderView = [[MetalSurfaceView alloc] initWithFrame:view.bounds];
    self.renderView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [view addSubview:self.renderView];

    NSTextField *headline = [NSTextField labelWithString:@"Interview secure surface (Metal)"];
    headline.frame = NSMakeRect(40, view.bounds.size.height - 52, 340, 24);
    headline.font = [NSFont boldSystemFontOfSize:15];
    headline.textColor = [NSColor colorWithWhite:0.92 alpha:1.0];
    headline.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [view addSubview:headline];

    NSButton *exitButton =
    [[NSButton alloc] initWithFrame:NSMakeRect(40, 40, 140, 45)];

    [exitButton setTitle:@"Exit Session"];
    [exitButton setTarget:self];
    [exitButton setAction:@selector(exitSession)];

    [view addSubview:exitButton];
    [self.secureWindow makeKeyAndOrderFront:nil];
}

- (void)exitSession {
    AppDelegate *delegate = (AppDelegate *)NSApp.delegate;
    [delegate exitCurrentMode];
}

- (void)destroySecureWindow {
    [self.renderView removeFromSuperview];
    self.renderView = nil;

    [self.secureWindow orderOut:nil];
    self.secureWindow = nil;
}

@end
