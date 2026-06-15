// ============================================================================
// SeamTestSupport.swift
// interTests
//
// Test-only bridge that lets the Objective-C visibility-seam tests
// (InterTileVisibilitySeamTests.m) build production roster snapshots.
//
// Why this exists: InterParticipantSnapshotEntry is a Swift @objc class in the
// `inter` module. ObjC files in the test target cannot import the app's private
// generated `inter-Swift.h`, and a hand-written ObjC @interface cannot link to a
// Swift class (its runtime symbol is name-mangled, hidden behind the SWIFT_CLASS
// macro in the generated header). Swift here builds the entries directly and
// hands them back as an NSArray, which the ObjC tests reach through the test
// target's own generated `interTests-Swift.h`.
// ============================================================================

import Foundation
@testable import inter

@objc public final class SeamTestSupport: NSObject {
    /// Build a roster snapshot of N remote, camera-on participants in pid order.
    /// Mirrors what InterParticipantRoster emits in production for joined,
    /// camera-on remotes.
    ///
    /// Returns a plain `NSArray` on purpose: InterParticipantSnapshotEntry is only
    /// reachable here through `@testable import inter`, so naming it in the @objc
    /// signature would make Swift drop this whole class from the generated
    /// `interTests-Swift.h` (it cannot express a testable-only type in the header).
    /// The element type stays internal to the implementation; ObjC receives the
    /// array and passes it straight into `-applyParticipantSnapshot:`.
    @objc public static func snapshotEntries(forPids pids: [String]) -> NSArray {
        let entries = pids.map { pid in
            InterParticipantSnapshotEntry(identity: pid,
                                          displayName: pid,
                                          isLocal: false,
                                          cameraOn: true,
                                          micMuted: false,
                                          handRaised: false,
                                          isSpeaking: false,
                                          isScreenSharing: false)
        }
        return entries as NSArray
    }

    // ------------------------------------------------------------------------
    // B5 secure-wiring seam support.
    //
    // The SecureWindowControllerSeamTests.m seam needs (1) a real
    // InterRoomController to assign to `SecureWindowController.roomController`
    // (so `wireSecureRemoteRendering` reaches `rc.subscriber`), and (2) the
    // InterLiveKitSubscriber class object so it can swizzle `reseedPresence`
    // and count invocations on the controller-owned subscriber instance
    // (the `subscriber` property is a `let`, so it cannot be replaced with a
    // spy — counting at the class level via swizzle is the seam).
    //
    // Both are returned as generic ObjC types (NSObject / AnyClass) for the
    // same reason `snapshotEntries(forPids:)` returns NSArray: naming the
    // `@testable import inter` types in an @objc signature would force Swift to
    // drop this class from the generated `interTests-Swift.h` (ObjC test files
    // cannot import the app's private generated Swift header).
    // ------------------------------------------------------------------------

    /// Construct a fresh InterRoomController for the secure-wiring seam.
    /// Returned as NSObject (see note above). The room controller starts
    /// `.disconnected`, so `wireSecureRemoteRendering`'s connected/alone overlay
    /// branch never fires — the only observable effect is the subscriber wiring.
    @objc public static func makeRoomController() -> NSObject {
        return InterRoomController()
    }

    /// The InterLiveKitSubscriber class object, so the ObjC seam can swizzle
    /// `reseedPresence` to count calls made by `wireSecureRemoteRendering`.
    @objc public static func subscriberClass() -> AnyClass {
        return InterLiveKitSubscriber.self
    }
}
