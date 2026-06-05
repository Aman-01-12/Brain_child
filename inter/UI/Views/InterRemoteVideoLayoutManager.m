#import "InterRemoteVideoLayoutManager.h"
#import "InterParticipantOverlayView.h"
#import <AVFoundation/AVFoundation.h>
#import <os/lock.h>

#if __has_include("inter-Swift.h")
#import "inter-Swift.h"
#endif

// ---------------------------------------------------------------------------
// Internal tile key helpers
// ---------------------------------------------------------------------------
static NSString *const kScreenShareTileKey = @"__screenshare__";
static NSString *const kLocalSelfTileKey   = @"__localself__";
static NSString *const kInterPreferGridLayoutKey = @"InterPreferGridLayout";

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
/// Mic-muted badge (🔇 emoji in bottom-right corner), shown when isMicMuted=YES.
/// Updated by the setIsMicMuted: custom setter — driven by LiveKit track events.
@property (nonatomic, strong) NSTextField *micMutedBadge;
/// Three-dot moderation menu button shown at top-right on hover (host mode only).
@property (nonatomic, strong) NSButton *moderationMenuButton;
/// When YES, the moderation menu button is shown on hover.
@property (nonatomic, assign) BOOL showsModerationMenu;
/// Whether this participant's microphone is currently muted (updated by track events).
/// Drives the visual mic indicator on the tile.
@property (nonatomic, assign) BOOL isMicMuted;
/// Whether the HOST has explicitly muted this participant (via tile action or Mute All).
/// Drives the tile three-dot menu label ("Mute Mic" vs "Unmute Mic"),
/// independent of the participant's self-mute state.
@property (nonatomic, assign) BOOL isHostMuted;
/// Whether this participant's camera is currently muted (updated by track events).
@property (nonatomic, assign) BOOL isCameraMuted;
/// When YES this tile is the current host-forced spotlight. The three-dot menu
/// shows "Unpin for All" instead of "Pin for All".
@property (nonatomic, assign) BOOL isPinnedByHost;
/// When YES all 5 host-pin slots are taken and this tile is not pinned;
/// the tile menu should show a disabled "Pin for All" item.
@property (nonatomic, assign) BOOL allPinSlotsUsed;
/// Called when the host selects an action from the tile's moderation menu.
@property (nonatomic, copy, nullable) void (^moderationMenuHandler)(NSString *tileKey, NSString *action);
/// Co-host crown badge (👑 emoji in top-right corner), shown when isCoHost=YES.
@property (nonatomic, strong) NSTextField *coHostBadge;
@property (nonatomic, assign) BOOL isCoHost;
/// Host-camera-locked badge (🔒 emoji), shown when the host has locked this participant's camera.
@property (nonatomic, strong) NSTextField *cameraLockedBadge;
@property (nonatomic, assign) BOOL isHostCameraLocked;
/// When YES, this tile belongs to the meeting host. The moderation menu shows only pin/unpin.
@property (nonatomic, assign) BOOL isHostParticipant;
/// When YES, the local user is the meeting host and may assign or revoke co-host status.
/// When NO (local user is a co-host), the Make/Remove Co-Host menu items are hidden.
@property (nonatomic, assign) BOOL localUserCanAssignCoHost;
/// Avatar placeholder shown when the participant's camera is off (no video).
/// A circular badge with the participant's initial, centered in the tile.
@property (nonatomic, strong) NSView *avatarPlaceholder;
/// The initial-letter label inside the avatar placeholder circle.
@property (nonatomic, strong) NSTextField *avatarInitial;
/// When YES, the avatar placeholder is shown and the video view is hidden
/// (participant present but camera off). Driven by presence + track/frame events.
@property (nonatomic, assign) BOOL cameraOff;

/// Update the avatar's initial letter when the display name becomes known.
- (void)updateAvatarInitialFromDisplayName:(NSString *)displayName;
/// Compute the single-character avatar initial for a display name.
+ (NSString *)initialForDisplayName:(NSString *)displayName;
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

    // Avatar placeholder — shown when the participant's camera is off. Sits above
    // the video view but below the name label / badges. A circular grey badge with
    // the participant's initial, centred in the tile (standard video-call style).
    NSView *avatar = [[NSView alloc] initWithFrame:NSZeroRect];
    avatar.wantsLayer = YES;
    avatar.layer.backgroundColor = [NSColor colorWithWhite:0.22 alpha:1.0].CGColor;
    avatar.hidden = YES;
    [self addSubview:avatar];
    self.avatarPlaceholder = avatar;

    NSTextField *initial = [NSTextField labelWithString:[[self class] initialForDisplayName:displayName]];
    initial.font = [NSFont systemFontOfSize:32 weight:NSFontWeightSemibold];
    initial.textColor = [NSColor whiteColor];
    initial.alignment = NSTextAlignmentCenter;
    initial.backgroundColor = [NSColor clearColor];
    initial.drawsBackground = NO;
    [avatar addSubview:initial];
    self.avatarInitial = initial;

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

    // Mic-muted indicator — bottom-right corner, shown when the participant's
    // microphone track is muted. Secondary indicator; does not affect host
    // controls (the three-dot menu label uses isHostMuted exclusively).
    self.micMutedBadge = [NSTextField labelWithString:@"🔇"];
    self.micMutedBadge.font = [NSFont systemFontOfSize:14];
    self.micMutedBadge.frame = NSMakeRect(0, 0, 22, 22);
    [self.micMutedBadge setWantsLayer:YES];
    self.micMutedBadge.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.55].CGColor;
    self.micMutedBadge.layer.cornerRadius = 4.0;
    self.micMutedBadge.alignment = NSTextAlignmentCenter;
    self.micMutedBadge.hidden = YES;
    [self addSubview:self.micMutedBadge];

    // Moderation three-dot button — top-right corner, visible on hover in host mode
    self.moderationMenuButton = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 22, 22)];
    self.moderationMenuButton.title = @"···";
    self.moderationMenuButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightBold];
    self.moderationMenuButton.bezelStyle = NSBezelStyleRounded;
    self.moderationMenuButton.bordered = NO;
    [self.moderationMenuButton setWantsLayer:YES];
    self.moderationMenuButton.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.65].CGColor;
    self.moderationMenuButton.layer.cornerRadius = 4.0;
    self.moderationMenuButton.contentTintColor = [NSColor whiteColor];
    [self.moderationMenuButton setTarget:self];
    [self.moderationMenuButton setAction:@selector(showModerationMenu:)];
    self.moderationMenuButton.hidden = YES;
    [self addSubview:self.moderationMenuButton];

    self.coHostBadge = [NSTextField labelWithString:@"👑"];
    self.coHostBadge.font = [NSFont systemFontOfSize:14];
    self.coHostBadge.frame = NSMakeRect(0, 0, 22, 22);
    [self.coHostBadge setWantsLayer:YES];
    self.coHostBadge.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.55].CGColor;
    self.coHostBadge.layer.cornerRadius = 4.0;
    self.coHostBadge.alignment = NSTextAlignmentCenter;
    self.coHostBadge.hidden = YES;
    [self addSubview:self.coHostBadge];

    self.cameraLockedBadge = [NSTextField labelWithString:@"🔒"];
    self.cameraLockedBadge.font = [NSFont systemFontOfSize:12];
    self.cameraLockedBadge.frame = NSMakeRect(0, 0, 22, 22);
    [self.cameraLockedBadge setWantsLayer:YES];
    self.cameraLockedBadge.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.55].CGColor;
    self.cameraLockedBadge.layer.cornerRadius = 4.0;
    self.cameraLockedBadge.alignment = NSTextAlignmentCenter;
    self.cameraLockedBadge.hidden = YES;
    [self addSubview:self.cameraLockedBadge];

    return self;
}

- (void)setHandRaised:(BOOL)handRaised {
    _handRaised = handRaised;
    self.handRaiseBadge.hidden = !handRaised;
}

/// Custom setter: propagate mic-muted state to the visual badge immediately.
/// Without this, isMicMuted is set but the badge never appears (no drawRect
/// trigger for layer-backed views). This is the Bug 3 host-tile fix.
- (void)setIsMicMuted:(BOOL)isMicMuted {
    if (_isMicMuted == isMicMuted) return;
    _isMicMuted = isMicMuted;
    self.micMutedBadge.hidden = !isMicMuted;
}

- (void)setIsCoHost:(BOOL)isCoHost {
    if (_isCoHost == isCoHost) return;
    _isCoHost = isCoHost;
    self.coHostBadge.hidden = !isCoHost;
}

- (void)setIsHostCameraLocked:(BOOL)isHostCameraLocked {
    if (_isHostCameraLocked == isHostCameraLocked) return;
    _isHostCameraLocked = isHostCameraLocked;
    self.cameraLockedBadge.hidden = !isHostCameraLocked;
}

/// Show/hide the avatar placeholder. When YES, the video view is hidden and the
/// circular initial badge is shown (participant present but camera off).
- (void)setCameraOff:(BOOL)cameraOff {
    _cameraOff = cameraOff;
    self.avatarPlaceholder.hidden = !cameraOff;
    self.videoView.hidden = cameraOff;
}

/// Update the avatar's initial letter when the display name becomes known.
- (void)updateAvatarInitialFromDisplayName:(NSString *)displayName {
    self.avatarInitial.stringValue = [[self class] initialForDisplayName:displayName];
}

