import XCTest
@testable import StrandAnalytics

final class SleepDebtTests: XCTestCase {

    // MARK: - Baseline shape (unchanged by the recency/cap/asymmetry model)

    /// Three nights exactly at need (8 h = 480 min) → zero balance, three counted nights.
    /// Every delta is 0, so decay/asymmetry/cap never engage: the model still reads 0.
    func testOnTargetNetsToZero() {
        let series: [(day: String, totalSleepMin: Double?)] = [
            ("2026-06-01", 480), ("2026-06-02", 480), ("2026-06-03", 480),
        ]
        let l = SleepDebt.ledger(series: series, needHours: 8.0)
        XCTAssertEqual(l.balanceMin, 0.0, accuracy: 1e-9)
        XCTAssertEqual(l.nightCount, 3)
        XCTAssertFalse(l.isDebt)
        XCTAssertEqual(l.needMin, 480.0, accuracy: 1e-9)
    }

    /// Nights with no usable sleep are skipped entirely (never zero-filled as debt). Two
    /// counted nights [480 (δ0), 420 (δ−60)]: the at-need night contributes 0, the deficit
    /// accrues fully with nothing before it to decay → balance −60.
    func testSkipsNoDataNights() {
        let series: [(day: String, totalSleepMin: Double?)] = [
            ("2026-06-01", 480),
            ("2026-06-02", nil),     // skipped
            ("2026-06-03", 0),       // skipped (non-positive)
            ("2026-06-04", 420),     // −60
        ]
        let l = SleepDebt.ledger(series: series, needHours: 8.0)
        XCTAssertEqual(l.nightCount, 2)
        XCTAssertEqual(l.balanceMin, -60.0, accuracy: 1e-9)
        XCTAssertEqual(l.nights.map { $0.day }, ["2026-06-01", "2026-06-04"])
        // The per-night deltas stay RAW (slept − need), so the diverging bars remain honest.
        XCTAssertEqual(l.nights.map { $0.deltaMin }, [0, -60])
    }

    /// Empty / all-skipped input → empty ledger, zero balance.
    func testEmptyLedger() {
        let l = SleepDebt.ledger(series: [], needHours: 8.0)
        XCTAssertEqual(l.balanceMin, 0.0, accuracy: 1e-9)
        XCTAssertEqual(l.nightCount, 0)
        XCTAssertTrue(l.nights.isEmpty)

        let allNil: [(day: String, totalSleepMin: Double?)] = [("2026-06-01", nil)]
        XCTAssertEqual(SleepDebt.ledger(series: allNil).nightCount, 0)
    }

    /// The default need is AnalyticsEngine.Rest.defaultNeedHours (8 h). One deficit night
    /// (420, δ−60) accrues fully → −60.
    func testDefaultNeedIsEightHours() {
        let l = SleepDebt.ledger(series: [("2026-06-01", 420)])
        XCTAssertEqual(l.needMin, AnalyticsEngine.Rest.defaultNeedHours * 60.0, accuracy: 1e-9)
        XCTAssertEqual(l.balanceMin, -60.0, accuracy: 1e-9)
    }

    /// Only the most-recent `window` COUNTED nights are in scope, and the per-night deltas
    /// stay raw. 16 uniform-deficit nights, window 14: the oldest two drop, 14 remain.
    func testWindowCapKeepsMostRecentNights() {
        let series: [(day: String, totalSleepMin: Double?)] = (1...16).map {
            (String(format: "2026-06-%02d", $0), Double(420))   // each δ −60
        }
        let l = SleepDebt.ledger(series: series, needHours: 8.0, window: 14)
        XCTAssertEqual(l.nightCount, 14)                    // window still caps the NIGHT count
        XCTAssertEqual(l.nights.first?.day, "2026-06-03")   // oldest kept
        XCTAssertEqual(l.nights.last?.day, "2026-06-16")    // newest kept
        // Balance is the decayed accumulation Σ −60·0.9^k, k=0…13 = −600·(1−0.9^14) ≈ −462.7,
        // NOT the flat 14×−60 = −840 the old symmetric sum reported (well under the cap).
        XCTAssertEqual(l.balanceMin, -462.7, accuracy: 0.05)
        XCTAssertGreaterThan(l.balanceMin, -840.0)          // strictly gentler than a flat sum
    }

