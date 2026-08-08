package com.noop.data

import com.noop.oura.OuraEvent
import com.noop.oura.OuraHR
import com.noop.oura.OuraHRV
import com.noop.oura.OuraIBI
import com.noop.oura.OuraMotionEvent
import com.noop.oura.OuraSleepPhase
import com.noop.oura.OuraSleepStage
import com.noop.oura.OuraSpO2
import com.noop.oura.OuraTemp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM tests for [OuraStreamMapping], the pure fold of decoded Oura events onto the protocol Streams
 * shape (section-4 of the Oura local-BLE architecture plan). These pin the exact event kinds and
 * payload keys the Swift twin must match, the honest-data invariants (no fabricated channels, no
 * faked timestamps), and the SpO2/skinTemp widening onto the store.
 *
 * The anchor maps a ring-clock value to wall-clock unix seconds; tests use a trivial linear anchor so
 * the mapping logic (not a clock model) is what is under test.
 */
class OuraStreamMappingTest {

    /** Ring-clock 0 -> a fixed wall-clock base; +1 ring tick == +1 second. */
    private val base = 1_750_000_000
    private val anchor: (Long) -> Int? = { rt -> base + rt.toInt() }

    @Test
    fun hrAndIbiMapToHrAndRr() {
        val s = OuraStreamMapping.streams(
            listOf(
                OuraEvent.Hr(OuraHR(ringTimestamp = 10, bpm = 72, ibiMs = 833)),
                OuraEvent.Ibi(OuraIBI(ringTimestamp = 10, ibiMs = 833)),
                OuraEvent.Ibi(OuraIBI(ringTimestamp = 11, ibiMs = 820)),
            ),
            anchor,
        )
        assertEquals(listOf(72), s.hr.map { it.bpm })
        assertEquals(listOf(base + 10), s.hr.map { it.ts })
        assertEquals(listOf(833, 820), s.rr.map { it.rrMs })
        assertEquals(listOf(base + 10, base + 11), s.rr.map { it.ts })
    }

    @Test
    fun hrvBecomesOuraHrvEventWithHrAndRmssd() {
        val s = OuraStreamMapping.streams(
            listOf(OuraEvent.Hrv(OuraHRV(ringTimestamp = 5, index = 0, hrBpm = 52, rmssdMs = 47))),
            anchor,
        )
        assertEquals(1, s.events.size)
        val ev = s.events.first()
        assertEquals(OuraStreamMapping.EVENT_HRV, ev.kind)
        assertEquals("OURA_HRV", ev.kind)
        // #1167: a 1-pair record's single bucket is the span [ts-300, ts) — its five minutes END at the
        // record time, so it is stamped 300 s before it.
        assertEquals(base + 5 - 300, ev.ts)
        // Layout pinned (u8 bpm, u8 ms) → honestly labelled fields; keys/values match the Swift twin.
        assertEquals(0, ev.payload["pair_index"])
        assertEquals(52, ev.payload["hr_bpm"])
        assertEquals(47, ev.payload["rmssd_ms"])
    }

    // Each 5-min bucket must land on its OWN timestamp: the event key is (deviceId, ts, kind), so pairs
    // sharing the record ts would collide on insert and only one survive. #1167: the record's FIRST pair
    // is its OLDEST bucket and the record ts marks the END of the covered span, so pair `index` sits
    // (count - index) * 300 s before it and the LAST pair's five minutes end exactly at the record time.
    // Twin of the Swift OuraStreamMapping test.
    @Test
    fun hrvMultiBucketGetsDistinctFiveMinTimestamps() {
        val s = OuraStreamMapping.streams(
            listOf(
                OuraEvent.Hrv(OuraHRV(ringTimestamp = 5, index = 0, hrBpm = 52, rmssdMs = 47, count = 3)),
                OuraEvent.Hrv(OuraHRV(ringTimestamp = 5, index = 1, hrBpm = 54, rmssdMs = 44, count = 3)),
                OuraEvent.Hrv(OuraHRV(ringTimestamp = 5, index = 2, hrBpm = 55, rmssdMs = 41, count = 3)),
            ),
            anchor,
        )
        assertEquals(3, s.events.size)
        // Distinct, 300 s apart, ascending in time, ending at the record time.
        assertEquals(listOf(base + 5 - 900, base + 5 - 600, base + 5 - 300), s.events.map { it.ts })
        assertEquals(3, s.events.map { it.ts }.toSet().size)
        assertEquals(listOf(0, 1, 2), s.events.map { it.payload["pair_index"] })
        assertEquals(listOf(52, 54, 55), s.events.map { it.payload["hr_bpm"] })
        assertEquals(listOf(47, 44, 41), s.events.map { it.payload["rmssd_ms"] })
    }

