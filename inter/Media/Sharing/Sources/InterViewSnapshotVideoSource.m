#import "InterViewSnapshotVideoSource.h"

#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <os/lock.h>
#if DEBUG
#import <os/log.h>
#endif

#import "InterShareTypes.h"

#if DEBUG
// [B1] DEBUG-only Retina-confirmation diagnostic. This supports the B1 Retina
// hypothesis (off-screen tool host captured at 1x instead of 2x): it lets a
// developer running a live secure session with the tool host parked off-screen
// confirm at runtime whether the captured pixels are 1x or 2x relative to the
// view's point bounds. It changes NO capture behavior — the robust
// backing-scale handling lands in task 16.1. Compiled out of release builds.
static os_log_t InterViewSnapshotLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.inter.sharing", "viewsnapshot");
    });
    return log;
}
#endif

// [B1] Capture stays at 10 fps (finding H1): the publisher already throttles the
// uplink to 15 fps, and raising snapshot fps would only worsen B6 main-thread
// contention (cacheDisplayInRect runs on main). Do NOT raise this to 15.
static const NSTimeInterval InterViewSnapshotFrameInterval = (1.0 / 10.0);
static const size_t InterViewSnapshotMaxWidth = 1920;
static const size_t InterViewSnapshotMaxHeight = 1080;
static const CGFloat InterViewSnapshotBackgroundIntensity = 0.04;

static CGSize InterViewSnapshotScaledSize(CGSize sourceSize, CGFloat maxWidth, CGFloat maxHeight) {
    if (sourceSize.width <= 0.0 || sourceSize.height <= 0.0) {
        return CGSizeZero;
    }

    CGFloat widthScale = maxWidth / sourceSize.width;
    CGFloat heightScale = maxHeight / sourceSize.height;
    CGFloat scale = MIN(1.0, MIN(widthScale, heightScale));
    return CGSizeMake(floor(sourceSize.width * scale), floor(sourceSize.height * scale));
}

@interface InterViewSnapshotVideoSource ()
@property (atomic, assign, readwrite, getter=isRunning) BOOL running;
@end

@implementation InterViewSnapshotVideoSource {
    __weak NSView *_capturedView;
    dispatch_queue_t _captureQueue;
    dispatch_source_t _timer;
    os_unfair_lock _stateLock;
    uint64_t _generation;
    BOOL _captureInFlight;
    InterShareVideoSourceFrameHandler _frameHandler;
    InterShareVideoSourceErrorHandler _errorHandler;
    InterShareVideoSourceAudioSampleBufferHandler _audioSampleBufferHandler;
}

@synthesize frameHandler = _frameHandler;
@synthesize errorHandler = _errorHandler;
@synthesize audioSampleBufferHandler = _audioSampleBufferHandler;

- (instancetype)initWithCapturedView:(NSView *)capturedView {
    self = [super init];
    if (!self) {
        return nil;
    }

    _capturedView = capturedView;
    _captureQueue = dispatch_queue_create("secure.inter.share.source.viewsnapshot.frames",
                                          DISPATCH_QUEUE_SERIAL);
    _stateLock = OS_UNFAIR_LOCK_INIT;
    _generation = 0;
    _captureInFlight = NO;
    _running = NO;
    return self;
}

- (void)start {
    __block uint64_t currentGeneration = 0;
    dispatch_source_t timer = nil;

    os_unfair_lock_lock(&_stateLock);
    if (self.running) {
        os_unfair_lock_unlock(&_stateLock);
        return;
    }

    self.running = YES;
    _generation += 1;
    currentGeneration = _generation;
    _captureInFlight = NO;
    os_unfair_lock_unlock(&_stateLock);

    NSView *capturedView = _capturedView;
    if (!capturedView) {
        [self failStartWithMessage:@"Secure tool surface is unavailable."];
        return;
    }

    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _captureQueue);
    if (!timer) {
        [self failStartWithMessage:@"Unable to create the secure tool capture timer."];
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf captureTickForGeneration:currentGeneration];
    });
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(InterViewSnapshotFrameInterval * (NSTimeInterval)NSEC_PER_SEC),
                              (uint64_t)(0.02 * (NSTimeInterval)NSEC_PER_SEC));

    os_unfair_lock_lock(&_stateLock);
    BOOL stillValid = self.running && _generation == currentGeneration;
    if (stillValid) {
        _timer = timer;
    }
    os_unfair_lock_unlock(&_stateLock);

    if (!stillValid) {
        dispatch_source_cancel(timer);
        return;
    }

    dispatch_resume(timer);
}

- (void)stop {
    dispatch_source_t timer = nil;

    os_unfair_lock_lock(&_stateLock);
    if (!self.running) {
        os_unfair_lock_unlock(&_stateLock);
        return;
    }

    self.running = NO;
    _generation += 1;
    _captureInFlight = NO;
    timer = _timer;
    _timer = nil;
    os_unfair_lock_unlock(&_stateLock);

    if (timer) {
        dispatch_source_cancel(timer);
    }
}

