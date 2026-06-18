// ============================================================================
// InterCodeEditorController.swift
// inter
//
// Collaborative Code Editor (Interview) — Task 4: the TRANSPORT layer.
//
// A DataChannel controller modelled on `InterChatController` / `InterPollController`:
// same publish path (`localParticipant.publish(data:options:)` on a dedicated
// topic, reliable+ordered), same attested-sender reconciliation, same per-sender
// rate limiting. It drives the pure RGA model (`CodeEditorDocument`) and the
// wire layer (`InterCodeEditorMessage`); see design.md "Transport, Attestation
// & Flood Resistance".
//
// Responsibilities (spec Task 4):
//   • Publish local ops, COALESCING a rapid keystroke run into one `ops`
//     message and CHUNKING long pastes so each encoded message stays under
//     `InterCodeEditorMessage.maxMessageBytes` (R6.2).
//   • Publish cursor + language changes (R2.4, R3.1).
//   • Queue outbound ops in order while the DataChannel is down and flush on
//     reconnect (R8.2).
//   • Decode inbound messages, reconcile the attested sender over the
//     self-declared field, REJECT inserts authored "as" the other participant,
//     and rate-limit per attested sender (R5.5, R6.1).
//   • Apply accepted ops to the document and surface remote cursor / language /
//     a size-limit notice to the view model via a delegate (R2.2, R2.4, R3.2).
//
// The snapshot request/serve assembly (late join, reconnect, atomic swap) is
// Task 5; the decode switch routes those types to documented stubs here so the
// seam is clean.
//
// THREADING:
//   `@MainActor`. The room dispatcher delivers data on the main queue;
//   `handleReceivedData` is `nonisolated` and re-enters the actor synchronously
//   (preserving the reliable channel's ordering — never via an async `Task`).
//
// TESTABILITY:
//   The LiveKit `Room` is hidden behind the `InterCodeEditorTransport` seam so
//   the coalescing / chunking / rate-limit / queue-and-flush logic is testable
//   without a live Room (tests inject a capturing fake). The coalescing/chunking
//   (`CodeEditorOutboundBuilder`) and rate-limit (`CodeEditorRateLimiter`) logic
//   are additionally factored into pure types tested directly.
// ============================================================================

import Foundation
import os.log
import LiveKit

// MARK: - Delegate

/// Notifies the view model of applied remote ops / remote cursor / language /
/// size-limit changes. Mirrors the `InterControlSignalDelegate` style but is a
/// plain Swift protocol because its payloads (`Op`, `ElementID`) are Swift value
/// types with no Objective-C representation. Default implementations let a
/// conformer implement only the events it needs.
@MainActor
protocol InterCodeEditorControllerDelegate: AnyObject {

    /// Remote ops were integrated into the shared document. The view model
    /// should refresh the rendered text (preserving the local caret).
    func codeEditorController(_ controller: InterCodeEditorController,
                              didIntegrateRemoteOps ops: [Op],
                              from senderIdentity: String)

    /// A remote cursor/selection update arrived (anchor/head element ids).
    func codeEditorController(_ controller: InterCodeEditorController,
                              didReceiveRemoteCursorAnchor anchor: ElementID,
                              head: ElementID,
                              from senderIdentity: String)

    /// A remote language-selection change arrived (LWW register value).
    func codeEditorController(_ controller: InterCodeEditorController,
                              didReceiveLanguage language: String,
                              lamport: UInt64,
                              from senderIdentity: String)

    /// A local insert was refused because the document hit `maxLiveChars`
    /// (R6.3). The view model should surface a non-blocking in-tool notice.
    func codeEditorControllerDidHitSizeLimit(_ controller: InterCodeEditorController)

    /// The controller could not heal a divergence automatically (an inbound
    /// insert referenced an `originLeft` that never resolved, and a recovery
    /// snapshot request did not reconcile it — R8.4). The view model should
    /// surface a NON-BLOCKING in-tool notice (mirroring the size-limit notice)
    /// while keeping local editing alive; recovery may still complete later.
    func codeEditorControllerDidRequestResync(_ controller: InterCodeEditorController)
}

extension InterCodeEditorControllerDelegate {
    func codeEditorController(_ controller: InterCodeEditorController,
                              didIntegrateRemoteOps ops: [Op],
                              from senderIdentity: String) {}
    func codeEditorController(_ controller: InterCodeEditorController,
                              didReceiveRemoteCursorAnchor anchor: ElementID,
                              head: ElementID,
                              from senderIdentity: String) {}
    func codeEditorController(_ controller: InterCodeEditorController,
                              didReceiveLanguage language: String,
                              lamport: UInt64,
                              from senderIdentity: String) {}
    func codeEditorControllerDidHitSizeLimit(_ controller: InterCodeEditorController) {}
    func codeEditorControllerDidRequestResync(_ controller: InterCodeEditorController) {}
}

// MARK: - Transport seam

/// Minimal seam over the LiveKit publish path so the controller's
/// coalescing / chunking / rate-limit / queue-and-flush logic is testable
/// without a live `Room`. Production uses `InterCodeEditorRoomTransport`
/// (backed by `InterRoomController`); tests substitute a capturing fake.
@MainActor
protocol InterCodeEditorTransport: AnyObject {
    /// Whether the DataChannel is currently usable (room connected).
    var isConnected: Bool { get }
    /// Publish `data` on the code-editor topic. Fire-and-forget.
    func publish(_ data: Data, reliable: Bool)
}

/// Production transport: publishes on the `codeEditor` topic via the room's
/// local participant, exactly like `InterChatController` / `InterPollController`.
@MainActor
final class InterCodeEditorRoomTransport: InterCodeEditorTransport {

