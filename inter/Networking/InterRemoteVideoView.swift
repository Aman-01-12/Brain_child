// ============================================================================
// InterRemoteVideoView.swift
// inter
//
// Phase 1.11 [G3] — Metal-accelerated NSView for remote video rendering.
//
// Renders CVPixelBuffer frames from remote participants using CVMetalTextureCache
// for zero-copy GPU access (IOSurface shared memory). Supports two pixel formats:
//   • NV12 (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange or FullRange)
//   • BGRA (kCVPixelFormatType_32BGRA)
//
// RENDERING PIPELINE:
// 1. updateFrame(_ pixelBuffer:) is called from the subscriber (WebRTC decode thread)
// 2. os_unfair_lock stores pixel buffer in single slot (latest-frame-wins)
// 3. CVDisplayLink fires at display refresh rate
// 4. Render callback reads from single slot, creates Metal textures via
//    CVMetalTextureCacheCreateTextureFromImage (zero-copy), draws fullscreen triangle
// 5. NV12: Y plane (r8Unorm) + CbCr plane (rg8Unorm) → BT.709 matrix → sRGB
//    BGRA: direct passthrough texture sample
//
// MEMORY: 4–8 MB per view (Metal textures share backing IOSurface).
//
// THREADING:
// - updateFrame: any thread (os_unfair_lock, <100ns)
// - CVDisplayLink callback: display link thread (render, ~2ms)
// - All Metal work on the display link callback
// ============================================================================

import Cocoa
import Metal
import MetalKit
import CoreVideo
import QuartzCore
import os.log

// MARK: - BT.709 Color Matrix

/// BT.709 video-range YCbCr → RGB conversion matrix.
/// Accounts for Y range [16, 235] and CbCr range [16, 240].
///
/// Matrix columns:
/// | R |   | 1.1644  0.0000  1.7927 -0.9729 | | Y  |
/// | G | = | 1.1644 -0.2132 -0.5329  0.3015 | | Cb |
/// | B |   | 1.1644  2.1124  0.0000 -1.1334 | | Cr |
/// | A |   | 0.0000  0.0000  0.0000  1.0000 | | 1  |
/// Internal (not private) for unit test access via @testable import.
let bt709VideoRangeMatrix: [Float] = [
    // Column-major for Metal float4x4
    1.1644, 1.1644, 1.1644, 0.0,   // Column 0 (Y coefficients)
    0.0,   -0.2132, 2.1124, 0.0,   // Column 1 (Cb coefficients)
    1.7927,-0.5329, 0.0,    0.0,   // Column 2 (Cr coefficients)
   -0.9729, 0.3015,-1.1334, 1.0    // Column 3 (offsets)
]

/// BT.709 full-range YCbCr → RGB. Y in [0, 255], CbCr in [0, 255].
let bt709FullRangeMatrix: [Float] = [
    1.0,    1.0,    1.0,    0.0,
    0.0,   -0.1873, 1.8556, 0.0,
    1.5748,-0.4681, 0.0,    0.0,
   -0.7874, 0.3290,-0.9278, 1.0
]

// MARK: - Detected Format

/// Pixel format classification for pipeline selection.
/// Internal for unit test access via @testable import.
enum DetectedFormat {
    case nv12VideoRange
    case nv12FullRange
    case bgra
    case unknown
}

// MARK: - InterRemoteVideoView

@objc public class InterRemoteVideoView: NSView {

    // MARK: - Public Properties

    /// Whether the view has ever received a frame.
    @objc public private(set) var hasReceivedFrame: Bool = false

    // MARK: - Metal State

    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var metalLayer: CAMetalLayer!
    private var textureCache: CVMetalTextureCache?
    private(set) var nv12PipelineState: MTLRenderPipelineState?
    private(set) var bgraPipelineState: MTLRenderPipelineState?

    // MARK: - Frame Storage

    /// Single-slot pixel buffer (latest-frame-wins). [1.8.9 / 1.11.10]
    private var lock = os_unfair_lock()
    private var pendingPixelBuffer: CVPixelBuffer?
    private var lastRenderedPixelBuffer: CVPixelBuffer?

    // MARK: - Format Detection [G3]

    /// Detected format (set on first frame, assumed stable).
    private var detectedFormat: DetectedFormat = .unknown

    // MARK: - Display Link

