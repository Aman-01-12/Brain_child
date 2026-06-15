//
//  interTests-Bridging-Header.h
//  interTests
//
//  Bridging header for the test target's Swift test code.
//
//  Some production types are Objective-C only (e.g. the stable captured host
//  `InterSecureToolHostView` and the `InterInterviewToolKind` enum). The test
//  bundle links against the host app, so their symbols resolve at link time,
//  but Swift needs their declarations at compile time. Importing the ObjC
//  headers here (by relative path, exactly as the ObjC test files do) exposes
//  those types to `@testable import inter` Swift test cases without widening any
//  production-public API.
//

#import "../inter/UI/Views/InterSecureToolHostView.h"
// [B6] Expose `InterPreviewShouldIngest` (declared in the stage view header) to
// the Swift test target. Pulling in AppKit via this header is fine — the
// bridging header already imports an AppKit NSView header above.
#import "../inter/UI/Views/InterSecureInterviewStageView.h"
