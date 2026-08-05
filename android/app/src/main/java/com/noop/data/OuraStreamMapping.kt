package com.noop.data

import com.noop.oura.OuraEvent
import com.noop.oura.OuraIbiChannel
import com.noop.protocol.RrSourceChannel
import com.noop.protocol.SkinTempSample
import com.noop.protocol.Spo2Sample
import com.noop.protocol.Streams
import com.noop.protocol.WhoopEvent

/**
 * Pure, JVM-testable mapping from the Oura ring's decoded [OuraEvent]s onto the datastore's
 * protocol [Streams] shape, so the WHOOP-isolated `OuraLiveSource` can persist its samples through
 * the SAME [WhoopRepository.insert] path (via [StreamPersistence.toBatch]) the WHOOP pipeline uses,
 * without duplicating row construction in the (untestable) app/BLE target. Kotlin twin of the Swift
 * `OuraStreamMapping` (WhoopStore), built from the architecture plan's section-4 table.
 *
 * HONEST-DATA INVARIANT (hard): we surface ONLY the ring's decoded raw signals and its OWN open
 * event tags. We never read or display Oura's encrypted readiness/sleep scores. NOOP computes its
 * own Charge/Rest downstream:
 *   - the IBI stream becomes [Streams.rr], from which RecoveryScorer reconstructs NOOP's OWN RMSSD;
 *   - the HR stream feeds resting-HR + strain;
 *   - the ring's open 0x5D HRV tag is recorded as an `OURA_HRV` diagnostic event carrying ITS RAW
 *     decoded fields (time_ms/b1/b2) ONLY, never a fabricated rmssd_ms (the int8 b1/b2 byte->ms
 *     scale is not Tier-A; NOOP's scoring RMSSD comes from `rr`, not this tag);
 *   - the open sleep-phase tags become `OURA_SLEEP_PHASE` events folded into a sleep session.
 *
 * Each event carries a ring-clock `ringTimestamp` (not wall-clock). To stay pure and avoid baking a
 * clock model in here, the caller supplies an [anchor] resolving a ring timestamp to wall-clock unix
 * seconds (driven by the ring's 0x42/0x85 time-sync events upstream). When the anchor cannot place a
 * record (anchor returns null), the sample is DROPPED rather than stamped with a guessed time
 * (honest-data invariant), a ts-less biometric row is unstorable anyway.
 */
object OuraStreamMapping {

    /** The event `kind` recorded for the ring's own open HRV (0x5D) tag. Must match Swift exactly. */
    const val EVENT_HRV = "OURA_HRV"

    /** The event `kind` recorded for the ring's own open sleep-phase (0x49.../0x58) tags. */
    const val EVENT_SLEEP_PHASE = "OURA_SLEEP_PHASE"

    /** The event `kind` for a decoded 0x47 motion window (activity instrumentation). Must match Swift. */
    const val EVENT_MOTION = "OURA_MOTION"

