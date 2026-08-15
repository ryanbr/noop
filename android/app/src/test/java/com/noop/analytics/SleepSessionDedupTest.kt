package com.noop.analytics

import com.noop.data.SleepSession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #899: an unstable strap clock re-banks the SAME night under a shifted timebase, so the store
 * accumulates two (or more) OVERLAPPING sleep sessions with different timestamps. The exact
 * (deviceId, startTs) primary-key upsert cannot catch them, day assignment then keys the stale
 * duplicate to the wrong day, and Charge/Rest pin to the old night. [SleepSessionDedup] is the
 * overlap-aware collapse applied before day assignment / scoring: overlapping copies of one night
 * resolve to a single canonical survivor, while genuinely distinct sessions (two real nights, a nap
 * grazing a night) are untouched. Mirrors the Swift SleepSessionDedupTests case-for-case.
 */
class SleepSessionDedupTest {

    private fun session(start: Long, end: Long, edited: Boolean = false, startAdjusted: Long? = null) =
        SleepSession(deviceId = "my-whoop-noop", startTs = start, endTs = end,
            userEdited = edited, startTsAdjusted = startAdjusted)

    /** Deterministic UTC end-day keyer, mirroring how callers assign a session to its wake day. */
    private fun endDay(s: SleepSession): Long = s.endTs / 86_400L

    /** A UTC midnight well inside a day so hour offsets stay on predictable day keys. */
    private val midnight = 1_750_032_000L // divisible by 86_400

    // ── Failing case (#899): shifted-timebase duplicates of one night ────────────────────────────

    @Test
    fun shiftedTimebaseDuplicate_collapsesToOneSurvivorOnTheCorrectDay() {
        // The REAL night on the current (correct) timebase: 22:00 -> 06:00, wakes on day D.
        val fresh = session(midnight - 2 * 3600L, midnight + 6 * 3600L)
        // The SAME night banked earlier under a clock running 7 h behind: 15:00 -> 23:00, so it
        // ends on day D-1 and overlaps the real night by 1 h.
        val stale = session(midnight - 9 * 3600L, midnight - 1 * 3600L)

        val result = SleepSessionDedup.dedupe(listOf(stale, fresh), freshStarts = setOf(fresh.startTs))
        assertEquals("the shifted re-bank is the same night, one survivor", 1, result.kept.size)
        assertEquals("the freshly-banked copy is canonical", fresh.startTs, result.kept.first().startTs)
        assertEquals(listOf(stale.startTs), result.dropped.map { it.startTs })
        // Day assignment: the survivor keys to the CORRECT wake day D, not the stale D-1.
        assertEquals(endDay(fresh), endDay(result.kept.first()))
        assertNotEquals(endDay(stale), endDay(result.kept.first()))
    }

    @Test
    fun threeShiftedCopies_collapseToOneSurvivor() {
        // A wandering clock re-banks the night twice more, each copy shifted a few hours.
        val fresh = session(midnight - 2 * 3600L, midnight + 6 * 3600L)
        val stale1 = session(midnight - 5 * 3600L, midnight + 3 * 3600L)
        val stale2 = session(midnight - 7 * 3600L, midnight + 1 * 3600L)
        val result = SleepSessionDedup.dedupe(listOf(stale2, fresh, stale1),
            freshStarts = setOf(fresh.startTs))
        assertEquals(listOf(fresh.startTs), result.kept.map { it.startTs })
        assertEquals(2, result.dropped.size)
    }

    // ── Non-overlap control: two real distinct nights both survive ────────────────────────────────

    @Test
    fun twoDistinctNights_areBothKept() {
        val nightA = session(midnight - 8 * 3600L, midnight)                          // ends day D
        val nightB = session(midnight + 16 * 3600L, midnight + 24 * 3600L)            // ends day D+1
        val result = SleepSessionDedup.dedupe(listOf(nightA, nightB))
        assertEquals("disjoint real nights are never collapsed",
            listOf(nightA.startTs, nightB.startTs), result.kept.map { it.startTs })
        assertTrue(result.dropped.isEmpty())
    }

    // ── Nap-vs-night control: a short graze below both thresholds keeps both ─────────────────────

    @Test
    fun napGrazingTheNightBelowThreshold_isKept() {
        // Main night ends at midnight; a 1 h nap starts 15 min before that wake (timebase jitter).
        // Overlap = 15 min: under the 30 min absolute bar AND under 50% of the 1 h nap.
        val night = session(midnight - 8 * 3600L, midnight)
        val nap = session(midnight - 15 * 60L, midnight + 45 * 60L)
        val result = SleepSessionDedup.dedupe(listOf(night, nap))
        assertEquals("a sub-threshold graze is not a duplicate", 2, result.kept.size)
        assertTrue(result.dropped.isEmpty())
    }

    // ── Canonical-survivor rules ──────────────────────────────────────────────────────────────────

