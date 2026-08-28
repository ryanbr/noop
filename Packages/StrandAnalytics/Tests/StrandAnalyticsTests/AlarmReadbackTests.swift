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
}
