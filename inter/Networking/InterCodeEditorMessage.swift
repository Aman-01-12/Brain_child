// ============================================================================
// InterCodeEditorMessage.swift
// inter
//
// Collaborative Code Editor (Interview) — Task 3: the WIRE layer.
//
// These are the `Codable` value types exchanged over the LiveKit DataChannel
// topic "codeEditor" (see design.md "Data Models" / "Edit operations & wire
// protocol"). They are deliberately DECOUPLED from the RGA model in
// `CodeEditorDocument.swift`: the model owns `ElementID` / `Element` / `Op` /
// `Snapshot`; this file owns their on-the-wire mirrors and the converters
// between the two. Keeping the layers separate means a change to the wire
// shape (e.g. a new field, a schema migration) never silently alters the
// convergence core, and the core stays unit/property-testable with no
// networking dependency.
//
// Convention: this mirrors `InterControlSignal` / `InterPollMessage` — a single
// `Codable` envelope carrying a `type` discriminator plus the payload for that
// type, with `toJSONData()` / `fromJSONData(_:)` for transport. Unlike those
// (which decode leniently with `try?`), the editor decoder is HARDENED
// (design.md R5.4): a conservative byte ceiling is enforced and every field is
// bounds-checked, so malformed / oversized / out-of-range peer input returns
// `nil` rather than throwing, crashing, or producing a half-formed value.
//
// ISOLATION INVARIANT [G8]:
//   Pure data types + pure converters only. No UI, no room references, no side
//   effects. Safe to use from any thread.
// ============================================================================

import Foundation

// MARK: - Wire value types
//
// Each mirrors a model type but is independently `Codable`. A `Character` is
// always carried as a `String` on the wire (JSON has no character type); the
// decode path validates that the string forms EXACTLY ONE Swift `Character`
// (one extended grapheme cluster) — see `codeEditorSingleCharacter(_:)`.

/// Wire mirror of `ElementID { site, seq }`.
struct CodeEditorWireID: Codable, Equatable {
    let site: String
    let seq: UInt64

    init(site: String, seq: UInt64) {
        self.site = site
        self.seq = seq
    }

    init(_ id: ElementID) {
        self.site = id.site
        self.seq = id.seq
    }

    /// The model id. A valid wire id has a NON-EMPTY `site` (the attested
    /// participant identity); an empty site is malformed and yields `nil`.
    func toModel() -> ElementID? {
        guard !site.isEmpty else { return nil }
        return ElementID(site: site, seq: seq)
    }
}

/// Wire mirror of a single `Op`. `kind` is `"ins"` or `"del"`; `value` is the
/// inserted character (single-`Character` string, absent for deletes);
/// `originLeft` is the left origin (absent for deletes and head inserts).
struct CodeEditorWireOp: Codable, Equatable {
    let kind: String
    let id: CodeEditorWireID
    let value: String?
    let originLeft: CodeEditorWireID?

    init(kind: String, id: CodeEditorWireID, value: String?, originLeft: CodeEditorWireID?) {
        self.kind = kind
        self.id = id
        self.value = value
        self.originLeft = originLeft
    }

    init(_ op: Op) {
        switch op.kind {
        case .insert:
            self.kind = "ins"
            self.id = CodeEditorWireID(op.id)
            self.value = op.value.map(String.init)
            self.originLeft = op.originLeft.map(CodeEditorWireID.init)
        case .delete:
            self.kind = "del"
            self.id = CodeEditorWireID(op.id)
            self.value = nil
            self.originLeft = nil
        }
    }

    /// `true` iff this op is well-formed: a known `kind`, a valid id, and (for
    /// inserts) a single-`Character` value and a valid origin if present.
    var isValid: Bool {
        guard id.toModel() != nil else { return false }
        switch kind {
        case "ins":
            guard codeEditorSingleCharacter(value) != nil else { return false }
            if let origin = originLeft, origin.toModel() == nil { return false }
            return true
        case "del":
            // A delete carries no value/origin; any extra origin must still be
            // well-formed if present (defensive — the encoder never sets it).
            if let origin = originLeft, origin.toModel() == nil { return false }
            return true
        default:
            return false
        }
    }

    /// Converts to a model `Op`, or `nil` if the op is malformed.
    func toModel() -> Op? {
        guard let modelID = id.toModel() else { return nil }
        switch kind {
        case "ins":
            guard let ch = codeEditorSingleCharacter(value) else { return nil }
            let left = originLeft.flatMap { $0.toModel() }
            if originLeft != nil && left == nil { return nil }
            return Op.insert(id: modelID, value: ch, originLeft: left)
        case "del":
            return Op.delete(id: modelID)
        default:
            return nil
        }
    }
}

