package com.noop.ui

import com.noop.analytics.SleepStageTotals
import com.noop.data.SleepSession
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import java.util.TimeZone

/**
 * Pins the VERBATIM "why this is your main sleep" copy (COMPONENT 1) the Sleep screen renders for each
 * foundation [SleepStageTotals.MainNightReason] branch, and the {DUR} fill. The strings are a hard
 * cross-platform contract — they MUST be byte-identical to iOS SleepView.mainSleepReasonText, so this
 * guards against an accidental reword on the Kotlin side.
 *
 * [mainSleepReasonText] resolves its sentence through the app's string resources, which a JVM test cannot
 * reach, so these cases drive [mainSleepReasonCopy] (which sentence, plus the {DUR} fill) and read that
 * sentence's English value out of values/strings.xml via [EnglishResources].
 *
 * [mainSleepReasonCopy] resolves the reason via [SleepStageTotals.mainNightSelection] using
 * `uiTzOffsetSec()` (the device default tz), so the timezone is pinned to UTC here — making the local
 * time-of-day of each block's midpoint equal its UTC time-of-day, exactly matching the `offsetSec = 0L`
 * foundation fixtures in MainNightConsistencyTest. One case per reason branch + the empty-day null.
 */
class MainSleepReasonCopyTest {

    private val saved = TimeZone.getDefault()
    @Before fun pinUtc() { TimeZone.setDefault(TimeZone.getTimeZone("UTC")) }
    @After fun restore() { TimeZone.setDefault(saved) }

    /** An arbitrary fixed UTC midnight (ref % 86400 == 0) so local == UTC under the pinned tz. */
    private val refMidnight = 1_749_513_600L
    private fun atHour(hour: Int): Long = refMidnight + hour * 3_600L
    private fun sod(hour: Int, min: Int): Long = hour * 3_600L + min * 60L
    private fun block(start: Long, durSec: Long) =
        SleepSession(deviceId = "my-whoop-noop", startTs = start, endTs = start + durSec)

    /** The English sentence [mainSleepReasonText] would show, resolved from the resource it picks. */
    private fun reasonText(blocks: List<SleepSession>, habitualMidsleepSec: Long?): String? =
        mainSleepReasonCopy(blocks, habitualMidsleepSec)?.let { copy ->
            if (copy.duration == null) EnglishResources.text(copy.res)
            else EnglishResources.format(copy.res, copy.duration)
        }

    @Test
    fun emptyDayHasNoReason() {
        assertNull(mainSleepReasonCopy(emptyList(), null))
    }

    /** onlyBlock: a single block, with {DUR} filled from its asleep span (7h 12m). */
    @Test
    fun onlyBlockCopy() {
        val night = atHour(23) - 86_400L
        val reason = reasonText(listOf(block(night, 7 * 3600L + 12 * 60L)), null)
        assertEquals("This is your only sleep block today.", reason)
    }

    /** longest (cold-start, null habitual): the longest block wins on duration; {DUR} = 6h 0m. */
    @Test
    fun longestColdStartCopy() {
        val a = atHour(22) - 86_400L
        val b = atHour(23) - 86_400L + 1_800L
        val blocks = listOf(block(a, 3 * 3600L), block(b, 6 * 3600L))
        val reason = reasonText(blocks, null) // null habitual = cold-start
        assertEquals(
            "Picked as your main sleep because it was your longest block (6h 0m).",
            reason,
        )
    }

    /** longestNearUsual: learned habitual present, the longest block is also bonus-aligned; {DUR} = 6h 0m. */
    @Test
    fun longestNearUsualCopy() {
        val habitual = sod(3, 0)
        val night = atHour(23) - 86_400L // 6h, mid 02:00 — longest AND ~1h from the 03:00 habitual
        val nap = atHour(15)             // 1h afternoon, far from the habitual
        val blocks = listOf(block(nap, 1 * 3600L), block(night, 6 * 3600L))
        val reason = reasonText(blocks, habitual)
        assertEquals(
            "Picked as your main sleep because it was your longest block (6h 0m), near your usual bedtime.",
            reason,
        )
    }

    /** alignedToUsual: the alignment bonus (not raw duration) flipped the pick toward a shorter, well-timed
     *  night, so the copy drops the duration and leads with the timing. */
    @Test
    fun alignedToUsualCopy() {
        val habitual = sod(3, 0)
        val afternoon = atHour(13) // 5h, mid 15:30, bonus 0 (duration-only winner)
        val night = atHour(1)      // 4h, mid 03:00, bonus 90 → score winner
        val blocks = listOf(block(afternoon, 5 * 3600L), block(night, 4 * 3600L))
        val reason = reasonText(blocks, habitual)
        assertEquals(
            "Picked as your main sleep because it started near your usual sleep time.",
            reason,
        )
    }
}
