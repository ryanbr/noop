package com.noop.analytics

import com.noop.data.HrSample
import com.noop.data.SkinTempSample
import com.noop.protocol.DeviceFamily
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1567: a scoring pass with no device registry behind it reads a WHOOP 4.0 on the 5/MG temperature scale.
 *
 * `analyzeRecent(ownerSource = …)` is nullable, and the post-backfill pass was documented as an accepted
 * exception to supplying it — correctly, while the parameter only chose which device *owned* a day: a
 * single-WHOOP install resolves to `importedDeviceId` either way, byte for byte.
 *
 * #938 later routed the skin-temp raw→°C **scale** through that same source (`skinFamily = ownerSource?
 * .skinTempFamily(owner) ?: DeviceFamily.WHOOP5`). For that consumer a missing source is *not*
 * byte-identical, and this test is the proof: the same samples, read under the two families, do not merely
 * differ — one of them produces no reading at all.
 *
 * Values are from the reported strap log (WHOOP 4.0, fw 41.17.6.0): `raw[min=577 p50=772 max=820]`,
 * `anchor=794 → p50 maps 31.9 °C`, worn gate 28–42 °C.
 *
 * The *fix* is Kotlin-only, because Swift has no parameter to thread: its `analyzeRecent` reads
 * `registry.all()` itself, so no caller is able to omit it. The *flaw* is shared, though — Swift reaches
 * the identical silent WHOOP5 fallback when that read THROWS, since `(try? registry.all()) ?? []` used to
 * swallow it and an empty device list resolves every day to WHOOP5. So the diagnostic half is twinned:
 * see `RegistryUnavailableLineTests` and `AnalyticsEngine.registryUnavailableLine`.
 */
class OwnerSourceSkinTempScaleTest {

    private val dev = "my-whoop"

    private fun session(start: Long, durSec: Long) = DetectedSleep(
        start = start, end = start + durSec, efficiency = 0.9,
        stages = emptyList(), restingHR = 50, avgHRV = 60.0,
    )

    private fun hr(ts: Long, bpm: Int = 55) = HrSample(deviceId = dev, ts = ts, bpm = bpm)
    private fun skin(ts: Long, raw: Int) = SkinTempSample(deviceId = dev, ts = ts, raw = raw)

    /** A night of a real WHOOP 4.0's raw skin-temp ADC, at the reported median. */
    private fun night(): Triple<List<DetectedSleep>, List<HrSample>, List<SkinTempSample>> {
        val start = 1_787_000_000L
        return Triple(
            listOf(session(start, 600)),
            (0 until 600).map { hr(start + it) },
            (0 until 600).map { skin(start + it, 772) },
        )
    }

    /**
     * The bug, stated as the two numbers a user would get depending on which pass wrote last.
     *
     * On the correct family the night reads as a plausible skin temperature. On the fallback the same raw
     * ADC is interpreted as centidegrees — 772 → 7.72 °C — which fails the 28–42 °C worn gate, so every
     * sample is dropped and the night yields NOTHING. Not a small numeric drift: a present value versus an
     * absent one, from identical input.
     */
    @Test
    fun theSameNightReadsAsATemperatureOnWhoop4AndAsNothingOnTheWhoop5Fallback() {
        val (sess, hrs, temps) = night()

        val correct = AnalyticsEngine.wornNightlySkinTempC(sess, hrs, temps, DeviceFamily.WHOOP4)
        assertNotNull("a WHOOP 4.0 night must yield a skin temperature", correct)
        assertTrue("expected a worn-range reading, got $correct", correct!! in 28.0..42.0)

        val fallback = AnalyticsEngine.wornNightlySkinTempC(sess, hrs, temps, DeviceFamily.WHOOP5)
        assertNull("the WHOOP5 scale reads 772 as 7.72 C and drops the whole night", fallback)
    }

    /**
     * The fallback is not wrong for a 5/MG — it is right for it. Pinned so the fix is understood as "route
     * the family correctly", not "the WHOOP5 branch is broken": a genuine 5/MG banks centidegrees, and 3400
     * is 34.00 °C on exactly the branch that mangled the 4.0's ADC.
     */
    @Test
    fun theWhoop5ScaleIsCorrectForAWhoop5() {
        val start = 1_787_000_000L
        val sess = listOf(session(start, 600))
        val hrs = (0 until 600).map { hr(start + it) }
        val temps = (0 until 600).map { skin(start + it, 3400) }   // centidegrees
        assertEquals(34.0, AnalyticsEngine.wornNightlySkinTempC(sess, hrs, temps, DeviceFamily.WHOOP5)!!, 1e-9)
    }

    /**
     * The resolver behind it: only a positively-identified 4.0 changes scale, and every other label — the
     * legacy seeded "WHOOP" row, an unknown, a null — lands on WHOOP5. That fall-through is deliberate
     * (#171/#938) and is left alone; what #1567 changes is that a pass no longer arrives here with no
     * registry at all.
     */
    @Test
    fun onlyAPositivelyIdentifiedFourPointZeroChangesScale() {
        assertEquals(DeviceFamily.WHOOP4, DeviceFamily.forRegistryModel("4.0"))
        assertEquals(DeviceFamily.WHOOP4, DeviceFamily.forRegistryModel("WHOOP 4.0"))
        assertEquals(DeviceFamily.WHOOP5, DeviceFamily.forRegistryModel("WHOOP"))
        assertEquals(DeviceFamily.WHOOP5, DeviceFamily.forRegistryModel(null))
    }

    /**
     * And the pass now says so out loud. The absence of any such line is why a WHOOP 4.0 could be scored on
     * the 5/MG scale across many passes without it being visible in an exported log — the two kinds of pass
     * were indistinguishable.
     */
    @Test
    fun anAbsentOwnerSourceNamesItselfAndTheFallbacksItIsUsing() {
        assertEquals(
            "analyzeRecent ownerSource=absent owner->my-whoop skinTempScale->whoop5",
            IntelligenceEngine.ownerSourceAbsentLine("my-whoop"),
        )
    }

    /**
     * The shared grammar with the Swift twin (`AnalyticsEngine.registryUnavailableLine`), pinned as a SHAPE
     * rather than as one identical string.
     *
     * The two platforms reach this state by genuinely different routes — Kotlin by a caller omitting the
     * optional owner source, Swift by its registry read failing — so the cause tokens differ on purpose.
     * What must match is everything a reader needs to act on: the same prefix, and the same two fallbacks
     * named the same way, so an Android log and an iOS log stay comparable.
     *
     * If someone later "fixes the parity" by making the strings identical, the cause is lost and the line
     * stops answering the question it exists for. That is what this guards.
     */
    @Test
    fun itNamesBothFallbacksTheReaderNeeds() {
        val line = IntelligenceEngine.ownerSourceAbsentLine("my-whoop")
        assertTrue(line, line.startsWith("analyzeRecent "))
        assertTrue("must say which owner it fell back to: $line", line.contains("owner->my-whoop"))
        assertTrue("must say which scale it used: $line", line.contains("skinTempScale->whoop5"))
        // The cause token is what SEPARATES the twins — Kotlin can only get here via an omitted parameter.
        assertTrue(line, line.contains("ownerSource=absent"))
        assertFalse("that is the Swift route, not this one: $line", line.contains("registry=unavailable"))
    }

    /** The id is not assumed to be the seeded default — a renamed or second strap must read back honestly. */
    @Test
    fun theOwnerIsWhicheverIdThePassFellBackTo() {
        assertEquals(
            "analyzeRecent ownerSource=absent owner->my-whoop-2 skinTempScale->whoop5",
            IntelligenceEngine.ownerSourceAbsentLine("my-whoop-2"),
        )
    }
}