    // #1167 + #1131 together: a dropped `00 00` pad must still be COUNTED, or every surviving bucket in
    // that record slides. The record had 4 pairs and the decoder dropped index 1, so the survivors keep
    // the exact slots they would have had with the pad present — a 300 s hole at ts-600, NOT three buckets
    // closing up. This is the mid-record shape observed in the field on 2026-08-08. Twin of Swift.
    @Test
    fun hrvDroppedPaddingPairStillConsumesItsSlot() {
        val s = OuraStreamMapping.streams(
            listOf(
                OuraEvent.Hrv(OuraHRV(ringTimestamp = 5, index = 0, hrBpm = 52, rmssdMs = 47, count = 4)),
                // index 1 was the `00 00` pad — never emitted by the decoder.
                OuraEvent.Hrv(OuraHRV(ringTimestamp = 5, index = 2, hrBpm = 55, rmssdMs = 41, count = 4)),
                OuraEvent.Hrv(OuraHRV(ringTimestamp = 5, index = 3, hrBpm = 56, rmssdMs = 39, count = 4)),
            ),
            anchor,
        )
        assertEquals(listOf(base + 5 - 1200, base + 5 - 600, base + 5 - 300), s.events.map { it.ts })
        assertEquals(listOf(0, 2, 3), s.events.map { it.payload["pair_index"] })
    }

    @Test
    fun motionBecomesOuraMotionEvent() {
        val s = OuraStreamMapping.streams(
            listOf(OuraEvent.MotionVectorEvent(OuraMotionEvent(
                ringTimestamp = 5, orientation = 5, motionSeconds = 21,
                avgX = -96, avgY = 0, avgZ = -1024, lowIntensity = 42, highIntensity = 63))),
            anchor,
        )
        assertEquals(1, s.events.size)
        val ev = s.events.first()
        assertEquals(OuraStreamMapping.EVENT_MOTION, ev.kind)
        assertEquals("OURA_MOTION", ev.kind)
        assertEquals(base + 5, ev.ts)
        // Keys/values must match the Swift twin exactly.
        assertEquals(5, ev.payload["orientation"])
        assertEquals(21, ev.payload["motion_seconds"])
        assertEquals(-96, ev.payload["x"])
        assertEquals(0, ev.payload["y"])
        assertEquals(-1024, ev.payload["z"])
        assertEquals(42, ev.payload["low_intensity"])
        assertEquals(63, ev.payload["high_intensity"])
    }

    @Test
    fun motionShortRecordOmitsIntensityKeys() {
        val s = OuraStreamMapping.streams(
            listOf(OuraEvent.MotionVectorEvent(OuraMotionEvent(
                ringTimestamp = 5, orientation = 1, motionSeconds = 0,
                avgX = 80, avgY = 0, avgZ = 0, lowIntensity = null, highIntensity = null))),
            anchor,
        )
        val ev = s.events.first()
        assertEquals(0, ev.payload["motion_seconds"])
        assertTrue("absent intensity must not be faked", !ev.payload.containsKey("low_intensity"))
        assertTrue("absent intensity must not be faked", !ev.payload.containsKey("high_intensity"))
    }

