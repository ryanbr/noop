package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.time.Instant

/**
 * The strap log on disk ([StrapLogArchive]), the twin of the Swift `StrapLogArchive`. What it must never do again is
 * what the SharedPreferences ring did: lose the lines logged just before a restart, a run's head beyond 1,000 lines,
 * and every run before the last three.
 *
 * The three `oracle…` tests pin byte-identity with iOS: their expected text is the Swift archive's own output for the
 * same scenario (the Lift Log handbook's `tools/oracle/strap-log` — Strand/BLE/StrapLogArchive.swift compiled on its
 * own with a main that runs the scenarios below and prints `exportText()`), pasted verbatim, never hand-written.
 */
class StrapLogArchiveTest {

    @get:Rule val folder = TemporaryFolder()

    private val t0Ms = 1_790_000_000_000L

    private fun process(dir: File, seconds: Long, budget: Long = StrapLogArchive.BUDGET_BYTES,
                        segment: Long = StrapLogArchive.SEGMENT_BYTES) =
        StrapLogArchive(dir, budget, segment, t0Ms + seconds * 1000)

    private fun iso(seconds: Long) = Instant.ofEpochSecond(t0Ms / 1000 + seconds).toString()

    /** The scenario the Swift oracle ran: the ring carried over, a short run, a 40-line run across segments of 100
     *  bytes, then the current run with one line. */
    private fun scenario(budget: Long): String {
        val dir = folder.newFolder()
        val first = process(dir, 0, budget, 100)
        first.importLegacy(StrapLogArchive.legacyRingLines(
            listOf(listOf("===== previous app session, 1 line(s), rolled at 2026-09-20T10:00:00Z (this launch) =====",
                          "ring run")),
            listOf("ring tail"), t0Ms))
        for (i in 1..3) first.append("first $i")
        val long = process(dir, 100, budget, 100)
        for (i in 1..40) long.append(String.format(java.util.Locale.US, "long %02d", i))
        val last = process(dir, 200, budget, 100)
        last.append("current 1")
        return last.exportText()
    }

    /** The locked-storage scenario the Swift oracle ran: nothing can be written (a phone before its first unlock),
     *  40 lines against a 250-byte budget, then storage opens and 64 more follow. */
    private fun lockedScenario(): Pair<String, String> {
        val dir = folder.newFolder()
        try {
            dir.setWritable(false)
            val locked = process(dir, 0, 250, 100)
            for (i in 1..40) locked.append(String.format(java.util.Locale.US, "locked %02d", i))
            val held = locked.exportText()
            dir.setWritable(true)
            for (i in 1..64) locked.append(String.format(java.util.Locale.US, "open %02d", i))
            return held to process(dir, 100, 250, 100).exportText()
        } finally {
            dir.setWritable(true)
        }
    }

    @Test
    fun oracleEveryRunKeptAsIOSRendersIt() {
        assertEquals(ORACLE_KEPT, scenario(budget = 4096))
    }

    @Test
    fun oracleOldestPrunedAndTheClippedRunSaysSoAsIOSRendersIt() {
        assertEquals(ORACLE_PRUNED, scenario(budget = 250))
    }

    @Test
    fun oracleLockedStorageAsIOSRendersIt() {
        val (held, after) = lockedScenario()
        assertEquals(ORACLE_LOCKED_HELD, held)
        assertEquals(ORACLE_LOCKED_AFTER, after)
    }

    /** Before the first unlock after a boot the files are refused, and that is when a restart after a reboot is
     *  logged. Those lines stay in memory past a segment boundary (#2386 review: they used to vanish there) and
     *  reach disk the moment a file opens, so a later restart keeps them too. */
    @Test
    fun linesThatCannotBeWrittenWaitAndReachDiskOnceStorageOpens() {
        val dir = folder.newFolder()
        try {
            dir.setWritable(false)
            val locked = process(dir, 0, segment = 200)
            val early = (1..100).map { String.format(java.util.Locale.US, "locked %03d", it) }
            early.forEach(locked::append)
            assertTrue("nothing can be written yet", dir.listFiles()!!.isEmpty())
            assertEquals(early.joinToString("\n"), locked.exportText())
            dir.setWritable(true)
            val later = (1..64).map { String.format(java.util.Locale.US, "unlocked %02d", it) }
            later.forEach(locked::append)
            assertEquals((early + later).joinToString("\n"), locked.exportText())
            assertEquals(
                "===== previous app session, 164 line(s), rolled at ${iso(10)} (this launch) =====\n" +
                    (early + later).joinToString("\n") + "\n===== current app session =====\n",
                process(dir, 10, segment = 200).exportText())
        } finally {
            dir.setWritable(true)
        }
    }

    /** While nothing can be written, memory holds the newest lines within the budget; once they reach disk the run
     *  says it lost its head. */
    @Test
    fun anUnwrittenBacklogStaysWithinTheBudgetAndSaysItsHeadWasClipped() {
        val dir = folder.newFolder()
        try {
            dir.setWritable(false)
            val locked = process(dir, 0, budget = 1_000, segment = 200)
            for (i in 1..200) locked.append(String.format(java.util.Locale.US, "locked %03d", i))
            val held = locked.exportText()
            assertTrue(held.toByteArray(Charsets.UTF_8).size <= 1_000)
            assertTrue("the newest line is kept", held.endsWith("locked 200"))
            assertFalse("the oldest line is the first to go", held.contains("locked 001"))
            dir.setWritable(true)
            for (i in 1..64) locked.append(String.format(java.util.Locale.US, "open %02d", i))
            assertTrue(process(dir, 10, budget = 1_000, segment = 200).exportText().contains("head clipped"))
        } finally {
            dir.setWritable(true)
        }
    }

