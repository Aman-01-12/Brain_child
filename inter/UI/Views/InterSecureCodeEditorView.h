#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface InterSecureCodeEditorView : NSView

@property (nonatomic, strong, readonly) NSTextView *textView;

- (void)focusTextEditor;

@end

NS_ASSUME_NONNULL_END
