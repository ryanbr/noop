import XCTest
@testable import StrandAnalytics

/// The steps-calibration motion cache's key and readout. Mirrored by the Kotlin
/// `StepsMotionCacheTest`, which pins the SAME literals — the key is a cross-platform contract only in
/// the sense that both sides must invalidate on the same facts, and pinning the rendered strings is how
/// a one-sided change to either rule is caught.
final class StepsMotionCacheTests: XCTestCase {

    func testKeyIsStableForUnchangedInputs() {
        let a = StepsMotionCache.cacheKey(owner: "my-whoop", gravityCount: 8640, gravityMaxTs: 1_757_000_000)
        let b = StepsMotionCache.cacheKey(owner: "my-whoop", gravityCount: 8640, gravityMaxTs: 1_757_000_000)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "my-whoop|8640|1757000000")
    }

    /// The three facts that MUST invalidate a fold, one at a time. A row added moves the count; a row
    /// replacing another at a newer timestamp moves the max; a day changing hands moves the owner.
    func testEveryInputInvalidates() {
        let base = StepsMotionCache.cacheKey(owner: "my-whoop", gravityCount: 8640, gravityMaxTs: 1_757_000_000)
        XCTAssertNotEqual(base, StepsMotionCache.cacheKey(owner: "my-whoop", gravityCount: 8641,
                                                          gravityMaxTs: 1_757_000_000))
        XCTAssertNotEqual(base, StepsMotionCache.cacheKey(owner: "my-whoop", gravityCount: 8640,
                                                          gravityMaxTs: 1_757_000_001))
        XCTAssertNotEqual(base, StepsMotionCache.cacheKey(owner: "whoop-5mg", gravityCount: 8640,
                                                          gravityMaxTs: 1_757_000_000))
    }

    /// An empty day is a real, cacheable answer — the key for it is well-formed and distinct from a day
    /// that has rows. Caching it is what stops an unworn gap re-reading its whole stream every pass.
    func testEmptyDayHasItsOwnKey() {
        let empty = StepsMotionCache.cacheKey(owner: "my-whoop", gravityCount: 0, gravityMaxTs: 0)
        XCTAssertEqual(empty, "my-whoop|0|0")
        XCTAssertNotEqual(empty, StepsMotionCache.cacheKey(owner: "my-whoop", gravityCount: 1,
                                                           gravityMaxTs: 0))
    }

    /// The owner is the FIRST field, so two devices cannot collide by arranging their counts: the
    /// separator makes `a|1|2` and `a|1|2` the only way to match.
    func testOwnerBoundaryCannotBeForgedByCounts() {
        XCTAssertNotEqual(StepsMotionCache.cacheKey(owner: "a", gravityCount: 1, gravityMaxTs: 2),
                          StepsMotionCache.cacheKey(owner: "a|1", gravityCount: 2, gravityMaxTs: 0))
    }

    func testLogLineReportsTheRatioAndSize() {
        XCTAssertEqual(StepsMotionCache.logLine(reused: 58, folded: 2, size: 60),
                       "analyzeRecent stepsMotion reused=58/60 size=60")
        // A cold process: everything folded, nothing reused. This is the line a FIRST pass prints, and
        // seeing it on every pass is the symptom that the key is moving when it should not.
        XCTAssertEqual(StepsMotionCache.logLine(reused: 0, folded: 60, size: 60),
                       "analyzeRecent stepsMotion reused=0/60 size=60")
    }
}