    /**
     * Fold a batch of decoded [events] into a protocol [Streams] for one flush. [anchor] maps a
     * ring-clock timestamp to wall-clock unix seconds (null => drop the sample). Pure: no BLE, no DB,
     * no clock, fully JVM-unit-testable. Tier-B events never reach scoring; if any leak in (they only
     * appear when the driver's allowTierB is set), they are ignored here so they cannot fabricate a
     * stream value.
     */
    fun streams(events: List<OuraEvent>, anchor: (Long) -> Int?): Streams {
        val out = Streams()
        for (ev in events) {
            when (ev) {
                is OuraEvent.Hr -> {
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    out.hr.add(com.noop.protocol.HrSample(ts, ev.value.bpm))
                }

                is OuraEvent.Ibi -> {
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    // Carry the decoder's OWN channel tag onto the durable row (#1071). The ring reports
                    // the same heartbeats on more than one tag — 0x80 green-quality all night, 0x6E only
                    // while an SpO2 measurement runs — and both decode to Ibi, so an untagged store held
                    // roughly TWO complete copies of every night (measured 2.06x beats and 2.17x
                    // sum(rrMs)/wall-clock over one 488-min window). Both rows are real measurements, so
                    // neither is dropped here; the scoring READ (WhoopDao.rrIntervals) picks one channel
                    // and the other stays on disk as its cross-check. Null stays null — never a guess.
                    // Mirrors the Swift OuraStreamMapping twin.
                    out.rr.add(
                        com.noop.protocol.RrInterval(ts, ev.value.ibiMs, rrChannel(ev.value.channel)),
                    )
                }

                is OuraEvent.Hrv -> {
                    // The ring's OWN open HRV tag, recorded raw for diagnostics/parity. NOT Oura's
                    // readiness score, and NOT used as NOOP's RMSSD (that comes from `rr`).
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    out.events.add(
                        WhoopEvent(
                            ts = ts,
                            kind = EVENT_HRV,
                            payload = linkedMapOf(
                                "time_ms" to ev.value.timeMs,
                                "b1" to ev.value.b1,
                                "b2" to ev.value.b2,
                            ),
                        ),
                    )
                }

                is OuraEvent.Spo2 -> {
                    // The ring exposes ONE combined SpO2 reading (not separate red/ir channels): its
                    // raw value goes in `red`; `ir` stays 0 (an unread channel, never a fabricated
                    // second reading). `unit` carries the decoder's own scale tag so downstream never
                    // assumes a percentage, mirroring the Swift twin's SpO2Sample(unit:).
                    //
                    // Each sample gets its OWN second. `spo2Sample` is keyed (deviceId, ts), so the 13
                    // samples of one 0x6F record written at the record's single `ts` collided and only the
                    // first survived — 92% of an overnight silently discarded, and unrecoverable because
                    // the ring trims its banked history once the offload is acked (#1070). The samples are
                    // one per second (measured: 13 values per packet at a 13 s median packet interval,
                    // p10 12 / p90 14, so they tile the interval at exactly 1 Hz), and they are laid
                    // BACKWARD from the record time — the record envelope marks the WRITE moment, so the
                    // LAST sample keeps the record's own `ts` and the anchor semantics are unchanged.
                    // `count == 1` (0x7B, and any single-sample record) yields offset 0, i.e. exactly the
                    // previous behaviour. PARITY: the Swift twin computes the IDENTICAL second.
                    //
                    // This is collision-RARE, not collision-proof. The cadence has a tight tail (p10 12 s),
                    // and a 12 s gap between two 13-sample records makes the newer record's FIRST second
                    // equal the older record's last, costing one sample at that boundary. Measured over the
                    // same overnight: 204 of 1,877 adjacent pairs overlap, by exactly 1 s each, so 204 of
                    // 24,405 samples (0.84 %) are lost — against 92.3 % before. The insert ignores the
                    // conflict rather than replacing, so the survivor is the older record's last sample,
                    // which is the anchor-exact one; what is dropped is the newer record's most
                    // back-extrapolated sample. Keeping both would need sub-second timestamps, and the row
                    // key is seconds.
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    val sampleTs = ts - maxOf(0, ev.value.count - 1 - ev.value.index)
                    out.spo2.add(Spo2Sample(ts = sampleTs, red = ev.value.value, ir = 0, unit = ev.value.unit))
                }

                is OuraEvent.Temp -> {
                    // The ring exposes skin temperature in degrees C; the store's raw integer uses the
                    // codebase-wide CENTI-degree-C convention (°C = raw / 100, the scale the analytics
                    // reader divides by), so persist celsius * 100 and tag the unit. PARITY: the Swift
                    // twin stores the IDENTICAL celsius * 100, so the same decoded celsius yields the same
                    // raw integer on both platforms.
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    out.skinTemp.add(
                        SkinTempSample(
                            ts = ts,
                            raw = Math.round(ev.value.celsius * 100.0).toInt(),
                            unit = "centi_c",
                        ),
                    )
                }

                is OuraEvent.SleepPhaseEvent -> {
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    out.events.add(
                        WhoopEvent(
                            ts = ts,
                            kind = EVENT_SLEEP_PHASE,
                            payload = linkedMapOf<String, Any?>(
                                "phase" to ev.value.stage.raw,
                                "index" to ev.value.index,
                            ),
                        ),
                    )
                }

                is OuraEvent.Battery -> {
                    // Live battery percent. No ring timestamp on a battery reading (it is a command
                    // response), so it is stamped by the live source's `onBattery` path, not persisted
                    // as a tied-to-ts row here. Leave the batch's battery list empty (honest: no faked ts).
                }

                // 0x47 averaged accel vector (Tier-A): decoded and available, but NOT written to any
                // durable stream. This is NOT merely a "pending LSB→g scale" hold — the open question is
                // whether gravitySample is the right destination AT ALL. 0x47 is MOVEMENT-GATED (emitted
                // only while moving, validated on-device #804), so it yields NO still samples; SleepStager
                // instead needs a CONTINUOUS gravity stream (≥70% of a rolling 15-min window with
                // per-sample delta < 0.01 g, a >20-min gap breaks the run). Missing samples are not still
                // samples, so feeding 0x47 into gravity is a SHAPE MISMATCH, not an unscaled one, and
                // synthesising still samples to fill the gaps would be inventing data. The usable signal is
                // motion_seconds / intensity as an ACTIVITY input on a separate path (#804 option B). Held
                // here until that path lands. Dropped, not faked. Mirrors the Swift twin.
                is OuraEvent.MotionVectorEvent -> {
                    // 0x47 motion window → an OURA_MOTION event: the ring's OWN per-window motion summary
                    // (orientation / motion_seconds / x / y / z / low_/high_intensity). INSTRUMENTATION only
                    // — an honest activity signal, never scored and never fed to the sleep stager (0x47 is
                    // movement-gated, a shape mismatch for the gravity-stillness stager, #804). Rides the SAME
                    // event-table path as OURA_HRV / OURA_SLEEP_PHASE, one row per window at its own anchored
                    // ts. Keys IDENTICAL to the Swift twin; low_/high_intensity omitted on a short record.
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    val m = ev.value
                    val payload = linkedMapOf<String, Any?>(
                        "orientation" to m.orientation,
                        "motion_seconds" to m.motionSeconds,
                        "x" to m.avgX, "y" to m.avgY, "z" to m.avgZ,
                    )
                    m.lowIntensity?.let { payload["low_intensity"] = it }
                    m.highIntensity?.let { payload["high_intensity"] = it }
                    out.events.add(WhoopEvent(ts = ts, kind = EVENT_MOTION, payload = payload))
                }

                // Motion / state / time-sync / rtc / debug / TierB / ActivityInfo never map onto a
                // scored stream. In particular the 0x50 activity/MET decode (PR #960) NEVER mints a
                // `steps` row: the formula is third-party and unvalidated (Tier B, OURA_PROTOCOL.md
                // s6.13), and MET is not a step count - fabricating one would break the honest-data
                // invariant and the per-source day-owner rules.
                else -> Unit
            }
        }
        return out
    }

