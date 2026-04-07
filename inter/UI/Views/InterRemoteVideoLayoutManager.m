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
@property (nonatomic, assign) BOOL isSpeaking;
@property (nonatomic, strong) NSTrackingArea *hoverTrackingArea;
/// [Phase 8.2.3] Hand-raise badge (✋ emoji in top-left corner).
@property (nonatomic, strong) NSTextField *handRaiseBadge;
@property (nonatomic, assign) BOOL handRaised;
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

    // [Phase 8.2.3] Hand raise badge — top-left corner
    self.handRaiseBadge = [NSTextField labelWithString:@"✋"];
    self.handRaiseBadge.font = [NSFont systemFontOfSize:16];
    self.handRaiseBadge.frame = NSMakeRect(4, 0, 24, 24);
    [self.handRaiseBadge setWantsLayer:YES];
    self.handRaiseBadge.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.6].CGColor;
    self.handRaiseBadge.layer.cornerRadius = 4.0;
    self.handRaiseBadge.alignment = NSTextAlignmentCenter;
    self.handRaiseBadge.hidden = YES;
    [self addSubview:self.handRaiseBadge];

    return self;
}

- (void)setHandRaised:(BOOL)handRaised {
    _handRaised = handRaised;
    self.handRaiseBadge.hidden = !handRaised;
}

- (void)layout {
    [super layout];
    NSRect b = self.bounds;
    // Video fills entire tile
    self.videoView.frame = b;
    // Name label at bottom, 22px tall
    CGFloat labelH = 22.0;
    self.nameLabel.frame = NSMakeRect(0, 0, b.size.width, labelH);
    // Hand raise badge at top-left
    self.handRaiseBadge.frame = NSMakeRect(4, b.size.height - 28, 24, 24);
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
    if (!self.isSpeaking) {
        self.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.5].CGColor;
        self.layer.borderWidth = 2.0;
    }
}

- (void)mouseExited:(NSEvent *)event {
    self.isHovered = NO;
    if (!self.isSpeaking) {
        self.layer.borderColor = nil;
        self.layer.borderWidth = 0.0;
    }
}

- (void)setIsSpeaking:(BOOL)isSpeaking {
    _isSpeaking = isSpeaking;
    if (isSpeaking) {
        self.layer.borderColor = [NSColor systemGreenColor].CGColor;
        self.layer.borderWidth = 3.0;
    } else if (self.isHovered) {
        self.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.5].CGColor;
        self.layer.borderWidth = 2.0;
    } else {
        self.layer.borderColor = nil;
        self.layer.borderWidth = 0.0;
    }
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

/// Per-participant display names, keyed by participant identity string.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *participantDisplayNames;
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

// -- Participant count badge --

/// Small label showing participant count (top-right corner).
@property (nonatomic, strong) NSTextField *participantCountBadge;

// -- Phase 7: Pagination state --

/// Current grid page (0-based).
@property (nonatomic, assign) NSUInteger currentGridPage;

/// Page indicator bar at bottom of grid area.
@property (nonatomic, strong) NSView *pageIndicatorBar;

/// Left arrow button for page navigation.
@property (nonatomic, strong) NSButton *pageLeftButton;

/// Right arrow button for page navigation.
@property (nonatomic, strong) NSButton *pageRightButton;

/// Page label showing "Page X of Y".
@property (nonatomic, strong) NSTextField *pageLabel;

/// Set of participant IDs currently visible (for track visibility callbacks).
@property (nonatomic, strong) NSMutableSet<NSString *> *visibleParticipantIds;

/// Tile recycling pool — reusable InterRemoteVideoView instances. [Phase 7.3.3]
@property (nonatomic, strong) NSMutableArray<InterRemoteVideoView *> *recycledVideoViews;

/// Spotlight key prior to auto-speaker-spotlight, for restoring after speaker stops. [Phase 7.4.2]
@property (nonatomic, copy, nullable) NSString *preAutoSpotlightKey;

/// Timer to revert auto-speaker-spotlight 3s after speaker stops. [Phase 7.4.2]
@property (nonatomic, strong, nullable) NSTimer *autoSpotlightRevertTimer;

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
static const NSUInteger kDefaultMaxTilesPerPage = 25;  // Phase 7: 5×5 grid max before pagination
static const CGFloat kPageIndicatorHeight    = 30.0;
static const CGFloat kPageIndicatorPadding   = 8.0;

@implementation InterRemoteVideoLayoutManager

