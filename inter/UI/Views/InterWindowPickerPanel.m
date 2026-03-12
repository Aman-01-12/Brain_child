#import "InterWindowPickerPanel.h"

#import <ScreenCaptureKit/ScreenCaptureKit.h>

// ---------------------------------------------------------------------------
// MARK: - Constants
// ---------------------------------------------------------------------------

static const CGFloat kPickerWidth           = 820.0;
static const CGFloat kPickerHeight          = 600.0;
static const CGFloat kTileSpacing           = 12.0;
static const CGFloat kTilePadding           = 20.0;
static const CGFloat kTileThumbnailHeight   = 140.0;
static const CGFloat kTileLabelHeight       = 44.0;
static const CGFloat kTileCornerRadius      = 10.0;
static const CGFloat kSelectedBorderWidth   = 3.0;
static const NSUInteger kGridColumns        = 3;
static const CGFloat kBottomBarHeight       = 56.0;

// ---------------------------------------------------------------------------
// MARK: - InterWindowInfo (internal model)
// ---------------------------------------------------------------------------

@interface InterWindowInfo : NSObject
@property (nonatomic, assign) CGWindowID windowID;
@property (nonatomic, copy) NSString *windowTitle;
@property (nonatomic, copy) NSString *appName;
@property (nonatomic, strong, nullable) NSImage *thumbnail;
@property (nonatomic, strong, nullable) NSImage *appIcon;
@end

@implementation InterWindowInfo
@end

// ---------------------------------------------------------------------------
// MARK: - InterWindowTileView (single tile in the grid)
// ---------------------------------------------------------------------------

@interface InterWindowTileView : NSView
@property (nonatomic, strong) InterWindowInfo *windowInfo;
@property (nonatomic, assign, getter=isSelected) BOOL selected;
@property (nonatomic, assign, getter=isHovered) BOOL hovered;
@property (nonatomic, copy, nullable) void (^clickHandler)(InterWindowTileView *tile);
@end

@implementation InterWindowTileView {
    NSImageView *_thumbnailView;
    NSImageView *_appIconView;
    NSTextField *_titleLabel;
    NSTextField *_subtitleLabel;
    NSTrackingArea *_trackingArea;
}

- (instancetype)initWithFrame:(NSRect)frameRect windowInfo:(InterWindowInfo *)info {
    self = [super initWithFrame:frameRect];
    if (!self) { return nil; }

    _windowInfo = info;
    _selected = NO;
    _hovered = NO;

    self.wantsLayer = YES;
    self.layer.cornerRadius = kTileCornerRadius;
    self.layer.masksToBounds = YES;
    self.layer.backgroundColor = [[NSColor colorWithWhite:0.12 alpha:1.0] CGColor];
    self.layer.borderWidth = 2.0;
    self.layer.borderColor = [[NSColor clearColor] CGColor];

    // Thumbnail
    _thumbnailView = [[NSImageView alloc] initWithFrame:NSMakeRect(0,
                                                                    kTileLabelHeight,
                                                                    frameRect.size.width,
                                                                    kTileThumbnailHeight)];
    _thumbnailView.imageScaling = NSImageScaleProportionallyUpOrDown;
    _thumbnailView.imageAlignment = NSImageAlignCenter;
    _thumbnailView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _thumbnailView.wantsLayer = YES;
    _thumbnailView.layer.backgroundColor = [[NSColor colorWithWhite:0.08 alpha:1.0] CGColor];
    if (info.thumbnail) {
        _thumbnailView.image = info.thumbnail;
    }
    [self addSubview:_thumbnailView];

    // Label area (bottom of tile)
    CGFloat labelAreaY = 0;
    CGFloat iconSize = 20.0;
    CGFloat iconPadding = 8.0;

    // App icon
    _appIconView = [[NSImageView alloc] initWithFrame:NSMakeRect(iconPadding,
                                                                  labelAreaY + (kTileLabelHeight - iconSize) / 2.0,
                                                                  iconSize, iconSize)];
    _appIconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    if (info.appIcon) {
        _appIconView.image = info.appIcon;
    }
    [self addSubview:_appIconView];

    CGFloat textX = iconPadding + iconSize + 6.0;
    CGFloat textWidth = frameRect.size.width - textX - 8.0;

    // Title (window name)
    NSString *displayTitle = info.windowTitle.length > 0 ? info.windowTitle : info.appName;
    _titleLabel = [NSTextField labelWithString:displayTitle ?: @"Untitled"];
    _titleLabel.frame = NSMakeRect(textX, labelAreaY + 22, textWidth, 16);
    _titleLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    _titleLabel.textColor = [NSColor colorWithWhite:0.92 alpha:1.0];
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _titleLabel.maximumNumberOfLines = 1;
    [self addSubview:_titleLabel];

    // Subtitle (app name, shown only if title != appName)
    NSString *subtitle = info.appName ?: @"";
    if ([subtitle isEqualToString:displayTitle]) { subtitle = @""; }
    _subtitleLabel = [NSTextField labelWithString:subtitle];
    _subtitleLabel.frame = NSMakeRect(textX, labelAreaY + 4, textWidth, 14);
    _subtitleLabel.font = [NSFont systemFontOfSize:10];
    _subtitleLabel.textColor = [NSColor colorWithWhite:0.60 alpha:1.0];
    _subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _subtitleLabel.maximumNumberOfLines = 1;
    [self addSubview:_subtitleLabel];

    return self;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea) {
        [self removeTrackingArea:_trackingArea];
    }
    _trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                 options:(NSTrackingMouseEnteredAndExited |
                                                          NSTrackingActiveInKeyWindow)
                                                   owner:self
                                                userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (void)mouseEntered:(NSEvent *)event {
#pragma unused(event)
    self.hovered = YES;
    [self updateAppearance];
}

