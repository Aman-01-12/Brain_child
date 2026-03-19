// ============================================================================
// InterLiveKitAudioBridge.swift
// inter
//
// Phase 1.4 [G1] — Audio bridge: app's AVCaptureSession → LiveKit network.
//
// ARCHITECTURE (Decision 1 — Single-Source Fan-Out):
// The app captures mic audio ONCE via AVCaptureAudioDataOutput. Raw
// CMSampleBuffers are fanned out to registered InterShareSink instances
// (e.g. InterLiveKitAudioBridge for network publish).
//
// HOW IT WORKS:
// The LiveKit Swift SDK does not expose a direct audio buffer injection API
// (unlike video's BufferCapturer). Instead, we use the
// `capturePostProcessingDelegate` hook on AudioManager.shared:
//
//   1. appendAudioSampleBuffer: called on router queue → convert to Float32
//      → write to lock-free ring buffer
//   2. AudioManager's capturePostProcessingDelegate calls our
//      audioProcessingProcess(audioBuffer:) on WebRTC's audio thread →
//      read from ring buffer → overwrite the LKAudioBuffer channels
//
// WebRTC's AudioDeviceModule still opens the mic (unavoidable), but its
// captured data is replaced by our data before encoding. This achieves
// the single-source invariant from Decision 1.
//
// ISOLATION INVARIANT [G8]:
// All errors are swallowed with logging. This class never affects local
// capture or UI. If it fails, the app continues in local-only mode.
//
// THREADING:
// - appendAudioSampleBuffer: returns in <500ns [G5] via CFRetain + dispatch
// - audioProcessingProcess: runs on WebRTC's real-time audio thread
//   (NO allocation, NO logging, NO locks that could block)
// - Ring buffer is single-producer single-consumer (SPSC) with atomics
// ============================================================================

import Foundation
import AVFoundation
import CoreMedia
import os.log
import LiveKit
import Atomics

// MARK: - SPSC Ring Buffer

/// Single-producer single-consumer lock-free circular buffer for Float32 audio samples.
/// Supports mono or stereo by interleaving: [L0, R0, L1, R1, ...].
///
/// The writer (appendAudioSampleBuffer queue) and reader (WebRTC audio thread)
/// never need to synchronize — they use atomic load/store on head/tail indices
/// with acquire/release memory ordering to guarantee visibility of buffer writes.
///
/// Memory ordering contract:
///   - Writer stores head with `.releasing` → buffer data is flushed before head advances.
///   - Reader loads head with `.acquiring` → sees all buffer writes before acting on them.
///   - Reader stores tail with `.releasing` → writer sees consumed range (for overwrite safety).
///   - Writer loads tail with `.acquiring` → not currently used (write always overwrites).
private final class AudioRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let channelCount: Int
    private let buffer: UnsafeMutablePointer<Float>

    /// Atomic write cursor (UInt64 to avoid wrapping concerns for ~12,000 years at 48kHz).
    /// Writer-owned: only the producer (conversion queue) stores to this.
    private let _head = ManagedAtomic<UInt64>(0)

    /// Atomic read cursor. Reader-owned: only the consumer (WebRTC audio thread) stores to this.
    private let _tail = ManagedAtomic<UInt64>(0)

    /// Create a ring buffer.
    /// - Parameters:
    ///   - frameDuration: Duration in seconds of audio to buffer (e.g. 0.5 for 500ms)
    ///   - sampleRate: Expected sample rate (e.g. 48000)
    ///   - channels: Number of channels (1 = mono, 2 = stereo)
    init(frameDuration: TimeInterval = 0.5, sampleRate: Int = 48000, channels: Int = 1) {
        self.channelCount = channels
        // Buffer enough interleaved samples for the given duration
        self.capacity = Int(frameDuration * Double(sampleRate)) * channels
        self.buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }

    deinit {
        buffer.deallocate()
    }

    /// Write interleaved Float32 samples. Called by the producer (conversion queue).
    /// Overwrites oldest data if the buffer is full (acceptable for real-time audio).
    func write(_ samples: UnsafePointer<Float>, count: Int) {
        // Relaxed load: writer owns head — no cross-thread ordering needed for the read.
        let h = _head.load(ordering: .relaxed)
        for i in 0..<count {
            let idx = Int((h &+ UInt64(i)) % UInt64(capacity))
            buffer[idx] = samples[i]
        }
        // Release store: ensures all buffer writes above are visible before head advances.
        _head.store(h &+ UInt64(count), ordering: .releasing)
    }

    /// Read interleaved Float32 samples into the destination buffer.
    /// Called by the consumer (WebRTC audio thread).
    /// Returns the number of samples actually read. If not enough data, fills remainder with silence.
    func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        // Acquire load: reader must see all buffer writes completed before this head value.
        let h = _head.load(ordering: .acquiring)
        // Relaxed load: reader owns tail.
        let t = _tail.load(ordering: .relaxed)

        let available = Int(h &- t)
        let toRead = min(count, available)

        for i in 0..<toRead {
            let idx = Int((t &+ UInt64(i)) % UInt64(capacity))
            destination[i] = buffer[idx]
        }
        // Fill remainder with silence
        if toRead < count {
            for i in toRead..<count {
                destination[i] = 0
            }
        }
        // Release store: marks consumed range (not strictly needed since writer doesn't
        // check space, but correct for potential future full-check).
        _tail.store(t &+ UInt64(toRead), ordering: .releasing)
        return toRead
    }

    /// Reset the buffer (called when both threads are quiescent).
    func reset() {
        _head.store(0, ordering: .relaxed)
        _tail.store(0, ordering: .relaxed)
    }
}

