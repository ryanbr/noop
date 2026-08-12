package com.noop.ui

import org.junit.Assert.assertEquals
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
}