    private weak var roomController: InterRoomController?

    init(roomController: InterRoomController?) {
        self.roomController = roomController
    }

    var isConnected: Bool {
        roomController?.connectionState == .connected
    }

    func publish(_ data: Data, reliable: Bool) {
        guard let rc = roomController else { return }
        Task {
            do {
                let localParticipant = rc.publisher.localParticipant
                try await localParticipant?.publish(data: data, options: DataPublishOptions(
                    topic: InterCodeEditorController.codeEditorTopic,
                    reliable: reliable
                ))
                interLogDebug(InterLog.room, "CodeEditorController: published (%d bytes)", data.count)
            } catch {
                interLogError(InterLog.room, "CodeEditorController: publish failed: %{public}@",
                              error.localizedDescription)
            }
        }
    }
}

// MARK: - Pure: outbound message builder (coalescing + chunking)

/// Pure builder that turns a flat batch of model `Op`s into the fewest
/// `InterCodeEditorMessage`s whose ENCODED size each stays under `maxBytes`.
///
/// This is what makes a rapid keystroke run COALESCE into one `ops` message
/// (the whole run is one batch when it fits) and a long paste CHUNK across
/// several ordered messages (R6.2). The op count per message is computed from a
/// conservative per-op byte upper bound (O(1)) so a 100k-char paste does not
/// trigger O(n²) re-encoding; a defensive encode-and-bisect guarantees the
/// ceiling even in the worst case.
enum CodeEditorOutboundBuilder {

    /// The conservative number of ops whose combined encoding is GUARANTEED to
    /// fit under `maxBytes` for the given sender. Exposed so tests can size a
    /// "single coalesced message" run exactly.
    static func maxOpsPerMessage(senderIdentity: String, maxBytes: Int) -> Int {
        // Envelope: {"type":"ops","senderIdentity":"<id>","ops":[ ... ]}
        let envelopeOverhead = 128 + senderIdentity.utf8.count
        // Worst-case bytes for ONE encoded op: an insert carrying two ids (id +
        // originLeft), each with the (longest) site string and a 20-digit
        // UInt64 seq, a generously-bounded grapheme value, plus JSON syntax and
        // the array comma. Sites are participant identities; 64 is a safe floor.
        let siteBudget = max(senderIdentity.utf8.count, 64)
        let perOp = 96 + (2 * siteBudget) + (2 * 20) + 64 + 4
        let usable = max(1, maxBytes - envelopeOverhead)
        return max(1, usable / perOp)
    }

    /// Build the ordered `ops` messages for `ops`. Returns `[]` for an empty
    /// batch.
    static func opsMessages(for ops: [Op],
                            senderIdentity: String,
                            maxBytes: Int) -> [InterCodeEditorMessage] {
        guard !ops.isEmpty else { return [] }
        let chunkSize = maxOpsPerMessage(senderIdentity: senderIdentity, maxBytes: maxBytes)
        var messages: [InterCodeEditorMessage] = []
        var index = 0
        while index < ops.count {
            let end = min(index + chunkSize, ops.count)
            let chunk = Array(ops[index..<end])
            messages.append(contentsOf: fit(chunk, senderIdentity: senderIdentity, maxBytes: maxBytes))
            index = end
        }
        return messages
    }

    /// Defensive: emit `ops` as one message if it fits, otherwise bisect until
    /// each piece fits. The estimate above keeps this from recursing in
    /// practice; it exists so a pathological value can never breach the ceiling.
    private static func fit(_ ops: [Op],
                            senderIdentity: String,
                            maxBytes: Int) -> [InterCodeEditorMessage] {
        let message = InterCodeEditorMessage.opsMessage(ops, senderIdentity: senderIdentity)
        if let data = message.toJSONData(), data.count <= maxBytes {
            return [message]
        }
        // A single op cannot be split further; emit it (the decoder will reject
        // it on the peer if it is genuinely oversized — single chars never are).
        guard ops.count > 1 else { return [message] }
        let mid = ops.count / 2
        return fit(Array(ops[0..<mid]), senderIdentity: senderIdentity, maxBytes: maxBytes)
             + fit(Array(ops[mid..<ops.count]), senderIdentity: senderIdentity, maxBytes: maxBytes)
    }
}

// MARK: - Pure: snapshot chunk builder

/// Pure builder that splits a full-document `Snapshot` into the fewest ordered
/// `snapshot` messages whose ENCODED size each stays under `maxBytes` (R4.3).
///
/// A snapshot carries the WHOLE element list (including tombstones), so for a
/// large interview document it can exceed the DataChannel ceiling. This builder
/// slices the element list across messages tagged with `CodeEditorSnapshotChunk
/// { index, count }`; the final index is the "complete" marker. A snapshot that
/// fits in one message is emitted WITHOUT chunk metadata (a self-contained
/// snapshot). The receiver assembles slices in index order into a staging
/// buffer and applies the document atomically only once every index has arrived
/// — never leaving a partially-applied document.
enum CodeEditorSnapshotBuilder {

    /// Conservative count of elements whose combined encoding is GUARANTEED to
    /// fit under `maxBytes`. Exposed so a test can size a "tiny ceiling" run.
    static func maxElementsPerMessage(senderIdentity: String,
                                      language: String,
                                      maxBytes: Int) -> Int {
        // Envelope: {"type":"snapshot","senderIdentity":"<id>","snapshot":
        //   {"elements":[ ... ],"languageState":{"language":"<lang>","lamport":N}},
        //   "snapshotChunk":{"index":I,"count":C}}
        let envelopeOverhead = 192 + senderIdentity.utf8.count + language.utf8.count
        // Worst-case bytes for ONE encoded element: id + originLeft (each a site
        // string + a 20-digit seq), a generously-bounded grapheme value, the
        // `deleted` flag, plus JSON syntax and the array comma.
        let siteBudget = max(senderIdentity.utf8.count, 64)
        let perElement = 96 + (2 * siteBudget) + (2 * 20) + 64 + 16 + 4
        let usable = max(1, maxBytes - envelopeOverhead)
        return max(1, usable / perElement)
    }

