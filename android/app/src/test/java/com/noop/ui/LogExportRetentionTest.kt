package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure retention logic behind the scheduled debug export's "Clear scheduled exports" / keep-count
 * pruning (#642). Mirror of [BackupSyncTest]'s prune tests — same shape (stamp extraction, keep-N,
 * oldest-first) applied to the `noop-straplog-<stamp>.txt`/`.bin` pair instead of a `.noopbak` snapshot.
 */
class LogExportRetentionTest {

    @Test fun stampExtractedFromLogAndRawFilenames() {
        assertEquals("20260617-070000", LogExport.scheduledExportStamp("noop-straplog-20260617-070000.txt"))
        assertEquals("20260617-070000", LogExport.scheduledExportStamp("noop-straplog-20260617-070000.bin"))
    }

    @Test fun stampRejectsUnrelatedFilenames() {
        // Interactive-share files use a DIFFERENT prefix (no dash between "strap" and "log") so they
        // must never be treated as scheduled exports by the pruner or the manual clear action.
        assertNull(LogExport.scheduledExportStamp("noop-strap-log-260617-1042.txt"))
        assertNull(LogExport.scheduledExportStamp("noop-raw-capture-260617-1042.jsonl"))
        assertNull(LogExport.scheduledExportStamp("random.txt"))
        assertNull(LogExport.scheduledExportStamp("noop-straplog-20260617-070000.zip"))
    }

    @Test fun pruneKeepsNewestNGenerations() {
        // Five generations, each with a log+raw pair sharing one stamp — a pair must count as ONE
        // generation, not two, when measured against `keep`.
        val stamps = (0..4).map { "2026061%d-070000".format(it) }
        val names = stamps.flatMap { listOf("noop-straplog-$it.txt", "noop-straplog-$it.bin") }
        val pruned = LogExport.scheduledExportStampsToPrune(names, keep = 2)
        assertEquals(3, pruned.size)
        assertTrue(pruned.contains(stamps[0]))   // oldest generation pruned
        assertTrue(pruned.contains(stamps[1]))
        assertTrue(pruned.contains(stamps[2]))
        assertTrue(!pruned.contains(stamps[3]))  // two newest kept
        assertTrue(!pruned.contains(stamps[4]))
    }

    @Test fun pruneNoOpWithinBudget() {
        val names = listOf("noop-straplog-20260617-070000.txt", "noop-straplog-20260617-070000.bin")
        assertTrue(LogExport.scheduledExportStampsToPrune(names, keep = 10).isEmpty())
    }

    @Test fun pruneIgnoresUnrelatedFiles() {
        val names = listOf(
            "noop-straplog-20260610-070000.txt", "noop-straplog-20260610-070000.bin",
            "noop-straplog-20260617-070000.txt", "noop-straplog-20260617-070000.bin",
            "noop-strap-log-260617-1042.txt", // interactive share — never a prune candidate
        )
        val pruned = LogExport.scheduledExportStampsToPrune(names, keep = 1)
        assertEquals(setOf("20260610-070000"), pruned)
    }

    @Test fun defaultKeepIsTwoWeeks() {
        assertEquals(14, DebugExportSettings.DEFAULT_KEEP)
    }
}