    /** THE ONE THAT MATTERS: every line reaches disk as it is logged, so a process killed without warning (it is
     *  never closed here) leaves all of them for the next run's export — none held back for a batch. */
    @Test
    fun everyLineSurvivesARestartWithoutAClose() {
        val dir = folder.newFolder()
        val killed = process(dir, 0)
        listOf("20:34:01 double-tap", "20:34:02 buzz", "20:34:03 cpu").forEach(killed::append)

        val next = process(dir, 10)
        assertEquals(
            "===== previous app session, 3 line(s), rolled at ${iso(10)} (this launch) =====\n" +
                "20:34:01 double-tap\n20:34:02 buzz\n20:34:03 cpu\n===== current app session =====\n",
            next.exportText())
        next.append("20:34:12 restored")
        assertTrue(next.exportText().endsWith("===== current app session =====\n20:34:12 restored"))
    }

    /** A long run is split across files and exported whole, in order, even with an export in the middle. */
    @Test
    fun aLongRunIsSplitIntoSegmentsAndExportedWhole() {
        val dir = folder.newFolder()
        val archive = process(dir, 0, segment = 200)
        val lines = (1..100).map { String.format(java.util.Locale.US, "line %03d", it) }
        lines.forEachIndexed { i, line ->
            archive.append(line)
            if (i == 40) archive.exportText()
        }
        assertTrue("the run spans several segments", dir.listFiles()!!.size > 1)
        assertEquals(lines.joinToString("\n"), archive.exportText())
        assertEquals(lines, archive.exportLines())
    }

    /** Report tapped right after a restart, before the new process has logged a line, carries the run before it
     *  (#1263) — and the line form keeps the marker as its last line. */
    @Test
    fun anExportBeforeTheFirstLineCarriesTheRunBefore() {
        val dir = folder.newFolder()
        process(dir, 0).append("03:14 reconnect storm")
        val next = process(dir, 60)
        assertTrue(next.exportText().contains("03:14 reconnect storm"))
        assertTrue(next.exportText().endsWith("===== current app session =====\n"))
        assertEquals(StrapLogArchive.CURRENT_RUN_MARKER, next.exportLines().last())
    }

    @Test
    fun nothingLoggedExportsNothing() {
        assertEquals("", process(folder.newFolder(), 0).exportText())
    }

    /** The ring is carried over once: a second import never writes over it. */
    @Test
    fun theRingIsCarriedOverOnce() {
        val dir = folder.newFolder()
        process(dir, 0).importLegacy(listOf("ring line"))
        process(dir, 10).importLegacy(listOf("must not be written twice"))
        val text = process(dir, 20).exportText()
        assertTrue(text.startsWith("ring line\n"))
        assertFalse(text.contains("must not be written twice"))
    }

    private companion object {
        /** Swift oracle output, scenario(budget: 4096). */
        val ORACLE_KEPT = """===== previous app session, 1 line(s), rolled at 2026-09-20T10:00:00Z (this launch) =====
ring run
===== previous app session, 1 line(s), rolled at 2026-09-21T14:13:20Z (this launch) =====
ring tail
===== previous app session, 3 line(s), rolled at 2026-09-21T14:15:00Z (this launch) =====
first 1
first 2
first 3
===== previous app session, 40 line(s), rolled at 2026-09-21T14:16:40Z (this launch) =====
long 01
long 02
long 03
long 04
long 05
long 06
long 07
long 08
long 09
long 10
long 11
long 12
long 13
long 14
long 15
long 16
long 17
long 18
long 19
long 20
long 21
long 22
long 23
long 24
long 25
long 26
long 27
long 28
long 29
long 30
long 31
long 32
long 33
long 34
long 35
long 36
long 37
long 38
long 39
long 40
===== current app session =====
current 1"""

        /** Swift oracle output, scenario(budget: 250). */
        val ORACLE_PRUNED = """===== previous app session, 28 line(s), head clipped, rolled at 2026-09-21T14:16:40Z (this launch) =====
long 13
long 14
long 15
long 16
long 17
long 18
long 19
long 20
long 21
long 22
long 23
long 24
long 25
long 26
long 27
long 28
long 29
long 30
long 31
long 32
long 33
long 34
long 35
long 36
long 37
long 38
long 39
long 40
===== current app session =====
current 1"""

        /** Swift oracle output, lockedScenario(): what memory holds while storage is refused. */
        val ORACLE_LOCKED_HELD = """locked 16
locked 17
locked 18
locked 19
locked 20
locked 21
locked 22
locked 23
locked 24
locked 25
locked 26
locked 27
locked 28
locked 29
locked 30
locked 31
locked 32
locked 33
locked 34
locked 35
locked 36
locked 37
locked 38
locked 39
locked 40"""

        /** Swift oracle output, lockedScenario(): the next run's export once storage opened. */
        val ORACLE_LOCKED_AFTER = """===== previous app session, 34 line(s), head clipped, rolled at 2026-09-21T14:15:00Z (this launch) =====
open 31
open 32
open 33
open 34
open 35
open 36
open 37
open 38
open 39
open 40
open 41
open 42
open 43
open 44
open 45
open 46
open 47
open 48
open 49
open 50
open 51
open 52
open 53
open 54
open 55
open 56
open 57
open 58
open 59
open 60
open 61
open 62
open 63
open 64
===== current app session =====
"""
    }
}
