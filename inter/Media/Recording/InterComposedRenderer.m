#import "InterComposedRenderer.h"

#import <AppKit/AppKit.h>
#import <CoreImage/CoreImage.h>
#import <CoreText/CoreText.h>
#import <os/lock.h>
#import <os/log.h>
#import <simd/simd.h>

static os_log_t InterComposedRendererLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.inter.recording", "composer");
    });
    return log;
}

// ---------------------------------------------------------------------------
// MARK: - Constants
// ---------------------------------------------------------------------------

static const NSInteger kPoolBufferCount = 3;   // Triple buffering.
static const CGFloat kPiPWidthRatio = 0.20;    // PiP is 20% of output width.
static const CGFloat kPiPPadding = 16.0;       // Padding from bottom-right edge.

// ---------------------------------------------------------------------------
// MARK: - Metal Shader Source
// ---------------------------------------------------------------------------

/// Minimal shader for compositing: samples a BGRA texture onto a positioned quad.
/// NV12→BGRA conversion is handled by creating a CIImage from NV12 CVPixelBuffers
/// and rendering via CIContext into a BGRA intermediate — this avoids maintaining
/// a separate shader for NV12 and keeps the compositor shader simple.
static NSString *const kCompositorShaderSource =
    @"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "\n"
    "struct CompositorVertexOut {\n"
    "    float4 position [[position]];\n"
    "    float2 texCoord;\n"
    "};\n"
    "\n"
    "struct CompositorQuadParams {\n"
    "    float2 origin;  // NDC origin [-1, 1]\n"
    "    float2 size;    // NDC size\n"
    "};\n"
    "\n"
    "vertex CompositorVertexOut compositorVertex(uint vertexID [[vertex_id]],\n"
    "                                            constant CompositorQuadParams &params [[buffer(0)]]) {\n"
    "    // Triangle strip: 0=BL, 1=BR, 2=TL, 3=TR\n"
    "    const float2 positions[4] = {\n"
    "        float2(0.0, 0.0),\n"
    "        float2(1.0, 0.0),\n"
    "        float2(0.0, 1.0),\n"
    "        float2(1.0, 1.0)\n"
    "    };\n"
    "    const float2 uvs[4] = {\n"
    "        float2(0.0, 1.0),\n"  // Metal texture coords: top-left = (0,0)
    "        float2(1.0, 1.0),\n"
    "        float2(0.0, 0.0),\n"
    "        float2(1.0, 0.0)\n"
    "    };\n"
    "    CompositorVertexOut out;\n"
    "    float2 pos = params.origin + positions[vertexID] * params.size;\n"
    "    out.position = float4(pos, 0.0, 1.0);\n"
    "    out.texCoord = uvs[vertexID];\n"
    "    return out;\n"
    "}\n"
    "\n"
    "fragment float4 compositorFragment(CompositorVertexOut in [[stage_in]],\n"
    "                                   texture2d<float> tex [[texture(0)]]) {\n"
    "    constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
    "    return tex.sample(s, in.texCoord);\n"
    "}\n"
    "\n"
    "fragment float4 compositorAlphaFragment(CompositorVertexOut in [[stage_in]],\n"
    "                                        texture2d<float> tex [[texture(0)]],\n"
    "                                        constant float &alpha [[buffer(0)]]) {\n"
    "    constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
    "    float4 color = tex.sample(s, in.texCoord);\n"
    "    color.a *= alpha;\n"
    "    return color;\n"
    "}\n";

/// Quad parameters passed to the vertex shader.
typedef struct {
    simd_float2 origin;  // NDC origin.
    simd_float2 size;    // NDC size.
} CompositorQuadParams;

// ---------------------------------------------------------------------------
// MARK: - Private Interface
// ---------------------------------------------------------------------------

@interface InterComposedRenderer ()
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, assign) CGSize outputSize;
@end

@implementation InterComposedRenderer {
    // Frame state — guarded by _frameLock.
    os_unfair_lock _frameLock;
    CVPixelBufferRef _screenSharePixelBuffer;
    CVPixelBufferRef _activeSpeakerPixelBuffer;
    NSString *_activeSpeakerIdentity;
    CVPixelBufferRef _secondarySpeakerPixelBuffer;
    NSString *_secondarySpeakerIdentity;
    InterComposedLayout _currentLayout;

    // Grid participant state — guarded by _frameLock.
    // Maps participant identity → CVPixelBufferRef (retained via __bridge_retained id).
    NSMutableDictionary<NSString *, id> *_gridFrames;
    // Ordered list of participant identities for deterministic grid rendering.
    NSArray<NSString *> *_gridParticipantOrder;

    // Triple-buffer pool — only accessed on the render queue.
    CVPixelBufferRef _poolBuffers[3];
    dispatch_semaphore_t _poolSemaphores[3];
    NSInteger _poolWriteIndex;

    // Metal state.
    id<MTLRenderPipelineState> _opaquePipelineState;
    id<MTLRenderPipelineState> _alphaPipelineState;
    CVMetalTextureCacheRef _textureCache;

    // Watermark texture — lazily generated, cached until outputSize changes.
    id<MTLTexture> _watermarkTexture;
    CGSize _watermarkSize;

    // CIContext for NV12→BGRA conversion (when needed).
    CIContext *_ciContext;

    // Placeholder cache: identity → CVPixelBuffer (dark bg + name text).
    NSMutableDictionary<NSString *, id> *_placeholderCache;

    BOOL _invalidated;
}

