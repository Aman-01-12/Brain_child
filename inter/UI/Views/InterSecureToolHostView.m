#import "InterSecureToolHostView.h"

#import "InterSecureCodeEditorView.h"
#import "InterSecureWhiteboardView.h"

@interface InterSecureToolHostView ()
@property (nonatomic, assign, readwrite) InterInterviewToolKind activeToolKind;
@property (nonatomic, strong, readwrite) InterSecureCodeEditorView *codeEditorView;
@property (nonatomic, strong, readwrite) InterSecureWhiteboardView *whiteboardView;
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

    _activeToolKind = toolKind;
    [self.activeToolView removeFromSuperview];
    self.activeToolView = [self viewForToolKind:toolKind];

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
            [self.codeEditorView focusTextEditor];
            break;
        case InterInterviewToolKindWhiteboard:
            if (self.window) {
                [self.window makeFirstResponder:self.whiteboardView];
            }
            break;
        case InterInterviewToolKindNone:
        default:
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
            if (!self.codeEditorView) {
                self.codeEditorView = [[InterSecureCodeEditorView alloc] initWithFrame:NSZeroRect];
            }
            return self.codeEditorView;
        case InterInterviewToolKindWhiteboard:
            if (!self.whiteboardView) {
                self.whiteboardView = [[InterSecureWhiteboardView alloc] initWithFrame:NSZeroRect];
            }
            return self.whiteboardView;
        case InterInterviewToolKindNone:
        default:
            return nil;
    }
}

@end