/// Compute the single-character avatar initial for a display name.
+ (NSString *)initialForDisplayName:(NSString *)displayName {
    NSString *trimmed = [displayName stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return @"?";
    return [[trimmed substringToIndex:1] uppercaseString];
}

- (void)layout {
    [super layout];
    NSRect b = self.bounds;
    // Video fills entire tile
    self.videoView.frame = b;
    // Avatar placeholder: centred circle sized to ~35% of the smaller dimension.
    CGFloat avatarD = MIN(b.size.width, b.size.height) * 0.35;
    avatarD = MAX(40.0, MIN(avatarD, 120.0));
    self.avatarPlaceholder.frame = NSMakeRect((b.size.width - avatarD) / 2.0,
                                              (b.size.height - avatarD) / 2.0,
                                              avatarD, avatarD);
    self.avatarPlaceholder.layer.cornerRadius = avatarD / 2.0;
    // Centre the initial label vertically within the circle.
    CGFloat initialH = avatarD * 0.5;
    self.avatarInitial.font = [NSFont systemFontOfSize:avatarD * 0.4 weight:NSFontWeightSemibold];
    self.avatarInitial.frame = NSMakeRect(0, (avatarD - initialH) / 2.0, avatarD, initialH);
    // Name label at bottom, 22px tall
    CGFloat labelH = 22.0;
    self.nameLabel.frame = NSMakeRect(0, 0, b.size.width, labelH);
    // Hand raise badge at top-left
    self.handRaiseBadge.frame = NSMakeRect(4, b.size.height - 28, 24, 24);
    // Mic-muted badge at bottom-right, just above the name label
    self.micMutedBadge.frame = NSMakeRect(b.size.width - 26, labelH + 2, 22, 22);
    // Co-host crown badge: top-right, below the moderation menu button
    self.coHostBadge.frame = NSMakeRect(b.size.width - 26, b.size.height - 54, 22, 22);
    // Host-camera-locked badge: bottom-right, left of the mic-muted badge
    self.cameraLockedBadge.frame = NSMakeRect(b.size.width - 52, labelH + 2, 22, 22);
    // Moderation menu button at top-right (symmetric with hand-raise badge)
    self.moderationMenuButton.frame = NSMakeRect(b.size.width - 26, b.size.height - 28, 22, 22);
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
    if (self.showsModerationMenu) {
        self.moderationMenuButton.hidden = NO;
    }
}

- (void)mouseExited:(NSEvent *)event {
    self.isHovered = NO;
    if (!self.isSpeaking) {
        self.layer.borderColor = nil;
        self.layer.borderWidth = 0.0;
    }
    self.moderationMenuButton.hidden = YES;
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

// ---------------------------------------------------------------------------
// Moderation menu
// ---------------------------------------------------------------------------

- (void)showModerationMenu:(NSButton *)sender {
    NSString *tileKey = self.tileKey;

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    menu.autoenablesItems = NO;

    // Helper to create a menu item that carries (tileKey, action) payload
    void (^addItem)(NSString *, NSString *) = ^(NSString *title, NSString *action) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                      action:@selector(moderationMenuItemClicked:)
                                               keyEquivalent:@""];
        item.target = self;
        item.enabled = YES;
        item.representedObject = @{@"tileKey": tileKey, @"action": action};
        [menu addItem:item];
    };

    // When the tile belongs to the meeting host, co-hosts can only pin/unpin.
    // All other moderation actions (mute, camera, remove, role changes) are not
    // shown to avoid confusing no-op items in the menu.
    if (self.isHostParticipant) {
        if (self.isPinnedByHost) {
            addItem(@"Unpin for All", @"unpinForAll");
        } else if (self.allPinSlotsUsed) {
            NSMenuItem *limitItem = [[NSMenuItem alloc] initWithTitle:@"Pin for All (max 5 reached)"
                                                               action:nil
                                                        keyEquivalent:@""];
            limitItem.enabled = NO;
            [menu addItem:limitItem];
        } else {
            addItem(@"Pin for All", @"pinForAll");
        }
        NSPoint hostOrigin = NSMakePoint(NSMinX(sender.frame), NSMinY(sender.frame));
        [menu popUpMenuPositioningItem:nil atLocation:hostOrigin inView:self];
        return;
    }

    // Mic — label reflects HOST's mute intent, not participant's self-mute state.
    // isMicMuted drives the visual mic indicator; isHostMuted drives the menu label
    // so the host sees "Unmute Mic" only when THEY explicitly muted this participant.
    if (self.isHostMuted) {
        addItem(@"Unmute Mic", @"unmuteMic");
    } else {
        addItem(@"Mute Mic", @"muteMic");
    }

    // Camera lock — unified "Mute Camera" (locks camera) / "Lift Camera Lock"
    if (self.isHostCameraLocked) {
        addItem(@"Unmute Camera", @"liftCameraLock");
    } else {
        addItem(@"Mute Camera", @"lockCamera");
    }
    [menu addItem:[NSMenuItem separatorItem]];
    // Pin/Unpin toggles.
    if (self.isPinnedByHost) {
        addItem(@"Unpin for All", @"unpinForAll");
    } else if (self.allPinSlotsUsed) {
        // All 5 host-pin slots are full — show a greyed-out label.
        NSMenuItem *limitItem = [[NSMenuItem alloc] initWithTitle:@"Pin for All (max 5 reached)"
                                                           action:nil
                                                    keyEquivalent:@""];
        limitItem.enabled = NO;
        [menu addItem:limitItem];
    } else {
        addItem(@"Pin for All",   @"pinForAll");
    }
    [menu addItem:[NSMenuItem separatorItem]];
    // Role assignment is host-only — co-hosts do not see Make/Remove Co-Host.
    if (self.localUserCanAssignCoHost) {
        if (self.isCoHost) {
            NSMenuItem *removeCoHostItem = [[NSMenuItem alloc] initWithTitle:@"Remove Co-Host"
                                                                       action:@selector(moderationMenuItemClicked:)
                                                                keyEquivalent:@""];
            removeCoHostItem.target = self;
            removeCoHostItem.enabled = YES;
            removeCoHostItem.representedObject = @{@"tileKey": tileKey, @"action": @"removeCoHost"};
            [menu addItem:removeCoHostItem];
        } else {
            NSMenuItem *makeCoHostItem = [[NSMenuItem alloc] initWithTitle:@"Make Co-Host"
                                                                     action:@selector(moderationMenuItemClicked:)
                                                              keyEquivalent:@""];
            makeCoHostItem.target = self;
            makeCoHostItem.enabled = YES;
            makeCoHostItem.representedObject = @{@"tileKey": tileKey, @"action": @"makeCoHost"};
            [menu addItem:makeCoHostItem];
        }
    }
    addItem(@"Rename…", @"rename");
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *removeItem = [[NSMenuItem alloc] initWithTitle:@"Remove from Meeting"
                                                        action:@selector(moderationMenuItemClicked:)
                                                 keyEquivalent:@""];
    removeItem.target = self;
    removeItem.enabled = YES;
    removeItem.representedObject = @{@"tileKey": tileKey, @"action": @"remove"};
    // Destructive visual hint — no standard NSMenuItem API for red text pre-macOS 14,
    // so we use an attributed title with the system red color.
    NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
    attrs[NSForegroundColorAttributeName] = [NSColor systemRedColor];
    removeItem.attributedTitle = [[NSAttributedString alloc]
                                  initWithString:@"Remove from Meeting"
                                  attributes:attrs];
    [menu addItem:removeItem];

    // Pop up directly below the button (in the tile's coordinate space)
    NSPoint origin = NSMakePoint(NSMinX(sender.frame), NSMinY(sender.frame));
    [menu popUpMenuPositioningItem:nil atLocation:origin inView:self];
}

