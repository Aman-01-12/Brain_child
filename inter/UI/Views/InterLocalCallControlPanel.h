#import <Cocoa/Cocoa.h>

#import "InterShareTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface InterLocalCallControlPanel : NSView

@property (nonatomic, copy, nullable) dispatch_block_t cameraToggleHandler;
@property (nonatomic, copy, nullable) dispatch_block_t microphoneToggleHandler;
@property (nonatomic, copy, nullable) dispatch_block_t shareToggleHandler;
@property (nonatomic, copy, nullable) void (^shareModeChangedHandler)(InterShareMode shareMode);

@property (nonatomic, strong, readonly) NSView *previewContainerView;

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
