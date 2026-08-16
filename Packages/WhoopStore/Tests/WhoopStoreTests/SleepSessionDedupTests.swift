import XCTest
@testable import WhoopStore   // reaches the internal overlapSeconds / edgeGapSeconds helpers the #1284 tests assert on

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

    // MARK: - #1284 residual 3 (cont.): the overlap==0 cliff, and the adjacent-nap guard

    func testOura1284GrazingFragmentCollapsesAcrossTheOverlapSeam() {
        // 08-13/14: a 26 min re-decode fragment whose backward lay overshot the onset, so it GRAZES the
        // 390 min anchored night by 121 s. The old rule collapsed a fragment ending 69 s SHORT but not one
        // grazing 121 s IN — a discontinuity at overlap==0. The fragment (6.7% of the night) now collapses.
        let night = session(start: midnight, end: midnight + 390 * 60)
        let fragEnd = midnight + 121
        let fragment = session(start: fragEnd - 26 * 60, end: fragEnd)   // 26 min, 121 s into the night
        XCTAssertEqual(SleepSessionDedup.overlapSeconds(fragment, night), 121, "grazes by 121 s, not disjoint")
        XCTAssertTrue(SleepSessionDedup.isDuplicate(fragment, night),
                      "a short fragment grazing the night is one interrupted night, not a second sleep")
        let result = SleepSessionDedup.dedupe([fragment, night], freshStarts: [night.startTs])
        XCTAssertEqual(result.kept.map(\.startTs), [night.startTs], "the fuller anchored night survives")
    }

    func testOura1284AdjacentNapsOfComparableLengthAreKept() {
        // The guard against over-collapse: two GENUINE consecutive naps (20 min then 33 min, a 471 s gap,
        // seen in the oura-import corpus) are comparable in length — the shorter is 61% of the longer, far
        // above the fragment ratio — so they must NOT merge, even though the gap is within the near bar.
        let nap1 = session(start: midnight, end: midnight + 20 * 60)
        let nap2 = session(start: midnight + 20 * 60 + 471, end: midnight + 20 * 60 + 471 + 33 * 60)
        XCTAssertLessThanOrEqual(SleepSessionDedup.edgeGapSeconds(nap1, nap2), SleepSessionDedup.nearAdjacentSeconds,
                                 "the gap is within the near-adjacent bar — only the ratio keeps them apart")
        XCTAssertFalse(SleepSessionDedup.isDuplicate(nap1, nap2), "comparable-length naps are two sleeps, not a fragment")
        XCTAssertEqual(SleepSessionDedup.dedupe([nap1, nap2]).kept.count, 2)
    }

    func testOura1284MultiplePhantomFragmentsAllCollapseToTheNight() {
        // 08-14/15: one night re-decoded into several short phantom copies at drifting offsets. Every
        // phantom is a fragment of the night, so all collapse to it regardless of how they relate to EACH
        // other — closing the non-transitive, sort-order-dependent survivor set the cliff produced.
        let night = session(start: midnight, end: midnight + 390 * 60)
        let phantomA = session(start: midnight - 24 * 60, end: midnight + 2 * 60)   // grazes in by 2 min
        let phantomB = session(start: midnight + 12 * 60, end: midnight + 38 * 60)  // fully inside the head
        let phantomC = session(start: midnight + 27 * 60, end: midnight + 53 * 60)  // fully inside the head
        for order in [[night, phantomA, phantomB, phantomC], [phantomC, phantomA, night, phantomB]] {
            let result = SleepSessionDedup.dedupe(order, freshStarts: [night.startTs])
            XCTAssertEqual(result.kept.map(\.startTs), [night.startTs],
                           "the night is the sole survivor whatever the input order")
        }
    }

    // MARK: - #1284 residual 3: survivor selection (mode-2 partial drain · mode-1 identical re-anchors)

    func testOura1284PartialDrainKeepsTheFullerOverlappingDecode() {
        // Mode 2 (08-13/14): two OVERLAPPING decodes of one night at different completeness — a full 494 min
        // decode and a 234 min partial from an earlier burst (nested inside it). Both are the same night; the
        // FULLER one must survive (rank rule 3, longest duration) so a partial re-drain never clobbers a
        // complete night. This is the "completeness adjudication" the generation-side keying will lean on.
        let full = session(start: midnight, end: midnight + 494 * 60)
        let partial = session(start: midnight + 242, end: midnight + 242 + 234 * 60)   // nested in `full`
        XCTAssertTrue(SleepSessionDedup.isDuplicate(full, partial))
        let result = SleepSessionDedup.dedupe([partial, full])   // no freshStarts → longest-wins decides
        XCTAssertEqual(result.kept.map(\.startTs), [full.startTs], "the fuller decode of the night survives")
        XCTAssertEqual(result.dropped.map(\.startTs), [partial.startTs])
    }

    // MARK: - #1284 residual 3: generation-side onset keying (keyedStart · planBank)

    func testKeyedStartCollapsesOnsetJitterToOneBucket() {
        // 08-16: the 0x49 onset jittered 21 s across 11 re-serves. Rounded to the 60 s key they share a
        // startTs, so the (deviceId, startTs) PK collapses the re-serves instead of minting a row per drain.
        let a = SleepSessionDedup.keyedStart(onsetUnixSeconds: midnight + 55)
        let b = SleepSessionDedup.keyedStart(onsetUnixSeconds: midnight + 76)   // +21 s
        XCTAssertEqual(a, b, "onsets within the jitter round to one key")
        XCTAssertEqual(a % SleepSessionDedup.onsetKeyGridSeconds, 0, "the key lands on the grid")
    }

    func testPlanBankSupersedesAShorterStoredCopy() {
        // The candidate is the fuller 494 min decode; a 234 min partial is already stored → bank + retire it.
        let candidate = session(start: midnight, end: midnight + 494 * 60)
        let stored = session(start: midnight + 60, end: midnight + 60 + 234 * 60)
        let plan = SleepSessionDedup.planBank(candidate: candidate, existing: [stored])
        XCTAssertTrue(plan.bank)
        XCTAssertEqual(plan.supersededStarts, [stored.startTs])
    }

    func testPlanBankSuppressesAPartialAgainstAFullerStoredNight() {
        // Mode-2 in reverse: a partial re-drain arrives after the full night is banked → suppress it.
        let stored = session(start: midnight, end: midnight + 494 * 60)
        let candidate = session(start: midnight + 60, end: midnight + 60 + 234 * 60)
        let plan = SleepSessionDedup.planBank(candidate: candidate, existing: [stored])
        XCTAssertFalse(plan.bank)
        XCTAssertTrue(plan.supersededStarts.isEmpty)
    }

    func testPlanBankLaterWakingReAnchorSupersedesTheEarlier() {
        // Mode-1 re-serve: same duration, later end (end chases wall-clock). The later copy wins and retires
        // the earlier — the table converges to the latest-waking (WHOOP-matching) row.
        let stored = session(start: midnight, end: midnight + 368 * 60)
        let candidate = session(start: midnight + 15 * 60, end: midnight + 15 * 60 + 368 * 60)
        let plan = SleepSessionDedup.planBank(candidate: candidate, existing: [stored])
        XCTAssertTrue(plan.bank)
        XCTAssertEqual(plan.supersededStarts, [stored.startTs])
    }

    func testPlanBankFreshNightWithNoStoredMatchBanksClean() {
        let candidate = session(start: midnight, end: midnight + 400 * 60)
        let lastNight = session(start: midnight - 24 * 3600, end: midnight - 16 * 3600)
        let plan = SleepSessionDedup.planBank(candidate: candidate, existing: [lastNight])
        XCTAssertTrue(plan.bank)
        XCTAssertTrue(plan.supersededStarts.isEmpty)
    }

    func testPlanBankIdenticalReserveIsANoOp() {
        // An exact re-serve keeps the stored row (idempotent), never churns the PK.
        let stored = session(start: midnight, end: midnight + 400 * 60)
        let candidate = session(start: midnight, end: midnight + 400 * 60)
        XCTAssertFalse(SleepSessionDedup.planBank(candidate: candidate, existing: [stored]).bank)
    }

    func testKeyedStartRoundsHalfUpAndClampsGrid() {
        XCTAssertEqual(SleepSessionDedup.keyedStart(onsetUnixSeconds: 1000, gridSeconds: 60), 1020)  // nearest 60
        XCTAssertEqual(SleepSessionDedup.keyedStart(onsetUnixSeconds: 990, gridSeconds: 60), 1020)   // +30 rounds up
        XCTAssertEqual(SleepSessionDedup.keyedStart(onsetUnixSeconds: 989, gridSeconds: 60), 960)    // just under → down
        XCTAssertEqual(SleepSessionDedup.keyedStart(onsetUnixSeconds: 1234, gridSeconds: 0), 1234)   // grid clamp ≥1 = identity
    }

    func testPlanBankSameBucketFullerStoredRowSuppressesAPartialReserve() {
        // F1 regression: a partial re-drain keyed to the SAME bucket (same PK) as a fuller banked night must
        // be SUPPRESSED — the upsert would otherwise replace the fuller night's stages by PK. `existing` is
        // the UNFILTERED stored set, so the same-PK row is weighed here.
        let fuller = session(start: midnight, end: midnight + 494 * 60)
        let partial = session(start: midnight, end: midnight + 234 * 60)   // re-drain at the SAME keyed startTs
        XCTAssertFalse(SleepSessionDedup.planBank(candidate: partial, existing: [fuller]).bank,
                       "a partial never overwrites a fuller row at the same keyed PK")
    }

    func testPlanBankSameBucketFullerCandidateBanksWithoutSelfDeleting() {
        // The candidate is fuller than the stored row at its OWN key → bank (the upsert replaces that row in
        // place); it must NOT list its own startTs to delete (that would delete the row it just banked).
        let stored = session(start: midnight, end: midnight + 234 * 60)
        let candidate = session(start: midnight, end: midnight + 494 * 60)   // fuller, same key
        let plan = SleepSessionDedup.planBank(candidate: candidate, existing: [stored])
        XCTAssertTrue(plan.bank)
        XCTAssertTrue(plan.supersededStarts.isEmpty, "the same-PK row is replaced by the upsert, never deleted")
    }

    func testPlanBankSupersedesOtherKeyRowsButNotItsOwn() {
        // Fuller than BOTH a same-key partial and an earlier different-key fragment: bank, delete only the
        // different-key one (the same-key row is replaced in place by the upsert).
        let candidate = session(start: midnight, end: midnight + 494 * 60)
        let sameKeyPartial = session(start: midnight, end: midnight + 200 * 60)
        let otherKeyFrag = session(start: midnight - 120, end: midnight - 120 + 180 * 60)
        let plan = SleepSessionDedup.planBank(candidate: candidate, existing: [sameKeyPartial, otherKeyFrag])
        XCTAssertTrue(plan.bank)
        XCTAssertEqual(plan.supersededStarts, [otherKeyFrag.startTs])
    }

    func testPlanBankNeverClobbersAUserEditedNight() {
        // Data safety: a hand-corrected night outranks any fresh ring persist (userEdited is rank rule 1),
        // even a FULLER one — so the candidate is suppressed and the edited row is never replaced OR deleted.
        let edited = session(start: midnight, end: midnight + 400 * 60, edited: true)
        let candidate = session(start: midnight + 30, end: midnight + 30 + 420 * 60)   // fuller re-detect
        let plan = SleepSessionDedup.planBank(candidate: candidate, existing: [edited])
        XCTAssertFalse(plan.bank, "a fresh persist never overwrites a hand-corrected night")
        XCTAssertTrue(plan.supersededStarts.isEmpty, "the edited row is never deleted")
    }

    func testOura1284IdenticalReAnchorsResolveByLatestEnd() {
        // Mode 1 (08-16): one rigid block re-anchored at several onsets — same duration, same shape, only the
        // END chases wall-clock. Duration can't adjudicate (all equal), so the tie-break (latest endTs) picks
        // the row whose wake edge is latest — the one that matched WHOOP's wake on the day it was measured.
        // Pins that load-bearing order so a future change never retunes the survivor away from ground truth.
        let r1 = session(start: midnight, end: midnight + 368 * 60)
        let r2 = session(start: midnight + 15 * 60, end: midnight + 15 * 60 + 368 * 60)
        let r3 = session(start: midnight + 30 * 60, end: midnight + 30 * 60 + 368 * 60)   // latest end
        let result = SleepSessionDedup.dedupe([r2, r3, r1])
        XCTAssertEqual(result.kept.map(\.startTs), [r3.startTs],
                       "among equal-length re-anchors, the latest-waking row wins")
        XCTAssertEqual(result.dropped.count, 2)
    }
}
