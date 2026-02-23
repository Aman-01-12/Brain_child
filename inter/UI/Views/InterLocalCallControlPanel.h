#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface InterLocalCallControlPanel : NSView

@property (nonatomic, copy, nullable) dispatch_block_t cameraToggleHandler;
@property (nonatomic, copy, nullable) dispatch_block_t microphoneToggleHandler;
@property (nonatomic, copy, nullable) dispatch_block_t shareToggleHandler;

@property (nonatomic, strong, readonly) NSView *previewContainerView;

- (void)setPanelTitleText:(NSString *)title;
- (void)setCameraEnabled:(BOOL)enabled;
- (void)setMicrophoneEnabled:(BOOL)enabled;
- (void)setSharingEnabled:(BOOL)enabled;
- (void)setMediaStatusText:(NSString *)text;
- (void)setShareStatusText:(NSString *)text;

@end

NS_ASSUME_NONNULL_END