    @Test
    fun freshBank_winsOverALongerStaleDuplicate() {
        // Bank recency outranks length: the stale copy is LONGER (the old timebase caught a
        // phantom tail), but the freshly-banked detection is the current truth.
        val stale = session(midnight - 2 * 3600L, midnight + 8 * 3600L) // 10 h
        val fresh = session(midnight - 1 * 3600L, midnight + 6 * 3600L) // 7 h
        val result = SleepSessionDedup.dedupe(listOf(stale, fresh), freshStarts = setOf(fresh.startTs))
        assertEquals(listOf(fresh.startTs), result.kept.map { it.startTs })
    }

    @Test
    fun withoutBankRecency_theLongerSessionWins() {
        // Read-side callers have no bank-recency witness: the longer capture of the night wins.
        val long = session(midnight - 2 * 3600L, midnight + 6 * 3600L)  // 8 h
        val short = session(midnight - 1 * 3600L, midnight + 4 * 3600L) // 5 h
        val result = SleepSessionDedup.dedupe(listOf(short, long))
        assertEquals(listOf(long.startTs), result.kept.map { it.startTs })
    }

    @Test
    fun userEditedSession_isNeverDropped() {
        // A hand-corrected night outranks everything, including a fresh re-detection.
        val edited = session(midnight - 8 * 3600L, midnight, edited = true)
        val fresh = session(midnight - 7 * 3600L, midnight + 3600L)
        val result = SleepSessionDedup.dedupe(listOf(edited, fresh), freshStarts = setOf(fresh.startTs))
        assertEquals(listOf(edited.startTs), result.kept.map { it.startTs })
        assertEquals(listOf(fresh.startTs), result.dropped.map { it.startTs })
    }

    @Test
    fun overlapUsesTheEditedEffectiveOnset() {
        // An edited onset moves the block's real span; the overlap test must honour it. The
        // detected key says 20:00 but the user corrected the onset to 02:00, so a stale copy
        // ending 01:30 no longer overlaps the edited block at all.
        val edited = session(midnight - 4 * 3600L, midnight + 6 * 3600L,
            edited = true, startAdjusted = midnight + 2 * 3600L)
        val earlier = session(midnight - 6 * 3600L, midnight + 3600L + 1800L)
        val result = SleepSessionDedup.dedupe(listOf(edited, earlier))
        assertEquals("no overlap once the corrected onset applies", 2, result.kept.size)
    }

    @Test
    fun emptyAndSingleInputs_passThrough() {
        assertTrue(SleepSessionDedup.dedupe(emptyList()).kept.isEmpty())
        val one = session(midnight, midnight + 3600L)
        assertEquals(listOf(one.startTs), SleepSessionDedup.dedupe(listOf(one)).kept.map { it.startTs })
    }

    // ── #1284 residual 3: a non-overlapping pre-onset fragment collapses; a real nap does not ────────

    @Test
    fun oura1284_preOnsetFragment_collapsesDespiteNoOverlap() {
        // The anchored night 22:00 -> 06:00, and the Oura SleepNet pre-onset fragment ending 69 s before
        // the night starts (measured on 08-10/11) — a 40 min piece with NO overlap with the night.
        val night = session(midnight - 2 * 3600L, midnight + 6 * 3600L)
        val fragEnd = (midnight - 2 * 3600L) - 69L
        val fragment = session(fragEnd - 40 * 60L, fragEnd)
        assertTrue("a 69 s edge gap is one interrupted night", SleepSessionDedup.isDuplicate(fragment, night))
        val result = SleepSessionDedup.dedupe(listOf(fragment, night), freshStarts = setOf(night.startTs))
        assertEquals("fragment + night collapse to one", 1, result.kept.size)
        assertEquals("the fuller anchored night survives", night.startTs, result.kept.first().startTs)
    }

    @Test
    fun oura1284_realNap_staysSeparate() {
        // A genuine afternoon nap hours before the night is never near-adjacent.
        val nap = session(midnight - 9 * 3600L, midnight - 8 * 3600L)
        val night = session(midnight - 2 * 3600L, midnight + 6 * 3600L)
        assertTrue(!SleepSessionDedup.isDuplicate(nap, night))
        assertEquals(2, SleepSessionDedup.dedupe(listOf(nap, night)).kept.size)
    }

    @Test
    fun oura1284_gapBeyondNearAdjacent_staysSeparate() {
        // Two disjoint sessions 20 min apart (> the 15 min near-adjacent bar) are not merged.
        val a = session(midnight - 3 * 3600L, midnight - 2 * 3600L)
        val b = session(midnight - 2 * 3600L + 20 * 60L, midnight + 4 * 3600L)
        assertTrue(!SleepSessionDedup.isDuplicate(a, b))
        assertEquals(2, SleepSessionDedup.dedupe(listOf(a, b)).kept.size)
    }
}
