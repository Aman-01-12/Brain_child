#import <Cocoa/Cocoa.h>

#import "InterShareTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface InterLocalCallControlPanel : NSView

@property (nonatomic, copy, nullable) dispatch_block_t cameraToggleHandler;
@property (nonatomic, copy, nullable) dispatch_block_t microphoneToggleHandler;
@property (nonatomic, copy, nullable) dispatch_block_t shareToggleHandler;
@property (nonatomic, copy, nullable) void (^shareModeChangedHandler)(InterShareMode shareMode);

@property (nonatomic, strong, readonly) NSView *previewContainerView;

/// [3.4.1] Connection status label — bound to InterRoomConnectionState text.
- (void)setConnectionStatusText:(NSString *)text;

/// [3.4.2] [G7] Show room code when hosting. Pass nil to hide.
- (void)setRoomCodeText:(nullable NSString *)code;

/// [3.4.4] Container view for the network quality indicator.
@property (nonatomic, strong, readonly) NSView *networkStatusContainerView;

- (void)setPanelTitleText:(NSString *)title;
- (void)setCameraEnabled:(BOOL)enabled;
- (void)setMicrophoneEnabled:(BOOL)enabled;
- (void)setSharingEnabled:(BOOL)enabled;
- (void)setMediaStatusText:(NSString *)text;
- (void)setShareStatusText:(NSString *)text;
- (void)setShareMode:(InterShareMode)shareMode;
- (InterShareMode)selectedShareMode;
- (void)setShareModeOptionEnabled:(BOOL)enabled forMode:(InterShareMode)shareMode;
- (void)setShareModeSelectorHidden:(BOOL)hidden;

@end

NS_ASSUME_NONNULL_END
