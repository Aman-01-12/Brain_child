#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

@interface MetalRenderEngine : NSObject

@property (nonatomic, readonly) id<MTLDevice> device;
@property (nonatomic, readonly) id<MTLCommandQueue> commandQueue;
@property (atomic, readonly, getter=isPipelineReady) BOOL pipelineReady;

+ (instancetype)sharedEngine;

- (void)encodeCompositePassToCaptureTexture:(id<MTLTexture>)captureTexture
                              commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                               drawableSize:(CGSize)drawableSize;

- (void)encodePresentPassFromCaptureTexture:(id<MTLTexture>)captureTexture
                          toDrawableTexture:(id<MTLTexture>)drawableTexture
                              commandBuffer:(id<MTLCommandBuffer>)commandBuffer;

@end

NS_ASSUME_NONNULL_END
