#import "InterShareVideoFrame.h"

@implementation InterShareVideoFrame {
    CVPixelBufferRef _pixelBuffer;
    CMTime _presentationTime;
}

- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer
                   presentationTime:(CMTime)presentationTime {
    self = [super init];
    if (!self) {
        return nil;
    }

    if (pixelBuffer) {
        _pixelBuffer = CVPixelBufferRetain(pixelBuffer);
    }
    _presentationTime = presentationTime;
    return self;
}

- (void)dealloc {
    if (_pixelBuffer) {
        CVPixelBufferRelease(_pixelBuffer);
        _pixelBuffer = NULL;
    }
}

- (CVPixelBufferRef)pixelBuffer {
    return _pixelBuffer;
}

- (CMTime)presentationTime {
    return _presentationTime;
}

@end
