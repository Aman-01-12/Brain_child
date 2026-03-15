#import "InterSecureInterviewStageView.h"

#import <CoreImage/CoreImage.h>

#import "InterRemoteVideoLayoutManager.h"
#import "InterSecureToolHostView.h"
#import "InterTrackRendererBridge.h"

#if __has_include("inter-Swift.h")
#import "inter-Swift.h"
#endif

static const CGFloat InterSecureStageSidebarWidth = 278.0;
static const CGFloat InterSecureStageSidebarTrailingMargin = 34.0;
static const CGFloat InterSecureStageTopMargin = 40.0;
static const CGFloat InterSecureStageLeftMargin = 40.0;
static const CGFloat InterSecureStageBottomWorkspaceMargin = 100.0;
static const CGFloat InterSecureStagePreviewCornerRadius = 18.0;
static const CGFloat InterSecureStageOffscreenPadding = 120.0;
static const CGFloat InterSecureStageControlPanelBottomMargin = 26.0;
static const CGFloat InterSecureStageControlPanelHeight = 470.0;
static const CGFloat InterSecureStageRailGap = 18.0;
static const CGFloat InterSecureStageRailTileGap = 14.0;
static const CGFloat InterSecureStageRailTileAspectRatio = 9.0 / 16.0;
static const CFTimeInterval InterSecureStagePreviewUpdateInterval = 1.0 / 6.0;
static NSString * const InterSecureStageScreenShareTileKey = @"__screenshare__";
static NSString * const InterSecureStageToolPreviewKey = @"__tool__";

typedef NS_ENUM(NSUInteger, InterSecureInterviewCenterContent) {
    InterSecureInterviewCenterContentRemote = 0,
    InterSecureInterviewCenterContentTool,
};

@interface InterSecureInterviewPreviewCardView : NSView
@property (nonatomic, strong) NSImageView *imageView;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, copy, nullable) dispatch_block_t clickHandler;
@property (nonatomic, assign, getter=isSelectedCard) BOOL selectedCard;
- (void)setPreviewImage:(NSImage * _Nullable)image title:(NSString *)title;
@end

@implementation InterSecureInterviewPreviewCardView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) {
        return nil;
    }

    self.wantsLayer = YES;
    self.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.05 alpha:1.0].CGColor;
    self.layer.cornerRadius = InterSecureStagePreviewCornerRadius;
    self.layer.masksToBounds = YES;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.10].CGColor;

    self.imageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    self.imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.imageView.wantsLayer = YES;
    self.imageView.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.08 alpha:1.0].CGColor;
    self.imageView.layer.cornerRadius = InterSecureStagePreviewCornerRadius - 4.0;
    self.imageView.layer.masksToBounds = YES;
    [self addSubview:self.imageView];

    self.titleLabel = [NSTextField labelWithString:@""];
    self.titleLabel.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightSemibold];
    self.titleLabel.textColor = [NSColor colorWithCalibratedWhite:0.92 alpha:1.0];
    self.titleLabel.alignment = NSTextAlignmentCenter;
    self.titleLabel.maximumNumberOfLines = 1;
    self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.titleLabel.wantsLayer = YES;
    self.titleLabel.backgroundColor = [NSColor colorWithCalibratedWhite:0.0 alpha:0.48];
    self.titleLabel.drawsBackground = YES;
    [self addSubview:self.titleLabel];

    return self;
}

- (void)layout {
    [super layout];

    NSRect insetBounds = NSInsetRect(self.bounds, 4.0, 4.0);
    self.imageView.frame = insetBounds;
    self.titleLabel.frame = NSMakeRect(NSMinX(insetBounds),
                                       NSMinY(insetBounds),
                                       NSWidth(insetBounds),
                                       24.0);
}

