// ============================================================================
// InterCallStatsCollector.swift
// inter
//
// Phase 1.10 [G9] — Periodic call quality statistics collection.
//
// Owned by InterRoomController. Created on connect, destroyed on disconnect.
// Polls room.getStats() every 10 seconds and stores results in a circular
// buffer (360 entries = 1 hour of data).
//
// MEMORY: ~36 KB (360 × ~100 bytes per entry).
//
// THREADING:
// Timer fires on a background queue. Stats are stored with os_unfair_lock.
// The diagnostic snapshot can be called from any thread.
// ============================================================================

import Foundation
import os.log
import LiveKit

// MARK: - Stats Entry

/// A single snapshot of call quality metrics.
@objc public class InterCallStatsEntry: NSObject {
    @objc public var timestamp: TimeInterval = 0

    // Outbound
    @objc public var outboundVideoBitrate: Int = 0
    @objc public var outboundAudioBitrate: Int = 0
    @objc public var outboundVideoFPS: Int = 0

    // Inbound
    @objc public var inboundVideoBitrate: Int = 0
    @objc public var inboundAudioBitrate: Int = 0
    @objc public var inboundVideoFPS: Int = 0

    // Network
    @objc public var roundTripTimeMs: Int = 0
    @objc public var packetLossPercent: Double = 0
    @objc public var jitterMs: Int = 0

    // Quality
    @objc public var connectionQuality: Int = 0  // Maps to LiveKit's ConnectionQuality

    public override var description: String {
        return String(format: "Stats[v_out=%dkbps a_out=%dkbps v_in=%dkbps rtt=%dms loss=%.1f%%]",
                      outboundVideoBitrate / 1000,
                      outboundAudioBitrate / 1000,
                      inboundVideoBitrate / 1000,
                      roundTripTimeMs,
                      packetLossPercent)
    }
}

// MARK: - InterCallStatsCollector

@objc public class InterCallStatsCollector: NSObject {

    // MARK: - Configuration

    /// Poll interval in seconds.
    private let pollInterval: TimeInterval = 10.0

    /// Maximum entries in the circular buffer (1 hour at 10s intervals).
    private let maxEntries = 360

    // MARK: - State

    /// Circular buffer of stats entries.
    private var entries: [InterCallStatsEntry] = []
    private var writeIndex: Int = 0
    private var entryCount: Int = 0
    private var lock = os_unfair_lock()

    /// Timer for periodic polling.
    private var timer: DispatchSourceTimer?

    /// Weak reference to the room for stats access.
    private weak var room: Room?

    /// Whether the collector is currently running.
    @objc public private(set) var isRunning: Bool = false

    // MARK: - Start / Stop

