//
//  InterCodeEditorControllerTests.swift
//  interTests
//
//  Unit tests for the collaborative-code-editor TRANSPORT layer
//  (`InterCodeEditorController`, spec Task 4.6). They cover:
//
//    • Coalescing — a keystroke run batches into ONE `ops` message instead of
//      one message per character (R6.2).
//    • Chunking — a long paste is split so every encoded message stays under
//      `InterCodeEditorMessage.maxMessageBytes` (R6.2).
//    • Rate limiting — the per-sender sliding window (msgs/s AND bytes/s) drops
//      excess and resets on a fresh window (R6.1).
//    • Attested-sender authorship — inbound inserts claiming another
//      participant's `site` are rejected; attribution uses the attested
//      identity over the self-declared field (R5.5).
//    • Queue-and-flush — outbound messages are buffered (in order) while the
//      channel is down and flushed on reconnect (R8.2).
//    • Size-limit notice — a refused local insert surfaces via the delegate
//      (R6.3).
//
//  The LiveKit `Room` is hidden behind the `InterCodeEditorTransport` seam, so
//  these tests inject a capturing fake — no live Room. The coalescing/chunking
//  (`CodeEditorOutboundBuilder`) and rate-limit (`CodeEditorRateLimiter`) logic
//  are pure types tested directly. `InterCodeEditorController` /
//  `CodeEditorDocument` are `@MainActor`, so the suite is annotated accordingly.
//

import XCTest
@testable import inter

// MARK: - Test seams

/// Capturing fake transport: records published payloads and lets the test flip
/// the connection state to exercise the queue/flush path.
@MainActor
private final class FakeCodeEditorTransport: InterCodeEditorTransport {
    var isConnected: Bool
    private(set) var published: [Data] = []

    init(isConnected: Bool = true) { self.isConnected = isConnected }

    func publish(_ data: Data, reliable: Bool) {
        published.append(data)
    }

    /// Discard captured payloads (so a later phase of a test asserts only the
    /// messages produced after this point).
    func clearPublished() {
        published.removeAll()
    }

    /// The decoded type of each published message, in order.
    var publishedTypes: [InterCodeEditorMessageType] {
        published.compactMap { InterCodeEditorMessage.fromJSONData($0)?.type }
    }
}

/// Records delegate callbacks for assertion.
@MainActor
private final class SpyDelegate: InterCodeEditorControllerDelegate {
    var integratedOps: [Op] = []
    var integratedFrom: [String] = []
    var cursors: [(anchor: ElementID, head: ElementID, from: String)] = []
    var languages: [(language: String, lamport: UInt64, from: String)] = []
    var sizeLimitHits = 0
    var resyncNotices = 0

    func codeEditorController(_ controller: InterCodeEditorController,
                              didIntegrateRemoteOps ops: [Op], from senderIdentity: String) {
        integratedOps.append(contentsOf: ops)
        integratedFrom.append(senderIdentity)
    }

    func codeEditorController(_ controller: InterCodeEditorController,
                              didReceiveRemoteCursorAnchor anchor: ElementID, head: ElementID,
                              from senderIdentity: String) {
        cursors.append((anchor, head, senderIdentity))
    }

    func codeEditorController(_ controller: InterCodeEditorController,
                              didReceiveLanguage language: String, lamport: UInt64,
                              from senderIdentity: String) {
        languages.append((language, lamport, senderIdentity))
    }

    func codeEditorControllerDidHitSizeLimit(_ controller: InterCodeEditorController) {
        sizeLimitHits += 1
    }

    func codeEditorControllerDidRequestResync(_ controller: InterCodeEditorController) {
        resyncNotices += 1
    }
}

@MainActor
final class InterCodeEditorControllerTests: XCTestCase {