/// Wire mirror of a remote cursor/selection: the anchor and head element ids.
struct CodeEditorWireCursor: Codable, Equatable {
    let anchorId: CodeEditorWireID
    let headId: CodeEditorWireID

    var isValid: Bool { anchorId.toModel() != nil && headId.toModel() != nil }
}

/// Wire mirror of the language LWW register: the selection plus its Lamport
/// clock value.
struct CodeEditorWireLanguage: Codable, Equatable {
    let language: String
    let lamport: UInt64

    /// A valid language register has a NON-EMPTY language identifier
    /// (e.g. "python", "Plain text").
    var isValid: Bool { !language.isEmpty }
}

/// Wire mirror of a single RGA `Element` for a snapshot (includes tombstones so
/// element ids stay consistent across replicas).
struct CodeEditorWireElement: Codable, Equatable {
    let id: CodeEditorWireID
    let value: String
    let originLeft: CodeEditorWireID?
    let deleted: Bool

    init(id: CodeEditorWireID, value: String, originLeft: CodeEditorWireID?, deleted: Bool) {
        self.id = id
        self.value = value
        self.originLeft = originLeft
        self.deleted = deleted
    }

    init(_ element: Element) {
        self.id = CodeEditorWireID(element.id)
        self.value = String(element.value)
        self.originLeft = element.originLeft.map(CodeEditorWireID.init)
        self.deleted = element.deleted
    }

    var isValid: Bool {
        guard id.toModel() != nil else { return false }
        guard codeEditorSingleCharacter(value) != nil else { return false }
        if let origin = originLeft, origin.toModel() == nil { return false }
        return true
    }

    func toModel() -> Element? {
        guard let modelID = id.toModel(),
              let ch = codeEditorSingleCharacter(value) else { return nil }
        let left = originLeft.flatMap { $0.toModel() }
        if originLeft != nil && left == nil { return nil }
        return Element(id: modelID, value: ch, originLeft: left, deleted: deleted)
    }
}

/// Wire mirror of a full-document snapshot: the ordered element list (incl.
/// tombstones) and the language register.
struct CodeEditorWireSnapshot: Codable, Equatable {
    let elements: [CodeEditorWireElement]
    let languageState: CodeEditorWireLanguage

    var isValid: Bool {
        guard languageState.isValid else { return false }
        for element in elements where !element.isValid { return false }
        return true
    }
}

/// Chunk metadata for a snapshot that is too large to fit a single
/// `maxMessageBytes` DataChannel payload (design.md "State Recovery": large
/// documents chunk the snapshot across ordered messages with a final
/// "complete" marker). A `snapshot` message WITHOUT this field — or with
/// `count <= 1` — is a single, self-contained snapshot; otherwise each message
/// carries `index` of `count` ordered slices of the element list, all sharing
/// the same `languageState`. The receiver assembles slices into a staging
/// buffer and applies the document atomically ONLY once every index has
/// arrived (R4.3). The wire snapshot's element list is the slice for this
/// chunk; the model `seqVector` is reconstructed from the assembled elements.
struct CodeEditorSnapshotChunk: Codable, Equatable {
    let index: Int
    let count: Int

    /// A valid chunk descriptor has `count >= 1` and `index` within range. A
    /// single-message snapshot uses `index = 0, count = 1`.
    var isValid: Bool { count >= 1 && index >= 0 && index < count }
}

// MARK: - Message type discriminator

/// The variant carried by an `InterCodeEditorMessage`. Decodes via the raw
/// string; an UNKNOWN `type` fails decoding and is therefore rejected (returns
/// `nil` from `fromJSONData`).
enum InterCodeEditorMessageType: String, Codable {
    /// A coalesced batch of insert/delete ops (R2.1, R6.2).
    case ops
    /// A remote cursor/selection update (R2.4).
    case cursor
    /// A language-selection change (R3).
    case language
    /// A request for a full-state snapshot (late join / reconnect — R4, R8.4).
    case snapshotRequest
    /// A full authoritative snapshot in reply to `snapshotRequest` (R4.1).
    case snapshot
}

// MARK: - Envelope

/// The single `Codable` envelope exchanged on the "codeEditor" DataChannel
/// topic. Exactly one payload field is populated, selected by `type`. The
/// `senderIdentity` is SELF-DECLARED; the controller reconciles it against the
/// LiveKit-attested identity on receipt (R5.5) — that reconciliation is out of
/// scope for this wire layer.
struct InterCodeEditorMessage: Codable, Equatable {

    /// Conservative DataChannel payload ceiling (design.md "Edit operations &
    /// wire protocol": `maxMessageBytes`, 12 KB). `fromJSONData` rejects any
    /// payload larger than this before attempting to decode, so a peer cannot
    /// force large allocations or deep nested parses. The transport layer
    /// (Task 4) chunks long pastes / large snapshots to stay under this bound.
    static let maxMessageBytes = 12 * 1024