- (void)moderationMenuItemClicked:(NSMenuItem *)item {
    NSDictionary<NSString *, NSString *> *info = item.representedObject;
    NSString *tileKey = info[@"tileKey"];
    NSString *action  = info[@"action"];
    if (self.moderationMenuHandler && tileKey.length > 0 && action.length > 0) {
        self.moderationMenuHandler(tileKey, action);
    }
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

/// Persisted co-host flag per participant identity. Outlives individual tile views so
/// that the crown badge is correctly restored when a tile is torn down and recreated.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *coHostStates;

/// Persisted host-camera-locked flag per participant identity. Same rationale as
/// coHostStates — survives layout mode changes that recreate tile views.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *hostCameraLockStates;

/// Persisted host-participant flag per participant identity. When YES for a given identity,
/// that tile's moderation menu shows only pin/unpin (co-hosts cannot moderate the host).
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *hostParticipantStates;

/// Persisted camera-off flag per participant identity. YES means the avatar placeholder
/// is shown (participant present but no video). Survives tile teardown/recreation so the
/// placeholder state is correct after layout-mode changes. Set by presence (join) and
/// track/frame events; cleared when the first camera frame arrives.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *cameraOffStates;

// -- Spotlight --

/// Tile key currently shown on the main stage (nil = auto).
/// Auto: screen share is spotlighted when present; otherwise first camera.
@property (nonatomic, copy, nullable) NSString *spotlightedTileKey;

/// Ordered list of tile keys locked by host-forced spotlight (max 5).
/// When non-empty, click-to-spotlight is blocked for all participants.
@property (nonatomic, strong, nonnull) NSMutableArray<NSString *> *hostForcedSpotlightTileKeys;

/// Records whether grid mode was active at the moment the host first pinned a tile,
/// so it can be restored when all pins are cleared.
@property (nonatomic, assign) BOOL gridWasEnabledBeforePin;
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

/// Set of participant IDs for which a first-frame dispatch has already been queued
/// but not yet processed on the main thread. Prevents duplicate dispatches that would
/// otherwise cause repeated animated layout thrash (freeze + blank screen) when many
/// frames arrive from the background thread before the main thread creates the view.
/// Protected by _pendingFirstFrameLock.
@property (nonatomic, strong) NSMutableSet<NSString *> *pendingFirstFrameIdentifiers;

/// Spotlight key prior to auto-speaker-spotlight, for restoring after speaker stops. [Phase 7.4.2]
@property (nonatomic, copy, nullable) NSString *preAutoSpotlightKey;

/// Timer to revert auto-speaker-spotlight 3s after speaker stops. [Phase 7.4.2]
@property (nonatomic, strong, nullable) NSTimer *autoSpotlightRevertTimer;

/// When YES the user has explicitly clicked a filmstrip tile to pin a specific
/// participant in the main stage. Auto-spotlight will NOT override the stage tile
/// while this is set. The pin clears when the pinned participant leaves or the
/// layout mode is toggled.
@property (nonatomic, assign) BOOL spotlightIsPinnedByUser;

/// Identity of the last participant who was the active speaker.
/// Used as the stage-mode spotlight fallback so the last speaker stays in the main
/// stage even after they stop speaking (until a new speaker takes over).
@property (nonatomic, copy, nullable) NSString *lastActiveSpeakerIdentity;

// -- Grid mode: local self-view tile --

/// AVCaptureVideoPreviewLayer powering the local self-view tile.
@property (nonatomic, strong, nullable) AVCaptureVideoPreviewLayer *localPreviewLayer;
/// Container NSView for the local self-view tile.
@property (nonatomic, strong, nullable) NSView *localSelfTileView;
/// "You" name label inside the self-view tile.
@property (nonatomic, strong, nullable) NSTextField *localSelfNameLabel;
/// Floating toggle button (top-right) for switching between Grid and Stage views.
@property (nonatomic, strong, nullable) NSButton *layoutToggleButton;

/// When YES, the local self-view tile shows the live preview; when NO, shows the
/// avatar placeholder. Driven by the roster snapshot from the local camera state.
@property (nonatomic, assign) BOOL localSelfCameraOn;

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

@implementation InterRemoteVideoLayoutManager {
    /// os_unfair_lock protecting pendingFirstFrameIdentifiers for lock-free
    /// first-frame dispatch deduplication. Must be declared as a raw ivar
    /// because os_unfair_lock is a value type, not an ObjC object.
    os_unfair_lock _pendingFirstFrameLock;
}

#pragma mark - Lifecycle

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;

    self.wantsLayer = YES;
    self.layer.backgroundColor = [NSColor blackColor].CGColor;

    self.participantDisplayNames = [NSMutableDictionary dictionary];
    self.remoteCameraViews   = [NSMutableDictionary dictionary];
    self.cameraParticipantOrder = [NSMutableArray array];
    self.tileViews                  = [NSMutableDictionary dictionary];
    self.hostForcedSpotlightTileKeys = [NSMutableArray array];
    self.coHostStates               = [NSMutableDictionary dictionary];
    self.hostCameraLockStates       = [NSMutableDictionary dictionary];
    self.hostParticipantStates      = [NSMutableDictionary dictionary];
    self.cameraOffStates            = [NSMutableDictionary dictionary];

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

    // Participant count badge — top-LEFT corner (keeps it away from the toggle button)
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
    self.pendingFirstFrameIdentifiers = [NSMutableSet set];
    _pendingFirstFrameLock = OS_UNFAIR_LOCK_INIT;

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
    self.compactPreviewMode = NO;
    // Enable auto-spotlight by default so active speaker is always promoted to
    // the main stage in stage+filmstrip mode, matching screen-share behaviour.
    self.autoSpotlightActiveSpeaker = YES;

    // Load persisted grid layout preference (default YES = equal grid).
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{kInterPreferGridLayoutKey: @YES}];
    BOOL preferGrid = [[NSUserDefaults standardUserDefaults] boolForKey:kInterPreferGridLayoutKey];
    _gridLayoutEnabled = preferGrid;
    _preferStageLayoutForMultipleCameras = !preferGrid;

    // Floating layout toggle button (top-right of the video area).
    [self setupLayoutToggleButton];

    return self;
}

#pragma mark - Computed Properties

- (NSUInteger)remoteCameraCount {
    return self.remoteCameraViews.count;
}

#pragma mark - Host Mode (per-participant moderation menus)

- (void)setIsHostMode:(BOOL)isHostMode {
    _isHostMode = isHostMode;
    __weak InterRemoteVideoLayoutManager *weakSelf = self;
    // Update all existing remote tiles — screen share tile never gets the menu
    for (NSString *key in self.tileViews) {
        InterRemoteVideoTileView *tile = self.tileViews[key];
        BOOL eligible = isHostMode && ![key isEqualToString:kScreenShareTileKey];
        tile.showsModerationMenu = eligible;
        if (eligible && !tile.moderationMenuHandler) {
            tile.moderationMenuHandler = ^(NSString *tileKey, NSString *action) {
                __strong InterRemoteVideoLayoutManager *s = weakSelf;
                if (s && s.moderationActionHandler) {
                    s.moderationActionHandler(tileKey, action);
                }
            };
        } else if (!eligible) {
            tile.moderationMenuHandler = nil;
        }
    }
}

- (void)setLocalUserCanAssignCoHost:(BOOL)canAssign {
    _localUserCanAssignCoHost = canAssign;
    for (NSString *key in self.tileViews) {
        self.tileViews[key].localUserCanAssignCoHost = canAssign;
    }
}

#pragma mark - Grid Layout Toggle

- (void)setGridLayoutEnabled:(BOOL)gridLayoutEnabled {
    if (_gridLayoutEnabled == gridLayoutEnabled) return;
    _gridLayoutEnabled = gridLayoutEnabled;
    // Write directly to ivars so we don't trigger redundant layout passes.
    _preferStageLayoutForMultipleCameras = !gridLayoutEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:gridLayoutEnabled forKey:kInterPreferGridLayoutKey];

    // Cancel any pending auto-spotlight revert timer — the saved pre-auto key belongs
    // to the previous mode and would restore the wrong tile after the switch.
    // Also release any user pin since the user is explicitly choosing a new layout.
    [self.autoSpotlightRevertTimer invalidate];
    self.autoSpotlightRevertTimer = nil;
    self.preAutoSpotlightKey = nil;
    self.spotlightIsPinnedByUser = NO;

    [self updateLayoutToggleButton];
    [self updateLayoutAnimated:YES];
}

/// Custom setter: creates the AVCaptureVideoPreviewLayer immediately so it
/// attaches to the session once, before any layout pass. Creating it lazily
/// inside arrangeCameraGridInRect: (called during layout) would briefly contend
/// with the camera capture thread and back up the CMIO stream queue.
- (void)setLocalCaptureSession:(AVCaptureSession *)localCaptureSession {
    if (_localCaptureSession == localCaptureSession) return;

    // Tear down old tile and preview layer.
    if (self.localPreviewLayer) {
        [self.localPreviewLayer removeFromSuperlayer];
        self.localPreviewLayer = nil;
    }
    if (self.localSelfTileView) {
        [self.localSelfTileView removeFromSuperview];
        self.localSelfTileView  = nil;
        self.localSelfNameLabel = nil;
    }

    // If the user had pinned themselves in the spotlight, release the pin now
    // so the layout doesn't try to render a torn-down tile.
    if ([self.spotlightedTileKey isEqualToString:kLocalSelfTileKey]) {
        self.spotlightIsPinnedByUser = NO;
        [self updateManualSpotlightTileKey:nil];
    }

    _localCaptureSession = localCaptureSession;

    // Pre-create the preview layer so it is attached to the session now,
    // not inside a layout pass later.
    if (localCaptureSession) {
        AVCaptureVideoPreviewLayer *preview = [AVCaptureVideoPreviewLayer layerWithSession:localCaptureSession];
        preview.videoGravity = AVLayerVideoGravityResizeAspect;
        preview.frame = CGRectMake(0, 0, 1, 1);  // sized during tile placement
        // Mirror to match remote tiles (which render with isMirrored = YES). Applied here
        // where the connection is freshly available, and again in setupLocalSelfTileIfNeeded
        // as a safety net in case the connection was not ready at creation time.
        if (preview.connection) {
            preview.connection.automaticallyAdjustsVideoMirroring = NO;
            preview.connection.videoMirrored = YES;
        }
        self.localPreviewLayer = preview;
    }

    // Re-layout so computeLayoutMode picks up the new effective camera count.
    [self updateLayoutAnimated:NO];
}

- (void)refreshLocalPreviewLayout {
    // Re-run the layout pass so arrangeCameraGridInRect: explicitly sets
    // localPreviewLayer.frame, which triggers AVSampleBufferDisplayLayer
    // to re-initialize its rendering pipeline after a camera disable/re-enable cycle.
    // Without this, localPreviewLayer can remain blank even though the session has
    // a live video input, because the backing display layer never receives a CALayer
    // property change to wake it up (unlike the control-panel _previewLayer which
    // gets an affineTransform update via updatePreviewMirroringPolicyOnMainThread).
    if (!self.localPreviewLayer || !self.localCaptureSession) return;

    // Resetting the session reference on the layer forces AVCaptureVideoPreviewLayer
    // to re-attach its internal sample buffer connection, reliably clearing any
    // stuck/paused state.
    self.localPreviewLayer.session = self.localCaptureSession;

    // Re-run layout so the tile is (re-)added to the hierarchy with correct geometry.
    [self updateLayoutAnimated:NO];
}

- (void)setupLayoutToggleButton {
    self.layoutToggleButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    self.layoutToggleButton.bezelStyle = NSBezelStyleRounded;
    self.layoutToggleButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.layoutToggleButton.wantsLayer = YES;
    [self.layoutToggleButton setTarget:self];
    [self.layoutToggleButton setAction:@selector(handleLayoutToggle:)];
    self.layoutToggleButton.hidden = YES;
    // Place the toggle button as the TOPMOST subview — above the badge and overlay
    // so nothing can ever sit in front of it and prevent clicks.
    [self addSubview:self.layoutToggleButton positioned:NSWindowAbove relativeTo:nil];
    [self updateLayoutToggleButton];
    [self repositionLayoutToggleButton];
}