    // Helper: a controller wired to a fake transport, with a retained delegate.
    private func makeController(site: String = "A",
                               maxLiveChars: Int = 100_000,
                               connected: Bool = true)
        -> (controller: InterCodeEditorController,
            document: CodeEditorDocument,
            transport: FakeCodeEditorTransport,
            delegate: SpyDelegate) {
        let document = CodeEditorDocument(site: site, maxLiveChars: maxLiveChars)
        let controller = InterCodeEditorController(document: document, localIdentity: site)
        let transport = FakeCodeEditorTransport(isConnected: connected)
        let delegate = SpyDelegate()
        controller.transport = transport
        controller.delegate = delegate
        return (controller, document, transport, delegate)
    }

    // MARK: - Coalescing

    /// A keystroke run that fits the per-message op budget coalesces into ONE
    /// `ops` message rather than one message per character (R6.2).
    func testCoalescing_KeystrokeRunBecomesSingleMessage() {
        let (controller, _, transport, _) = makeController()

        let maxOps = CodeEditorOutboundBuilder.maxOpsPerMessage(
            senderIdentity: "A", maxBytes: InterCodeEditorMessage.maxMessageBytes)
        XCTAssertGreaterThan(maxOps, 1, "budget should allow batching multiple ops")

        // A run exactly at the budget must still be a single coalesced message.
        controller.applyLocalInsert(at: 0, String(repeating: "x", count: maxOps))
        controller.flushCoalescedOps()

        XCTAssertEqual(transport.published.count, 1,
                       "a \(maxOps)-keystroke run should coalesce into one message, not \(maxOps)")
        XCTAssertEqual(transport.publishedTypes, [.ops])
        let decoded = InterCodeEditorMessage.fromJSONData(transport.published[0])
        XCTAssertEqual(decoded?.toOps()?.count, maxOps, "all ops should be carried in the one batch")
    }

    /// Several separate `sendLocalOps` calls within one window coalesce together.
    func testCoalescing_MultipleCallsInWindowMergeIntoFewerMessages() {
        let (controller, document, transport, _) = makeController()

        // 90 individual single-character edits, sent as separate calls.
        for i in 0..<90 {
            let ops = document.localInsert(at: i, "y")
            controller.sendLocalOps(ops)
        }
        controller.flushCoalescedOps()

        XCTAssertGreaterThanOrEqual(transport.published.count, 1)
        XCTAssertLessThan(transport.published.count, 90,
                          "coalescing must produce far fewer messages than one-per-keystroke")
    }

    // MARK: - Chunking

    /// A long paste is chunked so every encoded message stays under the byte
    /// ceiling, while still being far fewer messages than one-per-character.
    func testChunking_LongPasteStaysUnderByteCeiling() {
        let (controller, _, transport, _) = makeController()

        let pasteLength = 5_000
        controller.applyLocalInsert(at: 0, String(repeating: "z", count: pasteLength))
        controller.flushCoalescedOps()

        XCTAssertGreaterThan(transport.published.count, 1, "a long paste should chunk into multiple messages")
        XCTAssertLessThan(transport.published.count, pasteLength, "but far fewer than one per character")

        // Every published message must be under the wire ceiling AND decode.
        var totalOps = 0
        for data in transport.published {
            XCTAssertLessThanOrEqual(data.count, InterCodeEditorMessage.maxMessageBytes,
                                     "a chunk exceeded maxMessageBytes")
            let decoded = InterCodeEditorMessage.fromJSONData(data)
            XCTAssertNotNil(decoded, "every chunk must decode cleanly")
            totalOps += decoded?.toOps()?.count ?? 0
        }
        XCTAssertEqual(totalOps, pasteLength, "no ops should be lost across the chunks")
    }

    // MARK: - Rate limiter (pure)

