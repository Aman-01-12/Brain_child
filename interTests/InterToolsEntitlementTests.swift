// interTests/InterToolsEntitlementTests.swift
//
// Task 9 (collaborative-code-editor): client entitlement read + gating.
//
// Focused unit tests for the server-signed `tools` entitlement parser
// (`InterParticipantMetadata.parseToolsEntitlement`) and the combined
// tier-gate logic it feeds (`InterFeatureGate`). The token server stamps
// `{"role": "...", "tools": true|false}` into the participant's signed JWT
// metadata; the client reads ONLY the local participant's own metadata and
// fails closed when the flag is absent/malformed.
//
// Validates: Requirements 7.1, 7.5, 9.2, 9.5

import XCTest
@testable import inter

final class InterToolsEntitlementTests: XCTestCase {

    // MARK: - parseToolsEntitlement: true / false

    func testToolsEntitlementTrueWhenFlagIsTrue() {
        let metadata = "{\"role\": \"host\", \"tools\": true}"
        XCTAssertTrue(InterParticipantMetadata.parseToolsEntitlement(from: metadata),
                      "A genuine JSON boolean true must grant the entitlement.")
    }

    func testToolsEntitlementFalseWhenFlagIsFalse() {
        let metadata = "{\"role\": \"participant\", \"tools\": false}"
        XCTAssertFalse(InterParticipantMetadata.parseToolsEntitlement(from: metadata),
                       "A genuine JSON boolean false must deny the entitlement.")
    }

    // MARK: - parseToolsEntitlement: absent → fail-closed

    func testToolsEntitlementAbsentFailsClosed() {
        let metadata = "{\"role\": \"host\"}"
        XCTAssertFalse(InterParticipantMetadata.parseToolsEntitlement(from: metadata),
                       "Missing `tools` field must fail closed (R9.2).")
    }

    func testToolsEntitlementNilFailsClosed() {
        XCTAssertFalse(InterParticipantMetadata.parseToolsEntitlement(from: nil),
                       "nil metadata (e.g. disconnected) must fail closed.")
    }

    func testToolsEntitlementEmptyFailsClosed() {
        XCTAssertFalse(InterParticipantMetadata.parseToolsEntitlement(from: ""),
                       "Empty metadata must fail closed.")
    }

    // MARK: - parseToolsEntitlement: malformed → fail-closed

    func testToolsEntitlementMalformedJSONFailsClosed() {
        XCTAssertFalse(InterParticipantMetadata.parseToolsEntitlement(from: "{not json"),
                       "Malformed JSON must fail closed without crashing (R5.4).")
    }

    func testToolsEntitlementNonBooleanTypesFailClosed() {
        // A string "true", a number 1, and null are NOT genuine JSON booleans and
        // must all fail closed — a patched client cannot smuggle entitlement
        // through a non-boolean value.
        XCTAssertFalse(InterParticipantMetadata.parseToolsEntitlement(from: "{\"tools\": \"true\"}"),
                       "String \"true\" is not a JSON boolean → fail closed.")
        XCTAssertFalse(InterParticipantMetadata.parseToolsEntitlement(from: "{\"tools\": 1}"),
                       "Number 1 is not a JSON boolean → fail closed.")
        XCTAssertFalse(InterParticipantMetadata.parseToolsEntitlement(from: "{\"tools\": null}"),
                       "null is not a JSON boolean → fail closed.")
    }

    func testToolsEntitlementJSONArrayFailsClosed() {
        XCTAssertFalse(InterParticipantMetadata.parseToolsEntitlement(from: "[1,2,3]"),
                       "A top-level array (not an object) must fail closed.")
    }

    // MARK: - parseRole stays intact alongside the tools parser

    func testParseRoleUnaffectedByToolsField() {
        let metadata = "{\"role\": \"host\", \"tools\": true}"
        XCTAssertEqual(InterParticipantMetadata.parseRole(from: metadata), .host,
                       "Adding the tools field must not disturb existing role parsing.")
    }

    // MARK: - In-room tool gate follows the server `tools` flag, NOT local tier (R7.2, R9.1)

    func testInRoomToolGateFollowsServerFlagNotLocalParticipantTier() {
        // The InterFeatureGate tier table is unchanged — it still governs where
        // the LOCAL tier IS the basis (a host creating/hosting an interview).
        XCTAssertTrue(
            InterFeatureGate.isFeature(.collaborativeCodeEditor, availableForTier: "hiring"),
            "Hiring is the minimum tier for hosting the collaborative code editor.")
        XCTAssertFalse(
            InterFeatureGate.isFeature(.collaborativeCodeEditor, availableForTier: "pro"),
            "Pro is below the collaborative code editor's minimum tier.")

        // The IN-ROOM tool-selection gate (SecureWindowController
        // `isCollaborativeToolEntitled:`) is keyed on the ROOM CREATOR's tier,
        // delivered as the server-signed `tools` flag in the LOCAL participant's
        // JWT metadata. It is INDEPENDENT of the joining participant's own tier:
        // whoever created the room defines tool availability for everyone in it.
        // Model that decision (server flag alone — never the local tier).
        func inRoomToolAvailable(localTier: String, toolsMetadata: String?) -> Bool {
            return InterParticipantMetadata.parseToolsEntitlement(from: toolsMetadata)
        }

        let toolsOn  = "{\"role\": \"interviewee\", \"tools\": true}"
        let toolsOff = "{\"role\": \"interviewee\", \"tools\": false}"

        // Regression (the candidate bug): an ANONYMOUS / free candidate — whose
        // own tier resolves to "free" — in a hiring host's room (tools:true) IS
        // entitled. The old `tools && tierOK` gate wrongly blocked this.
        XCTAssertTrue(inRoomToolAvailable(localTier: "free", toolsMetadata: toolsOn),
                      "A free/anonymous candidate of a hiring host's room must be entitled (server tools flag).")
        XCTAssertTrue(inRoomToolAvailable(localTier: "pro", toolsMetadata: toolsOn),
                      "A pro candidate of a hiring host's room must be entitled too.")
        XCTAssertTrue(inRoomToolAvailable(localTier: "hiring", toolsMetadata: toolsOn),
                      "A hiring participant is of course entitled.")

        // The server flag remains authoritative for DENY: a non-hiring host's
        // room stamps tools:false, which denies regardless of the joiner's tier.
        XCTAssertFalse(inRoomToolAvailable(localTier: "hiring", toolsMetadata: toolsOff),
                       "Server-signed tools:false denies even a hiring-tier participant.")
        XCTAssertFalse(inRoomToolAvailable(localTier: "free", toolsMetadata: nil),
                       "No metadata (e.g. disconnected) → fail closed.")
    }
}
