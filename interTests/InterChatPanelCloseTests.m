//
//  InterChatPanelCloseTests.m
//  interTests
//
//  Regression coverage for the in-call chat panel's header "X" close routing.
//
//  Bug (interview/secure mode): closing the chat with the in-window "X" left the
//  overlay window open but EMPTY on reopen. Root cause — the panel's header close
//  hard-coded `collapsePanel` (slide content off-screen). In normal call mode the
//  panel lives inside the call window and collapse is correct; in secure mode the
//  panel fills a floating overlay window whose visibility is the toggle, so the
//  panel must stay expanded and the WINDOW must hide instead. The fix routes the
//  header close through an optional delegate (`chatPanelDidRequestClose:`) and only
//  falls back to `collapsePanel` when the delegate doesn't handle it.
//
//  These tests assert that asymmetry directly:
//    • delegate opts in  → delegate is told; panel stays expanded (overlay model).
//    • delegate opts out → panel collapses itself (normal in-window model).
//
//  ObjC on purpose: InterChatPanel is AppKit and not bridged to Swift. The close
//  entry point (-handleHeaderCloseRequest) is internal to the .m; ObjC's dynamic
//  dispatch lets the test declare it via a category and invoke it without adding
//  any production-public API.
//

#import <XCTest/XCTest.h>
#import "../inter/UI/Views/InterChatPanel.h"

// Expose the internal header-close entry point (implemented in InterChatPanel.m)
// to the test without widening the public header.
@interface InterChatPanel (CloseTesting)
- (void)handleHeaderCloseRequest;
@end

// MARK: - Delegate that HANDLES close (overlay-window host, e.g. secure mode)

@interface InterChatCloseHandlingDelegate : NSObject <InterChatPanelDelegate>
@property (nonatomic, assign) NSInteger closeCount;
@end

@implementation InterChatCloseHandlingDelegate
- (void)chatPanelDidRequestClose:(InterChatPanel *)panel {
#pragma unused(panel)
    self.closeCount += 1;
}
@end

// MARK: - Delegate that does NOT handle close (normal in-window host)

@interface InterChatNonClosingDelegate : NSObject <InterChatPanelDelegate>
@end

@implementation InterChatNonClosingDelegate
// Intentionally implements no close method — exercises the collapse fallback.
@end

// MARK: - Tests

@interface InterChatPanelCloseTests : XCTestCase
@property (nonatomic, strong) InterChatPanel *panel;
@end

@implementation InterChatPanelCloseTests

- (void)setUp {
    [super setUp];
    self.panel = [[InterChatPanel alloc] initWithFrame:NSMakeRect(0, 0, 320, 600)];
    [self.panel expandPanel];
    XCTAssertTrue(self.panel.isExpanded, @"precondition: panel starts expanded");
}

- (void)tearDown {
    self.panel = nil;
    [super tearDown];
}

/// Secure/overlay model: a delegate that owns close is notified, and the panel
/// must NOT collapse — its content stays expanded so reopening the overlay window
/// shows the chat (the exact regression: an empty window on reopen).
- (void)testHeaderClose_whenDelegateHandlesIt_notifiesDelegateAndStaysExpanded {
    InterChatCloseHandlingDelegate *delegate = [[InterChatCloseHandlingDelegate alloc] init];
    self.panel.delegate = delegate;

    [self.panel handleHeaderCloseRequest];

    XCTAssertEqual(delegate.closeCount, 1,
                   @"delegate that implements chatPanelDidRequestClose: must own the close");
    XCTAssertTrue(self.panel.isExpanded,
                  @"overlay-hosted panel must stay expanded on close — collapsing it is what "
                  @"left the reopened overlay window empty");
}

/// Normal in-window model: no delegate close handler → the panel falls back to
/// collapsing itself (slide off-screen within the call window), unchanged behavior.
- (void)testHeaderClose_whenDelegateDoesNotHandleIt_collapsesPanel {
    InterChatNonClosingDelegate *delegate = [[InterChatNonClosingDelegate alloc] init];
    self.panel.delegate = delegate;

    [self.panel handleHeaderCloseRequest];

    XCTAssertFalse(self.panel.isExpanded,
                   @"with no delegate close handler the panel must collapse itself (normal mode)");
}

/// No delegate at all → safe fallback to collapse (no crash, no stuck-open panel).
- (void)testHeaderClose_withNoDelegate_collapsesPanel {
    self.panel.delegate = nil;

    [self.panel handleHeaderCloseRequest];

    XCTAssertFalse(self.panel.isExpanded, @"nil delegate must fall back to collapse");
}

@end