    func testRateLimiter_DropsBeyondMessageWindowAndResets() {
        let limiter = CodeEditorRateLimiter(maxMessagesPerSecond: 3, maxBytesPerSecond: 1_000_000)
        let t0 = 1_000.0

        XCTAssertTrue(limiter.allow(sender: "B", byteCount: 1, now: t0))
        XCTAssertTrue(limiter.allow(sender: "B", byteCount: 1, now: t0 + 0.1))
        XCTAssertTrue(limiter.allow(sender: "B", byteCount: 1, now: t0 + 0.2))
        XCTAssertFalse(limiter.allow(sender: "B", byteCount: 1, now: t0 + 0.3),
                       "4th message in the window must be dropped")
        XCTAssertFalse(limiter.allow(sender: "B", byteCount: 1, now: t0 + 0.9),
                       "remains dropped for the rest of the window")

        // A message in a FRESH window resets the counter.
        XCTAssertTrue(limiter.allow(sender: "B", byteCount: 1, now: t0 + 1.5),
                      "a new 1s window should reset and admit again")
    }

    func testRateLimiter_DropsBeyondByteWindow() {
        let limiter = CodeEditorRateLimiter(maxMessagesPerSecond: 1_000, maxBytesPerSecond: 100)
        let t0 = 2_000.0

        XCTAssertTrue(limiter.allow(sender: "B", byteCount: 60, now: t0))
        XCTAssertFalse(limiter.allow(sender: "B", byteCount: 60, now: t0 + 0.1),
                       "exceeding the byte budget must drop even when under the message cap")
        XCTAssertTrue(limiter.allow(sender: "B", byteCount: 60, now: t0 + 1.2),
                      "byte budget resets on a fresh window")
    }

    func testRateLimiter_IsPerSender() {
        let limiter = CodeEditorRateLimiter(maxMessagesPerSecond: 1, maxBytesPerSecond: 1_000_000)
        let t0 = 3_000.0
        XCTAssertTrue(limiter.allow(sender: "B", byteCount: 1, now: t0))
        XCTAssertFalse(limiter.allow(sender: "B", byteCount: 1, now: t0 + 0.1), "B is over budget")
        XCTAssertTrue(limiter.allow(sender: "C", byteCount: 1, now: t0 + 0.1),
                      "a different sender must have an independent budget")
    }

    /// End-to-end: a flood of inbound ops from one sender is rate-limited so
    /// later messages stop being applied to the document (R6.1), without
    /// throwing.
    func testReceive_FloodIsRateLimited() {
        let (controller, document, _, delegate) = makeController()

        // Author a long chain from peer B, each as its OWN message so the
        // message-per-second cap (60) trips well before the chain ends.
        var left: ElementID? = nil
        var applied = 0
        for seq in 1...200 {
            let id = ElementID(site: "B", seq: UInt64(seq))
            let op = Op.insert(id: id, value: "a", originLeft: left)
            left = id
            guard let data = InterCodeEditorMessage.opsMessage([op], senderIdentity: "B").toJSONData() else {
                return XCTFail("encode failed")
            }
            controller.receive(data, senderIdentity: "B")
            applied += 1
        }
        XCTAssertEqual(applied, 200)
        XCTAssertLessThanOrEqual(document.text.count,
                                 InterCodeEditorController.maxInboundMessagesPerSecond,
                                 "messages beyond the per-second cap must be dropped")
        XCTAssertGreaterThan(document.text.count, 0, "early messages within the cap are applied")
        XCTAssertFalse(delegate.integratedFrom.isEmpty)
    }

    // MARK: - Attested-sender authorship (R5.5)

    /// A peer cannot author elements "as" the other participant: an inbound
    /// insert whose `site` != attested sender is rejected and never mutates the
    /// document.
    func testReceive_RejectsInsertClaimingForeignSite() {
        let (controller, document, _, delegate) = makeController(site: "A")

        // Peer B (attested) tries to author an element with site "A".
        let impersonating = [Op.insert(id: ElementID(site: "A", seq: 99), value: "x", originLeft: nil)]
        guard let data = InterCodeEditorMessage.opsMessage(impersonating, senderIdentity: "A").toJSONData() else {
            return XCTFail("encode failed")
        }
        controller.receive(data, senderIdentity: "B")

        XCTAssertEqual(document.text, "", "an op authored as another site must be rejected")
        XCTAssertTrue(delegate.integratedOps.isEmpty, "rejected ops must not reach the delegate")
    }

