#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class InterRoomController;

@interface SecureWindowController : NSObject

@property (nonatomic, strong, nullable) NSWindow *secureWindow;
@property (nonatomic, copy, nullable) dispatch_block_t exitSessionHandler;

/// [2.6.1] Weak reference to room controller for network wiring.
/// Set by AppDelegate before createSecureWindow is called.
@property (nonatomic, weak, nullable) InterRoomController *roomController;

- (void)createSecureWindow;
- (void)destroySecureWindow;

@end

NS_ASSUME_NONNULL_END