    /**
     * Group already-stamped events into ONE batch per timestamp, keeping the order they arrived in (and
     * the first-appearance order of the timestamps themselves). Pure → JVM-unit-testable. Swift twin:
     * `OuraStreamMapping.batched(_:)`.
     *
     * This exists because [com.noop.data.assignRrSeq]'s `seq` / `ord` counters are **batch-local by
     * design**: `ord` is a beat's position among the beats that share its second *within one persist*,
     * which is the only place emission order is still known (v30, #823). A transport that hands the
     * store one event per persist therefore restarts the counter on every beat and writes `ord = 0` on
     * every row — measured on a real database as 575,630 of 575,630 rows (#1072). With `ord` tied the
     * read falls through to `(rrMs, seq)`, i.e. a second's beats come back sorted by VALUE, and RMSSD —
     * built entirely from successive differences — is biased down by construction.
     *
     * One record's beats all carry that record's own ring time, so grouping by the resolved timestamp is
     * what hands the store a record's beats together. Order is the only property callers may rely on.
     */
    fun batched(stamped: List<Pair<OuraEvent, Int>>): List<Pair<Int, List<OuraEvent>>> {
        val byTs = LinkedHashMap<Int, MutableList<OuraEvent>>()
        for ((event, ts) in stamped) byTs.getOrPut(ts) { mutableListOf() }.add(event)
        return byTs.map { (ts, events) -> ts to events.toList() }
    }

    /**
     * Translate the protocol layer's [OuraIbiChannel] to the store's [RrSourceChannel] (#1071).
     *
     * Two enums rather than one because `com.noop.oura` is the pure ring decoder and does not depend on
     * the storage carriers — the same split the Swift twin has between `OuraProtocol` and
     * `WhoopProtocol`. They pin the SAME [OuraIbiChannel.code] / [RrSourceChannel.code] values, and the
     * mapping is written out case by case rather than as `fromCode(c.code)` so that adding a case on one
     * side without the other is a COMPILE error instead of a silent null. Internal for the parity test.
     */
    internal fun rrChannel(c: OuraIbiChannel?): RrSourceChannel? = when (c) {
        OuraIbiChannel.GREEN_QUALITY -> RrSourceChannel.GREEN_QUALITY
        OuraIbiChannel.SPO2_IBI -> RrSourceChannel.SPO2_IBI
        OuraIbiChannel.IBI_AMPLITUDE -> RrSourceChannel.IBI_AMPLITUDE
        null -> null
    }
}