    @Test
    fun sleepPhaseBecomesOuraSleepPhaseEvent() {
        val s = OuraStreamMapping.streams(
            listOf(
                OuraEvent.SleepPhaseEvent(OuraSleepPhase(ringTimestamp = 2, index = 0, stage = OuraSleepStage.DEEP)),
                OuraEvent.SleepPhaseEvent(OuraSleepPhase(ringTimestamp = 3, index = 1, stage = OuraSleepStage.REM)),
            ),
            anchor,
        )
        assertEquals(2, s.events.size)
        val deep = s.events[0]
        assertEquals(OuraStreamMapping.EVENT_SLEEP_PHASE, deep.kind)
        assertEquals("OURA_SLEEP_PHASE", deep.kind)
        assertEquals(0, deep.payload["phase"])           // OuraSleepStage.DEEP.raw == 0 (open_oura validated)
        assertEquals(0, deep.payload["index"])
        assertEquals(2, s.events[1].payload["phase"])     // REM.raw == 2 (open_oura validated)
        // PARITY: the payload is exactly { phase, index } - the Swift twin emits no phase_name, so neither
        // does Kotlin. Pin it so a re-added phase_name key breaks this test.
        assertNull(deep.payload["phase_name"])
    }

    @Test
    fun spo2UsesSingleChannelIrStaysZero() {
        val s = OuraStreamMapping.streams(
            listOf(OuraEvent.Spo2(OuraSpO2(ringTimestamp = 1, value = 97))),
            anchor,
        )
        assertEquals(1, s.spo2.size)
        assertEquals(97, s.spo2.first().red)
        assertEquals(0, s.spo2.first().ir) // unread channel, never a fabricated second reading
        // Single-sample records (count == 1) keep the record's own second, exactly as before #1070.
        assertEquals(base + 1, s.spo2.first().ts)
    }

    // #1070: `spo2Sample` is keyed (deviceId, ts). A 0x6F record's 13 per-second samples used to be
    // written at the record's single `ts`, so twelve collided away on insert and the night was stored at
    // 1/13 resolution — permanently, since the ring trims its banked history once the offload is acked.
    // Swift twin: OuraStreamMappingTests.testSpO2PerSampleRecordGetsThirteenDistinctSeconds. The seconds
    // asserted here are IDENTICAL to the ones the Swift test asserts (parity contract).
    @Test
    fun spo2PerSampleRecordGetsThirteenDistinctSeconds() {
        val n = 13
        val events = (0 until n).map {
            OuraEvent.Spo2(OuraSpO2(ringTimestamp = 100, value = 950 + it, unit = "raw", index = it, count = n))
        }
        val s = OuraStreamMapping.streams(events, anchor)

        assertEquals(n, s.spo2.size)
        // Thirteen DISTINCT seconds: nothing can collide on the primary key.
        assertEquals(n, s.spo2.map { it.ts }.toSet().size)
        // Laid BACKWARD at 1 s from the record anchor, so the LAST sample keeps the record's own ts.
        val recordTs = base + 100
        assertEquals(((recordTs - n + 1)..recordTs).toList(), s.spo2.map { it.ts })
        assertEquals(recordTs, s.spo2.last().ts)
        // Order is preserved, so sample i still carries sample i's value.
        assertEquals((0 until n).map { 950 + it }, s.spo2.map { it.red })
    }

    @Test
    fun spo2AdjacentRecordsTileAtTheNominalCadence() {
        // Packets arrive ~13 s apart carrying 13 values, so back-laying tiles the interval exactly:
        // at the NOMINAL cadence consecutive records produce a gapless, non-overlapping series.
        // The tight tail is covered separately below.
        val n = 13
        fun secondsFor(ringTs: Long): List<Int> = OuraStreamMapping.streams(
            (0 until n).map {
                OuraEvent.Spo2(OuraSpO2(ringTimestamp = ringTs, value = 950, unit = "raw", index = it, count = n))
            },
            anchor,
        ).spo2.map { it.ts }

        val a = secondsFor(100)
        val b = secondsFor(113)
        assertTrue(a.toSet().intersect(b.toSet()).isEmpty())
        assertEquals(((base + 100 - n + 1)..(base + 113)).toList(), a + b)
    }

