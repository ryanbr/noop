import XCTest
@testable import WhoopProtocol

final class Whoop5VariantTests: XCTestCase {

    func testSerialPrefixIdentifiesMG() {
        XCTAssertEqual(Whoop5Variant.from(serial: "5AM12345678"), .mg)
        XCTAssertTrue(Whoop5Variant.from(serial: "5AM12345678").isMG)
    }

    func testSerialPrefixIdentifiesFiveZero() {
        XCTAssertEqual(Whoop5Variant.from(serial: "5AG12345678"), .fiveZero)
        XCTAssertFalse(Whoop5Variant.from(serial: "5AG12345678").isMG)
    }

    func testHardwareRevisionIsDeviceAttestedFiveZero() {
        // The observed 5.0 hardware id, with no serial available at all.
        XCTAssertEqual(Whoop5Variant.from(serial: nil, hardwareRevision: "WG50_r52"), .fiveZero)
    }

    func testAdvertisedNamePrefixTolerated() {
        // Callers may pass the advertised name instead of the DIS serial.
        XCTAssertEqual(Whoop5Variant.from(serial: "WHOOP 5AM12345678"), .mg)
        XCTAssertEqual(Whoop5Variant.from(serial: "  whoop 5ag12345678  "), .fiveZero)
    }

    func testContradictionYieldsUnknownRatherThanAGuess() {
        // Only the 5.0 hardware string is attested today; a contradiction means our model is
        // incomplete, so refuse to pick a winner (#716: a mis-stamped model is worse than none).
        XCTAssertEqual(Whoop5Variant.from(serial: "5AM12345678", hardwareRevision: "WG50_r52"), .unknown)
    }

    func testAgreeingSignalsResolve() {
        XCTAssertEqual(Whoop5Variant.from(serial: "5AG12345678", hardwareRevision: "WG50_r52"), .fiveZero)
    }

    func testUnattestedInputsAreUnknownNeverInferred() {
        XCTAssertEqual(Whoop5Variant.from(serial: nil), .unknown)
        XCTAssertEqual(Whoop5Variant.from(serial: ""), .unknown)
        XCTAssertEqual(Whoop5Variant.from(serial: "WHOOP"), .unknown)
        // A stray digit in the name must NOT imply a generation (#772 — the bug that read a
        // serial's "5" as Gen5 on a Gen3 ring; same failure mode, different product).
        XCTAssertEqual(Whoop5Variant.from(serial: "WHOOP 4.0"), .unknown)
        XCTAssertEqual(Whoop5Variant.from(serial: "5XX99999999"), .unknown)
        // An MG hardware-revision string is not yet attested, so it must not resolve by itself.
        XCTAssertEqual(Whoop5Variant.from(serial: nil, hardwareRevision: "WGMG_r01"), .unknown)
    }

    func testLabels() {
        XCTAssertEqual(Whoop5Variant.mg.label, "MG")
        XCTAssertEqual(Whoop5Variant.fiveZero.label, "5.0")
        XCTAssertEqual(Whoop5Variant.unknown.label, "—")
    }

    /// The field capture that exposed the gap: serial prefix "MGB", hardware revision "WS50_r03" — neither
    /// matches `mgSerialPrefix` ("5AM") nor `fiveZeroHardwareIdToken` ("WG50"), so every heuristic returned
    /// unknown for a strap whose own model number said MG.
    func testRealMGResolvesFromItsModelNumberWhenPrefixesDoNot() {
        XCTAssertEqual(Whoop5Variant.from(serial: "MGB0779473", hardwareRevision: "WS50_r03"), .unknown)
        XCTAssertEqual(
            Whoop5Variant.from(serial: "MGB0779473", hardwareRevision: "WS50_r03", modelNumber: "MG"), .mg)
    }

    func testModelNumberIsTrimmedAndCaseInsensitive() {
        XCTAssertEqual(Whoop5Variant.from(serial: nil, modelNumber: "  mg  "), .mg)
    }

    /// Only MG is claimed. No 5.0 has been observed reporting a model number, so an unrecognised one must
    /// fall through to the existing heuristics rather than inventing a verdict.
    func testAnUnknownModelNumberDoesNotOverrideTheHeuristics() {
        XCTAssertEqual(Whoop5Variant.from(serial: "5AG12345678", modelNumber: "WHOOP5"), .fiveZero)
        XCTAssertEqual(Whoop5Variant.from(serial: nil, modelNumber: "WHOOP5"), .unknown)
    }

    /// The model number outranks the contradiction guard: two heuristics disagreeing is a reason not to
    /// guess, but it is not a reason to ignore the strap stating its own model.
    func testModelNumberBeatsTheContradictionGuard() {
        XCTAssertEqual(
            Whoop5Variant.from(serial: "5AM12345678", hardwareRevision: "WG50_r52", modelNumber: "MG"), .mg)
    }
}
