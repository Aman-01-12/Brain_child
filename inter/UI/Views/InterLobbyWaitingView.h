#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class InterLobbyWaitingView;

/// Delegate for lobby waiting view events.
@protocol InterLobbyWaitingViewDelegate <NSObject>
@optional
/// User cancelled waiting and wants to leave the lobby.
- (void)lobbyWaitingViewDidCancel:(InterLobbyWaitingView *)view;
@end

/// Participant-side waiting room view.
/// Shown when the host has lobby enabled. Displays a message with position,
/// a spinner, and a cancel button. Polls the server for admission status.
@interface InterLobbyWaitingView : NSView

@property (nonatomic, weak, nullable) id<InterLobbyWaitingViewDelegate> delegate;

/// Update the position in queue text. Pass 0 to hide position.
- (void)setPosition:(NSInteger)position;

/// Update the status message (e.g. "The host will let you in shortly").
- (void)setStatusMessage:(NSString *)message;

/// Transition to "denied" state — show denial message and stop spinner.
- (void)showDenied;

/// Transition to "admitted" state — show brief success before connecting.
- (void)showAdmitted;

@end

NS_ASSUME_NONNULL_END