    // MARK: - Recency weighting (recent deficits weigh more than old ones)

    /// The SAME single deficit night weighs more when it is RECENT than when it is OLD: a
    /// deficit on the newest night sits at full weight, one four at-need nights ago has
    /// decayed. Pins the EWMA recency-weighting.
    func testRecencyWeightsRecentDeficitMore() {
        let atNeed = 480.0, deficit = 360.0   // δ 0 and δ −120
        let recent: [(day: String, totalSleepMin: Double?)] = [
            ("2026-06-01", atNeed), ("2026-06-02", atNeed), ("2026-06-03", atNeed),
            ("2026-06-04", atNeed), ("2026-06-05", deficit),          // deficit NEWEST
        ]
        let old: [(day: String, totalSleepMin: Double?)] = [
            ("2026-06-01", deficit), ("2026-06-02", atNeed), ("2026-06-03", atNeed),
            ("2026-06-04", atNeed), ("2026-06-05", atNeed),           // deficit OLDEST
        ]
        let lRecent = SleepDebt.ledger(series: recent, needHours: 8.0)
        let lOld = SleepDebt.ledger(series: old, needHours: 8.0)
        XCTAssertEqual(lRecent.balanceMin, -120.0, accuracy: 1e-6)   // full weight
        XCTAssertEqual(lOld.balanceMin, -78.7, accuracy: 0.05)       // −120·0.9^4, decayed
        XCTAssertGreaterThan(lRecent.magnitudeMin, lOld.magnitudeMin)
        XCTAssertTrue(lRecent.isDebt && lOld.isDebt)
    }

    /// A single deficit fades as at-need nights pass — the debt decays over time even without
    /// any surplus to repay it (the "debt is not a permanent scar" asymmetry).
    func testDeficitDecaysAsAtNeedNightsPass() {
        let fresh = SleepDebt.ledger(series: [("2026-06-01", 360)], needHours: 8.0)
        let aged = SleepDebt.ledger(series: [
            ("2026-06-01", 360), ("2026-06-02", 480), ("2026-06-03", 480),
            ("2026-06-04", 480), ("2026-06-05", 480),
        ], needHours: 8.0)
        XCTAssertEqual(fresh.balanceMin, -120.0, accuracy: 1e-6)
        XCTAssertLessThan(aged.magnitudeMin, fresh.magnitudeMin)   // decayed toward zero
        XCTAssertTrue(aged.isDebt)                                 // but not yet cleared
    }

    // MARK: - Cap (debt can't grow to an absurd number)

    /// Sustained heavy deficits are bounded at `maxBalanceNights` × need — without the cap the
    /// decayed geometric series would still pile to ~10 nights' worth. 14 nights of a −420
    /// deficit clamp to exactly −1440 (3 × 480), not the ≈ −4000 the unclamped series implies.
    func testDebtIsCappedAtMaxNights() {
        let series: [(day: String, totalSleepMin: Double?)] = (1...14).map {
            (String(format: "2026-06-%02d", $0), Double(60))    // slept 1 h, δ −420
        }
        let l = SleepDebt.ledger(series: series, needHours: 8.0)
        let cap = SleepDebt.maxBalanceNights * l.needMin        // 3 × 480 = 1440
        XCTAssertEqual(l.balanceMin, -cap, accuracy: 1e-6)      // clamped to the floor
        XCTAssertLessThanOrEqual(l.magnitudeMin, cap + 1e-6)    // never exceeds the cap
        XCTAssertEqual(cap, 1440.0, accuracy: 1e-9)
    }

    /// A surplus is capped symmetrically at +cap so a long banked-sleep run can't read as an
    /// absurd credit either.
    func testSurplusIsCappedSymmetrically() {
        let series: [(day: String, totalSleepMin: Double?)] = (1...14).map {
            (String(format: "2026-06-%02d", $0), Double(900))   // slept 15 h, δ +420
        }
        let l = SleepDebt.ledger(series: series, needHours: 8.0)
        let cap = SleepDebt.maxBalanceNights * l.needMin
        XCTAssertLessThanOrEqual(l.magnitudeMin, cap + 1e-6)
        XCTAssertFalse(l.isDebt)
    }

