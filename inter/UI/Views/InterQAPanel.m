#import "InterQAPanel.h"

#if __has_include("inter-Swift.h")
#import "inter-Swift.h"
#endif

// The Q&A board is now SwiftUI (`QAView`), hosted via the Swift `InterQAHostView`
// bridge. This class is a thin Obj-C shell that preserves the original public API
// and the `InterQAPanelDelegate` contract, so `AppDelegate` (which owns the
// InterQAController wiring) is unchanged. The former AppKit implementation
// (NSTableView cells, expand/collapse strip, unread badge) was replaced — its
// behavior now lives in `QAViewModel` + `QAView`.

@interface InterQAPanel ()
@property (nonatomic, strong) InterQAHostView *host;
@end

@implementation InterQAPanel

#pragma mark - Lifecycle

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;
    [self buildQAHost];
    return self;
}

- (void)buildQAHost {
    self.host = [[InterQAHostView alloc] initWithFrame:self.bounds];
    self.host.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    __weak typeof(self) weakSelf = self;
    self.host.onSubmit = ^(NSString *text, BOOL isAnonymous) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf.delegate respondsToSelector:@selector(qaPanel:didSubmitQuestion:isAnonymous:)]) {
            [strongSelf.delegate qaPanel:strongSelf didSubmitQuestion:text isAnonymous:isAnonymous];
        }
    };
    self.host.onUpvote = ^(NSString *questionId) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf.delegate respondsToSelector:@selector(qaPanel:didUpvoteQuestion:)]) {
            [strongSelf.delegate qaPanel:strongSelf didUpvoteQuestion:questionId];
        }
    };
    self.host.onHighlight = ^(NSString *questionId) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf.delegate respondsToSelector:@selector(qaPanel:didHighlightQuestion:)]) {
            [strongSelf.delegate qaPanel:strongSelf didHighlightQuestion:questionId];
        }
    };
    self.host.onMarkAnswered = ^(NSString *questionId) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf.delegate respondsToSelector:@selector(qaPanel:didMarkAnswered:)]) {
            [strongSelf.delegate qaPanel:strongSelf didMarkAnswered:questionId];
        }
    };
    self.host.onDismissQuestion = ^(NSString *questionId) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf.delegate respondsToSelector:@selector(qaPanel:didDismissQuestion:)]) {
            [strongSelf.delegate qaPanel:strongSelf didDismissQuestion:questionId];
        }
    };

    [self addSubview:self.host];
}

#pragma mark - Public API

- (void)setIsHost:(BOOL)isHost {
    _isHost = isHost;
    self.host.isHost = isHost;
}

- (void)setQuestions:(NSArray<InterQuestionInfo *> *)questions {
    [self.host setQuestions:questions ?: @[]];
}

- (void)setUnreadBadge:(NSInteger)count {
#pragma unused(count)
    // Legacy no-op — visibility is window-level now (see header).
}

@end
