#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class InterRecordingConsentPanel;

/// Delegate protocol for handling consent responses.
@protocol InterRecordingConsentPanelDelegate <NSObject>
@optional
/// User accepted the recording consent.
- (void)recordingConsentPanelDidAccept:(InterRecordingConsentPanel *)panel;
/// User declined the recording consent (will leave the meeting).
- (void)recordingConsentPanelDidDecline:(InterRecordingConsentPanel *)panel;
@end

/// Consent notification panel shown to new joiners when
/// a recording is in progress. Displayed as a modal-style
/// overlay requiring the participant to accept or leave.
///
/// Per §12 of recording_architecture.md — consent is required
/// when a participant joins a room where recording is active.
@interface InterRecordingConsentPanel : NSView

@property (nonatomic, weak, nullable) id<InterRecordingConsentPanelDelegate> delegate;

/// Show the consent panel with the recording mode description.
/// - Parameter mode: "local_composed", "cloud_composed", or "multi_track".
- (void)showConsentForMode:(NSString *)mode;

/// Dismiss the panel (after accept or decline).
- (void)dismiss;

@end

NS_ASSUME_NONNULL_END