    // MARK: - Asymmetry (a repay night moves the balance less than an equal deficit night)

    /// Accrual and repayment are NOT symmetric: an X-minute deficit night accrues the full X,
    /// but an X-minute surplus night repays only `surplusRepayFraction`·X. Pins the core
    /// asymmetry the ticket asks for.
    func testSurplusRepaysLessThanDeficitAccrues() {
        let deficit = SleepDebt.ledger(series: [("2026-06-01", 360)], needHours: 8.0)   // δ −120
        let surplus = SleepDebt.ledger(series: [("2026-06-01", 600)], needHours: 8.0)   // δ +120
        XCTAssertEqual(deficit.balanceMin, -120.0, accuracy: 1e-6)                       // full accrual
        XCTAssertEqual(surplus.balanceMin, 60.0, accuracy: 1e-6)                         // half repay (0.5·120)
        XCTAssertGreaterThan(deficit.magnitudeMin, surplus.magnitudeMin)                 // asymmetric
        XCTAssertEqual(surplus.magnitudeMin,
                       SleepDebt.surplusRepayFraction * deficit.magnitudeMin, accuracy: 1e-6)
        XCTAssertTrue(deficit.isDebt)
        XCTAssertFalse(surplus.isDebt)
        // The RAW per-night deltas are still symmetric (±120) — only the accumulation is asymmetric.
        XCTAssertEqual(deficit.nights.first?.deltaMin, -120.0)
        XCTAssertEqual(surplus.nights.first?.deltaMin, 120.0)
    }

    /// A surplus night dropped onto an existing debt repays less than a fresh deficit of equal
    /// size would deepen it — the asymmetry holds mid-ledger, not just from zero.
    func testSurplusOffsetsDeficitButNotFully() {
        // [360, 540, 420] need 8 h → deltas −120, +60, −60.
        //   n1: 0·0.9 + (−120)            = −120
        //   n2: −120·0.9 + (0.5·60)       = −108 + 30 = −78
        //   n3: −78·0.9 + (−60)           = −70.2 − 60 = −130.2
        let l = SleepDebt.ledger(series: [
            ("2026-06-01", 360), ("2026-06-02", 540), ("2026-06-03", 420),
        ], needHours: 8.0)
        XCTAssertEqual(l.balanceMin, -130.2, accuracy: 1e-6)
        XCTAssertTrue(l.isDebt)
        XCTAssertEqual(l.nights.map { $0.deltaMin }, [-120, 60, -60])   // raw deltas intact
    }

    // MARK: - Rounding parity (Kotlin mirror must match byte-for-byte)

    /// A deficit lands its raw delta on the ledger (no repay-halving), so a −0.05 tie rounds
    /// AWAY from zero to −0.1 through the full model path (need 8 h keeps the cap slack).
    func testNegativeHalfTieRoundsAwayFromZero() {
        let l = SleepDebt.ledger(series: [("2026-06-01", 479.95)], needHours: 8.0)   // δ ≈ −0.05
        XCTAssertEqual(l.balanceMin, -0.1, accuracy: 1e-9)
    }

    /// `round1` itself rounds half AWAY from zero for BOTH signs — the load-bearing contract the
    /// Kotlin mirror's sign-aware `round1` must match (Swift `.rounded()` is half-away-from-zero;
    /// Kotlin `roundToInt()` is half-toward-+∞, which diverged on negative ties, audit #6).
    func testRound1HalfTiesAwayFromZero() {
        XCTAssertEqual(SleepDebt.round1(-0.05), -0.1, accuracy: 1e-9)
        XCTAssertEqual(SleepDebt.round1(0.05), 0.1, accuracy: 1e-9)
        XCTAssertEqual(SleepDebt.round1(-0.04), 0.0, accuracy: 1e-9)
        XCTAssertEqual(SleepDebt.round1(-0.25), -0.3, accuracy: 1e-9)
    }
}
