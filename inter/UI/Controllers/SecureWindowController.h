#import <Cocoa/Cocoa.h>

@interface SecureWindowController : NSObject

@property (nonatomic, strong) NSWindow *secureWindow;

- (void)createSecureWindow;
- (void)destroySecureWindow;

@end
