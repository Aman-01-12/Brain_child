//
//  InterWindowSecurity.h
//  inter
//
//  Single source of truth for the window capture-protection policy. Every window that
//  must be excluded from screen capture/recording calls `[window setSharingType:
//  InterWindowSharingType()]` instead of hard-coding `NSWindowSharingNone`, so the policy
//  can be flipped in ONE place.
//
//  DEFAULT = fully protected (NSWindowSharingNone) — the secure/anti-capture behaviour.
//  It is ONLY relaxed (to NSWindowSharingReadOnly, i.e. screenshottable) when BOTH:
//    1. this is a DEBUG build (`#if DEBUG`), AND
//    2. the process is launched with `--disable-capture-protection`
//       OR the env var `INTER_DISABLE_CAPTURE_PROTECTION=1`.
//
//  This makes the relaxation impossible in a Release build and opt-in even in Debug, so it
//  can never ship insecure. Intended ONLY as a temporary dev affordance for capturing the
//  native UI during the SwiftUI migration — remove the flag usage once migration is done.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// YES only in a DEBUG build with the explicit dev flag/env set. NO otherwise.
BOOL InterCaptureProtectionDisabled(void);

/// The sharing type every protected window should use:
///   - `NSWindowSharingNone`     (default / always in Release) — excluded from capture.
///   - `NSWindowSharingReadOnly` (DEBUG + flag only)           — screenshottable for dev.
NSWindowSharingType InterWindowSharingType(void);

NS_ASSUME_NONNULL_END
