package com.noop.analytics

import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests SleepStager.respRateFromRR (RSA) on a synthetic R-R series with a KNOWN breathing
 * frequency. WHOOP5 v18 carries no raw resp ADC, so respiratory rate is derived on-device
 * from the R-R stream via respiratory sinus arrhythmia; this pins that the estimator recovers
 * a planted breathing rate and returns NaN on too-little data (honest no-data). The value is
 * an APPROXIMATE on-device estimate, not cloud/clinical respiration.
 */
class RespRateRsaTest {

    @Test
    fun respRateFromRR_recoversKnownBreathingFrequency() {
        // Synthetic RR: mean HR 60 bpm (RR ~1000 ms) with a 0.25 Hz (15 breaths/min)
        // RSA modulation of +/-40 ms. ~7 minutes of beats so multiple 5-min windows.
        val breathHz = 0.25 // 15 breaths/min
        val baseRrMs = 1000.0
        val ampMs = 40.0
        val start = 1_700_000_000L
        val rows = ArrayList<RrInterval>()
        var tSec = 0.0
        // generate ~420 s of beats
        while (tSec < 420.0) {
            val rrMs = baseRrMs + ampMs * Math.sin(2.0 * Math.PI * breathHz * tSec)
            tSec += rrMs / 1000.0
            rows.add(
                RrInterval(
                    deviceId = "test",
                    ts = start + tSec.toLong(),
                    rrMs = rrMs.toInt(),
                )
            )
        }
        val end = start + tSec.toLong()
        val est = SleepStager.respRateFromRR(rows, start, end)
        assertTrue("expected finite resp estimate, got $est", est.isFinite())
        // RSA peak-pick should land within ~3 bpm of the true 15 breaths/min.
        assertEquals(15.0, est, 3.0)
    }

    /**
     * #958 regression: a slow breather (11 breaths/min, the value in the report) must read back
     * ~11, NOT the doubled ~20-21 the reporter saw. RSA peak-picking has a known failure mode where
     * a split / harmonic peak per breath can inflate the rate toward 2x; this pins that the median
     * across windows stays on the fundamental. Guards the exact factor rather than blindly halving.
     */
    @Test
    fun respRateFromRR_slowBreatherIsNotDoubled() {
        // Mean HR 55 bpm (RR ~1091 ms), 11 breaths/min (0.1833 Hz), +/-45 ms RSA, ~8 min of beats.
        val breathHz = 11.0 / 60.0
        val baseRrMs = 60000.0 / 55.0
        val ampMs = 45.0
        val start = 1_700_000_000L
        val rows = ArrayList<RrInterval>()
        var tSec = 0.0
        while (tSec < 480.0) {
            val rrMs = baseRrMs + ampMs * Math.sin(2.0 * Math.PI * breathHz * tSec)
            tSec += rrMs / 1000.0
            rows.add(RrInterval(deviceId = "test", ts = start + tSec.toLong(), rrMs = rrMs.toInt()))
        }
        val end = start + tSec.toLong()
        val est = SleepStager.respRateFromRR(rows, start, end)
        assertTrue("expected finite resp estimate, got $est", est.isFinite())
        // Must land on the true 11 breaths/min, well below the ~20-21 doubling in #958.
        assertEquals(11.0, est, 2.0)
        assertTrue("resp estimate must not be doubled toward ~22 (#958), got $est", est < 16.0)
    }

    @Test
    fun respRateFromRR_batchedTimestampsIsNaN() {
        // A banked/batched R-R stream whose timestamps are NOT beat-accurate (an Oura overnight IBI stamps
        // many beats at one coarse ring-time) must return NaN — RSA cannot recover breathing from a
        // corrupted time axis. Same R-R VALUES as the recovering test, only the TIMESTAMPS are batched.
        val breathHz = 0.25
        val baseRrMs = 1000.0
        val ampMs = 40.0
        val start = 1_700_000_000L
        val rows = ArrayList<RrInterval>()
        var tSec = 0.0
        var beat = 0
        while (tSec < 600.0) {
            val rrMs = baseRrMs + ampMs * Math.sin(2.0 * Math.PI * breathHz * tSec)
            tSec += rrMs / 1000.0
            // Batched stamp: 6 beats share one coarse second, then jump — like a banked-IBI record.
            rows.add(RrInterval(deviceId = "test", ts = start + (beat / 6).toLong(), rrMs = rrMs.toInt()))
            beat++
        }
        val est = SleepStager.respRateFromRR(rows, start, start + 600)
        assertTrue("batched (non-beat-accurate) timestamps must gate to NaN, got $est", est.isNaN())
    }

    @Test
    fun respRateFromRR_bankedStreamWithoutBreathingStillLooksPlausibleUngated() {
        // The gate is on BANKED-ness, not on the output value — because the value a banked stream
        // produces is PLAUSIBLE. Measured on two real Oura nights (2026-08-07): ungated, both return
        // 13.33 bpm, squarely inside respPlausibleRangeBpm, so the range clamp is no protection at all.
        // Here: banked timestamps over R-R values with NO breathing modulation by construction.
        // Guards against "just widen the plausible band" as an alternative to the gate.
        val start = 1_700_000_000L
        val rows = ArrayList<RrInterval>()
        var seed = 12345L
        var beat = 0
        var tSec = 0.0
        while (tSec < 900.0) {
            seed = seed * 6_364_136_223_846_793_005L + 1_442_695_040_888_963_407L
            val jitter = ((seed ushr 33) % 120L).toDouble()
            val rrMs = 1000.0 + jitter
            tSec += rrMs / 1000.0
            // Banked exactly as the ring does: ~6 beats share one record timestamp.
            rows.add(RrInterval(deviceId = "test", ts = start + (beat / 6) * 6L, rrMs = rrMs.toInt()))
            beat++
        }
        val fraction = HrvAnalyzer.beatAccurateFraction(rows.map { it.ts }, rows.map { it.rrMs.toDouble() })
        assertTrue("fixture must be banked; measured fraction $fraction",
            !HrvAnalyzer.beatValuesAreTrustworthy(fraction))
        assertTrue(SleepStager.respRateFromRR(rows, start, start + 900).isNaN())
    }