- (void)updateLayoutToggleButton {
    // Count ALL renderable video tiles: remote cameras + local self-view.
    // 1 remote + self-view = 2 tiles → toggle is meaningful (grid shows both
    // tiles; stage collapses to 1 full-screen remote + empty filmstrip).
    // 0 or 1 tile total → both modes are identical, hide the toggle.
    NSUInteger tileCount = self.remoteCameraViews.count
                         + (self.localCaptureSession != nil ? 1 : 0);
    BOOL shouldShow = (tileCount >= 2 &&
                       !self.compactPreviewMode &&
                       !self.screenShareParticipantId);
    self.layoutToggleButton.hidden = !shouldShow;
    // Title describes the mode the user will SWITCH TO.
    self.layoutToggleButton.title = self.gridLayoutEnabled ? @"Stage" : @"Grid";
}

- (void)repositionLayoutToggleButton {
    CGFloat btnW = 62.0, btnH = 24.0, margin = 10.0;

    // In camera-only stage mode the filmstrip occupies the right side.
    // Keep the button within the main stage area so it never overlaps
    // the filmstrip thumbnails (which would block interaction on both).
    // Stage mode: grid is off and there are enough renderable tiles.
    // Counts as stage when there are 2+ remote cameras, OR 1 remote camera plus
    // the local self-view (which appears in the filmstrip in stage mode).
    BOOL hasStageTileCount = (self.remoteCameraViews.count >= 2 ||
                              (self.remoteCameraViews.count >= 1 && self.localCaptureSession != nil));
    BOOL isStageMode = (!self.gridLayoutEnabled &&
                        !self.screenShareParticipantId &&
                        hasStageTileCount &&
                        !self.compactPreviewMode);

    CGFloat rightBound;
    if (isStageMode) {
        CGFloat filmstripW = self.bounds.size.width * kFilmstripWidthFraction;
        filmstripW = MAX(filmstripW, kFilmstripMinWidth);
        filmstripW = MIN(filmstripW, kFilmstripMaxWidth);
        // Place button flush against the filmstrip left edge.
        rightBound = self.bounds.size.width - filmstripW - margin;
    } else {
        rightBound = self.bounds.size.width - margin;
    }

    self.layoutToggleButton.frame = NSMakeRect(
        rightBound - btnW,
        self.bounds.size.height - btnH - margin,
        btnW, btnH);
}

- (IBAction)handleLayoutToggle:(id)sender {
    self.gridLayoutEnabled = !self.gridLayoutEnabled;
}

#pragma mark - Local Self-View Tile

- (void)setupLocalSelfTileIfNeeded {
    // Guard: tile already built, or preview layer not yet ready.
    if (self.localSelfTileView || !self.localPreviewLayer) return;

    NSView *tile = [[NSView alloc] initWithFrame:NSZeroRect];
    tile.wantsLayer = YES;
    tile.layer.backgroundColor = [NSColor blackColor].CGColor;
    tile.layer.cornerRadius = 8.0;
    tile.layer.masksToBounds = YES;

    // Preview layer was already created eagerly in setLocalCaptureSession:.
    // Just attach it to the tile's backing layer.
    // Mirror the local self-view to MATCH the remote tiles, which render camera
    // feeds with isMirrored = YES. Keeping both mirrored means the host sees their
    // own tile and every remote tile with the same handedness (no odd "one tile is
    // flipped" inconsistency).
    AVCaptureVideoPreviewLayer *preview = self.localPreviewLayer;
    preview.connection.automaticallyAdjustsVideoMirroring = NO;
    preview.connection.videoMirrored = YES;
    preview.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    [tile.layer addSublayer:preview];

    NSTextField *label = [NSTextField labelWithString:@"You"];
    label.font        = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    label.textColor   = [NSColor whiteColor];
    label.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.55];
    label.drawsBackground = YES;
    label.alignment   = NSTextAlignmentCenter;
    label.wantsLayer  = YES;
    label.layer.cornerRadius = 4.0;
    label.layer.masksToBounds = YES;
    [tile addSubview:label];

    // Click gesture — promotes the local self-view into the main stage spotlight,
    // exactly like clicking any remote participant tile in the filmstrip.
    NSClickGestureRecognizer *tap = [[NSClickGestureRecognizer alloc]
                                        initWithTarget:self
                                                action:@selector(handleLocalSelfTileClicked:)];
    [tile addGestureRecognizer:tap];
    tile.wantsLayer = YES;   // ensure hit-testing works through the CALayer

    self.localSelfTileView  = tile;
    self.localSelfNameLabel = label;
}

