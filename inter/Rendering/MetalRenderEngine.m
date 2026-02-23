#import "MetalRenderEngine.h"

#import <simd/simd.h>

typedef struct InterCompositeUniforms {
    float timeSeconds;
} InterCompositeUniforms;

@interface MetalRenderEngine ()
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (atomic, assign, readwrite, getter=isPipelineReady) BOOL pipelineReady;
@end

@implementation MetalRenderEngine {
    dispatch_queue_t _stateQueue;
    id<MTLRenderPipelineState> _composePipelineState;
    id<MTLRenderPipelineState> _presentPipelineState;

    CFAbsoluteTime _startTime;
}

+ (instancetype)sharedEngine {
    static MetalRenderEngine *sharedEngine = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedEngine = [[MetalRenderEngine alloc] initPrivate];
    });
    return sharedEngine;
}

- (instancetype)init {
    [NSException raise:@"SingletonOnly"
                format:@"Use +[MetalRenderEngine sharedEngine]."];
    return nil;
}

- (instancetype)initPrivate {
    self = [super init];
    if (!self) {
        return nil;
    }

    _stateQueue = dispatch_queue_create("secure.inter.metal.render.engine.state",
                                        DISPATCH_QUEUE_SERIAL);
    _startTime = CFAbsoluteTimeGetCurrent();

    _device = [self selectPreferredDevice];
    _commandQueue = [_device newCommandQueue];
    _pipelineReady = NO;

    [self compilePipelinesAsynchronously];
    return self;
}

- (id<MTLDevice>)selectPreferredDevice {
    NSArray<id<MTLDevice>> *allDevices = MTLCopyAllDevices();
    id<MTLDevice> preferred = nil;

    for (id<MTLDevice> device in allDevices) {
        // Prefer a high-power non-headless device when available (discrete GPU on Intel).
        if (!device.lowPower && !device.headless) {
            preferred = device;
            break;
        }
    }

    if (!preferred) {
        preferred = MTLCreateSystemDefaultDevice();
    }
    if (!preferred && allDevices.count > 0) {
        preferred = allDevices.firstObject;
    }

    NSAssert(preferred != nil, @"Metal device selection failed.");
    return preferred;
}

