import XCTest

/// The contract the batched gravity witness rests on, pinned on the Swift side.
///
/// Twin of Kotlin `GravityWitnessDayBucketTest`. The SQL in `WhoopStore.gravityFingerprintByDay` groups by
/// `(ts + tzOffset) / 86400`, and the steps-calibration loop looks a day up with the same expression. They
/// have to name the same bucket for every sample in a day, or the loop reads a witness belonging to another
/// day and the motion cache serves the wrong fold. Sixty per-day queries could not get this wrong, since
/// each carried its own window; one grouped query can.
///
/// `IntelligenceEngine` is app-target, so this pins the arithmetic the twin defines rather than importing
/// it. The Kotlin twin calls production directly; the shared definition is what keeps them honest.
final class GravityWitnessDayBucketTests: XCTestCase {

    private let day = 86_400

    /// Mirrors `IntelligenceEngine.midnightLocal`, which is Euclidean so it matches Kotlin's floorMod.
    private func midnightLocal(_ ts: Int, offsetSec: Int) -> Int {
        let m = (ts + offsetSec) % day
        return ts - (m < 0 ? m + day : m)
    }

    private func bucket(_ ts: Int, _ offsetSec: Int) -> Int { (ts + offsetSec) / day }

    private let offsets = [12 * 3600, 13 * 3600, 0, 5 * 3600 + 1800, -5 * 3600, -11 * 3600]

    func testEverySecondOfALocalDaySharesThatDaysBucket() {
        let anchor = 1_789_000_000
        for off in offsets {
            let dayMid = midnightLocal(anchor, offsetSec: off)
            let expected = bucket(dayMid, off)
            for probe in [0, 1, 3600, day / 2, day - 2, day - 1] {
                XCTAssertEqual(expected, bucket(dayMid + probe, off), "offset=\(off) probe=\(probe)")
            }
        }
    }

    func testTheSecondAfterADayEndsBelongsToTheNextBucket() {
        let anchor = 1_789_000_000
        for off in offsets {
            let dayMid = midnightLocal(anchor, offsetSec: off)
            XCTAssertEqual(bucket(dayMid, off) + 1, bucket(dayMid + day, off), "offset=\(off)")
        }
    }

    func testSixtyConsecutiveDaysOccupySixtyConsecutiveBuckets() {
        let anchor = 1_789_000_000
        for off in offsets {
            let now = midnightLocal(anchor, offsetSec: off)
            let buckets = (0..<60).map { bucket(midnightLocal(now - $0 * day, offsetSec: off), off) }
            XCTAssertEqual(60, Set(buckets).count, "offset=\(off): no two days may share a bucket")
            XCTAssertEqual(buckets.max()! - buckets.min()!, 59, "offset=\(off): and they must be contiguous")
        }
    }

    func testTruncationEqualsFloorAcrossThePlausibleRange() {
        // Truncation and floor diverge only for a negative dividend. Every real ts clears the 1.7e9
        // plausibility floor and the largest western offset is well under a day, so the sum stays positive.
        for off in offsets {
            for ts in [1_700_000_000, 1_789_000_000, 2_000_000_000] {
                XCTAssertGreaterThan(ts + off, 0, "ts=\(ts) offset=\(off)")
                let floored = Int((Double(ts + off) / Double(day)).rounded(.down))
                XCTAssertEqual(floored, bucket(ts, off))
            }
        }
    }
}