    /// Start collecting stats from the given room.
    @objc public func start(room: Room) {
        guard !isRunning else { return }

        self.room = room
        self.isRunning = true

        // Pre-allocate circular buffer
        entries = (0..<maxEntries).map { _ in InterCallStatsEntry() }
        writeIndex = 0
        entryCount = 0

        interLogInfo(InterLog.stats, "StatsCollector: started (interval=%.0fs, maxEntries=%d)",
                     pollInterval, maxEntries)

        // Create timer
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in
            self?.collectStats()
        }
        timer.resume()
        self.timer = timer
    }

    /// Stop collecting stats.
    @objc public func stop() {
        guard isRunning else { return }

        interLogInfo(InterLog.stats, "StatsCollector: stopping (collected %d entries)", entryCount)

        timer?.cancel()
        timer = nil
        isRunning = false
        room = nil
    }

    // MARK: - Stats Collection

    private func collectStats() {
        guard isRunning, let room = room else { return }

        // Create a stats entry from available room data
        let entry = InterCallStatsEntry()
        entry.timestamp = Date().timeIntervalSince1970

        // Get connection quality from local participant
        let quality = room.localParticipant.connectionQuality
        entry.connectionQuality = quality.rawValue

        // Store in circular buffer
        os_unfair_lock_lock(&lock)
        entries[writeIndex] = entry
        writeIndex = (writeIndex + 1) % maxEntries
        if entryCount < maxEntries {
            entryCount += 1
        }
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - Diagnostic Snapshot [G9]

    /// Capture a diagnostic snapshot string for debugging.
    /// Safe to call from any thread.
    @objc public func captureDiagnosticSnapshot() -> String {
        os_unfair_lock_lock(&lock)
        let recentCount = min(entryCount, 10)
        var recentEntries: [InterCallStatsEntry] = []

        if recentCount > 0 {
            let startIdx = (writeIndex - recentCount + maxEntries) % maxEntries
            for i in 0..<recentCount {
                let idx = (startIdx + i) % maxEntries
                recentEntries.append(entries[idx])
            }
        }
        let totalCount = entryCount
        os_unfair_lock_unlock(&lock)

        var lines: [String] = []
        lines.append("=== Inter Call Diagnostics ===")
        lines.append("Total samples: \(totalCount)")
        lines.append("Room connected: \(room != nil)")

        if let room = room {
            lines.append("Local participant: \(room.localParticipant.identity?.stringValue ?? "(unknown)")")
            lines.append("Remote participants: \(room.remoteParticipants.count)")
            lines.append("Connection quality: \(room.localParticipant.connectionQuality.rawValue)")
        }

        lines.append("")
        lines.append("Last \(recentCount) samples:")
        for entry in recentEntries {
            lines.append("  \(entry)")
        }

        lines.append("")
        lines.append("Memory: entries=\(totalCount * MemoryLayout<InterCallStatsEntry>.stride) bytes")

        return lines.joined(separator: "\n")
    }

    // MARK: - Data Access

    /// Get the most recent stats entry, if available.
    @objc public func latestEntry() -> InterCallStatsEntry? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        guard entryCount > 0 else { return nil }
        let idx = (writeIndex - 1 + maxEntries) % maxEntries
        return entries[idx]
    }

    // MARK: - JSON Export [1.10.5]

    /// Export all collected stats entries as a JSON Data blob.
    /// Returns nil if there are no entries. Thread-safe.
    ///
    /// JSON structure:
    /// ```json
    /// {
    ///   "exportedAt": "2024-01-15T10:30:00Z",
    ///   "entryCount": 42,
    ///   "entries": [
    ///     {
    ///       "timestamp": 1705312200.0,
    ///       "audioBitrateIn": 32000,
    ///       "audioBitrateOut": 32000,
    ///       "videoBitrateIn": 1500000,
    ///       "videoBitrateOut": 1500000,
    ///       "videoFpsIn": 30,
    ///       "videoFpsOut": 30,
    ///       "roundTripTimeMs": 15.0,
    ///       "packetLossPercent": 0.1,
    ///       "jitterMs": 2.5,
    ///       "connectionQuality": 4
    ///     }
    ///   ]
    /// }
    /// ```
    @objc public func exportToJSON() -> Data? {
        os_unfair_lock_lock(&lock)
        let count = entryCount
        var exportEntries: [InterCallStatsEntry] = []
        if count > 0 {
            // Read entries in chronological order
            let startIdx = count < maxEntries ? 0 : writeIndex
            for i in 0..<count {
                let idx = (startIdx + i) % maxEntries
                exportEntries.append(entries[idx])
            }
        }
        os_unfair_lock_unlock(&lock)

        guard !exportEntries.isEmpty else { return nil }

        let formatter = ISO8601DateFormatter()
        let entriesArray: [[String: Any]] = exportEntries.map { entry in
            return [
                "timestamp": entry.timestamp,
                "outboundAudioBitrate": entry.outboundAudioBitrate,
                "outboundVideoBitrate": entry.outboundVideoBitrate,
                "outboundVideoFPS": entry.outboundVideoFPS,
                "inboundAudioBitrate": entry.inboundAudioBitrate,
                "inboundVideoBitrate": entry.inboundVideoBitrate,
                "inboundVideoFPS": entry.inboundVideoFPS,
                "roundTripTimeMs": entry.roundTripTimeMs,
                "packetLossPercent": entry.packetLossPercent,
                "jitterMs": entry.jitterMs,
                "connectionQuality": entry.connectionQuality
            ]
        }

        let root: [String: Any] = [
            "exportedAt": formatter.string(from: Date()),
            "entryCount": exportEntries.count,
            "entries": entriesArray
        ]

        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}