- (void)compilePipelinesAsynchronously {
    static NSString *const kShaderSource =
    @"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "\n"
    "struct VertexOut {\n"
    "    float4 position [[position]];\n"
    "    float2 uv;\n"
    "};\n"
    "\n"
    "struct CompositeUniforms {\n"
    "    float timeSeconds;\n"
    "};\n"
    "\n"
    "vertex VertexOut interFullscreenVertex(uint vertexID [[vertex_id]]) {\n"
    "    const float2 positions[4] = {\n"
    "        float2(-1.0, -1.0),\n"
    "        float2( 1.0, -1.0),\n"
    "        float2(-1.0,  1.0),\n"
    "        float2( 1.0,  1.0)\n"
    "    };\n"
    "    const float2 uvs[4] = {\n"
    "        float2(0.0, 0.0),\n"
    "        float2(1.0, 0.0),\n"
    "        float2(0.0, 1.0),\n"
    "        float2(1.0, 1.0)\n"
    "    };\n"
    "    VertexOut out;\n"
    "    out.position = float4(positions[vertexID], 0.0, 1.0);\n"
    "    out.uv = uvs[vertexID];\n"
    "    return out;\n"
    "}\n"
    "\n"
    "fragment float4 interCompositeFragment(VertexOut in [[stage_in]],\n"
    "                                       constant CompositeUniforms &uniforms [[buffer(0)]]) {\n"
    "\n"
    "    float pulse = 0.08 * sin(uniforms.timeSeconds * 1.4);\n"
    "    float3 baseColor = float3(0.06 + in.uv.y * 0.14,\n"
    "                              0.08 + in.uv.x * 0.20 + pulse,\n"
    "                              0.13 + in.uv.y * 0.16);\n"
    "    return float4(baseColor, 1.0);\n"
    "}\n"
    "\n"
    "fragment float4 interPresentFragment(VertexOut in [[stage_in]],\n"
    "                                     texture2d<float> captureTexture [[texture(0)]]) {\n"
    "    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);\n"
    "    return captureTexture.sample(linearSampler, in.uv);\n"
    "}\n";

    __weak typeof(self) weakSelf = self;
    [self.device newLibraryWithSource:kShaderSource
                              options:nil
                    completionHandler:^(id<MTLLibrary> _Nullable library, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        if (!library || error) {
            NSLog(@"[MetalRenderEngine] Shader library compilation failed: %@", error.localizedDescription);
            return;
        }

        id<MTLFunction> vertexFunction = [library newFunctionWithName:@"interFullscreenVertex"];
        id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"interCompositeFragment"];
        if (!vertexFunction || !fragmentFunction) {
            NSLog(@"[MetalRenderEngine] Shader functions missing in library.");
            return;
        }

        id<MTLFunction> presentFragment = [library newFunctionWithName:@"interPresentFragment"];
        if (!presentFragment) {
            NSLog(@"[MetalRenderEngine] Present fragment function missing in library.");
            return;
        }

        MTLRenderPipelineDescriptor *composeDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
        composeDescriptor.vertexFunction = vertexFunction;
        composeDescriptor.fragmentFunction = fragmentFunction;
        composeDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

        [strongSelf.device newRenderPipelineStateWithDescriptor:composeDescriptor
                                               completionHandler:^(id<MTLRenderPipelineState> _Nullable composeState,
                                                                   NSError * _Nullable composeError) {
            if (!composeState || composeError) {
                NSLog(@"[MetalRenderEngine] Compose pipeline compilation failed: %@",
                      composeError.localizedDescription);
                return;
            }

            MTLRenderPipelineDescriptor *presentDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
            presentDescriptor.vertexFunction = vertexFunction;
            presentDescriptor.fragmentFunction = presentFragment;
            presentDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

            [strongSelf.device newRenderPipelineStateWithDescriptor:presentDescriptor
                                                   completionHandler:^(id<MTLRenderPipelineState> _Nullable presentState,
                                                                       NSError * _Nullable presentError) {
                if (!presentState || presentError) {
                    NSLog(@"[MetalRenderEngine] Present pipeline compilation failed: %@",
                          presentError.localizedDescription);
                    return;
                }

                dispatch_async(strongSelf->_stateQueue, ^{
                    strongSelf->_composePipelineState = composeState;
                    strongSelf->_presentPipelineState = presentState;
                    strongSelf.pipelineReady = YES;
                });
            }];
        }];
    }];
}

- (void)encodeCompositePassToCaptureTexture:(id<MTLTexture>)captureTexture
                              commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                               drawableSize:(CGSize)drawableSize {
    if (!captureTexture || !commandBuffer) {
        return;
    }

    __block id<MTLRenderPipelineState> pipelineState = nil;
    dispatch_sync(_stateQueue, ^{
        pipelineState = self->_composePipelineState;
    });

    MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    renderPassDescriptor.colorAttachments[0].texture = captureTexture;
    renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.03, 0.03, 0.03, 1.0);

    id<MTLRenderCommandEncoder> renderEncoder =
    [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
    if (!renderEncoder) {
        return;
    }

    if (pipelineState) {
        [renderEncoder setRenderPipelineState:pipelineState];

        InterCompositeUniforms uniforms;
        uniforms.timeSeconds = (float)(CFAbsoluteTimeGetCurrent() - _startTime);
#pragma unused(drawableSize)

        [renderEncoder setFragmentBytes:&uniforms
                                 length:sizeof(uniforms)
                                atIndex:0];
        [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                          vertexStart:0
                          vertexCount:4];
    }

    [renderEncoder endEncoding];
}

- (void)encodePresentPassFromCaptureTexture:(id<MTLTexture>)captureTexture
                          toDrawableTexture:(id<MTLTexture>)drawableTexture
                              commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    if (!captureTexture || !drawableTexture || !commandBuffer) {
        return;
    }

    __block id<MTLRenderPipelineState> presentPipelineState = nil;
    dispatch_sync(_stateQueue, ^{
        presentPipelineState = self->_presentPipelineState;
    });
    if (!presentPipelineState) {
        return;
    }

    MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    renderPassDescriptor.colorAttachments[0].texture = drawableTexture;
    renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLRenderCommandEncoder> renderEncoder =
    [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
    if (!renderEncoder) {
        return;
    }

    [renderEncoder setRenderPipelineState:presentPipelineState];
    [renderEncoder setFragmentTexture:captureTexture atIndex:0];
    [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                      vertexStart:0
                      vertexCount:4];
    [renderEncoder endEncoding];
}

@end
