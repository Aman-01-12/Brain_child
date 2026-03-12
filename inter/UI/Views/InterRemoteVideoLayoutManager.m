#import "InterRemoteVideoLayoutManager.h"
#import "InterParticipantOverlayView.h"

#if __has_include("inter-Swift.h")
#import "inter-Swift.h"
#endif

// ---------------------------------------------------------------------------
// Internal tile key helpers
// ---------------------------------------------------------------------------
static NSString *const kScreenShareTileKey = @"__screenshare__";

// ---------------------------------------------------------------------------
// InterRemoteVideoTileView — wrapper around InterRemoteVideoView that adds:
//   • Dark rounded rect background (filmstrip look)
//   • Participant name label at the bottom
//   • Hover highlight via NSTrackingArea
//   • Click-to-spotlight via target/action
// ---------------------------------------------------------------------------
@interface InterRemoteVideoTileView : NSView
@property (nonatomic, strong) InterRemoteVideoView *videoView;
@property (nonatomic, strong) NSTextField *nameLabel;
@property (nonatomic, copy) NSString *tileKey;
@property (nonatomic, weak) id spotlightTarget;
@property (nonatomic, assign) SEL spotlightAction;
@property (nonatomic, assign) BOOL isHovered;
@property (nonatomic, strong) NSTrackingArea *hoverTrackingArea;
@end

@implementation InterRemoteVideoTileView

- (instancetype)initWithVideoView:(InterRemoteVideoView *)videoView
                          tileKey:(NSString *)tileKey
                      displayName:(NSString *)displayName {
    self = [super initWithFrame:NSZeroRect];
    if (!self) return nil;

    self.wantsLayer = YES;
    self.layer.backgroundColor = [NSColor blackColor].CGColor;
    self.layer.cornerRadius = 8.0;
    self.layer.masksToBounds = YES;

    self.tileKey = tileKey;
    self.videoView = videoView;
    videoView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:videoView];

    // Name label pinned to bottom
    self.nameLabel = [NSTextField labelWithString:displayName];
    self.nameLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.nameLabel.textColor = [NSColor whiteColor];
    self.nameLabel.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.55];
    self.nameLabel.drawsBackground = YES;
    self.nameLabel.alignment = NSTextAlignmentCenter;
    self.nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.nameLabel.maximumNumberOfLines = 1;
    [self addSubview:self.nameLabel];

    return self;
}

- (void)layout {
    [super layout];
    NSRect b = self.bounds;
    // Video fills entire tile
    self.videoView.frame = b;
    // Name label at bottom, 22px tall
    CGFloat labelH = 22.0;
    self.nameLabel.frame = NSMakeRect(0, 0, b.size.width, labelH);
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.hoverTrackingArea) {
        [self removeTrackingArea:self.hoverTrackingArea];
    }
    self.hoverTrackingArea = [[NSTrackingArea alloc]
                              initWithRect:self.bounds
                              options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp)
                              owner:self
                              userInfo:nil];
    [self addTrackingArea:self.hoverTrackingArea];
}

- (void)mouseEntered:(NSEvent *)event {
    self.isHovered = YES;
    self.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.5].CGColor;
    self.layer.borderWidth = 2.0;
}

- (void)mouseExited:(NSEvent *)event {
    self.isHovered = NO;
    self.layer.borderColor = nil;
    self.layer.borderWidth = 0.0;
}

- (void)mouseDown:(NSEvent *)event {
    // Toggle: click filmstrip tile → promote to spotlight
    if (self.spotlightTarget && self.spotlightAction) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self.spotlightTarget performSelector:self.spotlightAction withObject:self.tileKey];
#pragma clang diagnostic pop
    }
}

// Show pointer cursor on hover
- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
}

@end

// ---------------------------------------------------------------------------
// InterRemoteVideoLayoutManager — Private interface
// ---------------------------------------------------------------------------
@interface InterRemoteVideoLayoutManager ()

/// Per-participant remote camera views, keyed by participant identity string.
@property (nonatomic, strong) NSMutableDictionary<NSString *, InterRemoteVideoView *> *remoteCameraViews;
/// Insertion-order list of participant IDs so grid layout is deterministic.
@property (nonatomic, strong) NSMutableArray<NSString *> *cameraParticipantOrder;
/// Single screen share view (at most one active at a time).
@property (nonatomic, strong) InterRemoteVideoView *remoteScreenShareView;
/// Participant ID currently screen-sharing (nil when none).
@property (nonatomic, copy, nullable) NSString *screenShareParticipantId;
@property (nonatomic, strong, readwrite) InterParticipantOverlayView *participantOverlay;
@property (nonatomic, assign, readwrite) InterRemoteVideoLayoutMode layoutMode;

