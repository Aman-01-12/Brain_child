//
//  SecureWindowControllerSeamTests.m
//  interTests
//
//  B5 bug-condition exploration seam (Property 9, Requirements 1.14–1.16 /
//  2.12–2.13). Confirms the missing-host-tile defect on the kiosk secure path.
//
//  Bug B5: SecureWindowController.wireSecureRemoteRendering assigns
//  `rc.subscriber.trackRenderer` but — unlike AppDelegate.wireNormalRemoteRendering
//  (`[rc.subscriber reseedPresence]`, AppDelegate.m ~line 3346) — never calls
//  `[rc.subscriber reseedPresence]`. So a host already present in the room when
//  the candidate joins via the kiosk is never seeded into the roster:
//    • `subscriber.attach` ran pre-connect with empty `remoteParticipants`,
//    • LiveKit fires no `participantDidConnect` for a pre-existing participant,
//    • `trackRenderer` `didSet` only `resync()`s an already-empty roster.
//  → No host tile (worst when the host's camera is off and no frame ever seeds it).
//
//  This is the EXPLORATION test: it asserts the DESIRED (fixed) behavior —
//  `reseedPresence` is invoked exactly once after `trackRenderer` is assigned.
//  On UNFIXED code that call is absent, so the assertion FAILS (call count == 0),
//  which CONFIRMS the bug. After the fix lands (task 3) this same test passes.
//
//  Seam style mirrors InterTileVisibilitySeamTests.m: ObjC on purpose because
//  SecureWindowController is ObjC and `-wireSecureRemoteRendering` is internal
//  to the .m (exercised here via a test category, no production-public widening).
//
//  How the call is counted: `InterRoomController.subscriber` is a `let`, so it
//  cannot be replaced with a spy subscriber. Instead we swizzle
//  `-[InterLiveKitSubscriber reseedPresence]` to bump a counter and then call
//  through to the original — counting any invocation on the controller-owned
//  subscriber instance. The subscriber class object and a fresh room controller
//  are vended by the Swift SeamTestSupport bridge (see that file for why ObjC
//  cannot name those `@testable import inter` types directly).
//

#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import "../../inter/UI/Controllers/SecureWindowController.h"
#import "../../inter/UI/Views/InterRemoteVideoLayoutManager.h"
#import "interTests-Swift.h"

// ---------------------------------------------------------------------------
// Expose the internal secure-wiring entry point + the private collaborators it
// reads, without widening SecureWindowController's public header.
// `roomController` is already public (weak); `remoteLayout`/`stageView` live in
// the .m class extension — redeclaring them in a category lets the test seed
// them (their synthesized accessors resolve at runtime against the host app).
// ---------------------------------------------------------------------------
@interface SecureWindowController (SeamTesting)
@property (nonatomic, strong, nullable) InterRemoteVideoLayoutManager *remoteLayout;
- (void)wireSecureRemoteRendering;
@end

// ---------------------------------------------------------------------------
// reseedPresence call counter + swizzle host.
// ---------------------------------------------------------------------------
static NSInteger gReseedPresenceCallCount = 0;

@interface InterReseedPresenceSpy : NSObject
@end

@implementation InterReseedPresenceSpy
/// After method_exchangeImplementations, this selector carries the ORIGINAL
/// `reseedPresence` IMP, so the recursive-looking call dispatches to it.
- (void)seam_countedReseedPresence {
    gReseedPresenceCallCount += 1;
    [self seam_countedReseedPresence];
}
@end

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@interface SecureWindowControllerSeamTests : XCTestCase
@property (nonatomic, strong) SecureWindowController *controller;
@property (nonatomic, strong) InterRemoteVideoLayoutManager *layout;
/// Strong ref to the room controller — SecureWindowController.roomController is
/// `weak`, so the test must own it for the duration of the wiring call.
@property (nonatomic, strong) NSObject *roomControllerRef;
@property (nonatomic, assign) BOOL didSwizzle;
@end

@implementation SecureWindowControllerSeamTests

- (void)setUp {
    [super setUp];
    gReseedPresenceCallCount = 0;
    [self installReseedPresenceSpy];

    self.controller = [[SecureWindowController alloc] init];
    self.layout = [[InterRemoteVideoLayoutManager alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    self.controller.remoteLayout = self.layout;

    self.roomControllerRef = [SeamTestSupport makeRoomController];
    XCTAssertNotNil(self.roomControllerRef, @"SeamTestSupport must vend a room controller");
    // roomController is forward-declared (@class InterRoomController); the bridge
    // returns it as NSObject. Cast through id to assign without a type warning.
    self.controller.roomController = (id)self.roomControllerRef;
}

- (void)tearDown {
    [self removeReseedPresenceSpy];
    self.controller = nil;
    self.layout = nil;
    self.roomControllerRef = nil;
    [super tearDown];
}

// MARK: - Swizzle plumbing

- (void)installReseedPresenceSpy {
    Class subscriberClass = [SeamTestSupport subscriberClass];
    XCTAssertNotNil(subscriberClass, @"SeamTestSupport must vend the InterLiveKitSubscriber class");

    Method original = class_getInstanceMethod(subscriberClass, @selector(reseedPresence));
    XCTAssertTrue(original != NULL, @"InterLiveKitSubscriber must declare reseedPresence");

    Method spy = class_getInstanceMethod([InterReseedPresenceSpy class], @selector(seam_countedReseedPresence));
    class_addMethod(subscriberClass, @selector(seam_countedReseedPresence),
                    method_getImplementation(spy), method_getTypeEncoding(spy));
    Method added = class_getInstanceMethod(subscriberClass, @selector(seam_countedReseedPresence));
    method_exchangeImplementations(original, added);
    self.didSwizzle = YES;
}

- (void)removeReseedPresenceSpy {
    if (!self.didSwizzle) { return; }
    Class subscriberClass = [SeamTestSupport subscriberClass];
    Method original = class_getInstanceMethod(subscriberClass, @selector(reseedPresence));
    Method added = class_getInstanceMethod(subscriberClass, @selector(seam_countedReseedPresence));
    // Re-exchange restores the original IMP mapping.
    method_exchangeImplementations(original, added);
    self.didSwizzle = NO;
}

// MARK: - B5 exploration

/// DESIRED (fixed) behavior: `-wireSecureRemoteRendering` must seed the roster
/// for participants already present at connect — i.e. call `[subscriber
/// reseedPresence]` exactly once after assigning `trackRenderer` (parity with
/// `wireNormalRemoteRendering`). On UNFIXED code the call is absent → this FAILS
/// with call count == 0, confirming bug B5 (1.14–1.16): a pre-existing host is
/// never seeded into the roster, so no host tile appears.
- (void)testWireSecureRemoteRenderingReseedsPresenceForPreExistingHost {
    [self.controller wireSecureRemoteRendering];

    XCTAssertEqual(gReseedPresenceCallCount, 1,
                   @"[B5] wireSecureRemoteRendering must call [subscriber reseedPresence] "
                   @"exactly once after wiring trackRenderer, so a host already present when "
                   @"the candidate joins via the kiosk is seeded into the roster and gets a "
                   @"tile. UNFIXED: count == 0 (no reseed) → host tile never appears.");
}

@end
