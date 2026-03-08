// ============================================================================
// InterLiveKitScreenShareSource.swift
// inter
//
// Phase 1.6 — Screen share video → LiveKit network.
//
// ARCHITECTURE:
// Conforms to InterShareSink. Receives InterShareVideoFrame from the
// router queue (InterSurfaceShareController), throttles to ≤15 FPS,
// caps resolution to 1920×1080, and pushes CVPixelBuffers to LiveKit
// via BufferCapturer.
//
// ISOLATION INVARIANT [G8]:
// All errors are caught and logged. If this sink fails, screen capture
// and recording continue unaffected. Never propagates errors.
//
// THREADING [G5]:
// appendVideoFrame: returns in <200ns. The CVPixelBuffer is retained
// and dispatched to a private encoder queue for processing.
// ============================================================================

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import Accelerate
import os.log
import LiveKit

// MARK: - InterLiveKitScreenShareSource

@objc public class InterLiveKitScreenShareSource: NSObject, InterShareSink, @unchecked Sendable {

    // MARK: - InterShareSink conformance

    @objc public private(set) dynamic var isActive: Bool = false

    // MARK: - Public Properties

    /// The LocalVideoTrack for screen share. Non-nil while active.
    public private(set) var videoTrack: LocalVideoTrack?

    /// The underlying BufferCapturer for pushing frames.
    public private(set) var bufferCapturer: BufferCapturer?

    // MARK: - Private Properties

    /// Private serial queue for encoding/downscaling work.
    private let encoderQueue = DispatchQueue(
        label: "inter.screenshare.livekit.encode",
        qos: .userInitiated
    )

    /// Minimum interval between frames (66ms = 15 FPS).
    private let minFrameInterval: TimeInterval = 1.0 / 15.0

    /// Timestamp of the last frame sent.
    private var lastFrameTime: CFAbsoluteTime = 0

    /// Resolution cap: frames larger than this are downscaled.
    private let maxWidth: Int = 1920
    private let maxHeight: Int = 1080

    /// Diagnostics.
    private(set) var framesSent: UInt64 = 0
    private(set) var framesDropped: UInt64 = 0
    private(set) var framesThrottled: UInt64 = 0

    // MARK: - InterShareSink: Start

    @objc public func start(
        with configuration: InterShareSessionConfiguration,
        completion: ((Bool, String?) -> Void)?
    ) {
        guard !isActive else {
            completion?(true, "Already active")
            return
        }

        interLogInfo(InterLog.media, "ScreenShareSource: starting")

        // Create LocalVideoTrack with BufferCapturer for screen share
        let options = BufferCaptureOptions()
        let track = LocalVideoTrack.createBufferTrack(
            name: Track.screenShareVideoName,
            source: .screenShareVideo,
            options: options,
            reportStatistics: false
        )
        self.videoTrack = track

        if let capturer = track.capturer as? BufferCapturer {
            self.bufferCapturer = capturer
        } else {
            interLogError(InterLog.media, "ScreenShareSource: capturer is not BufferCapturer")
        }

        isActive = true
        framesSent = 0
        framesDropped = 0
        framesThrottled = 0
        lastFrameTime = 0

        interLogInfo(InterLog.media, "ScreenShareSource: started, track created")
        completion?(true, nil)
    }

    // MARK: - InterShareSink: Append Video

