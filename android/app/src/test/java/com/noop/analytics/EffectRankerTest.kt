package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * Faithful Kotlin port of
 * Packages/StrandAnalytics/Tests/StrandAnalyticsTests/EffectRankerTests.swift.
 * Same fixtures, same numbers — cross-platform parity is the contract.
 */
class EffectRankerTest {

    private fun ymd(y: Int, m: Int, d: Int): String = "%04d-%02d-%02d".format(y, m, d)

    private fun row(rows: List<RankedEffect>, behavior: String): RankedEffect? =
        rows.firstOrNull { it.behavior == behavior }

    /** Deterministic per-calendar-day jitter in {-2,-1,0,1,2}, mirroring the Swift fixture, so
     *  with/without groups carry real spread (a constant group yields pooled SD 0 / d 0). */
    private fun jitter(dayOfMonth: Int): Double = ((dayOfMonth * 7) % 5 - 2).toDouble()

    /** Every outcome day the behaviour was not logged on. These fixtures predate the Yes/No split and
     *  test the LAG math, so they keep their original partition by declaring the complement explicitly —
     *  the engine no longer assumes it, and a test that quietly lost its control group would still pass
     *  by returning nothing. */
    private fun controlsFor(outcome: Map<String, Double>, behaviorDays: Set<String>): Set<String> =
        outcome.keys - behaviorDays

    /** Test-only: the BehaviorEffect at a specific lag, via the engine's own shift alignment. */
    private fun effectAtLag(behaviorDays: Set<String>, outcome: Map<String, Double>, lag: Int) =
        EffectRanker.effect(
            behaviorDays, controlsFor(outcome, behaviorDays),
            EffectRanker.shiftedOutcome(outcome, lag), "Alcohol", "Charge",
        )

    // Planted lag-1 effect is found at L=1 and beats L=0/L=2

    @Test
    fun plantedLag1IsFoundAndWins() {
        val outcome = HashMap<String, Double>()
        val behaviorDays = HashSet<String>()

        // Anchors Jun 1,5,9,13,17,21 (6, spaced 4 apart).
        for (i in 0 until 6) behaviorDays.add(ymd(2026, 6, 1 + 4 * i))
        for (d in 1..30) outcome[ymd(2026, 6, d)] = 70.0 + jitter(d)
        for (d in 1..8) outcome[ymd(2026, 7, d)] = 70.0 + jitter(d)
        for (i in 0 until 6) {
            val dip = 2 + 4 * i
            outcome[ymd(2026, 6, dip)] = 50.0 + jitter(dip)
        }

        val out = EffectRanker.rank(
            mapOf("Alcohol" to behaviorDays), mapOf("Alcohol" to controlsFor(outcome, behaviorDays)),
            outcome, "Charge",
        )
        val r = row(out, "Alcohol")
        assertNotNull(r)
        assertEquals(1, r!!.lag)
        assertEquals("next morning", r.leadLagText)
        assertTrue(r.effect.cohensD < 0)
        assertTrue(r.effect.significant)
        assertTrue(r.effect.meanWith < 55)
        assertTrue(r.effect.meanWithout > 65)

        val d1 = abs(r.effect.cohensD)
        val d0 = abs(effectAtLag(behaviorDays, outcome, 0)!!.cohensD)
        val d2 = abs(effectAtLag(behaviorDays, outcome, 2)!!.cohensD)
        assertTrue(d1 > d0)
        assertTrue(d1 > d2)
    }

    // Group gate suppresses thin behaviours

    @Test
    fun thinBehaviourIsDropped() {
        val outcome = HashMap<String, Double>()
        val thin = HashSet<String>()
        for (d in 1..3) {
            val day = ymd(2026, 6, d)
            thin.add(day)
            outcome[day] = 50.0 + jitter(d)
            outcome[ymd(2026, 6, d + 1)] = 50.0 + jitter(d + 1)
        }
        for (d in 1..8) outcome[ymd(2026, 7, d)] = 70.0 + jitter(d)

        val out = EffectRanker.rank(
            mapOf("Sparse" to thin), mapOf("Sparse" to controlsFor(outcome, thin)), outcome, "Charge",
        )
        assertTrue(out.isEmpty())
    }

    // Ranking order matches BehaviorInsights.rank

    @Test
    fun rankingOrder() {
        val outcome = HashMap<String, Double>()
        val big = HashSet<String>()
        for (d in 1..6) {
            val day = ymd(2026, 1, d)
            big.add(day)
            outcome[day] = 50.0 + jitter(d)
        }
        val small = HashSet<String>()
        for (d in 1..6) {
            val day = ymd(2026, 3, d)
            small.add(day)
            outcome[day] = 66.0 + jitter(d)
        }
        for (d in 10..20) outcome[ymd(2026, 5, d)] = 70.0 + jitter(d)

        val out = EffectRanker.rank(
            mapOf("Big" to big, "Small" to small),
            mapOf("Big" to controlsFor(outcome, big), "Small" to controlsFor(outcome, small)),
            outcome, "Charge",
        )
        assertEquals(listOf("Big", "Small"), out.map { it.behavior })
        assertEquals(0, row(out, "Big")!!.lag)
        assertEquals(0, row(out, "Small")!!.lag)
    }

