package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Kotlin parity for StrandAnalytics/SleepDebtTests.swift — same vectors, same results.
 *
 * Covers the recency-weighted, capped, asymmetric ledger (PR #464): each night's carried balance
 * decays by RECENCY_RETENTION, a deficit accrues in full while a surplus repays only
 * SURPLUS_REPAY_FRACTION of itself, and |balance| is clamped to MAX_BALANCE_NIGHTS × need. The raw
 * per-night deltas stay verbatim for the bars.
 */
class SleepDebtTest {

    // Baseline shape (unchanged by the recency/cap/asymmetry model) --------------------------------

    /** Three nights exactly at need (8 h = 480 min) → zero balance, three counted nights.
     *  Every delta is 0, so decay/asymmetry/cap never engage: the model still reads 0. */
    @Test
    fun onTarget_netsToZero() {
        val series = listOf(
            "2026-06-01" to 480.0, "2026-06-02" to 480.0, "2026-06-03" to 480.0,
        )
        val l = SleepDebt.ledger(series, needHours = 8.0)
        assertEquals(0.0, l.balanceMin, 1e-9)
        assertEquals(3, l.nightCount)
        assertFalse(l.isDebt)
        assertEquals(480.0, l.needMin, 1e-9)
    }

    /** Nights with no usable sleep are skipped entirely (never zero-filled as debt). Two counted
     *  nights [480 (δ0), 420 (δ−60)]: the at-need night contributes 0, the deficit accrues fully
     *  with nothing before it to decay → balance −60. */
    @Test
    fun skipsNoDataNights() {
        val series = listOf<Pair<String, Double?>>(
            "2026-06-01" to 480.0,
            "2026-06-02" to null,     // skipped
            "2026-06-03" to 0.0,      // skipped (non-positive)
            "2026-06-04" to 420.0,    // −60
        )
        val l = SleepDebt.ledger(series, needHours = 8.0)
        assertEquals(2, l.nightCount)
        assertEquals(-60.0, l.balanceMin, 1e-9)
        assertEquals(listOf("2026-06-01", "2026-06-04"), l.nights.map { it.day })
        // The per-night deltas stay RAW (slept − need), so the diverging bars remain honest.
        assertEquals(listOf(0.0, -60.0), l.nights.map { it.deltaMin })
    }

    /** Empty / all-skipped input → empty ledger, zero balance. */
    @Test
    fun emptyLedger() {
        val l = SleepDebt.ledger(emptyList(), needHours = 8.0)
        assertEquals(0.0, l.balanceMin, 1e-9)
        assertEquals(0, l.nightCount)
        assertTrue(l.nights.isEmpty())

        val allNull = listOf<Pair<String, Double?>>("2026-06-01" to null)
        assertEquals(0, SleepDebt.ledger(allNull).nightCount)
    }

    /** The default need is RestScorer.defaultSleepNeedHours (8 h). One deficit night (420, δ−60)
     *  accrues fully → −60. */
    @Test
    fun defaultNeed_isEightHours() {
        val l = SleepDebt.ledger(listOf("2026-06-01" to 420.0))
        assertEquals(RestScorer.defaultSleepNeedHours * 60.0, l.needMin, 1e-9)
        assertEquals(-60.0, l.balanceMin, 1e-9)
    }

    /** Only the most-recent `window` COUNTED nights are in scope, and the per-night deltas stay raw.
     *  16 uniform-deficit nights, window 14: the oldest two drop, 14 remain. */
    @Test
    fun windowCap_keepsMostRecentNights() {
        val series = (1..16).map { String.format("2026-06-%02d", it) to (420.0 as Double?) }   // each δ −60
        val l = SleepDebt.ledger(series, needHours = 8.0, window = 14)
        assertEquals(14, l.nightCount)                    // window still caps the NIGHT count
        assertEquals("2026-06-03", l.nights.first().day)  // oldest kept
        assertEquals("2026-06-16", l.nights.last().day)   // newest kept
        // Balance is the decayed accumulation Σ −60·0.9^k, k=0…13 = −600·(1−0.9^14) ≈ −462.7,
        // NOT the flat 14×−60 = −840 the old symmetric sum reported (well under the cap).
        assertEquals(-462.7, l.balanceMin, 0.05)
        assertTrue(l.balanceMin > -840.0)                 // strictly gentler than a flat sum
    }

    // Recency weighting (recent deficits weigh more than old ones) ---------------------------------

    /** The SAME single deficit night weighs more when it is RECENT than when it is OLD. Pins the
     *  EWMA recency-weighting. */
    @Test
    fun recencyWeightsRecentDeficitMore() {
        val atNeed = 480.0
        val deficit = 360.0   // δ 0 and δ −120
        val recent = listOf(
            "2026-06-01" to atNeed, "2026-06-02" to atNeed, "2026-06-03" to atNeed,
            "2026-06-04" to atNeed, "2026-06-05" to deficit,          // deficit NEWEST
        )
        val old = listOf(
            "2026-06-01" to deficit, "2026-06-02" to atNeed, "2026-06-03" to atNeed,
            "2026-06-04" to atNeed, "2026-06-05" to atNeed,           // deficit OLDEST
        )
        val lRecent = SleepDebt.ledger(recent, needHours = 8.0)
        val lOld = SleepDebt.ledger(old, needHours = 8.0)
        assertEquals(-120.0, lRecent.balanceMin, 1e-6)   // full weight
        assertEquals(-78.7, lOld.balanceMin, 0.05)       // −120·0.9^4, decayed
        assertTrue(lRecent.magnitudeMin > lOld.magnitudeMin)
        assertTrue(lRecent.isDebt && lOld.isDebt)
    }

    /** A single deficit fades as at-need nights pass — the debt decays over time even without any
     *  surplus to repay it (the "debt is not a permanent scar" asymmetry). */
    @Test
    fun deficitDecaysAsAtNeedNightsPass() {
        val fresh = SleepDebt.ledger(listOf("2026-06-01" to 360.0), needHours = 8.0)
        val aged = SleepDebt.ledger(
            listOf(
                "2026-06-01" to 360.0, "2026-06-02" to 480.0, "2026-06-03" to 480.0,
                "2026-06-04" to 480.0, "2026-06-05" to 480.0,
            ),
            needHours = 8.0,
        )
        assertEquals(-120.0, fresh.balanceMin, 1e-6)
        assertTrue(aged.magnitudeMin < fresh.magnitudeMin)   // decayed toward zero
        assertTrue(aged.isDebt)                              // but not yet cleared
    }

    // Cap (debt can't grow to an absurd number) ---------------------------------------------------

    /** Sustained heavy deficits are bounded at MAX_BALANCE_NIGHTS × need. 14 nights of a −420
     *  deficit clamp to exactly −1440 (3 × 480), not the ≈ −4000 the unclamped series implies. */
    @Test
    fun debtIsCappedAtMaxNights() {
        val series = (1..14).map { String.format("2026-06-%02d", it) to (60.0 as Double?) }   // slept 1 h, δ −420
        val l = SleepDebt.ledger(series, needHours = 8.0)
        val cap = SleepDebt.MAX_BALANCE_NIGHTS * l.needMin   // 3 × 480 = 1440
        assertEquals(-cap, l.balanceMin, 1e-6)               // clamped to the floor
        assertTrue(l.magnitudeMin <= cap + 1e-6)             // never exceeds the cap
        assertEquals(1440.0, cap, 1e-9)
    }

    /** A surplus is capped symmetrically at +cap so a long banked-sleep run can't read as an
     *  absurd credit either. */
    @Test
    fun surplusIsCappedSymmetrically() {
        val series = (1..14).map { String.format("2026-06-%02d", it) to (900.0 as Double?) }   // slept 15 h, δ +420
        val l = SleepDebt.ledger(series, needHours = 8.0)
        val cap = SleepDebt.MAX_BALANCE_NIGHTS * l.needMin
        assertTrue(l.magnitudeMin <= cap + 1e-6)
        assertFalse(l.isDebt)
    }

    // Asymmetry (a repay night moves the balance less than an equal deficit night) -----------------

    /** Accrual and repayment are NOT symmetric: an X-minute deficit night accrues the full X, but
     *  an X-minute surplus night repays only SURPLUS_REPAY_FRACTION·X. */
    @Test
    fun surplusRepaysLessThanDeficitAccrues() {
        val deficit = SleepDebt.ledger(listOf("2026-06-01" to 360.0), needHours = 8.0)   // δ −120
        val surplus = SleepDebt.ledger(listOf("2026-06-01" to 600.0), needHours = 8.0)   // δ +120
        assertEquals(-120.0, deficit.balanceMin, 1e-6)                                     // full accrual
        assertEquals(60.0, surplus.balanceMin, 1e-6)                                       // half repay (0.5·120)
        assertTrue(deficit.magnitudeMin > surplus.magnitudeMin)                            // asymmetric
        assertEquals(SleepDebt.SURPLUS_REPAY_FRACTION * deficit.magnitudeMin, surplus.magnitudeMin, 1e-6)
        assertTrue(deficit.isDebt)
        assertFalse(surplus.isDebt)
        // The RAW per-night deltas are still symmetric (±120) — only the accumulation is asymmetric.
        assertEquals(-120.0, deficit.nights.first().deltaMin, 1e-9)
        assertEquals(120.0, surplus.nights.first().deltaMin, 1e-9)
    }

    /** A surplus night dropped onto an existing debt repays less than a fresh deficit of equal size
     *  would deepen it — the asymmetry holds mid-ledger, not just from zero. */
    @Test
    fun surplusOffsetsDeficitButNotFully() {
        // [360, 540, 420] need 8 h → deltas −120, +60, −60.
        //   n1: 0·0.9 + (−120)            = −120
        //   n2: −120·0.9 + (0.5·60)       = −108 + 30 = −78
        //   n3: −78·0.9 + (−60)           = −70.2 − 60 = −130.2
        val l = SleepDebt.ledger(
            listOf("2026-06-01" to 360.0, "2026-06-02" to 540.0, "2026-06-03" to 420.0),
            needHours = 8.0,
        )
        assertEquals(-130.2, l.balanceMin, 1e-6)
        assertTrue(l.isDebt)
        assertEquals(listOf(-120.0, 60.0, -60.0), l.nights.map { it.deltaMin })   // raw deltas intact
    }

    // Rounding parity (Kotlin mirror must match byte-for-byte) -------------------------------------

    /** A deficit lands its raw delta on the ledger (no repay-halving), so a −0.05 tie rounds AWAY
     *  from zero to −0.1 through the full model path (need 8 h keeps the cap slack). */
    @Test
    fun negativeHalfTie_roundsAwayFromZero() {
        val l = SleepDebt.ledger(listOf("2026-06-01" to 479.95), needHours = 8.0)   // δ ≈ −0.05
        assertEquals(-0.1, l.balanceMin, 1e-9)
    }

    /** `round1` itself rounds half AWAY from zero for BOTH signs — the contract the sign-aware
     *  Kotlin `round1` must match (Swift `.rounded()` is half-away-from-zero; Kotlin `roundToInt()`
     *  is half-toward-+∞, which diverged on negative ties, audit #6). */
    @Test
    fun round1_halfTiesAwayFromZero() {
        assertEquals(-0.1, SleepDebt.round1(-0.05), 1e-9)
        assertEquals(0.1, SleepDebt.round1(0.05), 1e-9)
        assertEquals(0.0, SleepDebt.round1(-0.04), 1e-9)
        assertEquals(-0.3, SleepDebt.round1(-0.25), 1e-9)
    }
}
