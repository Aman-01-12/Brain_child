#import "InterPollPanel.h"

#if __has_include("inter-Swift.h")
#import "inter-Swift.h"
#endif

// The poll panel is now SwiftUI (`PollView`), hosted via the Swift
// `InterPollHostView` bridge. This class is a thin Obj-C shell that preserves
// the original public API and the `InterPollPanelDelegate` contract, so
// `AppDelegate` (which owns the InterPollController wiring) is unchanged. The
// former AppKit implementation (manual-frame create form, dynamic results
// rebuild, vote radio/checkbox rows) was replaced — its behavior now lives in
// `PollViewModel` + `PollView`.

@interface InterPollPanel ()
@property (nonatomic, strong) InterPollHostView *host;
@end

@implementation InterPollPanel

#pragma mark - Lifecycle

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;
    [self buildPollHost];
    return self;
}

- (void)buildPollHost {
    self.host = [[InterPollHostView alloc] initWithFrame:self.bounds];
    self.host.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    __weak typeof(self) weakSelf = self;
    self.host.onLaunch = ^(NSString *question, NSArray<NSString *> *options, BOOL isAnonymous, BOOL allowMultiSelect) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf.delegate respondsToSelector:@selector(pollPanel:didLaunchPollWithQuestion:options:isAnonymous:allowMultiSelect:)]) {
            [strongSelf.delegate pollPanel:strongSelf
                 didLaunchPollWithQuestion:question
                                   options:options
                               isAnonymous:isAnonymous
                          allowMultiSelect:allowMultiSelect];
        }
    };
    self.host.onEndPoll = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf.delegate respondsToSelector:@selector(pollPanelDidEndPoll:)]) {
            [strongSelf.delegate pollPanelDidEndPoll:strongSelf];
        }
    };
    self.host.onShareResults = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf.delegate respondsToSelector:@selector(pollPanelDidRequestShareResults:)]) {
            [strongSelf.delegate pollPanelDidRequestShareResults:strongSelf];
        }
    };
    self.host.onSubmitVote = ^(NSArray<NSNumber *> *indices) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf.delegate respondsToSelector:@selector(pollPanel:didSubmitVoteWithIndices:)]) {
            [strongSelf.delegate pollPanel:strongSelf didSubmitVoteWithIndices:indices];
        }
    };

    [self addSubview:self.host];
}

#pragma mark - Public API

- (void)setIsHost:(BOOL)isHost {
    _isHost = isHost;
    self.host.isHost = isHost;
}

- (void)showActivePoll:(InterPollInfo *)poll {
    [self.host showActivePoll:poll];
}

- (void)updateResults:(InterPollInfo *)poll {
    [self.host updateResults:poll];
}

- (void)showEndedPoll:(InterPollInfo *)poll {
    [self.host showEndedPoll:poll];
}

- (void)resetToCreateForm {
    [self.host resetToCreateForm];
}

#pragma mark - Toggle / Expand / Collapse (window-level, behavior unchanged)

- (BOOL)isExpanded {
    return self.window != nil && self.window.isVisible;
}

- (void)togglePanel {
    if (self.isExpanded) {
        [self collapsePanel];
    } else {
        [self expandPanel];
    }
}

- (void)expandPanel {
    [self.window makeKeyAndOrderFront:nil];
}

- (void)collapsePanel {
    [self.window orderOut:nil];
}

@end

