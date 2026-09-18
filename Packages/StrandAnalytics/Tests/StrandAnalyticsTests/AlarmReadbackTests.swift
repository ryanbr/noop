import XCTest
@testable import StrandAnalytics

/// #1706. The values here are the ones from the field log that produced the issue: an arm sent
/// 2026-08-26 06:30 against a readback claiming 2045-06-10, on a phone with a 4.0 and a 5.0 registered.
/// Twin of Kotlin `AlarmReadbackTest`.
final class AlarmReadbackTests: XCTestCase {

    private let sent = 1_787_682_600      // 2026-08-26 06:30 +12:00
    private let reported = 2_380_672_980  // 2045-06-10 14:03 +12:00, what the strap reported back

    func testSameStrapAndAgreeing() {
        XCTAssertEqual(AlarmReadback.verdict(sentEpoch: sent, reportedEpoch: sent + 5,
                                             sentDeviceId: "whoop-a", reportedDeviceId: "whoop-a"), .matches)
    }

    func testSameStrapAtTheToleranceBoundary() {
        XCTAssertEqual(AlarmReadback.verdict(sentEpoch: sent, reportedEpoch: sent + 120,
                                             sentDeviceId: "whoop-a", reportedDeviceId: "whoop-a"), .matches)
        XCTAssertEqual(AlarmReadback.verdict(sentEpoch: sent, reportedEpoch: sent + 121,
                                             sentDeviceId: "whoop-a", reportedDeviceId: "whoop-a"), .mismatch)
    }

    func testSameStrapAndDisagreeingIsTheOnlyRealRefusal() {
        let v = AlarmReadback.verdict(sentEpoch: sent, reportedEpoch: reported,
                                      sentDeviceId: "whoop-a", reportedDeviceId: "whoop-a")
        XCTAssertEqual(v, .mismatch)
        XCTAssertTrue(AlarmReadback.countsAsRejection(v))
    }

    /// The field case: the readback can only come from the 4.0, the arm went to the active 5.0.
    func testCrossStrapIsNotJudged() {
        let v = AlarmReadback.verdict(sentEpoch: sent, reportedEpoch: reported,
                                      sentDeviceId: "whoop-5mg", reportedDeviceId: "my-whoop")
        XCTAssertEqual(v, .differentStrap)
        XCTAssertFalse(AlarmReadback.countsAsRejection(v), "a strap that was never asked must not be blamed")
        XCTAssertFalse(AlarmReadback.clearsRejectionStreak(v), "nor may it clear a real refusal")
    }

    /// Data written before attribution existed. Unknown is not the same as innocent.
    func testMissingAttributionIsNotJudged() {
        let pairs: [(String?, String?)] = [(nil, "whoop-a"), ("whoop-a", nil), (nil, nil), ("", "whoop-a")]
        for (a, b) in pairs {
            let v = AlarmReadback.verdict(sentEpoch: sent, reportedEpoch: reported,
                                          sentDeviceId: a, reportedDeviceId: b)
            XCTAssertEqual(v, .unattributed, "\(String(describing: a)) / \(String(describing: b))")
            XCTAssertFalse(AlarmReadback.countsAsRejection(v))
            XCTAssertFalse(AlarmReadback.clearsRejectionStreak(v))
        }
    }

    func testOnlyAProvenAgreementClearsTheStreak() {
        XCTAssertTrue(AlarmReadback.clearsRejectionStreak(.matches))
        XCTAssertFalse(AlarmReadback.clearsRejectionStreak(.mismatch))
        XCTAssertFalse(AlarmReadback.clearsRejectionStreak(.differentStrap))
        XCTAssertFalse(AlarmReadback.clearsRejectionStreak(.unattributed))
    }

    func testSuffixShape() {
        XCTAssertEqual(AlarmReadback.suffix(.matches), "  ✓ matches")
        XCTAssertEqual(AlarmReadback.suffix(.mismatch), "  ⚠️ MISMATCH — strap didn't accept the time")
        XCTAssertEqual(AlarmReadback.suffix(.differentStrap), "  (readback is from a different strap — not comparable)")
        XCTAssertEqual(AlarmReadback.suffix(.unattributed), "  (no strap recorded for one of these — not comparable)")
    }

    // MARK: - #2322: same strap, but was it the same ARM?

    private let armedAt: Double = 1_789_728_000   // wall clock when the arm went out, seconds

    func testAReadbackOlderThanTheArmIsNotComparable() {
        // The shape from #2322: an arm goes out, its readback frame fails to decode, so the PREVIOUS
        // readback is still what is stored. Judging it blames the strap for answering a question it was
        // never asked on this arm.
        let v = AlarmReadback.verdict(sentEpoch: sent, reportedEpoch: reported,
                                      sentDeviceId: "whoop-a", reportedDeviceId: "whoop-a",
                                      sentAt: armedAt, reportedAt: armedAt - 60)
        XCTAssertEqual(v, .staleReadback)
        XCTAssertFalse(AlarmReadback.countsAsRejection(v),
                       "a readback from an earlier arm must not climb the streak")
        XCTAssertFalse(AlarmReadback.clearsRejectionStreak(v), "nor may it clear a real refusal")
    }

    func testAReadbackThatAnsweredThisArmIsStillJudged() {
        // The guard must not swallow the real signal it sits in front of.
        XCTAssertEqual(AlarmReadback.verdict(sentEpoch: sent, reportedEpoch: reported,
                                             sentDeviceId: "whoop-a", reportedDeviceId: "whoop-a",
                                             sentAt: armedAt, reportedAt: armedAt + 1), .mismatch)
        XCTAssertEqual(AlarmReadback.verdict(sentEpoch: sent, reportedEpoch: sent + 5,
                                             sentDeviceId: "whoop-a", reportedDeviceId: "whoop-a",
                                             sentAt: armedAt, reportedAt: armedAt + 1), .matches)
    }

    func testAnInstallWithNoArrivalStampsJudgesAsBefore() {
        // nil means the key was never written (an install predating them). Staleness is then not judged
        // rather than guessed, so behaviour is byte-identical to the pre-#2322 verdict.
        XCTAssertEqual(AlarmReadback.verdict(sentEpoch: sent, reportedEpoch: reported,
                                             sentDeviceId: "whoop-a", reportedDeviceId: "whoop-a"),
                       .mismatch)
        XCTAssertEqual(AlarmReadback.verdict(sentEpoch: sent, reportedEpoch: reported,
                                             sentDeviceId: "whoop-a", reportedDeviceId: "whoop-a",
                                             sentAt: armedAt, reportedAt: nil), .mismatch)
    }

    func testACrossStrapPairIsNamedBeforeStaleness() {
        // Both faults at once: the strap problem is the one that sends the reader to the right device.
        XCTAssertEqual(AlarmReadback.verdict(sentEpoch: sent, reportedEpoch: reported,
                                             sentDeviceId: "whoop-a", reportedDeviceId: "whoop-b",
                                             sentAt: armedAt, reportedAt: armedAt - 60), .differentStrap)
    }

    func testStaleHasItsOwnSuffix() {
        XCTAssertEqual(AlarmReadback.suffix(.staleReadback), "  (readback predates this arm — not comparable)")
    }
}
