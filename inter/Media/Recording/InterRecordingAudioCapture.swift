// ============================================================================
// InterRecordingAudioCapture.swift
// inter
//
// Phase 10 — Gap #14: Extracted audio capture subsystem.
// 2026-06-16 — Reworked to PER-TRACK remote capture + manual summation (Option B)
//              for recording-safe speaker mute (spec: recording-safe-speaker-mute).
//
// WHY PER-TRACK
// -------------
// Speaker-mute sets RemoteAudioTrack.volume = 0, which is applied at the WebRTC
// playout mixer. The previous combined tap (AudioManager.add(remoteAudioRenderer:))
// is taken AFTER that mixer (verified: the recording went silent on mute), so it is
// NOT recording-safe. Per-track sinks (RemoteAudioTrack.add(audioRenderer:)) receive
// each track's decoded audio BEFORE the volume stage, so the recording stays full
// regardless of playout mute.
//
// MIXING (manual summation — scales to InterMaxParticipantsPerRoom = 50)
// ----------------------------------------------------------------------
//   • Local mic + each remote track each feed a RecordingAudioSource that resamples
//     to 48 kHz stereo and writes interleaved frames into its own SPSC ring buffer
//     (producer = LiveKit audio thread).
//   • A periodic timer on coordinatorQueue pops `renderFrameCount` from every ring,
//     SUMS them (silence on underflow), soft-limits to [-1, 1], and emits one
//     CMSampleBuffer. Frame-locked → no per-track drift; bounded rings → no leak.
//
// THREADING
//   • start/stop/addRemoteTrack/removeRemoteTrack: coordinatorQueue.
//   • AudioRenderer.render(pcmBuffer:): LiveKit audio thread (writes to ring under lock).
//   • Drain timer: coordinatorQueue.
//
// ISOLATION INVARIANT [G8]: if removed, the coordinator loses audio capture but
// video recording still works.
// ============================================================================

import Foundation
import AVFoundation
import CoreMedia
import os.log
import LiveKit

// MARK: - InterRecordingAudioCapture

final class InterRecordingAudioCapture {

    // MARK: - Public Interface

    /// Called on `coordinatorQueue` with each mixed CMSampleBuffer.
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    // MARK: - Configuration

    private let coordinatorQueue: DispatchQueue

    /// 48 kHz stereo Float32 — matches InterRecordingEngine's audio input.
    private let processingFormat: AVAudioFormat
    private let channelCount = 2
    /// Frames per render call. 1024 / 48 000 ≈ 21.3 ms.
    private let renderFrameCount = 1024

    // MARK: - Sources (each owns a resampler + ring buffer)

    /// Local mic source (combined local renderer — unchanged source, ring-buffered now).
    private var localSource: RecordingAudioSource?
    /// Remote per-track sources, keyed by track sid. Mutated only on coordinatorQueue.
    private var remoteSources: [String: RecordingAudioSource] = [:]
    /// Remote tracks we attached a sink to, so we can detach on remove. coordinatorQueue.
    private var remoteTracks: [String: RemoteAudioTrack] = [:]

    private var renderTimer: DispatchSourceTimer?
    private var running = false

    private static let log = OSLog(subsystem: "com.inter.app", category: "RecordingAudioCapture")

    // MARK: - Init

    init(coordinatorQueue: DispatchQueue) {
        self.coordinatorQueue = coordinatorQueue
        self.processingFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    }

    // MARK: - Start / Stop

    func start() {
        dispatchPrecondition(condition: .onQueue(coordinatorQueue))
        guard !running else {
            os_log(.info, log: Self.log, "Audio capture already started")
            return
        }
        running = true

        // Local mic: same combined-local source as before, now ring-buffered.
        let localSrc = RecordingAudioSource(targetFormat: processingFormat,
                                            capacityFrames: 48_000) // ~1s
        localSource = localSrc
        AudioManager.shared.add(localAudioRenderer: localSrc)

        startRenderTimer()
        os_log(.info, log: Self.log, "Audio capture started (per-track manual summation)")
    }

    func stop() {
        teardown()
        os_log(.info, log: Self.log, "Audio capture stopped")
    }

    // MARK: - Per-track remote audio (recording-safe; pre-volume)