- (void)setSelectedCard:(BOOL)selectedCard {
    if (_selectedCard == selectedCard) {
        return;
    }

    _selectedCard = selectedCard;
    self.layer.borderWidth = selectedCard ? 2.0 : 1.0;
    self.layer.borderColor = selectedCard
        ? [NSColor colorWithCalibratedRed:0.33 green:0.68 blue:0.98 alpha:0.95].CGColor
        : [NSColor colorWithCalibratedWhite:1.0 alpha:0.10].CGColor;
}

- (void)setPreviewImage:(NSImage * _Nullable)image title:(NSString *)title {
    self.imageView.image = image;
    self.titleLabel.stringValue = title ?: @"";
}

- (void)mouseDown:(NSEvent *)event {
#pragma unused(event)
    dispatch_block_t clickHandler = self.clickHandler;
    if (clickHandler) {
        clickHandler();
    }
}

- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
}

@end

@interface InterSecureInterviewStageView () <InterTrackRendererPreviewObserver>
@property (nonatomic, strong, readwrite) InterRemoteVideoLayoutManager *remoteLayoutManager;
@property (nonatomic, strong, readwrite) InterSecureToolHostView *toolCaptureHostView;
@property (nonatomic, strong) InterSecureInterviewPreviewCardView *toolPreviewView;
@property (nonatomic, strong) NSScrollView *rightRailScrollView;
@property (nonatomic, strong) NSView *rightRailContentView;
@property (nonatomic, strong) NSMutableDictionary<NSString *, InterSecureInterviewPreviewCardView *> *remotePreviewViews;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSImage *> *remotePreviewImages;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *remotePreviewTimestamps;
@property (nonatomic, strong) NSMutableArray<NSString *> *remoteCameraOrder;
@property (nonatomic, copy, nullable) NSString *remoteScreenShareParticipantId;
@property (nonatomic, copy, nullable) NSString *selectedRemoteTileKey;
@property (nonatomic, assign) BOOL remoteSelectionIsUserDriven;
@property (nonatomic, strong) CIContext *previewCIContext;
@property (nonatomic, assign, readwrite) InterInterviewToolKind activeToolKind;
@property (nonatomic, assign) InterSecureInterviewCenterContent centerContent;
@end

@implementation InterSecureInterviewStageView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) {
        return nil;
    }

    [self configureStageView];
    return self;
}

- (BOOL)isFlipped {
    return NO;
}

- (void)setFrame:(NSRect)frame {
    [super setFrame:frame];
    [self applyStageLayout];
}

- (void)layout {
    [super layout];
    [self applyStageLayout];
}

- (void)setActiveToolKind:(InterInterviewToolKind)toolKind {
    BOOL hadSelectedTool = (_activeToolKind != InterInterviewToolKindNone);
    if (_activeToolKind == toolKind) {
        [self focusActiveToolIfVisible];
        return;
    }

    _activeToolKind = toolKind;
    [self.toolCaptureHostView setActiveToolKind:toolKind];

    if (toolKind == InterInterviewToolKindNone) {
        self.centerContent = InterSecureInterviewCenterContentRemote;
        [self clearToolPreview];
    } else if (hadSelectedTool && self.centerContent == InterSecureInterviewCenterContentRemote) {
        [self refreshToolPreview];
    } else {
        self.centerContent = InterSecureInterviewCenterContentTool;
        [self clearToolPreview];
    }

    [self synchronizeRemoteSelectionPreservingUserChoice];
    [self setNeedsLayout:YES];
}

- (void)setSecureShareActive:(BOOL)secureShareActive {
    if (_secureShareActive == secureShareActive) {
        return;
    }

    _secureShareActive = secureShareActive;

    if (self.activeToolKind == InterInterviewToolKindNone) {
        self.centerContent = InterSecureInterviewCenterContentRemote;
        [self clearToolPreview];
        [self relinquishToolFirstResponder];
    } else if (self.centerContent == InterSecureInterviewCenterContentRemote) {
        [self refreshToolPreview];
    } else {
        [self clearToolPreview];
        if (!secureShareActive) {
            [self focusActiveToolIfVisible];
        }
    }

    [self setNeedsLayout:YES];
}