// MARK: - InterLiveKitAudioBridge

@objc public class InterLiveKitAudioBridge: NSObject, InterShareSink, AudioCustomProcessingDelegate, @unchecked Sendable {

    // MARK: - InterShareSink conformance

    /// Maps to ObjC `active` property with `isActive` getter.
    @objc public private(set) dynamic var isActive: Bool = false

    // MARK: - Public Properties

    /// The LocalAudioTrack managed by this bridge. Non-nil while active.
    public private(set) var audioTrack: LocalAudioTrack?

    // MARK: - Private Properties

    /// Ring buffer for cross-thread audio transfer (router queue → WebRTC audio thread).
    private var ringBuffer: AudioRingBuffer?

    /// Conversion queue for CMSampleBuffer → Float32 processing.
    /// UserInteractive QoS to minimize latency.
    private let conversionQueue = DispatchQueue(
        label: "inter.audio.bridge.conversion",
        qos: .userInteractive
    )

    /// Format info from WebRTC's audioProcessingInitialize callback.
    private var webrtcSampleRate: Int = 48000
    private var webrtcChannels: Int = 1

    /// Whether we've registered as the capturePostProcessingDelegate.
    private var isProcessingDelegateRegistered: Bool = false

    /// [G2] Microphone network state machine.
    private var micState: InterMicrophoneNetworkState = .active

    /// [G2] Callback invoked when the first audio sample arrives after re-enable.
    private var pendingUnmuteCallback: (() -> Void)?

    /// Scratch buffer for format conversion (reused to avoid allocation).
    /// Protected by conversionQueue.
    private var conversionScratch: [Float] = []

    /// AVAudioConverter for sample rate conversion (reused across calls).
    /// Protected by conversionQueue.
    private var sampleRateConverter: AVAudioConverter?
    /// Source format of the current converter (invalidated on format change).
    private var converterSourceRate: Double = 0

    // MARK: - InterShareSink: Start

    @objc public func start(
        with configuration: InterShareSessionConfiguration,
        completion: ((Bool, String?) -> Void)?
    ) {
        guard !isActive else {
            completion?(true, "Already active")
            return
        }

        interLogInfo(InterLog.media, "AudioBridge: starting")

        // Create the audio track with processing disabled (we supply our own audio).
        let options = AudioCaptureOptions(
            echoCancellation: false,
            autoGainControl: false,
            noiseSuppression: false,
            highpassFilter: false,
            typingNoiseDetection: false
        )
        let track = LocalAudioTrack.createTrack(
            name: "inter-mic",
            options: options,
            reportStatistics: false
        )
        self.audioTrack = track

        // Initialize ring buffer (will be re-initialized in audioProcessingInitialize
        // once we know WebRTC's actual sample rate and channel count).
        self.ringBuffer = AudioRingBuffer(frameDuration: 0.5, sampleRate: 48000, channels: 1)

        // Register as capturePostProcessingDelegate to intercept and replace mic data.
        AudioManager.shared.capturePostProcessingDelegate = self
        isProcessingDelegateRegistered = true

        isActive = true
        micState = .active
        interLogInfo(InterLog.media, "AudioBridge: started, track created")
        completion?(true, nil)
    }

    // MARK: - InterShareSink: Append Audio

    /// Receives CMSampleBuffer from the router queue (InterSurfaceShareController).
    /// [G5] Must return in <500ns. Retains the buffer and dispatches conversion work.
    @objc public func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isActive else { return }