    private var displayLink: CVDisplayLink?
    private var renderSemaphore = DispatchSemaphore(value: 2)

    // MARK: - Init

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true

        // Reuse the shared engine's device and command queue [1.11.2]
        let engine = MetalRenderEngine.shared()
        device = engine.device
        commandQueue = engine.commandQueue

        guard device != nil, commandQueue != nil else {
            interLogError(InterLog.media, "RemoteVideoView: Metal device unavailable")
            return
        }

        // Create the CAMetalLayer
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        self.layer = layer
        self.metalLayer = layer

        // Create texture cache [1.11.3]
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        if status == kCVReturnSuccess {
            self.textureCache = cache
        } else {
            interLogError(InterLog.media, "RemoteVideoView: failed to create texture cache (status=%d)", status)
        }

        // Build pipelines
        buildPipelines()

        // Start display link [1.11.4]
        startDisplayLink()
    }

    deinit {
        stopDisplayLink()
    }

    // MARK: - Frame Input [1.11.10]

    /// Store a new pixel buffer for rendering. Called from any thread.
    /// Uses os_unfair_lock for minimal latency (<100ns). Latest-frame-wins.
    @objc public func updateFrame(_ pixelBuffer: CVPixelBuffer) {
        // Detect format on first frame [G3 / 1.11.8]
        if !hasReceivedFrame {
            let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
            detectedFormat = classifyFormat(format)
            hasReceivedFrame = true
            interLogInfo(InterLog.media, "RemoteVideoView: first frame format=%{public}@ (%dx%d)",
                         formatName(format),
                         CVPixelBufferGetWidth(pixelBuffer),
                         CVPixelBufferGetHeight(pixelBuffer))
        }

        os_unfair_lock_lock(&lock)
        pendingPixelBuffer = pixelBuffer
        os_unfair_lock_unlock(&lock)
    }

    /// Clear the current frame so the view renders black.
    /// Called when the remote participant mutes their camera.
    @objc public func clearFrame() {
        os_unfair_lock_lock(&lock)
        pendingPixelBuffer = nil
        lastRenderedPixelBuffer = nil
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - Layout

    public override func layout() {
        super.layout()
        metalLayer?.frame = bounds
        metalLayer?.drawableSize = CGSize(
            width: bounds.width * (metalLayer?.contentsScale ?? 2.0),
            height: bounds.height * (metalLayer?.contentsScale ?? 2.0)
        )
    }

    // MARK: - Display Link [1.11.4]

    private func startDisplayLink() {
        guard displayLink == nil else { return }

        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link = link else {
            interLogError(InterLog.media, "RemoteVideoView: failed to create display link")
            return
        }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo -> CVReturn in
            guard let userInfo = userInfo else { return kCVReturnError }
            let view = Unmanaged<InterRemoteVideoView>.fromOpaque(userInfo).takeUnretainedValue()
            view.displayLinkCallback()
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(link)
        self.displayLink = link
    }

    private func stopDisplayLink() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
    }

    /// Called on the display link thread at screen refresh rate.
    private func displayLinkCallback() {
        // Semaphore limits in-flight frames to 2 [1.11.4]
        guard renderSemaphore.wait(timeout: .now()) == .success else { return }

        // Grab the latest frame (or re-present the last one) [1.11.11]
        os_unfair_lock_lock(&lock)
        let pixelBuffer = pendingPixelBuffer ?? lastRenderedPixelBuffer
        if pendingPixelBuffer != nil {
            lastRenderedPixelBuffer = pendingPixelBuffer
            pendingPixelBuffer = nil
        }
        os_unfair_lock_unlock(&lock)

        guard let buffer = pixelBuffer else {
            // Never-set: render black [1.11.11]
            renderBlack()
            renderSemaphore.signal()
            return
        }

        render(pixelBuffer: buffer)
    }

    // MARK: - Rendering

    private func render(pixelBuffer: CVPixelBuffer) {
        guard let drawable = metalLayer?.nextDrawable() else {
            renderSemaphore.signal()
            return
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            renderSemaphore.signal()
            return
        }

        let semaphore = renderSemaphore
        commandBuffer.addCompletedHandler { _ in
            semaphore.signal()
        }

        let format = detectedFormat

        switch format {
        case .nv12VideoRange, .nv12FullRange:
            renderNV12(pixelBuffer: pixelBuffer,
                       isFullRange: format == .nv12FullRange,
                       drawable: drawable,
                       commandBuffer: commandBuffer)
        case .bgra:
            renderBGRA(pixelBuffer: pixelBuffer,
                       drawable: drawable,
                       commandBuffer: commandBuffer)
        case .unknown:
            // Fallback: try BGRA passthrough
            renderBGRA(pixelBuffer: pixelBuffer,
                       drawable: drawable,
                       commandBuffer: commandBuffer)
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Render NV12 pixel buffer (Y + CbCr planes, BT.709 color conversion). [1.11.5]
    private func renderNV12(
        pixelBuffer: CVPixelBuffer,
        isFullRange: Bool,
        drawable: CAMetalDrawable,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let cache = textureCache,
              let pipeline = nv12PipelineState else {
            renderSemaphore.signal()
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Y plane (r8Unorm) — plane 0 [1.11.5]
        var yTextureRef: CVMetalTexture?
        let yStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .r8Unorm, width, height, 0, &yTextureRef
        )

        // CbCr plane (rg8Unorm) — plane 1 [1.11.5]
        var cbcrTextureRef: CVMetalTexture?
        let cbcrStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .rg8Unorm, width / 2, height / 2, 1, &cbcrTextureRef
        )

        guard yStatus == kCVReturnSuccess, cbcrStatus == kCVReturnSuccess,
              let yTex = yTextureRef.flatMap({ CVMetalTextureGetTexture($0) }),
              let cbcrTex = cbcrTextureRef.flatMap({ CVMetalTextureGetTexture($0) }) else {
            return
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(yTex, index: 0)
        encoder.setFragmentTexture(cbcrTex, index: 1)

        // Pass the color matrix as fragment bytes [1.11.6]
        let matrix = isFullRange ? bt709FullRangeMatrix : bt709VideoRangeMatrix
        matrix.withUnsafeBufferPointer { ptr in
            encoder.setFragmentBytes(ptr.baseAddress!, length: MemoryLayout<Float>.stride * 16, index: 0)
        }

        // Pass aspect-fit uniforms [1.11.9]
        var aspectUniforms = computeAspectFitUniforms(
            videoWidth: Float(width),
            videoHeight: Float(height),
            viewWidth: Float(drawable.texture.width),
            viewHeight: Float(drawable.texture.height)
        )
        encoder.setVertexBytes(&aspectUniforms, length: MemoryLayout<AspectFitUniforms>.stride, index: 0)

        // Quad (4 vertices, triangle strip) [1.11.5]
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    /// Render BGRA pixel buffer (direct texture sample passthrough). [1.11.5]
    private func renderBGRA(
        pixelBuffer: CVPixelBuffer,
        drawable: CAMetalDrawable,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let cache = textureCache,
              let pipeline = bgraPipelineState else {
            renderSemaphore.signal()
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var textureRef: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &textureRef
        )

        guard status == kCVReturnSuccess,
              let texture = textureRef.flatMap({ CVMetalTextureGetTexture($0) }) else {
            return
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)

        // Aspect-fit uniforms [1.11.9]
        var aspectUniforms = computeAspectFitUniforms(
            videoWidth: Float(width),
            videoHeight: Float(height),
            viewWidth: Float(drawable.texture.width),
            viewHeight: Float(drawable.texture.height)
        )
        encoder.setVertexBytes(&aspectUniforms, length: MemoryLayout<AspectFitUniforms>.stride, index: 0)

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    /// Render a black frame when no content is available. [1.11.11]
    private func renderBlack() {
        guard let drawable = metalLayer?.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Offscreen Rendering (Testing) [1.11.13]

    /// Render a pixel buffer to an offscreen Metal texture for test validation.
    /// Internal access for unit tests via @testable import.
    func renderToOffscreenTexture(pixelBuffer: CVPixelBuffer,
                                  outputWidth: Int,
                                  outputHeight: Int) -> MTLTexture? {
        guard let device = device,
              let commandQueue = commandQueue,
              textureCache != nil else { return nil }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: outputWidth,
            height: outputHeight,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        #if arch(x86_64)
        desc.storageMode = .managed   // Intel: managed for CPU readback
        #else
        desc.storageMode = .shared    // Apple Silicon: shared memory
        #endif

        guard let outputTexture = device.makeTexture(descriptor: desc),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }

        let format = classifyFormat(CVPixelBufferGetPixelFormatType(pixelBuffer))

        switch format {
        case .nv12VideoRange, .nv12FullRange:
            renderNV12Offscreen(pixelBuffer: pixelBuffer,
                                isFullRange: format == .nv12FullRange,
                                outputTexture: outputTexture,
                                commandBuffer: commandBuffer)
        case .bgra, .unknown:
            renderBGRAOffscreen(pixelBuffer: pixelBuffer,
                                outputTexture: outputTexture,
                                commandBuffer: commandBuffer)
        }

        // Synchronize managed texture for CPU readback (Intel only)
        #if arch(x86_64)
        if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.synchronize(resource: outputTexture)
            blitEncoder.endEncoding()
        }
        #endif

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return outputTexture
    }

    private func renderNV12Offscreen(pixelBuffer: CVPixelBuffer,
                                     isFullRange: Bool,
                                     outputTexture: MTLTexture,
                                     commandBuffer: MTLCommandBuffer) {
        guard let cache = textureCache, let pipeline = nv12PipelineState else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var yTextureRef: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .r8Unorm, width, height, 0, &yTextureRef)

        var cbcrTextureRef: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .rg8Unorm, width / 2, height / 2, 1, &cbcrTextureRef)

        guard let yTex = yTextureRef.flatMap({ CVMetalTextureGetTexture($0) }),
              let cbcrTex = cbcrTextureRef.flatMap({ CVMetalTextureGetTexture($0) }) else { return }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = outputTexture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(yTex, index: 0)
        encoder.setFragmentTexture(cbcrTex, index: 1)

        let matrix = isFullRange ? bt709FullRangeMatrix : bt709VideoRangeMatrix
        matrix.withUnsafeBufferPointer { ptr in
            encoder.setFragmentBytes(ptr.baseAddress!, length: MemoryLayout<Float>.stride * 16, index: 0)
        }

        var aspectUniforms = computeAspectFitUniforms(
            videoWidth: Float(width), videoHeight: Float(height),
            viewWidth: Float(outputTexture.width), viewHeight: Float(outputTexture.height))
        encoder.setVertexBytes(&aspectUniforms, length: MemoryLayout<AspectFitUniforms>.stride, index: 0)

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    private func renderBGRAOffscreen(pixelBuffer: CVPixelBuffer,
                                     outputTexture: MTLTexture,
                                     commandBuffer: MTLCommandBuffer) {
        guard let cache = textureCache, let pipeline = bgraPipelineState else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var textureRef: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &textureRef)

        guard let texture = textureRef.flatMap({ CVMetalTextureGetTexture($0) }) else { return }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = outputTexture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)

        var aspectUniforms = computeAspectFitUniforms(
            videoWidth: Float(width), videoHeight: Float(height),
            viewWidth: Float(outputTexture.width), viewHeight: Float(outputTexture.height))
        encoder.setVertexBytes(&aspectUniforms, length: MemoryLayout<AspectFitUniforms>.stride, index: 0)

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    // MARK: - Pipeline Construction [1.11.5]

    private func buildPipelines() {
        guard device != nil else { return }

        let shaderSource = Self.metalShaderSource

        guard let library = try? device.makeLibrary(source: shaderSource, options: nil) else {
            interLogError(InterLog.media, "RemoteVideoView: failed to compile Metal shaders")
            return
        }

        // NV12 pipeline
        do {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "interRemoteVertexShader")
            desc.fragmentFunction = library.makeFunction(name: "interRemoteNV12FragmentShader")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            nv12PipelineState = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            interLogError(InterLog.media, "RemoteVideoView: NV12 pipeline failed: %{public}@",
                          error.localizedDescription)
        }

        // BGRA pipeline
        do {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "interRemoteVertexShader")
            desc.fragmentFunction = library.makeFunction(name: "interRemoteBGRAFragmentShader")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            bgraPipelineState = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            interLogError(InterLog.media, "RemoteVideoView: BGRA pipeline failed: %{public}@",
                          error.localizedDescription)
        }
    }

    // MARK: - Aspect Fit [1.11.9]

    struct AspectFitUniforms {
        var scaleX: Float
        var scaleY: Float
        var offsetX: Float
        var offsetY: Float
    }

    func computeAspectFitUniforms(
        videoWidth: Float,
        videoHeight: Float,
        viewWidth: Float,
        viewHeight: Float
    ) -> AspectFitUniforms {
        guard videoWidth > 0, videoHeight > 0, viewWidth > 0, viewHeight > 0 else {
            return AspectFitUniforms(scaleX: 1, scaleY: 1, offsetX: 0, offsetY: 0)
        }

        let videoAspect = videoWidth / videoHeight
        let viewAspect = viewWidth / viewHeight

        var scaleX: Float = 1
        var scaleY: Float = 1

        if videoAspect > viewAspect {
            // Video wider than view: letterbox (bars top/bottom)
            scaleY = viewAspect / videoAspect
        } else {
            // Video taller than view: pillarbox (bars left/right)
            scaleX = videoAspect / viewAspect
        }

        return AspectFitUniforms(scaleX: scaleX, scaleY: scaleY, offsetX: 0, offsetY: 0)
    }

    // MARK: - Format Detection [G3 / 1.11.8]

    func classifyFormat(_ format: OSType) -> DetectedFormat {
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return .nv12VideoRange
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return .nv12FullRange
        case kCVPixelFormatType_32BGRA:
            return .bgra
        default:
            interLogError(InterLog.media, "RemoteVideoView: unknown pixel format: %d", format)
            return .unknown
        }
    }

    private func formatName(_ format: OSType) -> String {
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return "NV12-VideoRange"
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return "NV12-FullRange"
        case kCVPixelFormatType_32BGRA:
            return "BGRA"
        default:
            return "Unknown(\(format))"
        }
    }

    // MARK: - Inline MSL Shaders [1.11.5]

    /// Metal Shading Language source compiled at runtime.
    /// Fullscreen triangle vertex shader + NV12/BGRA fragment shaders.
    private static let metalShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct AspectFitUniforms {
        float scaleX;
        float scaleY;
        float offsetX;
        float offsetY;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    // Quad vertex shader: 4 vertices forming a triangle strip.
    // Positions are scaled by aspect-fit uniforms; UVs map exactly [0,1].
    vertex VertexOut interRemoteVertexShader(
        uint vertexID [[vertex_id]],
        constant AspectFitUniforms &uniforms [[buffer(0)]]
    ) {
        float2 positions[4] = {
            float2(-1.0, -1.0),
            float2( 1.0, -1.0),
            float2(-1.0,  1.0),
            float2( 1.0,  1.0)
        };

        float2 texCoords[4] = {
            float2(0.0, 1.0),
            float2(1.0, 1.0),
            float2(0.0, 0.0),
            float2(1.0, 0.0)
        };

        VertexOut out;
        float2 pos = positions[vertexID];
        pos.x *= uniforms.scaleX;
        pos.y *= uniforms.scaleY;
        out.position = float4(pos, 0.0, 1.0);
        out.texCoord = texCoords[vertexID];
        return out;
    }

    // NV12 fragment shader: samples Y (r8Unorm) and CbCr (rg8Unorm) textures,
    // applies BT.709 color matrix to convert to sRGB. [1.11.5, 1.11.6]
    fragment float4 interRemoteNV12FragmentShader(
        VertexOut in [[stage_in]],
        texture2d<float> yTexture [[texture(0)]],
        texture2d<float> cbcrTexture [[texture(1)]],
        constant float4x4 &colorMatrix [[buffer(0)]]
    ) {
        constexpr sampler textureSampler(mag_filter::linear, min_filter::linear,
                                         address::clamp_to_edge);

        float y = yTexture.sample(textureSampler, in.texCoord).r;
        float2 cbcr = cbcrTexture.sample(textureSampler, in.texCoord).rg;

        float4 ycbcr = float4(y, cbcr.x, cbcr.y, 1.0);
        float4 rgb = colorMatrix * ycbcr;

        return float4(rgb.rgb, 1.0);
    }

    // BGRA passthrough fragment shader: direct texture sample. [1.11.5]
    fragment float4 interRemoteBGRAFragmentShader(
        VertexOut in [[stage_in]],
        texture2d<float> texture [[texture(0)]]
    ) {
        constexpr sampler textureSampler(mag_filter::linear, min_filter::linear,
                                         address::clamp_to_edge);
        return texture.sample(textureSampler, in.texCoord);
    }
    """
}
