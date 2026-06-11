// ============================================================================
// InterLobbyWaitingView.m
// inter
//
// Participant-side waiting room — now SwiftUI (`LobbyWaitingView`), hosted via the Swift
// `InterLobbyWaitingBridgeView`. This is a thin Obj-C shell preserving the original public
// API + `InterLobbyWaitingViewDelegate` so `AppDelegate`'s polling/admission flow is unchanged.
//
// ISOLATION INVARIANT [G8]: still has NO side effects on networking or media — all actions
// are reported via the delegate protocol (cancel).
// ============================================================================

#import "InterLobbyWaitingView.h"

#if __has_include("inter-Swift.h")
#import "inter-Swift.h"
#endif

@interface InterLobbyWaitingView ()
@property (nonatomic, strong) InterLobbyWaitingBridgeView *bridge;
@end

@implementation InterLobbyWaitingView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;
    [self buildBridge];
    return self;
}

- (void)buildBridge {
    self.bridge = [[InterLobbyWaitingBridgeView alloc] initWithFrame:self.bounds];
    self.bridge.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    __weak typeof(self) weakSelf = self;
    self.bridge.onCancel = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf.delegate respondsToSelector:@selector(lobbyWaitingViewDidCancel:)]) {
            [strongSelf.delegate lobbyWaitingViewDidCancel:strongSelf];
        }
    };

    [self addSubview:self.bridge];
}

// MARK: - Public API (forwarded to the SwiftUI bridge)

- (void)showJoining { [self.bridge showJoining]; }
- (void)showWaiting { [self.bridge showWaiting]; }
- (void)showDenied  { [self.bridge showDenied]; }
- (void)showAdmitted { [self.bridge showAdmitted]; }

- (void)setPosition:(NSInteger)position {
    [self.bridge setPosition:position];
}

- (void)setStatusMessage:(NSString *)message {
    [self.bridge setStatusMessage:message ?: @""];
}

@end