// ---------------------------------------------------------------------------
// MARK: - Init / Dealloc
// ---------------------------------------------------------------------------

- (instancetype)initWithDevice:(id<MTLDevice>)device
                  commandQueue:(id<MTLCommandQueue>)commandQueue
                    outputSize:(CGSize)outputSize {
    self = [super init];
    if (!self) return nil;

    _device = device;
    _commandQueue = commandQueue;
    _outputSize = outputSize;
    _frameLock = OS_UNFAIR_LOCK_INIT;
    _currentLayout = InterComposedLayoutIdle;
    _poolWriteIndex = 0;
    _invalidated = NO;

    _placeholderCache = [NSMutableDictionary dictionary];
    _gridFrames = [NSMutableDictionary dictionary];
    _gridParticipantOrder = @[];
    _ciContext = [CIContext contextWithMTLDevice:device
                                        options:@{kCIContextWorkingColorSpace: (__bridge_transfer id)CGColorSpaceCreateWithName(kCGColorSpaceSRGB)}];

    // Create texture cache.
    CVReturn result = CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL,
                                                device, NULL, &_textureCache);
    if (result != kCVReturnSuccess) {
        os_log_error(InterComposedRendererLog(), "Failed to create CVMetalTextureCache: %d", result);
        return nil;
    }

    // Create triple-buffer pool.
    [self _createPoolBuffers];

    // Compile Metal shaders.
    [self _compilePipelines];

    return self;
}

- (void)dealloc {
    [self invalidate];
}

- (void)invalidate {
    if (_invalidated) return;
    _invalidated = YES;

    os_unfair_lock_lock(&_frameLock);
    if (_screenSharePixelBuffer) { CVBufferRelease(_screenSharePixelBuffer); _screenSharePixelBuffer = NULL; }
    if (_activeSpeakerPixelBuffer) { CVBufferRelease(_activeSpeakerPixelBuffer); _activeSpeakerPixelBuffer = NULL; }
    if (_secondarySpeakerPixelBuffer) { CVBufferRelease(_secondarySpeakerPixelBuffer); _secondarySpeakerPixelBuffer = NULL; }
    [_gridFrames removeAllObjects];
    _gridParticipantOrder = @[];
    os_unfair_lock_unlock(&_frameLock);

    for (NSInteger i = 0; i < kPoolBufferCount; i++) {
        if (_poolBuffers[i]) {
            CVPixelBufferRelease(_poolBuffers[i]);
            _poolBuffers[i] = NULL;
        }
        _poolSemaphores[i] = nil;
    }

    if (_textureCache) {
        CFRelease(_textureCache);
        _textureCache = NULL;
    }

    _placeholderCache = nil;
}

// ---------------------------------------------------------------------------
// MARK: - Pool Creation
// ---------------------------------------------------------------------------

- (void)_createPoolBuffers {
    NSDictionary *attrs = @{
        (id)kCVPixelBufferWidthKey: @((int)_outputSize.width),
        (id)kCVPixelBufferHeightKey: @((int)_outputSize.height),
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},  // IOSurface-backed for zero-copy.
    };

    for (NSInteger i = 0; i < kPoolBufferCount; i++) {
        CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                              (size_t)_outputSize.width,
                                              (size_t)_outputSize.height,
                                              kCVPixelFormatType_32BGRA,
                                              (__bridge CFDictionaryRef)attrs,
                                              &_poolBuffers[i]);
        if (status != kCVReturnSuccess) {
            os_log_error(InterComposedRendererLog(),
                         "Failed to create pool buffer %ld: %d", (long)i, status);
        }
        // Start signaled — slot is available for the first render.
        _poolSemaphores[i] = dispatch_semaphore_create(1);
    }
}

// ---------------------------------------------------------------------------
// MARK: - Pipeline Compilation
// ---------------------------------------------------------------------------