- (void)mouseExited:(NSEvent *)event {
#pragma unused(event)
    self.hovered = NO;
    [self updateAppearance];
}

- (void)mouseDown:(NSEvent *)event {
#pragma unused(event)
    if (self.clickHandler) {
        self.clickHandler(self);
    }
}

- (void)setSelected:(BOOL)selected {
    _selected = selected;
    [self updateAppearance];
}

- (void)updateAppearance {
    if (self.isSelected) {
        self.layer.borderColor = [[NSColor systemBlueColor] CGColor];
        self.layer.borderWidth = kSelectedBorderWidth;
        self.layer.backgroundColor = [[NSColor colorWithWhite:0.16 alpha:1.0] CGColor];
    } else if (self.isHovered) {
        self.layer.borderColor = [[NSColor colorWithWhite:0.4 alpha:1.0] CGColor];
        self.layer.borderWidth = 2.0;
        self.layer.backgroundColor = [[NSColor colorWithWhite:0.15 alpha:1.0] CGColor];
    } else {
        self.layer.borderColor = [[NSColor clearColor] CGColor];
        self.layer.borderWidth = 2.0;
        self.layer.backgroundColor = [[NSColor colorWithWhite:0.12 alpha:1.0] CGColor];
    }
}

- (BOOL)isFlipped { return YES; }

@end

// ---------------------------------------------------------------------------
// MARK: - InterWindowPickerPanel
// ---------------------------------------------------------------------------

@interface InterWindowPickerPanel ()
@property (nonatomic, copy) InterWindowPickerCompletion completion;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSView *gridContainer;
@property (nonatomic, strong) NSMutableArray<InterWindowTileView *> *tiles;
@property (nonatomic, strong, nullable) InterWindowTileView *selectedTile;
@property (nonatomic, strong) NSButton *shareButton;
@property (nonatomic, strong) NSButton *cancelButton;
@end

@implementation InterWindowPickerPanel

// ---------------------------------------------------------------------------
// MARK: Public
// ---------------------------------------------------------------------------

+ (void)showPickerRelativeToWindow:(NSWindow *)parentWindow
                        completion:(InterWindowPickerCompletion)completion {
    NSRect parentFrame = parentWindow.frame;
    CGFloat x = NSMidX(parentFrame) - kPickerWidth / 2.0;
    CGFloat y = NSMidY(parentFrame) - kPickerHeight / 2.0;
    NSRect panelFrame = NSMakeRect(x, y, kPickerWidth, kPickerHeight);

    InterWindowPickerPanel *picker = [[InterWindowPickerPanel alloc]
        initWithContentRect:panelFrame
                  styleMask:(NSWindowStyleMaskTitled |
                             NSWindowStyleMaskClosable |
                             NSWindowStyleMaskFullSizeContentView)
                    backing:NSBackingStoreBuffered
                      defer:NO];

    picker.completion = completion;
    picker.title = @"Choose a window to share";
    picker.titlebarAppearsTransparent = YES;
    picker.titleVisibility = NSWindowTitleHidden;
    picker.backgroundColor = [NSColor colorWithWhite:0.10 alpha:1.0];
    picker.opaque = NO;
    picker.movableByWindowBackground = YES;
    picker.level = NSModalPanelWindowLevel;
    picker.releasedWhenClosed = NO;

    [picker buildUI];
    [picker loadWindows];

    [parentWindow beginSheet:picker completionHandler:^(NSModalResponse returnCode) {
#pragma unused(returnCode)
    }];
}

