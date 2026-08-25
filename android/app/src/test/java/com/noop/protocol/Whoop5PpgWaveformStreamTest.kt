package com.noop.protocol

import com.noop.data.PpgWaveformRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Durable v26 optical-PPG waveform persistence (issue #156 follow-up, PR #415 Android twin). Until now
 * [extractHistoricalStreams] accumulated a v26 record's waveform ONLY to derive a per-second HR estimate
 * (`ppgHr`); the raw samples were discarded once that estimate was taken. This proves the raw waveform now
 * survives as its OWN stream ([com.noop.data.StreamBatch.ppgWaveform]), independently of whether the HR
 * estimator had enough context to run.
 *
 * The fixture is the SAME real captured v26 frame the Swift `Whoop5PpgWaveformTests` uses (a clean PPG
 * upstroke, all-negative AC-coupled ADC counts), so the decoded waveform is cross-platform ground truth.
 */
class Whoop5PpgWaveformStreamTest {

    private fun bytes(s: String): ByteArray =
        ByteArray(s.length / 2) { ((Character.digit(s[it * 2], 16) shl 4) + Character.digit(s[it * 2 + 1], 16)).toByte() }

    // Real captured WHOOP 5.0 v26 optical-PPG frame (unix @15 == 1780917232), 24 i16 samples @ [27:75].
    private val v26Hex =
        "aa015000010035412f1a80ad418401f0a3266aae470100c3c5050068faccfa8dfb46fc8bfd4c" +
            "febafedafe6dff56ffd5fffbff37ff6afce5f9d7f8dffa5efc98fddbfe5afe84fe15ff5cff40" +
            "5fb33c50080101006cb67c17"

    private val expectedWaveform = listOf(
        -1432, -1332, -1139, -954, -629, -436, -326, -294, -147, -170, -43, -5,
        -201, -918, -1563, -1833, -1313, -930, -616, -293, -422, -380, -235, -164,
    )

    /**
     * A single v26 record is one second of samples — nowhere near the run [PpgHr] needs for a confident HR
     * estimate, so `ppgHr` stays empty. Before this change that meant the ENTIRE record vanished (nothing
     * else read the waveform); now the raw waveform is still captured as its own stream.
     */
    @Test
    fun extractPersistsRawPpgWaveform() {
        val streams = extractHistoricalStreams(
            listOf(bytes(v26Hex)),
            deviceClockRef = 1_780_917_232,
            wallClockRef = 1_780_917_232,
            family = DeviceFamily.WHOOP5,
        )
        assertEquals(
            listOf(PpgWaveformRow(ts = 1_780_917_232L, samples = expectedWaveform, burstIndex = 1)),
            streams.ppgWaveform,
        )
        assertTrue("a lone 1 s record is too short for a confident HR estimate", streams.ppgHr.isEmpty())
        // Not "no rows at all" — a waveform-only decode must read as non-empty so the Backfiller's
        // silent-data-loss diagnostic counts it as decoded.
        assertFalse(streams.isEmpty)
    }

    @Test
    fun zeroBurstIndexIsAbsentLikeSwift() {
        val frame = bytes(v26Hex)
        frame[21] = 0
        val end = frame.size - 4
        val crc = Crc.crc32(frame, 8, end)
        for (i in 0 until 4) frame[end + i] = ((crc ushr (8 * i)) and 0xFF).toByte()
        val streams = extractHistoricalStreams(
            listOf(frame), 1_780_917_232, 1_780_917_232, DeviceFamily.WHOOP5,
        )
        assertEquals(null, streams.ppgWaveform.single().burstIndex)
    }

    /** [com.noop.data.StreamBatch.isEmpty] must count a waveform-only decode as non-empty even when the
     *  derived `ppgHr` (produced FROM it) is empty, or the "chunk carried no records" diagnostic misfires. */
    @Test
    fun streamBatchIsEmptyConsidersPpgWaveform() {
        val empty = com.noop.data.StreamBatch()
        assertTrue(empty.isEmpty)
        val waveformOnly = com.noop.data.StreamBatch(
            ppgWaveform = listOf(PpgWaveformRow(ts = 1L, samples = listOf(1, 2, 3))),
        )
        assertFalse(waveformOnly.isEmpty)
    }
}