    // Confidence tiers from paired-day count

    @Test
    fun confidenceTiers() {
        assertEquals(ScoreConfidence.CALIBRATING, EffectRanker.confidence(4))
        assertEquals(ScoreConfidence.BUILDING, EffectRanker.confidence(5))
        assertEquals(ScoreConfidence.BUILDING, EffectRanker.confidence(9))
        assertEquals(ScoreConfidence.SOLID, EffectRanker.confidence(10))
    }

    // shiftedOutcome alignment

    @Test
    fun shiftedOutcomeAlignment() {
        val outcome = mapOf(ymd(2026, 6, 2) to 55.0, ymd(2026, 6, 3) to 60.0)
        assertEquals(outcome, EffectRanker.shiftedOutcome(outcome, 0))
        val s1 = EffectRanker.shiftedOutcome(outcome, 1)
        assertEquals(55.0, s1[ymd(2026, 6, 1)])
        assertEquals(60.0, s1[ymd(2026, 6, 2)])
        assertNull(s1[ymd(2026, 6, 3)])
    }

    // sentence appends the lead/lag clause

    @Test
    fun sentenceAppendsLeadLag() {
        val e = BehaviorEffect(
            behavior = "Alcohol", outcome = "Charge",
            meanWith = 50.0, meanWithout = 70.0, delta = -20.0,
            pctChange = -100.0 * 20.0 / 70.0, nWith = 6, nWithout = 8,
            cohensD = -2.0, pApprox = 0.001, significant = true,
        )
        val r = RankedEffect("Alcohol", "Charge", 1, e, ScoreConfidence.BUILDING)
        assertTrue(r.sentence().endsWith("(next morning)."))
    }
    // The Reddit report: unlogged days are not answers.

    /**
     * "If I didn't track something for 100 days, NOOP takes that as a NO for 100 days, whereas it simply
     * was not logged at all." Reported by a user on Reddit, and it was exactly what the split did.
     *
     * The fixture is that report: 8 days logged Yes with a real dip, 6 days logged No, and 60 days with
     * an outcome and no journal row at all. Those 60 must not reach the control group, because nothing
     * about them says the user did not do the thing.
     */
    @Test
    fun daysWithNoJournalRowAreNotControls() {
        val outcome = HashMap<String, Double>()
        val yes = HashSet<String>()
        val no = HashSet<String>()
        for (d in 1..8) { yes.add(ymd(2026, 6, d)); outcome[ymd(2026, 6, d)] = 50.0 + jitter(d) }
        for (d in 9..14) { no.add(ymd(2026, 6, d)); outcome[ymd(2026, 6, d)] = 70.0 + jitter(d) }
        // Never opened the journal on these, and their values sit far from BOTH answered groups.
        for (d in 15..30) outcome[ymd(2026, 6, d)] = 20.0 + jitter(d)
        for (d in 1..31) outcome[ymd(2026, 7, d)] = 20.0 + jitter(d)
        for (d in 1..13) outcome[ymd(2026, 8, d)] = 20.0 + jitter(d)

        val e = EffectRanker.effect(yes, no, outcome, "Alcohol", "Charge")
        assertNotNull(e)
        // Controls are the six NO days only. If the 60 unlogged days leaked in, nWithout would be 66 and
        // meanWithout would be dragged towards 20.
        assertEquals(6, e!!.nWithout)
        assertEquals(8, e.nWith)
        assertTrue("controls must average near the NO days, not the unlogged ones", e.meanWithout > 60.0)
    }

    /**
     * A behaviour the user only ever ticks Yes has no control group, so there is no comparison to make
     * and the honest answer is none. Previously it got one, built from every day the journal was never
     * opened - the most confident-looking findings in the app came from the least evidence.
     */
    @Test
    fun aBehaviourNeverLoggedNoYieldsNothing() {
        val outcome = HashMap<String, Double>()
        val yes = HashSet<String>()
        for (d in 1..20) { yes.add(ymd(2026, 6, d)); outcome[ymd(2026, 6, d)] = 50.0 + jitter(d) }
        for (d in 21..30) outcome[ymd(2026, 6, d)] = 80.0 + jitter(d)

        assertNull(EffectRanker.effect(yes, emptySet(), outcome, "Alcohol", "Charge"))
        assertTrue(
            EffectRanker.rank(mapOf("Alcohol" to yes), emptyMap(), outcome, "Charge").isEmpty(),
        )
    }

    /**
     * rank() fails CLOSED on a caller that forgets the controls: no insight, rather than a wrong one
     * measured against every day the user never opened the journal. There are two production callers and
     * this is what stops a third from reintroducing the bug silently.
     */
    @Test
    fun rankWithoutControlsProducesNothingRatherThanGuessing() {
        val outcome = HashMap<String, Double>()
        val yes = HashSet<String>()
        for (d in 1..10) { yes.add(ymd(2026, 6, d)); outcome[ymd(2026, 6, d)] = 50.0 + jitter(d) }
        for (d in 11..30) outcome[ymd(2026, 6, d)] = 75.0 + jitter(d)
        assertTrue(EffectRanker.rank(mapOf("Alcohol" to yes), emptyMap(), outcome, "Charge").isEmpty())
    }

}
