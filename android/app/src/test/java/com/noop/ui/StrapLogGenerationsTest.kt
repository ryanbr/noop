package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the pure strap-log "generation ring" logic (#1263 item 2 — Android parity for the iOS
 * `LiveStateLogGenerationsTests`). The durable strap-log tail used to be lost entirely on process death:
 * a fresh process began logging and its own mirror overwrote the previous session's tail before anyone
 * could read it — so the lines that would explain an unexplained restart were destroyed BY the restart.
 * These guard the ring that rescues the surviving tail into a bounded set of previous generations.
 *
 * Pure JVM (no Android, no SharedPreferences), so it runs directly in the unit-test JVM — the ring MATH
 * lives in [StrapLogGenerations]; the persistence + once-per-process latch is the thin, untested
 * SharedPreferences wrapper in `WhoopBleClient` (the same split iOS has with UserDefaults).
 */
class StrapLogGenerationsTest {

    private val now = 1_700_000_000_000L

    /** THE ONE THAT MATTERS: a surviving tail is moved into a generation, keeping its own header. */
    @Test
    fun rollMovesTheSurvivingTailIntoAGeneration() {
        val gens = StrapLogGenerations.roll(
            listOf("22:01 connected", "22:02 drain done"), emptyList(), now,
        )
        assertEquals(1, gens.size)
        assertEquals(listOf("22:01 connected", "22:02 drain done"), gens[0].drop(1))
        assertTrue("generation must carry its own header", gens[0][0].contains("previous app session"))
        assertTrue("header must say it's this launch's roll", gens[0][0].contains("this launch"))
    }

    /**
     * Once-per-process, expressed purely: after a roll the wrapper CLEARS the live slot, so the next roll
     * sees an EMPTY tail and must push nothing — otherwise it would evict a real generation and mislabel
     * this process's own lines as a "previous" session.
     */
    @Test
    fun rollAfterClearedTailAddsNothing() {
        val first = StrapLogGenerations.roll(listOf("old line"), emptyList(), now)
        assertEquals(1, first.size)
        // The client clears the tail after a successful roll; a second roll therefore gets an empty tail.
        val second = StrapLogGenerations.roll(emptyList(), first, now)
        assertEquals("a cleared/empty tail must not push a second generation", 1, second.size)
        assertEquals(first, second)
    }

    /** A launch that logs nothing must not push an empty generation — that would evict a real one. */
    @Test
    fun emptyTailRollsNothing() {
        val gens = StrapLogGenerations.roll(emptyList(), emptyList(), now)
        assertEquals(0, gens.size)
    }

    /** The ring is bounded and drops the OLDEST, keeping the most recent restarts. */
    @Test
    fun ringKeepsTheMostRecentGenerations() {
        var gens: List<List<String>> = emptyList()
        for (i in 1..(StrapLogGenerations.MAX_GENERATIONS + 2)) {
            gens = StrapLogGenerations.roll(listOf("session $i"), gens, now)
        }
        assertEquals(StrapLogGenerations.MAX_GENERATIONS, gens.size)
        assertEquals("oldest generations are evicted first", "session 3", gens.first().drop(1).first())
        assertEquals("session ${StrapLogGenerations.MAX_GENERATIONS + 2}", gens.last().drop(1).first())
    }

    /** Each generation is clipped to its own cap, keeping the TAIL — what explains a stop is the END of the
     *  previous session, not its start — so the ring can't grow persistence without bound. */
    @Test
    fun generationIsClippedToItsTail() {
        val many = (0 until (StrapLogGenerations.GENERATION_TAIL_LIMIT + 50)).map { "line $it" }
        val gens = StrapLogGenerations.roll(many, emptyList(), now)
        val body = gens[0].drop(1)
        assertEquals(StrapLogGenerations.GENERATION_TAIL_LIMIT, body.size)
        assertEquals(
            "the newest line must survive",
            "line ${StrapLogGenerations.GENERATION_TAIL_LIMIT + 49}", body.last(),
        )
    }

    /** A clipped generation must SAY it lost its head, in the same words iOS uses — the header reported the
     *  pre-clip total, so a generation holding 1,000 of 2,000 lines announced "2000 line(s)" and read as a
     *  complete session, and the dropped head then measures as silence in the log tools. */
    @Test
    fun clippedGenerationHeaderSaysWhatWasKept() {
        val many = (0 until (StrapLogGenerations.GENERATION_TAIL_LIMIT + 50)).map { "line $it" }
        val header = StrapLogGenerations.roll(many, emptyList(), now)[0][0]
        assertTrue(
            "header must carry both the kept and the pre-clip count: $header",
            header.contains("${StrapLogGenerations.GENERATION_TAIL_LIMIT} of ${many.size} line(s)"),
        )
        assertTrue("a clipped generation must say so: $header", header.contains("head clipped"))
    }

    /** ...and an UNCLIPPED one must not cry wolf: no "clipped", just the count. */
    @Test
    fun unclippedGenerationHeaderClaimsNoLoss() {
        val header = StrapLogGenerations.roll(listOf("22:01 connected", "22:02 drain done"), emptyList(), now)[0][0]
        assertTrue(header, header.contains("2 line(s)"))
        assertTrue(header, !header.contains("clipped"))
    }

