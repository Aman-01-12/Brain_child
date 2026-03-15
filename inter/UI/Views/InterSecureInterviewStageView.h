#import <Cocoa/Cocoa.h>

#import "InterInterviewToolTypes.h"
#import "InterTrackRendererBridge.h"

NS_ASSUME_NONNULL_BEGIN

@class InterRemoteVideoLayoutManager;
@class InterSecureToolHostView;

/// Secure interview-specific stage system.
///
/// Responsibilities:
/// - Keep remote media and secure tool presentation separate from the published
///   capture boundary.
/// - Allow the local center stage to swap between remote feeds and the secure
///   tool without resizing the authoritative capture host.
/// - Own the dedicated secure right rail used for local-only remote previews
///   and tool previews. Secure interview mode does not use the normal remote
///   layout manager's internal filmstrip.
/// - Expose the remote layout manager and authoritative capture host so the
///   surrounding controller can keep existing networking and capture plumbing.
@interface InterSecureInterviewStageView : NSView <InterTrackRendererPreviewObserver>

/// Remote media renderer used only for local presentation.
@property (nonatomic, strong, readonly) InterRemoteVideoLayoutManager *remoteLayoutManager;

/// Authoritative tool host captured by the secure share pipeline.
/// This view keeps a stable workspace-sized frame even when the local UI is
/// currently spotlighting remote media instead.
@property (nonatomic, strong, readonly) InterSecureToolHostView *toolCaptureHostView;

/// Currently selected interview tool.
@property (nonatomic, assign, readonly) InterInterviewToolKind activeToolKind;

/// Whether secure tool sharing is active.
@property (nonatomic, assign, getter=isSecureShareActive) BOOL secureShareActive;

/// Update which tool should be rendered by the authoritative capture host.
- (void)setActiveToolKind:(InterInterviewToolKind)toolKind;

/// Bring the active tool back to the center stage if it is currently visible.
- (void)focusActiveToolIfVisible;

@end

NS_ASSUME_NONNULL_END
