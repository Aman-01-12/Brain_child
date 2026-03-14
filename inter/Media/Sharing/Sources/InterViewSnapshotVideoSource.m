#import "InterViewSnapshotVideoSource.h"

#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <os/lock.h>

#import "InterShareTypes.h"

static const NSTimeInterval InterViewSnapshotFrameInterval = (1.0 / 10.0);
static const size_t InterViewSnapshotMaxWidth = 1600;
static const size_t InterViewSnapshotMaxHeight = 900;
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

    NSBitmapImageRep *bitmap = [capturedView bitmapImageRepForCachingDisplayInRect:capturedView.bounds];
    if (!bitmap) {
        return nil;
    }

    [capturedView cacheDisplayInRect:capturedView.bounds toBitmapImageRep:bitmap];
    CGImageRef cgImage = bitmap.CGImage;
    if (!cgImage) {
        return nil;
    }

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