#pragma mark - Lifecycle

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;

    self.wantsLayer = YES;
    self.layer.backgroundColor = [NSColor blackColor].CGColor;

    self.participantDisplayNames = [NSMutableDictionary dictionary];
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

    // Participant count badge — top-right corner
    self.participantCountBadge = [NSTextField labelWithString:@""];
    self.participantCountBadge.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    self.participantCountBadge.textColor = [NSColor whiteColor];
    self.participantCountBadge.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.6];
    self.participantCountBadge.drawsBackground = YES;
    self.participantCountBadge.alignment = NSTextAlignmentCenter;
    self.participantCountBadge.wantsLayer = YES;
    self.participantCountBadge.layer.cornerRadius = 10.0;
    self.participantCountBadge.layer.masksToBounds = YES;
    self.participantCountBadge.hidden = YES;
    [self addSubview:self.participantCountBadge];

    // Phase 7: Pagination UI
    self.maxTilesPerPage = kDefaultMaxTilesPerPage;
    self.currentGridPage = 0;
    self.visibleParticipantIds = [NSMutableSet set];
    self.recycledVideoViews = [NSMutableArray array];

    self.pageIndicatorBar = [[NSView alloc] initWithFrame:NSZeroRect];
    self.pageIndicatorBar.wantsLayer = YES;
    self.pageIndicatorBar.layer.backgroundColor = [NSColor colorWithWhite:0.1 alpha:0.85].CGColor;
    self.pageIndicatorBar.layer.cornerRadius = 6.0;
    self.pageIndicatorBar.hidden = YES;
    [self addSubview:self.pageIndicatorBar];

    self.pageLeftButton = [NSButton buttonWithTitle:@"◀" target:self action:@selector(previousGridPage)];
    self.pageLeftButton.bezelStyle = NSBezelStyleRounded;
    self.pageLeftButton.font = [NSFont systemFontOfSize:14];
    [self.pageIndicatorBar addSubview:self.pageLeftButton];

    self.pageRightButton = [NSButton buttonWithTitle:@"▶" target:self action:@selector(nextGridPage)];
    self.pageRightButton.bezelStyle = NSBezelStyleRounded;
    self.pageRightButton.font = [NSFont systemFontOfSize:14];
    [self.pageIndicatorBar addSubview:self.pageRightButton];

    self.pageLabel = [NSTextField labelWithString:@""];
    self.pageLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.pageLabel.textColor = [NSColor whiteColor];
    self.pageLabel.alignment = NSTextAlignmentCenter;
    [self.pageIndicatorBar addSubview:self.pageLabel];

    self.layoutMode = InterRemoteVideoLayoutModeNone;
    self.allowsManualSpotlightSelection = YES;
    self.preferStageLayoutForMultipleCameras = NO;
    self.compactPreviewMode = NO;
    return self;
}

#pragma mark - Computed Properties

- (NSUInteger)remoteCameraCount {
    return self.remoteCameraViews.count;
}

#pragma mark - Tile Factory

/// Returns display name for a tile key. Screen share → "Screen Share", camera → registered display name.
- (NSString *)displayNameForTileKey:(NSString *)key {
    if ([key isEqualToString:kScreenShareTileKey]) {
        return @"Screen Share";
    }
    NSString *registeredName = self.participantDisplayNames[key];
    return registeredName.length > 0 ? registeredName : key;
}

- (void)registerDisplayName:(NSString *)displayName forParticipant:(NSString *)participantId {
    if (!participantId || participantId.length == 0) return;
    self.participantDisplayNames[participantId] = displayName ?: participantId;

    // Update existing tile label if the tile was already created before the name arrived.
    InterRemoteVideoTileView *tile = self.tileViews[participantId];
    if (tile) {
        tile.nameLabel.stringValue = [self displayNameForTileKey:participantId];
    }
}