// ---------------------------------------------------------------------------
// MARK: UI Construction
// ---------------------------------------------------------------------------

- (void)buildUI {
    NSView *content = self.contentView;
    content.wantsLayer = YES;
    content.layer.backgroundColor = [[NSColor colorWithWhite:0.10 alpha:1.0] CGColor];

    // Header label
    NSTextField *headerLabel = [NSTextField labelWithString:@"Choose a window to share"];
    headerLabel.font = [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold];
    headerLabel.textColor = [NSColor colorWithWhite:0.94 alpha:1.0];
    headerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:headerLabel];

    // Scroll view for grid
    self.scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.hasHorizontalScroller = NO;
    self.scrollView.borderType = NSNoBorder;
    self.scrollView.backgroundColor = [NSColor colorWithWhite:0.10 alpha:1.0];
    self.scrollView.drawsBackground = YES;

    self.gridContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kPickerWidth, 400)];
    self.gridContainer.wantsLayer = YES;
    self.scrollView.documentView = self.gridContainer;
    [content addSubview:self.scrollView];

    // Bottom bar
    NSView *bottomBar = [[NSView alloc] initWithFrame:NSZeroRect];
    bottomBar.translatesAutoresizingMaskIntoConstraints = NO;
    bottomBar.wantsLayer = YES;
    bottomBar.layer.backgroundColor = [[NSColor colorWithWhite:0.08 alpha:1.0] CGColor];
    [content addSubview:bottomBar];

    // Cancel button
    self.cancelButton = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(handleCancel:)];
    self.cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.cancelButton.bezelStyle = NSBezelStyleRounded;
    [bottomBar addSubview:self.cancelButton];

    // Share button
    self.shareButton = [NSButton buttonWithTitle:@"Share" target:self action:@selector(handleShare:)];
    self.shareButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.shareButton.bezelStyle = NSBezelStyleRounded;
    self.shareButton.keyEquivalent = @"\r";
    self.shareButton.enabled = NO;
    if (@available(macOS 11.0, *)) {
        self.shareButton.hasDestructiveAction = NO;
        self.shareButton.bezelColor = [NSColor systemBlueColor];
    }
    [bottomBar addSubview:self.shareButton];

    // Layout
    [NSLayoutConstraint activateConstraints:@[
        // Header
        [headerLabel.topAnchor constraintEqualToAnchor:content.topAnchor constant:16],
        [headerLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:kTilePadding],
        [headerLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-kTilePadding],

        // Scroll view
        [self.scrollView.topAnchor constraintEqualToAnchor:headerLabel.bottomAnchor constant:12],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:bottomBar.topAnchor],

        // Bottom bar
        [bottomBar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [bottomBar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [bottomBar.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [bottomBar.heightAnchor constraintEqualToConstant:kBottomBarHeight],

        // Cancel button
        [self.cancelButton.trailingAnchor constraintEqualToAnchor:self.shareButton.leadingAnchor constant:-12],
        [self.cancelButton.centerYAnchor constraintEqualToAnchor:bottomBar.centerYAnchor],

        // Share button
        [self.shareButton.trailingAnchor constraintEqualToAnchor:bottomBar.trailingAnchor constant:-kTilePadding],
        [self.shareButton.centerYAnchor constraintEqualToAnchor:bottomBar.centerYAnchor],
        [self.shareButton.widthAnchor constraintGreaterThanOrEqualToConstant:80],
    ]];
}

// ---------------------------------------------------------------------------
// MARK: Window Enumeration (ScreenCaptureKit)
// ---------------------------------------------------------------------------

- (void)loadWindows {
    self.tiles = [NSMutableArray array];
    self.selectedTile = nil;

    // Show loading indicator
    NSProgressIndicator *spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(kPickerWidth / 2.0 - 16, 180, 32, 32)];
    spinner.style = NSProgressIndicatorStyleSpinning;
    spinner.controlSize = NSControlSizeRegular;
    [spinner startAnimation:nil];
    [self.gridContainer addSubview:spinner];
    self.gridContainer.frame = NSMakeRect(0, 0, kPickerWidth, 400);

    __weak typeof(self) weakSelf = self;
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES
                                              onScreenWindowsOnly:YES
                                                completionHandler:^(SCShareableContent * _Nullable content,
                                                                    NSError * _Nullable error) {
        if (error || !content) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [spinner removeFromSuperview];
                [weakSelf showEmptyState:@"Unable to access windows. Check Screen Recording permission."];
            });
            return;
        }

        NSArray<SCWindow *> *filteredSCWindows = nil;
        NSArray<InterWindowInfo *> *windows = [weakSelf filterShareableWindows:content
                                                               outSCWindows:&filteredSCWindows];

        // Capture thumbnails in parallel using SCScreenshotManager
        [weakSelf captureThumbnailsForWindows:windows
                                   scWindows:filteredSCWindows
                                  completion:^(NSArray<InterWindowInfo *> *updatedWindows) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [spinner removeFromSuperview];
                [weakSelf buildGridWithWindows:updatedWindows];
            });
        }];
    }];
}