    @Test
    fun spo2TightCadenceOverlapsByExactlyOneSecond() {
        // The cadence has a tight tail (p10 12 s). Back-laying 13 samples from a record only 12 s after
        // the previous one makes the newer record's FIRST second equal the older record's LAST — one
        // sample lost at that boundary on the (deviceId, ts) key. That is bounded and expected, not a
        // regression: measured over a real overnight it costs 0.84 % of samples, against 92.3 % before.
        // Pins the bound at ONE second so a future change to the lay cannot widen it silently.
        // PARITY: the Swift twin asserts the IDENTICAL overlap.
        val n = 13
        fun secondsFor(ringTs: Long): List<Int> = OuraStreamMapping.streams(
            (0 until n).map {
                OuraEvent.Spo2(OuraSpO2(ringTimestamp = ringTs, value = 950, unit = "raw", index = it, count = n))
            },
            anchor,
        ).spo2.map { it.ts }

        val a = secondsFor(100)
        val b = secondsFor(112)
        assertEquals(setOf(base + 100), a.toSet().intersect(b.toSet()))
        assertEquals(2 * n - 1, a.toSet().union(b.toSet()).size)
    }

    @Test
    fun tempPersistsAsHundredthsOfDegree() {
        val s = OuraStreamMapping.streams(
            listOf(OuraEvent.Temp(OuraTemp(ringTimestamp = 4, celsius = 33.27))),
            anchor,
        )
        assertEquals(1, s.skinTemp.size)
        assertEquals(3327, s.skinTemp.first().raw)
        assertEquals(base + 4, s.skinTemp.first().ts)
    }

    @Test
    fun unanchoredSamplesAreDroppedNotFaked() {
        // anchor returns null for ring time 99 -> that sample must be dropped, others kept.
        val partial: (Long) -> Int? = { rt -> if (rt == 99L) null else base + rt.toInt() }
        val s = OuraStreamMapping.streams(
            listOf(
                OuraEvent.Hr(OuraHR(ringTimestamp = 99, bpm = 60, ibiMs = 1000)),
                OuraEvent.Hr(OuraHR(ringTimestamp = 1, bpm = 61, ibiMs = 980)),
            ),
            partial,
        )
        assertEquals(listOf(61), s.hr.map { it.bpm })
    }

    @Test
    fun batteryIsNotPersistedAsAStreamRow() {
        // Battery has no ring timestamp; it flows via the live onBattery path, never a faked-ts row.
        val s = OuraStreamMapping.streams(
            listOf(OuraEvent.Battery(com.noop.oura.OuraBattery(percent = 88))),
            anchor,
        )
        assertTrue(s.battery.isEmpty())
        assertTrue(s.hr.isEmpty())
    }

    // --- Batching a record's events into one persist (#1072, root cause for #823) ---

    /**
     * The defect's shape: [assignRrSeq]'s `ord` counter is batch-local, so a record's beats only get a
     * real emission order if they reach the store TOGETHER. Grouping is by the resolved second, and the
     * `ord` values it produces are asserted end-to-end here. Twin of the Swift
     * `testBatchedGroupsOneRecordsBeatsIntoASingleBatch`.
     */
    @Test
    fun batchedGroupsOneRecordsBeatsIntoASinglePersist() {
        val beats = listOf(812, 795, 840, 801, 833)
        val stamped = beats.map { ms ->
            OuraEvent.Ibi(OuraIBI(ringTimestamp = 10, ibiMs = ms)) as OuraEvent to base + 10
        }
        val batches = OuraStreamMapping.batched(stamped)
        assertEquals("one record's beats must be ONE batch, not five", 1, batches.size)
        assertEquals(base + 10, batches[0].first)

        // Through the production widening (StreamPersistence.toBatch) so the ord assertion is on the
        // rows the DAO actually inserts.
        val rr = StreamPersistence.toBatch(OuraStreamMapping.streams(batches[0].second) { base + 10 }).rr
        assertEquals(beats, rr.map { it.rrMs })
        // ord is what the whole change exists for: emission order, not 0 on every row.
        assertEquals(listOf(0, 1, 2, 3, 4), assignRrSeq("ring", rr).map { it.ord })
    }

