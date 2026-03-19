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
#import "InterShareSink.h"
#import "MetalRenderEngine.h"