#pragma mark - Private

- (void)failStartWithMessage:(NSString *)message {
    os_unfair_lock_lock(&_stateLock);
    self.running = NO;
    _generation += 1;
    _captureInFlight = NO;
    dispatch_source_t timer = _timer;
    _timer = nil;
    os_unfair_lock_unlock(&_stateLock);

    if (timer) {
        dispatch_source_cancel(timer);
    }

    InterShareVideoSourceErrorHandler errorHandler = self.errorHandler;
    if (!errorHandler || message.length == 0) {
        return;
    }

    NSError *error = [NSError errorWithDomain:InterShareErrorDomain
                                         code:InterShareErrorCodeInvalidConfiguration
                                     userInfo:@{NSLocalizedDescriptionKey: message}];
    errorHandler(error);
}

- (void)captureTickForGeneration:(uint64_t)generation {
    if (![self beginCaptureForGeneration:generation]) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        CGImageRef snapshotImage = [self newSnapshotImageForGeneration:generation];
        if (!snapshotImage) {
            dispatch_async(self->_captureQueue, ^{
                [self completeCaptureForGeneration:generation withImage:nil];
            });
            return;
        }

        dispatch_async(self->_captureQueue, ^{
            [self completeCaptureForGeneration:generation withImage:snapshotImage];
            CGImageRelease(snapshotImage);
        });
    });
}

- (BOOL)beginCaptureForGeneration:(uint64_t)generation {
    os_unfair_lock_lock(&_stateLock);
    BOOL canCapture = self.running && _generation == generation && !_captureInFlight;
    if (canCapture) {
        _captureInFlight = YES;
    }
    os_unfair_lock_unlock(&_stateLock);
    return canCapture;
}

- (void)completeCaptureForGeneration:(uint64_t)generation withImage:(CGImageRef)image {
    BOOL generationIsActive = NO;
    os_unfair_lock_lock(&_stateLock);
    generationIsActive = self.running && _generation == generation;
    _captureInFlight = NO;
    os_unfair_lock_unlock(&_stateLock);

    if (!generationIsActive || !image) {
        return;
    }

    CVPixelBufferRef pixelBuffer = [self newPixelBufferForImage:image];
    if (!pixelBuffer) {
        return;
    }

    CMTime presentationTime = CMClockGetTime(CMClockGetHostTimeClock());
    InterShareVideoFrame *frame = [[InterShareVideoFrame alloc] initWithPixelBuffer:pixelBuffer
                                                                    presentationTime:presentationTime];
    CVPixelBufferRelease(pixelBuffer);

    InterShareVideoSourceFrameHandler frameHandler = self.frameHandler;
    if (frameHandler) {
        frameHandler(frame);
    }
}