    let type: InterCodeEditorMessageType
    let senderIdentity: String

    // Exactly one of the following is non-nil, per `type`.
    let ops: [CodeEditorWireOp]?
    let cursor: CodeEditorWireCursor?
    let language: CodeEditorWireLanguage?
    let snapshot: CodeEditorWireSnapshot?

    /// Present only on a chunked `snapshot` (otherwise `nil`). See
    /// `CodeEditorSnapshotChunk`.
    let snapshotChunk: CodeEditorSnapshotChunk?

    init(type: InterCodeEditorMessageType,
         senderIdentity: String,
         ops: [CodeEditorWireOp]? = nil,
         cursor: CodeEditorWireCursor? = nil,
         language: CodeEditorWireLanguage? = nil,
         snapshot: CodeEditorWireSnapshot? = nil,
         snapshotChunk: CodeEditorSnapshotChunk? = nil) {
        self.type = type
        self.senderIdentity = senderIdentity
        self.ops = ops
        self.cursor = cursor
        self.language = language
        self.snapshot = snapshot
        self.snapshotChunk = snapshotChunk
    }

    // MARK: Structural validation

    /// `true` iff the envelope is well-formed for its `type`: the required
    /// payload is present and every field is in range. This is the bounds-check
    /// gate applied by `fromJSONData` AFTER a successful decode, so unknown op
    /// kinds, missing payloads, empty sites, and non-single-`Character` values
    /// are all rejected (R5.4).
    var isStructurallyValid: Bool {
        switch type {
        case .ops:
            guard let ops = ops, !ops.isEmpty else { return false }
            for op in ops where !op.isValid { return false }
            return true
        case .cursor:
            guard let cursor = cursor else { return false }
            return cursor.isValid
        case .language:
            guard let language = language else { return false }
            return language.isValid
        case .snapshotRequest:
            // No payload required; any stray payload is simply ignored.
            return true
        case .snapshot:
            guard let snapshot = snapshot else { return false }
            guard snapshot.isValid else { return false }
            // Chunk metadata is OPTIONAL; when present it must be in range so a
            // peer cannot push an out-of-bounds index/count into the assembler.
            if let chunk = snapshotChunk, !chunk.isValid { return false }
            return true
        }
    }

    // MARK: Serialization

    /// Encode to JSON `Data` for DataChannel transport. Mirrors
    /// `InterControlSignal.toJSONData()` / `InterPollMessage.toJSONData()`.
    func toJSONData() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// Decode from JSON `Data` received over the DataChannel. HARDENED
    /// (design.md R5.4): returns `nil` — never throws or crashes — for
    /// oversized payloads (> `maxMessageBytes`), arbitrary/garbage bytes,
    /// truncated JSON, an unknown `type`, an unknown op `kind`, missing required
    /// fields, out-of-range numbers, or a value that is not a single
    /// `Character`. A returned message is guaranteed `isStructurallyValid`.
    static func fromJSONData(_ data: Data) -> InterCodeEditorMessage? {
        // Byte ceiling FIRST, before any parse work.
        guard data.count <= maxMessageBytes else { return nil }
        guard let message = try? JSONDecoder().decode(InterCodeEditorMessage.self, from: data) else {
            return nil
        }
        guard message.isStructurallyValid else { return nil }
        return message
    }
}

// MARK: - Model ↔ wire converters

extension InterCodeEditorMessage {

    // ---- Build a wire message FROM model values --------------------------------

    /// Builds an `ops` message from a batch of model `Op`s.
    static func opsMessage(_ ops: [Op], senderIdentity: String) -> InterCodeEditorMessage {
        InterCodeEditorMessage(type: .ops,
                               senderIdentity: senderIdentity,
                               ops: ops.map(CodeEditorWireOp.init))
    }

    /// Builds a `cursor` message from anchor/head element ids.
    static func cursorMessage(anchorId: ElementID,
                              headId: ElementID,
                              senderIdentity: String) -> InterCodeEditorMessage {
        InterCodeEditorMessage(type: .cursor,
                               senderIdentity: senderIdentity,
                               cursor: CodeEditorWireCursor(anchorId: CodeEditorWireID(anchorId),
                                                            headId: CodeEditorWireID(headId)))
    }

    /// Builds a `language` message from a selection + Lamport clock value.
    static func languageMessage(language: String,
                                lamport: UInt64,
                                senderIdentity: String) -> InterCodeEditorMessage {
        InterCodeEditorMessage(type: .language,
                               senderIdentity: senderIdentity,
                               language: CodeEditorWireLanguage(language: language, lamport: lamport))
    }

