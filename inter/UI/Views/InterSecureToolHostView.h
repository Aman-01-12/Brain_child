#import <Cocoa/Cocoa.h>

#import "InterInterviewToolTypes.h"

NS_ASSUME_NONNULL_BEGIN

@class InterSecureCodeEditorView;
@class InterSecureWhiteboardView;

@interface InterSecureToolHostView : NSView

@property (nonatomic, assign, readonly) InterInterviewToolKind activeToolKind;
@property (nonatomic, strong, readonly) InterSecureCodeEditorView *codeEditorView;
@property (nonatomic, strong, readonly) InterSecureWhiteboardView *whiteboardView;

- (void)setActiveToolKind:(InterInterviewToolKind)toolKind;
- (void)activateActiveToolResponder;

@end

NS_ASSUME_NONNULL_END