- (void)_compilePipelines {
    NSError *error = nil;
    id<MTLLibrary> library = [_device newLibraryWithSource:kCompositorShaderSource
                                                   options:nil
                                                     error:&error];
    if (!library) {
        os_log_error(InterComposedRendererLog(),
                     "Shader compilation failed: %{public}@", error.localizedDescription);
        return;
    }

    id<MTLFunction> vertexFunc = [library newFunctionWithName:@"compositorVertex"];
    id<MTLFunction> opaqueFrag = [library newFunctionWithName:@"compositorFragment"];
    id<MTLFunction> alphaFrag  = [library newFunctionWithName:@"compositorAlphaFragment"];

    // Opaque pipeline — for fullscreen / PiP quads (no blending needed).
    {
        MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.vertexFunction = vertexFunc;
        desc.fragmentFunction = opaqueFrag;
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        _opaquePipelineState = [_device newRenderPipelineStateWithDescriptor:desc error:&error];
        if (!_opaquePipelineState) {
            os_log_error(InterComposedRendererLog(),
                         "Opaque pipeline failed: %{public}@", error.localizedDescription);
        }
    }

    // Alpha pipeline — for watermark overlay (alpha blending).
    {
        MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.vertexFunction = vertexFunc;
        desc.fragmentFunction = alphaFrag;
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        desc.colorAttachments[0].blendingEnabled = YES;
        desc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        desc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        _alphaPipelineState = [_device newRenderPipelineStateWithDescriptor:desc error:&error];
        if (!_alphaPipelineState) {
            os_log_error(InterComposedRendererLog(),
                         "Alpha pipeline failed: %{public}@", error.localizedDescription);
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Frame Updates (Thread-Safe)
// ---------------------------------------------------------------------------

- (void)updateScreenShareFrame:(CVPixelBufferRef)pixelBuffer {
    os_unfair_lock_lock(&_frameLock);
    if (_screenSharePixelBuffer) CVBufferRelease(_screenSharePixelBuffer);
    _screenSharePixelBuffer = pixelBuffer ? CVBufferRetain(pixelBuffer) : NULL;
    [self _recalculateLayoutLocked];
    os_unfair_lock_unlock(&_frameLock);
}

- (void)updateActiveSpeakerFrame:(CVPixelBufferRef)pixelBuffer
                        identity:(NSString *)identity {
    os_unfair_lock_lock(&_frameLock);
    if (_activeSpeakerPixelBuffer) CVBufferRelease(_activeSpeakerPixelBuffer);
    _activeSpeakerPixelBuffer = pixelBuffer ? CVBufferRetain(pixelBuffer) : NULL;
    _activeSpeakerIdentity = [identity copy];
    [self _recalculateLayoutLocked];
    os_unfair_lock_unlock(&_frameLock);
}

- (void)updateSecondarySpeakerFrame:(CVPixelBufferRef)pixelBuffer
                           identity:(NSString *)identity {
    os_unfair_lock_lock(&_frameLock);
    if (_secondarySpeakerPixelBuffer) CVBufferRelease(_secondarySpeakerPixelBuffer);
    _secondarySpeakerPixelBuffer = pixelBuffer ? CVBufferRetain(pixelBuffer) : NULL;
    _secondarySpeakerIdentity = [identity copy];
    [self _recalculateLayoutLocked];
    os_unfair_lock_unlock(&_frameLock);
}

// ---------------------------------------------------------------------------
// MARK: - Grid Participant Updates (Thread-Safe)
// ---------------------------------------------------------------------------

- (void)updateParticipantFrame:(CVPixelBufferRef)pixelBuffer
                      identity:(NSString *)identity {
    if (!identity) return;

    os_unfair_lock_lock(&_frameLock);
    if (pixelBuffer) {
        // Store retained pixel buffer via ARC bridge. The old value (if any) is
        // released automatically by ARC when the dictionary entry is replaced.
        _gridFrames[identity] = (__bridge_transfer id)(CVBufferRetain(pixelBuffer));
    } else {
        [_gridFrames removeObjectForKey:identity];
    }
    [self _recalculateLayoutLocked];
    os_unfair_lock_unlock(&_frameLock);
}

- (void)removeParticipant:(NSString *)identity {
    if (!identity) return;

    os_unfair_lock_lock(&_frameLock);
    [_gridFrames removeObjectForKey:identity];
    NSMutableArray *order = [_gridParticipantOrder mutableCopy];
    [order removeObject:identity];
    _gridParticipantOrder = [order copy];
    [self _recalculateLayoutLocked];
    os_unfair_lock_unlock(&_frameLock);
}

- (void)setParticipantOrder:(NSArray<NSString *> *)identities {
    os_unfair_lock_lock(&_frameLock);
    _gridParticipantOrder = [identities copy];
    [self _recalculateLayoutLocked];
    os_unfair_lock_unlock(&_frameLock);
}

/// Recompute current layout based on which sources are non-NULL.
/// MUST be called while holding _frameLock.
- (void)_recalculateLayoutLocked {
    InterComposedLayout oldLayout = _currentLayout;

    BOOL hasScreen = (_screenSharePixelBuffer != NULL);
    // Count grid participants that have a frame (or will get a placeholder).
    NSUInteger gridCount = _gridParticipantOrder.count;

    if (hasScreen && gridCount > 0) {
        // Screen share + participants → filmstrip sidebar layout.
        _currentLayout = InterComposedLayoutScreenShareFilmstrip;
    } else if (hasScreen) {
        // Screen share only — no camera participants available.
        _currentLayout = InterComposedLayoutScreenShareOnly;
    } else if (gridCount >= 3) {
        // 3+ cameras — NxM grid.
        _currentLayout = InterComposedLayoutGrid;
    } else {
        // 0–2 cameras — use legacy active/secondary speaker logic.
        BOOL hasPrimary = (_activeSpeakerPixelBuffer != NULL);
        BOOL hasSecondary = (_secondarySpeakerPixelBuffer != NULL);

        if (hasPrimary && hasSecondary) {
            _currentLayout = InterComposedLayoutCameraSideBySide;
        } else if (hasPrimary) {
            _currentLayout = InterComposedLayoutCameraOnlyFull;
        } else {
            _currentLayout = InterComposedLayoutIdle;
        }
    }

    if (_currentLayout != oldLayout) {
        os_log_info(InterComposedRendererLog(),
                    "Layout changed: %ld → %ld", (long)oldLayout, (long)_currentLayout);
        id<InterComposedRendererDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:@selector(composedRenderer:didChangeLayout:)]) {
            InterComposedLayout layout = _currentLayout;
            dispatch_async(dispatch_get_main_queue(), ^{
                [delegate composedRenderer:self didChangeLayout:layout];
            });
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Placeholder Generation
// ---------------------------------------------------------------------------

- (CVPixelBufferRef)placeholderFrameForIdentity:(NSString *)identity {
    @synchronized (_placeholderCache) {
        id cached = _placeholderCache[identity];
        if (cached) {
            return (__bridge CVPixelBufferRef)cached;
        }
    }

    // Generate a dark-background placeholder with the participant's name centered.
    int width = (int)_outputSize.width;
    int height = (int)_outputSize.height;

    NSDictionary *attrs = @{
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };

    CVPixelBufferRef buffer = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                        kCVPixelFormatType_32BGRA,
                        (__bridge CFDictionaryRef)attrs, &buffer);
    if (!buffer) return NULL;

    CVPixelBufferLockBaseAddress(buffer, 0);
    void *baseAddress = CVPixelBufferGetBaseAddress(buffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(buffer);

    // Dark background (0x1A1A1A).
    memset(baseAddress, 0, bytesPerRow * height);
    uint8_t *pixels = (uint8_t *)baseAddress;
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            size_t offset = y * bytesPerRow + x * 4;
            pixels[offset + 0] = 0x1A; // B
            pixels[offset + 1] = 0x1A; // G
            pixels[offset + 2] = 0x1A; // R
            pixels[offset + 3] = 0xFF; // A
        }
    }

    // Draw the participant name in the center using Core Graphics.
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(baseAddress, width, height, 8,
                                             bytesPerRow,
                                             colorSpace,
                                             kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (ctx) {
        CGFloat scaleFactor = _outputSize.width / 1920.0;
        CGFloat fontSize = 36.0 * scaleFactor;

        NSDictionary *textAttrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:fontSize weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: [NSColor colorWithWhite:0.85 alpha:1.0],
        };

        NSAttributedString *attrStr = [[NSAttributedString alloc] initWithString:(identity ?: @"Participant")
                                                                      attributes:textAttrs];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attrStr);
        CGRect textBounds = CTLineGetBoundsWithOptions(line, 0);

        CGFloat textX = (width - textBounds.size.width) / 2.0 - textBounds.origin.x;
        CGFloat textY = (height - textBounds.size.height) / 2.0 - textBounds.origin.y;

        CGContextSetTextPosition(ctx, textX, textY);
        CTLineDraw(line, ctx);
        CFRelease(line);
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(colorSpace);

    CVPixelBufferUnlockBaseAddress(buffer, 0);

    // Transfer ownership of buffer to the cache. __bridge_transfer hands the +1
    // retain from CVPixelBufferCreate to ARC, so the dictionary becomes the sole
    // owner. No manual CVPixelBufferRelease is needed for this buffer.
    // Retrieve the raw pointer in the same lock scope so there is no window
    // between store and read.
    CVPixelBufferRef cached = NULL;
    @synchronized (_placeholderCache) {
        _placeholderCache[identity] = (__bridge_transfer id)buffer;
        cached = (__bridge CVPixelBufferRef)_placeholderCache[identity];
    }
    return cached;
}

// ---------------------------------------------------------------------------
// MARK: - Render Composed Frame
// ---------------------------------------------------------------------------

- (CVPixelBufferRef)renderComposedFrame {
#if DEBUG
    if (self.designatedRenderQueue) {
        dispatch_assert_queue(self.designatedRenderQueue);
    }
#endif
    if (_invalidated || !_opaquePipelineState) return NULL;

    // ---- 1. Snapshot frame state under lock ----
    CVPixelBufferRef screenShare = NULL;
    CVPixelBufferRef activeSpeaker = NULL;
    CVPixelBufferRef secondarySpeaker = NULL;
    InterComposedLayout layout;
    // Grid snapshot: ordered list of (identity, pixelBuffer) pairs.
    NSArray<NSString *> *gridOrder = nil;
    NSMutableArray *gridBuffers = nil;  // Parallel array of retained CVPixelBufferRef via ARC id.

    os_unfair_lock_lock(&_frameLock);
    screenShare    = _screenSharePixelBuffer    ? CVBufferRetain(_screenSharePixelBuffer)    : NULL;
    activeSpeaker  = _activeSpeakerPixelBuffer  ? CVBufferRetain(_activeSpeakerPixelBuffer)  : NULL;
    secondarySpeaker = _secondarySpeakerPixelBuffer ? CVBufferRetain(_secondarySpeakerPixelBuffer) : NULL;
    layout = _currentLayout;

    if (layout == InterComposedLayoutGrid || layout == InterComposedLayoutScreenShareFilmstrip) {
        gridOrder = [_gridParticipantOrder copy];
        gridBuffers = [NSMutableArray arrayWithCapacity:gridOrder.count];
        for (NSString *identity in gridOrder) {
            id frame = _gridFrames[identity];
            if (frame) {
                // Retain the pixel buffer for rendering outside the lock.
                CVPixelBufferRef pb = (__bridge CVPixelBufferRef)frame;
                [gridBuffers addObject:(__bridge_transfer id)CVBufferRetain(pb)];
            } else {
                // Will use placeholder — mark with NSNull sentinel.
                [gridBuffers addObject:[NSNull null]];
            }
        }
    }
    os_unfair_lock_unlock(&_frameLock);

    // ---- 2. Acquire pool slot ----
    NSInteger slot = _poolWriteIndex;
    _poolWriteIndex = (_poolWriteIndex + 1) % kPoolBufferCount;

    dispatch_semaphore_wait(_poolSemaphores[slot], DISPATCH_TIME_FOREVER);

    CVPixelBufferRef target = _poolBuffers[slot];
    if (!target) {
        dispatch_semaphore_signal(_poolSemaphores[slot]);
        goto cleanup;
    }

    // ---- 3. Create Metal texture from pool buffer ----
    {
        CVMetalTextureRef metalTexRef = NULL;
        CVReturn texResult = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, _textureCache, target, NULL,
            MTLPixelFormatBGRA8Unorm,
            (size_t)_outputSize.width, (size_t)_outputSize.height, 0, &metalTexRef);

        if (texResult != kCVReturnSuccess || !metalTexRef) {
            os_log_error(InterComposedRendererLog(),
                         "Failed to create render target texture: %d", texResult);
            dispatch_semaphore_signal(_poolSemaphores[slot]);
            goto cleanup;
        }

        id<MTLTexture> renderTarget = CVMetalTextureGetTexture(metalTexRef);

        // ---- 4. Encode render pass ----
        id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
        commandBuffer.label = @"InterComposedRenderer";

        MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture = renderTarget;
        rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0.03, 0.03, 0.03, 1.0);

        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:rpd];
        if (!encoder) {
            CFRelease(metalTexRef);
            dispatch_semaphore_signal(_poolSemaphores[slot]);
            goto cleanup;
        }

        [self _encodeLayout:layout
                    encoder:encoder
                screenShare:screenShare
              activeSpeaker:activeSpeaker
           secondarySpeaker:secondarySpeaker
                  gridOrder:gridOrder
                gridBuffers:gridBuffers];

        // Watermark overlay (drawn last, with alpha blending).
        if (self.watermarkEnabled) {
            [self _encodeWatermarkWithEncoder:encoder];
        }

        [encoder endEncoding];

        // ---- 5. Commit and wait for GPU completion ----
        // See recording_architecture.md §3.2: waitUntilCompleted is safe
        // because Metal compositing < 2ms and our 33ms budget has > 30ms headroom.
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];

        CFRelease(metalTexRef);
    }

    // GPU is done — signal the semaphore so this slot can be reused in 2 frames.
    dispatch_semaphore_signal(_poolSemaphores[slot]);

    // Release retained snapshots.
    if (screenShare) CVBufferRelease(screenShare);
    if (activeSpeaker) CVBufferRelease(activeSpeaker);
    if (secondarySpeaker) CVBufferRelease(secondarySpeaker);
    // gridBuffers is ARC-managed; it will be released automatically when it goes out of scope.

    // Return the pool buffer — caller (recording engine) reads the pixel data.
    // The buffer is NOT released; it stays in the pool for rotation.
    return target;

