#import <Cocoa/Cocoa.h>

#import "InterInterviewToolTypes.h"

NS_ASSUME_NONNULL_BEGIN

@class InterSecureCodeEditorView;
@class InterSecureWhiteboardView;
@class InterRoomController;

@interface InterSecureToolHostView : NSView

@property (nonatomic, assign, readonly) InterInterviewToolKind activeToolKind;
@property (nonatomic, strong, readonly) InterSecureCodeEditorView *codeEditorView;
@property (nonatomic, strong, readonly) InterSecureWhiteboardView *whiteboardView;

- (void)setActiveToolKind:(InterInterviewToolKind)toolKind;
- (void)activateActiveToolResponder;

/// Stand up the collaborative code editor for the session and wire it to the
/// LiveKit DataChannel via `roomController` (forwards to the owned
/// `InterSecureToolsBridge`). Call once the room is connected so the local
/// attested identity is available. Teardown happens automatically in `dealloc`
/// via `-[InterSecureToolsBridge invalidateHandlers]`.
- (void)configureCollaborationWithRoomController:(InterRoomController *)roomController;

@end

NS_ASSUME_NONNULL_END
