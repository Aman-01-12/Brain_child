#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Overlay state for participant presence in the call.
typedef NS_ENUM(NSUInteger, InterParticipantOverlayState) {
    InterParticipantOverlayStateHidden = 0,     // No overlay
    InterParticipantOverlayStateWaiting,         // "Waiting for participant..." (pulsing dot)
    InterParticipantOverlayStateParticipantLeft  // "Participant left." with Wait/End buttons
};

@class InterParticipantOverlayView;

/// Delegate for overlay action buttons.
@protocol InterParticipantOverlayDelegate <NSObject>
@optional
/// User chose "Wait" after participant left.
- (void)overlayDidRequestWait:(InterParticipantOverlayView *)overlay;
/// User chose "End Call" after participant left.
- (void)overlayDidRequestEndCall:(InterParticipantOverlayView *)overlay;
@end

/// Centered overlay that shows participant waiting/left states.
///
/// Draws a semi-transparent background with centered text and optional action buttons.
/// The waiting state includes a pulsing green dot animation via a CABasicAnimation.
@interface InterParticipantOverlayView : NSView

@property (nonatomic, weak, nullable) id<InterParticipantOverlayDelegate> delegate;

/// Set the overlay state. InterParticipantOverlayStateHidden hides the view.
- (void)setOverlayState:(InterParticipantOverlayState)state;

@end

NS_ASSUME_NONNULL_END