cleanup:
    if (screenShare) CVBufferRelease(screenShare);
    if (activeSpeaker) CVBufferRelease(activeSpeaker);
    if (secondarySpeaker) CVBufferRelease(secondarySpeaker);
    // gridBuffers is ARC-managed.
    return NULL;
}

// ---------------------------------------------------------------------------
// MARK: - Layout Encoding
// ---------------------------------------------------------------------------

/// Encode draw calls for the given layout. Called within an active render encoder.
- (void)_encodeLayout:(InterComposedLayout)layout
               encoder:(id<MTLRenderCommandEncoder>)encoder
           screenShare:(CVPixelBufferRef)screenShare
         activeSpeaker:(CVPixelBufferRef)activeSpeaker
      secondarySpeaker:(CVPixelBufferRef)secondarySpeaker
             gridOrder:(NSArray<NSString *> *)gridOrder
           gridBuffers:(NSArray *)gridBuffers {

    switch (layout) {
        case InterComposedLayoutIdle:
            // Clear color already set to dark; nothing else to draw.
            break;

        case InterComposedLayoutCameraOnlyFull:
            if (activeSpeaker) {
                [self _encodeTextureFromPixelBuffer:activeSpeaker
                                           encoder:encoder
                                            origin:(simd_float2){-1, -1}
                                              size:(simd_float2){2, 2}];
            }
            break;

        case InterComposedLayoutCameraSideBySide:
            // Left half — primary speaker.
            if (activeSpeaker) {
                [self _encodeTextureFromPixelBuffer:activeSpeaker
                                           encoder:encoder
                                            origin:(simd_float2){-1, -1}
                                              size:(simd_float2){1, 2}];
            }
            // Right half — secondary speaker.
            if (secondarySpeaker) {
                [self _encodeTextureFromPixelBuffer:secondarySpeaker
                                           encoder:encoder
                                            origin:(simd_float2){0, -1}
                                              size:(simd_float2){1, 2}];
            }
            break;

        case InterComposedLayoutScreenSharePiP: {
            // Screen share — fullscreen.
            if (screenShare) {
                [self _encodeTextureFromPixelBuffer:screenShare
                                           encoder:encoder
                                            origin:(simd_float2){-1, -1}
                                              size:(simd_float2){2, 2}];
            }
            // PiP — bottom-right, 20% of output width.
            if (activeSpeaker) {
                CGFloat pipW = kPiPWidthRatio * 2.0;  // In NDC (full width = 2.0).
                CGFloat pipH = pipW * (_outputSize.width / _outputSize.height) * (9.0 / 16.0);
                CGFloat padNDCx = (kPiPPadding / _outputSize.width) * 2.0;
                CGFloat padNDCy = (kPiPPadding / _outputSize.height) * 2.0;
                simd_float2 pipOrigin = {
                    (float)(1.0 - pipW - padNDCx),
                    (float)(-1.0 + padNDCy)
                };
                [self _encodeTextureFromPixelBuffer:activeSpeaker
                                           encoder:encoder
                                            origin:pipOrigin
                                              size:(simd_float2){(float)pipW, (float)pipH}];
            }
            break;
        }

        case InterComposedLayoutScreenShareOnly:
            if (screenShare) {
                [self _encodeTextureFromPixelBuffer:screenShare
                                           encoder:encoder
                                            origin:(simd_float2){-1, -1}
                                              size:(simd_float2){2, 2}];
            }
            break;

        case InterComposedLayoutGrid:
            [self _encodeGridLayout:encoder
                          gridOrder:gridOrder
                        gridBuffers:gridBuffers];
            break;

        case InterComposedLayoutScreenShareFilmstrip:
            [self _encodeScreenShareFilmstripLayout:encoder
                                        screenShare:screenShare
                                          gridOrder:gridOrder
                                        gridBuffers:gridBuffers];
            break;
    }
}