    /// Attribution uses the LiveKit-attested identity over the self-declared
    /// field: an honestly-authored batch (site == attested) is applied and
    /// attributed to the attested sender even when the message mislabels itself.
    func testReceive_UsesAttestedIdentityOverSelfDeclared() {
        let (controller, document, _, delegate) = makeController(site: "A")

        // Peer B authors with site "B" but stamps senderIdentity = "A".
        let ops = [Op.insert(id: ElementID(site: "B", seq: 1), value: "h", originLeft: nil)]
        guard let data = InterCodeEditorMessage.opsMessage(ops, senderIdentity: "A").toJSONData() else {
            return XCTFail("encode failed")
        }
        controller.receive(data, senderIdentity: "B")   // attested = B

        XCTAssertEqual(document.text, "h", "an honestly-authored op must be applied")
        XCTAssertEqual(delegate.integratedFrom, ["B"], "must attribute to the attested sender, not the claim")
    }

    /// The `nonisolated` dispatcher entry point applies an honest remote op.
    func testHandleReceivedData_AppliesRemoteOps() {
        let (controller, document, _, _) = makeController(site: "A")
        let ops = [Op.insert(id: ElementID(site: "B", seq: 1), value: "q", originLeft: nil)]
        guard let data = InterCodeEditorMessage.opsMessage(ops, senderIdentity: "B").toJSONData() else {
            return XCTFail("encode failed")
        }
        controller.handleReceivedData(data, senderIdentity: "B")
        XCTAssertEqual(document.text, "q")
    }

    /// Cursor and language messages reach the delegate, attributed to attested.
    func testReceive_RoutesCursorAndLanguage() {
        let (controller, _, _, delegate) = makeController(site: "A")

        let cursor = InterCodeEditorMessage.cursorMessage(
            anchorId: ElementID(site: "B", seq: 2),
            headId: ElementID(site: "B", seq: 5),
            senderIdentity: "B")
        controller.receive(cursor.toJSONData()!, senderIdentity: "B")
        XCTAssertEqual(delegate.cursors.count, 1)
        XCTAssertEqual(delegate.cursors.first?.from, "B")

        let language = InterCodeEditorMessage.languageMessage(language: "python", lamport: 7, senderIdentity: "B")
        controller.receive(language.toJSONData()!, senderIdentity: "B")
        XCTAssertEqual(delegate.languages.count, 1)
        XCTAssertEqual(delegate.languages.first?.language, "python")
        XCTAssertEqual(delegate.languages.first?.lamport, 7)
    }

    // MARK: - Queue when disconnected, flush on reconnect (R8.2)

    func testQueue_WhenDisconnectedThenFlushOnReconnect() {
        let (controller, _, transport, _) = makeController(connected: false)

        controller.applyLocalInsert(at: 0, "hello")  // 5 ops
        controller.flushCoalescedOps()
        XCTAssertEqual(transport.published.count, 0, "nothing is published while disconnected")

        transport.isConnected = true
        controller.connectionDidRestore()

        XCTAssertEqual(transport.published.count, 1, "queued ops flush on reconnect")
        let decoded = InterCodeEditorMessage.fromJSONData(transport.published[0])
        XCTAssertEqual(decoded?.type, .ops)
        XCTAssertEqual(decoded?.toOps()?.count, 5, "the coalesced 5-char run flushes intact")
    }

    /// Queued messages flush in the order they were produced (language before
    /// the later ops batch).
    func testQueue_PreservesOrderOnFlush() {
        let (controller, _, transport, _) = makeController(connected: false)

        controller.sendLanguage("go", lamport: 1)         // queued: [language]
        controller.applyLocalInsert(at: 0, "ab")          // 2 ops
        controller.flushCoalescedOps()                    // queued: [language, ops]
        XCTAssertEqual(transport.published.count, 0)

        transport.isConnected = true
        controller.connectionDidRestore()

        XCTAssertEqual(transport.publishedTypes, [.language, .ops],
                       "outage queue must flush in production order")
    }

