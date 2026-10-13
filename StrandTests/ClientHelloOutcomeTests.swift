import XCTest
@testable import Strand

/// Pins the CLIENT_HELLO outcome line (#1635). Kotlin twin: `ClientHelloOutcomeTest`.
final class ClientHelloOutcomeTests: XCTestCase {

    private let hello = "fd4b0002-cce1-4033-93ce-002d5875f58a"

    func testACompletionFromTheHelloCharacteristicIsARealAck() {
        XCTAssertEqual(
            ClientHelloOutcome.line(isHelloChar: true, charUuid: hello, elapsedMs: 120,
                                    status: "status=SUCCESS(0)"),
            "CLIENT_HELLO outcome: acked by \(hello) after 120ms status=SUCCESS(0)")
    }

    func testACompletionFromAnotherCharacteristicIsNamedNotCountedAsAnAck() {
        let line = ClientHelloOutcome.line(isHelloChar: false,
                                           charUuid: "00002a19-0000-1000-8000-00805f9b34fb",
                                           elapsedMs: 40, status: "status=SUCCESS(0)")
        XCTAssertTrue(line.contains("DIFFERENT characteristic 00002a19-0000-1000-8000-00805f9b34fb"), line)
        XCTAssertTrue(line.contains("NOT a CLIENT_HELLO ack"), line)
        XCTAssertFalse(line.contains("outcome: acked"), line)
    }

    func testNoCallbackAtAllIsReportedWithTheElapsedTime() {
        XCTAssertEqual(
            ClientHelloOutcome.line(isHelloChar: false, charUuid: nil, elapsedMs: 3200, status: nil),
            "CLIENT_HELLO outcome: NO write callback after 3200ms — the link dropped before the stack"
            + " reported, so the strap may never have seen it")
    }

    func testANilCharacteristicWinsOverTheIsHelloCharFlag() {
        XCTAssertTrue(ClientHelloOutcome.line(isHelloChar: true, charUuid: nil, elapsedMs: 10,
                                              status: "status=SUCCESS(0)").contains("NO write callback"))
    }

    func testABlankCharacteristicAndStatusDegradeWithoutPunctuationDebris() {
        XCTAssertEqual(
            ClientHelloOutcome.line(isHelloChar: true, charUuid: "   ", elapsedMs: 5, status: "  "),
            "CLIENT_HELLO outcome: acked by unknown after 5ms")
    }

    // MARK: - the bond gate (#1635)

    /// 15:24:13 in the field capture: DISABLE_ALARM was in flight, the CLIENT_HELLO write was rejected so
    /// nothing was owed, and DISABLE_ALARM's completion then arrived on fd4b0002 — the SAME characteristic
    /// the hello uses — and the link was declared bonded. `isHelloChar` is true here, which is exactly why
    /// a uuid check on its own would not have caught it.
    func testQueuedCommandOnTheHelloCharacteristicIsNotABond() {
        XCTAssertFalse(ClientHelloOutcome.isAck(
            isHelloChar: true, helloOutstanding: false, alreadyBonded: false, isWhoop5: true))
    }

    func testForeignCharacteristicInsideTheWindowIsNotABond() {
        XCTAssertFalse(ClientHelloOutcome.isAck(
            isHelloChar: false, helloOutstanding: true, alreadyBonded: false, isWhoop5: true))
    }

    /// The regression that matters most: the gate must not cost a real bond.
    func testGenuineAckStillBonds() {
        XCTAssertTrue(ClientHelloOutcome.isAck(
            isHelloChar: true, helloOutstanding: true, alreadyBonded: false, isWhoop5: true))
    }

    func testAlreadyBondedDoesNotReBondAndWhoop4NeverTakesThisPath() {
        XCTAssertFalse(ClientHelloOutcome.isAck(
            isHelloChar: true, helloOutstanding: true, alreadyBonded: true, isWhoop5: true))
        XCTAssertFalse(ClientHelloOutcome.isAck(
            isHelloChar: true, helloOutstanding: true, alreadyBonded: false, isWhoop5: false))
    }

    // MARK: - Re-proving a bond on a re-entered link

    /// The first bond is untouched: the hello's own completion on a link that has never bonded.
    func testTheHellosOwnCompletionOnAnUnbondedLinkIsTheFirstBond() {
        XCTAssertEqual(ClientHelloOutcome.classify(
            isHelloChar: true, helloOutstanding: true, alreadyBonded: false,
            encryptedBond: false, samePeripheralAsBond: true, isWhoop5: true), .firstBond)
    }

    /// The case this exists for. `didConnect` re-entered a live link (no disconnect, so `didBond` survives)
    /// and cleared `encryptedBond`; re-discovery wrote a fresh CLIENT_HELLO and this is its completion.
    /// Declining it leaves the strap on "Live HR (not fully paired)" with buzz refused for the whole link.
    func testTheHellosOwnCompletionAfterAReenteredConnectReprovesTheBond() {
        XCTAssertEqual(ClientHelloOutcome.classify(
            isHelloChar: true, helloOutstanding: true, alreadyBonded: true,
            encryptedBond: false, samePeripheralAsBond: true, isWhoop5: true), .reprove)
    }

    /// Every offload ack on fd4b0002 lands here once bonded; none may re-run bond bookkeeping.
    func testLaterAcksOnAProvenLinkRecordNothing() {
        XCTAssertEqual(ClientHelloOutcome.classify(
            isHelloChar: true, helloOutstanding: true, alreadyBonded: true,
            encryptedBond: true, samePeripheralAsBond: true, isWhoop5: true), .alreadyProven)
    }