- (void)focusActiveToolIfVisible {
    if (self.centerContent == InterSecureInterviewCenterContentTool &&
        self.activeToolKind != InterInterviewToolKindNone) {
        [self.toolCaptureHostView activateActiveToolResponder];
    }
}

#pragma mark - InterTrackRendererPreviewObserver

- (void)observeRemoteCameraFrame:(CVPixelBufferRef)pixelBuffer fromParticipant:(NSString *)participantId {
    if (!pixelBuffer || participantId.length == 0) {
        return;
    }

    CVPixelBufferRetain(pixelBuffer);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self ingestRemoteFrame:pixelBuffer
                         tileKey:participantId
                           title:participantId
                   screenShareID:nil];
        CVPixelBufferRelease(pixelBuffer);
    });
}

- (void)observeRemoteScreenShareFrame:(CVPixelBufferRef)pixelBuffer fromParticipant:(NSString *)participantId {
    if (!pixelBuffer || participantId.length == 0) {
        return;
    }

    CVPixelBufferRetain(pixelBuffer);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self ingestRemoteFrame:pixelBuffer
                         tileKey:InterSecureStageScreenShareTileKey
                           title:@"Screen Share"
                   screenShareID:participantId];
        CVPixelBufferRelease(pixelBuffer);
    });
}

- (void)observeRemoteTrackMuted:(NSUInteger)kind forParticipant:(NSString *)participantId {
#pragma unused(kind, participantId)
}

- (void)observeRemoteTrackUnmuted:(NSUInteger)kind forParticipant:(NSString *)participantId {
#pragma unused(kind, participantId)
}

- (void)observeRemoteTrackEnded:(NSUInteger)kind forParticipant:(NSString *)participantId {
    if (kind == InterTrackKindCamera) {
        [self removeRemoteCandidateForTileKey:participantId screenShareParticipant:nil];
    } else if (kind == InterTrackKindScreenShare) {
        [self removeRemoteCandidateForTileKey:InterSecureStageScreenShareTileKey screenShareParticipant:participantId];
    }
}

#pragma mark - Private

- (void)configureStageView {
    self.wantsLayer = YES;
    self.layer.backgroundColor = [NSColor clearColor].CGColor;

    self.previewCIContext = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @NO }];
    self.remotePreviewViews = [NSMutableDictionary dictionary];
    self.remotePreviewImages = [NSMutableDictionary dictionary];
    self.remotePreviewTimestamps = [NSMutableDictionary dictionary];
    self.remoteCameraOrder = [NSMutableArray array];

    self.remoteLayoutManager = [[InterRemoteVideoLayoutManager alloc] initWithFrame:NSZeroRect];
    self.remoteLayoutManager.autoresizingMask = NSViewNotSizable;
    self.remoteLayoutManager.allowsManualSpotlightSelection = NO;
    self.remoteLayoutManager.preferStageLayoutForMultipleCameras = NO;
    self.remoteLayoutManager.compactPreviewMode = YES;
    self.remoteLayoutManager.supplementalFilmstripView = nil;
    [self addSubview:self.remoteLayoutManager];

    self.toolCaptureHostView = [[InterSecureToolHostView alloc] initWithFrame:NSZeroRect];
    [self addSubview:self.toolCaptureHostView positioned:NSWindowBelow relativeTo:self.remoteLayoutManager];

    self.rightRailScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.rightRailScrollView.drawsBackground = NO;
    self.rightRailScrollView.borderType = NSNoBorder;
    self.rightRailScrollView.hasVerticalScroller = YES;
    self.rightRailScrollView.hasHorizontalScroller = NO;
    self.rightRailScrollView.autohidesScrollers = YES;
    self.rightRailScrollView.hidden = YES;
    self.rightRailContentView = [[NSView alloc] initWithFrame:NSZeroRect];
    self.rightRailContentView.wantsLayer = YES;
    self.rightRailContentView.layer.backgroundColor = [NSColor clearColor].CGColor;
    self.rightRailScrollView.documentView = self.rightRailContentView;
    [self addSubview:self.rightRailScrollView positioned:NSWindowAbove relativeTo:self.remoteLayoutManager];

    __weak typeof(self) weakSelf = self;
    self.toolPreviewView = [[InterSecureInterviewPreviewCardView alloc] initWithFrame:NSZeroRect];
    self.toolPreviewView.hidden = YES;
    self.toolPreviewView.clickHandler = ^{
        [weakSelf handleToolPreviewSelected];
    };

    self.activeToolKind = InterInterviewToolKindNone;
    self.centerContent = InterSecureInterviewCenterContentRemote;
    self.remoteSelectionIsUserDriven = NO;
    self.selectedRemoteTileKey = nil;

    [self applyStageLayout];
}

