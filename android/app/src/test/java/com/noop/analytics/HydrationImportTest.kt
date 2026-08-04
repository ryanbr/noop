package com.noop.analytics

import com.noop.data.MetricSeriesRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #949 — water imported from the health store lives in its OWN series row, and these pin the two pure
 * pieces that make that safe. Both run on the JVM with no Room, matching the rest of the hydration suite.
 *
 * The reason imported water is a second row rather than being folded into the hand-logged total is that
 * the two behave differently on write: [HydrationStore.KEY] accumulates (each tap adds to it) while
 * [HydrationStore.KEY_IMPORTED] is REPLACED with the health store's recomputed day sum. Keeping them
 * apart is what lets a re-import be idempotent without tracking individual sample ids.
 */
class HydrationImportTest {

    // --- sumByDay: the history/total merge ---

    /**
     * The bug this exists to prevent: the merge used `associate { it.day to it.value }`, which keeps the
     * LAST row for a day. With a hand-logged row and an imported row on the same day, that silently drops
     * one of them — the history bars would disagree with the Today card for every imported day.
     */
    @Test
    fun rowsForTheSameDayAddRatherThanOverwrite() {
        val merged = HydrationStore.sumByDay(
            listOf(
                MetricSeriesRow(HydrationStore.SOURCE_ID, "2026-07-30", HydrationStore.KEY, 500.0),
                MetricSeriesRow(HydrationStore.SOURCE_ID, "2026-07-30", HydrationStore.KEY_IMPORTED, 750.0),
            ),
        )
        assertEquals(1250.0, merged["2026-07-30"]!!, 0.0)
    }

    @Test
    fun distinctDaysStaySeparate() {
        val merged = HydrationStore.sumByDay(
            listOf(
                MetricSeriesRow(HydrationStore.SOURCE_ID, "2026-07-29", HydrationStore.KEY, 200.0),
                MetricSeriesRow(HydrationStore.SOURCE_ID, "2026-07-30", HydrationStore.KEY, 300.0),
            ),
        )
        assertEquals(200.0, merged["2026-07-29"]!!, 0.0)
        assertEquals(300.0, merged["2026-07-30"]!!, 0.0)
    }

    @Test
    fun noRowsIsAnEmptyMapNotAZeroDay() {
        assertTrue(HydrationStore.sumByDay(emptyList()).isEmpty())
    }

    // --- importWindow: what an import writes ---

    /**
     * Days the health store had no water for are written as 0.0, NOT omitted. This is the self-healing
     * half of the design: if the user deletes a drink in the app that logged it, the next import writes
     * the lower figure — and if they delete every drink, it writes 0 instead of leaving yesterday's
     * number stranded in the row forever.
     */
    @Test
    fun daysWithNoWaterAreWrittenAsZero() {
        val window = listOf("2026-07-30", "2026-07-29", "2026-07-28")
        val out = HydrationStore.importWindow(window, mapOf("2026-07-29" to 900.0))
        assertEquals(setOf("2026-07-30", "2026-07-29", "2026-07-28"), out.keys)
        assertEquals(0.0, out["2026-07-30"]!!, 0.0)
        assertEquals(900.0, out["2026-07-29"]!!, 0.0)
        assertEquals(0.0, out["2026-07-28"]!!, 0.0)
    }

    /**
     * Re-running an import over the same day yields the same value — the property that makes it safe to
     * write this row wholesale instead of tracking which samples were already seen.
     */
    @Test
    fun reimportingTheSameDayIsIdempotent() {
        val window = listOf("2026-07-30")
        val found = mapOf("2026-07-30" to 1500.0)
        assertEquals(
            HydrationStore.importWindow(window, found),
            HydrationStore.importWindow(window, found),
        )
    }

    /**
     * A day outside the window is dropped rather than written. The importer only summed records inside
     * its time filter, so a day it half-looked-at cannot be trusted as a REPLACEMENT value — writing it
     * would overwrite a complete figure with a partial one.
     */
    @Test
    fun daysOutsideTheWindowAreNotWritten() {
        val out = HydrationStore.importWindow(listOf("2026-07-30"), mapOf("2020-01-01" to 400.0))
        assertEquals(setOf("2026-07-30"), out.keys)
        assertEquals(0.0, out["2026-07-30"]!!, 0.0)
    }

    /** A negative volume (a malformed record) can never produce a negative stored total. */
    @Test
    fun negativeVolumesClampToZero() {
        val out = HydrationStore.importWindow(listOf("2026-07-30"), mapOf("2026-07-30" to -50.0))
        assertEquals(0.0, out["2026-07-30"]!!, 0.0)
    }

    @Test
    fun anEmptyWindowWritesNothing() {
        assertTrue(HydrationStore.importWindow(emptyList(), mapOf("2026-07-30" to 400.0)).isEmpty())
    }

    // --- the parity contract ---

    /**
     * The series ids are a cross-platform contract: iOS writes the SAME strings from
     * `Strand/Data/HydrationStore.swift`. A rename on one platform alone would leave a restored backup
     * reading water out of a row nothing writes.
     */
    @Test
    fun seriesIdsMatchTheSwiftTwin() {
        assertEquals("hydration", HydrationStore.SOURCE_ID)
        assertEquals("hydration", HydrationStore.KEY)
        assertEquals("hydrationImported", HydrationStore.KEY_IMPORTED)
    }

    /** Imported water is a DIFFERENT row from hand-logged water, or the write semantics collide. */
    @Test
    fun importedKeyIsNotTheManualKey() {
        assertTrue(HydrationStore.KEY != HydrationStore.KEY_IMPORTED)
    }
}