    /// Build the ordered `snapshot` messages for `snapshot`. A snapshot that
    /// fits in a single message is returned untagged; otherwise each message is
    /// tagged with its `{ index, count }`.
    static func snapshotMessages(for snapshot: Snapshot,
                                 language: String,
                                 lamport: UInt64,
                                 senderIdentity: String,
                                 maxBytes: Int) -> [InterCodeEditorMessage] {
        // Fast path: the whole snapshot fits in one untagged message.
        let single = InterCodeEditorMessage.snapshotMessage(snapshot, language: language,
                                                            lamport: lamport,
                                                            senderIdentity: senderIdentity)
        if let data = single.toJSONData(), data.count <= maxBytes {
            return [single]
        }

        // Chunk: slice the element list into ceiling-bounded pieces.
        let elements = snapshot.elements
        let chunkSize = maxElementsPerMessage(senderIdentity: senderIdentity,
                                              language: language, maxBytes: maxBytes)
        var slices: [[Element]] = []
        var index = 0
        while index < elements.count {
            let end = min(index + chunkSize, elements.count)
            slices.append(contentsOf: bisectToFit(Array(elements[index..<end]),
                                                  language: language, lamport: lamport,
                                                  senderIdentity: senderIdentity, maxBytes: maxBytes))
            index = end
        }
        // An empty element list still produces exactly one slice so the receiver
        // sees a complete (empty) snapshot.
        if slices.isEmpty { slices = [[]] }

        let count = slices.count
        var messages: [InterCodeEditorMessage] = []
        messages.reserveCapacity(count)
        for (i, slice) in slices.enumerated() {
            messages.append(InterCodeEditorMessage.snapshotMessage(
                elements: slice, language: language, lamport: lamport,
                senderIdentity: senderIdentity,
                chunk: CodeEditorSnapshotChunk(index: i, count: count)))
        }
        return messages
    }

    /// Defensive: split `elements` until each slice encodes under `maxBytes`.
    private static func bisectToFit(_ elements: [Element],
                                    language: String,
                                    lamport: UInt64,
                                    senderIdentity: String,
                                    maxBytes: Int) -> [[Element]] {
        let probe = InterCodeEditorMessage.snapshotMessage(
            elements: elements, language: language, lamport: lamport,
            senderIdentity: senderIdentity,
            chunk: CodeEditorSnapshotChunk(index: 0, count: 1))
        if let data = probe.toJSONData(), data.count <= maxBytes {
            return [elements]
        }
        guard elements.count > 1 else { return [elements] }
        let mid = elements.count / 2
        return bisectToFit(Array(elements[0..<mid]), language: language, lamport: lamport,
                           senderIdentity: senderIdentity, maxBytes: maxBytes)
             + bisectToFit(Array(elements[mid..<elements.count]), language: language, lamport: lamport,
                           senderIdentity: senderIdentity, maxBytes: maxBytes)
    }
}

// MARK: - Pure: per-sender sliding-window rate limiter

/// Per-attested-sender sliding window bounding BOTH messages/second and
/// bytes/second (R6.1). Edit traffic is higher-volume than control signals, so
/// the budget is expressed in two dimensions; coalescing keeps legitimate
/// typing far under the cap. Keyed on the attested identity so a flooder cannot
/// rotate the key by spoofing the self-declared sender field.
///
/// Bookkeeping mirrors `InterChatController`'s control-signal window: within a
/// 1s window the counters accumulate (and stay over-budget once tripped, so the
/// remainder of the window is dropped); a message in a fresh window resets it.
final class CodeEditorRateLimiter {

    private let maxMessagesPerSecond: Int
    private let maxBytesPerSecond: Int

    private var windowStart: [String: TimeInterval] = [:]
    private var messageCount: [String: Int] = [:]
    private var byteCount: [String: Int] = [:]

    init(maxMessagesPerSecond: Int, maxBytesPerSecond: Int) {
        self.maxMessagesPerSecond = max(1, maxMessagesPerSecond)
        self.maxBytesPerSecond = max(1, maxBytesPerSecond)
    }

    /// Returns `true` if a `byteCount`-byte message from `sender` is within
    /// budget for the current window, `false` if it should be dropped. Never
    /// throws — dropping must not freeze the UI.
    func allow(sender: String, byteCount: Int, now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        if let start = windowStart[sender], now - start < 1.0 {
            let msgs = (messageCount[sender] ?? 0) + 1
            let bytes = (self.byteCount[sender] ?? 0) + byteCount
            messageCount[sender] = msgs
            self.byteCount[sender] = bytes
            return msgs <= maxMessagesPerSecond && bytes <= maxBytesPerSecond
        }
        // Fresh window.
        windowStart[sender] = now
        messageCount[sender] = 1
        self.byteCount[sender] = byteCount
        // A single message could exceed the byte budget on its own.
        return byteCount <= maxBytesPerSecond
    }

    /// Clear all window state (e.g. on reset/disconnect).
    func reset() {
        windowStart.removeAll()
        messageCount.removeAll()
        byteCount.removeAll()
    }
}

// MARK: - InterCodeEditorController

@objc @MainActor public final class InterCodeEditorController: NSObject {

    // MARK: Topic

    /// DataChannel topic for collaborative-editor messages.
    @objc public static let codeEditorTopic = "codeEditor"

    // MARK: Tunables (documented constants)