- (NSArray<InterWindowInfo *> *)filterShareableWindows:(SCShareableContent *)content
                                          outSCWindows:(NSArray<SCWindow *> * __autoreleasing *)outSCWindows {
    pid_t ownPID = [NSProcessInfo processInfo].processIdentifier;
    NSString *ownBundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    NSMutableArray<InterWindowInfo *> *results = [NSMutableArray array];
    NSMutableArray<SCWindow *> *scWindowResults = [NSMutableArray array];

    for (SCWindow *window in content.windows) {
        // Skip non-normal-layer windows (menus, tooltips, etc.)
        if (window.windowLayer != 0) { continue; }

        // Skip windows that are not on screen
        if (!window.isOnScreen) { continue; }

        // Skip our own app's windows
        SCRunningApplication *owningApp = window.owningApplication;
        if (owningApp.processID == ownPID) { continue; }
        if (ownBundleIdentifier.length > 0 &&
            [owningApp.bundleIdentifier isEqualToString:ownBundleIdentifier]) { continue; }

        // Skip very small windows (likely invisible UI elements)
        CGRect frame = window.frame;
        if (CGRectGetWidth(frame) < 100 || CGRectGetHeight(frame) < 60) { continue; }

        InterWindowInfo *info = [[InterWindowInfo alloc] init];
        info.windowID = window.windowID;
        info.appName = owningApp.applicationName ?: @"Unknown";
        info.windowTitle = window.title ?: @"";

        // App icon from bundle identifier
        NSRunningApplication *runningApp =
            [NSRunningApplication runningApplicationWithProcessIdentifier:owningApp.processID];
        info.appIcon = runningApp.icon;

        [results addObject:info];
        [scWindowResults addObject:window];
    }

    if (outSCWindows) {
        *outSCWindows = [scWindowResults copy];
    }
    return [results copy];
}

- (void)captureThumbnailsForWindows:(NSArray<InterWindowInfo *> *)windows
                          scWindows:(NSArray<SCWindow *> *)scWindows
                         completion:(void (^)(NSArray<InterWindowInfo *> *))completion {
    if (windows.count == 0) {
        completion(windows);
        return;
    }

    dispatch_group_t group = dispatch_group_create();

    for (NSUInteger i = 0; i < windows.count; i++) {
        InterWindowInfo *info = windows[i];
        SCWindow *scWindow = (i < scWindows.count) ? scWindows[i] : nil;
        if (!scWindow) { continue; }

        dispatch_group_enter(group);

        SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:scWindow];
        SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
        // Use smaller resolution for thumbnails
        config.width = 480;
        config.height = 320;
        config.showsCursor = NO;
        config.scalesToFit = YES;

        [SCScreenshotManager captureImageWithFilter:filter
                                      configuration:config
                                  completionHandler:^(CGImageRef _Nullable sampleImage,
                                                      NSError * _Nullable captureError) {
            if (sampleImage && !captureError) {
                NSSize imageSize = NSMakeSize(CGImageGetWidth(sampleImage), CGImageGetHeight(sampleImage));
                NSImage *thumbnail = [[NSImage alloc] initWithCGImage:sampleImage size:imageSize];
                info.thumbnail = thumbnail;
            }
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        completion(windows);
    });
}