// -- Tile wrappers --

/// Per-tile wrapper views, keyed by tile key (participantId or kScreenShareTileKey).
@property (nonatomic, strong) NSMutableDictionary<NSString *, InterRemoteVideoTileView *> *tileViews;

// -- Spotlight --

/// Tile key currently shown on the main stage (nil = auto).
/// Auto: screen share is spotlighted when present; otherwise first camera.
@property (nonatomic, copy, nullable) NSString *spotlightedTileKey;

// -- Filmstrip scrolling --

/// Clip view wrapping the filmstrip content to allow vertical scrolling.
@property (nonatomic, strong) NSScrollView *filmstripScrollView;
/// Content view inside scroll view that holds filmstrip tiles.
@property (nonatomic, strong) NSView *filmstripContentView;

@end

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
static const CGFloat kFilmstripWidthFraction = 0.25;  // 25% of total width
static const CGFloat kFilmstripMinWidth      = 160.0;
static const CGFloat kFilmstripMaxWidth      = 280.0;
static const CGFloat kFilmstripTileGap       = 8.0;
static const CGFloat kFilmstripPadding       = 8.0;
static const CGFloat kAnimationDuration      = 0.3;

@implementation InterRemoteVideoLayoutManager

#pragma mark - Lifecycle

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;

    self.wantsLayer = YES;
    self.layer.backgroundColor = [NSColor blackColor].CGColor;

    self.remoteCameraViews   = [NSMutableDictionary dictionary];
    self.cameraParticipantOrder = [NSMutableArray array];
    self.tileViews           = [NSMutableDictionary dictionary];

    // Filmstrip scroll view (hidden until screen-share + cameras mode)
    self.filmstripScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.filmstripScrollView.drawsBackground = NO;
    self.filmstripScrollView.hasVerticalScroller = YES;
    self.filmstripScrollView.hasHorizontalScroller = NO;
    self.filmstripScrollView.autohidesScrollers = YES;
    self.filmstripScrollView.hidden = YES;
    self.filmstripContentView = [[NSView alloc] initWithFrame:NSZeroRect];
    self.filmstripContentView.wantsLayer = YES;
    self.filmstripScrollView.documentView = self.filmstripContentView;
    [self addSubview:self.filmstripScrollView];

    // Participant overlay — always on top of everything
    self.participantOverlay = [[InterParticipantOverlayView alloc] initWithFrame:self.bounds];
    self.participantOverlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.participantOverlay.hidden = YES;
    [self addSubview:self.participantOverlay];

    self.layoutMode = InterRemoteVideoLayoutModeNone;
    return self;
}

#pragma mark - Computed Properties

- (NSUInteger)remoteCameraCount {
    return self.remoteCameraViews.count;
}

#pragma mark - Tile Factory

/// Returns display name for a tile key. Screen share → "Screen Share", camera → participant ID.
- (NSString *)displayNameForTileKey:(NSString *)key {
    if ([key isEqualToString:kScreenShareTileKey]) {
        return @"Screen Share";
    }
    return key;
}

/// Wraps an InterRemoteVideoView in a tile (or returns existing tile).
- (InterRemoteVideoTileView *)tileForKey:(NSString *)key videoView:(InterRemoteVideoView *)videoView {
    InterRemoteVideoTileView *tile = self.tileViews[key];
    if (tile) {
        // Ensure the video view is still the correct one
        if (tile.videoView != videoView) {
            [tile.videoView removeFromSuperview];
            tile.videoView = videoView;
            videoView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            [tile addSubview:videoView positioned:NSWindowBelow relativeTo:tile.nameLabel];
        }
        return tile;
    }

    tile = [[InterRemoteVideoTileView alloc] initWithVideoView:videoView
                                                       tileKey:key
                                                   displayName:[self displayNameForTileKey:key]];
    tile.spotlightTarget = self;
    tile.spotlightAction = @selector(handleTileClicked:);
    self.tileViews[key] = tile;
    return tile;
}

