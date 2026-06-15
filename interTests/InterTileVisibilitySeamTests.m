//
//  InterTileVisibilitySeamTests.m
//  interTests
//
//  Verifies the layout→transport visibility seam (Phase 7.3.3 wiring):
//    • grid pagination emits diff-based visibility events,
//    • page navigation disables the old page and enables the new one,
//    • Finding #1 mitigation: switching to a non-grid presentation re-enables
//      participants a previous grid page had disabled (REMOVING the
//      reconcile-to-all call in applyCurrentLayoutAnimated: fails these),
//    • Finding #9 mitigation: a participant joining onto a hidden page gets a
//      one-shot disable instead of silently streaming at full rate,
//    • relay guards: the wiring controller drops invalid kinds/identities and
//      survives a nil room controller.
//
//  ObjC on purpose: InterRemoteVideoLayoutManager is not exposed to Swift
//  (no bridging into the test module); the test bundle links against the host
//  app, so importing the headers by relative path resolves the symbols.
//

#import <XCTest/XCTest.h>
#import <CoreVideo/CoreVideo.h>
#import "../inter/UI/Views/InterRemoteVideoLayoutManager.h"
#import "../inter/App/InterMediaWiringController.h"

// InterParticipantSnapshotEntry is a Swift @objc value type in the `inter`
// module. ObjC files in the test target cannot import the app's private
// generated `inter-Swift.h`, and a hand-written ObjC @interface cannot link to a
// Swift class (its runtime symbol is name-mangled). The snapshot path is the
// PRODUCTION source of truth for tile lifecycle, so these tests drive it via a
// tiny Swift bridge (SeamTestSupport) that builds the entries; we reach it
// through the test target's OWN generated interface header.
#import "interTests-Swift.h"

// ---------------------------------------------------------------------------
// Mock delegate — records every visibility/dimension event.
// ---------------------------------------------------------------------------

@interface InterVisibilitySeamRecorder : NSObject <InterRemoteVideoLayoutManagerDelegate>
/// "pid|1" / "pid|0" in arrival order.
@property (nonatomic, strong) NSMutableArray<NSString *> *visibilityEvents;
@property (nonatomic, strong) NSMutableArray<NSString *> *dimensionEvents;
@end

@implementation InterVisibilitySeamRecorder
- (instancetype)init {
    if ((self = [super init])) {
        _visibilityEvents = [NSMutableArray array];
        _dimensionEvents = [NSMutableArray array];
    }
    return self;
}
- (void)layoutManager:(InterRemoteVideoLayoutManager *)manager
  didChangeVisibility:(BOOL)visible
       forParticipant:(NSString *)participantId
               source:(NSUInteger)trackKind {
#pragma unused(manager, trackKind)
    [self.visibilityEvents addObject:[NSString stringWithFormat:@"%@|%d", participantId, visible ? 1 : 0]];
}
- (void)layoutManager:(InterRemoteVideoLayoutManager *)manager
 didRequestDimensions:(CGSize)dimensions
       forParticipant:(NSString *)participantId
               source:(NSUInteger)trackKind {
#pragma unused(manager, trackKind)
    [self.dimensionEvents addObject:[NSString stringWithFormat:@"%@|%.0fx%.0f",
                                     participantId, dimensions.width, dimensions.height]];
}
/// Latest visibility state per pid (nil = no event ever received).
- (NSNumber *)lastVisibilityFor:(NSString *)pid {
    for (NSString *event in self.visibilityEvents.reverseObjectEnumerator) {
        NSArray *parts = [event componentsSeparatedByString:@"|"];
        if ([parts.firstObject isEqualToString:pid]) {
            return @([parts.lastObject integerValue] == 1);
        }
    }
    return nil;
}
@end

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

static NSString *const kGridPrefKey = @"InterPreferGridLayout";

@interface InterTileVisibilitySeamTests : XCTestCase
@property (nonatomic, strong) InterRemoteVideoLayoutManager *layout;
@property (nonatomic, strong) InterVisibilitySeamRecorder *recorder;
@property (nonatomic, strong) id savedGridPref;
@end

