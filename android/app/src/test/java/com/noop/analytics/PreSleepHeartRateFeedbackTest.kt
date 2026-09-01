package com.noop.analytics

import com.noop.data.JournalEntry
import com.noop.protocol.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Kotlin twin of `PreSleepHeartRateFeedbackTests` (#1784), assertion for assertion.
 *
 * The numbers are the point: every expected value here was taken from the Swift suite unchanged, so a
 * divergence in [Baselines.rollingMeanSD], [Baselines.computeStatus] or the day arithmetic shows up as a
 * failure rather than as two platforms quietly disagreeing about the same night.
 */
class PreSleepHeartRateFeedbackTest {

    private fun samples(start: Int, bpm: Int, count: Int): List<HrSample> =
        (0 until count).map { HrSample(ts = start + it * 60, bpm = bpm) }

    private fun sleep(start: Long = 10_000, end: Long = 36_000) =
        DetectedSleep(start = start, end = end, efficiency = 0.9, stages = emptyList(),
                      restingHR = null, avgHRV = null)

    private fun reading(day: String, bpm: Double) =
        PreSleepHeartRateFeedback.HistoricalReading(day = day, meanBpm = bpm)

    @Test
    fun `eligible feedback separates observation, comparison, uncertainty and unsupported recommendation`() {
        val history = listOf(60.0, 61.0, 62.0, 63.0).mapIndexed { i, bpm ->
            reading("2026-08-0${i + 1}", bpm)
        }
        val journal = JournalEntry(deviceId = "d", day = "2026-08-05", question = "Late meal",
                                   answeredYes = true)
        val feedback = PreSleepHeartRateFeedback.evaluate(
            enabled = true, sessions = listOf(sleep()),
            hr = samples(8_800, 70, 12) + samples(10_000, 55, 12),
            history = history, journalEntries = listOf(journal), day = "2026-08-05",
            minimumValidSamples = 10, preSleepWindowSeconds = 1_800,
        )

        assertEquals(PreSleepHeartRateFeedback.Eligibility.Eligible, feedback.eligibility)
        assertEquals(8_200L, feedback.observation?.windowStartTs)
        assertEquals(10_000L, feedback.observation?.windowEndTs)
        assertEquals(70.0, feedback.observation!!.meanBpm, 1e-9)
        assertEquals(12, feedback.observation?.validSamples)
        assertEquals(61.5, feedback.comparison!!.baselineBpm, 1e-9)
        assertEquals(8.5, feedback.comparison!!.deltaBpm, 1e-9)
        assertEquals(BaselineStatus.PROVISIONAL, feedback.comparison?.baselineStatus)
        assertEquals(listOf(PreSleepHeartRateFeedback.Uncertainty.ProvisionalBaseline), feedback.uncertainty)
        assertEquals(PreSleepHeartRateFeedback.Inference.NOT_ESTABLISHED, feedback.inference)
        assertEquals(PreSleepHeartRateFeedback.Recommendation.UNSUPPORTED, feedback.recommendation)
        assertEquals(
            listOf(PreSleepHeartRateFeedback.JournalFact("2026-08-05", "Late meal", true, null)),
            feedback.journalContext,
        )
    }

    @Test
    fun `the baseline uses only sorted prior nights`() {
        val history = listOf(
            reading("2026-08-01", 60.0), reading("2026-08-04", 63.0), reading("2026-08-02", 61.0),
            reading("2026-08-03", 62.0), reading("2026-08-05", 90.0), reading("2026-08-06", 100.0),
        )
        val feedback = PreSleepHeartRateFeedback.evaluate(
            enabled = true, sessions = listOf(sleep()), hr = samples(8_800, 70, 12),
            history = history, journalEntries = emptyList(), day = "2026-08-05",
            minimumValidSamples = 10, preSleepWindowSeconds = 1_800,
        )
        // Current and future days must not leak in, and unsorted input must not change the answer.
        assertEquals(61.5, feedback.comparison!!.baselineBpm, 1e-9)
        assertEquals(4, feedback.comparison?.baselineNights)
    }

    @Test
    fun `a repeated prior day cannot satisfy the minimum baseline nights`() {
        val history = List(4) { reading("2026-08-01", 60.0) }
        val feedback = PreSleepHeartRateFeedback.evaluate(
            enabled = true, sessions = listOf(sleep()), hr = samples(8_800, 70, 12),
            history = history, journalEntries = emptyList(), day = "2026-08-05",
            minimumValidSamples = 10, preSleepWindowSeconds = 1_800,
        )
        assertEquals(
            PreSleepHeartRateFeedback.Eligibility.InsufficientBaseline(
                1, PreSleepHeartRateFeedback.minimumBaselineNights),
            feedback.eligibility,
        )
        assertNull(feedback.comparison)
        assertEquals(listOf(PreSleepHeartRateFeedback.Uncertainty.NoPersonalComparison), feedback.uncertainty)
    }

    @Test
    fun `noncanonical and impossible days cannot satisfy the minimum baseline nights`() {
        // "2026-08-04Z" is the wrong length; 2026-02-31 passes a shape check and fails a real calendar.
        val history = listOf(
            reading("2026-08-01", 60.0), reading("2026-08-04Z", 61.0),
            reading("2026-02-31", 62.0), reading("2026-08-03", 63.0),
        )
        val feedback = PreSleepHeartRateFeedback.evaluate(
            enabled = true, sessions = listOf(sleep()), hr = samples(8_800, 70, 12),
            history = history, journalEntries = emptyList(), day = "2026-08-05",
            minimumValidSamples = 10, preSleepWindowSeconds = 1_800,
        )
        assertEquals(
            PreSleepHeartRateFeedback.Eligibility.InsufficientBaseline(
                2, PreSleepHeartRateFeedback.minimumBaselineNights),
            feedback.eligibility,
        )
    }

    @Test
    fun `invalid evaluation days cannot produce feedback`() {
        for (day in listOf("2026-8-05", "2026-02-31", "not-a-day", "", "2026-08-05Z")) {
            val feedback = PreSleepHeartRateFeedback.evaluate(
                enabled = true, sessions = listOf(sleep()), hr = samples(8_800, 70, 12),
                history = emptyList(), journalEntries = emptyList(), day = day,
                minimumValidSamples = 10, preSleepWindowSeconds = 1_800,
            )
            assertEquals("day=$day", PreSleepHeartRateFeedback.Eligibility.InvalidDay, feedback.eligibility)
            assertNull(feedback.observation)
        }
    }

    @Test
    fun `a baseline at the exact stale boundary stays trusted across a year boundary`() {
        val history = (1..13).map { reading(String.format("2023-01-%02d", it), 60.0) } +
            reading("2023-12-18", 60.0)
        val feedback = PreSleepHeartRateFeedback.evaluate(
            enabled = true, sessions = listOf(sleep()), hr = samples(8_800, 70, 12),
            history = history, journalEntries = emptyList(), day = "2024-01-01",
            minimumValidSamples = 10, preSleepWindowSeconds = 1_800,
        )
        assertEquals(PreSleepHeartRateFeedback.Eligibility.Eligible, feedback.eligibility)
        assertEquals(BaselineStatus.TRUSTED, feedback.comparison?.baselineStatus)
        assertTrue(feedback.uncertainty.isEmpty())
    }

    @Test
    fun `one day past the stale boundary is explicitly stale across a leap day`() {
        val history = (1..13).map { reading(String.format("2024-01-%02d", it), 60.0) } +
            reading("2024-02-15", 60.0)
        val feedback = PreSleepHeartRateFeedback.evaluate(
            enabled = true, sessions = listOf(sleep()), hr = samples(8_800, 70, 12),
            history = history, journalEntries = emptyList(), day = "2024-03-01",
            minimumValidSamples = 10, preSleepWindowSeconds = 1_800,
        )
        // 15 only if 2024-02-29 is counted: the leap day is the assertion.
        assertEquals(PreSleepHeartRateFeedback.Eligibility.StaleBaseline(15), feedback.eligibility)
        assertNotNull(feedback.observation)
        assertNull(feedback.comparison)
        assertEquals(listOf(PreSleepHeartRateFeedback.Uncertainty.StaleBaseline(15)), feedback.uncertainty)
    }

    @Test
    fun `an extreme sleep session duration fails closed without trapping`() {
        val feedback = PreSleepHeartRateFeedback.evaluate(
            enabled = true, sessions = listOf(sleep(start = Long.MIN_VALUE, end = Long.MAX_VALUE)),
            hr = samples(8_800, 70, 12), history = emptyList(), journalEntries = emptyList(),
            day = "2026-08-05", minimumValidSamples = 10, preSleepWindowSeconds = 1_800,
        )
        assertEquals(PreSleepHeartRateFeedback.Eligibility.MissingPrimarySleep, feedback.eligibility)
    }

    @Test
    fun `an extreme pre-sleep window fails closed without trapping`() {
        val feedback = PreSleepHeartRateFeedback.evaluate(
            enabled = true, sessions = listOf(sleep(start = Long.MIN_VALUE + 1, end = Long.MIN_VALUE + 2)),
            hr = samples(8_800, 70, 12), history = emptyList(), journalEntries = emptyList(),
            day = "2026-08-05", minimumValidSamples = 10, preSleepWindowSeconds = 1_800,
        )
        assertEquals(PreSleepHeartRateFeedback.Eligibility.InvalidWindow, feedback.eligibility)
    }

    @Test
    fun `opting out and lapsing fail closed without creating feedback or punishment`() {
        val off = PreSleepHeartRateFeedback.evaluate(
            enabled = false, sessions = listOf(sleep()), hr = samples(8_800, 70, 12),
            history = emptyList(), journalEntries = emptyList(), day = "2026-08-05",
        )
        assertEquals(PreSleepHeartRateFeedback.Eligibility.Disabled, off.eligibility)
        assertNull(off.observation)
        assertTrue(off.journalContext.isEmpty())

        val noSleep = PreSleepHeartRateFeedback.evaluate(
            enabled = true, sessions = emptyList(), hr = samples(8_800, 70, 12),
            history = emptyList(), journalEntries = emptyList(), day = "2026-08-05",
        )
        assertEquals(PreSleepHeartRateFeedback.Eligibility.MissingPrimarySleep, noSleep.eligibility)

        val thin = PreSleepHeartRateFeedback.evaluate(
            enabled = true, sessions = listOf(sleep()), hr = samples(8_800, 70, 3),
            history = emptyList(), journalEntries = emptyList(), day = "2026-08-05",
            minimumValidSamples = 10, preSleepWindowSeconds = 1_800,
        )
        assertEquals(
            PreSleepHeartRateFeedback.Eligibility.InsufficientPreSleepSamples(3, 10), thin.eligibility)
        // Every one of these is recoverable on a later night: no streak, no goal, no obligation.
        assertEquals(PreSleepHeartRateFeedback.Recommendation.UNSUPPORTED, thin.recommendation)
    }

    @Test
    fun `duplicate timestamps keep the caller's first sample, which is its precedence order`() {
        // The repository coalesces measured over PPG before this runs, so first-wins preserves that
        // choice. Last-wins would silently invert it.
        val hr = samples(8_800, 70, 12) + samples(8_800, 200, 12)
        val feedback = PreSleepHeartRateFeedback.evaluate(
            enabled = true, sessions = listOf(sleep()), hr = hr, history = emptyList(),
            journalEntries = emptyList(), day = "2026-08-05",
            minimumValidSamples = 10, preSleepWindowSeconds = 1_800,
        )
        assertEquals(70.0, feedback.observation!!.meanBpm, 1e-9)
        assertEquals(12, feedback.observation?.totalTimestampSamples)
    }
}
