package com.noop.ui

import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the durable non-GPS active-workout codec (#529): the persist -> rehydrate round-trip that lets a
 * manually-started, non-GPS session survive the OS killing the process mid-session so it can still be
 * ended and saved. Pure (Context-free), so it mirrors the macOS ActiveWorkoutPersistenceTests case for
 * case without standing up SharedPreferences. Bound-checks the untrusted persisted values too.
 */
class ActiveWorkoutPersistenceTest {

    // The on-disk framing delimiters (ASCII unit / record separators), so the hand-rolled raw strings
    // below build the exact bytes the encoder writes.
    private val fs = "\u001F"
    private val rs = "\u001E"

    private fun sample(ts: Long, bpm: Int) = HrSample(deviceId = "my-whoop", ts = ts, bpm = bpm)

    private fun snapshot(
        startMs: Long = 1_700_000_000_000L,
        sportName: String = "Tennis",
        deviceId: String = "my-whoop",
        samples: List<HrSample> = listOf(sample(1_700_000_001L, 120), sample(1_700_000_061L, 145)),
        avgHr: Int = 133,
        peakHr: Int = 145,
        liveStrain: Double = 8.4,
        pausedAtMs: Long? = null,
        pausedDurationMs: Long = 0L,
    ) = ActiveWorkoutPersistence.Snapshot(
        startMs, sportName, deviceId, samples, avgHr, peakHr, liveStrain, pausedAtMs, pausedDurationMs,
    )

    /** A valid 7-field header for [startMs]/[deviceId] with zeroed stats and no samples. */
    private fun header(startMs: String = "1700000000000", deviceId: String = "my-whoop") =
        "v1$fs$startMs${fs}0${fs}0${fs}0.0${fs}Run$fs$deviceId"

    // MARK: - round-trip

    @Test
    fun encodeDecode_roundTripsEveryField() {
        val original = snapshot(pausedAtMs = 1_700_000_120_000L, pausedDurationMs = 45_000L)
        val decoded = ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(original))
        assertNotNull(decoded)
        decoded!!
        assertEquals(original.startMs, decoded.startMs)
        assertEquals(original.sportName, decoded.sportName)
        assertEquals(original.deviceId, decoded.deviceId)
        assertEquals(original.avgHr, decoded.avgHr)
        assertEquals(original.peakHr, decoded.peakHr)
        assertEquals(original.liveStrain, decoded.liveStrain, 1e-9)
        assertEquals(original.samples, decoded.samples)
        assertEquals(original.pausedAtMs, decoded.pausedAtMs)
        assertEquals(original.pausedDurationMs, decoded.pausedDurationMs)
    }

    @Test
    fun roundTrip_withNoSamples() {
        // A session that started but hasn't captured a sample yet (strap not streaming) must still
        // persist + rehydrate — otherwise an OS kill right after Start loses the start time.
        val decoded = ActiveWorkoutPersistence.decode(
            ActiveWorkoutPersistence.encode(snapshot(samples = emptyList(), avgHr = 0, peakHr = 0, liveStrain = 0.0)),
        )
        assertNotNull(decoded)
        assertTrue(decoded!!.samples.isEmpty())
        assertEquals(1_700_000_000_000L, decoded.startMs)
        assertEquals("Tennis", decoded.sportName)
    }

    @Test
    fun roundTrip_sportNameWithSpacesPreserved() {
        // "Traditional Strength Training" etc. carry spaces — they must survive intact (the framing uses
        // control-char delimiters, not whitespace).
        val decoded = ActiveWorkoutPersistence.decode(
            ActiveWorkoutPersistence.encode(snapshot(sportName = "Traditional Strength Training")),
        )
        assertEquals("Traditional Strength Training", decoded!!.sportName)
    }

    @Test
    fun encode_stripsDelimitersFromSportName() {
        // A sport name that somehow carried a framing delimiter must not corrupt the record — it's
        // sanitized to a space on the way out and the round-trip stays valid.
        val decoded = ActiveWorkoutPersistence.decode(
            ActiveWorkoutPersistence.encode(snapshot(sportName = "Ten${fs}nis$rs")),
        )
        assertNotNull(decoded)
        // No delimiter leaks back into the decoded name.
        assertTrue(!decoded!!.sportName.contains(fs) && !decoded.sportName.contains(rs))
    }

    // MARK: - honest failure (no revived bogus card)

    @Test
    fun decode_nullOrBlank_isNull() {
        assertNull(ActiveWorkoutPersistence.decode(null))
        assertNull(ActiveWorkoutPersistence.decode(""))
        assertNull(ActiveWorkoutPersistence.decode("   "))
    }

    @Test
    fun decode_garbageOrWrongVersion_isNull() {
        assertNull(ActiveWorkoutPersistence.decode("not-our-format"))
        // Wrong version tag.
        assertNull(ActiveWorkoutPersistence.decode(header().replaceFirst("v1", "v2")))
        // Too few header fields.
        assertNull(ActiveWorkoutPersistence.decode("v1${fs}1700000000000${fs}0"))
        // Non-numeric start.
        assertNull(ActiveWorkoutPersistence.decode(header(startMs = "nope")))
        // Blank device id.
        assertNull(ActiveWorkoutPersistence.decode(header(deviceId = "")))
        // Non-positive start.
        assertNull(ActiveWorkoutPersistence.decode(header(startMs = "0")))
    }

    // MARK: - bound-checked untrusted samples

    @Test
    fun decode_dropsOutOfRangeSamples() {
        // A valid header, then hand-rolled sample lines: one good, one bpm=0 (rejected), one bpm=400
        // (rejected), one ts<=0 (rejected), one torn (rejected) — only the good one survives.
        val raw = header() +
            "${rs}1700000001,150" +   // good
            "${rs}1700000002,0" +     // bpm 0 — rejected
            "${rs}1700000003,400" +   // bpm out of range — rejected
            "${rs}0,120" +            // ts <= 0 — rejected
            "${rs}1700000004"         // torn (no bpm) — rejected
        val decoded = ActiveWorkoutPersistence.decode(raw)
        assertNotNull(decoded)
        assertEquals(1, decoded!!.samples.size)
        assertEquals(150, decoded.samples[0].bpm)
        assertEquals(1_700_000_001L, decoded.samples[0].ts)
    }

    @Test
    fun decode_clampsNegativeDerivedStats() {
        // A corrupt write that put negative stats / a non-finite strain in must clamp, not propagate.
        val raw = "v1${fs}1700000000000${fs}-5${fs}-9${fs}NaN${fs}Run${fs}my-whoop"
        val decoded = ActiveWorkoutPersistence.decode(raw)
        assertNotNull(decoded)
        assertEquals(0, decoded!!.avgHr)
        assertEquals(0, decoded.peakHr)
        assertEquals(0.0, decoded.liveStrain, 1e-9)
    }
}