@implementation InterTileVisibilitySeamTests

- (void)setUp {
    [super setUp];
    // gridLayoutEnabled persists to UserDefaults — save and restore so tests
    // never leak a layout preference into the developer's environment.
    self.savedGridPref = [[NSUserDefaults standardUserDefaults] objectForKey:kGridPrefKey];

    self.layout = [[InterRemoteVideoLayoutManager alloc] initWithFrame:NSMakeRect(0, 0, 1200, 800)];
    self.recorder = [[InterVisibilitySeamRecorder alloc] init];
    self.layout.layoutDelegate = self.recorder;
    self.layout.gridLayoutEnabled = YES;
    self.layout.maxTilesPerPage = 3; // tiny pages keep the tests light
}

- (void)tearDown {
    if (self.savedGridPref) {
        [[NSUserDefaults standardUserDefaults] setObject:self.savedGridPref forKey:kGridPrefKey];
    } else {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kGridPrefKey];
    }
    self.layout = nil;
    self.recorder = nil;
    [super tearDown];
}

// MARK: - Helpers

/// Feed one camera frame per participant and pump the runloop until the
/// layout manager has registered them all (first-frame registration is
/// dispatched to main). Synchronisation signal: every pid has produced at
/// least one visibility event (page members get enable; off-page pids get the
/// Finding-#9 one-shot disable).
- (void)joinParticipants:(NSArray<NSString *> *)pids {
    CVPixelBufferRef buffer = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, 16, 9, kCVPixelFormatType_32BGRA, NULL, &buffer);
    XCTAssertTrue(buffer != NULL, @"test pixel buffer must allocate");

    for (NSString *pid in pids) {
        [self.layout handleRemoteCameraFrame:buffer fromParticipant:pid];
    }

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    while ([deadline timeIntervalSinceNow] > 0) {
        BOOL allSeen = YES;
        for (NSString *pid in pids) {
            if ([self.recorder lastVisibilityFor:pid] == nil) { allSeen = NO; break; }
        }
        if (allSeen) break;
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    CVPixelBufferRelease(buffer);
}

- (NSArray<NSString *> *)pidsWithCount:(NSUInteger)count {
    NSMutableArray *pids = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        [pids addObject:[NSString stringWithFormat:@"seam-pid-%02lu", (unsigned long)i]];
    }
    return pids;
}

// MARK: - Pagination diffs

- (void)testFirstGridPageEnablesPageMembersOnly {
    NSArray<NSString *> *pids = [self pidsWithCount:4]; // page size 3 → 1 hidden
    [self joinParticipants:pids];

    for (NSUInteger i = 0; i < 3; i++) {
        XCTAssertEqualObjects([self.recorder lastVisibilityFor:pids[i]], @YES,
                              @"page-0 member %@ must be enabled", pids[i]);
    }
    // Finding #9: the off-page joiner must have an explicit one-shot disable —
    // without it the SFU keeps streaming an invisible participant at full rate.
    XCTAssertEqualObjects([self.recorder lastVisibilityFor:pids[3]], @NO,
                          @"participant joining onto a hidden page must be disabled");
}

- (void)testPageNavigationFlipsVisibilityByDiff {
    NSArray<NSString *> *pids = [self pidsWithCount:4];
    [self joinParticipants:pids];
    [self.recorder.visibilityEvents removeAllObjects];

    [self.layout nextGridPage]; // page 1 = pids[3] (+ no local self tile: no capture session)

    XCTAssertEqualObjects([self.recorder lastVisibilityFor:pids[0]], @NO);
    XCTAssertEqualObjects([self.recorder lastVisibilityFor:pids[1]], @NO);
    XCTAssertEqualObjects([self.recorder lastVisibilityFor:pids[2]], @NO);
    XCTAssertEqualObjects([self.recorder lastVisibilityFor:pids[3]], @YES);

    [self.recorder.visibilityEvents removeAllObjects];
    [self.layout previousGridPage]; // back to page 0

    XCTAssertEqualObjects([self.recorder lastVisibilityFor:pids[0]], @YES);
    XCTAssertEqualObjects([self.recorder lastVisibilityFor:pids[3]], @NO);
}

