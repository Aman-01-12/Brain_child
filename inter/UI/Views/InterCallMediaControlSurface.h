//
//  InterCallMediaControlSurface.h
//  inter
//
//  The media-state surface InterMediaWiringController drives. Both in-call
//  control surfaces conform:
//    • InterLocalCallControlPanel (AppKit) — secure/candidate window.
//    • InterCallControlBarBridge (SwiftUI bar) — normal window.
//  Extracting the protocol lets the wiring controller stay agnostic while the
//  normal window migrates to the SwiftUI bottom bar.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol InterCallMediaControlSurface <NSObject>

- (void)setCameraEnabled:(BOOL)enabled;
- (void)setCameraInteractive:(BOOL)interactive;
- (void)setCameraButtonTitle:(nullable NSString *)title;
- (void)setMicrophoneEnabled:(BOOL)enabled;
- (void)setMicrophoneButtonTitle:(nullable NSString *)title;
- (void)setMediaStatusText:(NSString *)text;
- (void)setConnectionStatusText:(NSString *)text;

@optional
/// Update the network-quality indicator (signal bars) on the control surface.
/// The normal-mode SwiftUI bar renders this beside the room code; the AppKit
/// panel (secure window) uses a separate InterNetworkStatusView and does not
/// implement this. `level` is an InterNetworkQualityLevel raw value (0–4).
- (void)setNetworkQualityLevel:(NSInteger)level;

@end

NS_ASSUME_NONNULL_END
