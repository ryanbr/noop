package com.noop.ui

import com.noop.data.SleepSession
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.TimeZone

/**
 * #736 (Android twin of SleepOnsetStubTests.swift): the Sleep tab must not draw the night's hypnogram /
 * bedtime from a spurious BRIEF, sleepless pre-onset awake stub that the gap-bridge folded into the
 * main-night group. [isPreOnsetAwakeStub] is the rule that lets [selectNight] skip such a leading stub so
 * the chart and minutes start at the displayed bedtime (the main block's onset), the same fragment the
 * pencil edits. A genuine first sleep fragment of a biphasic night is NEVER mistaken for a stub (#555).
 */
class SleepOnsetStubTest {

    // The selectNight goldens below use fixed unix timestamps, but the scorer's cold-start alignment
    // bonus reads the MACHINE timezone (uiTzOffsetSec()): on a UTC+7 host fragment B's 02:46 UTC
    // midpoint lands outside the bonus window and fragment A outscores it, flipping the pick. Pin UTC
    // like the other selectNight tests (ConsistencyNightSpansTest et al.) so the goldens are
    // machine-independent.
    private val saved: TimeZone = TimeZone.getDefault()

    @Before fun setUtc() { TimeZone.setDefault(TimeZone.getTimeZone("UTC")) }

    @After fun restore() { TimeZone.setDefault(saved) }

    private fun block(startTs: Long, endTs: Long, stagesJSON: String?): SleepSession =
        SleepSession(deviceId = "dev", startTs = startTs, endTs = endTs, stagesJSON = stagesJSON)

    /** A brief, all-awake leading block (15 min, 0 asleep) IS a spurious pre-onset stub. */
    @Test
    fun briefAllAwakeIsStub() {
        val b = block(0, 15 * 60, """{"awake":15,"light":0,"deep":0,"rem":0}""")
        assertTrue(isPreOnsetAwakeStub(b))
    }

    /** A short block that already holds real sleep (12 min span, 8 asleep) is NOT a stub. */
    @Test
    fun shortButAsleepIsNotStub() {
        val b = block(0, 12 * 60, """{"awake":4,"light":8,"deep":0,"rem":0}""")
        assertFalse(isPreOnsetAwakeStub(b))
    }

    /** THE #736 SHAPE: a LONG all-awake pre-sleep block (the reporter's 21:41-00:27, ~2h45m, 0 asleep) IS a
     *  stub. A multi-hour lie-in before sleep is not part of the night, so it drops off the displayed bedtime. */
    @Test
    fun longAllAwakePreSleepBlockIsStub() {
        val b = block(0, 165 * 60, """{"awake":165,"light":0,"deep":0,"rem":0}""")
        assertTrue(isPreOnsetAwakeStub(b))
    }

    /** A truly absurd all-day awake block (beyond the cap) is NOT silently swallowed. */
    @Test
    fun beyondCapIsNotStub() {
        val b = block(0, 300 * 60, """{"awake":300,"light":0,"deep":0,"rem":0}""")
        assertFalse(isPreOnsetAwakeStub(b))
    }

    /** A block with no parseable stages but within the cap still reads as a (sleepless) stub. */
    @Test
    fun shortWithNoStagesIsStub() {
        val b = block(0, 10 * 60, null)
        assertTrue(isPreOnsetAwakeStub(b))
    }

    /** #259: a leading fragment carrying SOME sleep (> the 3-min sleepless cap) but MINOR relative to the
     *  main block (below the fraction of the group's largest asleep span) is a spurious lead and IS a stub —
     *  so it no longer hijacks the displayed onset. Without a reference (default) the relative test is OFF,
     *  so the same fragment is NOT a stub: existing callers stay byte-identical. */
    @Test
    fun minorRelativeLeadingFragmentIsStub() {
        // 30 min span, 10 asleep min; main block asleep 400 -> 10 < 0.15*400 = 60 -> spurious.
        val b = block(0, 30 * 60, """{"awake":20,"light":10,"deep":0,"rem":0}""")
        assertTrue(isPreOnsetAwakeStub(b, refAsleepMin = 400.0))
        assertFalse(isPreOnsetAwakeStub(b))
    }

    /** #259 guard: a substantial earlier sleep (comparable to the main block) is a genuine biphasic first
     *  sleep and is NEVER dropped, even with a reference size. */
    @Test
    fun substantialBiphasicFragmentIsNotStubEvenWithRef() {
        // 90 asleep min vs main block 240 -> 90 >= 0.15*240 = 36 -> kept.
        val b = block(0, 100 * 60, """{"awake":10,"light":60,"deep":30,"rem":0}""")
        assertFalse(isPreOnsetAwakeStub(b, refAsleepMin = 240.0))
    }