// [Phase 8.2.3] Show/hide hand-raise badge on participant tile.
- (void)setHandRaised:(BOOL)raised forParticipant:(NSString *)participantId {
    if (!participantId || participantId.length == 0) return;
    InterRemoteVideoTileView *tile = self.tileViews[participantId];
    if (tile) {
        tile.handRaised = raised;
    }
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

    // Apply active speaker highlight immediately if this new tile matches the
    // current speaker. Fixes a race where setActiveSpeakerIdentity: fires before
    // the tile exists (e.g. KVO initial on mode entry while the remote participant
    // is already speaking). Without this, the green border never appears until the
    // speaker briefly pauses and resumes (triggering a value change).
    if (![key isEqualToString:kScreenShareTileKey] &&
        _activeSpeakerIdentity.length > 0 &&
        [key isEqualToString:_activeSpeakerIdentity]) {
        tile.isSpeaking = YES;
    }

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
        // Phase 7.3.3: Try recycling pool before creating new
        if (self.recycledVideoViews.count > 0) {
            view = self.recycledVideoViews.lastObject;
            [self.recycledVideoViews removeLastObject];
            view.hidden = YES;
        } else {
            view = [[InterRemoteVideoView alloc] initWithFrame:self.bounds];
            view.hidden = YES;
        }
        view.isMirrored = YES;  // Mirror camera feeds for natural appearance
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
        // Phase 7.3.3: Recycle view instead of destroying it (up to 10 pooled).
        // Beyond 10, shut down rendering to cap memory usage.
        [self removeTileForKey:participantId];
        [view clearFrame];
        if (self.recycledVideoViews.count < 10) {
            [view removeFromSuperview];
            [self.recycledVideoViews addObject:view];
        } else {
            [view shutdownRenderingSynchronously];
        }
        [self.remoteCameraViews removeObjectForKey:participantId];
        [self.cameraParticipantOrder removeObject:participantId];
        [self.participantDisplayNames removeObjectForKey:participantId];
    }

    // Remove from visible set
    [self.visibleParticipantIds removeObject:participantId];

    // If the removed camera was spotlighted, reset to auto
    if ([self.spotlightedTileKey isEqualToString:participantId]) {
        [self updateManualSpotlightTileKey:nil];
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
            [self.remoteScreenShareView shutdownRenderingSynchronously];
            [self removeTileForKey:kScreenShareTileKey];
            [self.remoteScreenShareView removeFromSuperview];
            self.remoteScreenShareView = nil;
            self.screenShareParticipantId = nil;

            // If screen share was spotlighted, reset to auto
            if ([self.spotlightedTileKey isEqualToString:kScreenShareTileKey]) {
                [self updateManualSpotlightTileKey:nil];
            }
        }
    }
    [self updateLayoutAnimated:YES];
}

#pragma mark - Spotlight

- (void)spotlightTile:(NSString *)tileKey {
    [self handleTileClicked:tileKey];
}

- (void)setManualSpotlightTileKey:(NSString * _Nullable)tileKey animated:(BOOL)animated {
    [self updateManualSpotlightTileKey:tileKey];
    [self updateLayoutAnimated:animated];
}

