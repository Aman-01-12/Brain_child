// ============================================================================
// InterRecordingAudioCapture.swift
// inter
//
// Phase 10 — Gap #14: Extracted audio capture subsystem.
//
// Owns the audio tap on AVAudioEngine's output node, the lock-free ring buffer,
// the interleave scratch wrapper, the 10ms drain timer, and the Float32→
// CMSampleBuffer conversion. The coordinator simply calls start(engine:) /
// stop() and receives CMSampleBuffers via the callback.
//
// THREADING:
//   - start/stop must be called from the coordinator's serial queue.
//   - The tap callback runs on a real-time audio thread (must not lock/alloc/log).
//   - The drain timer fires on `audioConversionQueue` (non-RT).
//   - The engine-restart handler dispatches back to the caller-provided queue.
//
// ISOLATION INVARIANT [G8]:
//   If removed, the coordinator loses audio capture but video recording still works.
// ============================================================================

import Foundation
import AVFoundation
import CoreMedia
import os.log
import Atomics
import LiveKit

// MARK: - InterRecordingAudioCapture

/// Self-contained audio capture subsystem for recording.
///
/// Usage:
/// ```
/// let capture = InterRecordingAudioCapture(coordinatorQueue: queue)
/// capture.onSampleBuffer = { sampleBuffer in engine.appendAudioSampleBuffer(sampleBuffer) }
/// capture.start()
/// // ... recording ...
/// capture.stop()
/// ```
final class InterRecordingAudioCapture {

    // MARK: - Configuration

    /// Called on `audioConversionQueue` with each drained CMSampleBuffer.
    ///
    /// **Threading contract**: Must be set on `coordinatorQueue` *before*
    /// calling `start()` and must not be mutated until after `stop()` returns.
    /// The `start()` → `DispatchSource.resume()` path provides the
    /// happens-before guarantee that the drain timer sees the assigned value.
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    // MARK: - Private Properties

    /// The serial queue on which start/stop must be called (coordinator's queue).
    private let coordinatorQueue: DispatchQueue

    /// Ring buffer: 500ms at 48kHz stereo.
    private var audioRingBuffer: AudioCaptureRingBuffer?

    /// Drain timer: 10ms interval on `audioConversionQueue`.
    private var audioDrainTimer: DispatchSourceTimer?

    /// Conversion queue (non-RT).
    private let audioConversionQueue = DispatchQueue(
        label: "inter.recording.audio.conversion",
        qos: .userInitiated
    )

    /// Managed scratch buffer wrapper for the interleave tap callback.
    private var interleaveBuffer: AudioCaptureInterleaveBuffer?

    /// Logging.
    private static let log = OSLog(subsystem: "com.secure.inter.network", category: "audioCapture")

    // MARK: - Init

    init(coordinatorQueue: DispatchQueue) {
        self.coordinatorQueue = coordinatorQueue
    }

    deinit {
        stop()
    }

    // MARK: - Public API

    /// Install the audio tap and start draining samples.
    /// Must be called on `coordinatorQueue`.
    /// Safe to call when already running — tears down existing resources first.
    func start() {
        dispatchPrecondition(condition: .onQueue(coordinatorQueue))

        // Guard against double-start: clean up any existing tap, timer, and
        // buffers so we don't leak resources or orphan an audio tap.
        if audioRingBuffer != nil || audioDrainTimer != nil {
            stop()
        }

        let ringBuffer = AudioCaptureRingBuffer(frameDuration: 0.5,
                                                 sampleRate: 48000,
                                                 channels: 2)
        self.audioRingBuffer = ringBuffer

        // Install tap on the engine's main mixer node — the last node before the hardware
        // output that accumulates all sources. Only mixer/input nodes support installTap;
        // tapping AVAudioOutputNode directly throws "_isInput".
        if let mixerNode = InterAudioEngineAccess.outputNode() {
            let format = mixerNode.outputFormat(forBus: 0)
            let tapChannelCount = max(1, Int(format.channelCount))
            let tapCapacity = 4096 * tapChannelCount
            let scratchWrapper = AudioCaptureInterleaveBuffer(capacity: tapCapacity)
            self.interleaveBuffer = scratchWrapper

            mixerNode.installTap(onBus: 0, bufferSize: 4096, format: format) {
                [weak ringBuffer, scratchWrapper] (buffer, _) in
                guard scratchWrapper.isActive else { return }
                guard let ringBuffer = ringBuffer else { return }
                guard let floatData = buffer.floatChannelData else { return }

                let frameCount = Int(buffer.frameLength)
                let channelCount = Int(buffer.format.channelCount)
                let clampedChannels = min(channelCount, tapChannelCount)
                let interleavedCount = frameCount * clampedChannels

                guard interleavedCount <= scratchWrapper.capacity else { return }

                let scratch = scratchWrapper.pointer
                for frame in 0..<frameCount {
                    for ch in 0..<clampedChannels {
                        scratch[frame * clampedChannels + ch] = floatData[ch][frame]
                    }
                }
                ringBuffer.write(scratch, count: interleavedCount)
            }
        }

        // Drain timer: 10ms interval
        let drain = DispatchSource.makeTimerSource(queue: audioConversionQueue)
        drain.schedule(deadline: .now(), repeating: .milliseconds(10))
        drain.setEventHandler { [weak self, weak ringBuffer] in
            guard let self = self, let ringBuffer = ringBuffer else { return }

            let dropped = ringBuffer.exchangeOverflowCount()
            if dropped > 0 {
                os_log(.error, log: Self.log,
                       "Recording: audio ring buffer overflow — %llu write(s) dropped since last drain",
                       dropped)
            }

            let drainCount = 960  // 10ms @ 48kHz stereo
            var samples = [Float](repeating: 0, count: drainCount)
            let read = ringBuffer.read(into: &samples, count: drainCount)
            if read > 0 {
                if let sampleBuffer = self.convertFloatsToCMSampleBuffer(samples, count: read) {
                    self.onSampleBuffer?(sampleBuffer)
                }
            }
        }
        audioDrainTimer = drain
        drain.resume()

        // Engine-restart recovery: re-install tap if the AVAudioEngine restarts.
        InterAudioEngineAccess.shared.onEngineRestart = { [weak self] in
            guard let self = self else { return }
            self.coordinatorQueue.async {
                os_log(.info, log: Self.log,
                       "Recording: AVAudioEngine restarted — re-installing audio tap")
                self.stop()
                self.start()
            }
        }
    }

