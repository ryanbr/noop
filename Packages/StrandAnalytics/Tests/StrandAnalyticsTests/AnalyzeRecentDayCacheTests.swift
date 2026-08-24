import XCTest
@testable import StrandAnalytics

/// `AnalyzeRecentDayCache.cacheKey` — the per-day reuse identity for `analyzeRecent`'s pass-1 loop.
/// Oracle for the Android `AnalyzeRecentDayCacheTest`; keep the two in lockstep on the invalidation rules
/// (the exact key STRING may differ across platforms — the cache is in-memory and per-platform — but the
/// set of changes that must / must not invalidate a reused day is a shared contract).
final class AnalyzeRecentDayCacheTests: XCTestCase {
    // Unchanged inputs → identical key → the day is reused.
    func testStableInputsReuse() {
        let a = AnalyzeRecentDayCache.cacheKey(owner: "dev1", hrCount: 178_000, hrMaxTs: 1_700_000_000, skinAnchorRaw: 1290, hrvWindowDetail: false)
        let b = AnalyzeRecentDayCache.cacheKey(owner: "dev1", hrCount: 178_000, hrMaxTs: 1_700_000_000, skinAnchorRaw: 1290, hrvWindowDetail: false)
        XCTAssertEqual(a, b)
    }

    // A new HR row (count moves) OR a later newest-ts must invalidate — the day changed.
    func testHrChangeInvalidates() {
        let base = AnalyzeRecentDayCache.cacheKey(owner: "dev1", hrCount: 178_000, hrMaxTs: 1_700_000_000, skinAnchorRaw: 1290, hrvWindowDetail: false)
        let moreRows = AnalyzeRecentDayCache.cacheKey(owner: "dev1", hrCount: 178_001, hrMaxTs: 1_700_000_000, skinAnchorRaw: 1290, hrvWindowDetail: false)
        let laterTs = AnalyzeRecentDayCache.cacheKey(owner: "dev1", hrCount: 178_000, hrMaxTs: 1_700_000_060, skinAnchorRaw: 1290, hrvWindowDetail: false)
        XCTAssertNotEqual(base, moreRows)
        XCTAssertNotEqual(base, laterTs)
    }

    // A shifted window-wide skin anchor (another night's skin changed the 4.0 median) must invalidate even
    // when this night's HR fingerprint is identical — the skin conversion changed.
    func testAnchorShiftInvalidates() {
        let a = AnalyzeRecentDayCache.cacheKey(owner: "dev1", hrCount: 178_000, hrMaxTs: 1_700_000_000, skinAnchorRaw: 1290, hrvWindowDetail: false)
        let b = AnalyzeRecentDayCache.cacheKey(owner: "dev1", hrCount: 178_000, hrMaxTs: 1_700_000_000, skinAnchorRaw: 1290.5, hrvWindowDetail: false)
        XCTAssertNotEqual(a, b)
    }

    // A 5/MG night (no anchor) is a distinct, self-consistent key: nil reuses nil, and nil ≠ a real anchor
    // (so a 4.0 and a 5/MG night with the same fingerprint never alias to each other's scan).
    func testNilAnchorDistinctButStable() {
        let nilA = AnalyzeRecentDayCache.cacheKey(owner: "dev1", hrCount: 5_000, hrMaxTs: 1_700_000_000, skinAnchorRaw: nil, hrvWindowDetail: false)
        let nilB = AnalyzeRecentDayCache.cacheKey(owner: "dev1", hrCount: 5_000, hrMaxTs: 1_700_000_000, skinAnchorRaw: nil, hrvWindowDetail: false)
        let real = AnalyzeRecentDayCache.cacheKey(owner: "dev1", hrCount: 5_000, hrMaxTs: 1_700_000_000, skinAnchorRaw: 0, hrvWindowDetail: false)
        XCTAssertEqual(nilA, nilB)
        XCTAssertNotEqual(nilA, real)
    }

    // Multi-strap (4.0 + 5/MG): if a day's resolved owner flips between straps, the key must invalidate
    // EXPLICITLY — even in the astronomically-unlikely case that the two straps produced an identical
    // count+maxTs for the same window. The owner id is part of the key, so it never falsely reuses one
    // strap's scan for the other.
    func testDifferentOwnerInvalidates() {
        let whoop4 = AnalyzeRecentDayCache.cacheKey(owner: "whoop4-A", hrCount: 178_000, hrMaxTs: 1_700_000_000, skinAnchorRaw: 1290, hrvWindowDetail: false)
        let whoop5 = AnalyzeRecentDayCache.cacheKey(owner: "whoop5-B", hrCount: 178_000, hrMaxTs: 1_700_000_000, skinAnchorRaw: 1290, hrvWindowDetail: false)
        XCTAssertNotEqual(whoop4, whoop5)
    }

    /// #1575: the day that emits the per-window HRV DETAIL must not be reused as an ordinary night.
    ///
    /// An active trace no longer disables reuse, so the cached "today" carries a detailed HRV trace. After
    /// midnight that same night is an ordinary one and a fresh scan would emit only the one-line summary —
    /// replaying the detail would break the cache's whole promise, that a reused night is indistinguishable
    /// from a freshly-scored one. Folding the flag into the key costs one day's re-score per rollover, and
    /// only while a trace mode is on.
    ///
    /// Byte-parity twin of Kotlin `theHrvDetailDayIsNotReusedAsAnOrdinaryNight`.
    func testTheHrvDetailDayIsNotReusedAsAnOrdinaryNight() {
        let detail = AnalyzeRecentDayCache.cacheKey(owner: "dev1", hrCount: 178_000,
                                                    hrMaxTs: 1_700_000_000, skinAnchorRaw: 1290,
                                                    hrvWindowDetail: true)
        let summary = AnalyzeRecentDayCache.cacheKey(owner: "dev1", hrCount: 178_000,
                                                     hrMaxTs: 1_700_000_000, skinAnchorRaw: 1290,
                                                     hrvWindowDetail: false)
        XCTAssertNotEqual(detail, summary, "the detail day must invalidate when it stops being today")
    }
}