/// Called by tile click or programmatic spotlight.
- (void)handleTileClicked:(NSString *)tileKey {
    if (!self.allowsManualSpotlightSelection) {
        return;
    }

    // If the clicked tile is already in the spotlight, do nothing — the user
    // can bring a different tile to spotlight by clicking it in the filmstrip.
    NSString *effectiveKey = [self effectiveSpotlightKey];
    if ([effectiveKey isEqualToString:tileKey]) {
        return;
    }

    [self updateManualSpotlightTileKey:tileKey];
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

    dispatch_block_t handler = self.layoutStateChangedHandler;
    if (handler) {
        handler();
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
        if (self.preferStageLayoutForMultipleCameras) {
            return InterRemoteVideoLayoutModeScreenShareWithCameras;
        }
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
    if (self.preferStageLayoutForMultipleCameras && self.cameraParticipantOrder.firstObject != nil) {
        return self.cameraParticipantOrder.firstObject;
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
    [self.supplementalFilmstripView removeFromSuperview];

    if (self.compactPreviewMode) {
        [self applyCompactSpotlightLayoutAnimated:animated];
        return;
    }

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
            tile.isSpeaking = [pid isEqualToString:self.activeSpeakerIdentity];
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

- (void)applyCompactSpotlightLayoutAnimated:(BOOL)animated {
    CGFloat W = self.bounds.size.width;
    CGFloat H = self.bounds.size.height;

    NSString *spotlightKey = [self effectiveSpotlightKey];
    if (spotlightKey.length == 0) {
        if (self.screenShareParticipantId) {
            spotlightKey = kScreenShareTileKey;
        } else {
            spotlightKey = self.cameraParticipantOrder.firstObject;
        }
    }

    InterRemoteVideoView *spotlightVideoView = nil;
    if ([spotlightKey isEqualToString:kScreenShareTileKey]) {
        spotlightVideoView = self.remoteScreenShareView;
    } else if (spotlightKey.length > 0) {
        spotlightVideoView = self.remoteCameraViews[spotlightKey];
    }

    if (!spotlightVideoView) {
        return;
    }

    InterRemoteVideoTileView *tile = [self tileForKey:spotlightKey videoView:spotlightVideoView];
    tile.nameLabel.hidden = YES;
    tile.layer.cornerRadius = 8.0;
    if (![spotlightKey isEqualToString:kScreenShareTileKey]) {
        tile.isSpeaking = [spotlightKey isEqualToString:self.activeSpeakerIdentity];
    }
    [self addSubview:tile positioned:NSWindowBelow relativeTo:self.participantOverlay];
    tile.hidden = NO;
    spotlightVideoView.hidden = NO;
    [self setTile:tile frame:NSMakeRect(0, 0, W, H) animated:animated];
}

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
        if (![spotlightKey isEqualToString:kScreenShareTileKey]) {
            stageTile.isSpeaking = [spotlightKey isEqualToString:self.activeSpeakerIdentity];
        }
        [self addSubview:stageTile positioned:NSWindowBelow relativeTo:self.filmstripScrollView];
        stageTile.hidden = NO;
        spotlightVideoView.hidden = NO;

        NSRect stageFrame = NSMakeRect(0, kFilmstripPadding,
                                       stageW - kFilmstripPadding, H - 2 * kFilmstripPadding);
        [self setTile:stageTile frame:stageFrame animated:animated];

        // Phase 7.3.4: Request high-res for spotlighted view
        if (![spotlightKey isEqualToString:kScreenShareTileKey]) {
            [self notifyDimensionsChange:CGSizeMake(1280, 720) forParticipant:spotlightKey];
        }
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

    BOOL hasSupplementalFilmstripView = (self.supplementalFilmstripView != nil);
    CGFloat tileW = filmstripW - 2 * kFilmstripPadding;
    CGFloat tileH = tileW * 9.0 / 16.0;  // 16:9 aspect
    NSUInteger itemCount = filmstripKeys.count + (hasSupplementalFilmstripView ? 1 : 0);
    CGFloat totalH = itemCount * tileH + (MAX(itemCount, 1) - 1) * kFilmstripTileGap + 2 * kFilmstripPadding;
    totalH = MAX(totalH, H);

    self.filmstripContentView.frame = NSMakeRect(0, 0, filmstripW, totalH);

    NSUInteger itemIndex = 0;
    if (hasSupplementalFilmstripView) {
        NSView *supplementalView = self.supplementalFilmstripView;
        CGFloat y = totalH - kFilmstripPadding - (itemIndex + 1) * tileH - itemIndex * kFilmstripTileGap;
        NSRect supplementalFrame = NSMakeRect(kFilmstripPadding, y, tileW, tileH);
        supplementalView.hidden = NO;
        [self.filmstripContentView addSubview:supplementalView];
        if (animated) {
            supplementalView.animator.frame = supplementalFrame;
        } else {
            supplementalView.frame = supplementalFrame;
        }
        itemIndex += 1;
    }

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

        // Apply active speaker highlight in filmstrip tiles too
        if (![key isEqualToString:kScreenShareTileKey]) {
            tile.isSpeaking = [key isEqualToString:self.activeSpeakerIdentity];
        }

        NSUInteger visualIndex = itemIndex + i;
        CGFloat y = totalH - kFilmstripPadding - (visualIndex + 1) * tileH - visualIndex * kFilmstripTileGap;
        NSRect tileFrame = NSMakeRect(kFilmstripPadding, y, tileW, tileH);

        [self.filmstripContentView addSubview:tile];
        if (animated) {
            tile.animator.frame = tileFrame;
        } else {
            tile.frame = tileFrame;
        }

        // Phase 7.3.4: Request low-res for filmstrip tiles
        if (![key isEqualToString:kScreenShareTileKey]) {
            [self notifyDimensionsChange:CGSizeMake(320, 180) forParticipant:key];
        }
    }
}

#pragma mark - Camera Grid (Phase 7: Adaptive + Paginated)

/// Compute optimal grid dimensions for a given participant count.
/// 1 → 1×1, 2 → 2×1, 3-4 → 2×2, 5-6 → 3×2, 7-9 → 3×3,
/// 10-12 → 4×3, 13-16 → 4×4, 17-20 → 5×4, 21-25 → 5×5.
- (void)gridDimensionsForCount:(NSUInteger)count cols:(NSUInteger *)outCols rows:(NSUInteger *)outRows {
    NSUInteger cols, rows;
    if (count <= 1) {
        cols = 1; rows = 1;
    } else if (count <= 2) {
        cols = 2; rows = 1;
    } else if (count <= 4) {
        cols = 2; rows = 2;
    } else if (count <= 6) {
        cols = 3; rows = 2;
    } else if (count <= 9) {
        cols = 3; rows = 3;
    } else if (count <= 12) {
        cols = 4; rows = 3;
    } else if (count <= 16) {
        cols = 4; rows = 4;
    } else if (count <= 20) {
        cols = 5; rows = 4;
    } else {
        cols = 5; rows = 5;
    }
    *outCols = cols;
    *outRows = rows;
}

- (NSUInteger)totalGridPages {
    NSUInteger count = self.cameraParticipantOrder.count;
    if (count <= self.maxTilesPerPage) return 1;
    return (count + self.maxTilesPerPage - 1) / self.maxTilesPerPage;
}

- (void)nextGridPage {
    NSUInteger total = self.totalGridPages;
    if (total <= 1) return;
    self.currentGridPage = (self.currentGridPage + 1) % total;
    [self updateLayoutAnimated:YES];
}

- (void)previousGridPage {
    NSUInteger total = self.totalGridPages;
    if (total <= 1) return;
    if (self.currentGridPage == 0) {
        self.currentGridPage = total - 1;
    } else {
        self.currentGridPage -= 1;
    }
    [self updateLayoutAnimated:YES];
}

- (void)goToGridPage:(NSUInteger)page {
    NSUInteger total = self.totalGridPages;
    if (total <= 1) {
        self.currentGridPage = 0;
        return;
    }
    self.currentGridPage = MIN(page, total - 1);
    [self updateLayoutAnimated:YES];
}

- (void)arrangeCameraGridInRect:(NSRect)rect animated:(BOOL)animated {
    NSArray<NSString *> *allParticipants = [self.cameraParticipantOrder copy];
    NSUInteger totalCount = allParticipants.count;
    if (totalCount == 0) return;

    NSUInteger maxPerPage = self.maxTilesPerPage;
    BOOL isPaginated = (totalCount > maxPerPage);
    NSUInteger pages = self.totalGridPages;

    // Clamp current page to valid range
    if (self.currentGridPage >= pages) {
        self.currentGridPage = (pages > 0) ? pages - 1 : 0;
    }

    // Determine which participants are on the current page
    NSUInteger startIdx = self.currentGridPage * maxPerPage;
    NSUInteger endIdx = MIN(startIdx + maxPerPage, totalCount);
    NSArray<NSString *> *pageParticipants = [allParticipants subarrayWithRange:NSMakeRange(startIdx, endIdx - startIdx)];
    NSUInteger count = pageParticipants.count;

    // Phase 7.3.3: Track visibility changes for paged-out participants
    NSMutableSet<NSString *> *newVisibleSet = [NSMutableSet setWithArray:pageParticipants];
    [self notifyVisibilityChangesFrom:self.visibleParticipantIds to:newVisibleSet];
    self.visibleParticipantIds = newVisibleSet;

    // Reserve space for page indicator if paginated
    NSRect gridRect = rect;
    if (isPaginated) {
        gridRect.size.height -= (kPageIndicatorHeight + kPageIndicatorPadding);
        gridRect.origin.y += (kPageIndicatorHeight + kPageIndicatorPadding);
        [self updatePageIndicatorInRect:rect pageIndex:self.currentGridPage totalPages:pages];
    } else {
        self.pageIndicatorBar.hidden = YES;
    }

    // Phase 7.3.1: Dynamic grid dimensions
    NSUInteger cols, rows;
    [self gridDimensionsForCount:count cols:&cols rows:&rows];

    CGFloat gap = 6.0;
    CGFloat totalGapW = (cols > 0) ? (cols - 1) * gap : 0;
    CGFloat totalGapH = (rows > 0) ? (rows - 1) * gap : 0;
    CGFloat cellW = (gridRect.size.width - totalGapW) / MAX(cols, 1);
    CGFloat cellH = (gridRect.size.height - totalGapH) / MAX(rows, 1);

    // Check if the last row is incomplete
    BOOL lastRowIncomplete = (count > 0) && (count % cols != 0);
    NSUInteger lastRowCount = lastRowIncomplete ? (count % cols) : cols;
    NSUInteger lastRow = (count > 0) ? ((count - 1) / cols) : 0;

    // Phase 7.3.4: Determine quality based on tile size for stage vs filmstrip
    CGSize tileDimensions = CGSizeMake(cellW, cellH);
    CGSize qualityDimensions;
    if (count <= 4) {
        qualityDimensions = CGSizeMake(1280, 720);  // High quality for few participants
    } else if (count <= 9) {
        qualityDimensions = CGSizeMake(640, 360);  // Medium quality
    } else if (count <= 16) {
        qualityDimensions = CGSizeMake(480, 270);  // Lower quality
    } else {
        qualityDimensions = CGSizeMake(320, 180);  // Thumbnail quality for 17-25 per page
    }

    for (NSUInteger i = 0; i < count; i++) {
        NSString *pid = pageParticipants[i];
        InterRemoteVideoView *view = self.remoteCameraViews[pid];
        if (!view) continue;

        InterRemoteVideoTileView *tile = [self tileForKey:pid videoView:view];
        tile.nameLabel.hidden = NO;
        tile.layer.cornerRadius = 8.0;
        [self addSubview:tile positioned:NSWindowBelow relativeTo:self.participantOverlay];
        tile.hidden = NO;
        view.hidden = NO;

        // Apply active speaker highlight
        tile.isSpeaking = [pid isEqualToString:self.activeSpeakerIdentity];

        NSUInteger col = i % cols;
        NSUInteger row = i / cols;

        CGFloat x, y;
        y = gridRect.origin.y + (rows - 1 - row) * (cellH + gap);

        // Center the last row if it has fewer tiles than cols
        if (row == lastRow && lastRowIncomplete) {
            CGFloat lastRowTotalW = lastRowCount * cellW + (lastRowCount - 1) * gap;
            CGFloat offsetX = (gridRect.size.width - lastRowTotalW) / 2.0;
            x = gridRect.origin.x + offsetX + col * (cellW + gap);
        } else {
            x = gridRect.origin.x + col * (cellW + gap);
        }

        NSRect frame = NSMakeRect(x, y, cellW, cellH);
        [self setTile:tile frame:frame animated:animated];

        // Phase 7.3.4: Request appropriate quality for this tile
        [self notifyDimensionsChange:qualityDimensions forParticipant:pid];
    }
}

#pragma mark - Page Indicator

- (void)updatePageIndicatorInRect:(NSRect)containerRect pageIndex:(NSUInteger)page totalPages:(NSUInteger)total {
    self.pageIndicatorBar.hidden = NO;

    CGFloat barW = 180.0;
    CGFloat barH = kPageIndicatorHeight;
    CGFloat barX = (containerRect.size.width - barW) / 2.0;
    CGFloat barY = containerRect.origin.y + kPageIndicatorPadding;
    self.pageIndicatorBar.frame = NSMakeRect(barX, barY, barW, barH);

    // Layout: [◀] [Page X of Y] [▶]
    CGFloat btnW = 30.0;
    self.pageLeftButton.frame = NSMakeRect(4, 2, btnW, barH - 4);
    self.pageRightButton.frame = NSMakeRect(barW - btnW - 4, 2, btnW, barH - 4);
    self.pageLabel.frame = NSMakeRect(btnW + 4, 0, barW - 2 * (btnW + 8), barH);
    self.pageLabel.stringValue = [NSString stringWithFormat:@"Page %lu of %lu",
                                  (unsigned long)(page + 1), (unsigned long)total];

    self.pageLeftButton.enabled = (total > 1);
    self.pageRightButton.enabled = (total > 1);
}

#pragma mark - Visibility & Quality Notifications [Phase 7]

/// Notify delegate about participants that became visible or hidden due to pagination.
- (void)notifyVisibilityChangesFrom:(NSMutableSet<NSString *> *)oldSet to:(NSMutableSet<NSString *> *)newSet {
    id<InterRemoteVideoLayoutManagerDelegate> delegate = self.layoutDelegate;
    if (!delegate) return;

    // Participants that were visible but are now hidden
    for (NSString *pid in oldSet) {
        if (![newSet containsObject:pid]) {
            if ([delegate respondsToSelector:@selector(layoutManager:didChangeVisibility:forParticipant:source:)]) {
                [delegate layoutManager:self didChangeVisibility:NO forParticipant:pid source:0 /* camera */];
            }
        }
    }

    // Participants that were hidden but are now visible
    for (NSString *pid in newSet) {
        if (![oldSet containsObject:pid]) {
            if ([delegate respondsToSelector:@selector(layoutManager:didChangeVisibility:forParticipant:source:)]) {
                [delegate layoutManager:self didChangeVisibility:YES forParticipant:pid source:0 /* camera */];
            }
        }
    }
}

/// Notify delegate of preferred render dimensions for a participant's camera track.
- (void)notifyDimensionsChange:(CGSize)dimensions forParticipant:(NSString *)participantId {
    id<InterRemoteVideoLayoutManagerDelegate> delegate = self.layoutDelegate;
    if (!delegate) return;
    if ([delegate respondsToSelector:@selector(layoutManager:didRequestDimensions:forParticipant:source:)]) {
        [delegate layoutManager:self didRequestDimensions:dimensions forParticipant:participantId source:0 /* camera */];
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
    [self updateParticipantCountBadge];
}

#pragma mark - Keyboard Navigation (Phase 7)

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)keyDown:(NSEvent *)event {
    // Arrow keys for grid page navigation
    if (self.totalGridPages > 1 && self.layoutMode == InterRemoteVideoLayoutModeMultiCamera) {
        if (event.keyCode == 123) { // Left arrow
            [self previousGridPage];
            return;
        } else if (event.keyCode == 124) { // Right arrow
            [self nextGridPage];
            return;
        }
    }
    [super keyDown:event];
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
        [view shutdownRenderingSynchronously];
        [view removeFromSuperview];
    }
    [self.remoteCameraViews removeAllObjects];
    [self.cameraParticipantOrder removeAllObjects];
    [self.participantDisplayNames removeAllObjects];

    // Clean screen share state
    [self.remoteScreenShareView shutdownRenderingSynchronously];
    [self.remoteScreenShareView removeFromSuperview];
    self.remoteScreenShareView = nil;
    self.screenShareParticipantId = nil;
    [self updateManualSpotlightTileKey:nil];

    // Clean filmstrip
    for (NSView *sub in [self.filmstripContentView.subviews copy]) {
        [sub removeFromSuperview];
    }
    self.filmstripScrollView.hidden = YES;

    // Phase 7: Clean recycling pool and pagination state
    for (InterRemoteVideoView *recycled in self.recycledVideoViews) {
        [recycled shutdownRenderingSynchronously];
    }
    [self.recycledVideoViews removeAllObjects];
    [self.visibleParticipantIds removeAllObjects];
    self.currentGridPage = 0;
    self.pageIndicatorBar.hidden = YES;
    [self.autoSpotlightRevertTimer invalidate];
    self.autoSpotlightRevertTimer = nil;
    self.preAutoSpotlightKey = nil;

    self.participantOverlay.hidden = YES;
    self.layoutMode = InterRemoteVideoLayoutModeNone;
}