    /// Remove the audio tap and cancel the drain timer.
    /// May be called from `coordinatorQueue` or `deinit`.
    func stop() {
        InterAudioEngineAccess.shared.onEngineRestart = nil

        audioDrainTimer?.cancel()
        audioDrainTimer = nil

        if let mixerNode = InterAudioEngineAccess.outputNode() {
            mixerNode.removeTap(onBus: 0)
        }

        interleaveBuffer?.invalidate()
        interleaveBuffer = nil

        audioRingBuffer?.reset()
        audioRingBuffer = nil
    }

    // MARK: - Float32 → CMSampleBuffer Conversion

    private func convertFloatsToCMSampleBuffer(_ samples: [Float], count: Int) -> CMSampleBuffer? {
        let channelCount: UInt32 = 2
        let sampleRate: Float64 = 48000.0
        let frameCount = count / Int(channelCount)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size) * channelCount,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size) * channelCount,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?
        let fmtStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard fmtStatus == noErr, let fmt = formatDescription else { return nil }

        let dataSize = count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let block = blockBuffer else { return nil }

        let copyStatus = CMBlockBufferReplaceDataBytes(
            with: samples,
            blockBuffer: block,
            offsetIntoDestination: 0,
            dataLength: dataSize
        )
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        let timing = CMSampleTimingInfo(
            duration: CMTimeMake(value: Int64(frameCount), timescale: Int32(sampleRate)),
            presentationTimeStamp: CMTimeMakeWithSeconds(CACurrentMediaTime(), preferredTimescale: Int32(sampleRate)),
            decodeTimeStamp: .invalid
        )

        var timingInfo = timing
        let sbStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fmt,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr else { return nil }

        return sampleBuffer
    }
}

// MARK: - Interleave Buffer (Managed Scratch Wrapper)

/// Reference-counted wrapper for the interleave scratch buffer used by the audio tap.
/// See InterRecordingCoordinator.swift for the full safety contract documentation.
private final class AudioCaptureInterleaveBuffer: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<Float>
    let capacity: Int
    private let _isActive = ManagedAtomic<Bool>(true)

    var isActive: Bool { _isActive.load(ordering: .acquiring) }

    init(capacity: Int) {
        self.capacity = capacity
        self.pointer = .allocate(capacity: capacity)
        self.pointer.initialize(repeating: 0, count: capacity)
    }

    func invalidate() {
        _isActive.store(false, ordering: .releasing)
    }

    deinit {
        pointer.deallocate()
    }
}

// MARK: - Audio Capture Ring Buffer (Lock-free SPSC)

/// Lock-free single-producer single-consumer ring buffer for recording audio capture.
/// See InterRecordingCoordinator.swift for the full atomic-ordering rationale.
private final class AudioCaptureRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let buffer: UnsafeMutablePointer<Float>
    private let _head = ManagedAtomic<UInt64>(0)
    private let _tail = ManagedAtomic<UInt64>(0)
    private let _overflowCount = ManagedAtomic<UInt64>(0)

    var overflowCount: UInt64 { _overflowCount.load(ordering: .relaxed) }

    /// Atomically read and reset the overflow counter.
    /// Returns the number of overflows since the last call.
    func exchangeOverflowCount() -> UInt64 {
        return _overflowCount.exchange(0, ordering: .relaxed)
    }

    init(frameDuration: TimeInterval, sampleRate: Int, channels: Int) {
        self.capacity = Int(frameDuration * Double(sampleRate)) * channels
        self.buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }

    deinit {
        buffer.deallocate()
    }

    @discardableResult
    func write(_ samples: UnsafePointer<Float>, count: Int) -> Bool {
        let h = _head.load(ordering: .relaxed)
        let t = _tail.load(ordering: .acquiring)
        let used = Int(h &- t)
        let free = capacity - used
        guard count <= free else {
            _overflowCount.wrappingIncrement(ordering: .relaxed)
            return false
        }
        for i in 0..<count {
            let idx = Int((h &+ UInt64(i)) % UInt64(capacity))
            buffer[idx] = samples[i]
        }
        _head.store(h &+ UInt64(count), ordering: .releasing)
        return true
    }

    func read(into destination: inout [Float], count: Int) -> Int {
        let h = _head.load(ordering: .acquiring)
        let t = _tail.load(ordering: .relaxed)
        let available = Int(h &- t)
        let toRead = min(count, available)

        for i in 0..<toRead {
            let idx = Int((t &+ UInt64(i)) % UInt64(capacity))
            destination[i] = buffer[idx]
        }
        if toRead < count {
            for i in toRead..<count {
                destination[i] = 0
            }
        }
        _tail.store(t &+ UInt64(toRead), ordering: .releasing)
        return toRead
    }

    func reset() {
        _head.store(0, ordering: .relaxed)
        _tail.store(0, ordering: .relaxed)
        _overflowCount.store(0, ordering: .relaxed)
    }
}
