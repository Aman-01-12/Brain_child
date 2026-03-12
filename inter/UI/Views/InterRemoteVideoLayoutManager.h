#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class InterParticipantOverlayView;

/// Layout mode for remote video views based on which remote tracks are active.
///
/// Google-Meet / Zoom-style layout:
///   - CamerasOnly: equal-sized grid (1→fill, 2→side-by-side, 3+→2-col grid).
///   - ScreenSharePresent: main stage (≈75 %) shows the spotlighted feed
///     (screen share by default). A right-side filmstrip (≈25 %) shows
///     all other feeds as scrollable tiles. Any tile can be clicked to
///     swap into the main stage ("spotlight").
typedef NS_ENUM(NSUInteger, InterRemoteVideoLayoutMode) {
    InterRemoteVideoLayoutModeNone = 0,           // No remote tracks — local preview only
    InterRemoteVideoLayoutModeSingleCamera,        // 1 remote camera fills the area
    InterRemoteVideoLayoutModeMultiCamera,         // 2+ remote cameras in equal grid
    InterRemoteVideoLayoutModeScreenShareOnly,     // Remote screen share fills center
    InterRemoteVideoLayoutModeScreenShareWithCameras // Main stage + filmstrip sidebar
};

/// Manages the layout and frame routing for N remote video views.
///
/// Dynamically creates / removes InterRemoteVideoView instances per
/// participant identity.  Routes incoming frames and animates layout
/// transitions between modes (300 ms ease-in-out).
///
/// **Grid layout** (cameras only):
///   1 camera  → fills the entire area
///   2 cameras → side-by-side (each 50 % width)
///   3+        → 2-column grid, rows grow as needed
///
/// **Stage + filmstrip** (screen share active or user-spotlighted):
///   Main stage (left 75 %) shows the spotlighted view (screen share
///   by default). All other feeds are stacked in a right filmstrip
///   (25 %, 8 px gap, rounded corners, name labels). Clicking any
///   filmstrip tile makes it the spotlight and moves the previous
///   spotlight into the filmstrip.
///
/// The overlay sub-view handles "waiting" / "participant left" states.
@interface InterRemoteVideoLayoutManager : NSView

/// Current layout mode (read-only, changes automatically).
@property (nonatomic, readonly) InterRemoteVideoLayoutMode layoutMode;

/// The participant overlay view for waiting/left states.
@property (nonatomic, strong, readonly) InterParticipantOverlayView *participantOverlay;

/// Number of remote camera feeds currently displayed.
@property (nonatomic, readonly) NSUInteger remoteCameraCount;

/// Call when a remote camera frame arrives from a participant.
- (void)handleRemoteCameraFrame:(CVPixelBufferRef)pixelBuffer fromParticipant:(NSString *)participantId;

/// Call when a remote screen share frame arrives from a participant.
- (void)handleRemoteScreenShareFrame:(CVPixelBufferRef)pixelBuffer fromParticipant:(NSString *)participantId;

/// Call when a remote track mutes.
- (void)handleRemoteTrackMuted:(NSUInteger)trackKind forParticipant:(NSString *)participantId;

/// Call when a remote track unmutes.
- (void)handleRemoteTrackUnmuted:(NSUInteger)trackKind forParticipant:(NSString *)participantId;

/// Call when a remote track ends completely.
- (void)handleRemoteTrackEnded:(NSUInteger)trackKind forParticipant:(NSString *)participantId;

/// Programmatically spotlight a specific feed.
/// @param tileKey The tile key to spotlight. Screen share tile key is @"__screenshare__".
///                Camera tile keys are the participant identity string.
- (void)spotlightTile:(NSString *)tileKey;

/// Tear down and remove all remote views. Call on mode exit.
- (void)teardown;

@end

NS_ASSUME_NONNULL_END