#pragma mark - Active Speaker Highlight

- (void)setActiveSpeakerIdentity:(NSString *)activeSpeakerIdentity {
    if ([_activeSpeakerIdentity isEqualToString:activeSpeakerIdentity]) {
        return;
    }

    NSString *previousSpeaker = _activeSpeakerIdentity;
    _activeSpeakerIdentity = [activeSpeakerIdentity copy];

    // Remove highlight from previous speaker's tile
    if (previousSpeaker.length > 0) {
        InterRemoteVideoTileView *oldTile = self.tileViews[previousSpeaker];
        if (oldTile) {
            oldTile.isSpeaking = NO;
        }
    }

    // Add highlight to new speaker's tile
    if (_activeSpeakerIdentity.length > 0) {
        InterRemoteVideoTileView *newTile = self.tileViews[_activeSpeakerIdentity];
        if (newTile) {
            newTile.isSpeaking = YES;
        }
    }

    // Phase 7.4.2: Auto-spotlight active speaker in stage+filmstrip mode
    if (self.autoSpotlightActiveSpeaker &&
        (self.layoutMode == InterRemoteVideoLayoutModeScreenShareWithCameras ||
         (self.layoutMode == InterRemoteVideoLayoutModeMultiCamera && self.preferStageLayoutForMultipleCameras))) {

        // Cancel any pending revert timer
        [self.autoSpotlightRevertTimer invalidate];
        self.autoSpotlightRevertTimer = nil;

        if (_activeSpeakerIdentity.length > 0 && self.remoteCameraViews[_activeSpeakerIdentity]) {
            // Save current spotlight for later restoration (only if not already in auto mode)
            if (!self.preAutoSpotlightKey) {
                self.preAutoSpotlightKey = self.spotlightedTileKey;
            }
            self.spotlightedTileKey = _activeSpeakerIdentity;
            [self updateLayoutAnimated:YES];
        } else if (_activeSpeakerIdentity.length == 0 && self.preAutoSpotlightKey) {
            // Speaker stopped — start 3s timer before reverting to previous spotlight
            self.autoSpotlightRevertTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                                             target:self
                                                                           selector:@selector(revertAutoSpotlight)
                                                                           userInfo:nil
                                                                            repeats:NO];
        }
    }
}

