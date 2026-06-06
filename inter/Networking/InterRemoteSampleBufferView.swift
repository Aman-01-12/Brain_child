// ============================================================================
// InterRemoteSampleBufferView.swift
// inter
//
// Remote camera renderer backed by AVSampleBufferDisplayLayer. Replaces the
// custom Metal InterRemoteVideoView for normal-call camera tiles. Apple handles
// YCbCr→RGB conversion and display scheduling; no CVDisplayLink, no Metal shader,
// no drawableSize bookkeeping. Mirror is a layer transform.
//
// THREADING: updateFrame(_:) may be called on the WebRTC decode thread; enqueue
// is thread-safe. We wrap the CVPixelBuffer in a timed CMSampleBuffer and enqueue.
// ============================================================================

import AppKit
import AVFoundation
import CoreMedia
import CoreVideo

@objc public final class InterRemoteSampleBufferView: NSView {

    private let displayLayer = AVSampleBufferDisplayLayer()

    /// When true, updateFrame(_:) drops incoming frames instead of enqueueing them.
    /// Set while the camera is off so a late in-flight decode frame cannot be queued
    /// behind the avatar and flash when the view is next shown. Guarded by `pausedLock`
    /// because updateFrame runs on the decode thread while the setters run on main.
    private var _paused = false
    private let pausedLock = NSLock()
    private var isPaused: Bool {
        get { pausedLock.lock(); defer { pausedLock.unlock() }; return _paused }
        set { pausedLock.lock(); _paused = newValue; pausedLock.unlock() }
    }

    /// When true, the layer is horizontally mirrored (matches local preview).
    @objc public var isMirrored: Bool = true { didSet { applyMirror() } }

    /// When true, video fills the view by cropping to aspect-fill (no black bars).
    /// When false (default), video fits with letterbox/pillarbox bars.
    @objc public var aspectFill: Bool = false {
        didSet { displayLayer.videoGravity = aspectFill ? .resizeAspectFill : .resizeAspect }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = bounds
        layer?.addSublayer(displayLayer)
        layer?.backgroundColor = NSColor.black.cgColor
        applyMirror()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    public override func layout() {
        super.layout()
        displayLayer.frame = bounds
        applyMirror()
    }

    private func applyMirror() {
        // Horizontal flip around the layer's center.
        if isMirrored {
            displayLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        } else {
            displayLayer.setAffineTransform(.identity)
        }
    }

    /// Enqueue a decoded frame. Safe to call off the main thread.
    /// Does NOT check displayLayer.status — that property is not thread-safe.
    /// Call prepareForResume() on the main thread before resuming after a mute
    /// to clear any .failed state so the layer accepts new frames immediately.
    @objc public func updateFrame(_ pixelBuffer: CVPixelBuffer) {
        // Drop frames while paused (camera off). Prevents a late decode-thread frame
        // from being enqueued behind the avatar and flashing on the next reveal.
        if isPaused { return }
        guard let sample = Self.makeSampleBuffer(from: pixelBuffer) else { return }
        displayLayer.enqueue(sample)
    }

    /// Prepare the layer to accept new frames after a pause/mute.
    /// Must be called on the main thread (AVSampleBufferDisplayLayer.status
    /// and flush() are not thread-safe). Clears any .failed state so that
    /// the first enqueued frame after unmute is displayed immediately.
    @objc public func prepareForResume() {
        assert(Thread.isMainThread, "prepareForResume must be called on the main thread")
        isPaused = false
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
    }

    /// Tear down rendering: flush queued frames and remove the displayed image.
    /// Must be called on the main thread.
    @objc public func shutdownRendering() {
        assert(Thread.isMainThread, "shutdownRendering must be called on the main thread")
        isPaused = true
        displayLayer.flushAndRemoveImage()
        // Proactively flush after flushAndRemoveImage to prevent the layer from
        // entering .failed on rapid mute/unmute cycles, which would cause the
        // first new frame to be dropped and the feed to appear frozen.
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
    }

    /// Wrap a CVPixelBuffer in a display-ready CMSampleBuffer with an immediate PTS.
    @objc public static func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        let fdStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDesc)
        guard fdStatus == noErr, let fd = formatDesc else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)

        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: fd,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer)
        guard sbStatus == noErr, let sb = sampleBuffer else { return nil }

        // Display immediately (no decode reordering for live frames).
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }
}