    /// Coalescing window: local ops emitted within this interval are batched
    /// into a single `ops` publish (a "typing batch"). 50 ms is comfortably
    /// below human perception of latency while collapsing a fast keystroke run
    /// (or a multi-character paste delivered op-by-op) into one message (R6.2).
    static let coalesceInterval: TimeInterval = 0.05

    /// Inbound per-sender caps (R6.1). Peak legitimate typing — even a paste,
    /// after coalescing — stays far below these; they exist to absorb a flood
    /// without freezing the UI.
    static let maxInboundMessagesPerSecond = 60
    static let maxInboundBytesPerSecond = 256 * 1024

    /// Bounds of the RANDOMISED responder-fallback delay (R4.1). When a
    /// `snapshotRequest` arrives and the local participant is NOT the interview
    /// host, the controller waits a random interval in this range before serving
    /// the snapshot itself — staggering peers so they don't all answer at once,
    /// and giving the host first chance. A snapshot observed in the meantime
    /// cancels the fallback. Duplicate snapshots are harmless (idempotent).
    static let snapshotFallbackDelayRange: ClosedRange<TimeInterval> = 0.4...1.2

    /// Bounded window after which an unresolved `originLeft` triggers a recovery
    /// snapshot request (R8.4). The reliable+ordered channel heals same-sender
    /// gaps quickly; an origin still missing after this window indicates a
    /// cross-sender divergence that a fresh snapshot reconciles.
    static let selfHealWindow: TimeInterval = 2.0

    // MARK: Collaborators

    /// The shared RGA document. Owned for the session by the editor bridge and
    /// injected here; its `site` is the local attested identity.
    let document: CodeEditorDocument

    /// Delegate that bridges remote changes into the view model.
    weak var delegate: InterCodeEditorControllerDelegate?

    /// Weak reference to the room controller (set on `attach`), matching the
    /// chat/poll/Q&A controllers.
    private weak var roomController: InterRoomController?

    /// The publish seam. Production wires `InterCodeEditorRoomTransport`; tests
    /// inject a fake. `internal` so `@testable` tests can substitute it.
    var transport: InterCodeEditorTransport?

    /// The local participant's attested identity, stamped into every outbound
    /// message's `senderIdentity`. Should equal `document.site`.
    private(set) var localIdentity: String

    // MARK: Responder selection seam (Task 5.2)

    /// Whether the LOCAL participant is the interview host. The host answers a
    /// `snapshotRequest` immediately; any other peer answers only after a
    /// randomised fallback delay (R4.1). Host-ness is server-stamped into the
    /// participant's LiveKit JWT metadata (never self-declared), so the
    /// integration layer (Task 10) injects this closure — e.g. backed by
    /// `InterRoomController.role(forParticipantIdentity:) == .host` for the
    /// local identity, or the moderation controller's `localRole`. It defaults
    /// to `false` (treat as a non-host peer), which is the SAFE default: a
    /// non-host still serves after the fallback delay, so recovery never stalls
    /// even if the seam is left unwired.
    var isLocalParticipantHost: () -> Bool = { false }

    /// Source of the randomised responder-fallback delay. Injectable so tests
    /// are deterministic (production uses a uniform random draw within
    /// `snapshotFallbackDelayRange`).
    var snapshotFallbackDelayProvider: () -> TimeInterval = {
        TimeInterval.random(in: InterCodeEditorController.snapshotFallbackDelayRange)
    }

    // MARK: Outbound state

    /// Ops accumulated during the current coalescing window, in order.
    private var pendingOutboundOps: [Op] = []

    /// One-shot coalescing timer; `nil` when no flush is scheduled.
    private var coalesceTimer: Timer?

    /// Ordered outbound messages buffered while the channel is down (R8.2),
    /// flushed in order on reconnect. Bounded in practice by the document's
    /// `maxLiveChars` size clamp, which limits how many local ops can exist.
    private var queuedMessages: [InterCodeEditorMessage] = []

    // MARK: Inbound state

    /// Per-attested-sender inbound rate limiter (R6.1).
    private let inboundRateLimiter = CodeEditorRateLimiter(
        maxMessagesPerSecond: InterCodeEditorController.maxInboundMessagesPerSecond,
        maxBytesPerSecond: InterCodeEditorController.maxInboundBytesPerSecond
    )

    // MARK: Recovery state (Task 5)

    /// `true` while awaiting an authoritative snapshot after `beginRecovery()`.
    /// Inbound ops arriving in this window are BUFFERED rather than applied so
    /// the snapshot defines the baseline; they are replayed (idempotently) once
    /// it lands. Exposed `internal` for test assertions.
    private(set) var isRecovering = false

    /// Ops accepted (authorship-checked) while `isRecovering`, replayed in order
    /// after the snapshot is applied. Each entry keeps its attested sender so
    /// the delegate attribution is correct on replay.
    private var bufferedRemoteOps: [(ops: [Op], from: String)] = []

    /// In-flight chunked-snapshot assembly, keyed by the attested sender of the
    /// chunks. Holds the element slices in a STAGING buffer; the document is
    /// only touched once every index has arrived (atomic swap, R4.3).
    private var snapshotAssemblies: [String: SnapshotAssembly] = [:]

    /// Pending responder-fallback timer + action (non-host peer waiting to serve
    /// a snapshot if the host stays silent — R4.1).
    private var snapshotFallbackTimer: Timer?
    private var pendingSnapshotFallback: (() -> Void)?

    /// Self-heal: the latest known language register (so a served snapshot
    /// carries the current language) and the bounded-window timer that fires a
    /// recovery request for an unresolved `originLeft` (R8.4).
    private var currentLanguage = "Plain text"
    private var currentLanguageLamport: UInt64 = 0
    private var selfHealTimer: Timer?
    private var selfHealAttempted = false