/// Revert auto-spotlight back to the previous spotlight key after timeout. [Phase 7.4.2]
- (void)revertAutoSpotlight {
    self.autoSpotlightRevertTimer = nil;
    if (self.preAutoSpotlightKey) {
        self.spotlightedTileKey = self.preAutoSpotlightKey;
        self.preAutoSpotlightKey = nil;
        [self updateLayoutAnimated:YES];
    }
}

#pragma mark - Participant Count Badge

- (void)setRemoteParticipantCount:(NSUInteger)remoteParticipantCount {
    _remoteParticipantCount = remoteParticipantCount;
    [self updateParticipantCountBadge];
}

- (void)updateParticipantCountBadge {
    // Show badge when 2+ remote participants (i.e. 3+ total in call)
    NSUInteger count = self.remoteParticipantCount;
    if (count <= 1) {
        self.participantCountBadge.hidden = YES;
        return;
    }

    // +1 for local participant
    NSUInteger totalCount = count + 1;
    self.participantCountBadge.stringValue = [NSString stringWithFormat:@" 👥 %lu ", (unsigned long)totalCount];
    self.participantCountBadge.hidden = NO;

    // Position top-right
    [self.participantCountBadge sizeToFit];
    NSSize badgeSize = self.participantCountBadge.frame.size;
    badgeSize.width = MAX(badgeSize.width + 8, 44);
    badgeSize.height = MAX(badgeSize.height, 22);
    CGFloat x = self.bounds.size.width - badgeSize.width - 12;
    CGFloat y = self.bounds.size.height - badgeSize.height - 12;
    self.participantCountBadge.frame = NSMakeRect(x, y, badgeSize.width, badgeSize.height);
}

