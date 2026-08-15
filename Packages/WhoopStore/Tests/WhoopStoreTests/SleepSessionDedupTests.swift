import XCTest
import WhoopStore

/// #899: an unstable strap clock re-banks the SAME night under a shifted timebase, so the store
/// accumulates two (or more) OVERLAPPING sleep sessions with different timestamps. The exact
/// (deviceId, startTs) primary-key upsert cannot catch them, day assignment then keys the stale
/// duplicate to the wrong day, and Charge/Rest pin to the old night. `SleepSessionDedup` is the
/// overlap-aware collapse applied before day assignment / scoring: overlapping copies of one night
/// resolve to a single canonical survivor, while genuinely distinct sessions (two real nights, a
/// nap grazing a night) are untouched.
final class SleepSessionDedupTests: XCTestCase {

    private func session(start: Int, end: Int, edited: Bool = false,
                         startAdjusted: Int? = nil) -> CachedSleepSession {
        CachedSleepSession(startTs: start, endTs: end, efficiency: nil,
                           restingHr: nil, avgHrv: nil, stagesJSON: nil,
                           userEdited: edited, startTsAdjusted: startAdjusted)
    }

    // Deterministic UTC end-day keyer, mirroring how callers assign a session to its wake day.
    private func endDay(_ s: CachedSleepSession) -> Int { s.endTs / 86_400 }

    /// A UTC midnight well inside a day so hour offsets stay on predictable day keys.
    private let midnight = 1_750_032_000   // divisible by 86_400

    // MARK: - Failing case (#899): shifted-timebase duplicates of one night

    func testShiftedTimebaseDuplicateCollapsesToOneSurvivorOnTheCorrectDay() {
        // The REAL night on the current (correct) timebase: 22:00 -> 06:00, wakes on day D.
        let fresh = session(start: midnight - 2 * 3600, end: midnight + 6 * 3600)
        // The SAME night banked earlier under a clock running 7 h behind: 15:00 -> 23:00,
        // so it ends on day D-1 and overlaps the real night by 1 h.
        let stale = session(start: midnight - 9 * 3600, end: midnight - 1 * 3600)

        let result = SleepSessionDedup.dedupe([stale, fresh],
                                              freshStarts: [fresh.startTs])
        XCTAssertEqual(result.kept.count, 1, "the shifted re-bank is the same night, one survivor")
        XCTAssertEqual(result.kept.first?.startTs, fresh.startTs, "the freshly-banked copy is canonical")
        XCTAssertEqual(result.dropped.map(\.startTs), [stale.startTs])
        // Day assignment: the survivor keys to the CORRECT wake day D, not the stale D-1.
        XCTAssertEqual(result.kept.first.map(endDay), endDay(fresh))
        XCTAssertNotEqual(result.kept.first.map(endDay), endDay(stale))
    }

    func testThreeShiftedCopiesCollapseToOneSurvivor() {
        // A wandering clock re-banks the night twice more, each copy shifted a few hours.
        let fresh  = session(start: midnight - 2 * 3600, end: midnight + 6 * 3600)
        let stale1 = session(start: midnight - 5 * 3600, end: midnight + 3 * 3600)
        let stale2 = session(start: midnight - 7 * 3600, end: midnight + 1 * 3600)
        let result = SleepSessionDedup.dedupe([stale2, fresh, stale1],
                                              freshStarts: [fresh.startTs])
        XCTAssertEqual(result.kept.map(\.startTs), [fresh.startTs])
        XCTAssertEqual(result.dropped.count, 2)
    }

    // MARK: - Non-overlap control: two real distinct nights both survive

    func testTwoDistinctNightsAreBothKept() {
        let nightA = session(start: midnight - 8 * 3600, end: midnight)                    // ends day D
        let nightB = session(start: midnight + 16 * 3600, end: midnight + 24 * 3600)      // ends day D+1
        let result = SleepSessionDedup.dedupe([nightA, nightB])
        XCTAssertEqual(result.kept.map(\.startTs), [nightA.startTs, nightB.startTs],
                       "disjoint real nights are never collapsed")
        XCTAssertTrue(result.dropped.isEmpty)
    }

    // MARK: - Nap-vs-night control: a short graze below both thresholds keeps both

    func testNapGrazingTheNightBelowThresholdIsKept() {
        // Main night ends at midnight; a 1 h nap starts 15 min before that wake (timebase jitter).
        // Overlap = 15 min: under the 30 min absolute bar AND under 50% of the 1 h nap.
        let night = session(start: midnight - 8 * 3600, end: midnight)
        let nap = session(start: midnight - 15 * 60, end: midnight + 45 * 60)
        let result = SleepSessionDedup.dedupe([night, nap])
        XCTAssertEqual(result.kept.count, 2, "a sub-threshold graze is not a duplicate")
        XCTAssertTrue(result.dropped.isEmpty)
    }

    // MARK: - Canonical-survivor rules