    /// Attach a recording sink to a remote audio track. coordinatorQueue.
    func addRemoteTrack(_ track: RemoteAudioTrack, sid: String) {
        dispatchPrecondition(condition: .onQueue(coordinatorQueue))
        guard running, !sid.isEmpty, remoteSources[sid] == nil else { return }
        let src = RecordingAudioSource(targetFormat: processingFormat, capacityFrames: 48_000)
        remoteSources[sid] = src
        remoteTracks[sid] = track
        track.add(audioRenderer: src)
        os_log(.info, log: Self.log, "Added remote audio sink (sid=%{public}@, total=%d)",
               sid, remoteSources.count)
    }

    /// Detach a remote track's recording sink. coordinatorQueue.
    func removeRemoteTrack(sid: String) {
        dispatchPrecondition(condition: .onQueue(coordinatorQueue))
        guard !sid.isEmpty else { return }
        if let track = remoteTracks[sid], let src = remoteSources[sid] {
            track.remove(audioRenderer: src)
        }
        remoteSources[sid] = nil
        remoteTracks[sid] = nil
        os_log(.info, log: Self.log, "Removed remote audio sink (sid=%{public}@, total=%d)",
               sid, remoteSources.count)
    }

    // MARK: - Teardown

    private func teardown() {
        // NOTE: callable from `deinit` (arbitrary thread) as well as coordinatorQueue,
        // so no queue precondition here — mirrors the prior implementation. The timer is
        // cancelled first; remaining state mutation races are bounded as before.
        renderTimer?.cancel()
        renderTimer = nil

        if let src = localSource { AudioManager.shared.remove(localAudioRenderer: src) }
        localSource = nil

        for (sid, track) in remoteTracks {
            if let src = remoteSources[sid] { track.remove(audioRenderer: src) }
        }
        remoteSources.removeAll()
        remoteTracks.removeAll()
        running = false
    }

    // MARK: - Render Timer

    private func startRenderTimer() {
        let timer = DispatchSource.makeTimerSource(queue: coordinatorQueue)
        let intervalNs = UInt64(Double(renderFrameCount) / processingFormat.sampleRate * 1_000_000_000)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(intervalNs)))
        timer.setEventHandler { [weak self] in self?.renderAndDeliver() }
        renderTimer = timer
        timer.resume()
    }

    // MARK: - Manual Mix + Deliver

    /// Scratch buffers (coordinatorQueue-only) to avoid per-tick allocation.
    private lazy var _mix = [Float](repeating: 0, count: renderFrameCount * 2)
    private lazy var _scratch = [Float](repeating: 0, count: renderFrameCount * 2)

    private func renderAndDeliver() {
        let interleavedCount = renderFrameCount * channelCount

        // Sum local + all remote sources (each pops one frame; underflow = silence).
        for i in 0..<interleavedCount { _mix[i] = 0 }

        if let local = localSource {
            local.popInterleaved(into: &_scratch, count: interleavedCount)
            for i in 0..<interleavedCount { _mix[i] += _scratch[i] }
        }
        for src in remoteSources.values {
            src.popInterleaved(into: &_scratch, count: interleavedCount)
            for i in 0..<interleavedCount { _mix[i] += _scratch[i] }
        }

        // Soft peak guard: summing multiple talkers can exceed full scale → clamp.
        // (Mirrors the implicit headroom an AVAudioEngine mixer would have provided.)
        for i in 0..<interleavedCount {
            let v = _mix[i]
            if v > 1.0 { _mix[i] = 1.0 } else if v < -1.0 { _mix[i] = -1.0 }
        }

        if let sb = makeCMSampleBuffer(fromInterleaved: _mix, frameCount: renderFrameCount) {
            onSampleBuffer?(sb)
        }
    }

    // MARK: - CMSampleBuffer Conversion (interleaved Float32 → CMSampleBuffer)

    private func makeCMSampleBuffer(fromInterleaved interleaved: [Float], frameCount: Int) -> CMSampleBuffer? {
        let channels = channelCount
        let sampleCount = frameCount * channels
        let byteSize = sampleCount * MemoryLayout<Float>.size

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

        var fmtDesc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmtDesc
        ) == noErr, let fmt = fmtDesc else { return nil }

        let pts = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 48_000)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(frameCount),
                             timescale: CMTimeScale(processingFormat.sampleRate)),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)

        var blockBuf: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteSize,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: byteSize, flags: 0, blockBufferOut: &blockBuf
        ) == kCMBlockBufferNoErr, let bb = blockBuf else { return nil }

        let ok = interleaved.withUnsafeBytes { ptr -> Bool in
            CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!, blockBuffer: bb,
                offsetIntoDestination: 0, dataLength: byteSize) == kCMBlockBufferNoErr
        }
        guard ok else { return nil }

        var sampleBuf: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: bb, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt,
            sampleCount: frameCount, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuf
        ) == noErr else { return nil }

        return sampleBuf
    }
}