- (NSRect)workspaceFrame {
    CGFloat sidebarOriginX = self.bounds.size.width - InterSecureStageSidebarTrailingMargin - InterSecureStageSidebarWidth;
    CGFloat width = MAX(320.0, sidebarOriginX - (InterSecureStageLeftMargin + 24.0));
    CGFloat height = MAX(320.0, self.bounds.size.height - (InterSecureStageBottomWorkspaceMargin + InterSecureStageTopMargin + 30.0));
    return NSMakeRect(InterSecureStageLeftMargin,
                      InterSecureStageBottomWorkspaceMargin,
                      width,
                      height);
}

- (NSRect)rightRailFrame {
    CGFloat originX = self.bounds.size.width - InterSecureStageSidebarTrailingMargin - InterSecureStageSidebarWidth;
    CGFloat originY = InterSecureStageControlPanelBottomMargin + InterSecureStageControlPanelHeight + InterSecureStageRailGap;
    CGFloat height = MAX(120.0, self.bounds.size.height - InterSecureStageTopMargin - originY);
    return NSMakeRect(originX,
                      originY,
                      InterSecureStageSidebarWidth,
                      height);
}

- (NSRect)offscreenCaptureFrame {
    NSRect workspaceFrame = [self workspaceFrame];
    return NSMakeRect(NSMaxX(self.bounds) + InterSecureStageOffscreenPadding,
                      NSMinY(workspaceFrame),
                      NSWidth(workspaceFrame),
                      NSHeight(workspaceFrame));
}

- (NSRect)offscreenRemoteFrame {
    NSRect workspaceFrame = [self workspaceFrame];
    return NSMakeRect(NSMaxX(self.bounds) + InterSecureStageOffscreenPadding + NSWidth(workspaceFrame) + 40.0,
                      NSMinY(workspaceFrame),
                      NSWidth(workspaceFrame),
                      NSHeight(workspaceFrame));
}

- (NSArray<NSString *> *)orderedRemoteTileKeys {
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    if (self.remoteScreenShareParticipantId.length > 0) {
        [keys addObject:InterSecureStageScreenShareTileKey];
    }
    [keys addObjectsFromArray:self.remoteCameraOrder];
    return keys;
}

- (void)applyStageLayout {
    NSRect workspaceFrame = [self workspaceFrame];
    BOOL hasSelectedTool = self.activeToolKind != InterInterviewToolKindNone;
    BOOL toolOwnsCenter = hasSelectedTool && self.centerContent == InterSecureInterviewCenterContentTool;
    BOOL hasRemoteSelection = self.selectedRemoteTileKey.length > 0;

    self.remoteLayoutManager.compactPreviewMode = YES;
    self.remoteLayoutManager.supplementalFilmstripView = nil;
    self.remoteLayoutManager.hidden = !(self.centerContent == InterSecureInterviewCenterContentRemote && hasRemoteSelection);

    if (toolOwnsCenter) {
        self.toolCaptureHostView.frame = workspaceFrame;
        self.remoteLayoutManager.frame = [self offscreenRemoteFrame];
    } else {
        self.toolCaptureHostView.frame = [self offscreenCaptureFrame];
        if (hasRemoteSelection) {
            self.remoteLayoutManager.frame = workspaceFrame;
        } else {
            self.remoteLayoutManager.frame = [self offscreenRemoteFrame];
        }
    }

    [self layoutRightRail];
    [self.remoteLayoutManager layoutSubtreeIfNeeded];
}