/// Remove a tile by key.
- (void)removeTileForKey:(NSString *)key {
    InterRemoteVideoTileView *tile = self.tileViews[key];
    if (tile) {
        [tile removeFromSuperview];
        [self.tileViews removeObjectForKey:key];
    }
}

#pragma mark - View Factory (low-level)

- (InterRemoteVideoView *)cameraViewForParticipant:(NSString *)participantId {
    InterRemoteVideoView *view = self.remoteCameraViews[participantId];
    if (!view) {
        view = [[InterRemoteVideoView alloc] initWithFrame:self.bounds];
        view.hidden = YES;
        self.remoteCameraViews[participantId] = view;
        [self.cameraParticipantOrder addObject:participantId];
    }
    return view;
}

- (InterRemoteVideoView *)screenShareView {
    if (!self.remoteScreenShareView) {
        self.remoteScreenShareView = [[InterRemoteVideoView alloc] initWithFrame:self.bounds];
        self.remoteScreenShareView.hidden = YES;
    }
    return self.remoteScreenShareView;
}

- (void)removeCameraViewForParticipant:(NSString *)participantId {
    InterRemoteVideoView *view = self.remoteCameraViews[participantId];
    if (view) {
        [self removeTileForKey:participantId];
        [self.remoteCameraViews removeObjectForKey:participantId];
        [self.cameraParticipantOrder removeObject:participantId];
    }

    // If the removed camera was spotlighted, reset to auto
    if ([self.spotlightedTileKey isEqualToString:participantId]) {
        self.spotlightedTileKey = nil;
    }
}

#pragma mark - Frame Routing

- (void)handleRemoteCameraFrame:(CVPixelBufferRef)pixelBuffer fromParticipant:(NSString *)participantId {
    InterRemoteVideoView *view = self.remoteCameraViews[participantId];
    if (view) {
        [view updateFrame:pixelBuffer];
        return;
    }

    // First frame from a new participant
    CVPixelBufferRetain(pixelBuffer);
    dispatch_async(dispatch_get_main_queue(), ^{
        InterRemoteVideoView *v = [self cameraViewForParticipant:participantId];
        [v updateFrame:pixelBuffer];
        CVPixelBufferRelease(pixelBuffer);
        [self updateLayoutAnimated:YES];
    });
}

- (void)handleRemoteScreenShareFrame:(CVPixelBufferRef)pixelBuffer fromParticipant:(NSString *)participantId {
    InterRemoteVideoView *view = self.remoteScreenShareView;
    if (view && [self.screenShareParticipantId isEqualToString:participantId]) {
        [view updateFrame:pixelBuffer];
        return;
    }

    CVPixelBufferRetain(pixelBuffer);
    dispatch_async(dispatch_get_main_queue(), ^{
        self.screenShareParticipantId = participantId;
        InterRemoteVideoView *v = [self screenShareView];
        [v updateFrame:pixelBuffer];
        CVPixelBufferRelease(pixelBuffer);

        // Auto-spotlight screen share when it first appears
        if (!self.spotlightedTileKey) {
            self.spotlightedTileKey = kScreenShareTileKey;
        }
        [self updateLayoutAnimated:YES];
    });
}

- (void)handleRemoteTrackMuted:(NSUInteger)trackKind forParticipant:(NSString *)participantId {
    if (trackKind == InterTrackKindCamera) {
        InterRemoteVideoView *view = self.remoteCameraViews[participantId];
        [view clearFrame];
    } else if (trackKind == InterTrackKindScreenShare) {
        if ([self.screenShareParticipantId isEqualToString:participantId]) {
            [self.remoteScreenShareView clearFrame];
        }
    }
}

- (void)handleRemoteTrackUnmuted:(NSUInteger)trackKind forParticipant:(NSString *)participantId {
    // No-op: view exists, frames will flow again.
}

- (void)handleRemoteTrackEnded:(NSUInteger)trackKind forParticipant:(NSString *)participantId {
    if (trackKind == InterTrackKindCamera) {
        [self removeCameraViewForParticipant:participantId];
    } else if (trackKind == InterTrackKindScreenShare) {
        if ([self.screenShareParticipantId isEqualToString:participantId]) {
            [self removeTileForKey:kScreenShareTileKey];
            [self.remoteScreenShareView removeFromSuperview];
            self.remoteScreenShareView = nil;
            self.screenShareParticipantId = nil;

            // If screen share was spotlighted, reset to auto
            if ([self.spotlightedTileKey isEqualToString:kScreenShareTileKey]) {
                self.spotlightedTileKey = nil;
            }
        }
    }
    [self updateLayoutAnimated:YES];
}