// MARK: - RecordingAudioSource

/// Bridges LiveKit's `AudioRenderer` to an SPSC interleaved-float ring buffer.
/// Producer = LiveKit audio thread (`render`); consumer = coordinatorQueue (`popInterleaved`).
/// Resamples / channel-maps to the target (48 kHz stereo) via a lazy `AVAudioConverter`.
private final class RecordingAudioSource: NSObject, AudioRenderer, @unchecked Sendable {

    private let targetFormat: AVAudioFormat
    private let channels: Int

    private let _lock = NSLock()
    private var _converter: AVAudioConverter?
    // Interleaved float ring.
    private let capacity: Int
    private var ring: [Float]
    private var writeIdx = 0
    private var available = 0

    init(targetFormat: AVAudioFormat, capacityFrames: Int) {
        self.targetFormat = targetFormat
        self.channels = Int(targetFormat.channelCount)
        self.capacity = capacityFrames * channels
        self.ring = [Float](repeating: 0, count: capacity)
        super.init()
    }

    // MARK: AudioRenderer (LiveKit audio thread)

    func render(pcmBuffer: AVAudioPCMBuffer) {
        guard pcmBuffer.frameLength > 0 else { return }
        let srcFmt = pcmBuffer.format

        let outBuf: AVAudioPCMBuffer
        if srcFmt.sampleRate == targetFormat.sampleRate,
           srcFmt.channelCount == targetFormat.channelCount {
            outBuf = pcmBuffer
        } else {
            let conv: AVAudioConverter? = {
                _lock.lock(); defer { _lock.unlock() }
                if _converter == nil || _converter?.inputFormat != srcFmt {
                    _converter = AVAudioConverter(from: srcFmt, to: targetFormat)
                }
                return _converter
            }()
            guard let conv else { return }
            let ratio = targetFormat.sampleRate / srcFmt.sampleRate
            let outFrames = AVAudioFrameCount(Double(pcmBuffer.frameLength) * ratio) + 1
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames)
            else { return }
            var err: NSError?
            conv.convert(to: converted, error: &err) { _, status in
                status.pointee = .haveData; return pcmBuffer
            }
            guard err == nil, converted.frameLength > 0 else { return }
            outBuf = converted
        }

        guard let chData = outBuf.floatChannelData else { return }
        let frames = Int(outBuf.frameLength)
        let ch = min(channels, Int(outBuf.format.channelCount))
        // Interleave into the ring (overwrite-oldest on overflow).
        _lock.lock()
        for f in 0..<frames {
            for c in 0..<channels {
                // If source has fewer channels than target, duplicate channel 0.
                let srcC = c < ch ? c : 0
                ring[writeIdx] = chData[srcC][f]
                writeIdx = (writeIdx + 1) % capacity
            }
            available = min(available + channels, capacity)
        }
        _lock.unlock()
    }

    // MARK: Consumer (coordinatorQueue)

    /// Pop `count` interleaved samples into `dest`; zero-fill any underflow.
    func popInterleaved(into dest: inout [Float], count: Int) {
        _lock.lock()
        let toRead = min(count, available)
        // Oldest sample index = writeIdx - available (mod capacity).
        var readIdx = ((writeIdx - available) % capacity + capacity) % capacity
        for i in 0..<toRead {
            dest[i] = ring[readIdx]
            readIdx = (readIdx + 1) % capacity
        }
        for i in toRead..<count { dest[i] = 0 }
        available -= toRead
        _lock.unlock()
    }
}