    /// Staging buffer for one in-flight chunked snapshot.
    private struct SnapshotAssembly {
        let expectedCount: Int
        var slices: [Int: [Element]] = [:]
        var language = "Plain text"
        var lamport: UInt64 = 0

        var isComplete: Bool { slices.count >= expectedCount }

        /// The assembled element list in ascending chunk-index order.
        var assembledElements: [Element] {
            var result: [Element] = []
            for i in 0..<expectedCount { result.append(contentsOf: slices[i] ?? []) }
            return result
        }
    }

    // MARK: Init / lifecycle

    /// Create the controller around a session document. `localIdentity` is the
    /// attested identity used to stamp outbound messages and validate inbound
    /// element authorship; it should match `document.site`.
    init(document: CodeEditorDocument, localIdentity: String) {
        self.document = document
        self.localIdentity = localIdentity
        super.init()
    }

    /// Attach to a connected room controller. Wires the production transport and
    /// flushes anything queued during a prior outage. Mirrors the chat/poll
    /// controllers' `attach(to:identity:…)`.
    func attach(to roomController: InterRoomController, identity: String) {
        self.roomController = roomController
        self.localIdentity = identity
        self.transport = InterCodeEditorRoomTransport(roomController: roomController)
        interLogInfo(InterLog.room, "CodeEditorController: attached (identity=%{public}@)", identity)
        drainQueue()
    }

    /// Detach before disconnect: flush any pending coalesced ops, stop the
    /// timer, and drop the room/transport references.
    func detach() {
        flushCoalescedOps()
        coalesceTimer?.invalidate()
        coalesceTimer = nil
        cancelSnapshotFallback()
        selfHealTimer?.invalidate()
        selfHealTimer = nil
        roomController = nil
        transport = nil
        interLogInfo(InterLog.room, "CodeEditorController: detached")
    }

    /// Clear all transient state (e.g. on mode transition or teardown).
    func reset() {
        coalesceTimer?.invalidate()
        coalesceTimer = nil
        cancelSnapshotFallback()
        selfHealTimer?.invalidate()
        selfHealTimer = nil
        selfHealAttempted = false
        pendingOutboundOps.removeAll()
        queuedMessages.removeAll()
        bufferedRemoteOps.removeAll()
        snapshotAssemblies.removeAll()
        isRecovering = false
        inboundRateLimiter.reset()
        interLogInfo(InterLog.room, "CodeEditorController: reset")
    }

    /// Call when the connection is restored so any messages queued during an
    /// outage are flushed in order (R8.2). The integration layer (Task 10)
    /// wires this to the room's connection-state changes.
    func connectionDidRestore() {
        drainQueue()
    }

    // MARK: - Local edit convenience (seam for the view-model bridge, Task 6)

    /// Insert `text` at a live offset, publish the generated ops, and surface a
    /// size-limit notice if the insert was refused (R6.3). Returns the applied
    /// ops (empty if refused).
    @discardableResult
    func applyLocalInsert(at offset: Int, _ text: String) -> [Op] {
        let ops = document.localInsert(at: offset, text)
        if document.didHitSizeLimit {
            delegate?.codeEditorControllerDidHitSizeLimit(self)
        }
        sendLocalOps(ops)
        return ops
    }

    /// Delete a live offset range, publishing the generated delete ops.
    @discardableResult
    func applyLocalDelete(range: Range<Int>) -> [Op] {
        let ops = document.localDelete(range: range)
        sendLocalOps(ops)
        return ops
    }

    // MARK: - Publish path (R6.2, R8.2)

    /// Queue `ops` for publication, coalescing into the current typing batch.
    /// A short window collapses a keystroke run into one `ops` message; long
    /// runs are chunked under the byte ceiling at flush time.
    func sendLocalOps(_ ops: [Op]) {
        guard !ops.isEmpty else { return }
        pendingOutboundOps.append(contentsOf: ops)
        scheduleCoalesceFlush()
    }

    /// Publish a cursor/selection update. Cursor state is EPHEMERAL, so when the
    /// channel is down it is dropped rather than queued (a stale cursor is
    /// worthless on reconnect).
    func sendCursor(anchor: ElementID, head: ElementID) {
        guard let transport = transport, transport.isConnected else { return }
        drainQueue()
        let message = InterCodeEditorMessage.cursorMessage(anchorId: anchor, headId: head,
                                                           senderIdentity: localIdentity)
        publishNow(message, via: transport)
    }

    /// Publish a language-selection change. Language is stateful (an LWW
    /// register), so it is queued when disconnected and flushed on reconnect.
    func sendLanguage(_ language: String, lamport: UInt64) {
        noteLanguage(language, lamport: lamport)
        let message = InterCodeEditorMessage.languageMessage(language: language, lamport: lamport,
                                                            senderIdentity: localIdentity)
        publishOrQueue(message)
    }

    /// Request a full-document snapshot (late join / reconnect / resync). The
    /// RESPONDER selection + chunked assembly is Task 5; this is the request
    /// seam.
    func sendSnapshotRequest() {
        let message = InterCodeEditorMessage.snapshotRequestMessage(senderIdentity: localIdentity)
        publishOrQueue(message)
    }

    /// Flush the current coalescing window NOW (also called by the scheduled
    /// timer). Builds the minimal set of ceiling-bounded `ops` messages and
    /// publishes-or-queues them in order. Exposed `internal` so tests can drive
    /// the flush deterministically without waiting on the timer.
    func flushCoalescedOps() {
        coalesceTimer?.invalidate()
        coalesceTimer = nil
        guard !pendingOutboundOps.isEmpty else { return }
        let ops = pendingOutboundOps
        pendingOutboundOps.removeAll(keepingCapacity: true)

        let messages = CodeEditorOutboundBuilder.opsMessages(
            for: ops,
            senderIdentity: localIdentity,
            maxBytes: InterCodeEditorMessage.maxMessageBytes
        )
        for message in messages {
            publishOrQueue(message)
        }
    }

