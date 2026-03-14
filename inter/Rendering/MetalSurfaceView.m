#import "MetalSurfaceView.h"

#import <QuartzCore/CAMetalLayer.h>
#import <os/lock.h>
#import <string.h>

static CVReturn InterDisplayLinkCallback(CVDisplayLinkRef displayLink,
                                         const CVTimeStamp *now,
                                         const CVTimeStamp *outputTime,
                                         CVOptionFlags flagsIn,
                                         CVOptionFlags *flagsOut,
                                         void *displayLinkContext);

@interface MetalSurfaceView ()
@property (nonatomic, strong) MetalRenderEngine *engine;
@property (nonatomic, strong) CAMetalLayer *metalLayer;
@end

@implementation MetalSurfaceView {
    CVDisplayLinkRef _displayLink;
    dispatch_semaphore_t _inFlightSemaphore;
    dispatch_queue_t _egressQueue;

    os_unfair_lock _surfaceLock;
    BOOL _stopped;
    CGSize _drawableSize;
    id<MTLTexture> _captureTexture;
    NSUInteger _captureWidth;
    NSUInteger _captureHeight;

    CVPixelBufferPoolRef _pixelBufferPool;
    NSUInteger _readbackBytesPerRow;
    NSUInteger _readbackBufferLength;
    id<MTLBuffer> _readbackBuffers[3];

    uint64_t _frameIndex;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) {
        return nil;
    }

    [self commonInit];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (!self) {
        return nil;
    }

    [self commonInit];
    return self;
}

- (void)dealloc {
    // Defensive cleanup in case lifecycle teardown did not run.
    [self shutdownRenderingSynchronously];

    if (_pixelBufferPool != NULL) {
        CVPixelBufferPoolRelease(_pixelBufferPool);
        _pixelBufferPool = NULL;
    }
}

- (void)commonInit {
    self.engine = [MetalRenderEngine sharedEngine];
    self.wantsLayer = YES;

    _inFlightSemaphore = dispatch_semaphore_create(3);
    _egressQueue = dispatch_queue_create("secure.inter.metal.egress.queue",
                                         DISPATCH_QUEUE_SERIAL);
    _surfaceLock = OS_UNFAIR_LOCK_INIT;

    CAMetalLayer *layer = (CAMetalLayer *)self.layer;
    layer.device = self.engine.device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    layer.opaque = YES;
    layer.backgroundColor = [NSColor blackColor].CGColor;
    layer.contentsGravity = kCAGravityResizeAspect;
    self.metalLayer = layer;

    [self refreshDrawableSize];
}

- (BOOL)acceptsFirstResponder {
    return YES;
}
- (BOOL)wantsUpdateLayer {
    return YES;
}

- (CALayer *)makeBackingLayer {
    return [CAMetalLayer layer];
}

- (void)updateLayer {
    [self refreshDrawableSize];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self refreshDrawableSize];
}

- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
    [super viewWillMoveToWindow:newWindow];
    if (newWindow == nil) {
        [self stopAndReleaseDisplayLink];
        return;
    }

    [self startDisplayLinkIfNeeded];
}

- (void)startDisplayLinkIfNeeded {
    if (_displayLink != NULL) {
        return;
    }

    os_unfair_lock_lock(&_surfaceLock);
    _stopped = NO;
    os_unfair_lock_unlock(&_surfaceLock);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CVReturn result = CVDisplayLinkCreateWithActiveCGDisplays(&_displayLink);
    if (result == kCVReturnSuccess && _displayLink != NULL) {
        CVDisplayLinkSetOutputCallback(_displayLink,
                                       InterDisplayLinkCallback,
                                       (__bridge void *)self);
        CVDisplayLinkStart(_displayLink);
    }
#pragma clang diagnostic pop

    if (result != kCVReturnSuccess || _displayLink == NULL) {
        return;
    }
}

