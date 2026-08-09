package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * HIGH-2 READ-SPINE UNION (#814 parity, Android twin of the Swift ReadSpineActiveDeviceTests):
 *
 * After a remove+re-add the strap gets a FRESH registry id ("whoop-<uuid>") and the Collector writes LIVE
 * raw under THAT id, but the WHOOP-export IMPORT path ([com.noop.ingest.WhoopCsvImporter.importZip]) keeps
 * writing under the CANONICAL "my-whoop" (its `deviceId` arg defaults to "my-whoop" and is never
 * overridden), and the computed history derived from that import lives under "my-whoop-noop". So the
 * dashboard read must resolve the UNION of (active id) AND the canonical "my-whoop"/"my-whoop-noop", or the
 * entire import is ORPHANED after a re-add.
 *
 * These exercise the PURE companion seams the merged reads ([daysMerged] / [recentDaysMergedFlow] /
 * [FusionDayAdapter]) are built on, so they run on the JVM with no Room:
 *   - [WhoopRepository.importedSourceIdsFor] / [WhoopRepository.computedSourceIdsFor] give the union ids;
 *   - [WhoopRepository.unionByDay] is the per-day active-wins de-dupe;
 *   - [WhoopRepository.mergeDaily] is the imports-win-over-computed cross-bucket merge.
 */
class ReadSpineUnionTest {

    private val canonical = "my-whoop"
    private val reAdded = "whoop-ABC123" // the id a re-added strap gets (whoop-<uuid>)

    private fun row(day: String, source: String, asleep: Double? = null, recovery: Double? = null) =
        DailyMetric(deviceId = source, day = day, totalSleepMin = asleep, recovery = recovery)

    /** A single-WHOOP install (active id still "my-whoop") resolves to the canonical id ONLY (one source
     *  per bucket), so every merged read is byte-identical to the pre-#814 behaviour. */
    @Test
    fun singleWhoopInstallResolvesToCanonicalIdOnly() {
        assertEquals(listOf("my-whoop"), WhoopRepository.importedSourceIdsFor(canonical))
        assertEquals(listOf("my-whoop-noop"), WhoopRepository.computedSourceIdsFor(canonical))
    }

    /** After a re-add the union is (active id, canonical), active FIRST so a per-day pick takes the
     *  active/live row; the computed ids mirror it ("<id>-noop"). */
    @Test
    fun reAddResolvesToActiveUnionCanonicalActiveFirst() {
        assertEquals(listOf(reAdded, "my-whoop"), WhoopRepository.importedSourceIdsFor(reAdded))
        assertEquals(listOf("$reAdded-noop", "my-whoop-noop"), WhoopRepository.computedSourceIdsFor(reAdded))
    }

    /** The core regression: imported history written under the CANONICAL id must still surface after a
     *  re-add. Before the union the dashboard read only the active id (empty) and the whole import vanished. */
    @Test
    fun canonicalImportHistorySurvivesAfterReAdd() {
        // The WHOOP CSV import sits under the canonical id; the re-added strap's imported id has nothing yet.
        val canonicalImport = listOf(
            row("2026-06-10", canonical, asleep = 460.0, recovery = 55.0),
            row("2026-06-11", canonical, asleep = 470.0, recovery = 60.0),
        )
        val activeImport = emptyList<DailyMetric>() // imports never drift to the active id

        val importedUnion = WhoopRepository.unionByDay(
            WhoopRepository.importedSourceIdsFor(reAdded).map { id ->
                (canonicalImport + activeImport).filter { it.deviceId == id }
            },
        )
        val merged = WhoopRepository.mergeDaily(imported = importedUnion, computed = emptyList())

        assertEquals(
            "both imported days must survive the re-add, not be orphaned",
            listOf("2026-06-10", "2026-06-11"), merged.map { it.day },
        )
        assertEquals(460.0, merged.first { it.day == "2026-06-10" }.totalSleepMin)
    }

    /** Per-day precedence: when BOTH the active (live/measured) id and the canonical (imported) id cover the
     *  SAME day, the active row WINS the day (no double-count). [unionByDay] is active-first putIfAbsent. */
    @Test
    fun activeLiveRowWinsADayBothIdsCover() {
        // Same day under both ids: the re-added strap recorded a live night (480), the canonical import has
        // an older value (399) for the same day.
        val day = "2026-06-12"
        val active = row(day, reAdded, asleep = 480.0)
        val canonicalDup = row(day, canonical, asleep = 399.0)

        // Lists in precedence order (active first), exactly as importedSourceIdsFor orders them.
        val union = WhoopRepository.unionByDay(listOf(listOf(active), listOf(canonicalDup)))

        assertEquals("the day is not double-counted", 1, union.count { it.day == day })
        assertEquals("the active/live row wins the day", 480.0, union.first { it.day == day }.totalSleepMin)
    }

    /** Union across days: a day only the canonical import has AND a day only the active strap has BOTH
     *  surface (the union is additive across days, deduped only within a day). */
    @Test
    fun unionIsAdditiveAcrossDistinctDays() {
        val active = listOf(row("2026-06-13", reAdded, asleep = 500.0))
        val canonicalOnly = listOf(row("2026-06-09", canonical, asleep = 440.0))
        val union = WhoopRepository.unionByDay(listOf(active, canonicalOnly))
        // mergeDaily re-sorts oldest-first downstream; here assert the day SET is the union.
        assertTrue(union.map { it.day }.toSet() == setOf("2026-06-09", "2026-06-13"))
    }

    /** #-: a day two straps in the bucket both cover is coalesced per COLUMN, not taken whole — a hollow
     *  winner (steps and nothing else) keeps every column the other strap's fully-scored row carries,
     *  instead of the old whole-row first-wins that discarded it. Ported from tanarchytan/noop @de370b85. */
    @Test
    fun aHollowWinningRowKeepsTheOtherStrapsColumns() {
        val day = "2026-07-29"
        val active = DailyMetric(deviceId = "$reAdded-noop", day = day, steps = 10_775)
        val other = DailyMetric(
            deviceId = "$canonical-noop", day = day,
            totalSleepMin = 435.0, efficiency = 91.0, deepMin = 96.0, remMin = 110.0, lightMin = 229.0,
            recovery = 93.2, restingHr = 64, avgHrv = 37.06, strain = 8.4,
        )
        val merged = WhoopRepository.unionByDay(listOf(listOf(active), listOf(other))).single()
        assertEquals("the winner's identity is kept", "$reAdded-noop", merged.deviceId)
        assertEquals("the winner's own steps survive", 10_775, merged.steps)
        assertEquals(435.0, merged.totalSleepMin)
        assertEquals(96.0, merged.deepMin)
        assertEquals(93.2, merged.recovery)
        assertEquals(64, merged.restingHr)
        assertEquals(37.06, merged.avgHrv)
        assertEquals(8.4, merged.strain)
    }

    /** A measured zero is a READING, not an absence: a hollow-looking 0 steps / 0 strain / 0 HRV on the
     *  winner is kept ("carries" is non-null), never overwritten by the other strap's value. */
    @Test
    fun aMeasuredZeroIsAValueNotAnAbsence() {
        val day = "2026-07-29"
        val active = DailyMetric(deviceId = reAdded, day = day, steps = 0, strain = 0.0, avgHrv = 0.0)
        val other = DailyMetric(deviceId = canonical, day = day, steps = 9_120, strain = 14.7, avgHrv = 42.0)
        val merged = WhoopRepository.unionByDay(listOf(listOf(active), listOf(other))).single()
        assertEquals("zero steps is a reading", 0, merged.steps)
        assertEquals("zero strain is a reading", 0.0, merged.strain)
        assertEquals("zero HRV is a reading", 0.0, merged.avgHrv)
    }

    /** The sleep block moves as a GROUP from one row: a winner that carries a sleep total keeps its OWN
     *  (null) stages rather than borrowing the other strap's — a total never sits beside foreign stages. */
    @Test
    fun aSleepBlockIsNeverAssembledFromTwoStraps() {
        val day = "2026-07-29"
        val active = DailyMetric(deviceId = reAdded, day = day, totalSleepMin = 402.0)
        val other = DailyMetric(
            deviceId = canonical, day = day,
            totalSleepMin = 435.0, deepMin = 96.0, remMin = 110.0, lightMin = 229.0,
        )
        val merged = WhoopRepository.unionByDay(listOf(listOf(active), listOf(other))).single()
        assertEquals("the winner's total stands", 402.0, merged.totalSleepMin)
        assertNull("stages must not be borrowed from the other strap", merged.deepMin)
        assertNull(merged.remMin)
        assertNull(merged.lightMin)
    }
}