/// Tap handler wired to the local self-view tile's NSClickGestureRecognizer.
- (void)handleLocalSelfTileClicked:(NSClickGestureRecognizer *)recognizer {
    [self handleTileClicked:kLocalSelfTileKey];
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
        [tile updateAvatarInitialFromDisplayName:[self displayNameForTileKey:participantId]];
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

- (void)setMicMuted:(BOOL)muted forParticipant:(NSString *)participantId {
    if (!participantId || participantId.length == 0) return;
    InterRemoteVideoTileView *tile = self.tileViews[participantId];
    if (tile) {
        tile.isMicMuted = muted;
    }
}

- (void)setHostMuted:(BOOL)hostMuted forParticipant:(NSString *)participantId {
    if (!participantId || participantId.length == 0) return;
    InterRemoteVideoTileView *tile = self.tileViews[participantId];
    if (tile) {
        tile.isHostMuted = hostMuted;
    }
}

- (void)setIsCoHost:(BOOL)isCoHost forParticipant:(NSString *)identity {
    if (!identity || identity.length == 0) return;
    // Persist so the flag survives tile teardown/recreation.
    self.coHostStates[identity] = @(isCoHost);
    InterRemoteVideoTileView *tile = self.tileViews[identity];
    if (tile) {
        tile.isCoHost = isCoHost;
    }
}

- (void)setIsHostParticipant:(BOOL)isHost forParticipant:(NSString *)identity {
    if (!identity || identity.length == 0) return;
    // Persist so the flag survives tile teardown/recreation.
    self.hostParticipantStates[identity] = @(isHost);
    InterRemoteVideoTileView *tile = self.tileViews[identity];
    if (tile) {
        tile.isHostParticipant = isHost;
    }
}

- (void)setIsHostCameraLocked:(BOOL)locked forParticipant:(NSString *)identity {
    if (!identity || identity.length == 0) return;
    // Persist so the flag survives tile teardown/recreation.
    self.hostCameraLockStates[identity] = @(locked);
    InterRemoteVideoTileView *tile = self.tileViews[identity];
    if (tile) {
        tile.isHostCameraLocked = locked;
    }
}

- (void)clearAllHostCameraLocks {
    [self.hostCameraLockStates removeAllObjects];
    for (InterRemoteVideoTileView *tile in self.tileViews.allValues) {
        tile.isHostCameraLocked = NO;
    }
}

- (void)setHostForcedSpotlightTileKeys:(NSArray<NSString *> * _Nullable)tileKeys animated:(BOOL)animated {
    NSArray<NSString *> *incoming = tileKeys ?: @[];

    // Clear isPinnedByHost and allPinSlotsUsed on all currently tracked tiles.
    for (NSString *key in self.hostForcedSpotlightTileKeys) {
        InterRemoteVideoTileView *tile = self.tileViews[key];
        tile.isPinnedByHost = NO;
    }
    for (InterRemoteVideoTileView *tile in self.tileViews.allValues) {
        tile.allPinSlotsUsed = NO;
    }

    BOOL wasEmpty = (self.hostForcedSpotlightTileKeys.count == 0);
    [self.hostForcedSpotlightTileKeys setArray:incoming];

    if (incoming.count > 0) {
        // Transition from no-pin to first pin: save grid state and switch to stage.
        if (wasEmpty && _gridLayoutEnabled) {
            self.gridWasEnabledBeforePin = YES;
            // Bypass the public setter (which writes to UserDefaults) — flip raw flags.
            _gridLayoutEnabled = NO;
            _preferStageLayoutForMultipleCameras = YES;
            [self updateLayoutToggleButton];
        }
        // Mark all incoming tiles as pinned.
        for (NSString *key in incoming) {
            InterRemoteVideoTileView *tile = self.tileViews[key];
            tile.isPinnedByHost = YES;
        }
        // When all 5 slots are full, tell non-pinned tiles so their menu can grey out.
        if (incoming.count >= 5) {
            for (InterRemoteVideoTileView *tile in self.tileViews.allValues) {
                if (!tile.isPinnedByHost) tile.allPinSlotsUsed = YES;
            }
        }
        // Point single-spotlight at first pinned tile (used by compact and single-pin paths).
        [self updateManualSpotlightTileKey:incoming.firstObject];
    } else {
        // All pins cleared — restore the user's previous grid preference.
        if (self.gridWasEnabledBeforePin) {
            self.gridWasEnabledBeforePin = NO;
            _gridLayoutEnabled = YES;
            _preferStageLayoutForMultipleCameras = NO;
            [self updateLayoutToggleButton];
        }
        [self updateManualSpotlightTileKey:nil];
    }
    [self updateLayoutAnimated:animated];
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

    // Wire per-participant moderation menu for host/co-host
    if (_isHostMode && ![key isEqualToString:kScreenShareTileKey]) {
        tile.showsModerationMenu = YES;
        __weak InterRemoteVideoLayoutManager *weakSelf = self;
        tile.moderationMenuHandler = ^(NSString *tileKey, NSString *action) {
            __strong InterRemoteVideoLayoutManager *s = weakSelf;
            if (s && s.moderationActionHandler) {
                s.moderationActionHandler(tileKey, action);
            }
        };
    }

    // Restore persisted moderation flags so badges survive tile teardown/recreation.
    if (![key isEqualToString:kScreenShareTileKey]) {
        NSNumber *coHost = self.coHostStates[key];
        if (coHost) tile.isCoHost = coHost.boolValue;
        NSNumber *cameraLocked = self.hostCameraLockStates[key];
        if (cameraLocked) tile.isHostCameraLocked = cameraLocked.boolValue;
        NSNumber *isHost = self.hostParticipantStates[key];
        if (isHost) tile.isHostParticipant = isHost.boolValue;
        tile.localUserCanAssignCoHost = _localUserCanAssignCoHost;
        // Restore camera-off (avatar placeholder) state so it survives tile recreation.
        NSNumber *camOff = self.cameraOffStates[key];
        tile.cameraOff = camOff ? camOff.boolValue : NO;
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

#pragma mark - Presence-Driven Tiles

- (void)addRemoteParticipant:(NSString *)participantId displayName:(NSString *)displayName {
    if (participantId.length == 0) return;

    if (displayName.length > 0) {
        self.participantDisplayNames[participantId] = displayName;
    }

    // Create the camera view + register the participant immediately so a tile exists
    // even before any video frame arrives. The tile shows the avatar placeholder until
    // the first frame flips cameraOff → NO.
    BOOL isNew = (self.remoteCameraViews[participantId] == nil);
    if (isNew) {
        // Default to camera-off (avatar placeholder) until a frame proves otherwise.
        self.cameraOffStates[participantId] = @YES;
        (void)[self cameraViewForParticipant:participantId];
    }

    // Ensure the tile exists and reflects the avatar placeholder + correct name.
    InterRemoteVideoView *view = self.remoteCameraViews[participantId];
    if (view) {
        InterRemoteVideoTileView *tile = [self tileForKey:participantId videoView:view];
        [tile updateAvatarInitialFromDisplayName:[self displayNameForTileKey:participantId]];
        if (isNew) {
            tile.cameraOff = YES;
        }
    }

    [self updateLayoutAnimated:NO];
}

- (void)removeRemoteParticipant:(NSString *)participantId {
    if (participantId.length == 0) return;
    [self.cameraOffStates removeObjectForKey:participantId];
    [self removeCameraViewForParticipant:participantId];
    [self updateLayoutAnimated:NO];
}

#pragma mark - Presence-Driven Reconciler (snapshot-based)

/// Create a tile for the given identity if it doesn't exist yet. The tile starts with
/// the avatar placeholder shown (cameraOff = YES). The reconciler sets the final state.
- (void)ensureTileForParticipant:(NSString *)identity displayName:(NSString *)displayName {
    if (self.tileViews[identity]) { return; }
    if (displayName.length > 0) {
        self.participantDisplayNames[identity] = displayName;
    }
    InterRemoteVideoView *videoView = [self cameraViewForParticipant:identity];
    InterRemoteVideoTileView *tile = [self tileForKey:identity videoView:videoView];
    [tile updateAvatarInitialFromDisplayName:[self displayNameForTileKey:identity]];
    [tile setCameraOff:YES];   // avatar until first frame flips cameraOn in the snapshot
}

- (void)applyParticipantSnapshot:(NSArray<InterParticipantSnapshotEntry *> *)entries {
    NSAssert([NSThread isMainThread], @"applyParticipantSnapshot: must run on main");

    // 1. Build the set of remote identities the snapshot wants on screen.
    NSMutableSet<NSString *> *wantedRemote = [NSMutableSet set];
    InterParticipantSnapshotEntry *localEntry = nil;
    for (InterParticipantSnapshotEntry *e in entries) {
        if (e.isLocal) { localEntry = e; continue; }
        [wantedRemote addObject:e.identity];
    }

    // 2. Removals: any current remote tile not in the snapshot is torn down.
    NSArray<NSString *> *currentKeys = self.tileViews.allKeys.copy;
    for (NSString *key in currentKeys) {
        if ([key isEqualToString:@"__screenshare__"] || [key isEqualToString:@"__localself__"]) {
            continue;
        }
        if (![wantedRemote containsObject:key]) {
            [self removeCameraViewForParticipant:key];
        }
    }

    // 3. Additions + updates for remote entries.
    for (InterParticipantSnapshotEntry *e in entries) {
        if (e.isLocal) { continue; }
        [self ensureTileForParticipant:e.identity displayName:e.displayName];
        InterRemoteVideoTileView *tile = self.tileViews[e.identity];
        if (!tile) { continue; }

        // State is DERIVED from the snapshot every pass — avatar can never float over
        // a live feed because its visibility is recomputed here, not mutated ad-hoc.
        [tile updateAvatarInitialFromDisplayName:e.displayName];
        tile.nameLabel.stringValue = e.displayName;
        [tile setCameraOff:!e.cameraOn];
        // Persist so tileForKey: restores correctly after tile teardown/recreation.
        self.cameraOffStates[e.identity] = @(!e.cameraOn);
        tile.isMicMuted = e.micMuted;
        [tile setHandRaised:e.handRaised];
        tile.isSpeaking = e.isSpeaking;
        // Register display name so displayNameForTileKey: returns the latest value.
        if (e.displayName.length > 0) {
            self.participantDisplayNames[e.identity] = e.displayName;
        }
    }

    // 4. Local self entry: drive the existing local preview path.
    if (localEntry) {
        self.localSelfCameraOn = localEntry.cameraOn;
    }

    // 5. Keep count + active-speaker bookkeeping in sync, then lay out.
    self.remoteParticipantCount = wantedRemote.count;
    NSString *speaker = @"";
    for (InterParticipantSnapshotEntry *e in entries) {
        if (e.isSpeaking) { speaker = e.identity; break; }
    }
    self.activeSpeakerIdentity = speaker;
    [self updateLayoutAnimated:NO];
}

- (void)removeCameraViewForParticipant:(NSString *)participantId {
    // Clear any pending first-frame dispatch so a stale dispatch does not
    // recreate the tile after the participant has already left.
    os_unfair_lock_lock(&_pendingFirstFrameLock);
    [self.pendingFirstFrameIdentifiers removeObject:participantId];
    os_unfair_lock_unlock(&_pendingFirstFrameLock);

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

    // Clear persisted camera-off (placeholder) state for this participant.
    [self.cameraOffStates removeObjectForKey:participantId];

    // Remove from visible set
    [self.visibleParticipantIds removeObject:participantId];

    // If the removed camera was spotlighted, reset to auto and release any
    // user pin so the layout reverts to speaker-auto immediately.
    if ([self.spotlightedTileKey isEqualToString:participantId]) {
        self.spotlightIsPinnedByUser = NO;
        [self.autoSpotlightRevertTimer invalidate];
        self.autoSpotlightRevertTimer = nil;
        self.preAutoSpotlightKey = nil;
        [self updateManualSpotlightTileKey:nil];
    }

    // If the departed participant was host-force-pinned, remove them from the
    // pinned list and re-apply so the layout re-renders correctly.
    // On the host side this also causes the host to re-broadcast the updated
    // list via AppDelegate's response to the local delegate call.
    if ([self.hostForcedSpotlightTileKeys containsObject:participantId]) {
        NSMutableArray<NSString *> *pruned = [self.hostForcedSpotlightTileKeys mutableCopy];
        [pruned removeObject:participantId];
        [self setHostForcedSpotlightTileKeys:pruned animated:YES];
        // Notify the host (AppDelegate) so it can re-broadcast the updated list
        // to all remote clients via the moderation controller DataChannel.
        if (self.hostForcedSpotlightChangedHandler) {
            self.hostForcedSpotlightChangedHandler([pruned copy]);
        }
    }
}

#pragma mark - Frame Routing

- (void)handleRemoteCameraFrame:(CVPixelBufferRef)pixelBuffer fromParticipant:(NSString *)participantId {
    InterRemoteVideoView *view = self.remoteCameraViews[participantId];
    if (view) {
        [view updateFrame:pixelBuffer];
        // First frame after the camera turns on (or after a presence-created tile):
        // hide the avatar placeholder and reveal the live video. Cheap guard — only
        // touches the UI when the placeholder is currently shown.
        if ([self.cameraOffStates[participantId] boolValue]) {
            self.cameraOffStates[participantId] = @NO;
            self.tileViews[participantId].cameraOff = NO;
        }
        return;
    }

    // ── First frame from a new participant ──────────────────────────────────
    // Guard: only queue ONE dispatch per participant until the main thread
    // creates the view. Without this, a 30 fps stream arriving before the
    // main thread processes the first dispatch would queue ~30 identical
    // dispatch blocks per second. Each block calls updateLayoutAnimated:
    // which detaches and re-adds tiles on every call, causing animated
    // layout thrash that freezes the host UI and leaves the screen blank.
    os_unfair_lock_lock(&_pendingFirstFrameLock);
    BOOL alreadyPending = [self.pendingFirstFrameIdentifiers containsObject:participantId];
    if (!alreadyPending) {
        [self.pendingFirstFrameIdentifiers addObject:participantId];
    }
    os_unfair_lock_unlock(&_pendingFirstFrameLock);

    if (alreadyPending) {
        // A dispatch is already in flight; drop this frame. The view will
        // be created by the pending dispatch, after which subsequent frames
        // take the lock-free fast path above.
        return;
    }

    CVPixelBufferRetain(pixelBuffer);
    dispatch_async(dispatch_get_main_queue(), ^{
        // Remove pending flag before creating the view so that any frames
        // that arrive between now and remoteCameraViews being populated
        // fall through to the fast path once the view is visible.
        os_unfair_lock_lock(&self->_pendingFirstFrameLock);
        [self.pendingFirstFrameIdentifiers removeObject:participantId];
        os_unfair_lock_unlock(&self->_pendingFirstFrameLock);

        InterRemoteVideoView *v = [self cameraViewForParticipant:participantId];
        [v updateFrame:pixelBuffer];
        CVPixelBufferRelease(pixelBuffer);

        // Frames are flowing — ensure the avatar placeholder is hidden for this tile.
        self.cameraOffStates[participantId] = @NO;
        self.tileViews[participantId].cameraOff = NO;

        // Use non-animated layout for the first appearance.
        // tile.animator.frame bypasses setFrame:, so layout() on the
        // InterRemoteVideoView is deferred 300 ms, leaving
        // metalLayer.drawableSize at CGSizeZero and producing a blank
        // screen until the animation completes. A direct setFrame: call
        // (animated:NO) triggers layout() immediately, ensuring
        // metalLayer.drawableSize is correct on the very next display-link
        // tick and the video appears without any blank period.
        [self updateLayoutAnimated:NO];

        // Re-attach the local self-view preview layer's session connection.
        // When the previous participant left and the layout entered .none mode,
        // the self-view tile was detached from the view hierarchy. AVCaptureVideoPreviewLayer
        // can enter a stale/frozen state after being removed from a visible hierarchy.
        // Re-setting .session forces it to re-establish its internal sample buffer
        // connection, restoring live video. This is the same technique used by
        // refreshLocalPreviewLayout for the toggle-camera path.
        if (self.localPreviewLayer && self.localCaptureSession) {
            self.localPreviewLayer.session = self.localCaptureSession;
        }
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
        self.tileViews[participantId].isCameraMuted = YES;
        // Camera turned off — show the avatar placeholder (tile stays; presence owns removal).
        self.cameraOffStates[participantId] = @YES;
        self.tileViews[participantId].cameraOff = YES;
    } else if (trackKind == InterTrackKindMicrophone) {
        self.tileViews[participantId].isMicMuted = YES;
    } else if (trackKind == InterTrackKindScreenShare) {
        if ([self.screenShareParticipantId isEqualToString:participantId]) {
            [self.remoteScreenShareView clearFrame];
        }
    }
}

- (void)handleRemoteTrackUnmuted:(NSUInteger)trackKind forParticipant:(NSString *)participantId {
    if (trackKind == InterTrackKindCamera) {
        self.tileViews[participantId].isCameraMuted = NO;
        // Camera coming back on. Keep the avatar placeholder until the first frame
        // arrives (handleRemoteCameraFrame: clears cameraOff), avoiding a black flash.
    } else if (trackKind == InterTrackKindMicrophone) {
        self.tileViews[participantId].isMicMuted = NO;
    }
    // No other work needed: view exists, frames will flow again.
}

- (void)handleRemoteTrackEnded:(NSUInteger)trackKind forParticipant:(NSString *)participantId {
    if (trackKind == InterTrackKindCamera) {
        // Presence-driven model: a camera track ending means the participant turned
        // their camera off / unpublished — NOT that they left. Show the avatar
        // placeholder and keep the tile. Tile removal happens only on participant
        // disconnect (removeRemoteParticipant:).
        InterRemoteVideoView *view = self.remoteCameraViews[participantId];
        [view clearFrame];
        self.cameraOffStates[participantId] = @YES;
        self.tileViews[participantId].cameraOff = YES;
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
    // When the host has force-pinned tiles for all participants, block any
    // click-to-spotlight so the forced pins cannot be overridden.
    if (self.hostForcedSpotlightTileKeys.count > 0) {
        return;
    }

    if (!self.allowsManualSpotlightSelection) {
        return;
    }

    // If the clicked tile is already in the spotlight, do nothing — the user
    // can bring a different tile to spotlight by clicking it in the filmstrip.
    NSString *effectiveKey = [self effectiveSpotlightKey];
    if ([effectiveKey isEqualToString:tileKey]) {
        return;
    }

    // Pin the spotlight: the user has made an explicit choice. Cancel any
    // pending auto-revert timer and clear the saved pre-auto key so that if
    // the pin is later released the layout falls back to speaker-auto, not
    // to some stale tile from before this interaction.
    self.spotlightIsPinnedByUser = YES;
    [self.autoSpotlightRevertTimer invalidate];
    self.autoSpotlightRevertTimer = nil;
    self.preAutoSpotlightKey = nil;

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

    [self updateLayoutToggleButton];

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

    // Count the local self-view tile as an extra camera in grid/stage mode.
    //
    // Key fix: include the local self-view whenever remote participants are present
    // even if their cameras are all off (camCount == 0 but remoteParticipantCount > 0).
    // Without this, computeLayoutMode returns .none the moment a participant joins with
    // camera-off — the host's own preview disappears and the screen stays blank until
    // the remote participant turns their camera on.
    BOOL hasRemoteParticipants = (self.remoteParticipantCount > 0);
    BOOL addLocalSelf = (self.localCaptureSession != nil &&
                         (self.gridLayoutEnabled || self.preferStageLayoutForMultipleCameras) &&
                         (camCount >= 1 || hasRemoteParticipants));
    NSUInteger effectiveCamCount = camCount + (addLocalSelf ? 1 : 0);

    if (effectiveCamCount > 1) {
        if (self.preferStageLayoutForMultipleCameras) {
            return InterRemoteVideoLayoutModeScreenShareWithCameras;
        }
        return InterRemoteVideoLayoutModeMultiCamera;
    }
    if (effectiveCamCount == 1) {
        // Either 1 remote camera, or just the local self-view tile (host camera on,
        // participant present but camera off). Both render as a single full-frame tile.
        return InterRemoteVideoLayoutModeSingleCamera;
    }
    return InterRemoteVideoLayoutModeNone;
}

/// Resolves the effective spotlight key. Returns nil when no spotlight should be shown.
- (NSString *)effectiveSpotlightKey {
    NSString *key = self.spotlightedTileKey;

    // Validate that the key still references a live tile.
    if ([key isEqualToString:kScreenShareTileKey]) {
        return self.screenShareParticipantId ? key : nil;
    }
    if ([key isEqualToString:kLocalSelfTileKey]) {
        return self.localCaptureSession ? key : nil;
    }
    if (key && self.remoteCameraViews[key]) {
        return key;
    }

    // --- Auto-resolution (no valid manual spotlight) ---

    // Screen share always takes the main stage when present.
    if (self.screenShareParticipantId) {
        return kScreenShareTileKey;
    }

    // In stage (non-grid) mode, pick the best default spotlight:
    // 1. Current active speaker (most relevant person right now)
    // 2. Last active speaker (keeps the last talker on stage after they stop)
    // 3. First-joined as a last-resort fallback
    if (self.preferStageLayoutForMultipleCameras && self.cameraParticipantOrder.firstObject != nil) {
        if (_activeSpeakerIdentity.length > 0 && self.remoteCameraViews[_activeSpeakerIdentity]) {
            return _activeSpeakerIdentity;
        }
        if (self.lastActiveSpeakerIdentity.length > 0 && self.remoteCameraViews[self.lastActiveSpeakerIdentity]) {
            return self.lastActiveSpeakerIdentity;
        }
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
            // Single camera fills the entire area (no filmstrip).
            // May be a remote camera OR the local self-view only (host camera on,
            // remote participant present but camera off).
            NSString *pid = self.cameraParticipantOrder.firstObject;
            if (pid) {
                InterRemoteVideoView *camView = self.remoteCameraViews[pid];
                if (!camView) break;

                camView.aspectFill = NO;
                InterRemoteVideoTileView *tile = [self tileForKey:pid videoView:camView];
                tile.nameLabel.hidden = YES; // no label in full-view mode
                tile.layer.cornerRadius = 0;
                tile.isSpeaking = [pid isEqualToString:self.activeSpeakerIdentity];
                [self addSubview:tile positioned:NSWindowBelow relativeTo:self.participantOverlay];
                tile.hidden = NO;
                camView.hidden = NO;
                [self setTile:tile frame:NSMakeRect(0, 0, W, H) animated:animated];
            } else if (self.localCaptureSession) {
                // No remote cameras yet — show local self-view tile filling the area
                // so the host can see themselves while waiting for the participant's camera.
                [self setupLocalSelfTileIfNeeded];
                NSView *selfTile = self.localSelfTileView;
                if (!selfTile) break;
                [self addSubview:selfTile positioned:NSWindowBelow relativeTo:self.participantOverlay];
                selfTile.hidden = NO;
                self.localPreviewLayer.frame = CGRectMake(0, 0, W, H);
                CGFloat lblH = 20.0, lblPad = 6.0;
                self.localSelfNameLabel.frame = NSMakeRect(lblPad, lblPad,
                                                           MIN(60.0, W - 2 * lblPad), lblH);
                if (animated) {
                    selfTile.animator.frame = NSMakeRect(0, 0, W, H);
                } else {
                    selfTile.frame = NSMakeRect(0, 0, W, H);
                }
                self.localPreviewLayer.frame = CGRectMake(0, 0, W, H);
                // Refresh the preview layer connection so it doesn't show a frozen frame.
                if (self.localCaptureSession) {
                    self.localPreviewLayer.session = self.localCaptureSession;
                }
            }
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

    // Always keep the toggle button as the topmost subview so nothing
    // (tiles, filmstrip, badge) can ever render in front of it.
    if (self.layoutToggleButton) {
        [self addSubview:self.layoutToggleButton positioned:NSWindowAbove relativeTo:nil];
        [self repositionLayoutToggleButton];
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

/// Renders 2-5 host-pinned tiles in a sub-grid inside the stage area, with all
/// other participants in the filmstrip.
- (void)applyMultiPinStageLayoutAnimated:(BOOL)animated {
    CGFloat W = self.bounds.size.width;
    CGFloat H = self.bounds.size.height;

    CGFloat filmstripW = W * kFilmstripWidthFraction;
    filmstripW = MAX(filmstripW, kFilmstripMinWidth);
    filmstripW = MIN(filmstripW, kFilmstripMaxWidth);
    CGFloat stageW = W - filmstripW;

    NSRect stageFrame = NSMakeRect(0, kFilmstripPadding,
                                   stageW - kFilmstripPadding, H - 2 * kFilmstripPadding);

    NSArray<NSString *> *pinnedKeys = self.hostForcedSpotlightTileKeys;
    NSSet<NSString *> *pinnedSet = [NSSet setWithArray:pinnedKeys];

    // Build filmstrip: every tile NOT in the pinned set.
    NSMutableArray<NSString *> *filmstripKeys = [NSMutableArray array];
    if (self.screenShareParticipantId && ![pinnedSet containsObject:kScreenShareTileKey]) {
        [filmstripKeys addObject:kScreenShareTileKey];
    }
    for (NSString *pid in self.cameraParticipantOrder) {
        if (![pinnedSet containsObject:pid]) [filmstripKeys addObject:pid];
    }
    if (self.localCaptureSession && ![pinnedSet containsObject:kLocalSelfTileKey]) {
        [self setupLocalSelfTileIfNeeded];
        if (self.localSelfTileView) [filmstripKeys addObject:kLocalSelfTileKey];
    }

    // --- Sub-grid of pinned tiles in the main stage ---
    NSUInteger count = pinnedKeys.count;
    NSUInteger cols, rows;
    [self gridDimensionsForCount:count cols:&cols rows:&rows];

    static const CGFloat kPinGap = 4.0;
    CGFloat pinTileW = (stageFrame.size.width  - kPinGap * (cols + 1)) / cols;
    CGFloat pinTileH = (stageFrame.size.height - kPinGap * (rows + 1)) / rows;

    for (NSUInteger i = 0; i < count; i++) {
        NSString *key = pinnedKeys[i];
        NSUInteger col = i % cols;
        NSUInteger row = i / cols;
        CGFloat x = stageFrame.origin.x + kPinGap + col * (pinTileW + kPinGap);
        CGFloat y = stageFrame.origin.y + stageFrame.size.height
                    - kPinGap - (row + 1) * pinTileH - row * kPinGap;
        NSRect tileFrame = NSMakeRect(x, y, pinTileW, pinTileH);

        InterRemoteVideoView *videoView = self.remoteCameraViews[key];
        if (!videoView) continue;
        InterRemoteVideoTileView *tile = [self tileForKey:key videoView:videoView];
        tile.nameLabel.hidden = NO;
        tile.layer.cornerRadius = 8.0;
        tile.isSpeaking = [key isEqualToString:self.activeSpeakerIdentity];

        // Set the correct frame BEFORE adding to the hierarchy.
        tile.frame = tileFrame;

        // Also pre-size the videoView explicitly so the Metal drawable is updated
        // to the correct dimensions before the display link fires. Without this,
        // a tile that was previously in the filmstrip (small frame) keeps its
        // filmstrip-sized metalLayer.frame / drawableSize until the deferred
        // layout pass runs on the main thread — causing the Metal layer to appear
        // as a tiny rectangle in the corner of the larger stage tile while the
        // rest of the tile shows black.
        videoView.frame = NSMakeRect(0, 0, pinTileW, pinTileH);

        [self addSubview:tile positioned:NSWindowBelow relativeTo:self.filmstripScrollView];
        tile.hidden = NO;
        videoView.hidden = NO;

        // Force a synchronous layout of the tile subtree so InterRemoteVideoView.layout()
        // runs NOW (updating metalLayer.frame and metalLayer.drawableSize) before the
        // CVDisplayLink fires on its background thread. This prevents the one-or-more-
        // frame black-tile window that would otherwise occur while the layout is deferred.
        [tile setNeedsLayout:YES];
        [tile layoutSubtreeIfNeeded];

        // If animated, fade the tile in rather than animating the frame.
        // Frame animation from an old (filmstrip) coordinate causes the Metal
        // drawable to resize mid-flight and can produce black frames.
        if (animated) {
            tile.alphaValue = 0.0;
            [tile.animator setAlphaValue:1.0];
        }

        [self notifyDimensionsChange:CGSizeMake(1280, 720) forParticipant:key];
    }

    // --- Filmstrip ---
    if (filmstripKeys.count == 0) {
        self.filmstripScrollView.hidden = YES;
        return;
    }
    self.filmstripScrollView.hidden = NO;
    NSRect filmstripFrame = NSMakeRect(stageW, 0, filmstripW, H);
    if (animated) { self.filmstripScrollView.animator.frame = filmstripFrame; }
    else          { self.filmstripScrollView.frame = filmstripFrame; }

    for (NSView *sub in [self.filmstripContentView.subviews copy]) [sub removeFromSuperview];

    CGFloat tileW = filmstripW - 2 * kFilmstripPadding;
    CGFloat tileH = tileW * 9.0 / 16.0;
    NSUInteger itemCount = filmstripKeys.count;
    CGFloat totalH = itemCount * tileH
                     + (MAX(itemCount, 1) - 1) * kFilmstripTileGap
                     + 2 * kFilmstripPadding;
    totalH = MAX(totalH, H);
    self.filmstripContentView.frame = NSMakeRect(0, 0, filmstripW, totalH);

    for (NSUInteger i = 0; i < filmstripKeys.count; i++) {
        NSString *key = filmstripKeys[i];
        CGFloat y = totalH - kFilmstripPadding - (i + 1) * tileH - i * kFilmstripTileGap;
        NSRect tileFrame = NSMakeRect(kFilmstripPadding, y, tileW, tileH);

        if ([key isEqualToString:kLocalSelfTileKey]) {
            NSView *selfTile = self.localSelfTileView;
            if (!selfTile) continue;
            selfTile.hidden = NO;
            self.localPreviewLayer.frame = CGRectMake(0, 0, tileW, tileH);
            CGFloat lblH = 20.0, lblPad = 6.0;
            self.localSelfNameLabel.frame = NSMakeRect(lblPad, lblPad, MIN(60.0, tileW - 2 * lblPad), lblH);
            [self.filmstripContentView addSubview:selfTile];
            if (animated) { selfTile.animator.frame = tileFrame; }
            else          { selfTile.frame = tileFrame; }
            self.localPreviewLayer.frame = CGRectMake(0, 0, tileFrame.size.width, tileFrame.size.height);
            continue;
        }

        InterRemoteVideoView *videoView = [key isEqualToString:kScreenShareTileKey]
                                          ? self.remoteScreenShareView
                                          : self.remoteCameraViews[key];
        if (!videoView) continue;

        InterRemoteVideoTileView *tile = [self tileForKey:key videoView:videoView];
        tile.nameLabel.hidden = NO;
        tile.layer.cornerRadius = 8.0;
        tile.hidden = NO;
        videoView.hidden = NO;
        if (![key isEqualToString:kScreenShareTileKey]) {
            tile.isSpeaking = [key isEqualToString:self.activeSpeakerIdentity];
        }
        [self.filmstripContentView addSubview:tile];
        if (animated) { tile.animator.frame = tileFrame; }
        else          { tile.frame = tileFrame; }
        if (![key isEqualToString:kScreenShareTileKey]) {
            [self notifyDimensionsChange:CGSizeMake(480, 270) forParticipant:key];
        }
    }
}

- (void)applyStageAndFilmstripLayoutAnimated:(BOOL)animated {
    // 2+ pinned tiles need their own sub-grid stage rendering.
    if (self.hostForcedSpotlightTileKeys.count > 1) {
        [self applyMultiPinStageLayoutAnimated:animated];
        return;
    }

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

    // Local self-view goes in the filmstrip unless it is the current spotlight.
    BOOL selfIsSpotlight = [kLocalSelfTileKey isEqualToString:spotlightKey];
    if (self.localCaptureSession && !selfIsSpotlight) {
        [self setupLocalSelfTileIfNeeded];
        if (self.localSelfTileView) {
            [filmstripKeys addObject:kLocalSelfTileKey];
        }
    }

    // --- Main stage ---
    NSRect stageFrame = NSMakeRect(0, kFilmstripPadding,
                                   stageW - kFilmstripPadding, H - 2 * kFilmstripPadding);

    if (selfIsSpotlight) {
        // Local self-view in the main stage.
        [self setupLocalSelfTileIfNeeded];
        NSView *selfTile = self.localSelfTileView;
        if (selfTile) {
            [self addSubview:selfTile positioned:NSWindowBelow relativeTo:self.filmstripScrollView];
            selfTile.hidden = NO;
            if (animated) {
                selfTile.animator.frame = stageFrame;
            } else {
                selfTile.frame = stageFrame;
            }
            // Keep the preview layer in sync with the new stage bounds.
            self.localPreviewLayer.frame = CGRectMake(0, 0, stageFrame.size.width, stageFrame.size.height);
            CGFloat lblH = 20.0, lblPad = 8.0;
            self.localSelfNameLabel.frame = NSMakeRect(lblPad, lblPad,
                                                       MIN(80.0, stageFrame.size.width - 2 * lblPad), lblH);
        }
    } else {
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

            [self setTile:stageTile frame:stageFrame animated:animated];

            // Phase 7.3.4: Request high-res for spotlighted view
            if (![spotlightKey isEqualToString:kScreenShareTileKey]) {
                [self notifyDimensionsChange:CGSizeMake(1280, 720) forParticipant:spotlightKey];
            }
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
        NSUInteger visualIndex = itemIndex + i;
        CGFloat y = totalH - kFilmstripPadding - (visualIndex + 1) * tileH - visualIndex * kFilmstripTileGap;
        NSRect tileFrame = NSMakeRect(kFilmstripPadding, y, tileW, tileH);

        // --- Local self-view tile ---
        if ([key isEqualToString:kLocalSelfTileKey]) {
            NSView *selfTile = self.localSelfTileView;
            if (!selfTile) continue;
            selfTile.hidden = NO;
            // Keep preview layer filling the tile
            self.localPreviewLayer.frame = CGRectMake(0, 0, tileW, tileH);
            // Name label: bottom-left pill
            CGFloat lblH = 20.0, lblPad = 6.0;
            self.localSelfNameLabel.frame = NSMakeRect(lblPad, lblPad, MIN(60.0, tileW - 2 * lblPad), lblH);
            [self.filmstripContentView addSubview:selfTile];
            if (animated) {
                selfTile.animator.frame = tileFrame;
            } else {
                selfTile.frame = tileFrame;
            }
            // Update preview layer to match new tile bounds
            self.localPreviewLayer.frame = CGRectMake(0, 0, tileFrame.size.width, tileFrame.size.height);
            continue;
        }

        // --- Remote camera / screen share tile ---
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

        [self.filmstripContentView addSubview:tile];
        if (animated) {
            tile.animator.frame = tileFrame;
        } else {
            tile.frame = tileFrame;
        }

        // Phase 7.3.4: Request reduced-res for filmstrip tiles.
        // 480×270 matches a typical WebRTC simulcast medium-low tier and avoids
        // requesting 320×180 which can cause the SFU to stall frame delivery
        // while switching to the lowest simulcast layer.
        if (![key isEqualToString:kScreenShareTileKey]) {
            [self notifyDimensionsChange:CGSizeMake(480, 270) forParticipant:key];
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
    // Build the participant list. In grid mode, append the local self-view tile last.
    NSMutableArray<NSString *> *allParticipants = [self.cameraParticipantOrder mutableCopy];
    BOOL includeLocalSelf = (self.gridLayoutEnabled && self.localCaptureSession != nil);
    if (includeLocalSelf) {
        [allParticipants addObject:kLocalSelfTileKey];
    }

    NSUInteger totalCount = allParticipants.count;
    if (totalCount == 0) return;

    NSUInteger maxPerPage = self.maxTilesPerPage;
    BOOL isPaginated = (totalCount > maxPerPage);
    NSUInteger pages = isPaginated ? (totalCount + maxPerPage - 1) / maxPerPage : 1;

    // Clamp current page to valid range
    if (self.currentGridPage >= pages) {
        self.currentGridPage = (pages > 0) ? pages - 1 : 0;
    }

    // Determine which participants are on the current page
    NSUInteger startIdx = self.currentGridPage * maxPerPage;
    NSUInteger endIdx = MIN(startIdx + maxPerPage, totalCount);
    NSArray<NSString *> *pageParticipants = [allParticipants subarrayWithRange:NSMakeRange(startIdx, endIdx - startIdx)];
    NSUInteger count = pageParticipants.count;

    // Phase 7.3.3: Track visibility changes for paged-out remote participants
    NSMutableSet<NSString *> *newVisibleSet = [NSMutableSet set];
    for (NSString *pid in pageParticipants) {
        if (![pid isEqualToString:kLocalSelfTileKey]) [newVisibleSet addObject:pid];
    }
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

    // Phase 7.3.4: Determine quality based on tile count
    CGSize qualityDimensions;
    if (count <= 4) {
        qualityDimensions = CGSizeMake(1280, 720);
    } else if (count <= 9) {
        qualityDimensions = CGSizeMake(640, 360);
    } else if (count <= 16) {
        qualityDimensions = CGSizeMake(480, 270);
    } else {
        qualityDimensions = CGSizeMake(320, 180);
    }

    for (NSUInteger i = 0; i < count; i++) {
        NSString *pid = pageParticipants[i];

        // --- Compute frame (common for all tile types) ---
        NSUInteger col = i % cols;
        NSUInteger row = i / cols;

        CGFloat x, y;
        y = gridRect.origin.y + (rows - 1 - row) * (cellH + gap);

        if (row == lastRow && lastRowIncomplete) {
            CGFloat lastRowTotalW = lastRowCount * cellW + (lastRowCount - 1) * gap;
            CGFloat offsetX = (gridRect.size.width - lastRowTotalW) / 2.0;
            x = gridRect.origin.x + offsetX + col * (cellW + gap);
        } else {
            x = gridRect.origin.x + col * (cellW + gap);
        }

        NSRect frame = NSMakeRect(x, y, cellW, cellH);

        // --- Local self-view tile ---
        if ([pid isEqualToString:kLocalSelfTileKey]) {
            [self setupLocalSelfTileIfNeeded];
            NSView *selfTile = self.localSelfTileView;
            if (!selfTile) continue;

            [self addSubview:selfTile positioned:NSWindowBelow relativeTo:self.participantOverlay];
            selfTile.hidden = NO;

            // Keep preview layer filling the tile
            self.localPreviewLayer.frame = CGRectMake(0, 0, cellW, cellH);

            // Name label: bottom-left pill
            CGFloat lblH = 20.0, lblPad = 6.0;
            self.localSelfNameLabel.frame = NSMakeRect(lblPad, lblPad,
                                                       MIN(60.0, cellW - 2 * lblPad), lblH);
            if (animated) {
                selfTile.animator.frame = frame;
            } else {
                selfTile.frame = frame;
            }
            // Keep the preview layer in sync with the tile's new bounds.
            self.localPreviewLayer.frame = CGRectMake(0, 0, frame.size.width, frame.size.height);
            continue;
        }

        // --- Remote camera tile ---
        InterRemoteVideoView *view = self.remoteCameraViews[pid];
        if (!view) continue;

        view.aspectFill = NO; // aspect-fit: downscale 2x keeps compression artifacts invisible
        InterRemoteVideoTileView *tile = [self tileForKey:pid videoView:view];
        tile.nameLabel.hidden = NO;
        tile.layer.cornerRadius = 8.0;
        [self addSubview:tile positioned:NSWindowBelow relativeTo:self.participantOverlay];
        tile.hidden = NO;
        view.hidden = NO;

        tile.isSpeaking = [pid isEqualToString:self.activeSpeakerIdentity];

        [self setTile:tile frame:frame animated:animated];
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
    if (self.localSelfTileView) {
        [self.localSelfTileView removeFromSuperview];
        self.localSelfTileView.hidden = YES;
    }
}

#pragma mark - Resize

- (void)setFrame:(NSRect)frame {
    [super setFrame:frame];
    [self applyCurrentLayoutAnimated:NO];
    [self updateParticipantCountBadge];
    [self repositionLayoutToggleButton];
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
    self.lastActiveSpeakerIdentity = nil;
    self.spotlightIsPinnedByUser = NO;

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

    // Track last active speaker so the stage spotlight fallback keeps the most
    // recently speaking participant on stage (not just insertion-order first).
    if (previousSpeaker.length > 0) {
        self.lastActiveSpeakerIdentity = previousSpeaker;
    }

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

    // Phase 7.4.2: Auto-spotlight active speaker in stage+filmstrip mode.
    // Skipped when the user has manually pinned a tile — their explicit choice
    // always takes priority over the automatic speaker-follow behaviour.
    if (self.autoSpotlightActiveSpeaker &&
        !self.spotlightIsPinnedByUser &&
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
    BOOL changed = (_remoteParticipantCount != remoteParticipantCount);
    _remoteParticipantCount = remoteParticipantCount;
    [self updateParticipantCountBadge];
    // Re-evaluate the toggle: participant count affects whether the call has
    // enough people to make a layout switch meaningful, even before video
    // frames have arrived from all participants.
    [self updateLayoutToggleButton];
    // Re-run layout: computeLayoutMode now uses remoteParticipantCount to decide
    // whether to show the local self-view tile (host camera on, participant camera off).
    // Without this, the host's self-view only appears after the participant's first frame
    // arrives — a multi-second blank screen when "mute camera on join" is set.
    if (changed) {
        [self updateLayoutAnimated:NO];
    }
}

- (void)updateParticipantCountBadge {
    // Show badge for any multi-person call (2+ total, i.e. 1+ remote).
    NSUInteger count = self.remoteParticipantCount;
    if (count < 1) {
        self.participantCountBadge.hidden = YES;
        return;
    }

    // +1 for the local participant.
    NSUInteger totalCount = count + 1;
    self.participantCountBadge.stringValue = [NSString stringWithFormat:@" 👥 %lu ", (unsigned long)totalCount];
    self.participantCountBadge.hidden = NO;

    [self.participantCountBadge sizeToFit];
    NSSize badgeSize = self.participantCountBadge.frame.size;
    badgeSize.width  = MAX(badgeSize.width + 8, 44);
    badgeSize.height = MAX(badgeSize.height, 22);

    // Position top-LEFT so it never overlaps the toggle button (top-right area).
    // In stage mode the filmstrip is on the right, so top-left is always clear.
    CGFloat x = 12;
    CGFloat y = self.bounds.size.height - badgeSize.height - 12;
    self.participantCountBadge.frame = NSMakeRect(x, y, badgeSize.width, badgeSize.height);

    // Ensure badge is below the toggle button in z-order.
    if (self.layoutToggleButton) {
        [self addSubview:self.participantCountBadge
              positioned:NSWindowBelow
              relativeTo:self.layoutToggleButton];
    }
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