    /** The export puts previous sessions AHEAD of the current-session marker, so `report.txt` stays
     *  chronological and the log-parsing tools keep working on it unchanged. */
    @Test
    fun previousSessionsTextPrecedesTheCurrentMarker() {
        val gens = StrapLogGenerations.roll(listOf("last night 03:00 disconnected"), emptyList(), now)
        val text = StrapLogGenerations.previousSessionsText(gens)
        val prevIdx = text.indexOf("last night 03:00 disconnected")
        val curIdx = text.indexOf("current app session")
        assertTrue(prevIdx >= 0)
        assertTrue(curIdx >= 0)
        assertTrue("previous session must precede the current marker", prevIdx < curIdx)
    }

    /** Oldest-first across multiple generations, each keeping its own header block. */
    @Test
    fun previousSessionsTextIsOldestFirst() {
        var gens: List<List<String>> = emptyList()
        gens = StrapLogGenerations.roll(listOf("older session line"), gens, now)
        gens = StrapLogGenerations.roll(listOf("newer session line"), gens, now)
        val text = StrapLogGenerations.previousSessionsText(gens)
        assertTrue(text.indexOf("older session line") < text.indexOf("newer session line"))
    }

    @Test
    fun noGenerationsRendersNothing() {
        assertEquals("", StrapLogGenerations.previousSessionsText(emptyList()))
    }

    /**
     * #1468 follow-up: [StrapLogGenerations.previousSessionsText] must be a PURE function of its argument.
     *
     * `WhoopBleClient.exportLogText` memoises this half of the export for the process lifetime — safe only
     * because the generations are written exactly once (inside the latched roll) and this formatting reads
     * no clock and no other state. If someone later folds a timestamp or a live counter in here, the memo
     * would start serving a stale string and nothing else would notice: the strap log would simply stop
     * updating that section, which is far harder to spot than a crash.
     */
    @Test
    fun previousSessionsTextIsPureSoItCanBeMemoised() {
        val generations = listOf(
            listOf("===== session 2026-08-19 =====", "line a", "line b"),
            listOf("===== session 2026-08-20 =====", "line c"),
        )
        val first = StrapLogGenerations.previousSessionsText(generations)
        repeat(3) { assertEquals(first, StrapLogGenerations.previousSessionsText(generations)) }

        // A DIFFERENT input must still produce a different string — the equality above must come from
        // purity, not from the function ignoring its argument.
        assertNotEquals(first, StrapLogGenerations.previousSessionsText(generations.take(1)))
        assertEquals("", StrapLogGenerations.previousSessionsText(emptyList()))
    }

    /**
     * #1468 follow-up: the LINE form and the TEXT form of the previous-sessions block must describe the
     * same content.
     *
     * `WhoopBleClient.exportLogLines` builds its previous-session lines straight from the generations —
     * `gens.flatten() + CURRENT_SESSION_MARKER` — instead of formatting the string and splitting it back
     * apart. That shortcut is only valid while [previousSessionsText] renders exactly those lines in that
     * order. Reformatting it (an extra header, a blank line between generations, a different marker) would
     * make the two exports disagree, and nothing else would catch it: the share sheet would keep showing
     * the new shape while the live readouts kept filtering the old one.
     */
    @Test
    fun lineFormMatchesTheRenderedTextForm() {
        val generations = listOf(
            listOf("===== session 2026-08-19 =====", "line a", "line b"),
            listOf("===== session 2026-08-20 =====", "line c"),
        )
        val rendered = StrapLogGenerations.previousSessionsText(generations)
        // The rendered form ends in a newline, so splitting yields one trailing empty segment.
        val renderedLines = rendered.split("\n").dropLast(1)
        val lineForm = StrapLogGenerations.previousSessionsLines(generations)

        assertEquals(lineForm, renderedLines)
        assertEquals("", rendered.split("\n").last())
        // ...and the marker really is the last content line, not buried mid-block.
        assertEquals(StrapLogGenerations.CURRENT_SESSION_MARKER, renderedLines.last())
        // Empty generations render empty on both sides, so a caller can concatenate unconditionally.
        assertEquals("", StrapLogGenerations.previousSessionsText(emptyList()))
    }

    /**
     * The rendering must still match what `joinToString` produced before [previousSessionsText] was
     * rewritten to derive from [StrapLogGenerations.previousSessionsLines] — including for an EMPTY
     * generation, which renders as a blank line.
     *
     * This is the case that caught a real bug: the line form was first built with `flatten()`, which DROPS
     * an empty generation instead of rendering its blank line, so every line after it would have shifted in
     * one form but not the other. `roll` never stores an empty generation, but `persistedLogGenerations`
     * decodes an empty block to `emptyList()`, so the shape is representable.
     */
    @Test
    fun anEmptyGenerationRendersAsABlankLineInBothForms() {
        val generations = listOf(listOf("a"), emptyList(), listOf("b"))

        // The pre-rewrite expression, spelled out, as the reference.
        val legacy = generations.joinToString("\n") { it.joinToString("\n") } + "\n" +
            StrapLogGenerations.CURRENT_SESSION_MARKER + "\n"
        assertEquals(legacy, StrapLogGenerations.previousSessionsText(generations))

        assertEquals(
            listOf("a", "", "b", StrapLogGenerations.CURRENT_SESSION_MARKER),
            StrapLogGenerations.previousSessionsLines(generations),
        )
        // flatten() would have produced ["a", "b", MARKER] — one line short, and misaligned from here on.
        assertNotEquals(
            generations.flatten() + StrapLogGenerations.CURRENT_SESSION_MARKER,
            StrapLogGenerations.previousSessionsLines(generations),
        )
    }
}