- (void)stopAndReleaseDisplayLink {
    // Signal stopped first so any in-flight callback bails out.
    os_unfair_lock_lock(&_surfaceLock);
    _stopped = YES;
    os_unfair_lock_unlock(&_surfaceLock);

    if (_displayLink == NULL) {
        return;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CVDisplayLinkStop(_displayLink);
    CVDisplayLinkRelease(_displayLink);
#pragma clang diagnostic pop
    _displayLink = NULL;

    // Drain the in-flight semaphore to wait for any callback that was
    // already past the _stopped check when we set the flag.
    for (int i = 0; i < 3; i++) {
        dispatch_semaphore_wait(_inFlightSemaphore, DISPATCH_TIME_FOREVER);
    }
    for (int i = 0; i < 3; i++) {
        dispatch_semaphore_signal(_inFlightSemaphore);
    }
}

- (void)shutdownRenderingSynchronously {
    // Teardown can remove the view hierarchy while the display-link callback is
    // still racing on its own thread. Clearing the egress handler first and
    // then synchronously draining the display link ensures no callback can
    // reach engine-backed resources after callers start dismantling the window.
    self.frameEgressHandler = nil;
    [self stopAndReleaseDisplayLink];
}

- (void)refreshDrawableSize {
    CGFloat scaleFactor = self.window.backingScaleFactor;
    if (scaleFactor <= 0.0) {
        scaleFactor = NSScreen.mainScreen.backingScaleFactor;
    }
    if (scaleFactor <= 0.0) {
        scaleFactor = 1.0;
    }

    CGSize size = CGSizeMake(self.bounds.size.width * scaleFactor,
                             self.bounds.size.height * scaleFactor);
    if (size.width < 1.0 || size.height < 1.0) {
        size = CGSizeZero;
    }

    self.metalLayer.drawableSize = size;

    os_unfair_lock_lock(&_surfaceLock);
    _drawableSize = size;
    os_unfair_lock_unlock(&_surfaceLock);
}

- (void)renderFrameFromDisplayLink {
    // Early-out if the view is being torn down.
    os_unfair_lock_lock(&_surfaceLock);
    BOOL stopped = _stopped;
    os_unfair_lock_unlock(&_surfaceLock);
    if (stopped) {
        return;
    }

    dispatch_semaphore_wait(_inFlightSemaphore, DISPATCH_TIME_FOREVER);

    // Re-check after semaphore acquisition — teardown may have started while waiting.
    os_unfair_lock_lock(&_surfaceLock);
    stopped = _stopped;
    os_unfair_lock_unlock(&_surfaceLock);
    if (stopped) {
        dispatch_semaphore_signal(_inFlightSemaphore);
        return;
    }

    CGSize drawableSize = CGSizeZero;
    os_unfair_lock_lock(&_surfaceLock);
    drawableSize = _drawableSize;
    os_unfair_lock_unlock(&_surfaceLock);

    if (drawableSize.width < 1.0 || drawableSize.height < 1.0) {
        dispatch_semaphore_signal(_inFlightSemaphore);
        return;
    }

    id<CAMetalDrawable> drawable = [self.metalLayer nextDrawable];
    if (!drawable) {
        dispatch_semaphore_signal(_inFlightSemaphore);
        return;
    }

    NSUInteger drawableWidth = drawable.texture.width;
    NSUInteger drawableHeight = drawable.texture.height;
    if (drawableWidth == 0 || drawableHeight == 0) {
        dispatch_semaphore_signal(_inFlightSemaphore);
        return;
    }

    id<MTLTexture> captureTexture = nil;
    id<MTLBuffer> readbackBuffer = nil;
    CVPixelBufferPoolRef pixelBufferPool = NULL;
    NSUInteger readbackBytesPerRow = 0;

    os_unfair_lock_lock(&_surfaceLock);
    [self ensureSurfaceResourcesLockedForWidth:drawableWidth height:drawableHeight];

    captureTexture = _captureTexture;
    readbackBuffer = _readbackBuffers[_frameIndex % 3];
    readbackBytesPerRow = _readbackBytesPerRow;
    if (_pixelBufferPool != NULL) {
        pixelBufferPool = _pixelBufferPool;
        CFRetain(pixelBufferPool);
    }
    _frameIndex++;
    os_unfair_lock_unlock(&_surfaceLock);

    id<MTLCommandBuffer> commandBuffer = [self.engine.commandQueue commandBuffer];
    if (!commandBuffer || !captureTexture) {
        if (pixelBufferPool != NULL) {
            CFRelease(pixelBufferPool);
        }
        dispatch_semaphore_signal(_inFlightSemaphore);
        return;
    }

    dispatch_semaphore_t semaphore = _inFlightSemaphore;
    [commandBuffer addCompletedHandler:^(__unused id<MTLCommandBuffer> cb) {
        dispatch_semaphore_signal(semaphore);
    }];

    [self.engine encodeCompositePassToCaptureTexture:captureTexture
                                       commandBuffer:commandBuffer
                                        drawableSize:drawableSize];

    MetalSurfaceFrameEgressHandler egressHandler = self.frameEgressHandler;
    if (egressHandler && readbackBuffer) {
        id<MTLBlitCommandEncoder> blitEncoder = [commandBuffer blitCommandEncoder];
        [blitEncoder copyFromTexture:captureTexture
                         sourceSlice:0
                         sourceLevel:0
                        sourceOrigin:MTLOriginMake(0, 0, 0)
                          sourceSize:MTLSizeMake(drawableWidth, drawableHeight, 1)
                            toBuffer:readbackBuffer
                   destinationOffset:0
              destinationBytesPerRow:readbackBytesPerRow
            destinationBytesPerImage:readbackBytesPerRow * drawableHeight
                             options:MTLBlitOptionNone];
        [blitEncoder endEncoding];
    }

    if (egressHandler && readbackBuffer && pixelBufferPool != NULL) {
        dispatch_queue_t egressQueue = _egressQueue;
        NSUInteger frameWidth = drawableWidth;
        NSUInteger frameHeight = drawableHeight;
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completedBuffer) {
            if (completedBuffer.status != MTLCommandBufferStatusCompleted) {
                CFRelease(pixelBufferPool);
                return;
            }

            dispatch_async(egressQueue, ^{
                CVPixelBufferRef pixelBuffer = NULL;
                CVReturn cvResult = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                                                       pixelBufferPool,
                                                                       &pixelBuffer);
                if (cvResult != kCVReturnSuccess || pixelBuffer == NULL) {
                    CFRelease(pixelBufferPool);
                    return;
                }

                CVPixelBufferLockBaseAddress(pixelBuffer, 0);
                uint8_t *destinationBase = CVPixelBufferGetBaseAddress(pixelBuffer);
                size_t destinationRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer);

                const uint8_t *sourceBase = (const uint8_t *)readbackBuffer.contents;
                size_t copyBytesPerRow = MIN(destinationRowBytes, frameWidth * 4);
                for (NSUInteger row = 0; row < frameHeight; row++) {
                    memcpy(destinationBase + (row * destinationRowBytes),
                           sourceBase + (row * readbackBytesPerRow),
                           copyBytesPerRow);
                }
                CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

                egressHandler(pixelBuffer);
                CVPixelBufferRelease(pixelBuffer);
                CFRelease(pixelBufferPool);
            });
        }];
    } else if (pixelBufferPool != NULL) {
        CFRelease(pixelBufferPool);
    }

    [self.engine encodePresentPassFromCaptureTexture:captureTexture
                                   toDrawableTexture:drawable.texture
                                       commandBuffer:commandBuffer];

    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