    private func scheduleCoalesceFlush() {
        guard coalesceTimer == nil else { return }
        coalesceTimer = Timer.scheduledTimer(withTimeInterval: Self.coalesceInterval, repeats: false) { [weak self] _ in
            // The timer fires on the main run loop (scheduled from the main
            // actor), so re-entering synchronously preserves op ordering.
            MainActor.assumeIsolated {
                self?.flushCoalescedOps()
            }
        }
    }

    /// Publish if connected (draining any backlog first to preserve order),
    /// otherwise append to the ordered outage queue (R8.2).
    private func publishOrQueue(_ message: InterCodeEditorMessage) {
        if let transport = transport, transport.isConnected {
            drainQueue()
            publishNow(message, via: transport)
        } else {
            queuedMessages.append(message)
        }
    }

    private func publishNow(_ message: InterCodeEditorMessage, via transport: InterCodeEditorTransport) {
        guard let data = message.toJSONData() else {
            interLogError(InterLog.room, "CodeEditorController: failed to encode outbound %{public}@",
                          message.type.rawValue)
            return
        }
        transport.publish(data, reliable: true)
    }

    /// Flush queued messages in order when the channel is up.
    private func drainQueue() {
        guard let transport = transport, transport.isConnected, !queuedMessages.isEmpty else { return }
        let toSend = queuedMessages
        queuedMessages.removeAll(keepingCapacity: true)
        for message in toSend {
            publishNow(message, via: transport)
        }
        interLogInfo(InterLog.room, "CodeEditorController: flushed %d queued messages on reconnect",
                     toSend.count)
    }

    // MARK: - Receive path (R5.5, R6.1)

    /// Entry point invoked by `InterRoomController`'s data dispatcher on the
    /// main queue. `nonisolated` so the existing `DispatchQueue.main.async`
    /// dispatch can call it without an actor hop; it re-enters synchronously
    /// (NOT via an async `Task`) so the reliable channel's delivery order is
    /// preserved.
    nonisolated func handleReceivedData(_ data: Data, senderIdentity: String?) {
        MainActor.assumeIsolated {
            self.receive(data, senderIdentity: senderIdentity)
        }
    }

    /// Decode, reconcile the attested sender, rate-limit, and route by type.
    /// Exposed `internal` so tests can drive it directly.
    func receive(_ data: Data, senderIdentity: String?) {
        guard let message = InterCodeEditorMessage.fromJSONData(data) else {
            interLogError(InterLog.room, "CodeEditorController: failed to decode message (%d bytes)",
                          data.count)
            return
        }

        // ATTESTED-SENDER RECONCILIATION (R5.5): trust the LiveKit-attested
        // identity over the self-declared `senderIdentity` field. On mismatch,
        // log and use the attested value. A nil identity is genuine server-sent
        // data, trusted as-is (consistent with the chat/poll controllers).
        let attested: String
        if let identity = senderIdentity, !identity.isEmpty {
            if identity != message.senderIdentity {
                interLogError(InterLog.room,
                    "CodeEditorController: sender mismatch (claimed=%{private}@ attested=%{private}@) — using attested",
                    message.senderIdentity, identity)
            }
            attested = identity
        } else {
            attested = message.senderIdentity
        }

        // Ignore our own echo (LiveKit normally never echoes a sender's own
        // broadcast, but guard defensively).
        guard attested != localIdentity else { return }

        // RATE LIMIT (R6.1), keyed on the attested identity. Excess inbound
        // messages for the window are dropped WITHOUT throwing or freezing.
        guard inboundRateLimiter.allow(sender: attested, byteCount: data.count) else {
            interLogError(InterLog.room,
                "CodeEditorController: rate-limited inbound from %{private}@ (>%d msg/s or >%d bytes/s)",
                attested, Self.maxInboundMessagesPerSecond, Self.maxInboundBytesPerSecond)
            return
        }

        switch message.type {
        case .ops:
            handleOps(message, attested: attested)
        case .cursor:
            handleCursor(message, attested: attested)
        case .language:
            handleLanguage(message, attested: attested)
        case .snapshotRequest:
            handleSnapshotRequest(message, attested: attested)
        case .snapshot:
            handleSnapshot(message, attested: attested)
        }
    }

    private func handleOps(_ message: InterCodeEditorMessage, attested: String) {
        guard let ops = message.toOps() else {
            interLogError(InterLog.room, "CodeEditorController: ops message decoded but failed to convert")
            return
        }

        // AUTHORSHIP (R5.5): a peer cannot author NEW elements "as" the other
        // participant. Every INSERT must carry `id.site == attested`. (Deletes
        // legitimately target any site — you may delete characters authored by
        // anyone — so the rule applies only to inserts.) Reject the whole batch
        // on any violation: applying it partially could orphan causal chains.
        for op in ops where op.kind == .insert && op.id.site != attested {
            interLogError(InterLog.room,
                "CodeEditorController: rejecting ops batch — insert claims site %{private}@ != attested %{private}@",
                op.id.site, attested)
            return
        }

        // RECOVERY BUFFERING (R4.1): while awaiting an authoritative snapshot,
        // hold accepted ops aside rather than applying them, then replay them
        // (idempotently) after the snapshot defines the baseline. Don't drop.
        if isRecovering {
            bufferedRemoteOps.append((ops, attested))
            return
        }

        applyRemoteOps(ops, from: attested)
    }

