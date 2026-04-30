#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class InterRoomController;
@class InterChatController;

@interface SecureWindowController : NSObject

@property (nonatomic, strong, nullable) NSWindow *secureWindow;
@property (nonatomic, copy, nullable) dispatch_block_t exitSessionHandler;

/// [2.6.1] Weak reference to room controller for network wiring.
/// Set by AppDelegate before createSecureWindow is called.
@property (nonatomic, weak, nullable) InterRoomController *roomController;

/// Chat controller for in-session messaging. Set by AppDelegate after attach.
@property (nonatomic, weak, nullable) InterChatController *chatController;

- (void)createSecureWindow;
- (void)destroySecureWindow;

/// Immediately hide the secure window without tearing down room/media objects.
- (void)hideSecureWindow;

@end

NS_ASSUME_NONNULL_END