    /// Builds a `snapshotRequest` message (no payload).
    static func snapshotRequestMessage(senderIdentity: String) -> InterCodeEditorMessage {
        InterCodeEditorMessage(type: .snapshotRequest, senderIdentity: senderIdentity)
    }

    /// Builds a `snapshot` message from a model `Snapshot` plus the language
    /// register. The model `Snapshot.seqVector` is NOT carried on the wire — it
    /// is fully derivable from the element ids and is reconstructed on decode
    /// (see `toSnapshot()`), matching the design's `{ elements, languageState }`
    /// snapshot shape. Pass `chunk` to mark this as one ordered slice of a
    /// chunked snapshot (R4.3); omit it for a single self-contained snapshot.
    static func snapshotMessage(_ snapshot: Snapshot,
                                language: String,
                                lamport: UInt64,
                                senderIdentity: String,
                                chunk: CodeEditorSnapshotChunk? = nil) -> InterCodeEditorMessage {
        snapshotMessage(elements: snapshot.elements,
                        language: language,
                        lamport: lamport,
                        senderIdentity: senderIdentity,
                        chunk: chunk)
    }

    /// Builds a `snapshot` message carrying a (possibly partial) ordered slice
    /// of model `Element`s. Used by the chunked-snapshot builder, which splits
    /// a large element list across several ordered messages.
    static func snapshotMessage(elements: [Element],
                                language: String,
                                lamport: UInt64,
                                senderIdentity: String,
                                chunk: CodeEditorSnapshotChunk? = nil) -> InterCodeEditorMessage {
        InterCodeEditorMessage(type: .snapshot,
                               senderIdentity: senderIdentity,
                               snapshot: CodeEditorWireSnapshot(
                                elements: elements.map(CodeEditorWireElement.init),
                                languageState: CodeEditorWireLanguage(language: language, lamport: lamport)),
                               snapshotChunk: chunk)
    }

    // ---- Decode a wire message BACK TO model values ----------------------------

    /// Decodes an `ops` message to model `Op`s, or `nil` if the type is wrong or
    /// any op is malformed.
    func toOps() -> [Op]? {
        guard type == .ops, let wireOps = ops else { return nil }
        var result: [Op] = []
        result.reserveCapacity(wireOps.count)
        for wire in wireOps {
            guard let op = wire.toModel() else { return nil }
            result.append(op)
        }
        return result
    }

    /// Decodes a `cursor` message to anchor/head element ids, or `nil`.
    func toCursor() -> (anchor: ElementID, head: ElementID)? {
        guard type == .cursor, let cursor = cursor,
              let anchor = cursor.anchorId.toModel(),
              let head = cursor.headId.toModel() else { return nil }
        return (anchor, head)
    }

    /// Decodes a `language` message to the selection + Lamport value, or `nil`.
    func toLanguage() -> (language: String, lamport: UInt64)? {
        guard type == .language, let language = language, language.isValid else { return nil }
        return (language.language, language.lamport)
    }

    /// Decodes a `snapshot` message to a model `Snapshot` plus the language
    /// register, or `nil`. The `seqVector` is reconstructed as the max `seq`
    /// observed per `site` across the element ids — exactly the vector the model
    /// would have accumulated by integrating those ids.
    func toSnapshot() -> (snapshot: Snapshot, language: String, lamport: UInt64)? {
        guard type == .snapshot, let snapshot = snapshot, snapshot.isValid else { return nil }
        var elements: [Element] = []
        elements.reserveCapacity(snapshot.elements.count)
        var seqVector: [String: UInt64] = [:]
        for wire in snapshot.elements {
            guard let element = wire.toModel() else { return nil }
            elements.append(element)
            if (seqVector[element.id.site] ?? 0) < element.id.seq {
                seqVector[element.id.site] = element.id.seq
            }
        }
        return (Snapshot(elements: elements, seqVector: seqVector),
                snapshot.languageState.language,
                snapshot.languageState.lamport)
    }
}

// MARK: - Character decode helper

/// Returns the single `Character` represented by `string`, or `nil` if the
/// string is absent, empty, or contains more than one `Character` (extended
/// grapheme cluster).
///
/// DOCUMENTED CHOICE: an RGA element holds exactly one `Character`, so the wire
/// value for an insert MUST be exactly one `Character`. We REJECT empty or
/// multi-`Character` strings rather than silently taking the first — silently
/// truncating peer input would let a malformed message mutate the document in a
/// surprising way. Note a multi-SCALAR grapheme (e.g. a flag or skin-toned
/// emoji) is a single `Character` and is therefore accepted; only multi-
/// grapheme strings are rejected.
func codeEditorSingleCharacter(_ string: String?) -> Character? {
    guard let string = string, string.count == 1 else { return nil }
    return string.first
}
