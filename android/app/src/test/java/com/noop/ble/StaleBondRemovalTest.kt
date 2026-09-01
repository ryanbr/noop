package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1635: when NOOP may delete a pairing from the user's phone.
 *
 * Every clause is a separate way to get this wrong, and getting it wrong means removing a working
 * pairing rather than a stale one — so each is pinned on its own rather than trusting one happy path.
 */
class StaleBondRemovalTest {

    private fun ok(
        optedIn: Boolean = true,
        isWhoop5: Boolean = true,
        osBonded: Boolean = true,
        failures: Int = STALE_BOND_REMOVAL_THRESHOLD,
        already: Boolean = false,
    ) = shouldRemoveStaleBond(optedIn, isWhoop5, osBonded, failures, already)

    @Test
    fun `the streak at threshold, opted in, on a bonded 5MG, clears the pairing`() {
        assertTrue(ok())
    }

    @Test
    fun `no switch, no bond removal - deleting a pairing never rides in on other consent`() {
        assertFalse(ok(optedIn = false))
        // ...not even far past the threshold.
        assertFalse(ok(optedIn = false, failures = 500))
    }

    @Test
    fun `a WHOOP 4 is never touched - it bonds by the route it always has`() {
        assertFalse(ok(isWhoop5 = false))
    }

    @Test
    fun `nothing to remove when the OS holds no bond`() {
        assertFalse(ok(osBonded = false))
    }

    @Test
    fun `one drop is a transient, not a stale pairing`() {
        for (n in 0 until STALE_BOND_REMOVAL_THRESHOLD) {
            assertFalse("failures=$n must not remove", ok(failures = n))
        }
        assertTrue(ok(failures = STALE_BOND_REMOVAL_THRESHOLD))
    }

    @Test
    fun `exactly once per streak - a second failure does not delete a second pairing`() {
        assertFalse(ok(already = true))
        assertFalse(ok(already = true, failures = 500))
    }

    @Test
    fun `it waits longer than the guide, which asks the user first`() {
        // The re-pair guide appears at 2. Acting before the user has had cycles to act themselves would
        // take the choice away from them; this is what happens when asking did not work.
        assertTrue(STALE_BOND_REMOVAL_THRESHOLD > 2)
    }

    @Test
    fun `the line separates asking from happening, and carries no PII`() {
        val accepted = staleBondRemovalLine(5, accepted = true)
        val refused = staleBondRemovalLine(5, accepted = false)
        assertTrue(accepted.contains("Android accepted"))
        assertTrue(refused.contains("REFUSED"))
        assertTrue("a refusal must say nothing changed", refused.contains("Nothing has changed"))
        assertEquals(2, listOf(accepted, refused).count { it.contains("5 failed") })
        // A bare ":" is prose punctuation here, so match the SHAPE of a MAC rather than the character.
        val macLike = Regex("[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}")
        for (line in listOf(accepted, refused)) {
            assertFalse("no MAC in a shared log: $line", macLike.containsMatchIn(line))
            assertFalse("no serial prefix", line.contains("MGB"))
        }
    }
}