- (void)showEmptyState:(NSString *)message {
    for (NSView *subview in [self.gridContainer.subviews copy]) {
        [subview removeFromSuperview];
    }

    NSTextField *emptyLabel = [NSTextField labelWithString:message];
    emptyLabel.font = [NSFont systemFontOfSize:14];
    emptyLabel.textColor = [NSColor colorWithWhite:0.6 alpha:1.0];
    emptyLabel.alignment = NSTextAlignmentCenter;
    emptyLabel.frame = NSMakeRect(20, 180, kPickerWidth - 40, 40);
    [self.gridContainer addSubview:emptyLabel];
    self.gridContainer.frame = NSMakeRect(0, 0, kPickerWidth, 400);
}

- (void)buildGridWithWindows:(NSArray<InterWindowInfo *> *)windows {
    // Remove old tiles
    for (NSView *subview in [self.gridContainer.subviews copy]) {
        [subview removeFromSuperview];
    }

    [self.tiles removeAllObjects];

    if (windows.count == 0) {
        [self showEmptyState:@"No windows available to share."];
        return;
    }

    CGFloat availableWidth = kPickerWidth - kTilePadding * 2;
    CGFloat tileWidth = (availableWidth - kTileSpacing * (kGridColumns - 1)) / kGridColumns;
    CGFloat tileHeight = kTileThumbnailHeight + kTileLabelHeight;
    NSUInteger rowCount = (windows.count + kGridColumns - 1) / kGridColumns;
    CGFloat totalHeight = rowCount * tileHeight + (rowCount - 1) * kTileSpacing + kTilePadding * 2;

    // Ensure the grid is at least as tall as the scroll view
    self.gridContainer.frame = NSMakeRect(0, 0, kPickerWidth, MAX(totalHeight, 400));

    __weak typeof(self) weakSelf = self;
    for (NSUInteger i = 0; i < windows.count; i++) {
        InterWindowInfo *info = windows[i];
        NSUInteger col = i % kGridColumns;
        NSUInteger row = i / kGridColumns;

        // In a non-flipped view, y=0 is bottom. We want row 0 at the top.
        CGFloat x = kTilePadding + col * (tileWidth + kTileSpacing);
        CGFloat y = totalHeight - kTilePadding - (row + 1) * tileHeight - row * kTileSpacing;

        NSRect tileFrame = NSMakeRect(x, y, tileWidth, tileHeight);
        InterWindowTileView *tile = [[InterWindowTileView alloc] initWithFrame:tileFrame windowInfo:info];
        tile.clickHandler = ^(InterWindowTileView *clicked) {
            [weakSelf handleTileClicked:clicked];
        };

        [self.gridContainer addSubview:tile];
        [self.tiles addObject:tile];
    }
}

// ---------------------------------------------------------------------------
// MARK: Actions
// ---------------------------------------------------------------------------

- (void)handleTileClicked:(InterWindowTileView *)clicked {
    // Deselect previous
    if (self.selectedTile && self.selectedTile != clicked) {
        self.selectedTile.selected = NO;
    }

    // Toggle selection
    clicked.selected = !clicked.isSelected;
    self.selectedTile = clicked.isSelected ? clicked : nil;
    self.shareButton.enabled = (self.selectedTile != nil);
}

- (void)handleShare:(id)sender {
#pragma unused(sender)
    NSString *identifier = nil;
    if (self.selectedTile) {
        identifier = [NSString stringWithFormat:@"%u", self.selectedTile.windowInfo.windowID];
    }

    InterWindowPickerCompletion handler = self.completion;
    self.completion = nil;

    NSWindow *parent = self.sheetParent;
    if (parent) {
        [parent endSheet:self returnCode:NSModalResponseOK];
    } else {
        [self orderOut:nil];
    }

    if (handler) {
        handler(identifier);
    }
}

- (void)handleCancel:(id)sender {
#pragma unused(sender)
    InterWindowPickerCompletion handler = self.completion;
    self.completion = nil;

    NSWindow *parent = self.sheetParent;
    if (parent) {
        [parent endSheet:self returnCode:NSModalResponseCancel];
    } else {
        [self orderOut:nil];
    }

    if (handler) {
        handler(nil);
    }
}

// Handle clicking the close button as a cancel
- (void)close {
    if (self.completion) {
        [self handleCancel:nil];
        return;
    }
    [super close];
}

@end
