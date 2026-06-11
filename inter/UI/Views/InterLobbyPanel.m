#import "InterLobbyPanel.h"

#if __has_include("inter-Swift.h")
#import "inter-Swift.h"
#endif

// The host-side waiting room is now SwiftUI (`LobbyHostView`), hosted via the Swift
// `InterLobbyPanelBridgeView`. This class is a thin Obj-C shell that preserves the original
// public API + `InterLobbyPanelDelegate` contract, so `AppDelegate` (which owns the lobby
// admission backend via the moderation controller) is unchanged.

@interface InterLobbyPanel ()
@property (nonatomic, strong) InterLobbyPanelBridgeView *bridge;
@end

@implementation InterLobbyPanel

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;
    [self buildBridge];
    return self;
}

- (void)buildBridge {
    self.bridge = [[InterLobbyPanelBridgeView alloc] initWithFrame:self.bounds];
    self.bridge.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    __weak typeof(self) weakSelf = self;
    self.bridge.onAdmit = ^(NSString *identity, NSString *displayName) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf.delegate respondsToSelector:@selector(lobbyPanel:didAdmitParticipant:displayName:)]) {
            [strongSelf.delegate lobbyPanel:strongSelf didAdmitParticipant:identity displayName:displayName];
        }
    };
    self.bridge.onDeny = ^(NSString *identity) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf.delegate respondsToSelector:@selector(lobbyPanel:didDenyParticipant:)]) {
            [strongSelf.delegate lobbyPanel:strongSelf didDenyParticipant:identity];
        }
    };
    self.bridge.onAdmitAll = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf.delegate respondsToSelector:@selector(lobbyPanelDidAdmitAll:)]) {
            [strongSelf.delegate lobbyPanelDidAdmitAll:strongSelf];
        }
    };
    self.bridge.onToggleLobby = ^(BOOL enabled) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf.delegate respondsToSelector:@selector(lobbyPanel:didToggleLobbyEnabled:)]) {
            [strongSelf.delegate lobbyPanel:strongSelf didToggleLobbyEnabled:enabled];
        }
    };

    [self addSubview:self.bridge];
}

// MARK: - Public API (forwarded to the SwiftUI bridge)

- (void)addWaitingParticipant:(NSString *)identity displayName:(NSString *)displayName {
    [self.bridge addWaitingParticipant:identity displayName:displayName];
}

- (void)removeWaitingParticipant:(NSString *)identity {
    [self.bridge removeWaitingParticipant:identity];
}

- (void)clearWaitingList {
    [self.bridge clearWaitingList];
}

- (NSUInteger)waitingCount {
    return (NSUInteger)self.bridge.waitingCount;
}

- (void)setLobbyEnabled:(BOOL)lobbyEnabled {
    _lobbyEnabled = lobbyEnabled;
    self.bridge.lobbyEnabled = lobbyEnabled;
}

- (void)setLobbyToggleEnabled:(BOOL)enabled {
    [self.bridge setLobbyToggleEnabled:enabled];
}

@end