#pragma mark - Spotlight

- (void)spotlightTile:(NSString *)tileKey {
    [self handleTileClicked:tileKey];
}

/// Called by tile click or programmatic spotlight.
- (void)handleTileClicked:(NSString *)tileKey {
    // If already spotlighted, un-spotlight (back to auto)
    if ([self.spotlightedTileKey isEqualToString:tileKey]) {
        // Reset to auto (screen share if present, else nil)
        if (self.screenShareParticipantId) {
            self.spotlightedTileKey = kScreenShareTileKey;
        } else {
            self.spotlightedTileKey = nil;
        }
    } else {
        self.spotlightedTileKey = tileKey;
    }
    [self updateLayoutAnimated:YES];
}

#pragma mark - Layout Engine

- (void)updateLayoutAnimated:(BOOL)animated {
    InterRemoteVideoLayoutMode newMode = [self computeLayoutMode];
    self.layoutMode = newMode;

    if (animated) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = kAnimationDuration;
            context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            [self applyCurrentLayoutAnimated:YES];
        } completionHandler:nil];
    } else {
        [self applyCurrentLayoutAnimated:NO];
    }
}

- (InterRemoteVideoLayoutMode)computeLayoutMode {
    NSUInteger camCount = self.remoteCameraViews.count;
    BOOL hasScreenShare = (self.screenShareParticipantId != nil);

    if (hasScreenShare && camCount > 0) {
        return InterRemoteVideoLayoutModeScreenShareWithCameras;
    }
    if (hasScreenShare) {
        return InterRemoteVideoLayoutModeScreenShareOnly;
    }
    if (camCount > 1) {
        return InterRemoteVideoLayoutModeMultiCamera;
    }
    if (camCount == 1) {
        return InterRemoteVideoLayoutModeSingleCamera;
    }
    return InterRemoteVideoLayoutModeNone;
}

/// Resolves the effective spotlight key. Returns nil when no spotlight should be shown.
- (NSString *)effectiveSpotlightKey {
    NSString *key = self.spotlightedTileKey;

    // Validate that the key still references a live tile
    if ([key isEqualToString:kScreenShareTileKey]) {
        return self.screenShareParticipantId ? key : nil;
    }
    if (key && self.remoteCameraViews[key]) {
        return key;
    }

    // Auto: spotlight screen share if present
    if (self.screenShareParticipantId) {
        return kScreenShareTileKey;
    }
    return nil;
}

- (void)applyCurrentLayoutAnimated:(BOOL)animated {
    CGFloat W = self.bounds.size.width;
    CGFloat H = self.bounds.size.height;

    InterRemoteVideoLayoutMode mode = self.layoutMode;

    // Detach all tiles from superview first — we'll re-parent as needed
    [self detachAllTilesFromHierarchy];
    self.filmstripScrollView.hidden = YES;

    switch (mode) {
        case InterRemoteVideoLayoutModeNone:
            break;

        case InterRemoteVideoLayoutModeSingleCamera: {
            // Single camera fills the entire area (no filmstrip)
            NSString *pid = self.cameraParticipantOrder.firstObject;
            if (!pid) break;
            InterRemoteVideoView *camView = self.remoteCameraViews[pid];
            if (!camView) break;

            InterRemoteVideoTileView *tile = [self tileForKey:pid videoView:camView];
            tile.nameLabel.hidden = YES; // no label in full-view mode
            tile.layer.cornerRadius = 0;
            [self addSubview:tile positioned:NSWindowBelow relativeTo:self.participantOverlay];
            tile.hidden = NO;
            camView.hidden = NO;
            [self setTile:tile frame:NSMakeRect(0, 0, W, H) animated:animated];
            break;
        }

        case InterRemoteVideoLayoutModeMultiCamera: {
            // Grid layout — all cameras equally
            NSRect gridRect = NSMakeRect(0, 0, W, H);
            [self arrangeCameraGridInRect:gridRect animated:animated];
            break;
        }

        case InterRemoteVideoLayoutModeScreenShareOnly: {
            // Screen share fills the entire area (no filmstrip)
            InterRemoteVideoView *ssView = self.remoteScreenShareView;
            if (!ssView) break;

            InterRemoteVideoTileView *tile = [self tileForKey:kScreenShareTileKey videoView:ssView];
            tile.nameLabel.hidden = YES;
            tile.layer.cornerRadius = 0;
            [self addSubview:tile positioned:NSWindowBelow relativeTo:self.participantOverlay];
            tile.hidden = NO;
            ssView.hidden = NO;
            [self setTile:tile frame:NSMakeRect(0, 0, W, H) animated:animated];
            break;
        }

        case InterRemoteVideoLayoutModeScreenShareWithCameras: {
            [self applyStageAndFilmstripLayoutAnimated:animated];
            break;
        }
    }
}