- (void)testRelayoutWithoutChangesEmitsNoEvents {
    NSArray<NSString *> *pids = [self pidsWithCount:4];
    [self joinParticipants:pids];
    [self.recorder.visibilityEvents removeAllObjects];

    // Same page, same participants — a redundant layout pass (resize etc.)
    // must not spam the SFU with enable/disable churn (Finding #3).
    [self.layout goToGridPage:0];

    XCTAssertEqual(self.recorder.visibilityEvents.count, 0u,
                   @"diff-based seam must stay silent when nothing changed");
}

// MARK: - Finding #1 mitigation (mode-switch stale disable)

- (void)testSwitchingToStageModeReenablesPagedOutParticipants {
    NSArray<NSString *> *pids = [self pidsWithCount:4];
    [self joinParticipants:pids];
    XCTAssertEqualObjects([self.recorder lastVisibilityFor:pids[3]], @NO,
                          @"precondition: pids[3] paged out and disabled");
    [self.recorder.visibilityEvents removeAllObjects];

    // Leaving the paginated grid renders ALL tiles (stage/filmstrip). The
    // paged-out participant MUST be re-enabled or their tile stays black.
    // This is the test that fails if reconcileVisibilityToAllCameraParticipants
    // is removed from applyCurrentLayoutAnimated:.
    self.layout.gridLayoutEnabled = NO;

    XCTAssertEqualObjects([self.recorder lastVisibilityFor:pids[3]], @YES,
                          @"mode switch must re-enable previously paged-out participants");
    // And the still-visible ones must not get redundant events.
    XCTAssertNil([self.recorder lastVisibilityFor:pids[0]],
                 @"already-visible participants produce no event on mode switch");
}

- (void)testCompactPreviewModeAlsoReenables {
    NSArray<NSString *> *pids = [self pidsWithCount:4];
    [self joinParticipants:pids];
    XCTAssertEqualObjects([self.recorder lastVisibilityFor:pids[3]], @NO);
    [self.recorder.visibilityEvents removeAllObjects];

    self.layout.compactPreviewMode = YES; // secure-mode compact spotlight path

    XCTAssertEqualObjects([self.recorder lastVisibilityFor:pids[3]], @YES,
                          @"compact preview renders the spotlight from all tiles — nothing may stay disabled");
}

// MARK: - Finding #9 one-shot does not repeat

- (void)testHiddenJoinerDisableIsOneShot {
    NSArray<NSString *> *pids = [self pidsWithCount:4];
    [self joinParticipants:pids];
    [self.recorder.visibilityEvents removeAllObjects];

    // Redundant layout passes must not re-emit the one-shot disable.
    [self.layout goToGridPage:0];
    [self.layout goToGridPage:0];

    XCTAssertEqual(self.recorder.visibilityEvents.count, 0u,
                   @"one-shot disable for hidden joiners must not repeat");
}

// MARK: - Quality hints flow

- (void)testGridEmitsDimensionHints {
    NSArray<NSString *> *pids = [self pidsWithCount:2]; // single page, no pagination
    [self joinParticipants:pids];

    XCTAssertGreaterThan(self.recorder.dimensionEvents.count, 0u,
                         @"layout passes must emit preferred-dimension hints for simulcast selection");
}

// MARK: - Relay guards (wiring controller)

- (void)testRelaySurvivesNilRoomControllerAndDropsInvalidInput {
    InterMediaWiringController *wiring = [[InterMediaWiringController alloc] init];
    InterRemoteVideoLayoutManager *layout = self.layout;

    // No room controller wired — every relay call must be a safe no-op.
    id<InterRemoteVideoLayoutManagerDelegate> relay = (id<InterRemoteVideoLayoutManagerDelegate>)wiring;
    XCTAssertNoThrow([relay layoutManager:layout didChangeVisibility:NO
                           forParticipant:@"pid" source:0 /* camera */]);
    XCTAssertNoThrow([relay layoutManager:layout didChangeVisibility:YES
                           forParticipant:@"" source:0],
                     @"empty identity dropped");
    XCTAssertNoThrow([relay layoutManager:layout didChangeVisibility:NO
                           forParticipant:@"pid" source:1 /* microphone — invalid kind */]);
    XCTAssertNoThrow([relay layoutManager:layout didRequestDimensions:CGSizeMake(-10, 0)
                           forParticipant:@"pid" source:0],
                     @"non-positive dimensions dropped");
    XCTAssertNoThrow([relay layoutManager:layout didRequestDimensions:CGSizeMake(640, 360)
                           forParticipant:@"pid" source:99 /* unknown kind */]);
}