- (void)ensureSurfaceResourcesLockedForWidth:(NSUInteger)width height:(NSUInteger)height {
    if (_captureTexture && _captureWidth == width && _captureHeight == height) {
        return;
    }

    _captureWidth = width;
    _captureHeight = height;

    MTLTextureDescriptor *captureDescriptor =
    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                       width:width
                                                      height:height
                                                   mipmapped:NO];
    captureDescriptor.storageMode = MTLStorageModePrivate;
    captureDescriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    _captureTexture = [self.engine.device newTextureWithDescriptor:captureDescriptor];

    if (_pixelBufferPool != NULL) {
        CVPixelBufferPoolRelease(_pixelBufferPool);
        _pixelBufferPool = NULL;
    }
    _pixelBufferPool = [self createPixelBufferPoolForWidth:width height:height];

    _readbackBytesPerRow = [self alignedBytesPerRowForWidth:width];
    _readbackBufferLength = _readbackBytesPerRow * height;
    for (NSUInteger i = 0; i < 3; i++) {
        _readbackBuffers[i] = [self.engine.device newBufferWithLength:_readbackBufferLength
                                                               options:MTLResourceStorageModeShared];
    }
}

- (CVPixelBufferPoolRef)createPixelBufferPoolForWidth:(NSUInteger)width
                                                height:(NSUInteger)height {
    NSDictionary *poolAttributes = @{
        (id)kCVPixelBufferPoolMinimumBufferCountKey: @(6)
    };

    NSDictionary *pixelBufferAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES
    };

    CVPixelBufferPoolRef pool = NULL;
    CVReturn result = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                              (__bridge CFDictionaryRef)poolAttributes,
                                              (__bridge CFDictionaryRef)pixelBufferAttributes,
                                              &pool);
    if (result != kCVReturnSuccess) {
        return NULL;
    }
    return pool;
}

- (NSUInteger)alignedBytesPerRowForWidth:(NSUInteger)width {
    NSUInteger rawBytesPerRow = width * 4;
    NSUInteger alignment = 256;
    return ((rawBytesPerRow + alignment - 1) / alignment) * alignment;
}

@end

static CVReturn InterDisplayLinkCallback(__unused CVDisplayLinkRef displayLink,
                                         __unused const CVTimeStamp *now,
                                         __unused const CVTimeStamp *outputTime,
                                         __unused CVOptionFlags flagsIn,
                                         __unused CVOptionFlags *flagsOut,
                                         void *displayLinkContext) {
    @autoreleasepool {
        MetalSurfaceView *surfaceView = (__bridge MetalSurfaceView *)displayLinkContext;
        [surfaceView renderFrameFromDisplayLink];
    }
    return kCVReturnSuccess;
}
