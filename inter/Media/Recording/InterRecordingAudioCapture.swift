// ============================================================================
// InterRecordingAudioCapture.swift
// inter
//
// Phase 10 — Gap #14: Extracted audio capture subsystem.
//
// Captures both local (microphone) and remote (participant) audio using
// LiveKit's AudioRenderer protocol.  On macOS, LiveKit routes audio through
// WebRTC's audioDeviceModule (CoreAudio HAL), so the previous approach of
// tapping AVAudioEngine's mainMixerNode captured nothing.
//
// Architecture (mirrors LiveKit's AudioMixRecorder pattern):
//   1. A private AVAudioEngine in manual-rendering mode provides an offline
//      mix bus.
//   2. Two AVAudioPlayerNode instances (local + remote) are connected to the
//      mixer.
//   3. RecordingAudioSource objects conform to AudioRenderer and schedule
//      incoming PCM into the player nodes.
//   4. A periodic timer calls the engine's manualRenderingBlock, interleaves
//      the Float32 output, and wraps it in a CMSampleBuffer for the recording
//      engine.
//
// THREADING:
//   - start / stop must be called from the coordinator's serial queue.
//   - AudioRenderer.render(pcmBuffer:) is called on LiveKit's audio thread.
//   - The drain timer fires on coordinatorQueue.
//
// ISOLATION INVARIANT [G8]:
//   If removed, the coordinator loses audio capture but video recording
//   still works.
// ============================================================================

import Foundation
import AVFoundation
import CoreMedia
import os.log
import LiveKit

// MARK: - InterRecordingAudioCapture

/// Self-contained audio capture subsystem for recording.
///
/// Usage:
/// ```
/// let capture = InterRecordingAudioCapture(coordinatorQueue: queue)
/// capture.onSampleBuffer = { sb in engine.appendAudioSampleBuffer(sb) }
/// capture.start()
/// // … recording …
/// capture.stop()
/// ```
final class InterRecordingAudioCapture {

    // MARK: - Public Interface

    /// Called on `coordinatorQueue` with each mixed CMSampleBuffer.
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    // MARK: - Configuration

    private let coordinatorQueue: DispatchQueue

    /// 48 kHz stereo Float32 – matches InterRecordingEngine's audio input.
    private let processingFormat: AVAudioFormat

    /// Frames per render call.  1024 / 48 000 ≈ 21.3 ms.
    private let renderFrameCount: AVAudioFrameCount = 1024

    // MARK: - Engine & Nodes

    private var engine: AVAudioEngine?
    private var localPlayerNode: AVAudioPlayerNode?
    private var remotePlayerNode: AVAudioPlayerNode?

    // MARK: - LiveKit Sources

    private var localSource: RecordingAudioSource?
    private var remoteSource: RecordingAudioSource?

    // MARK: - Timer

    private var renderTimer: DispatchSourceTimer?

    // MARK: - Logging

    private static let log = OSLog(
        subsystem: "com.inter.app",
        category: "RecordingAudioCapture"
    )

    // MARK: - Init