    /**
     * THE #736 GOLDEN at selectNight level: a three-fragment night — a brief pre-sleep awake stub, then two
     * real sleep fragments split by a short wake (biphasic). The hero's reconstructed segments must start at
     * the FIRST real sleep fragment, never the stub's awake block, so the chart begins at the displayed
     * bedtime. The biphasic split is preserved (both real fragments contribute). The stub stays out of the
     * naps card (it rides in the main-night group).
     */
    @Test
    fun selectNightDropsLeadingStubButKeepsBiphasicNight() {
        // Stub: 21:41-21:55 (14 min), all awake.
        val stubStart = 1_780_000_000L
        val stubEnd = stubStart + 14 * 60
        val stub = block(stubStart, stubEnd,
            """[{"start":$stubStart,"end":$stubEnd,"stage":"wake"}]""")
        // Sleep fragment A ~46 min after the stub (gap < gapBridgeMaxMin so all three bridge), 3h.
        val aStart = stubStart + 60 * 60
        val aEnd = aStart + 3 * 3600
        val fragA = block(aStart, aEnd,
            """[
                {"start":$aStart,"end":${aStart + 3600},"stage":"light"},
                {"start":${aStart + 3600},"end":$aEnd,"stage":"deep"}
            ]""")
        // A brief wake, then sleep fragment B, 4h (the longest → the main block / edit anchor).
        val bStart = aEnd + 20 * 60
        val bEnd = bStart + 4 * 3600
        val fragB = block(bStart, bEnd,
            """[
                {"start":$bStart,"end":${bStart + 2 * 3600},"stage":"light"},
                {"start":${bStart + 2 * 3600},"end":$bEnd,"stage":"rem"}
            ]""")
        val navDays = listOf(listOf(stub, fragA, fragB))

        val hero = selectNight(navDays, emptyList(), 0, habitualMidsleepSec = null)!!
        // The reconstructed group segments start at the first REAL sleep fragment, not the stub's awake block.
        val firstSeg = hero.groupSegments!!.first()
        assertTrue("hero segments must start at real sleep (>= fragment A), not the pre-onset stub",
            firstSeg.start >= aStart)
        // Both real fragments contribute (biphasic night preserved): more than fragment B alone.
        assertTrue("biphasic night must keep both real fragments", hero.groupSegments.size >= 4)
        // The stub is not a nap — it stays inside the main-night group.
        assertTrue(hero.napBlocks.none { it.startTs == stubStart })
        // #345: the hero's clock WINDOW spans the whole night — displayed bedtime (fragment A's onset,
        // the stub dropped) to the GROUP's latest wake (fragment B's end). The winning session is
        // fragment B (the longest), so reading ITS window would show B's onset/wake and the Asleep/Woke
        // row + hypnogram axis would contradict the header pill on exactly this biphasic shape.
        assertTrue("session (edit anchor) is fragment B", hero.session.startTs == bStart)
        assertTrue("window opens at the displayed bedtime (fragment A)", hero.heroOnsetTs == aStart)
        assertTrue("window closes at the group's latest wake (fragment B end)", hero.heroWakeTs == bEnd)
    }

    // ── Real-night regression (#259 / bridged-night headline): a genuine short first sleep is NOT a lead ──

    /**
     * THE BUG (real 2026-07-14 night): a 67-min first-sleep fragment (~34 asleep min) leading a 1:29 → 7:32
     * main sleep (~340 asleep). The #259 relative "minor lead" test compared 34 asleep min against 15% of the
     * ~340-min main (≈51 min) and wrongly classified the real first sleep as a spurious lead, hiding the true
     * 12:16 bedtime. The absolute asleep floor keeps a real sleep episode: 34 ≥ 20, so it is NOT a stub.
     */
    @Test
    fun realFirstSleepFragmentIsNotStub() {
        // 66.8 min span, 34 asleep min, main block asleep 340. Old test: 34 < 0.15*340 (≈51) → wrongly a stub.
        val b = block(0, 4008, """{"awake":33,"light":34,"deep":0,"rem":0}""")
        assertFalse("a real 34-min first sleep beside a 340-min main is NOT a spurious lead",
            isPreOnsetAwakeStub(b, refAsleepMin = 340.0))
    }

