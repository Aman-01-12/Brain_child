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

    // MARK: - Combined gate: tools flag AND tier both required (R9.2)

    func testCombinedGateRequiresBothToolsAndTier() {
        // Hiring tier passes the centralized feature check.
        XCTAssertTrue(
            InterFeatureGate.isFeature(.collaborativeCodeEditor, availableForTier: "hiring"),
            "Hiring is the minimum tier for the collaborative code editor.")
        XCTAssertFalse(
            InterFeatureGate.isFeature(.collaborativeCodeEditor, availableForTier: "pro"),
            "Pro is below the collaborative code editor's minimum tier.")
        XCTAssertFalse(
            InterFeatureGate.isFeature(.collaborativeCodeEditor, availableForTier: "free"),
            "Free is below the collaborative code editor's minimum tier.")

        // The effective client-side decision is the AND of the server-signed
        // tools flag and the tier check. Model that combination explicitly.
        func available(tier: String, toolsMetadata: String?) -> Bool {
            let tools = InterParticipantMetadata.parseToolsEntitlement(from: toolsMetadata)
            let tierOK = InterFeatureGate.isFeature(.collaborativeCodeEditor, availableForTier: tier)
            return tools && tierOK
        }

        let hiringMeta = "{\"role\": \"host\", \"tools\": true}"
        let noToolsMeta = "{\"role\": \"host\", \"tools\": false}"

        XCTAssertTrue(available(tier: "hiring", toolsMetadata: hiringMeta),
                      "Hiring tier + server-signed tools:true → available.")
        XCTAssertFalse(available(tier: "hiring", toolsMetadata: noToolsMeta),
                       "Server-signed tools:false denies even at hiring tier (R9.2).")
        XCTAssertFalse(available(tier: "pro", toolsMetadata: hiringMeta),
                       "Below-hiring tier denies even with tools:true (defense-in-depth, R7.5).")
        XCTAssertFalse(available(tier: "free", toolsMetadata: nil),
                       "No tier + no metadata → fail closed.")
    }
}
