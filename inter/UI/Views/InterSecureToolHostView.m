#import "InterSecureToolHostView.h"

// Retained as fallback (R12.5): the legacy AppKit tool views are no longer
// instantiated in the migrated path, but their headers keep the forward-declared
// codeEditorView/whiteboardView property types resolving for the public API.
#import "InterSecureCodeEditorView.h"
#import "InterSecureWhiteboardView.h"

// Swift module bridge — same mechanism SecureWindowController.m uses to see the
// generated @objc Swift classes (e.g. InterSecureChromeBridge).
#if __has_include("inter-Swift.h")
#import "inter-Swift.h"
#endif

@interface InterSecureToolHostView ()
@property (nonatomic, assign, readwrite) InterInterviewToolKind activeToolKind;
@property (nonatomic, strong, readwrite) InterSecureCodeEditorView *codeEditorView;
@property (nonatomic, strong, readwrite) InterSecureWhiteboardView *whiteboardView;
@property (nonatomic, strong) InterSecureToolsBridge *toolsBridge;
@property (nonatomic, strong) NSTextField *placeholderLabel;
@property (nonatomic, strong, nullable) NSView *activeToolView;
@end

@implementation InterSecureToolHostView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) {
        return nil;
    }

    [self configureHostView];
    return self;
}

- (BOOL)isFlipped {
    return NO;
}

- (void)dealloc {
    // M2 teardown: release the bridge's per-session view models (and the editor's
    // weak text-view linkage) at session end. AppKit views dealloc on the main
    // thread, matching invalidateHandlers' @objc/@MainActor contract.
    [_toolsBridge invalidateHandlers];
}

- (void)configureCollaborationWithRoomController:(InterRoomController *)roomController {
    // Forward to the session-owned bridge, which constructs the shared
    // CodeEditorDocument + InterCodeEditorController, registers the controller on
    // the room's DataChannel dispatcher, and configures the vended view model.
    if (!roomController) {
        return;
    }
    [self.toolsBridge configureCollaborationWithRoomController:roomController];
}

- (void)layout {
    [super layout];

    NSRect contentBounds = NSInsetRect(self.bounds, 18.0, 18.0);
    self.placeholderLabel.frame = NSInsetRect(contentBounds, 18.0, 18.0);
    self.activeToolView.frame = contentBounds;
}

- (void)setActiveToolKind:(InterInterviewToolKind)toolKind {
    if (self.activeToolKind == toolKind) {
        [self activateActiveToolResponder];
        return;
    }

    // Compute the next leaf view BEFORE mutating any state. viewForToolKind: is
    // now side-effect-free (the bridge owns lazy instantiation), so this probe is
    // safe and idempotent.
    NSView *nextToolView = [self viewForToolKind:toolKind];

    // R1.7: an unrecognized Tool_Kind resolves to a nil leaf for a value that is
    // NOT the explicit "None" kind. Preserve the currently displayed tool view
    // (never tear down / blank the captured surface) and log the raw value.
    if (!nextToolView && toolKind != InterInterviewToolKindNone) {
        NSLog(@"[InterSecureToolHostView] Ignoring unrecognized InterInterviewToolKind raw value %lu; preserving current tool surface.",
              (unsigned long)toolKind);
        return;
    }

    _activeToolKind = toolKind;
    [self.activeToolView removeFromSuperview];
    self.activeToolView = nextToolView;

    if (self.activeToolView) {
        self.activeToolView.frame = NSInsetRect(self.bounds, 18.0, 18.0);
        self.activeToolView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self addSubview:self.activeToolView positioned:NSWindowBelow relativeTo:self.placeholderLabel];
    }

    self.placeholderLabel.hidden = self.activeToolView != nil;
    [self activateActiveToolResponder];
}

- (void)activateActiveToolResponder {
    switch (self.activeToolKind) {
        case InterInterviewToolKindCodeEditor:
            [self.toolsBridge focusCodeEditor];
            break;
        case InterInterviewToolKindWhiteboard:
            // The SwiftUI whiteboard hosting view manages its own first responder
            // internally; promote the active (hosting) leaf so pointer/keyboard
            // input is routed into it.
            if (self.window && self.activeToolView) {
                [self.window makeFirstResponder:self.activeToolView];
            }
            break;
        case InterInterviewToolKindNone:
        default:
            // R6.3: do not focus the editor for non-CodeEditor kinds.
            break;
    }
}

#pragma mark - Private

- (void)configureHostView {
    self.wantsLayer = YES;
    self.canDrawSubviewsIntoLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;
    self.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.04 alpha:1.0].CGColor;
    self.layer.cornerRadius = 20.0;
    self.layer.masksToBounds = YES;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.08].CGColor;

    // The Tool_Bridge owns the two SwiftUI-hosted leaf views for the session.
    self.toolsBridge = [[InterSecureToolsBridge alloc] init];

    self.placeholderLabel = [NSTextField labelWithString:@"Choose Code or Whiteboard from Interview Controls. Only the active tool surface is shared."];
    self.placeholderLabel.textColor = [NSColor colorWithCalibratedWhite:0.76 alpha:1.0];
    self.placeholderLabel.font = [NSFont systemFontOfSize:18.0 weight:NSFontWeightMedium];
    self.placeholderLabel.alignment = NSTextAlignmentCenter;
    self.placeholderLabel.maximumNumberOfLines = 0;
    self.placeholderLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [self addSubview:self.placeholderLabel];

    self.activeToolKind = InterInterviewToolKindNone;
}

- (NSView *)viewForToolKind:(InterInterviewToolKind)toolKind {
    switch (toolKind) {
        case InterInterviewToolKindCodeEditor:
            return self.toolsBridge.codeEditorHostingView;
        case InterInterviewToolKindWhiteboard:
            return self.toolsBridge.whiteboardHostingView;
        case InterInterviewToolKindNone:
        default:
            return nil;
    }
}

@end