// ---------------------------------------------------------------------------
// MARK: - Grid Layout Encoding (NxM)
// ---------------------------------------------------------------------------

/// Calculate grid dimensions (cols, rows) for a given count, optimized for 16:9 output.
static void InterGridDimensions(NSUInteger count, NSUInteger *outCols, NSUInteger *outRows) {
    // Optimal grid for 16:9: prefer wider rectangles.
    if (count <= 1) { *outCols = 1; *outRows = 1; }
    else if (count <= 2) { *outCols = 2; *outRows = 1; }
    else if (count <= 4) { *outCols = 2; *outRows = 2; }
    else if (count <= 6) { *outCols = 3; *outRows = 2; }
    else if (count <= 9) { *outCols = 3; *outRows = 3; }
    else if (count <= 12) { *outCols = 4; *outRows = 3; }
    else if (count <= 16) { *outCols = 4; *outRows = 4; }
    else if (count <= 20) { *outCols = 5; *outRows = 4; }
    else if (count <= 25) { *outCols = 5; *outRows = 5; }
    else { // 26+: dynamic calculation
        NSUInteger cols = (NSUInteger)ceil(sqrt((double)count * 16.0 / 9.0));
        NSUInteger rows = (NSUInteger)ceil((double)count / (double)cols);
        *outCols = cols;
        *outRows = rows;
    }
}

