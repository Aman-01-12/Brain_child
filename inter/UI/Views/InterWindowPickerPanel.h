#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^InterWindowPickerCompletion)(NSString * _Nullable selectedWindowIdentifier);

/// A modal-sheet window picker panel that shows live thumbnails of all
/// on-screen windows, letting the user select which one to share.
/// Designed to match the Google Meet / Zoom "Choose what to share" experience.
@interface InterWindowPickerPanel : NSPanel

/// Present the picker as a sheet on `parentWindow`. On selection the
/// completion is called with the window identifier string (CGWindowID as
/// NSString). On cancel, nil is passed.
+ (void)showPickerRelativeToWindow:(NSWindow *)parentWindow
                        completion:(InterWindowPickerCompletion)completion;

@end

NS_ASSUME_NONNULL_END