    /// The #1635 hazard, re-asked of the new path: re-proving must demand the hello's OWN window, or an
    /// ordinary command completing on the shared command characteristic would re-grant the bond. That is
    /// the DISABLE_ALARM capture all over again, just on a link that bonded once.
    func testAQueuedCommandCannotReproveABondOnAReenteredLink() {
        XCTAssertEqual(ClientHelloOutcome.classify(
            isHelloChar: true, helloOutstanding: false, alreadyBonded: true,
            encryptedBond: false, samePeripheralAsBond: true, isWhoop5: true), .notAnAck)
    }

    /// Nor may a completion from a different characteristic that happens to land inside the window.
    func testAForeignCompletionCannotReproveABondOnAReenteredLink() {
        XCTAssertEqual(ClientHelloOutcome.classify(
            isHelloChar: false, helloOutstanding: true, alreadyBonded: true,
            encryptedBond: false, samePeripheralAsBond: true, isWhoop5: true), .notAnAck)
    }

    /// A WHOOP 4.0 link never reaches this classifier; its own `Whoop4BondAck` owns that family.
    func testWhoop4NeverReachesThisClassifier() {
        for bonded in [false, true] {
            for encrypted in [false, true] {
                XCTAssertEqual(ClientHelloOutcome.classify(
                    isHelloChar: true, helloOutstanding: true, alreadyBonded: bonded,
                    encryptedBond: encrypted, samePeripheralAsBond: true, isWhoop5: false), .notAnAck)
            }
        }
    }

    /// `isAck` is now derived from `classify`, so the two cannot drift. Pin that across every input, which
    /// also means the existing `isAck` cases above are assertions about the classifier.
    func testIsAckAgreesWithTheClassifierOnEveryInput() {
        for isHelloChar in [false, true] {
            for helloOutstanding in [false, true] {
                for alreadyBonded in [false, true] {
                    for isWhoop5 in [false, true] {
                        let ack = ClientHelloOutcome.isAck(
                            isHelloChar: isHelloChar, helloOutstanding: helloOutstanding,
                            alreadyBonded: alreadyBonded, isWhoop5: isWhoop5)
                        let classified = ClientHelloOutcome.classify(
                            isHelloChar: isHelloChar, helloOutstanding: helloOutstanding,
                            alreadyBonded: alreadyBonded, encryptedBond: false,
                            samePeripheralAsBond: true, isWhoop5: isWhoop5)
                        XCTAssertEqual(ack, classified == .firstBond,
                                       "hello=\(isHelloChar) outstanding=\(helloOutstanding) "
                                       + "bonded=\(alreadyBonded) whoop5=\(isWhoop5)")
                    }
                }
            }
        }
    }

    /// The 5/MG half of the strap-identity guard, same reasoning as `Whoop4BondAckTests`: a second strap's
    /// own hello ack arriving while `didBond` still reads true from the first must run ITS first bond.
    func testADifferentStrapsOwnHelloAckIsItsFirstBond() {
        for encrypted in [false, true] {
            XCTAssertEqual(ClientHelloOutcome.classify(
                isHelloChar: true, helloOutstanding: true, alreadyBonded: true,
                encryptedBond: encrypted, samePeripheralAsBond: false, isWhoop5: true), .firstBond)
        }
    }

    /// The guard does not loosen the evidence standard: a queued command on the shared characteristic is
    /// still not an ack, whichever strap it came from.
    func testTheStrapGuardDoesNotAdmitAQueuedCommand() {
        XCTAssertEqual(ClientHelloOutcome.classify(
            isHelloChar: true, helloOutstanding: false, alreadyBonded: true,
            encryptedBond: false, samePeripheralAsBond: false, isWhoop5: true), .notAnAck)
    }

    // MARK: - #1883: Apple bond timing tell

    /// A completion faster than one connection interval did not come from the strap — that is the
    /// signature of #1635's false bond. The line must name it as UNVERIFIED and reference both issues.
    func testSuspiciouslyFastCompletionFlagsUnverifiedBond() {
        let line = ClientHelloOutcome.unverifiedBondTimingLine(elapsedMs: 5)
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains("acked after 5ms"), line!)
        XCTAssertTrue(line!.contains("under one BLE connection interval"), line!)
        XCTAssertTrue(line!.contains("UNVERIFIED"), line!)
        XCTAssertTrue(line!.contains("#1883"), line!)
        XCTAssertTrue(line!.contains("#1635"), line!)
    }

    /// A completion at or above the threshold is plausible and returns nil — no diagnostic line.
    func testPlausibleCompletionReturnsNil() {
        XCTAssertNil(ClientHelloOutcome.unverifiedBondTimingLine(elapsedMs: 8))
        XCTAssertNil(ClientHelloOutcome.unverifiedBondTimingLine(elapsedMs: 120))
        XCTAssertNil(ClientHelloOutcome.unverifiedBondTimingLine(elapsedMs: 3150))
    }

    /// The threshold matches the Android twin (MIN_PLAUSIBLE_ATT_ROUND_TRIP_MS = 8).
    func testThresholdMatchesAndroidTwin() {
        XCTAssertEqual(ClientHelloOutcome.minPlausibleAttRoundTripMs, 8)
    }

    /// A 0ms completion is the most suspicious — it cannot be a round trip at all.
    func testZeroMsCompletionFlagsUnverifiedBond() {
        let line = ClientHelloOutcome.unverifiedBondTimingLine(elapsedMs: 0)
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains("acked after 0ms"), line!)
        XCTAssertTrue(line!.contains("UNVERIFIED"), line!)
    }
}