    /// Integrate a validated remote ops batch, notify the delegate, and arm the
    /// self-heal watchdog if the batch left an unresolved `originLeft` (R8.4).
    private func applyRemoteOps(_ ops: [Op], from attested: String) {
        for op in ops {
            document.integrate(op)
        }
        delegate?.codeEditorController(self, didIntegrateRemoteOps: ops, from: attested)
        scheduleSelfHealIfNeeded()
    }

    private func handleCursor(_ message: InterCodeEditorMessage, attested: String) {
        guard let cursor = message.toCursor() else { return }
        delegate?.codeEditorController(self, didReceiveRemoteCursorAnchor: cursor.anchor,
                                       head: cursor.head, from: attested)
    }

    private func handleLanguage(_ message: InterCodeEditorMessage, attested: String) {
        guard let language = message.toLanguage() else { return }
        noteLanguage(language.language, lamport: language.lamport)
        delegate?.codeEditorController(self, didReceiveLanguage: language.language,
                                       lamport: language.lamport, from: attested)
    }

    /// Track the current language register (LWW by `lamport`) so a snapshot we
    /// serve carries the up-to-date language/Lamport value.
    private func noteLanguage(_ language: String, lamport: UInt64) {
        if lamport >= currentLanguageLamport {
            currentLanguage = language
            currentLanguageLamport = lamport
        }
    }

    // MARK: - State recovery: late join, reconnect, resync (Task 5)

    /// Public entry for the view-model bridge (Task 6) / integration layer
    /// (Task 10): request an authoritative snapshot ONLY when the local replica
    /// is empty (a fresh mount or a reconnect that lost state). A populated
    /// document needs no recovery — concurrent ops merge automatically (R4.2).
    func requestSnapshotIfNeeded() {
        guard document.isEmpty else { return }
        beginRecovery()
    }

    /// Begin recovery: publish a `snapshotRequest` and BUFFER inbound ops until
    /// the snapshot lands (R4.1, R4.2). Idempotent-safe to call while already
    /// recovering (it simply re-requests). The integration layer calls this on
    /// mount and on reconnect.
    func beginRecovery() {
        isRecovering = true
        interLogInfo(InterLog.room, "CodeEditorController: begin recovery — requesting snapshot")
        sendSnapshotRequest()
    }

    /// Finish recovery once a snapshot has been applied: replay the ops buffered
    /// during the request, in order, idempotently (overlap with the snapshot is
    /// safe — duplicates are no-ops), then clear the recovery flag.
    private func finishRecovery() {
        guard isRecovering else { return }
        isRecovering = false
        let buffered = bufferedRemoteOps
        bufferedRemoteOps.removeAll(keepingCapacity: false)
        for entry in buffered {
            applyRemoteOps(entry.ops, from: entry.from)
        }
        interLogInfo(InterLog.room, "CodeEditorController: recovery complete — replayed %d buffered op batches",
                     buffered.count)
    }

    /// Respond to a snapshot request (R4.1). The interview HOST answers
    /// immediately; any other peer schedules a randomised fallback and answers
    /// only if no snapshot is observed first (cancelled in `handleSnapshot`).
    private func handleSnapshotRequest(_ message: InterCodeEditorMessage, attested: String) {
        // Nothing useful to serve from an empty replica — let a peer with state
        // answer (or our own recovery request will be answered by them).
        guard !document.isEmpty else {
            interLogInfo(InterLog.room,
                "CodeEditorController: snapshotRequest from %{private}@ ignored — local replica empty", attested)
            return
        }

        if isLocalParticipantHost() {
            interLogInfo(InterLog.room, "CodeEditorController: host serving snapshot to %{private}@", attested)
            serveSnapshot()
        } else {
            interLogInfo(InterLog.room,
                "CodeEditorController: non-host scheduling snapshot fallback for %{private}@", attested)
            scheduleSnapshotFallback { [weak self] in
                self?.serveSnapshot()
            }
        }
    }

    /// Apply an incoming snapshot. A single (untagged) snapshot is applied
    /// directly; a chunked snapshot is assembled in a STAGING buffer and applied
    /// only once every index has arrived — an atomic swap that never leaves a
    /// partially-applied document (R4.3). Any snapshot answers an outstanding
    /// request, so it cancels a pending responder fallback.
    private func handleSnapshot(_ message: InterCodeEditorMessage, attested: String) {
        guard let decoded = message.toSnapshot() else {
            interLogError(InterLog.room, "CodeEditorController: snapshot decoded but failed to convert")
            return
        }
        // A snapshot is now in flight / arrived → we no longer need to serve.
        cancelSnapshotFallback()

        let chunk = message.snapshotChunk
        guard let chunk = chunk, chunk.count > 1 else {
            // Single self-contained snapshot — apply atomically right away.
            applyAuthoritativeSnapshot(elements: decoded.snapshot.elements,
                                       language: decoded.language, lamport: decoded.lamport)
            return
        }

        // Chunked: stage this slice; apply only when complete.
        var assembly = snapshotAssemblies[attested] ?? SnapshotAssembly(expectedCount: chunk.count)
        guard assembly.expectedCount == chunk.count else {
            // A peer changed the chunk count mid-stream — restart assembly to
            // avoid mixing two snapshots.
            interLogError(InterLog.room, "CodeEditorController: snapshot chunk count changed — restarting assembly")
            var fresh = SnapshotAssembly(expectedCount: chunk.count)
            fresh.slices[chunk.index] = decoded.snapshot.elements
            fresh.language = decoded.language
            fresh.lamport = decoded.lamport
            snapshotAssemblies[attested] = fresh
            return
        }
        assembly.slices[chunk.index] = decoded.snapshot.elements
        // Carry the language register from the latest chunk (all chunks share it).
        assembly.language = decoded.language
        assembly.lamport = decoded.lamport
        snapshotAssemblies[attested] = assembly

        guard assembly.isComplete else { return }
        snapshotAssemblies[attested] = nil
        applyAuthoritativeSnapshot(elements: assembly.assembledElements,
                                   language: assembly.language, lamport: assembly.lamport)
    }