    /// Receives screen capture frames from the router queue.
    /// [G5] Returns quickly. CVPixelBuffer is captured by the closure (ARC retains it).
    @objc public func append(_ frame: InterShareVideoFrame) {
        guard isActive, let capturer = bufferCapturer else { return }

        // Throttle: skip frames beyond 15 FPS
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastFrameTime < minFrameInterval {
            framesThrottled += 1
            return
        }
        lastFrameTime = now

        // Capture the pixel buffer — Swift ARC retains it for the closure lifetime.
        let pixelBuffer = frame.pixelBuffer

        encoderQueue.async { [weak self] in
            guard let self = self, self.isActive else { return }

            // Check if downscaling is needed [1.6.7]
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)

            if width > self.maxWidth || height > self.maxHeight {
                // Downscale
                if let scaled = self.downscale(pixelBuffer: pixelBuffer,
                                               maxWidth: self.maxWidth,
                                               maxHeight: self.maxHeight) {
                    capturer.capture(scaled, timeStampNs: interCreateTimeStampNs())
                } else {
                    // Downscale failed — send original
                    capturer.capture(pixelBuffer, timeStampNs: interCreateTimeStampNs())
                    self.framesDropped += 1
                }
            } else {
                // No downscale needed
                capturer.capture(pixelBuffer, timeStampNs: interCreateTimeStampNs())
            }

            self.framesSent += 1
        }
    }

    // MARK: - InterShareSink: Append Audio (no-op)

    @objc public func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        // Screen share source ignores audio (future: system audio capture).
    }

    // MARK: - InterShareSink: Stop

    @objc public func stop(completion: (() -> Void)?) {
        guard isActive else {
            completion?()
            return
        }

        interLogInfo(InterLog.media,
                     "ScreenShareSource: stopping (sent=%{public}llu, dropped=%{public}llu, throttled=%{public}llu)",
                     framesSent, framesDropped, framesThrottled)

        isActive = false

        // Drain encoder queue before cleanup
        encoderQueue.async { [weak self] in
            self?.videoTrack = nil
            self?.bufferCapturer = nil

            interLogInfo(InterLog.media, "ScreenShareSource: stopped")
            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    // MARK: - Private: Downscaling

    /// Downscale a CVPixelBuffer to fit within maxWidth × maxHeight, preserving aspect ratio.
    /// Uses vImage for efficient BGRA scaling.
    private func downscale(pixelBuffer: CVPixelBuffer, maxWidth: Int, maxHeight: Int) -> CVPixelBuffer? {
        let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
        let srcHeight = CVPixelBufferGetHeight(pixelBuffer)

        // Calculate target size preserving aspect ratio
        let widthRatio = Double(maxWidth) / Double(srcWidth)
        let heightRatio = Double(maxHeight) / Double(srcHeight)
        let scale = min(widthRatio, heightRatio)

        let dstWidth = Int(Double(srcWidth) * scale)
        let dstHeight = Int(Double(srcHeight) * scale)

        // Lock source
        let lockFlags = CVPixelBufferLockFlags.readOnly
        guard CVPixelBufferLockBaseAddress(pixelBuffer, lockFlags) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, lockFlags) }

        guard let srcBaseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        var srcBuffer = vImage_Buffer(
            data: srcBaseAddress,
            height: vImagePixelCount(srcHeight),
            width: vImagePixelCount(srcWidth),
            rowBytes: srcBytesPerRow
        )

        // Create destination CVPixelBuffer
        var dstPixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: dstWidth,
            kCVPixelBufferHeightKey: dstHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            dstWidth,
            dstHeight,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &dstPixelBuffer
        )
        guard status == kCVReturnSuccess, let dst = dstPixelBuffer else {
            return nil
        }

        guard CVPixelBufferLockBaseAddress(dst, []) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(dst, []) }

        guard let dstBaseAddress = CVPixelBufferGetBaseAddress(dst) else {
            return nil
        }

        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(dst)

        var dstBuffer = vImage_Buffer(
            data: dstBaseAddress,
            height: vImagePixelCount(dstHeight),
            width: vImagePixelCount(dstWidth),
            rowBytes: dstBytesPerRow
        )

        // Scale using vImage (Lanczos for quality, but kvImageHighQualityResampling flag)
        let error = vImageScale_ARGB8888(&srcBuffer, &dstBuffer, nil, vImage_Flags(kvImageHighQualityResampling))
        guard error == kvImageNoError else {
            interLogError(InterLog.media, "ScreenShareSource: vImage scale failed (%{public}d)", error)
            return nil
        }

        return dst
    }
}

// MARK: - Timestamp Helper

/// Convenience function to create a nanosecond timestamp for manual frame injection.
/// Uses VideoCapturer's built-in method.
private func interCreateTimeStampNs() -> Int64 {
    return VideoCapturer.createTimeStampNs()
}