/// The wiring controller must self-assign as the layout's delegate the moment
/// the layout is wired — this assignment WAS the missing link that left the
/// whole seam dead in production.
- (void)testWiringControllerSelfAssignsAsLayoutDelegate {
    InterMediaWiringController *wiring = [[InterMediaWiringController alloc] init];
    InterRemoteVideoLayoutManager *layout =
        [[InterRemoteVideoLayoutManager alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];

    wiring.remoteLayout = layout;

    XCTAssertEqual((id)layout.layoutDelegate, (id)wiring,
                   @"setRemoteLayout: must wire the visibility/quality relay");
}

// MARK: - Snapshot-driven seam (Finding #1: production path coverage)

/// Build a roster snapshot of N remote, camera-on participants in pid order.
/// Delegates to the Swift SeamTestSupport bridge (see that file for why).
- (NSArray<InterParticipantSnapshotEntry *> *)snapshotEntriesForPids:(NSArray<NSString *> *)pids {
    return [SeamTestSupport snapshotEntriesForPids:pids];
}

/// Finding #1 regression guard: the PRODUCTION tile-lifecycle path is
/// applyParticipantSnapshot:, not handleRemoteCameraFrame:. Driving the seam
/// through the snapshot reconciler proves visibility management stays wired if
/// the reconciler is later refactored (e.g. reordering cameraParticipantOrder
/// population). The reconciler ends in a synchronous updateLayoutAnimated:NO,
/// so visibility events are emitted before this method returns — no runloop pump.
- (void)testSnapshotDrivenJoinEnablesPageMembersOnly {
    NSArray<NSString *> *pids = [self pidsWithCount:4]; // page size 3 → 1 hidden

    [self.layout applyParticipantSnapshot:[self snapshotEntriesForPids:pids]];

    for (NSUInteger i = 0; i < 3; i++) {
        XCTAssertEqualObjects([self.recorder lastVisibilityFor:pids[i]], @YES,
                              @"snapshot page-0 member %@ must be enabled", pids[i]);
    }
    // Off-page joiner from the snapshot must be explicitly disabled (Finding #9),
    // exactly as the legacy frame path does — proving the seam is fed by the
    // reconciler, not only by handleRemoteCameraFrame:.
    XCTAssertEqualObjects([self.recorder lastVisibilityFor:pids[3]], @NO,
                          @"snapshot participant on a hidden page must be disabled");
}

/// Finding #1 mitigation through the production path: a snapshot-driven grid
/// that paged someone out, then a mode switch to stage, must re-enable them.
/// This fails if reconcileVisibilityToAllCameraParticipants is removed from
/// applyCurrentLayoutAnimated: — the same guard as the frame-path test, but
/// exercised end-to-end through applyParticipantSnapshot:.
- (void)testSnapshotDrivenModeSwitchReenablesPagedOutParticipants {
    NSArray<NSString *> *pids = [self pidsWithCount:4];
    [self.layout applyParticipantSnapshot:[self snapshotEntriesForPids:pids]];
    XCTAssertEqualObjects([self.recorder lastVisibilityFor:pids[3]], @NO,
                          @"precondition: pids[3] paged out and disabled via snapshot");
    [self.recorder.visibilityEvents removeAllObjects];

    self.layout.gridLayoutEnabled = NO; // leave grid → stage renders ALL tiles

    XCTAssertEqualObjects([self.recorder lastVisibilityFor:pids[3]], @YES,
                          @"mode switch must re-enable the snapshot-paged-out participant");
}

@end