    /** The pre-fix shape, pinned so it cannot come back: one beat per persist can only ever write 0. */
    @Test
    fun onePersistPerBeatRecordsNoOrder() {
        val ords = listOf(812, 795, 840).map { ms ->
            assignRrSeq("ring", listOf(RrRow(base.toLong(), ms))).single().ord
        }
        assertEquals(listOf(0, 0, 0), ords)
    }

    /** Distinct seconds stay distinct batches, in arrival order — `ord` numbers within a second. */
    @Test
    fun batchedKeepsDistinctTimestampsSeparateAndInArrivalOrder() {
        val batches = OuraStreamMapping.batched(
            listOf(
                OuraEvent.Ibi(OuraIBI(ringTimestamp = 13, ibiMs = 800)) as OuraEvent to base + 13,
                OuraEvent.Ibi(OuraIBI(ringTimestamp = 13, ibiMs = 810)) as OuraEvent to base + 13,
                OuraEvent.Ibi(OuraIBI(ringTimestamp = 10, ibiMs = 900)) as OuraEvent to base + 10,
            ),
        )
        assertEquals(listOf(base + 13, base + 10), batches.map { it.first })
        assertEquals(listOf(2, 1), batches.map { it.second.size })
    }

    /** Interleaved same-second events fold into one batch, relative order preserved. */
    @Test
    fun batchedFoldsInterleavedSameSecondEventsIntoOneBatch() {
        val batches = OuraStreamMapping.batched(
            listOf(
                OuraEvent.Ibi(OuraIBI(ringTimestamp = 10, ibiMs = 800)) as OuraEvent to base + 10,
                OuraEvent.Ibi(OuraIBI(ringTimestamp = 11, ibiMs = 900)) as OuraEvent to base + 11,
                OuraEvent.Ibi(OuraIBI(ringTimestamp = 10, ibiMs = 810)) as OuraEvent to base + 10,
            ),
        )
        assertEquals(2, batches.size)
        assertEquals(
            listOf(800, 810),
            OuraStreamMapping.streams(batches[0].second) { base + 10 }.rr.map { it.rrMs },
        )
    }

    @Test
    fun batchedOnEmptyInputYieldsNoBatches() {
        assertTrue(OuraStreamMapping.batched(emptyList()).isEmpty())
    }

    @Test
    fun tierBAndActivityInfoNeverMapToAStream() {
        // HONEST-DATA INVARIANT (PR #960): Tier-B raw summaries AND the decoded-but-unvalidated 0x50
        // activity/MET events must never produce a durable stream row (in particular no step count is
        // ever minted from MET - it is not one), exactly like the Swift twin's drop test.
        val s = OuraStreamMapping.streams(
            listOf(
                OuraEvent.TierB(
                    com.noop.oura.OuraTierBSummary(
                        tag = 0x7E, ringTimestamp = 100, rawPayload = intArrayOf(1, 2, 3),
                        kind = "real_steps",
                    ),
                ),
                OuraEvent.ActivityInfo(
                    com.noop.oura.OuraActivityInfo(ringTimestamp = 100, state = 0x41, met = listOf(1.8, 1.9)),
                ),
            ),
            anchor,
        )
        assertTrue(s.hr.isEmpty())
        assertTrue(s.rr.isEmpty())
        assertTrue(s.events.isEmpty())
        assertTrue(s.battery.isEmpty())
        assertTrue(s.spo2.isEmpty())
        assertTrue(s.skinTemp.isEmpty())
    }
}
