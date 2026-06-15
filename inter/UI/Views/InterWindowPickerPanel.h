#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^InterWindowPickerCompletion)(NSString * _Nullable selectedWindowIdentifier);

/// Unified picker completion: `isDisplay` distinguishes an entire-screen pick
/// (identifier = CGDirectDisplayID string) from a window pick (CGWindowID
/// string). `shareSystemAudio` carries the in-picker audio toggle. identifier
/// nil = cancelled.
typedef void (^InterSharePickerCompletion)(BOOL isDisplay,
                                           NSString * _Nullable identifier,
                                           BOOL shareSystemAudio);

/// A modal-sheet share picker showing live thumbnails of every display
/// ("Entire Screen") and shareable window, with a "Share system audio"
/// toggle. Designed to match the Google Meet / Zoom "Choose what to share"
/// experience.
@interface InterWindowPickerPanel : NSPanel

/// Legacy windows-only picker (kept for existing call sites).
+ (void)showPickerRelativeToWindow:(NSWindow *)parentWindow
                        completion:(InterWindowPickerCompletion)completion;

/// Unified picker: entire-screen tiles + window grid + system-audio toggle.
+ (void)showUnifiedPickerRelativeToWindow:(NSWindow *)parentWindow
                            systemAudioOn:(BOOL)systemAudioOn
                               completion:(InterSharePickerCompletion)completion;

@end

NS_ASSUME_NONNULL_END