#pragma mark - Spotlight State

- (void)updateManualSpotlightTileKey:(NSString * _Nullable)tileKey {
    BOOL unchanged = ((self.spotlightedTileKey == nil && tileKey == nil) ||
                      [self.spotlightedTileKey isEqualToString:tileKey]);
    if (unchanged) {
        return;
    }

    self.spotlightedTileKey = [tileKey copy];

    void (^handler)(NSString * _Nullable) = self.spotlightSelectionChangedHandler;
    if (handler) {
        handler(self.spotlightedTileKey);
    }
}

- (void)setAllowsManualSpotlightSelection:(BOOL)allowsManualSpotlightSelection {
    if (_allowsManualSpotlightSelection == allowsManualSpotlightSelection) {
        return;
    }

    _allowsManualSpotlightSelection = allowsManualSpotlightSelection;
    if (!allowsManualSpotlightSelection && self.spotlightedTileKey != nil) {
        // Disabling manual spotlight should also clear any previously selected
        // tile so future layout is purely automatic.
        [self updateManualSpotlightTileKey:nil];
        [self updateLayoutAnimated:NO];
    }
}

- (void)setCompactPreviewMode:(BOOL)compactPreviewMode {
    if (_compactPreviewMode == compactPreviewMode) {
        return;
    }

    _compactPreviewMode = compactPreviewMode;

    // Compact preview mode is a presentation-only concern. As soon as the
    // container changes between full remote stage and secure-tool-owned stage,
    // the layout manager must rebuild its hierarchy immediately so stale nested
    // filmstrip geometry never remains visible.
    [self updateLayoutAnimated:NO];
}

- (void)setSupplementalFilmstripView:(NSView *)supplementalFilmstripView {
    if (_supplementalFilmstripView == supplementalFilmstripView) {
        return;
    }

    [_supplementalFilmstripView removeFromSuperview];
    _supplementalFilmstripView = supplementalFilmstripView;
    [self updateLayoutAnimated:NO];
}

@end
