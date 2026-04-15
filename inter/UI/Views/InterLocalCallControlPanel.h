#import <Cocoa/Cocoa.h>

#import "InterInterviewToolTypes.h"
#import "InterShareTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface InterLocalCallControlPanel : NSView

@property (nonatomic, copy, nullable) dispatch_block_t cameraToggleHandler;
@property (nonatomic, copy, nullable) dispatch_block_t microphoneToggleHandler;
@property (nonatomic, copy, nullable) dispatch_block_t shareToggleHandler;
@property (nonatomic, copy, nullable) void (^shareModeChangedHandler)(InterShareMode shareMode);
@property (nonatomic, copy, nullable) void (^audioInputSelectionChangedHandler)(NSString * _Nullable deviceID);
@property (nonatomic, copy, nullable) void (^shareSystemAudioChangedHandler)(BOOL enabled);
@property (nonatomic, copy, nullable) void (^interviewToolChangedHandler)(InterInterviewToolKind toolKind);
@property (nonatomic, copy, nullable) dispatch_block_t recordToggleHandler;
@property (nonatomic, copy, nullable) dispatch_block_t viewRecordingsHandler;

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

/// Set a custom microphone button title. Pass nil to restore the default
/// state-based title ("Turn Mic On" / "Turn Mic Off").
- (void)setMicrophoneButtonTitle:(nullable NSString *)title;
- (void)setSharingEnabled:(BOOL)enabled;
- (void)setShareStartPending:(BOOL)pending;
- (void)setMediaStatusText:(NSString *)text;
- (void)setShareStatusText:(NSString *)text;
- (void)setShareMode:(InterShareMode)shareMode;
- (InterShareMode)selectedShareMode;
- (void)setShareModeOptionEnabled:(BOOL)enabled forMode:(InterShareMode)shareMode;
- (void)setShareModeSelectorHidden:(BOOL)hidden;
- (void)setShareSystemAudioEnabled:(BOOL)enabled;
- (void)setShareSystemAudioToggleHidden:(BOOL)hidden;
- (void)setInterviewToolSelectorHidden:(BOOL)hidden;
- (void)setSelectedInterviewToolKind:(InterInterviewToolKind)toolKind;
- (InterInterviewToolKind)selectedInterviewToolKind;

/// Populate the microphone source selector.
/// Expected dictionary keys in `options`: @"id", @"name".
- (void)setAudioInputOptions:(NSArray<NSDictionary<NSString *, NSString *> *> *)options
			selectedDeviceID:(nullable NSString *)selectedDeviceID;

/// Update the recording button title and state.
- (void)setRecordingActive:(BOOL)active;
- (void)setRecordingButtonHidden:(BOOL)hidden;

/// [Phase 10 R2] Show or hide the "View Recordings" button.
- (void)setViewRecordingsButtonHidden:(BOOL)hidden;

@end

NS_ASSUME_NONNULL_END