- (void)layoutRightRail {
    NSArray<NSString *> *remoteKeys = [self orderedRemoteTileKeys];
    BOOL toolOwnsCenter = (self.activeToolKind != InterInterviewToolKindNone &&
                           self.centerContent == InterSecureInterviewCenterContentTool);
    NSMutableArray<NSString *> *railKeys = [NSMutableArray array];

    if (self.activeToolKind != InterInterviewToolKindNone && !toolOwnsCenter) {
        [self refreshToolPreview];
        [railKeys addObject:InterSecureStageToolPreviewKey];
    }

    for (NSString *tileKey in remoteKeys) {
        if (self.centerContent == InterSecureInterviewCenterContentRemote &&
            [tileKey isEqualToString:self.selectedRemoteTileKey]) {
            continue;
        }
        [railKeys addObject:tileKey];
    }

    if (railKeys.count == 0) {
        self.rightRailScrollView.hidden = YES;
        for (NSView *subview in [self.rightRailContentView.subviews copy]) {
            [subview removeFromSuperview];
        }
        return;
    }

    self.rightRailScrollView.hidden = NO;
    self.rightRailScrollView.frame = [self rightRailFrame];

    CGFloat tileWidth = NSWidth(self.rightRailScrollView.bounds) - 8.0;
    tileWidth = MAX(200.0, tileWidth);
    CGFloat tileHeight = tileWidth * InterSecureStageRailTileAspectRatio;
    CGFloat totalHeight = railKeys.count * tileHeight + MAX((NSInteger)railKeys.count - 1, 0) * InterSecureStageRailTileGap + 8.0;
    totalHeight = MAX(totalHeight, NSHeight(self.rightRailScrollView.bounds));
    self.rightRailContentView.frame = NSMakeRect(0, 0, NSWidth(self.rightRailScrollView.bounds), totalHeight);

    NSMutableSet<NSView *> *activeViews = [NSMutableSet set];
    for (NSUInteger index = 0; index < railKeys.count; index++) {
        NSString *itemKey = railKeys[index];
        InterSecureInterviewPreviewCardView *cardView = [self previewCardForRailItem:itemKey];
        if (!cardView) {
            continue;
        }

        [activeViews addObject:cardView];
        if (cardView.superview != self.rightRailContentView) {
            [self.rightRailContentView addSubview:cardView];
        }

        CGFloat y = totalHeight - 4.0 - tileHeight - index * (tileHeight + InterSecureStageRailTileGap);
        cardView.frame = NSMakeRect(4.0, y, tileWidth, tileHeight);
        cardView.hidden = NO;
        cardView.selectedCard = NO;
    }

    for (NSView *subview in [self.rightRailContentView.subviews copy]) {
        if (![activeViews containsObject:subview]) {
            [subview removeFromSuperview];
        }
    }
}

- (InterSecureInterviewPreviewCardView *)previewCardForRailItem:(NSString *)itemKey {
    if ([itemKey isEqualToString:InterSecureStageToolPreviewKey]) {
        self.toolPreviewView.hidden = NO;
        self.toolPreviewView.selectedCard = NO;
        return self.toolPreviewView;
    }

    InterSecureInterviewPreviewCardView *cardView = self.remotePreviewViews[itemKey];
    if (!cardView) {
        __weak typeof(self) weakSelf = self;
        cardView = [[InterSecureInterviewPreviewCardView alloc] initWithFrame:NSZeroRect];
        cardView.clickHandler = ^{
            [weakSelf handleRemotePreviewSelectionForTileKey:itemKey];
        };
        self.remotePreviewViews[itemKey] = cardView;
    }

    NSString *title = [self titleForRemoteTileKey:itemKey];
    NSImage *previewImage = self.remotePreviewImages[itemKey];
    [cardView setPreviewImage:previewImage title:title];
    return cardView;
}

