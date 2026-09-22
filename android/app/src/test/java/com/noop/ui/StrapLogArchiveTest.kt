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
 * The two `oracle…` tests pin byte-identity with iOS: their expected text is the Swift archive's own output for the
 * same scenario (the Lift Log handbook's `tools/oracle` method — Strand/BLE/StrapLogArchive.swift compiled on its own
 * with a main that runs `scenario(budget:)` as below and prints `exportText()`), pasted verbatim, never hand-written.
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

    @Test
    fun oracleEveryRunKeptAsIOSRendersIt() {
        assertEquals(ORACLE_KEPT, scenario(budget = 4096))
    }

    @Test
    fun oracleOldestPrunedAndTheClippedRunSaysSoAsIOSRendersIt() {
        assertEquals(ORACLE_PRUNED, scenario(budget = 250))
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
    }
}