    @Test
    fun respRateFromRR_compressedBankingProducesNoSplicesSoOnlyTheGateCatchesIt() {
        // The gate and #977's splice skip catch OPPOSITE banking geometries, so neither subsumes the
        // other. This pins the half only the gate can catch: banking that COMPRESSES time (6 beats in one
        // second) never produces a wall-clock gap above rsaGapToleranceS, so no window looks spliced. On
        // the real ring the geometry is the other one — records TILE time and every boundary reads as a
        // splice — which is why both protections are kept.
        val breathHz = 0.25
        val baseRrMs = 1000.0
        val ampMs = 40.0
        val start = 1_700_000_000L
        val rows = ArrayList<RrInterval>()
        var tSec = 0.0
        var beat = 0
        while (tSec < 600.0) {
            val rrMs = baseRrMs + ampMs * Math.sin(2.0 * Math.PI * breathHz * tSec)
            tSec += rrMs / 1000.0
            rows.add(RrInterval(deviceId = "test", ts = start + (beat / 6).toLong(), rrMs = rrMs.toInt()))
            beat++
        }
        var maxOverrun = 0.0
        for (i in 1 until rows.size) {
            val gapS = (rows[i].ts - rows[i - 1].ts).toDouble()
            maxOverrun = kotlin.math.max(maxOverrun, gapS - rows[i].rrMs.toDouble() / 1000.0)
        }
        assertTrue("compressed banking must not register as a splice, else this proves nothing",
            maxOverrun < SleepStager.rsaGapToleranceS)
        assertTrue(SleepStager.respRateFromRR(rows, start, start + 600).isNaN())
    }

    @Test
    fun respRateFromRR_retimingABankedStreamDefeatsTheGate_knownLimitation() {
        // KNOWN LIMITATION, pinned deliberately so the next person does not walk into it.
        //
        // The gate detects BANKING by its symptom — coarse, repeated timestamps. That symptom is a
        // TRANSPORT artifact and is trivially repairable: give each beat in a record recordTs + cumsum of
        // that record's own intervals and the stream looks beat-accurate again. Measured on two real Oura
        // nights (2026-08-07), re-timing moves beatAccurateFraction 0.0246 / 0.0235 -> 0.875 / 0.863, so it
        // sails through this gate AND #977's splice skip — and the estimate is still 13.3333 bpm, still
        // unchanged when the R-R values are shuffled. Re-timing repairs the axis, not the VALUES.
        //
        // A well-intentioned decoder change that distributes beat timestamps within a record would
        // silently switch respiration back on for a stream carrying no breathing information. If that
        // change is made, this gate must move onto provenance (was this stream banked?) rather than onto
        // timestamp shape. This test fails the day someone re-times, which is the point.
        val start = 1_700_000_000L
        val banked = ArrayList<RrInterval>()
        var seed = 999L
        var beat = 0
        while (beat < 600) {
            seed = seed * 6_364_136_223_846_793_005L + 1_442_695_040_888_963_407L
            val rrMs = 1000 + ((seed ushr 33) % 120L).toInt()
            banked.add(RrInterval(deviceId = "test", ts = start + (beat / 6) * 6L, rrMs = rrMs))
            beat++
        }
        val bankedFraction = HrvAnalyzer.beatAccurateFraction(
            banked.map { it.ts }, banked.map { it.rrMs.toDouble() })
        assertTrue("as stored, the banked stream must be refused",
            !HrvAnalyzer.beatValuesAreTrustworthy(bankedFraction))

        // Re-time: each record's beats laid out from the record's own timestamp by cumulative sum.
        val retimed = ArrayList<RrInterval>()
        var i = 0
        while (i < banked.size) {
            val recordTs = banked[i].ts
            var offset = 0.0
            var j = i
            while (j < banked.size && banked[j].ts == recordTs) {
                retimed.add(RrInterval(deviceId = "test",
                    ts = recordTs + Math.round(offset), rrMs = banked[j].rrMs))
                offset += banked[j].rrMs.toDouble() / 1000.0
                j++
            }
            i = j
        }
        val retimedFraction = HrvAnalyzer.beatAccurateFraction(
            retimed.map { it.ts }, retimed.map { it.rrMs.toDouble() })
        assertTrue(
            "re-timing is expected to DEFEAT this gate (measured 0.875/0.863 on real nights); got " +
                "$retimedFraction. If this now fails, the decoder changed and the gate must be re-based " +
                "on provenance, not on timestamp shape.",
            HrvAnalyzer.beatValuesAreTrustworthy(retimedFraction))
    }

    @Test
    fun respRateFromRR_tooFewBeatsIsNaN() {
        val start = 1_700_000_000L
        val rows = listOf(
            RrInterval(deviceId = "test", ts = start + 1, rrMs = 1000),
            RrInterval(deviceId = "test", ts = start + 2, rrMs = 1000),
            RrInterval(deviceId = "test", ts = start + 3, rrMs = 1000),
        )
        assertTrue(SleepStager.respRateFromRR(rows, start, start + 10).isNaN())
        assertTrue(SleepStager.respRateFromRR(emptyList(), start, start + 10).isNaN())
    }
}
