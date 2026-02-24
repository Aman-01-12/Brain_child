#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface SecureWindowController : NSObject

@property (nonatomic, strong, nullable) NSWindow *secureWindow;
@property (nonatomic, copy, nullable) dispatch_block_t exitSessionHandler;

- (void)createSecureWindow;
- (void)destroySecureWindow;

@end

NS_ASSUME_NONNULL_END
