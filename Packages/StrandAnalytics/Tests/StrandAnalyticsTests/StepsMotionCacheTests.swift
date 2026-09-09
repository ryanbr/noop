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

    // MARK: - Persistence

    /// The exact payload the cache renders, pinned as a literal. This is the cross-platform contract that
    /// matters most now the cache is stored: the Kotlin twin pins the SAME string, so a one-sided change to
    /// the header, the separators or the number rendering is caught here rather than by a user whose folds
    /// silently stopped being reused after an update.
    static let vector = """
    stepsMotion v1
    2026-09-01\tmy-whoop|8640|1757000000\t4659742922898407424
    2026-09-02\tmy-whoop|0|0\t0
    """

    static let vectorEntries: [String: (key: String, motion: Double)] = [
        "2026-09-01": (key: "my-whoop|8640|1757000000", motion: 3421.75),
        "2026-09-02": (key: "my-whoop|0|0", motion: 0),
    ]

    func testSerializeRendersThePinnedPayload() {
        XCTAssertEqual(StepsMotionCache.serialize(Self.vectorEntries), Self.vector)
    }

    func testRoundTripPreservesKeysAndVolumes() {
        let back = StepsMotionCache.deserialize(StepsMotionCache.serialize(Self.vectorEntries))
        XCTAssertEqual(back.count, 2)
        for (day, want) in Self.vectorEntries {
            XCTAssertEqual(back[day]?.key, want.key)
            XCTAssertEqual(back[day]?.motion, want.motion)
        }
    }

    /// A ZERO fold is a cached VALUE, not a missing one — the engine caches a zero from a read that
    /// succeeded so unworn gaps stop re-reading their whole stream every pass. A round trip that dropped it
    /// would quietly reintroduce exactly the cost the cache exists to remove, on the sparse libraries it is
    /// worst for, so the zero day is asserted present rather than merely equal.
    func testZeroFoldSurvivesTheRoundTrip() {
        let back = StepsMotionCache.deserialize(StepsMotionCache.serialize(Self.vectorEntries))
        XCTAssertNotNil(back["2026-09-02"])
        XCTAssertEqual(back["2026-09-02"]?.motion, 0)
    }

    /// Rendering is sorted, so an unchanged cache re-renders byte-identically and the store write coalesces
    /// instead of churning a 60-entry payload on every pass.
    func testRenderingIsStableAcrossDictionaryOrder() {
        var shuffled: [String: (key: String, motion: Double)] = [:]
        for (day, e) in Self.vectorEntries.sorted(by: { $0.key > $1.key }) { shuffled[day] = e }
        XCTAssertEqual(StepsMotionCache.serialize(shuffled), StepsMotionCache.serialize(Self.vectorEntries))
    }

    /// An older fold's payload must be DISCARDED, not read. `cacheKey` witnesses the inputs only, so a day
    /// whose gravity has not moved keys identically across an app update — without the header check the
    /// pre-update volume would be served until that day's stream happened to change.
    func testOlderFoldVersionIsDiscarded() {
        let stale = Self.vector.replacingOccurrences(of: "stepsMotion v1", with: "stepsMotion v0")
        XCTAssertTrue(StepsMotionCache.deserialize(stale).isEmpty)
    }

    /// Anything that is not a payload this cache wrote yields an empty cache and one re-fold, never a
    /// partially-trusted one.
    func testUnreadablePayloadsYieldNothing() {
        for raw in ["", "stepsMotion", "garbage", "\n", "v1\n2026-09-01\tk\t0"] {
            XCTAssertTrue(StepsMotionCache.deserialize(raw).isEmpty, "expected empty for \(raw.debugDescription)")
        }
    }

    /// A malformed line is skipped and its neighbours survive: a truncated write should cost the days it
    /// truncated, not the whole window.
    func testMalformedLinesAreSkippedIndividually() {
        let raw = """
        stepsMotion v1
        2026-09-01\tmy-whoop|8640|1757000000\t4659742922898407424
        2026-09-02\tmissing-a-field
        2026-09-03\tmy-whoop|1|2\tnot-a-number
        \tempty-day\t0
        2026-09-05\t\t0
        2026-09-06\tmy-whoop|3|4\t4623226492472524800
        """
        let back = StepsMotionCache.deserialize(raw)
        XCTAssertEqual(Set(back.keys), ["2026-09-01", "2026-09-06"])
        XCTAssertEqual(back["2026-09-06"]?.motion, 12.5)
    }

    /// The writer prunes to the calibration window every pass, so a payload far above it did not come from
    /// this cache. Rejecting it whole keeps a hand-edited or corrupt store from being parsed at length.
    func testImplausiblyLargePayloadIsRejected() {
        var raw = "stepsMotion v1"
        for i in 0...513 { raw += "\nday-\(i)\tmy-whoop|1|2\t0" }
        XCTAssertTrue(StepsMotionCache.deserialize(raw).isEmpty)
    }

    /// Rendering is a FIXPOINT over a payload this build wrote. The engine skips the store write when the
    /// rendered cache equals what is stored, so a pass that reused every day must produce the string it
    /// read: if this ever stopped holding, every pass of an offload storm would write ~4 KB to say nothing.
    func testRenderingIsAFixpoint() {
        let once = StepsMotionCache.serialize(Self.vectorEntries)
        XCTAssertEqual(StepsMotionCache.serialize(StepsMotionCache.deserialize(once)), once)
    }

    /// The other half of that guard: a payload carrying a line this build DROPS must not re-render to
    /// itself, so the cleaned version is written back once rather than being re-parsed every launch.
    func testDroppedLinesReRenderDifferentlyAndAreRewritten() {
        let dirty = Self.vector + "\n2026-09-03\tmy-whoop|1|2\tnot-a-number"
        let cleaned = StepsMotionCache.serialize(StepsMotionCache.deserialize(dirty))
        XCTAssertNotEqual(cleaned, dirty)
        XCTAssertEqual(cleaned, Self.vector)
    }
}
