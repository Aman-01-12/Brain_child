#import "InterSecureCodeEditorView.h"

@interface InterSecureCodeEditorView () <NSTextViewDelegate>
@property (nonatomic, strong, readwrite) NSTextView *textView;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSTextField *placeholderLabel;
@end

@implementation InterSecureCodeEditorView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) {
        return nil;
    }

    [self configureEditorView];
    return self;
}

- (BOOL)isFlipped {
    return NO;
}

- (void)layout {
    [super layout];

    NSRect insetBounds = NSInsetRect(self.bounds, 18.0, 18.0);
    self.scrollView.frame = insetBounds;
    self.placeholderLabel.frame = NSInsetRect(insetBounds, 12.0, 12.0);
}

- (void)focusTextEditor {
    if (self.window) {
        [self.window makeFirstResponder:self.textView];
    }
}

#pragma mark - NSTextViewDelegate

- (void)textDidChange:(NSNotification *)notification {
#pragma unused(notification)
    [self updatePlaceholderVisibility];
}

#pragma mark - Private

- (void)configureEditorView {
    NSColor *editorChromeColor = [NSColor colorWithCalibratedWhite:0.08 alpha:1.0];
    NSColor *editorTextBackgroundColor = [NSColor colorWithCalibratedWhite:0.10 alpha:1.0];

    self.wantsLayer = YES;
    self.canDrawSubviewsIntoLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;
    self.layer.backgroundColor = editorChromeColor.CGColor;
    self.layer.cornerRadius = 16.0;
    self.layer.masksToBounds = YES;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.10].CGColor;

    self.scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.scrollView.borderType = NSNoBorder;
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.hasHorizontalScroller = NO;
    self.scrollView.autohidesScrollers = YES;
    self.scrollView.drawsBackground = NO;
    self.scrollView.wantsLayer = YES;
    self.scrollView.layer.backgroundColor = editorTextBackgroundColor.CGColor;
    self.scrollView.layer.cornerRadius = 12.0;
    self.scrollView.layer.masksToBounds = YES;

    // AppKit scroll/text subviews can briefly repaint with their default backing
    // during resize or first-responder changes. Giving the scroll hierarchy an
    // explicit dark layer-backed background keeps the rounded corners visually
    // stable both locally and in the captured secure-tool stream.
    self.scrollView.contentView.wantsLayer = YES;
    self.scrollView.contentView.layer.backgroundColor = editorTextBackgroundColor.CGColor;

    NSTextStorage *textStorage = [[NSTextStorage alloc] init];
    NSLayoutManager *layoutManager = [[NSLayoutManager alloc] init];
    [textStorage addLayoutManager:layoutManager];

    NSTextContainer *textContainer = [[NSTextContainer alloc] initWithSize:NSMakeSize(0.0, CGFLOAT_MAX)];
    textContainer.widthTracksTextView = YES;
    [layoutManager addTextContainer:textContainer];

    self.textView = [[NSTextView alloc] initWithFrame:NSZeroRect textContainer:textContainer];
    self.textView.delegate = self;
    self.textView.minSize = NSMakeSize(0.0, 0.0);
    self.textView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    self.textView.verticallyResizable = YES;
    self.textView.horizontallyResizable = NO;
    self.textView.autoresizingMask = NSViewWidthSizable;
    self.textView.font = [NSFont monospacedSystemFontOfSize:13.0 weight:NSFontWeightRegular];
    self.textView.textColor = [NSColor colorWithCalibratedWhite:0.94 alpha:1.0];
    self.textView.backgroundColor = editorTextBackgroundColor;
    self.textView.insertionPointColor = [NSColor colorWithCalibratedWhite:0.95 alpha:1.0];
    self.textView.drawsBackground = YES;
    self.textView.richText = NO;
    self.textView.importsGraphics = NO;
    self.textView.usesFindBar = YES;
    self.textView.allowsUndo = YES;
    self.textView.automaticDataDetectionEnabled = NO;
    self.textView.automaticLinkDetectionEnabled = NO;
    self.textView.automaticTextReplacementEnabled = NO;
    self.textView.automaticDashSubstitutionEnabled = NO;
    self.textView.automaticSpellingCorrectionEnabled = NO;
    self.textView.continuousSpellCheckingEnabled = NO;
    self.textView.grammarCheckingEnabled = NO;
    self.textView.smartInsertDeleteEnabled = NO;

    // Coding input must remain literal. Smart substitutions are good for prose,
    // but they silently corrupt source text and make the captured workspace lie
    // about what the participant actually typed.
    if ([self.textView respondsToSelector:@selector(setAutomaticQuoteSubstitutionEnabled:)]) {
        self.textView.automaticQuoteSubstitutionEnabled = NO;
    }
    if ([self.textView respondsToSelector:@selector(setAutomaticTextCompletionEnabled:)]) {
        self.textView.automaticTextCompletionEnabled = NO;
    }

    self.scrollView.documentView = self.textView;
    [self addSubview:self.scrollView];

    self.placeholderLabel = [NSTextField labelWithString:@"Open the secure editor and type here. Only this editor surface is shared in interview mode."];
    self.placeholderLabel.textColor = [NSColor colorWithCalibratedWhite:0.72 alpha:1.0];
    self.placeholderLabel.font = [NSFont systemFontOfSize:14.0 weight:NSFontWeightRegular];
    self.placeholderLabel.alignment = NSTextAlignmentLeft;
    self.placeholderLabel.maximumNumberOfLines = 0;
    self.placeholderLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [self addSubview:self.placeholderLabel];

    [self updatePlaceholderVisibility];
}

- (void)updatePlaceholderVisibility {
    self.placeholderLabel.hidden = self.textView.string.length > 0;
}

@end
