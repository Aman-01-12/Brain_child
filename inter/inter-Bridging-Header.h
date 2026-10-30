//
//  inter-Bridging-Header.h
//  inter
//
//  Bridging header for Swift ↔ Objective-C interop.
//  Import ONLY ObjC headers whose types are referenced from Swift code.
//  Adding unused headers slows incremental compilation.
//

#import "InterShareTypes.h"
#import "InterShareVideoFrame.h"
// interview-recording-tool-layout (task 3.3): the coordinator owns an
// interviewer-local InterViewSnapshotVideoSource over the tool host. Importing it
// transitively brings in the InterShareVideoSource protocol (frameHandler / start /
// stop) referenced from Swift.
#import "InterViewSnapshotVideoSource.h"
#import "InterShareSink.h"
#import "MetalRenderEngine.h"
#import "InterRecordingEngine.h"
#import "InterComposedRenderer.h"
#import "InterRecordingSink.h"
#import "InterSurfaceShareController.h"
#import "InterLocalMediaController.h"
#import "InterRecordingIndicatorView.h"
// Schedule port: InterScheduledMeeting model + InterPreMeetingSettings (saved
// meeting defaults) are consumed by the SwiftUI schedule screen.
#import "InterSchedulePanel.h"
#import "InterPreMeetingPanel.h"
// In-call control bar port: the SwiftUI bridge conforms to the same media
// control surface the wiring controller drives on the legacy AppKit panel.
#import "InterCallMediaControlSurface.h"
// Interviewer collaborative tools: the tool-kind enum is referenced from Swift
// (InterSecureToolsBridge peer-activity seam, task 6.1).
#import "InterInterviewToolTypes.h"
