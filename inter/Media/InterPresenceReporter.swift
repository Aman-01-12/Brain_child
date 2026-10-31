// ============================================================================
// InterPresenceReporter.swift
// inter
//
// PRESENCE MONITORING (provisional, server flag default OFF).
//
// Batches CLOSED presence events and POSTs them over HTTPS through
// InterTokenService every 15 s and on stop. Delete it with the rest of the
// feature. See .agents/tasks/presence-monitoring/REMOVAL.md.
//
// NEVER SENDS PIXELS. Not a frame, not a crop, not a thumbnail, not a landmark,
// not a numeric series — ever. That is enforced structurally rather than by
// discipline: `PresenceEvent` is a struct of String / Double / Int, and
// `PresenceEvent.asPayload()` is the ONLY serialisation path in the pipeline.
// There is no second encoder in this file.
//
// NOT over the LiveKit DataChannel and NOT over Socket.IO (§7.6: no behavioural
// data crosses the SFU). The upload is the one server-authorised ingest path.
//
// An EMPTY batch is VALID and IS the heartbeat: the server records a
// `monitoring_gap` after PRESENCE_GAP_SECONDS of silence, so a clean session
// that simply stopped posting would be filled with gaps that never happened.
// ============================================================================

import Foundation
import os.log

public final class InterPresenceReporter {

    /// Injected uploader, so the reporter unit-tests with a fake and the one
    /// real implementation (InterTokenService.uploadPresenceEvents) stays in the
    /// coordinator. Completion: (accepted count, HTTP status, error).
    public typealias Uploader = (_ events: [[String: Any]],
                                 _ completion: @escaping (Int, Int, Error?) -> Void) -> Void

    /// Hard cap. Overflow drops the OLDEST events and counts them; the server's
    /// own `monitoring_gap` records the resulting silence, which is the honest
    /// outcome — the client never silently pretends a full buffer was a quiet
    /// session.
    public static let maxBufferedEvents = 200

    /// 15.0 s, per §D.
    public static let flushInterval: TimeInterval = 15.0

    /// Called once, on the main queue, when the server refuses the ingest with
    /// 403 or 409: reporting stops and monitoring is reported as off upward so
    /// the candidate's indicator cannot keep claiming it is on.
    public var monitoringOffHandler: (() -> Void)?

    private(set) var eventsDropped: Int = 0
    private(set) var eventsSent: Int = 0
    private(set) var flushCount: Int = 0
    private(set) var isStopped: Bool = false

    private let detectorVersion: String
    private let uploader: Uploader
    private let queue = DispatchQueue(label: "inter.presence.report", qos: .utility)
    private var buffer: [PresenceEvent] = []
    private var timer: DispatchSourceTimer?

    public init(detectorVersion: String, uploader: @escaping Uploader) {
        self.detectorVersion = detectorVersion
        self.uploader = uploader
    }

    // MARK: - Lifecycle

    /// Start the 15 s cadence. The first post goes out one interval in, so the
    /// session's first batch carries whatever the first 15 s produced.
    public func start() {
        queue.async { [weak self] in
            guard let self = self, self.timer == nil, !self.isStopped else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + InterPresenceReporter.flushInterval,
                           repeating: InterPresenceReporter.flushInterval,
                           leeway: .seconds(1))
            timer.setEventHandler { [weak self] in
                self?.flushLocked()
            }
            self.timer = timer
            timer.resume()
        }
    }

    /// Flush whatever is buffered and stop for good.
    public func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.timer?.cancel()
            self.timer = nil
            if !self.isStopped {
                self.flushLocked()
            }
            self.isStopped = true
        }
    }

    // MARK: - Buffering

    /// Buffer closed events. Cheap and non-blocking: called from the detector
    /// path at most a few times a minute.
    public func enqueue(_ events: [PresenceEvent]) {
        guard !events.isEmpty else { return }
        queue.async { [weak self] in
            guard let self = self, !self.isStopped else { return }
            self.buffer.append(contentsOf: events)
            if self.buffer.count > InterPresenceReporter.maxBufferedEvents {
                let overflow = self.buffer.count - InterPresenceReporter.maxBufferedEvents
                self.buffer.removeFirst(overflow)
                self.eventsDropped += overflow
                interLogError(InterLog.media,
                              "Presence: buffer full, dropped %{public}d oldest event(s)", overflow)
            }
        }
    }

    /// Flush now (used by `stop` and the timer, and available to the owner).
    public func flush() {
        queue.async { [weak self] in self?.flushLocked() }
    }

    // MARK: - Upload

    /// Must run on `queue`.
    private func flushLocked() {
        guard !isStopped else { return }
        flushCount += 1

        let batch = buffer
        buffer.removeAll(keepingCapacity: true)

        // THE ONLY serialisation path. One call per event, nothing added.
        let payload = batch.map { $0.asPayload(detectorVersion: detectorVersion) }
        let count = payload.count

        uploader(payload) { [weak self] accepted, status, error in
            guard let self = self else { return }
            self.queue.async {
                if status == 403 || status == 409 {
                    // The server has withdrawn permission (consent revoked, the
                    // room was never armed, the event type is disabled, or the
                    // leave token no longer authorises this identity). Stop
                    // reporting and say so upward — a stale "monitoring on"
                    // indicator must be impossible.
                    interLogError(InterLog.media,
                                  "Presence: ingest refused (HTTP %{public}d) — reporting stops", status)
                    self.isStopped = true
                    self.timer?.cancel()
                    self.timer = nil
                    self.buffer.removeAll()
                    let handler = self.monitoringOffHandler
                    DispatchQueue.main.async { handler?() }
                    return
                }
                if error != nil {
                    // Transient failure: put the batch back at the FRONT so
                    // ordering is preserved, subject to the same cap.
                    self.buffer.insert(contentsOf: batch, at: 0)
                    if self.buffer.count > InterPresenceReporter.maxBufferedEvents {
                        let overflow = self.buffer.count - InterPresenceReporter.maxBufferedEvents
                        self.buffer.removeFirst(overflow)
                        self.eventsDropped += overflow
                    }
                    return
                }
                self.eventsSent += accepted
                if count > 0 {
                    interLogInfo(InterLog.media,
                                 "Presence: %{public}d event(s) accepted", accepted)
                }
            }
        }
    }
}
