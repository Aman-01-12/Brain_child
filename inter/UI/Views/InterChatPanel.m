#import "InterChatPanel.h"

#if __has_include("inter-Swift.h")
#import "inter-Swift.h"
#endif

// The chat panel BODY is now SwiftUI (`ChatView`), hosted via the Swift
// `InterChatHostView` bridge. This class keeps what must stay AppKit — the
// slide-in container + animation, the click pass-through hit-testing over the
// stage, and the unread badge (it must render while the container is
// off-screen) — and preserves the original public API and the
// `InterChatPanelDelegate` contract, so AppDelegate (normal call) and
// SecureWindowController (secure overlay) are unchanged. The former
// NSTableView/NSTextField implementation was replaced — its behavior now
// lives in `ChatViewModel` + `ChatView`.

/// Catalogue panel width (ChatMock). Clamped to the overlay bounds so the
/// secure mode's 320pt window is filled edge-to-edge.
static const CGFloat InterChatPanelMaxWidth = 360.0;
static const CGFloat InterChatAnimationDuration = 0.25;

@interface InterChatPanel ()

@property (nonatomic, strong) NSView *containerView;
@property (nonatomic, strong) InterChatHostView *host;
@property (nonatomic, strong) NSView *unreadBadgeView;
@property (nonatomic, strong) NSTextField *unreadLabel;
@property (nonatomic, assign) BOOL expanded;

@end

@implementation InterChatPanel

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _expanded = NO;
        [self setupViews];
    }
    return self;
}

- (BOOL)isExpanded {
    return self.expanded;
}

/// Effective slide-in width: the catalogue's 360pt, clamped to the overlay.
- (CGFloat)panelWidth {
    return MIN(InterChatPanelMaxWidth, self.bounds.size.width);
}

/// Pass through mouse events when collapsed. Only forward hits that land
/// inside the visible container view when expanded.
- (NSView *)hitTest:(NSPoint)point {
    if (!self.expanded) {
        return nil;  // Fully transparent to clicks when collapsed
    }
    // point is in superview coordinates — convert to self's coords for child hit-testing
    NSPoint pointInSelf = [self convertPoint:point fromView:self.superview];
    // Check if the point falls inside the container
    NSPoint containerPoint = [self.containerView convertPoint:pointInSelf fromView:self];
    if (NSPointInRect(containerPoint, self.containerView.bounds)) {
        // hitTest: expects the point in the *superview's* coordinate system,
        // so pass pointInSelf (self is containerView's superview).
        return [self.containerView hitTest:pointInSelf];
    }
    return nil;  // Click is outside the panel slide-in area
}

#pragma mark - Setup

- (void)setupViews {
    [self setWantsLayer:YES];
    self.layer.backgroundColor = [NSColor clearColor].CGColor;

    // Container: the actual panel content (starts off-screen right)
    self.containerView = [[NSView alloc] initWithFrame:NSMakeRect(self.bounds.size.width,
                                                                   0,
                                                                   [self panelWidth],
                                                                   self.bounds.size.height)];
    self.containerView.autoresizingMask = NSViewHeightSizable;
    [self.containerView setWantsLayer:YES];
    [self addSubview:self.containerView];

    [self setupChatHost];
    [self setupUnreadBadge];
}

- (void)setupChatHost {
    self.host = [[InterChatHostView alloc] initWithFrame:self.containerView.bounds];
    self.host.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    __weak typeof(self) weakSelf = self;
    self.host.onSend = ^(NSString *text) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf.delegate respondsToSelector:@selector(chatPanel:didSubmitMessage:)]) {
            [strongSelf.delegate chatPanel:strongSelf didSubmitMessage:text];
        }
    };
    self.host.onSelectRecipient = ^(NSString * _Nullable identity) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf.delegate respondsToSelector:@selector(chatPanel:didSelectRecipient:)]) {
            [strongSelf.delegate chatPanel:strongSelf didSelectRecipient:identity];
        }
    };
    self.host.onAttach = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf.delegate respondsToSelector:@selector(chatPanelDidRequestFileAttach:)]) {
            [strongSelf.delegate chatPanelDidRequestFileAttach:strongSelf];
        }
    };
    self.host.onExport = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf.delegate respondsToSelector:@selector(chatPanelDidRequestExport:)]) {
            [strongSelf.delegate chatPanelDidRequestExport:strongSelf];
        }
    };
    self.host.onDownload = ^(InterChatMessageInfo *message) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf.delegate respondsToSelector:@selector(chatPanel:didRequestDownloadFileMessage:)]) {
            [strongSelf.delegate chatPanel:strongSelf didRequestDownloadFileMessage:message];
        }
    };
    self.host.onClose = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf handleHeaderCloseRequest];
    };

    [self.containerView addSubview:self.host];
}

