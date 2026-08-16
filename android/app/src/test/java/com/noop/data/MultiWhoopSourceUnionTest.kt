package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * #1304 / #512-class: the read-path resolvers that every multi-WHOOP-safe read threads. A user's SECOND
 * strap banks its data under a fresh id ("whoop-<uuid>"), while the canonical import bucket stays
 * "my-whoop". The union-aware repo methods (`sleepSessionsUnion`, `habitualMidsleepSec`, `daysMerged`,
 * `recentDaysMergedFlow`, `rrIntervals`, …) resolve their read ids through [WhoopRepository.importedSourceIdsFor]
 * / [WhoopRepository.computedSourceIdsFor].
 *
 * The trap this pins (the bug fixed across CoupledScreen / TodayScreen hero+battery / AiCoach /
 * WhoopConnectionService): passing the LITERAL "my-whoop" into a union-aware method collapses the union
 * to the canonical id alone and RE-DROPS the 2nd strap. Callers must pass the ACTIVE strap id instead —
 * which is exactly what these assertions lock. Pure companion functions, no DB (twin of
 * [WorkoutHrDeviceKeyTest]).
 */
class MultiWhoopSourceUnionTest {

    private val second = "whoop-aabbcc"   // a 2nd strap's live id

    @Test fun `a 2nd strap's active id unions active first then canonical`() {
        assertEquals(listOf(second, "my-whoop"), WhoopRepository.importedSourceIdsFor(second))
        assertEquals(
            listOf("$second-noop", "my-whoop-noop"),
            WhoopRepository.computedSourceIdsFor(second),
        )
    }

    @Test fun `the canonical literal collapses to a single id -- the caller bug this fixes`() {
        // Passing "my-whoop" (what the fixed callers used to hardcode) yields ONLY the canonical bucket,
        // so a union-aware method fed this literal never reads the 2nd strap. This is why callers must
        // thread the active strap id, not the literal.
        assertEquals(listOf("my-whoop"), WhoopRepository.importedSourceIdsFor("my-whoop"))
        assertEquals(listOf("my-whoop-noop"), WhoopRepository.computedSourceIdsFor("my-whoop"))
    }

    @Test fun `an import-only install is byte-identical whichever way it is threaded`() {
        // Single-WHOOP / import-only users have activeStrapId == "my-whoop", so the fix is a no-op for them.
        assertEquals(
            WhoopRepository.importedSourceIdsFor("my-whoop"),
            WhoopRepository.importedSourceIdsFor(WhoopRepository.WHOOP_SOURCE),
        )
    }
}