- (NSString *)titleForRemoteTileKey:(NSString *)tileKey {
    if ([tileKey isEqualToString:InterSecureStageScreenShareTileKey]) {
        return @"Screen Share";
    }
    return tileKey ?: @"Participant";
}

- (void)handleRemotePreviewSelectionForTileKey:(NSString *)tileKey {
    NSArray<NSString *> *remoteKeys = [self orderedRemoteTileKeys];
    if (![remoteKeys containsObject:tileKey]) {
        return;
    }

    if (self.activeToolKind != InterInterviewToolKindNone) {
        [self refreshToolPreview];
    }

    self.remoteSelectionIsUserDriven = YES;
    self.selectedRemoteTileKey = [tileKey copy];
    self.centerContent = InterSecureInterviewCenterContentRemote;
    [self.remoteLayoutManager setManualSpotlightTileKey:self.selectedRemoteTileKey animated:NO];
    [self relinquishToolFirstResponder];
    [self setNeedsLayout:YES];
    [self layoutSubtreeIfNeeded];
}

- (void)handleToolPreviewSelected {
    if (self.activeToolKind == InterInterviewToolKindNone) {
        return;
    }

    self.centerContent = InterSecureInterviewCenterContentTool;
    [self clearToolPreview];
    [self setNeedsLayout:YES];
    [self layoutSubtreeIfNeeded];
    [self focusActiveToolIfVisible];
}

- (void)relinquishToolFirstResponder {
    NSResponder *firstResponder = self.window.firstResponder;
    if ([firstResponder isKindOfClass:[NSView class]]) {
        NSView *responderView = (NSView *)firstResponder;
        if ([responderView isDescendantOf:self.toolCaptureHostView]) {
            [self.window makeFirstResponder:nil];
        }
    }
}

- (void)refreshToolPreview {
    NSImage *previewImage = [self snapshotImageForToolCaptureHost];
    NSString *title = [self previewTitleForActiveTool];
    [self.toolPreviewView setPreviewImage:previewImage title:title];
}

- (void)clearToolPreview {
    [self.toolPreviewView setPreviewImage:nil title:@""];
}

- (NSString *)previewTitleForActiveTool {
    switch (self.activeToolKind) {
        case InterInterviewToolKindCodeEditor:
            return @"Code Preview";
        case InterInterviewToolKindWhiteboard:
            return @"Whiteboard Preview";
        case InterInterviewToolKindNone:
        default:
            return @"";
    }
}

- (NSImage * _Nullable)snapshotImageForToolCaptureHost {
    if (self.activeToolKind == InterInterviewToolKindNone) {
        return nil;
    }

    [self.toolCaptureHostView layoutSubtreeIfNeeded];

    NSBitmapImageRep *bitmap = [self.toolCaptureHostView bitmapImageRepForCachingDisplayInRect:self.toolCaptureHostView.bounds];
    if (!bitmap) {
        return nil;
    }

    [self.toolCaptureHostView cacheDisplayInRect:self.toolCaptureHostView.bounds toBitmapImageRep:bitmap];
    CGImageRef cgImage = bitmap.CGImage;
    if (!cgImage) {
        return nil;
    }

    return [[NSImage alloc] initWithCGImage:cgImage size:self.toolCaptureHostView.bounds.size];
}

- (void)ingestRemoteFrame:(CVPixelBufferRef)pixelBuffer
                  tileKey:(NSString *)tileKey
                    title:(NSString *)title
            screenShareID:(NSString * _Nullable)screenShareID {
    if (screenShareID.length > 0) {
        self.remoteScreenShareParticipantId = [screenShareID copy];
    } else if (![self.remoteCameraOrder containsObject:tileKey]) {
        [self.remoteCameraOrder addObject:tileKey];
    }

    [self updateRemotePreviewImageForTileKey:tileKey pixelBuffer:pixelBuffer title:title];
    [self synchronizeRemoteSelectionPreservingUserChoice];
}