    init(coordinatorQueue: DispatchQueue) {
        self.coordinatorQueue = coordinatorQueue
        self.processingFormat = AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 2
        )!
    }

    // MARK: - Start

    func start() {
        dispatchPrecondition(condition: .onQueue(coordinatorQueue))

        guard engine == nil else {
            os_log(.info, log: Self.log, "Audio capture already started")
            return
        }

        do {
            let eng = AVAudioEngine()

            // ---- Manual rendering mode ----
            try eng.enableManualRenderingMode(
                .realtime,
                format: processingFormat,
                maximumFrameCount: renderFrameCount
            )

            // ---- Player nodes ----
            let localPlayer  = AVAudioPlayerNode()
            let remotePlayer = AVAudioPlayerNode()

            eng.attach(localPlayer)
            eng.attach(remotePlayer)

            eng.connect(localPlayer,        to: eng.mainMixerNode, format: processingFormat)
            eng.connect(remotePlayer,       to: eng.mainMixerNode, format: processingFormat)
            eng.connect(eng.mainMixerNode,  to: eng.outputNode,    format: processingFormat)

            try eng.start()
            localPlayer.play()
            remotePlayer.play()

            self.engine           = eng
            self.localPlayerNode  = localPlayer
            self.remotePlayerNode = remotePlayer

            // ---- AudioRenderer sources ----
            let localSrc  = RecordingAudioSource(playerNode: localPlayer,  targetFormat: processingFormat)
            let remoteSrc = RecordingAudioSource(playerNode: remotePlayer, targetFormat: processingFormat)
            self.localSource  = localSrc
            self.remoteSource = remoteSrc

            AudioManager.shared.add(localAudioRenderer:  localSrc)
            AudioManager.shared.add(remoteAudioRenderer: remoteSrc)

            // ---- Render timer ----
            startRenderTimer()

            os_log(.info, log: Self.log, "Audio capture started (LiveKit AudioRenderer)")

        } catch {
            os_log(
                .error, log: Self.log,
                "Failed to start audio capture: %{public}@",
                error.localizedDescription
            )
            teardown()
        }
    }

    // MARK: - Stop

    func stop() {
        teardown()
        os_log(.info, log: Self.log, "Audio capture stopped")
    }

    // MARK: - Teardown

    private func teardown() {
        renderTimer?.cancel()
        renderTimer = nil

        if let src = localSource  { AudioManager.shared.remove(localAudioRenderer:  src) }
        if let src = remoteSource { AudioManager.shared.remove(remoteAudioRenderer: src) }
        localSource  = nil
        remoteSource = nil

        localPlayerNode?.stop()
        remotePlayerNode?.stop()
        localPlayerNode  = nil
        remotePlayerNode = nil

        engine?.stop()
        engine?.reset()
        engine = nil
    }

    // MARK: - Render Timer

    private func startRenderTimer() {
        let timer = DispatchSource.makeTimerSource(queue: coordinatorQueue)
        let intervalNs = UInt64(
            Double(renderFrameCount) / processingFormat.sampleRate * 1_000_000_000
        )
        timer.schedule(
            deadline: .now(),
            repeating: .nanoseconds(Int(intervalNs))
        )
        timer.setEventHandler { [weak self] in
            self?.renderAndDeliver()
        }
        self.renderTimer = timer
        timer.resume()
    }

    // MARK: - Manual Render

    private func renderAndDeliver() {
        guard let engine = engine else { return }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: renderFrameCount
        ) else { return }

        // Pre-set frameLength so the AudioBufferList data sizes are correct.
        buffer.frameLength = renderFrameCount

        let status = engine.manualRenderingBlock(
            renderFrameCount,
            buffer.mutableAudioBufferList,
            nil
        )

        guard status == .success, buffer.frameLength > 0 else { return }

        if let sb = makeCMSampleBuffer(from: buffer) {
            onSampleBuffer?(sb)
        }
    }

    // MARK: - CMSampleBuffer Conversion

    /// Converts a non-interleaved Float32 AVAudioPCMBuffer into an
    /// interleaved Float32 CMSampleBuffer suitable for AVAssetWriter.
    private func makeCMSampleBuffer(from pcm: AVAudioPCMBuffer) -> CMSampleBuffer? {
        let frameCount = Int(pcm.frameLength)
        let channels   = Int(processingFormat.channelCount)
        guard let floatData = pcm.floatChannelData, frameCount > 0 else { return nil }

        // ---- Interleave ----
        let sampleCount = frameCount * channels
        let byteSize    = sampleCount * MemoryLayout<Float>.size

        var interleaved = [Float](repeating: 0, count: sampleCount)
        for f in 0..<frameCount {
            for ch in 0..<channels {
                interleaved[f * channels + ch] = floatData[ch][f]
            }
        }

        // ---- ASBD: interleaved Float32 PCM ----
        var asbd = AudioStreamBasicDescription(
            mSampleRate:       processingFormat.sampleRate,
            mFormatID:         kAudioFormatLinearPCM,
            mFormatFlags:      kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket:   UInt32(channels * MemoryLayout<Float>.size),
            mFramesPerPacket:  1,
            mBytesPerFrame:    UInt32(channels * MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel:   UInt32(MemoryLayout<Float>.size * 8),
            mReserved:         0
        )

        // ---- Format description ----
        var fmtDesc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator:            kCFAllocatorDefault,
            asbd:                 &asbd,
            layoutSize:           0,
            layout:               nil,
            magicCookieSize:      0,
            magicCookie:          nil,
            extensions:           nil,
            formatDescriptionOut: &fmtDesc
        ) == noErr, let fmt = fmtDesc else { return nil }

        // ---- Timing ----
        let pts = CMTime(
            seconds: CACurrentMediaTime(),
            preferredTimescale: 48_000
        )
        var timing = CMSampleTimingInfo(
            duration:                CMTime(
                value:     CMTimeValue(frameCount),
                timescale: CMTimeScale(processingFormat.sampleRate)
            ),
            presentationTimeStamp:  pts,
            decodeTimeStamp:        .invalid
        )

        // ---- Block buffer ----
        var blockBuf: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator:       kCFAllocatorDefault,
            memoryBlock:     nil,
            blockLength:     byteSize,
            blockAllocator:  kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData:    0,
            dataLength:      byteSize,
            flags:           0,
            blockBufferOut:  &blockBuf
        ) == kCMBlockBufferNoErr, let bb = blockBuf else { return nil }

        guard interleaved.withUnsafeBytes({ ptr in
            CMBlockBufferReplaceDataBytes(
                with:                 ptr.baseAddress!,
                blockBuffer:          bb,
                offsetIntoDestination: 0,
                dataLength:           byteSize
            )
        }) == kCMBlockBufferNoErr else { return nil }

        // ---- Sample buffer ----
        var sampleBuf: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator:              kCFAllocatorDefault,
            dataBuffer:             bb,
            dataReady:              true,
            makeDataReadyCallback:  nil,
            refcon:                 nil,
            formatDescription:      fmt,
            sampleCount:            frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray:      &timing,
            sampleSizeEntryCount:   0,
            sampleSizeArray:        nil,
            sampleBufferOut:        &sampleBuf
        ) == noErr else { return nil }

        return sampleBuf
    }
}

