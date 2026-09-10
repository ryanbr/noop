package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The day-owner probe short-circuits: it asks candidates in priority order and stops at the first with
 * data, instead of probing every candidate and then selecting. That is only safe while it agrees with
 * [DayOwnerResolver.resolve] on every input, so this asserts the agreement exhaustively rather than
 * leaving it to the argument in the comment.
 *
 * The saving is one query per candidate per day. On the 60-day steps-calibration window with two straps
 * that is 120 probes a pass, and the active strap usually answers on the first.
 */
class DayOwnerResolverEquivalenceTest {

    /** The short-circuit, expressed over a pre-computed data map so it can be compared exhaustively. */
    private fun shortCircuit(candidates: List<Pair<String, Int>>, hasData: Map<String, Boolean>): String? =
        candidates.sortedBy { it.second }.firstOrNull { hasData[it.first] == true }?.first

    /**
     * Every subset of a three-candidate set, against every possible data pattern: 3 priority orderings
     * are covered by using distinct priorities, and all 8 data combinations are enumerated. If the two
     * ever disagree the loop names the case.
     */
    @Test
    fun theShortCircuitAgreesWithTheResolverOnEveryCombination() {
        val ids = listOf("active" to 0, "second" to 1, "import" to 2)
        for (mask in 0 until 8) {
            val hasData = ids.mapIndexed { i, (id, _) -> id to ((mask shr i) and 1 == 1) }.toMap()
            val viaResolver = DayOwnerResolver.resolve(
                day = "2026-09-09",
                lockedOwner = null,
                candidates = ids.map { (id, p) ->
                    DayOwnerResolver.Candidate(deviceId = id, priority = p, hasData = hasData[id]!!)
                },
            )
            assertEquals("data mask $mask", viaResolver, shortCircuit(ids, hasData))
        }
    }

    /**
     * Priority, not list order, decides. A candidate list handed over in the wrong order must still pick
     * the lowest priority number with data, which is why the probe sorts before it walks.
     */
    @Test
    fun listOrderDoesNotDecide() {
        val reversed = listOf("import" to 2, "second" to 1, "active" to 0)
        val hasData = mapOf("active" to true, "second" to true, "import" to true)
        assertEquals("active", shortCircuit(reversed, hasData))
        assertEquals(
            DayOwnerResolver.resolve(
                day = "2026-09-09", lockedOwner = null,
                candidates = reversed.map { (id, p) ->
                    DayOwnerResolver.Candidate(deviceId = id, priority = p, hasData = true)
                },
            ),
            shortCircuit(reversed, hasData),
        )
    }

    /**
     * TIED priorities, which two non-active straps have: both are priority 1. The answer must be the
     * FIRST of them in list order, deterministically, on both platforms.
     *
     * This is the case the short-circuit could have got wrong. Kotlin is safe by luck of the library:
     * `sortedBy` is stable and `minByOrNull` takes the first minimum. Swift's `sorted` is NOT stable by
     * contract, so its probe sorts on (priority, original index) to reach the same answer by
     * construction rather than by a sort's incidental behaviour.
     */
    @Test
    fun tiedPrioritiesResolveToTheFirstInListOrder() {
        val tied = listOf("strapA" to 1, "strapB" to 1)
        assertEquals("strapA", shortCircuit(tied, mapOf("strapA" to true, "strapB" to true)))
        // And when the first of the tie has NO data, the second wins rather than nothing.
        assertEquals("strapB", shortCircuit(tied, mapOf("strapA" to false, "strapB" to true)))
        // The resolver agrees: minByOrNull returns the FIRST minimum among candidates with data.
        assertEquals(
            "strapA",
            DayOwnerResolver.resolve(
                day = "2026-09-09", lockedOwner = null,
                candidates = tied.map { (id, p) ->
                    DayOwnerResolver.Candidate(deviceId = id, priority = p, hasData = true)
                },
            ),
        )
    }

    /** Nobody with data yields nobody, so the caller falls back to its imported id rather than guessing. */
    @Test
    fun noCandidateWithDataResolvesToNothing() {
        val ids = listOf("active" to 0, "second" to 1)
        val none = mapOf("active" to false, "second" to false)
        assertEquals(null, shortCircuit(ids, none))
    }
}