    /// Reconstruct the model `Snapshot` from assembled elements and merge it
    /// idempotently (newer local elements survive), then surface the language
    /// register and finish recovery. Applying the same snapshot twice is a
    /// no-op, so duplicate/overlapping snapshots are safe (R4.3, Property 2).
    private func applyAuthoritativeSnapshot(elements: [Element], language: String, lamport: UInt64) {
        var seqVector: [String: UInt64] = [:]
        for element in elements {
            if (seqVector[element.id.site] ?? 0) < element.id.seq {
                seqVector[element.id.site] = element.id.seq
            }
        }
        document.applySnapshot(Snapshot(elements: elements, seqVector: seqVector))

        // Surface the snapshot's language register (LWW) to the view model.
        noteLanguage(language, lamport: lamport)
        delegate?.codeEditorController(self, didReceiveLanguage: language, lamport: lamport,
                                       from: localIdentity)

        finishRecovery()

        // A snapshot may have resolved (or failed to resolve) pending origins.
        selfHealAttempted = false
        scheduleSelfHealIfNeeded()
        interLogInfo(InterLog.room, "CodeEditorController: applied snapshot (%d elements)", elements.count)
    }

    /// Serve the local document state as a snapshot, chunked under the byte
    /// ceiling (R4.3). Published reliably/ordered so chunks arrive in sequence.
    func serveSnapshot() {
        let messages = CodeEditorSnapshotBuilder.snapshotMessages(
            for: document.snapshot(),
            language: currentLanguage,
            lamport: currentLanguageLamport,
            senderIdentity: localIdentity,
            maxBytes: InterCodeEditorMessage.maxMessageBytes)
        for message in messages {
            publishOrQueue(message)
        }
        interLogInfo(InterLog.room, "CodeEditorController: served snapshot in %d message(s)", messages.count)
    }

    // MARK: Responder fallback (deterministic-testable)

    private func scheduleSnapshotFallback(_ action: @escaping () -> Void) {
        // Only one fallback in flight; a fresh request reuses the existing one.
        guard pendingSnapshotFallback == nil else { return }
        pendingSnapshotFallback = action
        let delay = snapshotFallbackDelayProvider()
        snapshotFallbackTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fireSnapshotFallback()
            }
        }
    }

    private func fireSnapshotFallback() {
        snapshotFallbackTimer?.invalidate()
        snapshotFallbackTimer = nil
        let action = pendingSnapshotFallback
        pendingSnapshotFallback = nil
        action?()
    }

    /// Cancel a pending responder fallback (a snapshot was observed answering
    /// the request).
    private func cancelSnapshotFallback() {
        snapshotFallbackTimer?.invalidate()
        snapshotFallbackTimer = nil
        pendingSnapshotFallback = nil
    }

    /// TEST HOOK: fire the pending responder fallback now (deterministic — no
    /// sleeping on the randomised delay). Returns `true` if a fallback was
    /// pending and fired.
    @discardableResult
    func fireSnapshotFallbackNowForTesting() -> Bool {
        guard pendingSnapshotFallback != nil else { return false }
        fireSnapshotFallback()
        return true
    }

    /// TEST/INTROSPECTION: whether a responder fallback is currently scheduled.
    var hasPendingSnapshotFallback: Bool { pendingSnapshotFallback != nil }

    // MARK: Self-heal (R8.4)

    /// Arm the bounded-window watchdog when the document has an unresolved
    /// `originLeft`. A reliable+ordered channel heals same-sender gaps quickly;
    /// an origin still missing when the window elapses indicates a cross-sender
    /// divergence that a fresh snapshot reconciles.
    private func scheduleSelfHealIfNeeded() {
        guard document.hasUnresolvedInserts else {
            // Backlog cleared — stand the watchdog down and reset escalation.
            selfHealTimer?.invalidate()
            selfHealTimer = nil
            selfHealAttempted = false
            return
        }
        guard selfHealTimer == nil else { return }
        selfHealTimer = Timer.scheduledTimer(withTimeInterval: Self.selfHealWindow, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.performSelfHealCheck()
            }
        }
    }

    /// Window elapsed: if origins are still unresolved, first try a recovery
    /// snapshot request; if a subsequent window still finds them unresolved,
    /// surface a NON-BLOCKING resync notice (R8.4) and keep local editing alive.
    private func performSelfHealCheck() {
        selfHealTimer?.invalidate()
        selfHealTimer = nil

        guard document.hasUnresolvedInserts else {
            selfHealAttempted = false
            return
        }

        if !selfHealAttempted {
            selfHealAttempted = true
            interLogInfo(InterLog.room,
                "CodeEditorController: unresolved origin past window — requesting recovery snapshot")
            beginRecovery()
            // Re-arm so a still-divergent state escalates to the delegate notice.
            scheduleSelfHealIfNeeded()
        } else {
            interLogError(InterLog.room,
                "CodeEditorController: still divergent after recovery — surfacing resync notice")
            delegate?.codeEditorControllerDidRequestResync(self)
            selfHealAttempted = false
        }
    }

    /// TEST HOOK: run the self-heal window check now (deterministic — no waiting
    /// on the bounded window timer).
    func performSelfHealCheckNowForTesting() {
        performSelfHealCheck()
    }
}
