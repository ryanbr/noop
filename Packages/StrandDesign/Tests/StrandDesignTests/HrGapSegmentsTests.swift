import XCTest
@testable import StrandDesign

/// A bucket aggregate omits buckets that had no samples, so without a break the line joins the two
/// sides of an absence and draws a steady climb across hours the strap recorded nothing. These ids are
/// what break it.
///
/// The same table is asserted in Kotlin `HrGapSegmentsTest`, so the two platforms cannot start
/// disagreeing about what counts as a gap.
final class HrGapSegmentsTests: XCTestCase {

    private let b = 300

    func testContiguousBucketsAreOneUnbrokenLine() {
        XCTAssertEqual(hrGapSegments(bucketTs: [0, 300, 600, 900], bucketSeconds: b),
                       ["0", "0", "0", "0"])
    }

    func testOneMissingBucketBreaksIt() {
        XCTAssertEqual(hrGapSegments(bucketTs: [0, 300, 900, 1_200], bucketSeconds: b),
                       ["0", "0", "1", "1"])
    }

    func testEveryGapAdvancesTheSegment() {
        XCTAssertEqual(hrGapSegments(bucketTs: [0, 900, 1_200, 3_000], bucketSeconds: b),
                       ["0", "1", "1", "2"])
    }

    func testALongAbsenceIsStillOneBreakNotMany() {
        // The four and a half hour hole from the report: one break, not fifty-four.
        XCTAssertEqual(hrGapSegments(bucketTs: [0, 300, 300 + 16_200], bucketSeconds: b),
                       ["0", "0", "1"])
    }

    func testExactlyOneBucketApartIsNotAGap() {
        XCTAssertEqual(hrGapSegments(bucketTs: [0, 300], bucketSeconds: b), ["0", "0"])
    }

    func testDegenerateInputsDoNotThrow() {
        XCTAssertEqual(hrGapSegments(bucketTs: [], bucketSeconds: b), [])
        XCTAssertEqual(hrGapSegments(bucketTs: [42], bucketSeconds: b), ["0"])
    }

    func testTheBucketWidthIsRespectedRatherThanAssumed() {
        // A 15-second load (the narrow end of the dynamic sizing) must not read every step as a gap.
        XCTAssertEqual(hrGapSegments(bucketTs: [0, 15, 30, 90], bucketSeconds: 15),
                       ["0", "0", "0", "1"])
    }
}