    /// A reconnect followed by a fresh local edit still drains the backlog
    /// first, preserving order (the publish path drains before sending new).
    func testQueue_DrainsBacklogBeforeNewSendAfterReconnect() {
        let (controller, _, transport, _) = makeController(connected: false)

        controller.applyLocalInsert(at: 0, "ab")
        controller.flushCoalescedOps()                    // queued ops #1
        XCTAssertEqual(transport.published.count, 0)

        transport.isConnected = true
        // Without an explicit connectionDidRestore, the next publish drains too.
        controller.applyLocalInsert(at: 2, "cd")
        controller.flushCoalescedOps()                    // ops #2 → drains #1 then sends #2

        XCTAssertEqual(transport.published.count, 2)
        XCTAssertEqual(transport.publishedTypes, [.ops, .ops])
    }

    // MARK: - Size-limit notice (R6.3)

    func testApplyLocalInsert_SurfacesSizeLimitNotice() {
        let (controller, document, _, delegate) = makeController(maxLiveChars: 3)

        controller.applyLocalInsert(at: 0, "abc")     // fills to the cap
        XCTAssertEqual(document.text, "abc")
        XCTAssertEqual(delegate.sizeLimitHits, 0)

        controller.applyLocalInsert(at: 3, "d")        // refused
        XCTAssertEqual(document.text, "abc", "insert past the cap is refused")
        XCTAssertEqual(delegate.sizeLimitHits, 1, "a refused insert must surface the size-limit notice")
    }

    // MARK: - State recovery: snapshots, late join, reconnect (Task 5.5)

    /// snapshotRequest → serve → apply round-trips a NON-EMPTY document (incl. a
    /// tombstone) into a fresh replica, which converges to identical text.
    func testSnapshot_RoundTripsIntoFreshReplica() {
        // Source replica "A" with some content and a deletion (tombstone).
        let (source, sourceDoc, sourceTransport, _) = makeController(site: "A")
        source.applyLocalInsert(at: 0, "hello world")
        source.applyLocalDelete(range: 5..<6)            // drop the space → "helloworld"
        source.flushCoalescedOps()
        XCTAssertEqual(sourceDoc.text, "helloworld")

        // Source serves a snapshot (host path); capture the published messages.
        sourceTransport.clearPublished()
        source.serveSnapshot()
        XCTAssertGreaterThanOrEqual(sourceTransport.published.count, 1)
        XCTAssertTrue(sourceTransport.publishedTypes.allSatisfy { $0 == .snapshot })

        // Fresh replica "B" receives the snapshot and converges.
        let (replica, replicaDoc, _, _) = makeController(site: "B")
        for data in sourceTransport.published {
            replica.receive(data, senderIdentity: "A")
        }
        XCTAssertEqual(replicaDoc.text, sourceDoc.text,
                       "a fresh replica must converge to the source document via the snapshot")
    }

