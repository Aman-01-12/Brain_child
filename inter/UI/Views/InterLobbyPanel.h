#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class InterLobbyPanel;

/// Delegate protocol for lobby panel actions (host-side).
@protocol InterLobbyPanelDelegate <NSObject>
@optional
/// Host tapped Admit for a waiting participant.
- (void)lobbyPanel:(InterLobbyPanel *)panel didAdmitParticipant:(NSString *)identity displayName:(NSString *)displayName;
/// Host tapped Deny for a waiting participant.
- (void)lobbyPanel:(InterLobbyPanel *)panel didDenyParticipant:(NSString *)identity;
/// Host tapped Admit All.
- (void)lobbyPanelDidAdmitAll:(InterLobbyPanel *)panel;
/// Host toggled the lobby on/off.
- (void)lobbyPanel:(InterLobbyPanel *)panel didToggleLobbyEnabled:(BOOL)enabled;
@end

/// Host-side lobby management panel.
/// Shows waiting participants with admit/deny buttons.
@interface InterLobbyPanel : NSView

@property (nonatomic, weak, nullable) id<InterLobbyPanelDelegate> delegate;

/// Add a participant to the waiting list.
- (void)addWaitingParticipant:(NSString *)identity displayName:(NSString *)displayName;

/// Remove a participant from the waiting list (admitted or denied).
- (void)removeWaitingParticipant:(NSString *)identity;

/// Clear all waiting participants.
- (void)clearWaitingList;

/// Number of participants currently waiting.
@property (nonatomic, readonly) NSUInteger waitingCount;

/// Whether the lobby toggle is enabled.
@property (nonatomic, assign) BOOL lobbyEnabled;

@end

NS_ASSUME_NONNULL_END