/// Encode an NxM grid of participant camera frames (or placeholders).
- (void)_encodeGridLayout:(id<MTLRenderCommandEncoder>)encoder
                gridOrder:(NSArray<NSString *> *)gridOrder
              gridBuffers:(NSArray *)gridBuffers {
    NSUInteger count = gridOrder.count;
    if (count == 0) return;

    NSUInteger cols, rows;
    InterGridDimensions(count, &cols, &rows);

    // Each cell in NDC: total width = 2.0 (-1..1), total height = 2.0 (-1..1).
    // Add 1px gap between cells: gap in NDC.
    CGFloat gapPixels = 2.0;
    CGFloat gapNDCx = (gapPixels / _outputSize.width) * 2.0;
    CGFloat gapNDCy = (gapPixels / _outputSize.height) * 2.0;

    CGFloat totalGapX = gapNDCx * (CGFloat)(cols - 1);
    CGFloat totalGapY = gapNDCy * (CGFloat)(rows - 1);

    CGFloat cellW = (2.0 - totalGapX) / (CGFloat)cols;
    CGFloat cellH = (2.0 - totalGapY) / (CGFloat)rows;

    for (NSUInteger i = 0; i < count; i++) {
        NSUInteger col = i % cols;
        NSUInteger row = i / cols;

        // NDC origin: bottom-left is (-1, -1), top-left is (-1, 1).
        // Row 0 = top of screen → NDC y = 1 - cellH.
        CGFloat originX = -1.0 + (CGFloat)col * (cellW + gapNDCx);
        CGFloat originY = 1.0 - (CGFloat)(row + 1) * cellH - (CGFloat)row * gapNDCy;

        // Center the last row if it's not full.
        NSUInteger lastRowStart = (rows - 1) * cols;
        if (i >= lastRowStart) {
            NSUInteger lastRowCount = count - lastRowStart;
            if (lastRowCount < cols) {
                CGFloat emptySpace = (CGFloat)(cols - lastRowCount) * (cellW + gapNDCx);
                originX += emptySpace / 2.0;
            }
        }

        id bufferObj = gridBuffers[i];
        CVPixelBufferRef pb = NULL;
        if (bufferObj != [NSNull null]) {
            pb = (__bridge CVPixelBufferRef)bufferObj;
        } else {
            // Use placeholder for this participant.
            pb = [self placeholderFrameForIdentity:gridOrder[i]];
        }

        if (pb) {
            [self _encodeTextureFromPixelBuffer:pb
                                       encoder:encoder
                                        origin:(simd_float2){(float)originX, (float)originY}
                                          size:(simd_float2){(float)cellW, (float)cellH}];
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Screen Share + Filmstrip Layout
// ---------------------------------------------------------------------------

static const CGFloat kFilmstripWidthRatio = 0.20;  // Filmstrip takes 20% of width.

/// Encode screen share (main stage, 80% width) + participant filmstrip (right 20%).
- (void)_encodeScreenShareFilmstripLayout:(id<MTLRenderCommandEncoder>)encoder
                              screenShare:(CVPixelBufferRef)screenShare
                                gridOrder:(NSArray<NSString *> *)gridOrder
                              gridBuffers:(NSArray *)gridBuffers {
    // Screen share occupies the left 80% of the frame.
    CGFloat stageW = 2.0 * (1.0 - kFilmstripWidthRatio);  // In NDC.
    if (screenShare) {
        [self _encodeTextureFromPixelBuffer:screenShare
                                   encoder:encoder
                                    origin:(simd_float2){-1.0, -1.0}
                                      size:(simd_float2){(float)stageW, 2.0}];
    }

    // Filmstrip: right 20%, stacked vertically.
    NSUInteger count = gridOrder.count;
    if (count == 0) return;

    CGFloat filmstripX = -1.0 + stageW;
    CGFloat filmstripW = 2.0 * kFilmstripWidthRatio;  // NDC width.

    // Gap between filmstrip tiles.
    CGFloat gapPixels = 2.0;
    CGFloat gapNDCy = (gapPixels / _outputSize.height) * 2.0;

    // Cap visible tiles to avoid impossibly small thumbnails.
    NSUInteger maxVisible = MIN(count, 6);
    CGFloat totalGap = gapNDCy * (CGFloat)(maxVisible - 1);
    CGFloat tileH = (2.0 - totalGap) / (CGFloat)maxVisible;

    for (NSUInteger i = 0; i < maxVisible; i++) {
        CGFloat originY = 1.0 - (CGFloat)(i + 1) * tileH - (CGFloat)i * gapNDCy;

        id bufferObj = gridBuffers[i];
        CVPixelBufferRef pb = NULL;
        if (bufferObj != [NSNull null]) {
            pb = (__bridge CVPixelBufferRef)bufferObj;
        } else {
            pb = [self placeholderFrameForIdentity:gridOrder[i]];
        }

        if (pb) {
            [self _encodeTextureFromPixelBuffer:pb
                                       encoder:encoder
                                        origin:(simd_float2){(float)filmstripX, (float)originY}
                                          size:(simd_float2){(float)filmstripW, (float)tileH}];
        }
    }
}

/// Encode a single textured quad from a CVPixelBuffer.
- (void)_encodeTextureFromPixelBuffer:(CVPixelBufferRef)pixelBuffer
                              encoder:(id<MTLRenderCommandEncoder>)encoder
                               origin:(simd_float2)origin
                                 size:(simd_float2)size {
    if (!pixelBuffer) return;

    // Handle NV12 → BGRA conversion if needed.
    CVPixelBufferRef bgraBuffer = [self _ensureBGRAPixelBuffer:pixelBuffer];
    if (!bgraBuffer) return;

    CVMetalTextureRef metalTexRef = NULL;
    size_t width = CVPixelBufferGetWidth(bgraBuffer);
    size_t height = CVPixelBufferGetHeight(bgraBuffer);

    CVReturn result = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, _textureCache, bgraBuffer, NULL,
        MTLPixelFormatBGRA8Unorm, width, height, 0, &metalTexRef);

    // If we created a converted buffer, release it.
    if (bgraBuffer != pixelBuffer) {
        CVPixelBufferRelease(bgraBuffer);
    }

    if (result != kCVReturnSuccess || !metalTexRef) return;

    id<MTLTexture> texture = CVMetalTextureGetTexture(metalTexRef);

    [encoder setRenderPipelineState:_opaquePipelineState];
    CompositorQuadParams params = { .origin = origin, .size = size };
    [encoder setVertexBytes:&params length:sizeof(params) atIndex:0];
    [encoder setFragmentTexture:texture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];

    CFRelease(metalTexRef);
}

/// Ensure the pixel buffer is in BGRA format. If NV12/420v, convert via CIContext.
/// Returns a retained CVPixelBuffer (caller must release if different from input).
- (CVPixelBufferRef)_ensureBGRAPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    OSType format = CVPixelBufferGetPixelFormatType(pixelBuffer);
    if (format == kCVPixelFormatType_32BGRA) {
        return pixelBuffer;  // Already BGRA — no conversion needed.
    }

    // NV12 (420v / 420f) → BGRA via CIContext.
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    if (!ciImage) return NULL;

    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);

    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };

    CVPixelBufferRef bgraBuffer = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                        kCVPixelFormatType_32BGRA,
                        (__bridge CFDictionaryRef)attrs, &bgraBuffer);
    if (!bgraBuffer) return NULL;

    [_ciContext render:ciImage toCVPixelBuffer:bgraBuffer];
    return bgraBuffer;  // Caller must release if != input.
}