#pragma mark - Stage + Filmstrip Layout

- (void)applyStageAndFilmstripLayoutAnimated:(BOOL)animated {
    CGFloat W = self.bounds.size.width;
    CGFloat H = self.bounds.size.height;

    // Compute filmstrip width
    CGFloat filmstripW = W * kFilmstripWidthFraction;
    filmstripW = MAX(filmstripW, kFilmstripMinWidth);
    filmstripW = MIN(filmstripW, kFilmstripMaxWidth);

    CGFloat stageW = W - filmstripW;

    // --- Determine spotlight and filmstrip tile keys ---
    NSString *spotlightKey = [self effectiveSpotlightKey];
    NSMutableArray<NSString *> *filmstripKeys = [NSMutableArray array];

    // Screen share tile
    if (self.screenShareParticipantId) {
        if (![kScreenShareTileKey isEqualToString:spotlightKey]) {
            [filmstripKeys addObject:kScreenShareTileKey];
        }
    }

    // Camera tiles
    for (NSString *pid in self.cameraParticipantOrder) {
        if (![pid isEqualToString:spotlightKey]) {
            [filmstripKeys addObject:pid];
        }
    }

    // --- Main stage ---
    InterRemoteVideoView *spotlightVideoView = nil;
    if ([spotlightKey isEqualToString:kScreenShareTileKey]) {
        spotlightVideoView = self.remoteScreenShareView;
    } else if (spotlightKey) {
        spotlightVideoView = self.remoteCameraViews[spotlightKey];
    }

    if (spotlightVideoView) {
        InterRemoteVideoTileView *stageTile = [self tileForKey:spotlightKey videoView:spotlightVideoView];
        stageTile.nameLabel.hidden = NO;
        stageTile.layer.cornerRadius = 8.0;
        [self addSubview:stageTile positioned:NSWindowBelow relativeTo:self.filmstripScrollView];
        stageTile.hidden = NO;
        spotlightVideoView.hidden = NO;

        NSRect stageFrame = NSMakeRect(0, kFilmstripPadding,
                                       stageW - kFilmstripPadding, H - 2 * kFilmstripPadding);
        [self setTile:stageTile frame:stageFrame animated:animated];
    }

    // --- Filmstrip ---
    if (filmstripKeys.count == 0) {
        self.filmstripScrollView.hidden = YES;
        return;
    }

    self.filmstripScrollView.hidden = NO;
    NSRect filmstripFrame = NSMakeRect(stageW, 0, filmstripW, H);
    if (animated) {
        self.filmstripScrollView.animator.frame = filmstripFrame;
    } else {
        self.filmstripScrollView.frame = filmstripFrame;
    }

    // Remove old subviews from filmstrip content
    for (NSView *sub in [self.filmstripContentView.subviews copy]) {
        [sub removeFromSuperview];
    }

    CGFloat tileW = filmstripW - 2 * kFilmstripPadding;
    CGFloat tileH = tileW * 9.0 / 16.0;  // 16:9 aspect
    CGFloat totalH = filmstripKeys.count * tileH + (filmstripKeys.count - 1) * kFilmstripTileGap + 2 * kFilmstripPadding;
    totalH = MAX(totalH, H);

    self.filmstripContentView.frame = NSMakeRect(0, 0, filmstripW, totalH);

    // Stack tiles top-to-bottom. NSView y=0 is bottom, so we invert.
    for (NSUInteger i = 0; i < filmstripKeys.count; i++) {
        NSString *key = filmstripKeys[i];
        InterRemoteVideoView *videoView = nil;

        if ([key isEqualToString:kScreenShareTileKey]) {
            videoView = self.remoteScreenShareView;
        } else {
            videoView = self.remoteCameraViews[key];
        }
        if (!videoView) continue;

        InterRemoteVideoTileView *tile = [self tileForKey:key videoView:videoView];
        tile.nameLabel.hidden = NO;
        tile.layer.cornerRadius = 8.0;
        tile.hidden = NO;
        videoView.hidden = NO;

        CGFloat y = totalH - kFilmstripPadding - (i + 1) * tileH - i * kFilmstripTileGap;
        NSRect tileFrame = NSMakeRect(kFilmstripPadding, y, tileW, tileH);

        [self.filmstripContentView addSubview:tile];
        if (animated) {
            tile.animator.frame = tileFrame;
        } else {
            tile.frame = tileFrame;
        }
    }
}