        // [G2] If we're in enabling state, this is the first sample after re-enable.
        if micState == .enabling, let callback = pendingUnmuteCallback {
            pendingUnmuteCallback = nil
            micState = .active
            callback()
        }

        // Retain the sample buffer for async processing [G5]
        let retained = Unmanaged.passRetained(sampleBuffer)

        conversionQueue.async { [weak self] in
            let sb = retained.takeRetainedValue()
            self?.convertAndWrite(sb)
        }
    }

    // MARK: - InterShareSink: Append Video (no-op)

    @objc public func append(_ frame: InterShareVideoFrame) {
        // Audio bridge ignores video frames.
    }

    // MARK: - InterShareSink: Stop

    @objc public func stop(completion: (() -> Void)?) {
        guard isActive else {
            completion?()
            return
        }

        interLogInfo(InterLog.media, "AudioBridge: stopping")

        isActive = false
        micState = .muted
        pendingUnmuteCallback = nil

        // Unregister processing delegate
        if isProcessingDelegateRegistered {
            AudioManager.shared.capturePostProcessingDelegate = nil
            isProcessingDelegateRegistered = false
        }

        // Clean up
        audioTrack = nil
        ringBuffer?.reset()
        ringBuffer = nil
        sampleRateConverter = nil
        converterSourceRate = 0

        interLogInfo(InterLog.media, "AudioBridge: stopped")
        completion?()
    }

    // MARK: - G2: Mute/Unmute State Machine

    /// Begin muting: mute the LiveKit track first, then caller stops capture device.
    @objc public func beginMute(completion: @escaping () -> Void) {
        guard let nextState = micState.nextState(for: .beginMute) else {
            interLogError(InterLog.media, "AudioBridge: invalid mute transition from %{public}@",
                          String(describing: micState))
            return
        }
        micState = nextState

        // Mute the track (async)
        if let track = audioTrack {
            Task {
                do {
                    try await track.mute()
                    interLogInfo(InterLog.media, "AudioBridge: track muted")
                } catch {
                    interLogError(InterLog.media, "AudioBridge: mute failed: %{public}@",
                                  error.localizedDescription)
                }
                // Transition to muted regardless of success [G8]
                self.micState = .muted
                DispatchQueue.main.async { completion() }
            }
        } else {
            micState = .muted
            completion()
        }
    }

    /// Begin enabling: caller starts capture device first, then we unmute on first sample.
    @objc public func beginEnable() {
        guard let nextState = micState.nextState(for: .beginEnable) else {
            interLogError(InterLog.media, "AudioBridge: invalid enable transition from %{public}@",
                          String(describing: micState))
            return
        }
        micState = nextState

        // Set up the pending unmute callback — triggered by first appendAudioSampleBuffer
        pendingUnmuteCallback = { [weak self] in
            guard let track = self?.audioTrack else { return }
            Task {
                do {
                    try await track.unmute()
                    interLogInfo(InterLog.media, "AudioBridge: track unmuted after first sample")
                } catch {
                    interLogError(InterLog.media, "AudioBridge: unmute failed: %{public}@",
                                  error.localizedDescription)
                }
            }
        }

        interLogInfo(InterLog.media, "AudioBridge: enabling, waiting for first sample")
    }

    // MARK: - AudioCustomProcessingDelegate

    /// Called by WebRTC when the audio processing is initialized with format info.
    public func audioProcessingInitialize(sampleRate sampleRateHz: Int, channels: Int) {
        webrtcSampleRate = sampleRateHz
        webrtcChannels = channels

        // Recreate ring buffer with actual WebRTC format.
        ringBuffer = AudioRingBuffer(
            frameDuration: 0.5,
            sampleRate: sampleRateHz,
            channels: channels
        )

        interLogInfo(InterLog.media, "AudioBridge: WebRTC audio initialized (rate=%{public}d, ch=%{public}d)",
                     sampleRateHz, channels)
    }

    /// Called on WebRTC's real-time audio thread.
    /// CRITICAL: No allocation, no logging, no locks in this method.
    public func audioProcessingProcess(audioBuffer: LKAudioBuffer) {
        guard let ringBuffer = ringBuffer, isActive else { return }

        let frames = audioBuffer.frames
        let channels = audioBuffer.channels

        // Read interleaved data from ring buffer into a stack-allocated-ish scratch
        // Then deinterleave into LKAudioBuffer's per-channel raw buffers.
        let totalSamples = frames * channels

        // Use a stack-allocated temp buffer for small sizes, heap for large
        if totalSamples <= 960 {
            // 960 = 10ms at 48kHz stereo — typical WebRTC callback size
            var temp = (
                Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0),
                Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0)
            )
            // Can't use tuple for variable-length. Use UnsafeMutableBufferPointer with alloca-like pattern.
            let tempBuffer = UnsafeMutablePointer<Float>.allocate(capacity: totalSamples)
            defer { tempBuffer.deallocate() }

            _ = ringBuffer.read(into: tempBuffer, count: totalSamples)

            // Deinterleave: fill each channel's raw buffer
            if channels == 1 {
                let channelBuffer = audioBuffer.rawBuffer(forChannel: 0)
                for i in 0..<frames {
                    // Scale to WebRTC's Int16-range Float format
                    channelBuffer[i] = tempBuffer[i]
                }
            } else {
                for ch in 0..<channels {
                    let channelBuffer = audioBuffer.rawBuffer(forChannel: ch)
                    for i in 0..<frames {
                        channelBuffer[i] = tempBuffer[i * channels + ch]
                    }
                }
            }
        } else {
            // Larger buffer — same logic, just note it's unusual
            let tempBuffer = UnsafeMutablePointer<Float>.allocate(capacity: totalSamples)
            defer { tempBuffer.deallocate() }

            _ = ringBuffer.read(into: tempBuffer, count: totalSamples)

            for ch in 0..<channels {
                let channelBuffer = audioBuffer.rawBuffer(forChannel: ch)
                for i in 0..<frames {
                    channelBuffer[i] = tempBuffer[i * channels + ch]
                }
            }
        }
    }

    /// Called when audio processing is no longer needed.
    public func audioProcessingRelease() {
        interLogInfo(InterLog.media, "AudioBridge: WebRTC audio processing released")
    }

    // MARK: - Private: Format Conversion

    /// Convert CMSampleBuffer to interleaved Float32 and write to ring buffer.
    /// Runs on conversionQueue.
    private func convertAndWrite(_ sampleBuffer: CMSampleBuffer) {
        guard let ringBuffer = ringBuffer else { return }

        // Get the format description
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return
        }

        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        guard let asbd = asbd?.pointee else { return }

        let sampleRate = asbd.mSampleRate
        let channels = Int(asbd.mChannelsPerFrame)
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)

        guard numSamples > 0 else { return }

        // Use the LiveKit SDK's convenience extension to convert CMSampleBuffer → AVAudioPCMBuffer
        guard let pcmBuffer = sampleBuffer.toAVAudioPCMBuffer() else {
            return
        }

        let frameLength = Int(pcmBuffer.frameLength)

        // Need interleaved Float32 in WebRTC's Int16-scaled format.
        // WebRTC expects Float values in the range [-32768, 32767].
        let totalSamples = frameLength * channels

        // Ensure scratch buffer is large enough
        if conversionScratch.count < totalSamples {
            conversionScratch = [Float](repeating: 0, count: totalSamples)
        }

        let format = pcmBuffer.format.commonFormat

        switch format {
        case .pcmFormatFloat32:
            // Float32 normalized [-1.0, 1.0] → Int16-scaled Float [-32768, 32767]
            if let floatData = pcmBuffer.floatChannelData {
                if channels == 1 {
                    let src = floatData[0]
                    for i in 0..<frameLength {
                        conversionScratch[i] = src[i] * 32767.0
                    }
                } else {
                    // Interleave
                    for i in 0..<frameLength {
                        for ch in 0..<channels {
                            conversionScratch[i * channels + ch] = floatData[ch][i] * 32767.0
                        }
                    }
                }
            }

        case .pcmFormatInt16:
            // Int16 → Int16-scaled Float (just convert to Float)
            if let int16Data = pcmBuffer.int16ChannelData {
                if channels == 1 {
                    let src = int16Data[0]
                    for i in 0..<frameLength {
                        conversionScratch[i] = Float(src[i])
                    }
                } else {
                    for i in 0..<frameLength {
                        for ch in 0..<channels {
                            conversionScratch[i * channels + ch] = Float(int16Data[ch][i])
                        }
                    }
                }
            }

        case .pcmFormatInt32:
            // Int32 → scale to Int16 range
            if let int32Data = pcmBuffer.int32ChannelData {
                if channels == 1 {
                    let src = int32Data[0]
                    for i in 0..<frameLength {
                        conversionScratch[i] = Float(src[i]) / 65536.0 // Int32 → Int16 range
                    }
                } else {
                    for i in 0..<frameLength {
                        for ch in 0..<channels {
                            conversionScratch[i * channels + ch] = Float(int32Data[ch][i]) / 65536.0
                        }
                    }
                }
            }

        default:
            // Unsupported format — skip
            return
        }

        // Handle sample rate mismatch: if source rate differs from WebRTC's expected rate,
        // use AVAudioConverter for proper sinc-interpolated resampling (replaces the
        // nearest-neighbor approximation that caused audible aliasing with non-standard devices).
        if Int(sampleRate) != webrtcSampleRate && webrtcSampleRate > 0 {
            guard let resampled = resampleConversionScratch(
                frameCount: frameLength,
                channels: channels,
                sourceRate: sampleRate
            ) else {
                // Fallback: write unresampled data (better than silence)
                conversionScratch.withUnsafeBufferPointer { ptr in
                    ringBuffer.write(ptr.baseAddress!, count: totalSamples)
                }
                return
            }
            resampled.withUnsafeBufferPointer { ptr in
                ringBuffer.write(ptr.baseAddress!, count: ptr.count)
            }
        } else {
            conversionScratch.withUnsafeBufferPointer { ptr in
                ringBuffer.write(ptr.baseAddress!, count: totalSamples)
            }
        }
    }

    // MARK: - Private: Sample Rate Conversion

    /// Resample interleaved Int16-scaled Float32 data from `conversionScratch` to WebRTC's
    /// expected sample rate using AVAudioConverter (sinc interpolation, anti-aliased).
    /// Runs on conversionQueue only.
    ///
    /// - Parameters:
    ///   - frameCount: Number of audio frames in conversionScratch
    ///   - channels: Number of audio channels
    ///   - sourceRate: Source sample rate
    /// - Returns: Interleaved resampled data, or nil on failure
    private func resampleConversionScratch(
        frameCount: Int,
        channels: Int,
        sourceRate: Double
    ) -> [Float]? {
        let destRate = Double(webrtcSampleRate)

        // Create or reuse converter (invalidate on source rate change)
        if sampleRateConverter == nil || converterSourceRate != sourceRate {
            let srcFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sourceRate,
                channels: AVAudioChannelCount(channels),
                interleaved: false
            )
            let dstFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: destRate,
                channels: AVAudioChannelCount(channels),
                interleaved: false
            )
            guard let srcFmt = srcFormat, let dstFmt = dstFormat,
                  let converter = AVAudioConverter(from: srcFmt, to: dstFmt) else {
                interLogError(InterLog.media,
                              "AudioBridge: failed to create AVAudioConverter (%{public}.0f → %{public}.0f Hz)",
                              sourceRate, destRate)
                return nil
            }
            converter.sampleRateConverterQuality = .max  // highest quality sinc interpolation
            sampleRateConverter = converter
            converterSourceRate = sourceRate
        }

        guard let converter = sampleRateConverter else { return nil }

        // Build source PCM buffer (non-interleaved) from conversionScratch (interleaved)
        guard let srcFormat = converter.inputFormat as AVAudioFormat?,
              let srcBuffer = AVAudioPCMBuffer(
                  pcmFormat: srcFormat,
                  frameCapacity: AVAudioFrameCount(frameCount)
              ) else { return nil }

        srcBuffer.frameLength = AVAudioFrameCount(frameCount)
        if let channelData = srcBuffer.floatChannelData {
            for ch in 0..<channels {
                let dst = channelData[ch]
                if channels == 1 {
                    for i in 0..<frameCount { dst[i] = conversionScratch[i] }
                } else {
                    for i in 0..<frameCount {
                        dst[i] = conversionScratch[i * channels + ch]
                    }
                }
            }
        }

        // Allocate output buffer
        let ratio = destRate / sourceRate
        let outputFrames = AVAudioFrameCount(ceil(Double(frameCount) * ratio))
        guard let dstBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: outputFrames
        ) else { return nil }

        // Convert
        var error: NSError?
        var inputProvided = false
        let status = converter.convert(to: dstBuffer, error: &error) { _, outStatus in
            if inputProvided {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            inputProvided = true
            return srcBuffer
        }

        guard status != .error else {
            interLogError(InterLog.media, "AudioBridge: AVAudioConverter failed: %{public}@",
                          error?.localizedDescription ?? "unknown")
            return nil
        }

        // Re-interleave output into [Float]
        let outFrames = Int(dstBuffer.frameLength)
        let outTotal = outFrames * channels
        var result = [Float](repeating: 0, count: outTotal)
        if let channelData = dstBuffer.floatChannelData {
            if channels == 1 {
                let src = channelData[0]
                for i in 0..<outFrames { result[i] = src[i] }
            } else {
                for i in 0..<outFrames {
                    for ch in 0..<channels {
                        result[i * channels + ch] = channelData[ch][i]
                    }
                }
            }
        }
        return result
    }
}
