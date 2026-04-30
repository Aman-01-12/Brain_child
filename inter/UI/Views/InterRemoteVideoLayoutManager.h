#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@class InterParticipantOverlayView;
@class InterRemoteVideoLayoutManager;

/// Delegate protocol for layout manager to request track visibility/quality changes. [Phase 7]
/// Implemented by the media wiring controller to relay to InterLiveKitSubscriber.
@protocol InterRemoteVideoLayoutManagerDelegate <NSObject>
@optional
/// Called when a tile's visibility changes (e.g. paged in/out of grid).
- (void)layoutManager:(InterRemoteVideoLayoutManager *)manager
    didChangeVisibility:(BOOL)visible
       forParticipant:(NSString *)participantId
               source:(NSUInteger)trackKind;

/// Called when the layout requests a different video quality for a participant.
/// Dimensions represent the desired render size (e.g. 320×180 for filmstrip, 1280×720 for stage).
- (void)layoutManager:(InterRemoteVideoLayoutManager *)manager
    didRequestDimensions:(CGSize)dimensions
       forParticipant:(NSString *)participantId
               source:(NSUInteger)trackKind;
@end

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

/// Delegate for track visibility/quality change notifications. [Phase 7]
@property (nonatomic, weak, nullable) id<InterRemoteVideoLayoutManagerDelegate> layoutDelegate;

/// Current layout mode (read-only, changes automatically).
@property (nonatomic, readonly) InterRemoteVideoLayoutMode layoutMode;

/// The participant overlay view for waiting/left states.
@property (nonatomic, strong, readonly) InterParticipantOverlayView *participantOverlay;

/// Number of remote camera feeds currently displayed.
@property (nonatomic, readonly) NSUInteger remoteCameraCount;

/// Identity of the current dominant/active speaker. Empty string means none.
/// Set by InterMediaWiringController via KVO on InterRoomController.
/// Tiles for the active speaker get a green highlight border.
@property (nonatomic, copy) NSString *activeSpeakerIdentity;

/// Total remote participant count (including those who may not have published video yet).
/// Used for participant count badge and overlay messaging.
@property (nonatomic, assign) NSUInteger remoteParticipantCount;

// MARK: — Phase 7: Pagination (Grid Mode)

/// Current page index in paginated grid mode (0-based). Read-only.
@property (nonatomic, readonly) NSUInteger currentGridPage;

/// Total number of pages in paginated grid mode. Read-only.
@property (nonatomic, readonly) NSUInteger totalGridPages;

/// Maximum tiles per grid page before pagination kicks in. Default 25 (5×5).
@property (nonatomic, assign) NSUInteger maxTilesPerPage;

/// Navigate to the next grid page (wraps to first if at end).
- (void)nextGridPage;

/// Navigate to the previous grid page (wraps to last if at start).
- (void)previousGridPage;

/// Navigate to a specific grid page (clamped to valid range).
- (void)goToGridPage:(NSUInteger)page;

/// Optional callback fired when the user manually selects or clears a spotlight tile.
/// This is intended for container-level UI reactions outside the layout manager itself,
/// such as secure-mode expansion of the local-only remote preview area.
/// A nil tile key means the layout manager returned to automatic spotlight behavior.
@property (nonatomic, copy, nullable) void (^spotlightSelectionChangedHandler)(NSString * _Nullable tileKey);

/// Enables click-to-spotlight behavior for tiles. Normal call layouts can keep
/// this on; secure interview mode turns it off so remote feeds are positioned
/// only by secure share state, never by local tile clicks.
@property (nonatomic, assign) BOOL allowsManualSpotlightSelection;

/// Forces multi-camera remote feeds into the stage + filmstrip presentation
/// instead of the equal-sized grid. Secure interview mode uses this so remote
/// feeds keep a stable "selected feed in center" model even without a remote
/// screen-share track.
@property (nonatomic, assign) BOOL preferStageLayoutForMultipleCameras;

/// When YES, all remote cameras (plus the local self-view) are shown in an
/// equal-size grid. When NO, uses stage+filmstrip. Only applies to multi-camera
/// situations — screen share always takes the main stage regardless.
/// Initialised from and persisted to NSUserDefaults key "InterPreferGridLayout".
@property (nonatomic, assign) BOOL gridLayoutEnabled;

/// The local camera capture session used to render a self-view tile in grid mode.
/// Set by the caller (AppDelegate) once the capture session is running.
@property (nonatomic, strong, nullable) AVCaptureSession *localCaptureSession;

/// Collapses the layout into a single spotlighted remote tile that fills the
/// available bounds, hiding the internal filmstrip. Secure interview mode uses
/// this when the local secure tool already owns the primary center stage and
/// remote media is shown only as a compact side preview.
@property (nonatomic, assign) BOOL compactPreviewMode;

/// Optional external preview view inserted into the filmstrip column when the
/// container wants to treat a non-remote candidate as part of the same stage
/// system. Secure interview mode uses this for the local tool preview so it
/// shares the same rail as remote camera/screen-share candidates.
@property (nonatomic, strong, nullable) NSView *supplementalFilmstripView;

/// Callback fired after the layout manager re-evaluates its layout state.
/// Secure interview mode uses this to react when remote content changes from a
/// single tile to stage+filmstrip or back.
@property (nonatomic, copy, nullable) dispatch_block_t layoutStateChangedHandler;

/// When YES and in stage+filmstrip mode, automatically promotes the active speaker
/// to the main stage spotlight. Resets to the previous tile 3 seconds after the speaker
/// stops (or a new speaker takes over). Default is NO. [Phase 7.4.2]
@property (nonatomic, assign) BOOL autoSpotlightActiveSpeaker;

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

/// Register a human-readable display name for a participant identity.
/// Once registered, tiles for this participant show the display name
/// instead of the raw identity string (UUID).
- (void)registerDisplayName:(NSString *)displayName forParticipant:(NSString *)participantId;

/// Look up the registered display name for a tile key.
/// Returns the registered display name, or the raw tile key if none was registered.
- (NSString *)displayNameForTileKey:(NSString *)tileKey;

/// [Phase 8.2.3] Show or hide the raised-hand badge (✋) on a participant's tile.
- (void)setHandRaised:(BOOL)raised forParticipant:(NSString *)participantId;

/// Programmatically spotlight a specific feed.
/// @param tileKey The tile key to spotlight. Screen share tile key is @"__screenshare__".
///                Camera tile keys are the participant identity string.
- (void)spotlightTile:(NSString *)tileKey;

/// Set the spotlight selection directly without toggle semantics.
/// Passing nil returns the layout manager to automatic spotlight behavior.
- (void)setManualSpotlightTileKey:(NSString * _Nullable)tileKey animated:(BOOL)animated;

/// Tear down and remove all remote views. Call on mode exit.
- (void)teardown;

@end

NS_ASSUME_NONNULL_END