// ---------------------------------------------------------------------------
// MARK: - Watermark
// ---------------------------------------------------------------------------

- (void)_encodeWatermarkWithEncoder:(id<MTLRenderCommandEncoder>)encoder {
    if (!_alphaPipelineState) return;

    // Lazily generate the watermark texture.
    if (!_watermarkTexture) {
        [self _generateWatermarkTexture];
    }
    if (!_watermarkTexture) return;

    [encoder setRenderPipelineState:_alphaPipelineState];

    // Position: bottom-left, 15% from edge.
    CGFloat scaleFactor = _outputSize.width / 1920.0;
    CGFloat wmW = (200.0 * scaleFactor / _outputSize.width) * 2.0;
    CGFloat wmH = (50.0 * scaleFactor / _outputSize.height) * 2.0;
    CGFloat padX = (0.15 * _outputSize.width / _outputSize.width) * 2.0;  // 15% from left in NDC.
    CGFloat padY = (0.05 * _outputSize.height / _outputSize.height) * 2.0; // 5% from bottom.

    CompositorQuadParams params = {
        .origin = { (float)(-1.0 + padX), (float)(-1.0 + padY) },
        .size = { (float)wmW, (float)wmH },
    };
    [encoder setVertexBytes:&params length:sizeof(params) atIndex:0];

    float alpha = 0.3f;
    [encoder setFragmentBytes:&alpha length:sizeof(alpha) atIndex:0];
    [encoder setFragmentTexture:_watermarkTexture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

- (void)_generateWatermarkTexture {
    CGFloat scaleFactor = _outputSize.width / 1920.0;
    NSInteger wmWidth = (NSInteger)ceil(200.0 * scaleFactor);
    NSInteger wmHeight = (NSInteger)ceil(50.0 * scaleFactor);

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    size_t bytesPerRow = wmWidth * 4;
    uint8_t *pixelData = calloc(bytesPerRow * wmHeight, 1);  // Transparent black.
    if (!pixelData) { CGColorSpaceRelease(colorSpace); return; }

    CGContextRef ctx = CGBitmapContextCreate(pixelData, wmWidth, wmHeight, 8,
                                             bytesPerRow, colorSpace,
                                             kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (ctx) {
        CGFloat fontSize = 36.0 * scaleFactor;
        NSDictionary *textAttrs = @{
            NSFontAttributeName: [NSFont boldSystemFontOfSize:fontSize],
            NSForegroundColorAttributeName: [NSColor whiteColor],
        };
        NSAttributedString *attrStr = [[NSAttributedString alloc] initWithString:@"Inter"
                                                                      attributes:textAttrs];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attrStr);
        CGRect textBounds = CTLineGetBoundsWithOptions(line, 0);

        CGFloat textX = (wmWidth - textBounds.size.width) / 2.0 - textBounds.origin.x;
        CGFloat textY = (wmHeight - textBounds.size.height) / 2.0 - textBounds.origin.y;

        CGContextSetTextPosition(ctx, textX, textY);
        CTLineDraw(line, ctx);
        CFRelease(line);
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(colorSpace);

    MTLTextureDescriptor *texDesc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                          width:wmWidth
                                                         height:wmHeight
                                                      mipmapped:NO];
    texDesc.usage = MTLTextureUsageShaderRead;
    _watermarkTexture = [_device newTextureWithDescriptor:texDesc];
    [_watermarkTexture replaceRegion:MTLRegionMake2D(0, 0, wmWidth, wmHeight)
                         mipmapLevel:0
                           withBytes:pixelData
                         bytesPerRow:bytesPerRow];

    _watermarkSize = CGSizeMake(wmWidth, wmHeight);
    free(pixelData);
}

@end