    /// Ops arriving DURING recovery are buffered (not dropped), then replayed
    /// after the snapshot is applied; idempotent overlap with the snapshot is
    /// safe, and the replica converges with no duplication.
    func testRecovery_OpsDuringRecoveryAreBufferedThenAppliedAndConverge() {
        // Source "A" = "hello"; take a snapshot of that baseline.
        let (source, sourceDoc, sourceTransport, _) = makeController(site: "A")
        source.applyLocalInsert(at: 0, "hello")
        source.flushCoalescedOps()
        XCTAssertEqual(sourceDoc.text, "hello")
        sourceTransport.clearPublished()
        source.serveSnapshot()
        let snapshotMessages = sourceTransport.published

        // Fresh replica "B" begins recovery (buffers inbound ops meanwhile).
        let (replica, replicaDoc, replicaTransport, delegate) = makeController(site: "B")
        replica.beginRecovery()
        XCTAssertTrue(replica.isRecovering)
        XCTAssertTrue(replicaTransport.publishedTypes.contains(.snapshotRequest),
                      "beginRecovery must publish a snapshotRequest")

        // While recovering, A sends ops: a DUPLICATE of an element already in
        // the snapshot (id A,3) plus a NEW append (id A,6 = '!').
        let dup = Op.insert(id: ElementID(site: "A", seq: 3), value: "l",
                            originLeft: ElementID(site: "A", seq: 2))
        let appendBang = Op.insert(id: ElementID(site: "A", seq: 6), value: "!",
                                   originLeft: ElementID(site: "A", seq: 5))
        let opsData = InterCodeEditorMessage.opsMessage([dup, appendBang], senderIdentity: "A").toJSONData()!
        replica.receive(opsData, senderIdentity: "A")
        XCTAssertEqual(replicaDoc.text, "", "ops during recovery must be BUFFERED, not applied yet")

        // Snapshot lands → applied atomically, then buffered ops replay.
        for data in snapshotMessages {
            replica.receive(data, senderIdentity: "A")
        }
        XCTAssertFalse(replica.isRecovering, "recovery completes once the snapshot is applied")
        XCTAssertEqual(replicaDoc.text, "hello!",
                       "buffered ops replay after the snapshot; the duplicate is idempotent")
        XCTAssertEqual(replicaDoc.text.count, 6, "idempotent overlap must not duplicate characters")
        XCTAssertFalse(delegate.integratedFrom.isEmpty, "replayed ops reach the delegate")
    }

    /// A NON-host peer schedules a randomised responder fallback and serves the
    /// snapshot itself if no snapshot is observed; the host serves immediately.
    func testResponderFallback_NonHostServesAfterDelay_HostServesImmediately() {
        // Non-host peer "B" with content to serve.
        let (peer, _, peerTransport, _) = makeController(site: "B")
        peer.isLocalParticipantHost = { false }
        peer.applyLocalInsert(at: 0, "code")
        peer.flushCoalescedOps()
        peerTransport.clearPublished()

        // A snapshotRequest from "A" schedules a fallback — nothing served yet.
        let reqData = InterCodeEditorMessage.snapshotRequestMessage(senderIdentity: "A").toJSONData()!
        peer.receive(reqData, senderIdentity: "A")
        XCTAssertTrue(peer.hasPendingSnapshotFallback, "a non-host must defer via a scheduled fallback")
        XCTAssertFalse(peerTransport.publishedTypes.contains(.snapshot),
                       "a non-host must not serve immediately")

        // Fire the fallback deterministically → now it serves.
        XCTAssertTrue(peer.fireSnapshotFallbackNowForTesting())
        XCTAssertTrue(peerTransport.publishedTypes.contains(.snapshot),
                      "the fallback must serve the snapshot when it fires")

        // The HOST serves immediately, with no fallback scheduled.
        let (host, _, hostTransport, _) = makeController(site: "C")
        host.isLocalParticipantHost = { true }
        host.applyLocalInsert(at: 0, "code")
        host.flushCoalescedOps()
        hostTransport.clearPublished()
        host.receive(reqData, senderIdentity: "A")
        XCTAssertFalse(host.hasPendingSnapshotFallback, "the host does not defer")
        XCTAssertTrue(hostTransport.publishedTypes.contains(.snapshot), "the host serves immediately")
    }