// MARK: - RecordingAudioSource

/// Bridges LiveKit's `AudioRenderer` protocol to an `AVAudioPlayerNode`.
///
/// Each instance receives PCM buffers from LiveKit (local mic or combined
/// remote) and schedules them into its player node.  If the incoming format
/// doesn't match the mix engine's processing format, a lazy `AVAudioConverter`
/// handles resampling / channel mapping.
private final class RecordingAudioSource: NSObject, AudioRenderer, @unchecked Sendable {

    private let playerNode: AVAudioPlayerNode
    private let targetFormat: AVAudioFormat

    /// Guards `_converter` — render() may be called from any LiveKit audio thread.
    private let _lock = NSLock()
    private var _converter: AVAudioConverter?

    init(playerNode: AVAudioPlayerNode, targetFormat: AVAudioFormat) {
        self.playerNode   = playerNode
        self.targetFormat = targetFormat
        super.init()
    }

    // MARK: - AudioRenderer

    func render(pcmBuffer: AVAudioPCMBuffer) {
        guard pcmBuffer.frameLength > 0 else { return }

        let srcFmt = pcmBuffer.format

        // Fast path: formats already match — no converter needed.
        if srcFmt.sampleRate   == targetFormat.sampleRate,
           srcFmt.channelCount == targetFormat.channelCount {
            playerNode.scheduleBuffer(pcmBuffer)
            return
        }

        // Slow path: resolve converter under lock, then convert outside.
        let conv: AVAudioConverter? = {
            _lock.lock()
            defer { _lock.unlock() }
            if _converter == nil || _converter?.inputFormat != srcFmt {
                _converter = AVAudioConverter(from: srcFmt, to: targetFormat)
            }
            return _converter
        }()

        guard let conv else {
            playerNode.scheduleBuffer(pcmBuffer)
            return
        }

        let ratio     = targetFormat.sampleRate / srcFmt.sampleRate
        let outFrames = AVAudioFrameCount(Double(pcmBuffer.frameLength) * ratio)

        guard let outBuf = AVAudioPCMBuffer(
            pcmFormat:     targetFormat,
            frameCapacity: outFrames
        ) else { return }

        var error: NSError?
        conv.convert(to: outBuf, error: &error) { _, status in
            status.pointee = .haveData
            return pcmBuffer
        }

        if error == nil, outBuf.frameLength > 0 {
            playerNode.scheduleBuffer(outBuf)
        }
    }
}