    /** Floor boundary: a fragment carrying at least [PRE_ONSET_STUB_MINOR_ASLEEP_FLOOR_MIN] asleep minutes is a
     *  real sleep episode and never a spurious lead, whatever the main block's size. */
    @Test
    fun atMinorAsleepFloorIsNotStub() {
        val b = block(0, 40 * 60, """{"awake":5,"light":20,"deep":0,"rem":0}""")   // exactly 20 asleep min
        assertFalse(isPreOnsetAwakeStub(b, refAsleepMin = 1000.0))
    }

    /** The floor does NOT reopen #736/#259: a tiny stray sleep lead (10 asleep, under the floor AND under 15%
     *  of a big main) is still a spurious lead, so the existing minor-lead goldens stay green. */
    @Test
    fun tinyStrayLeadStillStubUnderFloor() {
        val b = block(0, 30 * 60, """{"awake":20,"light":10,"deep":0,"rem":0}""")
        assertTrue(isPreOnsetAwakeStub(b, refAsleepMin = 400.0))
    }

    // ── Decode-format regression: a computed night's SEGMENT ARRAY first sleep is not read as 0 asleep ──

    /**
     * The real 12:16 → 1:22 first-sleep fragment (deviceId my-whoop-noop, startTs 1784013364), byte-for-byte
     * as stored on the device: an on-device COMPUTED night's SEGMENT ARRAY. Non-wake sum: light 926 s + deep
     * 1320 s + rem 990 s = 3236 s ≈ 53.9 asleep minutes. The displayed-onset stub test must read this
     * format-agnostically ([decodedAsleepMinutes]) — a dict-only decode would return 0 asleep min, trip the
     * "essentially sleepless stub" branch, and the shown bedtime would jump to the 1:29 main block.
     */
    private val fragmentSegmentJson =
        """[{"end":1784013450,"stage":"light","start":1784013364},{"end":1784013540,"stage":"wake","start":1784013450},{"end":1784013600,"stage":"light","start":1784013540},{"end":1784013720,"stage":"wake","start":1784013600},{"end":1784013930,"stage":"light","start":1784013720},{"end":1784015250,"stage":"deep","start":1784013930},{"end":1784015580,"stage":"light","start":1784015250},{"end":1784015640,"stage":"wake","start":1784015580},{"end":1784015880,"stage":"light","start":1784015640},{"end":1784016180,"stage":"wake","start":1784015880},{"end":1784017170,"stage":"rem","start":1784016180},{"end":1784017375,"stage":"wake","start":1784017170}]"""

    /** THE DECODE BUG, guarded: the segment-array format (an on-device computed night) decodes to its real
     *  asleep minutes — not 0. Before a format-agnostic decode a dict-only reader returned 0 here. */
    @Test
    fun segmentArrayFormatDecodesRealAsleepMinutes() {
        val asleep = decodedAsleepMinutes(fragmentSegmentJson, effectiveStartTs = 1_784_013_364L)
        assertEquals(3236.0 / 60.0, asleep, 0.01)
        // Above the #259 floor — the whole point: a real sleep episode must clear it.
        assertTrue(asleep >= PRE_ONSET_STUB_MINOR_ASLEEP_FLOOR_MIN)
    }

    /** END-TO-END: a real first-sleep fragment stored as a SEGMENT ARRAY, beside a large main block, is NOT
     *  skipped as a pre-onset stub — the both-format decode populates its asleep minutes and the floor keeps
     *  it. Before the fix (dict-only decode → 0 asleep) it tripped the sleepless-stub branch and the displayed
     *  bedtime jumped to the main block. */
    @Test
    fun segmentArrayFirstSleepFragmentIsNotSkipped() {
        val frag = block(1_784_013_364L, 1_784_017_375L, fragmentSegmentJson)
        assertFalse("a real segment-array first sleep must not be skipped as a stub",
            isPreOnsetAwakeStub(frag, refAsleepMin = 340.0))
    }

    /** A genuine single-block night is unchanged: the session is that block. */
    @Test
    fun singleBlockNightUnchanged() {
        val start = 1_780_000_000L
        val end = start + 7 * 3600
        val one = block(start, end,
            """[
                {"start":$start,"end":${start + 3 * 3600},"stage":"light"},
                {"start":${start + 3 * 3600},"end":$end,"stage":"deep"}
            ]""")
        val hero = selectNight(listOf(listOf(one)), emptyList(), 0, habitualMidsleepSec = null)!!
        assertEquals(start, hero.session.effectiveStartTs)
    }
}