    func testFreshBankWinsOverALongerStaleDuplicate() {
        // Bank recency outranks length: the stale copy is LONGER (the old timebase caught a
        // phantom tail), but the freshly-banked detection is the current truth.
        let stale = session(start: midnight - 2 * 3600, end: midnight + 8 * 3600)   // 10 h
        let fresh = session(start: midnight - 1 * 3600, end: midnight + 6 * 3600)   // 7 h
        let result = SleepSessionDedup.dedupe([stale, fresh],
                                              freshStarts: [fresh.startTs])
        XCTAssertEqual(result.kept.map(\.startTs), [fresh.startTs])
    }

    func testWithoutBankRecencyTheLongerSessionWins() {
        // Read-side callers have no bank-recency witness: the longer capture of the night wins.
        let long  = session(start: midnight - 2 * 3600, end: midnight + 6 * 3600)   // 8 h
        let short = session(start: midnight - 1 * 3600, end: midnight + 4 * 3600)   // 5 h
        let result = SleepSessionDedup.dedupe([short, long])
        XCTAssertEqual(result.kept.map(\.startTs), [long.startTs])
    }

    func testUserEditedSessionIsNeverDropped() {
        // A hand-corrected night outranks everything, including a fresh re-detection.
        let edited = session(start: midnight - 8 * 3600, end: midnight, edited: true)
        let fresh = session(start: midnight - 7 * 3600, end: midnight + 1 * 3600)
        let result = SleepSessionDedup.dedupe([edited, fresh],
                                              freshStarts: [fresh.startTs])
        XCTAssertEqual(result.kept.map(\.startTs), [edited.startTs])
        XCTAssertEqual(result.dropped.map(\.startTs), [fresh.startTs])
    }

    func testOverlapUsesTheEditedEffectiveOnset() {
        // An edited onset moves the block's real span; the overlap test must honour it. The
        // detected key says 20:00 but the user corrected the onset to 02:00, so a stale copy
        // ending 01:30 no longer overlaps the edited block at all.
        let edited = session(start: midnight - 4 * 3600, end: midnight + 6 * 3600,
                             edited: true, startAdjusted: midnight + 2 * 3600)
        let earlier = session(start: midnight - 6 * 3600, end: midnight + 3600 + 1800)
        let result = SleepSessionDedup.dedupe([edited, earlier])
        XCTAssertEqual(result.kept.count, 2, "no overlap once the corrected onset applies")
    }

    func testEmptyAndSingleInputsPassThrough() {
        XCTAssertTrue(SleepSessionDedup.dedupe([]).kept.isEmpty)
        let one = session(start: midnight, end: midnight + 3600)
        XCTAssertEqual(SleepSessionDedup.dedupe([one]).kept.map(\.startTs), [one.startTs])
    }

    // MARK: - #1284 residual 3: a non-overlapping pre-onset fragment collapses; a real nap does not

    func testOura1284PreOnsetFragmentCollapsesDespiteNoOverlap() {
        // The anchored night 22:00 → 06:00, and the Oura SleepNet pre-onset fragment ending 69 s before
        // the night starts (measured on 08-10/11) — a 40 min piece with NO overlap with the night.
        let night = session(start: midnight - 2 * 3600, end: midnight + 6 * 3600)
        let fragEnd = (midnight - 2 * 3600) - 69
        let fragment = session(start: fragEnd - 40 * 60, end: fragEnd)
        XCTAssertTrue(SleepSessionDedup.isDuplicate(fragment, night), "a 69 s edge gap is one interrupted night")
        let result = SleepSessionDedup.dedupe([fragment, night], freshStarts: [night.startTs])
        XCTAssertEqual(result.kept.count, 1, "fragment + night collapse to one")
        XCTAssertEqual(result.kept.first?.startTs, night.startTs, "the fuller anchored night survives")
    }

    func testOura1284RealNapStaysSeparate() {
        // A genuine afternoon nap hours before the night is never near-adjacent.
        let nap = session(start: midnight - 9 * 3600, end: midnight - 8 * 3600)
        let night = session(start: midnight - 2 * 3600, end: midnight + 6 * 3600)
        XCTAssertFalse(SleepSessionDedup.isDuplicate(nap, night))
        XCTAssertEqual(SleepSessionDedup.dedupe([nap, night]).kept.count, 2)
    }

    func testOura1284GapBeyondNearAdjacentStaysSeparate() {
        // Two disjoint sessions 20 min apart (> the 15 min near-adjacent bar) are not merged.
        let a = session(start: midnight - 3 * 3600, end: midnight - 2 * 3600)
        let b = session(start: midnight - 2 * 3600 + 20 * 60, end: midnight + 4 * 3600)
        XCTAssertFalse(SleepSessionDedup.isDuplicate(a, b))
        XCTAssertEqual(SleepSessionDedup.dedupe([a, b]).kept.count, 2)
    }
}