- (void)updateRemotePreviewImageForTileKey:(NSString *)tileKey
                               pixelBuffer:(CVPixelBufferRef)pixelBuffer
                                     title:(NSString *)title {
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    NSNumber *lastUpdateValue = self.remotePreviewTimestamps[tileKey];
    if (lastUpdateValue && (now - lastUpdateValue.doubleValue) < InterSecureStagePreviewUpdateInterval) {
        return;
    }

    NSImage *previewImage = [self imageFromPixelBuffer:pixelBuffer];
    if (!previewImage) {
        return;
    }

    self.remotePreviewTimestamps[tileKey] = @(now);
    self.remotePreviewImages[tileKey] = previewImage;

    InterSecureInterviewPreviewCardView *cardView = self.remotePreviewViews[tileKey];
    if (cardView) {
        [cardView setPreviewImage:previewImage title:title];
    }
}

- (NSImage * _Nullable)imageFromPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    if (!ciImage) {
        return nil;
    }

    CGRect extent = CGRectIntegral(ciImage.extent);
    if (CGRectIsEmpty(extent)) {
        return nil;
    }

    CGImageRef cgImage = [self.previewCIContext createCGImage:ciImage fromRect:extent];
    if (!cgImage) {
        return nil;
    }

    NSImage *image = [[NSImage alloc] initWithCGImage:cgImage size:NSMakeSize(CGRectGetWidth(extent), CGRectGetHeight(extent))];
    CGImageRelease(cgImage);
    return image;
}

- (void)removeRemoteCandidateForTileKey:(NSString *)tileKey screenShareParticipant:(NSString * _Nullable)screenShareParticipant {
    if ([tileKey isEqualToString:InterSecureStageScreenShareTileKey]) {
        if (screenShareParticipant.length == 0 ||
            [self.remoteScreenShareParticipantId isEqualToString:screenShareParticipant]) {
            self.remoteScreenShareParticipantId = nil;
        }
    } else {
        [self.remoteCameraOrder removeObject:tileKey];
    }

    InterSecureInterviewPreviewCardView *cardView = self.remotePreviewViews[tileKey];
    [cardView removeFromSuperview];
    [self.remotePreviewViews removeObjectForKey:tileKey];
    [self.remotePreviewImages removeObjectForKey:tileKey];
    [self.remotePreviewTimestamps removeObjectForKey:tileKey];

    if ([self.selectedRemoteTileKey isEqualToString:tileKey]) {
        self.selectedRemoteTileKey = nil;
        self.remoteSelectionIsUserDriven = NO;
    }

    [self synchronizeRemoteSelectionPreservingUserChoice];
}

- (void)synchronizeRemoteSelectionPreservingUserChoice {
    NSArray<NSString *> *remoteKeys = [self orderedRemoteTileKeys];
    if (remoteKeys.count == 0) {
        self.selectedRemoteTileKey = nil;
        self.remoteSelectionIsUserDriven = NO;
        [self.remoteLayoutManager setManualSpotlightTileKey:nil animated:NO];
        if (self.centerContent == InterSecureInterviewCenterContentRemote &&
            self.activeToolKind != InterInterviewToolKindNone) {
            self.centerContent = InterSecureInterviewCenterContentTool;
        }
        [self setNeedsLayout:YES];
        return;
    }

    if (self.selectedRemoteTileKey.length == 0 || ![remoteKeys containsObject:self.selectedRemoteTileKey]) {
        self.remoteSelectionIsUserDriven = NO;
    }

    if (!self.remoteSelectionIsUserDriven) {
        self.selectedRemoteTileKey = remoteKeys.firstObject;
    }

    [self.remoteLayoutManager setManualSpotlightTileKey:self.selectedRemoteTileKey animated:NO];

    if (self.activeToolKind == InterInterviewToolKindNone) {
        self.centerContent = InterSecureInterviewCenterContentRemote;
    }

    [self setNeedsLayout:YES];
}

@end