/// Single entry point for the in-panel header "X". The delegate owns close when it
/// opts in (overlay-window hosts hide their window instead of sliding the panel
/// off-screen). Otherwise fall back to the in-window collapse used by the normal
/// call layout, which has no separate window to hide.
- (void)handleHeaderCloseRequest {
    if ([self.delegate respondsToSelector:@selector(chatPanelDidRequestClose:)]) {
        [self.delegate chatPanelDidRequestClose:self];
    } else {
        [self collapsePanel];
    }
}

- (void)setupUnreadBadge {
    // Badge sits next to the panel toggle button (positioned by the container)
    self.unreadBadgeView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 22, 22)];
    [self.unreadBadgeView setWantsLayer:YES];
    self.unreadBadgeView.layer.backgroundColor = [NSColor systemRedColor].CGColor;
    self.unreadBadgeView.layer.cornerRadius = 11.0;
    self.unreadBadgeView.hidden = YES;

    self.unreadLabel = [NSTextField labelWithString:@"0"];
    self.unreadLabel.frame = NSMakeRect(0, 2, 22, 16);
    self.unreadLabel.font = [NSFont boldSystemFontOfSize:10];
    self.unreadLabel.textColor = [NSColor whiteColor];
    self.unreadLabel.alignment = NSTextAlignmentCenter;
    [self.unreadBadgeView addSubview:self.unreadLabel];
    [self addSubview:self.unreadBadgeView];
}

#pragma mark - Public API

- (void)appendMessage:(InterChatMessageInfo *)message {
    [self.host appendMessage:message];
}

- (void)setUnreadBadge:(NSInteger)count {
    if (count <= 0) {
        self.unreadBadgeView.hidden = YES;
        return;
    }

    self.unreadBadgeView.hidden = NO;
    NSString *text = count > 99 ? @"99+" : [NSString stringWithFormat:@"%ld", (long)count];
    self.unreadLabel.stringValue = text;

    // Resize badge for wide numbers
    CGFloat badgeW = count > 9 ? 28.0 : 22.0;
    NSRect badgeFrame = self.unreadBadgeView.frame;
    badgeFrame.size.width = badgeW;
    self.unreadBadgeView.frame = badgeFrame;
    self.unreadBadgeView.layer.cornerRadius = badgeW / 2.0;
    self.unreadLabel.frame = NSMakeRect(0, 2, badgeW, 16);
}

- (void)setParticipantList:(nullable NSArray<NSDictionary<NSString *, NSString *> *> *)participants {
    [self.host setParticipantList:participants ?: @[]];
}

#pragma mark - Panel Toggle

- (void)togglePanel {
    if (self.expanded) {
        [self collapsePanel];
    } else {
        [self expandPanel];
    }
}

- (void)expandPanel {
    if (self.expanded) return;
    self.expanded = YES;
    self.hidden = NO;

    CGFloat panelW = [self panelWidth];
    CGFloat targetX = self.bounds.size.width - panelW;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = InterChatAnimationDuration;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        self.containerView.animator.frame = NSMakeRect(targetX, 0,
                                                        panelW,
                                                        self.bounds.size.height);
    } completionHandler:^{
        [self.host focusInput];
    }];
}

- (void)collapsePanel {
    if (!self.expanded) return;
    self.expanded = NO;

    CGFloat offscreenX = self.bounds.size.width;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = InterChatAnimationDuration;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        self.containerView.animator.frame = NSMakeRect(offscreenX, 0,
                                                        [self panelWidth],
                                                        self.bounds.size.height);
    } completionHandler:nil];
}

#pragma mark - Layout

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    [super resizeSubviewsWithOldSize:oldSize];

    CGFloat panelW = [self panelWidth];
    if (self.expanded) {
        CGFloat targetX = self.bounds.size.width - panelW;
        self.containerView.frame = NSMakeRect(targetX, 0,
                                               panelW,
                                               self.bounds.size.height);
    } else {
        self.containerView.frame = NSMakeRect(self.bounds.size.width, 0,
                                               panelW,
                                               self.bounds.size.height);
    }
}

#pragma mark - Phase 9: Moderation

- (void)setChatInputEnabled:(BOOL)enabled {
    [self.host setChatInputEnabled:enabled];
}

- (void)setExportButtonHidden:(BOOL)hidden {
    [self.host setExportButtonHidden:hidden];
}

- (void)setUploadInProgress:(BOOL)inProgress {
    // The view model keeps the upload and moderation flags separate, so ending
    // an upload never re-enables a composer that moderation disabled.
    [self.host setUploadInProgress:inProgress];
}

- (void)displaySystemMessage:(NSString *)text {
    InterChatMessageInfo *sysMessage = [[InterChatMessageInfo alloc] initWithSystemText:text];
    [self appendMessage:sysMessage];
}

@end