    /// The responder fallback is CANCELLED when a snapshot is observed answering
    /// the request (avoids a duplicate serve).
    func testResponderFallback_CancelledWhenSnapshotObserved() {
        let (peer, _, _, _) = makeController(site: "B")
        peer.isLocalParticipantHost = { false }
        peer.applyLocalInsert(at: 0, "code")
        peer.flushCoalescedOps()

        let reqData = InterCodeEditorMessage.snapshotRequestMessage(senderIdentity: "A").toJSONData()!
        peer.receive(reqData, senderIdentity: "A")
        XCTAssertTrue(peer.hasPendingSnapshotFallback)

        // Another peer "D" answers first — observing the snapshot cancels ours.
        let other = CodeEditorDocument(site: "D")
        _ = other.localInsert(at: 0, "code")
        let snapData = InterCodeEditorMessage.snapshotMessage(other.snapshot(), language: "Plain text",
                                                              lamport: 0, senderIdentity: "D").toJSONData()!
        peer.receive(snapData, senderIdentity: "D")

        XCTAssertFalse(peer.hasPendingSnapshotFallback, "observing a snapshot cancels the fallback")
        XCTAssertFalse(peer.fireSnapshotFallbackNowForTesting(), "no fallback remains to fire")
    }

    /// A chunked snapshot assembles ATOMICALLY: the document stays unchanged
    /// until the final chunk arrives, then swaps to the full state in one step.
    func testChunkedSnapshot_AssemblesAtomically() {
        // Source "A" with 10 chars; chunk under a TINY ceiling to force splits.
        let sourceDoc = CodeEditorDocument(site: "A")
        _ = sourceDoc.localInsert(at: 0, "abcdefghij")
        let messages = CodeEditorSnapshotBuilder.snapshotMessages(
            for: sourceDoc.snapshot(), language: "Plain text", lamport: 0,
            senderIdentity: "A", maxBytes: 400)
        XCTAssertGreaterThan(messages.count, 1, "a tiny ceiling must force multiple chunks")
        XCTAssertTrue(messages.allSatisfy { $0.snapshotChunk != nil }, "chunks carry chunk metadata")

        let (replica, replicaDoc, _, _) = makeController(site: "B")

        // Feed every chunk EXCEPT the last → document must stay empty (atomic).
        for message in messages.dropLast() {
            replica.receive(message.toJSONData()!, senderIdentity: "A")
            XCTAssertEqual(replicaDoc.text, "",
                           "a partially-received snapshot must NOT be applied")
        }

        // Final chunk completes the staging buffer → atomic swap to full state.
        replica.receive(messages.last!.toJSONData()!, senderIdentity: "A")
        XCTAssertEqual(replicaDoc.text, "abcdefghij",
                       "the assembled snapshot swaps in atomically once complete")
    }

    /// Self-heal: an inbound insert whose `originLeft` never resolves first
    /// triggers a recovery snapshotRequest, and — if still divergent — surfaces
    /// a non-blocking resync notice via the delegate (R8.4).
    func testSelfHeal_UnresolvedOriginRequestsSnapshotThenNotifies() {
        let (controller, document, transport, delegate) = makeController(site: "B")

        // Insert from "A" referencing a missing origin (A,1 never delivered).
        let orphan = Op.insert(id: ElementID(site: "A", seq: 2), value: "x",
                               originLeft: ElementID(site: "A", seq: 1))
        let data = InterCodeEditorMessage.opsMessage([orphan], senderIdentity: "A").toJSONData()!
        controller.receive(data, senderIdentity: "A")
        XCTAssertTrue(document.hasUnresolvedInserts, "the orphan insert is buffered awaiting its origin")
        XCTAssertEqual(document.text, "", "an insert with a missing origin is not yet visible")

        // First window: request a recovery snapshot.
        transport.clearPublished()
        controller.performSelfHealCheckNowForTesting()
        XCTAssertTrue(transport.publishedTypes.contains(.snapshotRequest),
                      "an unresolved origin past the window triggers a recovery request")
        XCTAssertEqual(delegate.resyncNotices, 0, "no resync notice on the first attempt")

        // Second window: still divergent → non-blocking resync notice.
        controller.performSelfHealCheckNowForTesting()
        XCTAssertEqual(delegate.resyncNotices, 1,
                       "a still-unresolved origin surfaces a resync notice")
    }
}