- (CGImageRef)newSnapshotImageForGeneration:(uint64_t)generation CF_RETURNS_RETAINED {
    os_unfair_lock_lock(&_stateLock);
    BOOL generationIsActive = self.running && _generation == generation;
    os_unfair_lock_unlock(&_stateLock);
    if (!generationIsActive) {
        return nil;
    }

    NSView *capturedView = _capturedView;
    if (!capturedView || capturedView.isHidden || capturedView.bounds.size.width <= 1.0 || capturedView.bounds.size.height <= 1.0) {
        return nil;
    }

    [capturedView layoutSubtreeIfNeeded];

    // [B1] Capture at NATIVE backing scale (Retina) robustly. AppKit's
    // bitmapImageRepForCachingDisplayInRect: derives its scale from the view's
    // window; an off-screen / window-less tool host yields a 1x rep and blurry
    // text after the <=1920x1080 cap. Build the rep explicitly at native pixel
    // dimensions (ceil(points * scale)) and set its point size to the bounds, so
    // cacheDisplayInRect: renders the points-sized view into native-pixel backing
    // even with no window. Falls back to the main display's backing scale
    // (typically 2.0) when the view has no window, then to 1.0 as a last resort.
    CGFloat scale = capturedView.window.backingScaleFactor;
    if (scale < 1.5) {
        scale = NSScreen.mainScreen.backingScaleFactor;
    }
    if (scale < 1.0) {
        scale = 1.0;
    }

    CGFloat boundsW = capturedView.bounds.size.width;
    CGFloat boundsH = capturedView.bounds.size.height;
    NSBitmapImageRep *bitmap =
        [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                pixelsWide:(NSInteger)ceil(boundsW * scale)
                                                pixelsHigh:(NSInteger)ceil(boundsH * scale)
                                             bitsPerSample:8
                                           samplesPerPixel:4
                                                  hasAlpha:YES
                                                  isPlanar:NO
                                            colorSpaceName:NSDeviceRGBColorSpace
                                               bytesPerRow:0
                                              bitsPerPixel:0];
    if (!bitmap) {
        return nil;
    }
    // Point size = bounds so AppKit renders the points-sized view into the
    // native-pixel backing above.
    bitmap.size = NSMakeSize(boundsW, boundsH);

    [capturedView cacheDisplayInRect:capturedView.bounds toBitmapImageRep:bitmap];
    CGImageRef cgImage = bitmap.CGImage;
    if (!cgImage) {
        return nil;
    }

#if DEBUG
    // [B1] Retina-confirmation diagnostic (gates task 16.1 backing-scale fix).
    // Log captured pixel dimensions vs the view's point bounds and backing scale
    // so a developer can confirm whether the off-screen capture is 1x or 2x.
    // Throttled to at most once per second to avoid spamming the log at 10 fps.
    {
        static os_unfair_lock diagnosticLock = OS_UNFAIR_LOCK_INIT;
        static NSTimeInterval lastLogTime = 0.0;
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        BOOL shouldLog = NO;
        os_unfair_lock_lock(&diagnosticLock);
        if (now - lastLogTime >= 1.0) {
            lastLogTime = now;
            shouldLog = YES;
        }
        os_unfair_lock_unlock(&diagnosticLock);

        if (shouldLog) {
            CGFloat windowScale = capturedView.window.backingScaleFactor;
            CGFloat mainScreenScale = NSScreen.mainScreen.backingScaleFactor;
            CGSize pointSize = capturedView.bounds.size;
            size_t pixelWidth = CGImageGetWidth(cgImage);
            size_t pixelHeight = CGImageGetHeight(cgImage);
            os_log(InterViewSnapshotLog(),
                   "[B1 Retina] window.backingScale=%.2f (mainScreen.backingScale=%.2f fallback) "
                   "bounds(points)=%.1fx%.1f captured(pixels)=%zux%zu bitmap(pixels)=%ldx%ld",
                   windowScale, mainScreenScale,
                   pointSize.width, pointSize.height,
                   pixelWidth, pixelHeight,
                   (long)bitmap.pixelsWide, (long)bitmap.pixelsHigh);
        }
    }
#endif

    return CGImageCreateCopy(cgImage);
}

- (CVPixelBufferRef)newPixelBufferForImage:(CGImageRef)image CF_RETURNS_RETAINED {
    size_t sourceWidth = CGImageGetWidth(image);
    size_t sourceHeight = CGImageGetHeight(image);
    CGSize scaledSize = InterViewSnapshotScaledSize(CGSizeMake((CGFloat)sourceWidth, (CGFloat)sourceHeight),
                                                    (CGFloat)InterViewSnapshotMaxWidth,
                                                    (CGFloat)InterViewSnapshotMaxHeight);
    if (CGSizeEqualToSize(scaledSize, CGSizeZero)) {
        return nil;
    }

    size_t targetWidth = (size_t)scaledSize.width;
    size_t targetHeight = (size_t)scaledSize.height;
    NSDictionary *attributes = @{
        (NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
    };

    CVPixelBufferRef pixelBuffer = nil;
    CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault,
                                          targetWidth,
                                          targetHeight,
                                          kCVPixelFormatType_32BGRA,
                                          (__bridge CFDictionaryRef)attributes,
                                          &pixelBuffer);
    if (result != kCVReturnSuccess || !pixelBuffer) {
        return nil;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(baseAddress,
                                                 targetWidth,
                                                 targetHeight,
                                                 8,
                                                 bytesPerRow,
                                                 colorSpace,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(colorSpace);

    if (!context) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CVPixelBufferRelease(pixelBuffer);
        return nil;
    }

    // The secure tool surface is already a fully composed app-owned view tree.
    // Drawing it into a BGRA pixel buffer here keeps the sharing boundary
    // explicit: only this subtree is serialized into the outgoing stream.
    //
    // Rounded AppKit/layer-backed edges carry alpha. If we draw them over an
    // uninitialized pixel buffer, the transparent edge pixels can blend against
    // garbage memory and show up remotely as white shimmer after encode/decode.
    // Flattening onto the host's dark background makes every outgoing frame
    // fully deterministic and opaque.
    memset(baseAddress, 0, bytesPerRow * targetHeight);
    CGRect targetRect = CGRectMake(0.0, 0.0, (CGFloat)targetWidth, (CGFloat)targetHeight);
    CGContextSetRGBFillColor(context,
                             InterViewSnapshotBackgroundIntensity,
                             InterViewSnapshotBackgroundIntensity,
                             InterViewSnapshotBackgroundIntensity,
                             1.0);
    CGContextFillRect(context, targetRect);
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, targetRect, image);
    CGContextRelease(context);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return pixelBuffer;
}

@end