#pragma mark - Camera Grid

- (void)arrangeCameraGridInRect:(NSRect)rect animated:(BOOL)animated {
    NSArray<NSString *> *participants = [self.cameraParticipantOrder copy];
    NSUInteger count = participants.count;
    if (count == 0) return;

    NSUInteger cols, rows;
    if (count <= 2) {
        cols = count;
        rows = 1;
    } else {
        cols = 2;
        rows = (count + 1) / 2;
    }

    CGFloat gap = 6.0;
    CGFloat totalGapW = (cols - 1) * gap;
    CGFloat totalGapH = (rows - 1) * gap;
    CGFloat cellW = (rect.size.width - totalGapW) / cols;
    CGFloat cellH = (rect.size.height - totalGapH) / rows;

    for (NSUInteger i = 0; i < count; i++) {
        NSString *pid = participants[i];
        InterRemoteVideoView *view = self.remoteCameraViews[pid];
        if (!view) continue;

        InterRemoteVideoTileView *tile = [self tileForKey:pid videoView:view];
        tile.nameLabel.hidden = NO;
        tile.layer.cornerRadius = 8.0;
        [self addSubview:tile positioned:NSWindowBelow relativeTo:self.participantOverlay];
        tile.hidden = NO;
        view.hidden = NO;

        NSUInteger col = i % cols;
        NSUInteger row = i / cols;
        CGFloat x = rect.origin.x + col * (cellW + gap);
        CGFloat y = rect.origin.y + (rows - 1 - row) * (cellH + gap);
        NSRect frame = NSMakeRect(x, y, cellW, cellH);

        [self setTile:tile frame:frame animated:animated];
    }
}

#pragma mark - Tile Helpers

- (void)setTile:(InterRemoteVideoTileView *)tile frame:(NSRect)frame animated:(BOOL)animated {
    if (animated) {
        tile.animator.frame = frame;
    } else {
        tile.frame = frame;
    }
}

/// Remove all tiles from their current superview without destroying them.
- (void)detachAllTilesFromHierarchy {
    for (InterRemoteVideoTileView *tile in self.tileViews.allValues) {
        [tile removeFromSuperview];
        tile.hidden = YES;
    }
}

#pragma mark - Resize

- (void)setFrame:(NSRect)frame {
    [super setFrame:frame];
    [self applyCurrentLayoutAnimated:NO];
}

#pragma mark - Teardown

- (void)teardown {
    // Remove all tiles
    for (InterRemoteVideoTileView *tile in self.tileViews.allValues) {
        [tile removeFromSuperview];
    }
    [self.tileViews removeAllObjects];

    // Clean camera state
    for (InterRemoteVideoView *view in self.remoteCameraViews.allValues) {
        [view removeFromSuperview];
    }
    [self.remoteCameraViews removeAllObjects];
    [self.cameraParticipantOrder removeAllObjects];

    // Clean screen share state
    [self.remoteScreenShareView removeFromSuperview];
    self.remoteScreenShareView = nil;
    self.screenShareParticipantId = nil;
    self.spotlightedTileKey = nil;

    // Clean filmstrip
    for (NSView *sub in [self.filmstripContentView.subviews copy]) {
        [sub removeFromSuperview];
    }
    self.filmstripScrollView.hidden = YES;

    self.participantOverlay.hidden = YES;
    self.layoutMode = InterRemoteVideoLayoutModeNone;
}

@end
