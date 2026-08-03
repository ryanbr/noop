package com.noop.data

import android.content.Context
import com.noop.protocol.DroppedRtcEvent
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlin.math.roundToInt

/**
 * Decoded streams to persist in one transaction. Android mirror of the Swift `Streams`
 * struct (Packages/WhoopProtocol/Sources/WhoopProtocol/Streams.swift) carrying the rows
 * for a single flush/backfill chunk. All `ts` values are wall-clock unix seconds (Long).
 *
 * The protocol/decoder layer builds one of these (deviceId stamped at insert time, not
 * stored on the per-row sample models , it is supplied to [WhoopRepository.insert]).
 */
data class StreamBatch(
    val hr: List<HrRow> = emptyList(),
    val rr: List<RrRow> = emptyList(),
    val events: List<EventEntry> = emptyList(),
    val battery: List<BatteryRow> = emptyList(),
    val spo2: List<Spo2Row> = emptyList(),
    val skinTemp: List<SkinTempRow> = emptyList(),
    val resp: List<RespRow> = emptyList(),
    val gravity: List<GravityRow> = emptyList(),
    val steps: List<StepRow> = emptyList(),
    /**
     * The strap's OWN band sleep_state per record (#175), carried verbatim off @81's high nibble. Optional
     * signal (only 5/MG v18 records emit it; a WHOOP 4.0 leaves it empty), consumed by the H7 re-onset
     * CONFIRM guard and shown as a Deep Timeline track. Never overrides the derived stage.
     */
    val sleepState: List<SleepStateRow> = emptyList(),
    /** HR derived from the WHOOP 5/MG v26 optical PPG waveform (autocorrelation). (#156) */
    val ppgHr: List<PpgHrRow> = emptyList(),
    /**
     * The RAW WHOOP 5/MG v26 optical PPG waveform itself, one record per second (#156 follow-up) — the
     * 24 Hz samples [ppgHr] is derived FROM. Kept separate so a consumer that only wants the HR estimate
     * never pays for the 24x-larger raw stream. Persisted into `ppgWaveformSample` as a packed i16 BLOB.
     */
    val ppgWaveform: List<PpgWaveformRow> = emptyList(),
    /**
     * Every remaining 5/MG v18 per-second field the decoder produces and the extractor used to discard —
     * carried verbatim for a later census. Empty on a WHOOP 4.0 and on the live path. Nothing reads it.
     */
    val v18Aux: List<V18AuxRow> = emptyList(),
    /**
     * #547: how many historical records this batch DROPPED because their timestamp was implausible
     * (older than 2023-11 or more than a day ahead of now) , a bad strap clock/flash artefact. A
     * diagnostic counter only, NOT decoded data, so it is deliberately excluded from [isEmpty]. The
     * Backfiller surfaces it once per session via its existing strap-log seam so a bad-clock strap is
     * visible in a shared log. Defaulted so every existing constructor/copy call site is unchanged.
     */
    val droppedImplausibleTs: Int = 0,
    /**
     * #324 diagnostic: the OLDEST / NEWEST own-timestamp (unix seconds, the strap's OWN dated value) among
     * records dropped this batch for an implausible ts. Lets the Backfiller log the epoch SPAN of a bad-clock
     * strap's poisoned range, so a whole-range-future strap can be told from one mixed with real data. Diag
     * only (excluded from [isEmpty]); null when nothing dropped. Mirrors Swift `Streams.droppedImplausible*Ts`.
     */
    val droppedImplausibleOldestTs: Long? = null,
    val droppedImplausibleNewestTs: Long? = null,
    /**
     * #324 diagnostic: strap RTC-STATE events (RTC_LOST / BOOT / SET_RTC) dropped for an implausible own-ts.
     * The #547 gate discards them like any bad-ts record, but they are the GROUND TRUTH that the clock reset,
     * so they are captured here for the strap log. Diag only; empty when none. Mirrors Swift `droppedRtcEvents`.
     */
    val droppedRtcEvents: List<DroppedRtcEvent> = emptyList(),
    /**
     * #891 diagnostic: packet types this batch carried that the decoder has no `when` branch for, keyed by
     * the rendered type name (a byte no enum names renders `type53`), value = record count.
     *
     * The decode loop handles four of the schema's sixteen packet types and drops the rest at `else -> Unit`,
     * and `rejectedHistoricalRecords` archives only type-47 — non-47 frames are excluded from it by
     * construction. So a record type nobody has mapped was dropped twice and counted zero times, and the sync
     * reported clean. `HISTORICAL_IMU_DATA_STREAM(52)` is a banked raw-stream type the schema already names
     * and this funnel does not handle; every one would vanish.
     *
     * METADATA and CONSOLE_LOGS are excluded ([EXPECTED_UNHANDLED_HISTORICAL_TYPES]) — an offload legitimately
     * carries both and they decode to zero rows by design, so counting them would bury the signal. Diag only
     * (excluded from [isEmpty]); empty when nothing fell through. Mirrors Swift `Streams.unhandledPacketTypes`.
     */
    val unhandledPacketTypes: Map<String, Int> = emptyMap(),
    /**
     * #520 diagnostic: a summary of `dynamic_acceleration@41` (the strap's own gravity-removed motion
     * magnitude) over this batch's v18 records. The field has been decoded on both platforms all along
     * with nothing consuming it, so there is no evidence on whether it is a usable stillness signal;
     * this counts what arrived so the strap log can answer that from real nights before anyone pays for
     * a migration. Diag only (excluded from [isEmpty]). Byte-identical twin of Swift `Streams.dynAccel`.
     */
    val dynAccel: DynAccelDiag = DynAccelDiag(),
) {
    // [v18Aux] counts here, and it is load-bearing rather than cosmetic: `insert` early-returns on
    // `isEmpty`, so a batch carrying ONLY aux rows would silently bank nothing. Swift's `Streams.isEmpty`
    // lists it too — the two must agree or the same offload drops rows on one platform only.
    val isEmpty: Boolean
        get() = hr.isEmpty() && rr.isEmpty() && events.isEmpty() && battery.isEmpty() &&
            spo2.isEmpty() && skinTemp.isEmpty() && resp.isEmpty() && gravity.isEmpty() &&
            steps.isEmpty() && sleepState.isEmpty() && ppgHr.isEmpty() && ppgWaveform.isEmpty() &&
            v18Aux.isEmpty()
}

/**
 * #520 diagnostic: distribution of `dynamic_acceleration` over one decoded batch. Deliberately a
 * summary, not a stream — at 1 Hz a night is ~30k values and the open question needs a shape, not
 * samples. [still] counts values under `SleepStager.gravityStillThresholdG` (0.01 g) — borrowed as a
 * REFERENCE CUT, not because the two quantities are the same thing. The stager thresholds a per-sample
 * DELTA (how much the gravity vector moved between consecutive samples); this field is an ABSOLUTE
 * gravity-removed magnitude at one instant. Both go to ~0 when the wrist is still, so the same cut is a
 * sensible starting point, but the two still-fractions are not measuring the same thing and a match does
 * not prove equivalence. [min]/[max]/[mean] let a reader re-derive any other cut from the logs.
 * Byte-identical twin of Swift `Streams.DynAccelDiag` — same fields, same fold order, same nulls.
 */
data class DynAccelDiag(
    var count: Int = 0,
    var still: Int = 0,
    var min: Double? = null,
    var max: Double? = null,
    /** Running sum, so a batch of any size costs O(1) memory. */
    var sum: Double = 0.0,
) {
    /** Mean over [count] values, or null when nothing arrived. */
    val mean: Double? get() = if (count > 0) sum / count else null

    /** Fraction of values below the stillness threshold, or null when nothing arrived. */
    val stillFraction: Double? get() = if (count > 0) still.toDouble() / count else null

    /**
     * Fold another batch's summary into this one. A batch is an arbitrary slice of an offload, so the
     * still-fraction only means anything once a whole session is merged — the Backfiller accumulates with
     * this and logs once at the session boundary. Merging an empty diag is a no-op. Twin of Swift.
     */
    fun merge(other: DynAccelDiag) {
        if (other.count <= 0) return
        count += other.count
        still += other.still
        sum += other.sum
        other.min?.let { lo -> min = min?.let { kotlin.math.min(it, lo) } ?: lo }
        other.max?.let { hi -> max = max?.let { kotlin.math.max(it, hi) } ?: hi }
    }

    /**
     * The strap-log line for a whole offload session, or null when nothing arrived (so a WHOOP 4.0 or a
     * caught-up session stays quiet). Every field is an Int rendered by interpolation — deliberately NOT
     * [String.format]. Two separate traps live in that function: the default locale renders `0,021` on a
     * de/fr device, and Java rounds HALF_UP where C (and so Swift) rounds half-to-EVEN, which makes ties
     * diverge. Integers avoid both. Byte-identical twin of Swift `DynAccelDiag.logLine`.
     */
    fun logLine(threshold: Double): String? {
        val lo = min ?: return null
        val hi = max ?: return null
        val avg = mean ?: return null
        val frac = stillFraction ?: return null
        if (count <= 0) return null
        return "Backfill: dynaccel n=$count still=${pct(frac)}% mean=${mg(avg)}mg " +
            "range=${mg(lo)}..${mg(hi)}mg (thr ${mg(threshold)}mg) " +
            "— diagnostic only, not stored or scored (#520)"
    }

    companion object {
        /**
         * Milli-g, rounded to match Swift's `.rounded()` (ties away from zero).
         *
         * [kotlin.math.roundToInt] is REQUIRED here and [kotlin.math.round] is WRONG: `round` is
         * `Math.rint`, which breaks ties toward the EVEN integer, while `roundToInt` is `Math.round`,
         * which breaks them toward positive infinity — the same answer as Swift for non-negative input.
         * With `round`, 62.5 mg would give 62 on Kotlin and 63 on Swift, which is exactly the printf
         * divergence this integer formatting exists to avoid. The decoder gates this field to `[0, 8] g`
         * so input is never negative, where the two rules would part company again.
         */
        fun mg(g: Double): Int = (g * 1000).roundToInt()

        /** Whole percent, same rounding rule and the same reason. */
        fun pct(fraction: Double): Int = (fraction * 100).roundToInt()
    }

    /**
     * Fold one decoded value in. [threshold] is passed rather than imported so the protocol layer keeps
     * no dependency on the analytics layer; the caller supplies the stager's own constant.
     */
    fun add(g: Double, threshold: Double) {
        if (!g.isFinite()) return
        count += 1
        sum += g
        if (g < threshold) still += 1
        min = min?.let { kotlin.math.min(it, g) } ?: g
        max = max?.let { kotlin.math.max(it, g) } ?: g
    }
}

// Device-agnostic decoded rows (deviceId attached when inserted). Mirror Streams.swift shapes.
data class HrRow(val ts: Long, val bpm: Int)
data class RrRow(val ts: Long, val rrMs: Int)

/**
 * Attach a tiebreaker `seq` to each R-R interval before insert (Room v18). Multiple beats share one
 * whole-second `ts`; the old PK (deviceId, ts, rrMs) + IGNORE-on-conflict silently dropped the second of
 * two EQUAL successive intervals in the same second, removing a zero-difference pair and biasing RMSSD/HRV
 * high. `seq` counts occurrences of each EQUAL (ts, rrMs) beat (0, 1, …), so both survive.
 *
 * Keying by (ts, rrMs) — not ts alone — is deliberate: DISTINCT intervals keep seq 0 and thus their own
 * (deviceId, ts, rrMs, 0) key, so a distinct beat is NEVER dropped even when same-second beats arrive in
 * SEPARATE insert batches or via the live/historical merge (an earlier ts-only index would have restarted
 * per batch and collided distinct beats — a data-loss regression). Re-syncing identical records reproduces
 * the same (ts, rrMs, seq) → the insert stays idempotent. The residual: two EQUAL beats in one second that
 * straddle a live-flush boundary still collide (batch-local), the same narrow case the old key dropped and
 * strictly no worse; the authoritative historical path delivers a second's beats atomically in one batch.
 * Pure so it is unit-testable.
 *
 * Also stamps `ord` (Room v24, #823): the beat's position among ALL beats sharing this `ts` in this batch —
 * its emission order, which `seq` cannot express because `seq` keys on (ts, rrMs) and so is 0 for every
 * DISTINCT beat in a second. `ord` is NOT in the key and never affects which rows survive; it exists so
 * reads can return beats in the order the heart produced them rather than sorted by value, which biases
 * RMSSD down. Same batch-local caveat as `seq`: a second split across two live flushes restarts `ord` at 0,
 * and ON CONFLICT DO NOTHING keeps whichever row landed first. The historical path delivers a second
 * atomically, so the authoritative copy is correctly ordered.
 */
internal fun assignRrSeq(deviceId: String, rows: List<RrRow>): List<RrInterval> {
    val seqByBeat = HashMap<Pair<Long, Int>, Int>()
    val ordByTs = HashMap<Long, Int>()
    return rows.map { row ->
        val key = row.ts to row.rrMs
        val s = seqByBeat.getOrDefault(key, 0)
        seqByBeat[key] = s + 1
        val o = ordByTs.getOrDefault(row.ts, 0)
        ordByTs[row.ts] = o + 1
        RrInterval(deviceId = deviceId, ts = row.ts, rrMs = row.rrMs, seq = s, ord = o)
    }
}

/** payloadJSON is the deterministic sorted-keys JSON for the remaining parsed fields. */
data class EventEntry(val ts: Long, val kind: String, val payloadJSON: String)
data class BatteryRow(val ts: Long, val soc: Double?, val mv: Int?, val charging: Boolean? = null)
data class Spo2Row(val ts: Long, val red: Int, val ir: Int)
/**
 * A skin-temperature reading at [ts], plus the two AUXILIARY thermal channels that ride the same 5/MG
 * v18 record ([aux1Raw] = `temp_aux_1_raw@69`, [aux2Raw] = `temp_aux_2_raw@71`).
 *
 * [raw] is the primary channel (`skin_temp_raw@73`) and is unchanged. The aux channels are signed i16
 * registers on their OWN scale — °C = value/10, NOT the primary's /100 — decoded since the v18 layout was
 * mapped and dropped at the storage boundary until now. They track the primary closely (corr ~0.92 and
 * ~0.97 over the captured corpus) with the same diurnal curve; nothing here asserts what they measure and
 * no analytic reads them. Null on a WHOOP 4.0, on a byte that failed the decoder's thermal gate, and on
 * every row banked before the channels were persisted. Swift `SkinTempSample`.
 */
data class SkinTempRow(val ts: Long, val raw: Int, val aux1Raw: Int? = null, val aux2Raw: Int? = null)
/**
 * Cumulative u16 step/motion counter at [ts] (WHOOP5 step_motion_counter@57). deviceId attached on insert. (#78)
 * [activityClass] is the per-record activity-class enum from @63 (community finding #316): 0=still, 1=walk,
 * 2=run; null when the byte was 0xFF/invalid or absent. Optional + defaulted so existing call sites and the
 * persisted store (which carries only ts/counter today) are unchanged.
 */
data class StepRow(val ts: Long, val counter: Int, val activityClass: Int? = null)
/**
 * The strap's OWN @81 high-nibble band sleep_state at [ts] (0 wake/1 still/2 asleep/3 up), decoded and
 * streamed but dropped at storage until #175. deviceId attached on insert. Swift `SleepStateSample`.
 */
data class SleepStateRow(val ts: Long, val state: Int, val rawByte: Int? = null)
data class RespRow(val ts: Long, val raw: Int)
/**
 * The 1 Hz gravity vector at [ts], plus the strap's OWN gravity-removed motion magnitude from the same
 * record ([dynAccel] = `dynamic_acceleration@41`, f32 g).
 *
 * The two are different measurements of the same second and belong together. NOOP's motion spine derives
 * its stillness signal from `gravityDeltas` — the L2 distance between CONSECUTIVE 1 Hz gravity vectors —
 * which is a proxy: it sees orientation CHANGE at 1 Hz, not acceleration. [dynAccel] is the strap's
 * absolute gravity-removed magnitude at one instant, computed on-device from the full-rate IMU. It is
 * stored BESIDE the proxy, never instead of it, and read by nothing — before this it was computed and
 * discarded one line after decode, and the strap trims its banked history as soon as an offload is acked,
 * so every second of it was lost permanently. Null on a WHOOP 4.0, outside the decoder's [0, 8] g gate,
 * and on every row banked before the column existed. Swift `GravitySample`.
 */
data class GravityRow(
    val ts: Long,
    val x: Double,
    val y: Double,
    val z: Double,
    val dynAccel: Double? = null,
)
/** HR derived from the v26 PPG waveform: [ts] window-centre sec, [bpm], [conf] in 0…1. (#156) */
data class PpgHrRow(val ts: Long, val bpm: Int, val conf: Double)
/**
 * The RAW v26 optical PPG waveform for one strap-second (#156 follow-up): [ts] the record's wall-clock
 * unix second, [samples] the raw i16 ADC counts (usually 24, fewer on a truncated frame). deviceId is
 * attached on insert; the samples are packed to a little-endian i16 BLOB by [StreamPersistence.packPpgSamples].
 */
data class PpgWaveformRow(val ts: Long, val samples: List<Int>)

/** Count of rows ACTUALLY inserted per stream (mirrors WhoopStore.insert return tuple). */
data class InsertCounts(
    val hr: Int = 0,
    val rr: Int = 0,
    val events: Int = 0,
    val battery: Int = 0,
    val spo2: Int = 0,
    val skinTemp: Int = 0,
    val steps: Int = 0,
    val resp: Int = 0,
    val gravity: Int = 0,
)

/**
 * A compact snapshot of how much history each source holds, for the Data Sources "Freshness
 * Pipeline" card (PR#196). Counts only , no per-day rows leave the read. Port of macOS
 * RepositoryFreshness.
 */
data class DataFreshness(
    val importedDays: Int = 0,
    val computedDays: Int = 0,
    val appleDays: Int = 0,
    val importedSleeps: Int = 0,
    val computedSleeps: Int = 0,
    val earliestDay: String? = null,
    val latestDay: String? = null,
) {
    val hasAnyHistory: Boolean get() = importedDays > 0 || computedDays > 0 || appleDays > 0

    companion object {
        val EMPTY = DataFreshness()
    }
}

/**
 * #547 one-time heal predicates, kept PURE (no DB) so they are unit-testable on the JVM. A bad strap
 * clock/flash (pikapik) wrote rows with implausible timestamps BEFORE the ingest gate existed; the heal
 * purges them on upgrade so a normal rescore recomputes the real days cleanly.
 *
 * Bounds mirror the ingest gate exactly: a unix-second `ts` is implausible when below
 * [com.noop.protocol.MIN_PLAUSIBLE_UNIX] (2023-11) or above now + [com.noop.protocol.FUTURE_MARGIN]
 * (one day). A computed daily `day` ("yyyy-MM-dd") is implausible when it sorts AFTER the local "today"
 * key (a future-dated day) or before the floor day. The same predicate the SQL deletes apply, exposed so
 * a test pins the boundary behaviour without Room.
 */
object HistoryHeal {
    /** True when a unix-second timestamp is outside the plausible window [min, nowSec + futureMargin]. */
    fun isImplausibleTs(
        ts: Long,
        nowSec: Long,
        minTs: Long = com.noop.protocol.MIN_PLAUSIBLE_UNIX,
        futureMargin: Long = com.noop.protocol.FUTURE_MARGIN,
    ): Boolean = ts < minTs || ts > nowSec + futureMargin

    /** True when a "yyyy-MM-dd" computed-day key is future (after [today]) or before [minDay]. ISO date
     *  strings sort lexicographically in chronological order, so a plain string compare is correct. */
    fun isImplausibleDay(day: String, today: String, minDay: String): Boolean =
        day > today || day < minDay
}

/**
 * Repository over [WhoopDatabase] / [WhoopDao]. The single seam the rest of the app uses
 * to read/write the local store. Port of WhoopStore's public surface (StreamStore.swift,
 * Reads.swift, MetricsCache.swift) , the phone does NO metric computation here; daily/sleep
 * rows are an offline cache of server-computed values.
 */
class WhoopRepository(private val dao: WhoopDao) {

    /** v18 aux rows banked since the retention sweep last ran, PER DEVICE — the sweep is per device too,
     *  so a shared counter would let one strap spend another's budget. Only the single-threaded offload
     *  path banks v18 rows, so a plain map is enough. Swift twin: `WhoopStore.v18AuxRowsSincePrune`. */
    private val v18AuxRowsSincePrune = mutableMapOf<String, Int>()

    constructor(db: WhoopDatabase) : this(db.whoopDao())

    // MARK: - Device

    suspend fun upsertDevice(id: String, mac: String? = null, name: String? = null) {
        val now = System.currentTimeMillis() / 1000
        // Preserve firstSeen on update: read existing, keep its firstSeen if present.
        val existing = dao.device(id)
        dao.upsertDevice(
            DeviceRow(
                id = id,
                mac = mac,
                name = name,
                firstSeen = existing?.firstSeen ?: now,
                lastSeen = now,
            )
        )
    }

    /** #716: update the model label for the seeded device once the BLE family is known. */
    suspend fun setDeviceModel(id: String, model: String) = dao.setModel(id, model)

    /** #716: read all paired devices (thin pass-through for the BLE scan fix). */
    suspend fun pairedDevices(): List<PairedDeviceRow> = dao.pairedDevices()

    // MARK: - Insert decoded streams (idempotent by natural key)

    /**
     * Persist one decoded batch under [deviceId]. Returns the number of rows actually inserted
     * per stream (0 for rows that already existed). Empty sub-lists compile/run nothing.
     * Port of WhoopStore.insert(_:deviceId:v18AuxRetentionRows:v18AuxPruneEveryRows:).
     */
    suspend fun insert(
        streams: StreamBatch,
        deviceId: String,
        // Injectable for the same reason the Swift twin takes them as parameters rather than reading the
        // statics: once the v18-aux sweep became amortised, a test could no longer observe it at all
        // without inserting 10 000 rows. `StreamStore.insert(_:deviceId:v18AuxRetentionRows:
        // v18AuxPruneEveryRows:)` is the shape being mirrored. Production callers pass neither and get the
        // shipped constants. (#888)
        v18AuxRetentionRows: Int = V18_AUX_RETENTION_ROWS,
        v18AuxPruneEveryRows: Int = V18_AUX_PRUNE_EVERY_ROWS,
    ): InsertCounts {
        if (streams.isEmpty) return InsertCounts()

        val hrIds = if (streams.hr.isEmpty()) emptyList() else
            dao.insertHr(streams.hr.map { HrSample(deviceId, it.ts, it.bpm) })
        val rrIds = if (streams.rr.isEmpty()) emptyList() else
            dao.insertRr(assignRrSeq(deviceId, streams.rr))
        val evIds = if (streams.events.isEmpty()) emptyList() else
            dao.insertEvents(streams.events.map { EventRow(deviceId, it.ts, it.kind, it.payloadJSON) })
        val batIds = if (streams.battery.isEmpty()) emptyList() else
            dao.insertBattery(streams.battery.map { BatterySample(deviceId, it.ts, it.soc, it.mv, it.charging) })
        val spo2Ids = if (streams.spo2.isEmpty()) emptyList() else
            dao.insertSpo2(streams.spo2.map { Spo2Sample(deviceId, it.ts, it.red, it.ir) })
        val skinIds = if (streams.skinTemp.isEmpty()) emptyList() else
            dao.insertSkinTemp(
                streams.skinTemp.map {
                    SkinTempSample(deviceId, it.ts, it.raw, aux1Raw = it.aux1Raw, aux2Raw = it.aux2Raw)
                },
            )
        // activityClass (#316, v13 column) is the @63 activity-class enum (0=still/1=walk/2=run) the decoder
        // already carries on each StepRow; it was dropped here before v13 (the insert listed only ts/counter).
        // it.activityClass is null when the @63 byte was 0xFF/invalid/absent → stored as SQL NULL.
        val stepIds = if (streams.steps.isEmpty()) emptyList() else
            dao.insertSteps(streams.steps.map { StepSample(deviceId, it.ts, it.counter, it.activityClass) })
        // Band sleep_state (#175). Persist-only, same as steps — the strap's OWN @81 high-nibble state
        // (0 wake/1 still/2 asleep/3 up), decoded and streamed but dropped at storage until now. Idempotent
        // by (deviceId, ts); not counted into InsertCounts (no consumer reads a count). The raw 0-3 code is
        // stored verbatim — a strap that never reports it inserts nothing.
        if (streams.sleepState.isNotEmpty()) {
            dao.insertSleepState(
                streams.sleepState.map { SleepStateSampleEntity(deviceId, it.ts, it.state, it.rawByte) },
            )
        }
        val respIds = if (streams.resp.isEmpty()) emptyList() else
            dao.insertResp(streams.resp.map { RespSample(deviceId, it.ts, it.raw) })
        val gravIds = if (streams.gravity.isEmpty()) emptyList() else
            dao.insertGravity(
                streams.gravity.map {
                    GravitySample(deviceId, it.ts, it.x, it.y, it.z, dynAccel = it.dynAccel)
                },
            )
        // v26 PPG-derived HR (#156). Idempotent by (deviceId, ts); counted into InsertCounts.hr so the
        // backfill "persisted N" summary reflects HR recovered from the optical waveform too.
        val ppgHrIds = if (streams.ppgHr.isEmpty()) emptyList() else
            dao.insertPpgHr(streams.ppgHr.map { PpgHrSample(deviceId, it.ts, it.bpm, it.conf) })
        // RAW v26 optical PPG waveform (#156 follow-up) — the samples ppgHr above is derived FROM.
        // Persist-only, same as steps/sleepState: not added to the InsertCounts return. Idempotent by
        // (deviceId, ts), IGNORE-on-conflict keeps the FIRST-seen waveform for a second (mirrors every
        // other per-second stream). Packed into one compact i16 BLOB per row (see packPpgSamples).
        if (streams.ppgWaveform.isNotEmpty()) {
            dao.insertPpgWaveform(
                streams.ppgWaveform.map {
                    PpgWaveformSampleEntity(deviceId, it.ts, StreamPersistence.packPpgSamples(it.samples))
                },
            )
        }

        // Every remaining v18 slot (v31), one compact blob per strap-second. Persist-only, same as
        // steps/sleepState/ppgWaveform: not added to InsertCounts. A sample whose slots are all absent
        // packs to an empty blob and is SKIPPED rather than banking a meaningless row — which is also
        // what keeps a WHOOP 4.0 offload from writing here at all.
        if (streams.v18Aux.isNotEmpty()) {
            val rows = streams.v18Aux.mapNotNull {
                val blob = V18AuxCodec.pack(it)
                if (blob.isEmpty()) null else V18AuxSampleEntity(deviceId, it.ts, blob)
            }
            if (rows.isNotEmpty()) {
                dao.insertV18Aux(rows)
                // Rolling retention (the insertRawImu shape, #423) but AMORTISED. The delete finds the
                // Nth-newest row by rank, so it walks up to [V18_AUX_RETENTION_ROWS] index entries;
                // insertRawImu keeps 3,600 so that is free, this keeps 604,800 and an offload inserts once
                // per chunk. Swept once per [V18_AUX_PRUNE_EVERY_ROWS] rows instead, which keeps
                // newest-N-rows exactly (a time window would not — a sporadically-worn strap's rows span
                // far more than a week, and the census wants that). Counter is per device because the
                // delete is. Swift twin: `WhoopStore.v18AuxRowsSincePrune`.
                val banked = (v18AuxRowsSincePrune[deviceId] ?: 0) + rows.size
                v18AuxRowsSincePrune[deviceId] = banked
                // Best-effort: the rows above are already committed, so a sweep failure must not surface
                // as an insert failure and make Backfiller re-send a chunk it has already banked. Leaving
                // the budget unspent means the next batch retries the sweep.
                if (banked >= v18AuxPruneEveryRows) {
                    runCatching { dao.pruneV18Aux(deviceId, v18AuxRetentionRows) }
                        .onSuccess { v18AuxRowsSincePrune[deviceId] = 0 }
                        // pruneV18Aux is a suspend call, so a scope cancellation arrives here as a
                        // CancellationException that runCatching would otherwise swallow — the caller would
                        // then carry on inside a cancelled coroutine. Same rethrow AppViewModel (#125) and
                        // HealthConnectWriter already use.
                        .onFailure { if (it is kotlin.coroutines.cancellation.CancellationException) throw it }
                }
            }
        }

        // OnConflictStrategy.IGNORE returns -1 for skipped (already-present) rows; count the inserts.
        return InsertCounts(
            hr = hrIds.countInserted() + ppgHrIds.countInserted(),
            rr = rrIds.countInserted(),
            events = evIds.countInserted(),
            battery = batIds.countInserted(),
            spo2 = spo2Ids.countInserted(),
            skinTemp = skinIds.countInserted(),
            steps = stepIds.countInserted(),
            resp = respIds.countInserted(),
            gravity = gravIds.countInserted(),
        )
    }

    /** #836 — cheap whole-history raw-HR change fingerprint `"count:maxTs"`. The idle 15-min rescore (the
     *  AppViewModel backstop) skips when this is unchanged since the last completed run. Any HR insert/delete
     *  moves it (count or maxTs), so a real change always rescores; mirrors Swift WhoopStore.hrFingerprint. */
    suspend fun hrFingerprint(): String = "${dao.countHr()}:${dao.maxHrTs()}"

    // MARK: - Server-derived caches (latest value wins on conflict)

    suspend fun upsertDailyMetrics(days: List<DailyMetric>) = dao.upsertDailyMetrics(days)
    suspend fun upsertSleepSessions(sessions: List<SleepSession>) = dao.upsertSleepSessions(sessions)

    /** Delete the computed source's cached daily rows whose day-key is in [from, to] (inclusive,
     *  yyyy-MM-dd). The #277 local-day re-bucketing migration clears the computed UTC-keyed rows over
     *  the recompute window before re-upserting LOCAL-keyed rows. Imported rows are never touched. */
    suspend fun deleteComputedDailyInRange(deviceId: String, from: String, to: String) =
        dao.deleteDailyMetricsInRange(deviceId, from, to)

    suspend fun replaceComputedScoreWindow(
        deviceId: String,
        from: String,
        to: String,
        dailyMetrics: List<DailyMetric>,
        metricPoints: List<MetricSeriesRow>,
        provenance: List<ScoreInputProvenanceRow>,
    ) = dao.replaceComputedScoreWindow(
        deviceId, from, to, dailyMetrics, metricPoints, provenance
    )

    suspend fun scoreInputSource(deviceId: String, day: String, key: String): String? =
        dao.scoreInputSource(deviceId, day, key)

    /** Hand-correct the bed (onset) / wake (end) time of an existing sleep session, DURABLY , port
     *  of iOS PR #395 (Repository.editSleepTimes + MetricsCache.applySleepEdit).
     *
     *  The corrected onset is stored in [SleepSession.startTsAdjusted] and [SleepSession.startTs] stays
     *  the IMMUTABLE detected primary key, so this upsert REPLACEs the existing (deviceId, startTs) row
     *  IN PLACE , no delete, no key move. [SleepSession.userEdited] is set true so the post-sync
     *  recompute's overlap guard (IntelligenceEngine) preserves the correction instead of re-inserting
     *  the strap-detected twin over it.
     *
     *  This fixes the prior Android bug: the old delete-then-reinsert MUTATED the startTs primary key,
     *  so a later analysis run (which re-detects the night at a slightly drifted startTs) inserted a
     *  SECOND row beside the edited one (different PK ⇒ no ON CONFLICT match), double-counting time in
     *  bed AND reverting the edit. Every other field (efficiency, restingHr, avgHrv, stagesJSON) is
     *  preserved via [SleepSession.copy]. */
    suspend fun updateSleepSessionTimes(session: SleepSession, newStartTs: Long, newEndTs: Long) {
        // #940 belt-and-braces: never persist a future-ending or inverted corrected window, whatever
        // the UI sent. The Sleep screen's own guards (cross-midnight bed auto-correct + the disjoint
        // confirm) should make this unreachable; it is the last line so no client misbehaviour can
        // write a phantom night the display merge cannot render. Twin of Swift
        // Repository.editSleepTimes' SleepEditGuard.clampedEditWindow gate.
        val (safeStartTs, safeEndTs) = com.noop.analytics.SleepEditGuard.clampedEditWindow(
            newStartTs, newEndTs, System.currentTimeMillis() / 1000L,
        ) ?: return
        val reclipped = com.noop.analytics.SleepWindowReclip.reclip(
            session.stagesJSON, session.effectiveStartTs, session.endTs, safeStartTs, safeEndTs,
        )
        dao.upsertSleepSessions(
            listOf(session.copy(
                startTsAdjusted = safeStartTs,
                endTs = safeEndTs,
                userEdited = true,
                stagesJSON = reclipped ?: session.stagesJSON,
            )),
        )
    }

    /** Remove a sleep session entirely , the delete half of [updateSleepSessionTimes] with no
     *  re-insert. (deviceId, startTs) is the primary key, so it uniquely identifies the row, letting
     *  the user clear a misread or spurious night so the day recomputes without it (#281).
     *
     *  #65: a DETECTED night is tombstoned so the recompute does not silently regenerate it (mirrors the
     *  dismissedWorkout marker; `endTs` is the span the engine's overlap test uses, since a re-detected
     *  onset can drift second-to-second). A user-created/edited (`userEdited`) night (a hand-corrected
     *  night or a manually-added nap) is deleted WITHOUT a tombstone: it is never re-detected, so
     *  suppressing its window would needlessly block a real future night overlapping it. The tombstone is
     *  written under the row's OWN [SleepSession.deviceId] and the engine reads the union of both id
     *  namespaces (see [dismissedSleeps], #65 3A).
     *
     *  ORDER MATTERS (#1008 fail-safe nit): tombstone FIRST, row-delete second, matching Swift
     *  Repository.deleteSleepSession. The old row-first order left a crash window where the row was gone
     *  but no tombstone existed, so the next analyzeRecent silently re-detected + resurrected the night
     *  the user just deleted. Tombstone-first fails safe: a crash between the two writes leaves the row
     *  in place with its tombstone , the night still displays, a re-delete completes the pair, and the
     *  undo/"allow re-detection" paths already lift a tombstone by the same (deviceId, startTs) key. */
    suspend fun deleteSleepSession(session: SleepSession) {
        if (com.noop.analytics.DismissedSleepGuard.writesTombstoneOnDelete(session.userEdited)) {
            dao.insertDismissedSleep(listOf(DismissedSleep(session.deviceId, session.startTs, session.endTs)))
        }
        dao.deleteSleepSession(session.deviceId, session.startTs)
    }

    /** Undo a [deleteSleepSession] (#65): lift the tombstone and restore the deleted row into its ORIGINAL
     *  namespace (the row still carries its owning `deviceId`), preserving `userEdited` so the next analyze
     *  pass does NOT treat a hand-corrected night as a fresh detected twin (HAZARD 2). Single-level +
     *  transient: the Sleep screen's undo snackbar calls this within a few seconds. The tombstone lift is
     *  a no-op for a `userEdited` delete (which wrote none). Mirrors Swift Repository.undoDeleteSleepSession. */
    suspend fun undoDeleteSleepSession(session: SleepSession) {
        dao.deleteDismissedSleep(session.deviceId, session.startTs)
        dao.upsertSleepSessions(listOf(session))
    }

    /** Lift a deleted-sleep tombstone by (deviceId, startTs) (#65 "Allow re-detection" escape hatch): the
     *  night regenerates from raw on the next analyze pass for a computed night. An imported night can't be
     *  re-created (no raw to re-derive); the caller shows that honest caption. */
    suspend fun allowSleepReDetection(deviceId: String, startTs: Long) =
        dao.deleteDismissedSleep(deviceId, startTs)

    /** Remove one deletion marker from the Sleep screen's management list without deleting the marker
     *  itself. The detector-facing [dismissedSleeps] read intentionally still returns hidden markers, so
     *  a mistaken sleep stays deleted after its now-irrelevant recompute row is dismissed (#515). */
    suspend fun hideDeletedSleepWindow(deviceId: String, startTs: Long): Boolean =
        dao.hideDismissedSleepFromManagement(deviceId, startTs) > 0

    /** #899 dedup heal: remove ONE sleep-session row WITHOUT the #33 dismissal tombstone. The heal
     *  deletes stale timebase-shifted duplicates of a night whose canonical copy is STAYING; a tombstone
     *  here would overlap the surviving night's window and permanently suppress its re-detection. Only
     *  the engine's dedup heal calls this; the user-facing delete stays [deleteSleepSession]. Mirrors
     *  the Swift heal, which calls the tombstone-free store-level delete directly. */
    suspend fun deleteSleepSessionRowOnly(session: SleepSession) {
        dao.deleteSleepSession(session.deviceId, session.startTs)
    }

    /**
     * #547 one-time heal: purge rows polluted by a bad-strap-clock timestamp. pikapik's WHOOP 4.0 emitted
     * records whose `unix` decoded to garbage (far-past / a 2027 spike / a future date) which entered the
     * DB verbatim before the ingest gate existed. This (a) deletes raw stream rows (HR/PPG-HR/RR/skinTemp/
     * step/resp/gravity/spo2/event/battery) whose `ts` is implausible, and (b) deletes COMPUTED daily-metric
     * + sleep-session rows whose day/ts is future or implausibly old , across EVERY device id, since the bad
     * raw rows sit under the strap id and the bad computed rows under the "-noop" id. The caller then runs a
     * normal analyzeRecent rescore so the real days recompute cleanly (the repeated 721-minute block is gone
     * once its garbage rows are purged). Idempotent: a re-run matches nothing.
     *
     * Returns the TOTAL number of rows deleted (for the heal log). Bounds default to the ingest-gate
     * constants; [nowSec] / [today] / [minDay] are injectable so a test pins the boundary deterministically.
     */
    suspend fun healImplausibleTimestamps(
        nowSec: Long = System.currentTimeMillis() / 1000L,
        today: String = java.time.LocalDate.now().toString(),
        minTs: Long = com.noop.protocol.MIN_PLAUSIBLE_UNIX,
        futureMargin: Long = com.noop.protocol.FUTURE_MARGIN,
    ): Int {
        val maxTs = nowSec + futureMargin
        // The far-past floor day (local day of MIN_PLAUSIBLE_UNIX). A computed (`-noop`) row before this
        // can't legitimately predate NOOP, so it is bad-clock garbage and is purged; the prune queries
        // apply this floor ONLY to `-noop` rows so a WHOOP CSV import (bare "my-whoop", REAL dates going
        // back years) is never touched (v8.2.1). A day after `today` is future-dated and always purged.
        val minDay = java.time.Instant.ofEpochSecond(minTs)
            .atZone(java.time.ZoneId.systemDefault()).toLocalDate().toString()
        var deleted = 0
        // (a) raw streams (all keyed by ts)
        deleted += dao.pruneHrByTs(minTs, maxTs)
        deleted += dao.prunePpgHrByTs(minTs, maxTs)
        deleted += dao.pruneRrByTs(minTs, maxTs)
        deleted += dao.pruneSkinTempByTs(minTs, maxTs)
        deleted += dao.pruneStepByTs(minTs, maxTs)
        deleted += dao.pruneRespByTs(minTs, maxTs)
        deleted += dao.pruneGravityByTs(minTs, maxTs)
        deleted += dao.pruneSpo2ByTs(minTs, maxTs)
        // The instrumentation streams, missing from this list since they landed (see the DAO note).
        deleted += dao.pruneSleepStateByTs(minTs, maxTs)
        deleted += dao.prunePpgWaveformByTs(minTs, maxTs)
        deleted += dao.pruneRawImuByTs(minTs, maxTs)
        deleted += dao.pruneV18AuxByTs(minTs, maxTs)
        deleted += dao.pruneEventByTs(minTs, maxTs)
        deleted += dao.pruneBatteryByTs(minTs, maxTs)
        // (b) computed daily metrics (by day key) + sleep sessions (by startTs). The prune queries apply
        // the far-past floor ONLY to `-noop` computed rows, so a multi-year import (bare "my-whoop")
        // survives; future rows are always purged (v8.2.1).
        deleted += dao.pruneDailyMetricByDay(today, minDay)
        deleted += dao.pruneSleepSessionByTs(minTs, maxTs)
        return deleted
    }

    /** Manually ADD a missed sleep session , typically a daytime NAP the detector didn't pick up (#508).
     *  Port of iOS Repository.addManualNap + MetricsCache.insertManualSleepSession.
     *
     *  Stages the chosen window from the raw streams via [SleepStageHealer.restageFromRaw] (the SAME
     *  density gate + stager the bed/wake edit's self-heal uses), falling back to a single "wake" block
     *  when the strap has no dense data there yet , the post-sync self-heal then swaps in real stages
     *  once the raw lands. Written under the COMPUTED source as its OWN separate session
     *  (userEdited = true, startTsAdjusted = null), so the recompute overlap guard preserves it and it is
     *  NEVER folded into the night's main sleep (which would mislabel the awake daytime gap as light
     *  sleep). Purely additive , the DAO's IGNORE-on-conflict makes a same-onset add a no-op. */
    suspend fun addManualNap(strapDeviceId: String, startTs: Long, endTs: Long) {
        // #940 belt-and-braces (same rule as updateSleepSessionTimes): a manually-added session
        // can't end in the future or invert; a future nap would otherwise own the tab's newest day
        // as an all-awake phantom exactly like the bad edit did. The clamped end is used verbatim.
        val (safeStartTs, safeEndTs) = com.noop.analytics.SleepEditGuard.clampedEditWindow(
            startTs, endTs, System.currentTimeMillis() / 1000L,
        ) ?: return
        val computedId = computedDeviceId(strapDeviceId)
        val stagesJSON = com.noop.analytics.SleepStageHealer.restageFromRaw(this, strapDeviceId, safeStartTs, safeEndTs)
            ?: com.noop.analytics.AnalyticsEngine.encodeStages(
                listOf(com.noop.analytics.StageSegment(start = safeStartTs, end = safeEndTs, stage = "wake")),
            )
        dao.insertSleepSession(
            SleepSession(
                deviceId = computedId,
                startTs = safeStartTs,
                endTs = safeEndTs,
                efficiency = sleepEfficiency(stagesJSON),
                stagesJSON = stagesJSON,
                userEdited = true,
                startTsAdjusted = null,
            ),
        )
    }

    /** Asleep fraction (light+deep+rem ÷ total in-bed) of a segment-array [stagesJSON], or null when the
     *  JSON is the fallback wake-only block / unparseable. Seeds a manual nap's efficiency so its footer
     *  reads sensibly before the next recompute re-derives it. Mirrors iOS `sleepEfficiency`. (#508) */
    private fun sleepEfficiency(stagesJSON: String?): Double? {
        stagesJSON ?: return null
        val arr = runCatching { org.json.JSONArray(stagesJSON) }.getOrNull() ?: return null
        var asleep = 0.0
        var total = 0.0
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val s = o.optLong("start", -1L)
            val e = o.optLong("end", -1L)
            val stage = o.optString("stage")
            if (s < 0 || e <= s) continue
            val dur = (e - s).toDouble()
            total += dur
            if (stage != "wake" && stage != "awake") asleep += dur
        }
        return if (total > 0 && asleep > 0) asleep / total else null
    }

    /** Narrow stages-ONLY write for the post-sync self-heal (port of iOS PR #449
     *  MetricsCache.updateSleepStages, driven by [com.noop.analytics.SleepStageHealer]). Replaces a
     *  user-edited night's stage breakdown with stages re-derived from the now-available raw, leaving
     *  the corrected bed/wake bounds and the userEdited flag untouched. Scoped to userEdited=1 rows by
     *  the DAO query; keyed by the IMMUTABLE detected [detectedStartTs]. Returns rows changed. */
    suspend fun updateSleepStages(deviceId: String, detectedStartTs: Long, stagesJSON: String): Int =
        dao.updateSleepStages(deviceId, detectedStartTs, stagesJSON)

    // MARK: - Per-epoch sleep analytics (v18: motionJSON / sleepStateJSON). Banked beside stagesJSON on
    // the sleepSession row; written/read through targeted methods so the @Upsert recompute/import path
    // (which never names these columns) preserves them. Port of iOS WhoopStore.persist/sessionMotion +
    // persist/sessionSleepState. HONESTY: an absent signal is stored as NULL and read back as null, never
    // a fabricated zero series; an EMPTY input array clears the column.

    /** Persist the SleepStager's per-epoch motion magnitudes for one session (H8), keyed by the immutable
     *  detected [sessionStart]. Empty clears to NULL. Returns rows changed (0 when no such session). */
    suspend fun persistSessionMotion(deviceId: String, sessionStart: Long, motionEpochs: List<Double>): Int =
        dao.updateSessionMotion(deviceId, sessionStart, if (motionEpochs.isEmpty()) null else encodeDoubleArray(motionEpochs))

    /** The persisted per-epoch motion magnitudes for one session, or null when unset / unparseable. */
    suspend fun sessionMotion(deviceId: String, sessionStart: Long): List<Double>? =
        dao.sessionMotionJson(deviceId, sessionStart)?.let { decodeDoubleArray(it) }

    /** Per-epoch MOTION series for each of [starts] (detected session start keys), keyed by start (#407).
     *  Motion is written ONLY under the computed ("-noop") source by the engine, so we read there; an
     *  imported-only night (no computed twin) has no motion (absent stays absent , an honest empty state,
     *  never a fabricated zero array). Does NOT resolve the night: the caller has already chosen the
     *  main-night GROUP and passes those blocks' starts. A start with no stored series is omitted. Mirrors
     *  iOS Repository.sessionMotions. */
    suspend fun sessionMotions(strapDeviceId: String, starts: List<Long>): Map<Long, List<Double>> {
        if (starts.isEmpty()) return emptyMap()
        val computedId = computedDeviceId(strapDeviceId)
        val out = HashMap<Long, List<Double>>()
        for (start in starts) {
            val m = dao.sessionMotionJson(computedId, start)?.let { decodeDoubleArray(it) }
            if (!m.isNullOrEmpty()) out[start] = m
        }
        return out
    }

    /** Persist the decoded v18 band sleep_state per epoch for one session (H2), keyed by [sessionStart].
     *  Empty clears to NULL. Returns rows changed. */
    suspend fun persistSessionSleepState(deviceId: String, sessionStart: Long, states: List<Int>): Int =
        dao.updateSessionSleepState(deviceId, sessionStart, if (states.isEmpty()) null else encodeIntArray(states))

    /** The persisted decoded v18 band sleep_state per epoch for one session, or null when unset. */
    suspend fun sessionSleepState(deviceId: String, sessionStart: Long): List<Int>? =
        dao.sessionSleepStateJson(deviceId, sessionStart)?.let { decodeIntArray(it) }

    suspend fun upsertMetricSeries(rows: List<MetricSeriesRow>) = dao.upsertMetricSeries(rows)
    suspend fun upsertJournal(rows: List<JournalEntry>) = dao.upsertJournal(rows)
    suspend fun upsertWorkouts(rows: List<WorkoutRow>) = dao.upsertWorkouts(rows)
    suspend fun upsertAppleDaily(rows: List<AppleDaily>) = dao.upsertAppleDaily(rows)

    // MARK: - Live Sessions (silent guardian, v22). The runner banks the row at start (endTs null) and
    // again at end (totals); the summary reads the recent rows for its guarded-count / streak line.
    suspend fun upsertLiveSession(row: LiveSessionRow) = dao.upsertLiveSession(row)
    suspend fun recentLiveSessions(deviceId: String, limit: Int): List<LiveSessionRow> =
        dao.recentLiveSessions(deviceId, limit)

    // MARK: - Lab Book markers (Swift labMarker, v17). Writing also projects the daily series into
    // metricSeries under WhoopDao.LAB_BOOK_SOURCE_ID, so Compare/Explore/Coach see markers unchanged.
    suspend fun upsertLabMarkers(rows: List<LabMarkerRow>) = dao.upsertLabMarkers(rows)
    suspend fun deleteLabMarker(id: String): Boolean = dao.deleteLabMarker(id)
    suspend fun labMarkersByKey(deviceId: String, markerKey: String) = dao.labMarkersByKey(deviceId, markerKey)
    suspend fun labMarkersByCategory(deviceId: String, category: String) = dao.labMarkersByCategory(deviceId, category)
    suspend fun markerKeysPresent(deviceId: String) = dao.markerKeysPresent(deviceId)

    // MARK: - Reads

    suspend fun hrSamples(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.hrSamples(deviceId, from, to, limit)

    /** #856: HR samples over an EXPLICIT id list, deduped by ts with earlier ids winning — the sample
     *  twin of [hrBucketsFor], so a workout's ZONE MINUTES bin the same rows its chart plots and its
     *  Avg HR aggregates. One id ⇒ a plain single-id read. */
    suspend fun hrSamplesFor(deviceIds: List<String>, from: Long, to: Long, limit: Int = DEFAULT_LIMIT):
        List<HrSample> =
        if (deviceIds.isEmpty()) emptyList()
        else mergeHrByTs(deviceIds.map { dao.hrSamples(it, from, to, limit) })

    /**
     * HR samples over the read-side UNION of the active strap id AND the canonical "my-whoop" (SPINE /
     * #814 + HIGH-2), deduped by ts with the active strap winning. This is the Kotlin twin of the Swift
     * [com.noop] Repository.hrSamples(from:to:) union overload.
     *
     * #908: a strap re-added through the in-app device manager banks its LIVE raw under its OWN fresh id
     * (e.g. "whoop-<uuid>"), NOT "my-whoop". A Today-curve / live-Effort read pinned to the hardcoded
     * "my-whoop" then finds NOTHING and the day looks frozen (and Effort integrates to 0 off an empty
     * series). Reading the union surfaces the re-added strap's live data AND the canonical import history.
     * A single-WHOOP install resolves [activeDeviceId] to "my-whoop" ⇒ ONE id ⇒ byte-identical read.
     */
    suspend fun hrSamplesUnion(activeDeviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT):
        List<HrSample> = mergeHrByTs(importedSourceIds(activeDeviceId).map { dao.hrSamples(it, from, to, limit) })

    /** Raw measured HR only (no v26 PPG-derived union) for the raw-sensor diagnostic export. */
    suspend fun rawHrSamples(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.rawHrSamples(deviceId, from, to, limit)

    /** v26 PPG-derived HR samples (own stream) for the raw-sensor diagnostic export. (#156) */
    suspend fun ppgHrSamples(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.ppgHrSamples(deviceId, from, to, limit)

    /**
     * The RAW v26 optical PPG waveform (#156 follow-up), one record per second, in [from, to] for one
     * device, ascending by ts. [PpgWaveformRow.samples] are the raw i16 ADC counts the strap sent,
     * unpacked from the compact on-disk BLOB ([StreamPersistence.packPpgSamples]/[unpackPpgSamples]).
     * Empty when the strap never emitted v26 (the WHOOP 4.0 / v18-only case) or the window has no
     * v26-heavy stretch. Kotlin twin of the Swift `WhoopStore.ppgWaveformSamples(deviceId:from:to:)`.
     */
    suspend fun ppgWaveformSamples(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT):
        List<PpgWaveformRow> =
        dao.ppgWaveformSamples(deviceId, from, to, limit)
            .map { PpgWaveformRow(it.ts, StreamPersistence.unpackPpgSamples(it.samples)) }

    /**
     * The banked 5/MG v18 auxiliary fields in [from, to] for one device, ascending by ts — one row per
     * strap-second, decoded from the compact blob by [V18AuxCodec]. Empty on a WHOOP 4.0 and for any
     * window offloaded before the table existed. INSTRUMENTATION: nothing in the app calls this; it
     * exists so the banked bytes are reachable for a census and so the write path has a round-trip test.
     * Kotlin twin of the Swift `WhoopStore.v18AuxSamples(deviceId:from:to:)`.
     */
    suspend fun v18AuxSamples(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT):
        List<V18AuxRow> =
        dao.v18AuxSamples(deviceId, from, to, limit)
            .map { V18AuxCodec.unpack(it.fields, it.ts) }

    /** #423: persist a batch of decoded 5/MG raw-IMU offload buffers (one row per strap-second, packed i16
     *  BLOB), then bound the table to the newest [RAW_IMU_RETENTION_ROWS] for the device. Comes from the
     *  deep-buffer capture seam, not the normal stream path, so it inserts directly (idempotent by ts). */
    suspend fun insertRawImu(deviceId: String, rows: List<RawImuSampleEntity>) {
        if (rows.isEmpty()) return
        dao.insertRawImu(rows)
        dao.pruneRawImu(deviceId, RAW_IMU_RETENTION_ROWS)
    }

    /** #423: raw 5/MG IMU buffers in [from, to] as the decoded i16 columns [ax…az,gx…gz] (100/axis). */
    suspend fun rawImuSamples(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT):
        List<Pair<Long, ShortArray>> =
        dao.rawImuSamples(deviceId, from, to, limit)
            .map { it.ts to StreamPersistence.unpackImuColumns(it.samples) }

    /** Downsampled HR (mean bpm per [bucketSeconds]) for the strap, for the Today 24h trend chart. */
    suspend fun hrBuckets(deviceId: String, from: Long, to: Long, bucketSeconds: Long = 300L) =
        dao.hrBuckets(deviceId, from, to, bucketSeconds)

    /** #856: the same dedup over an EXPLICIT id list, so a workout can read its OWN recording strap
     *  rather than the day-level active ∪ canonical. Order is precedence — earlier ids win per bucket
     *  start, exactly as [hrBucketsUnion] does. One id ⇒ a plain single-id read. */
    suspend fun hrBucketsFor(deviceIds: List<String>, from: Long, to: Long, bucketSeconds: Long = 300L):
        List<HrBucket> =
        if (deviceIds.isEmpty()) emptyList()
        else mergeHrBucketsByStart(deviceIds.map { dao.hrBuckets(it, from, to, bucketSeconds) })

    /**
     * Downsampled HR buckets over the read-side UNION of the active strap id AND the canonical "my-whoop"
     * (SPINE / #814 + HIGH-2), deduped by bucket start with the active strap winning. Kotlin twin of the
     * Swift Repository.hrBuckets(from:to:bucketSeconds:) union overload. #908: keeps the Today HR curve
     * pointed at whichever id the re-added strap actually banks under. Single-WHOOP install ⇒ one id ⇒
     * byte-identical read.
     */
    suspend fun hrBucketsUnion(activeDeviceId: String, from: Long, to: Long, bucketSeconds: Long = 300L):
        List<HrBucket> = mergeHrBucketsByStart(
            importedSourceIds(activeDeviceId).map { dao.hrBuckets(it, from, to, bucketSeconds) },
        )

    /**
     * DISPLAY-ONLY: reconcile a workout's shown HR with the strap trace that actually drives its
     * graph / zones / effort (#77, #499). The detail screen always charts and zone-bins the strap's
     * own ~1 Hz samples over [startTs, endTs] (under [strapDeviceId]); the displayed Avg HR comes from
     * the stored `avgHr` column. Those two can DIVERGE , a hand-edited Avg (128→139) changes the number
     * but not the trace, so the average no longer matches the graph/zones/effort (#499). Here we make the
     * stored field defer to the trace whenever the trace is present:
     *
     *  - STRAP-NATIVE rows (source "manual" or detected "<id>-noop") are charted/zoned/scored straight
     *    from this strap trace, so their Avg HR is ALWAYS recomputed as the true mean of those samples ,
     *    a manual edit can no longer drift it out of agreement with the graph. (max likewise → true peak.)
     *  - IMPORTED rows (Apple Health / Health Connect / Whoop CSV) carry their OWN avg/max from the
     *    import; we only FILL them when null (and the strap happened to be worn), never override a real
     *    imported value with strap-derived numbers.
     *
     * Requires [minSamples] (~1 min of data) so a few stray samples can't fabricate an average, and caps
     * the lookups so a huge history can't jank first paint. NEVER persisted , the derived value is a
     * read-time projection of the trace (the workout PK upsert would wipe it anyway, and re-deriving on
     * every load keeps display == graph == zones == effort by construction).
     */
    suspend fun fillWorkoutHrFromStrap(
        rows: List<WorkoutRow>,
        // HR read key for IMPORTED rows ONLY (Apple/HC/CSV/activity file): they carry no strap HR of their
        // own, so #77 derives it from the worn strap. STRAP-NATIVE rows ignore this and key on their OWN
        // recording strap (see [workoutHrDeviceIds]). The canonical "my-whoop" default is the worn strap on a
        // single-WHOOP install (and every current caller uses it); which strap was worn during an imported
        // session on a MULTI-strap install is undetermined, so that case is left as-is (not the active strap).
        strapDeviceId: String = "my-whoop",
        minSamples: Long = 60,
        cap: Int = 300,
        // #961: the user's HRmax + sex. When supplied, a strap-native row whose Effort (strain) is null gets
        // one recomputed from the strap trace on display, so a live/manual session that ended with sparse HR
        // (near-zero strain at save on a 5/MG) can't read a blank Effort while the DAY total counted the bout.
        // null (the default) leaves every existing call site byte-identical: no raw-sample read, strain stays
        // as stored. Display-only; the durable value is written by IntelligenceEngine.rescoreManualWorkouts.
        strainMaxHR: Double? = null,
        strainSex: String = "male",
    ): List<WorkoutRow> {
        var budget = cap
        return rows.map { row ->
            if (row.endTs <= row.startTs || budget <= 0) return@map row
            // Strap-native rows are graphed/zoned/scored from the strap trace, so their Avg HR must come
            // from that same trace (recompute, overriding any stored/edited value). Imported rows keep
            // their own avg/max and are only filled when missing.
            val strapNative = isStrapNativeWorkout(row.source)
            // #961: a strap-native row still missing a strain is a fill target even when its avgHr is present.
            val needsStrainFill = strapNative && row.strain == null && strainMaxHR != null
            if (!strapNative && row.avgHr != null && !needsStrainFill) return@map row
            budget -= 1
            // #510: read the HR window under the device that ACTUALLY recorded this workout — its OWN strap
            // for a strap-native row (never a hardcoded id), the [strapDeviceId] worn-strap default for an
            // imported one. A 2nd WHOOP (id "whoop-<mac>") used to read the empty "my-whoop" window, so its
            // strap-native workouts' Avg HR wasn't reconciled from the trace and a null Effort wasn't recomputed.
            // #856: up to two ids, the first winning per second. A detected bout reads only the strap
            // that recorded it; an imported row reads the active ∪ canonical union, because it has no
            // strap of its own and the worn strap may bank under either after a re-add.
            val hrIds = workoutHrDeviceIds(row.source, row.deviceId, strapDeviceId)
            val stats = dao.hrWindowStats(
                hrIds[0], hrIds.getOrElse(1) { hrIds[0] }, row.startTs, row.endTs,
            )
            if (stats.n < minSamples || stats.avg == null || stats.max == null) return@map row
            // #961: recompute Effort from the SAME samples the graph/zones use. Read the raw window ONLY when
            // this row actually needs a strain (keeps the common no-fill path a single aggregate query), and
            // let StrainScorer return null on a still-too-thin window (never a fabricated number).
            val filledStrain = if (needsStrainFill && strainMaxHR != null) {
                val samples = dao.hrSamples(hrIds[0], row.startTs, row.endTs, 8000)
                com.noop.analytics.StrainScorer.strain(samples, maxHR = strainMaxHR, sex = strainSex)
            } else null
            if (strapNative) {
                // True mean / peak of the very samples the graph + zones + effort use; FILL a null Effort
                // (never override a stored one) from the recompute.
                row.copy(avgHr = stats.avg.roundToInt(), maxHr = stats.max,
                         strain = row.strain ?: filledStrain)
            } else {
                // Imported row with no avg , fill from strap, preserving any imported max.
                row.copy(avgHr = stats.avg.roundToInt(), maxHr = row.maxHr ?: stats.max)
            }
        }
    }

    suspend fun rrIntervals(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.rrIntervals(deviceId, from, to, limit)

    suspend fun events(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.events(deviceId, from, to, limit)

    suspend fun batterySamples(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.batterySamples(deviceId, from, to, limit)

    suspend fun spo2Samples(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.spo2Samples(deviceId, from, to, limit)

    suspend fun skinTempSamples(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.skinTempSamples(deviceId, from, to, limit)

    suspend fun stepSamples(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.stepSamples(deviceId, from, to, limit)

    /**
     * The strap's OWN band sleep_state samples (#175) in [from, to] as (ts, state) pairs, ascending. Feeds
     * the Deep Timeline band-state track and the per-session grid the H7 re-onset confirm guard reads. Empty
     * when the strap never reported it (a WHOOP 4.0, or a not-yet-offloaded window). Swift `sleepStateSamples`.
     */
    suspend fun sleepStateSamples(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT):
        List<SleepStateRow> =
        dao.sleepStateSamples(deviceId, from, to, limit).map { SleepStateRow(it.ts, it.state) }

    /**
     * The latest (greatest-ts) non-null @63 activity class over [from, to], read across the active strap ∪
     * canonical "my-whoop" union ([importedSourceIds]), for the Steps tile icon (#316 / @63). Kotlin twin of
     * the Swift Repository.stepActivityClassLatest(from:to:). #908 family: a re-added strap banks its LIVE step
     * samples (which carry [com.noop.data.StepSample.activityClass]) under its OWN fresh id, exactly like HR,
     * so a read pinned to the canonical "my-whoop" returned nothing and the tile icon vanished for a re-added
     * strap. A single-WHOOP install resolves to one id ⇒ byte-identical read. A ts tie favours the active strap
     * (its list is scanned first by [latestActivityClass]).
     */
    suspend fun stepActivityClassLatestUnion(activeDeviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT):
        Int? = latestActivityClass(importedSourceIds(activeDeviceId).map { dao.stepSamples(it, from, to, limit) })

    /** Delete a computed source's [sport] workouts in [from, to] (makes re-detection idempotent). (#78) */
    suspend fun deleteComputedWorkouts(deviceId: String, sport: String, from: Long, to: Long) =
        dao.deleteWorkoutsBySport(deviceId, sport, from, to)

    // MARK: - Workout editing (manual add/edit · relabel · dismiss · delete) (#107)
    //
    // Mirrors macOS Repository's workout-editing surface. Manual workouts live under the strap source
    // ([strapDeviceId], source "manual") , the same place live-tracked sessions land. Detected bouts
    // live under "<strapDeviceId>-noop" with sport "detected" and are wiped + re-derived each engine
    // run, so a durable dismissal is recorded in the independent `dismissedWorkout` table.

    /** Dismissed detected-bout markers for the computed source of [strapDeviceId]. */
    suspend fun dismissedDetected(strapDeviceId: String = "my-whoop"): List<DismissedWorkout> =
        dao.dismissedWorkouts(computedDeviceId(strapDeviceId))

    /** Deleted-sleep tombstones for BOTH the imported and computed sources of [strapDeviceId] (#33/#65).
     *
     *  HAZARD FIX (#65 3A): [deleteSleepSession] writes the tombstone under the deleted row's OWN
     *  `session.deviceId` ("my-whoop" for an IMPORTED night, "my-whoop-noop" for a computed one). This
     *  read used to consult ONLY the computed id, so a deleted IMPORTED night wrote a tombstone the engine
     *  never saw, and a strap raw re-detection over that window resurrected it as a computed twin. Reading
     *  the UNION of both ids fixes it with NO data migration: tombstones written under either id are now
     *  found. De-duping on (deviceId,startTs) is unnecessary because the two id namespaces never collide. */
    suspend fun dismissedSleeps(strapDeviceId: String = "my-whoop"): List<DismissedSleep> =
        dao.dismissedSleeps(strapDeviceId) + dao.dismissedSleeps(computedDeviceId(strapDeviceId))

    /** Deleted-sleep tombstones across the active strap + canonical import union (#515). The Sleep screen
     *  uses this management view so a night deleted before a strap remove/re-add does not lose its
     *  "Recompute this night" escape hatch. The engine-facing [dismissedSleeps] stays scoped to the source
     *  it is currently analysing; this read is deliberately broader because it is user-facing history. */
    suspend fun dismissedSleepsUnion(activeDeviceId: String): List<DismissedSleep> =
        (importedSourceIds(activeDeviceId) + computedSourceIds(activeDeviceId))
            .flatMap { dao.dismissedSleeps(it) }
            .filter { it.managementVisible }
            .distinctBy { it.deviceId to it.startTs }
            .sortedByDescending { it.endTs }

    /**
     * Persist a retroactive / edited manual workout under the strap source. [replacing] is the row the
     * edit started from:
     *  - editing a DETECTED bout replaces it with this manual row , the detected original is dismissed
     *    durably so the re-detector doesn't bring it back (else both would show);
     *  - editing a MANUAL row whose natural key (startTs/sport) changed deletes the stale row first
     *    (the (deviceId, startTs, sport) PK upsert would otherwise orphan it);
     *  - an IMPORTED row is never passed here as `replacing` (duplicating one is a pure add).
     */
    suspend fun saveManualWorkout(row: WorkoutRow, replacing: WorkoutRow? = null) {
        if (replacing != null && replacing.source.lowercase().endsWith("-noop")) {
            dismissDetected(replacing)
        } else if (replacing != null && (replacing.startTs != row.startTs || replacing.sport != row.sport)) {
            dao.deleteWorkoutByKey(replacing.deviceId, replacing.startTs, replacing.sport)
        }
        dao.upsertWorkouts(listOf(row))
    }

    /**
     * Re-label a detected bout: copy it to a manual strap row with the chosen [sport], then delete the
     * detected original. Survives analyzeRecent , the engine re-derives only sport="detected" rows AND
     * skips any re-derived bout overlapping a real strap workout, which this copy now is , so the same
     * session is never re-created as a duplicate. (#107)
     */
    suspend fun relabelDetected(row: WorkoutRow, sport: String, strapDeviceId: String = "my-whoop") {
        val trimmed = sport.trim()
        if (trimmed.isEmpty()) return
        val manual = row.copy(deviceId = strapDeviceId, sport = trimmed, source = "manual")
        dao.upsertWorkouts(listOf(manual))
        dao.deleteWorkoutsBySport(computedDeviceId(strapDeviceId), "detected", row.startTs, row.startTs)
    }

    /**
     * Dismiss a DETECTED bout the user says isn't a workout: record a durable marker (so a re-detect
     * that recreates the same PK stays hidden) AND delete the current row so it disappears now.
     * No-op when the row isn't a detected bout. (#107)
     */
    suspend fun dismissDetected(row: WorkoutRow) {
        if (!row.source.lowercase().endsWith("-noop")) return
        // Marker carries the bout's [startTs, endTs] span so a re-detected bout whose boundary drifts
        // still overlaps it and stays hidden (matches macOS dismissed-span semantics).
        dao.insertDismissed(listOf(DismissedWorkout(row.deviceId, row.startTs, row.endTs)))
        dao.deleteWorkoutsBySport(row.deviceId, row.sport, row.startTs, row.startTs)
    }

    /**
     * Delete ONE workout. A detected bout is dismissed durably (so it doesn't come back on the next
     * re-detect); everything else is removed by its exact natural key. (#107)
     */
    suspend fun deleteWorkout(row: WorkoutRow) {
        if (row.source.lowercase().endsWith("-noop")) { dismissDetected(row); return }
        dao.deleteWorkoutByKey(row.deviceId, row.startTs, row.sport)
    }

    /**
     * #64: merge two-or-more overlapping / adjacent MANUAL or DETECTED sessions into ONE manual session
     * ([merged], built by the pure [com.noop.ui.WorkoutMerge.merge]), then retire the originals. Imported
     * history is NEVER passed here (the caller gates on WorkoutMerge.canMerge, and this only writes the
     * manual-row path), so the imported-read-only invariant holds. The Android WorkoutRow carries its own
     * routePolyline, so the route re-key is a field copy (no side-store): keep the longest original route.
     * The caller runs rescoreAfterEdit (rescores strain from strap HR, the #598 pattern) + reloads.
     */
    suspend fun mergeWorkouts(originals: List<WorkoutRow>, merged: WorkoutRow) {
        if (originals.size < 2) return
        // Keep the longest original route on the merged row (mirrors macOS RouteStore re-key #10).
        val keptRoute = originals.mapNotNull { it.routePolyline }.maxByOrNull { it.length }
        val mergedWithRoute = if (keptRoute != null) merged.copy(routePolyline = keptRoute) else merged
        saveManualWorkout(mergedWithRoute)
        // Retire each original. Skip any row whose natural key matches the merged row's, so we never
        // dismiss/delete the span the merged row now owns.
        for (r in originals) {
            if (r.startTs == merged.startTs && r.sport == merged.sport) continue
            when {
                r.source.lowercase().endsWith("-noop") -> dismissDetected(r)
                r.source.lowercase() == "manual" -> dao.deleteWorkoutByKey(r.deviceId, r.startTs, r.sport)
                // Defensive: canMerge already excludes imported rows; never rewrite imported history.
                else -> continue
            }
        }
    }

    /**
     * #64: bulk-delete the selected sessions, routing per class exactly like the single-row path
     * (detected -> durable dismiss, manual -> delete). Imported rows are never selectable so never reach
     * here. The caller reloads afterwards.
     */
    suspend fun bulkDeleteWorkouts(rows: List<WorkoutRow>) {
        for (r in rows) {
            when {
                r.source.lowercase().endsWith("-noop") -> dismissDetected(r)
                r.source.lowercase() == "manual" -> dao.deleteWorkoutByKey(r.deviceId, r.startTs, r.sport)
                else -> continue
            }
        }
    }

    suspend fun respSamples(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.respSamples(deviceId, from, to, limit)

    suspend fun gravitySamples(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.gravitySamples(deviceId, from, to, limit)

    suspend fun sleepSessions(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.sleepSessions(deviceId, from, to, limit)

    /**
     * The user's learned habitual midsleep (local time-of-day seconds) for [deviceId], or null under
     * [com.noop.analytics.SleepStageTotals.HABITUAL_MIN_DAYS] of history (cold-start). Computed EXACTLY as
     * `IntelligenceEngine.computeHabitualMidsleep` does , the SAME raw imported + computed ("-noop")
     * sleep-session union, one HistoryBlock per session (effective bounds, dayKey = the LOCAL calendar day
     * of the midpoint), deferring to the SAME shared [com.noop.analytics.SleepStageTotals.habitualMidsleepSec]
     * pure function , so the Sleep tab's main-night pick aligns to the same value the analytics rollup used.
     * The whole point of #547: the UI hero and the analytics daily total resolve to the SAME block for a
     * shift/late sleeper, not just at cold-start. Reads a wide window so the distinct-day count comfortably
     * clears the threshold; `habitualMidsleepSec` keeps the longest block per day, so window/order/source
     * merge differences wash out. Mirrors Swift `Repository.habitualMidsleepSec`. (#547)
     */
    suspend fun habitualMidsleepSec(deviceId: String, days: Int = 4000): Long? {
        val now = System.currentTimeMillis() / 1000L
        val lo = now - days * 86_400L
        val hi = now + 86_400L
        // UNION active strap + canonical "my-whoop" (imported) and their computed siblings (#814/#1008),
        // de-duplicating identical (startTs, endTs) blocks recorded under both ids so a night present in
        // both namespaces doesn't double-weight the learner. Reading one id narrowed the night set vs iOS
        // after a strap re-add (the learner could cold-start to null where iOS returned a learned value).
        // Mirrors Swift Repository.habitualMidsleepSec (importedReadIds/computedReadIds + dedupBlocks).
        val imported = dedupSleepBlocks(importedSourceIds(deviceId).flatMap { dao.sleepSessions(it, lo, hi, 4000) })
        val computed = dedupSleepBlocks(computedSourceIds(deviceId).flatMap { dao.sleepSessions(it, lo, hi, 4000) })
        val offsetSec = (java.util.TimeZone.getDefault().getOffset(System.currentTimeMillis()) / 1000).toLong()
        val blocks = (imported + computed).mapNotNull { s ->
            val start = s.effectiveStartTs
            val end = s.endTs
            if (end <= start) {
                null
            } else {
                val mid = start + (end - start) / 2
                com.noop.analytics.SleepStageTotals.HistoryBlock(
                    start, end, com.noop.analytics.AnalyticsEngine.dayString(mid, offsetSec),
                )
            }
        }
        return com.noop.analytics.SleepStageTotals.habitualMidsleepSec(blocks, offsetSec)
    }

    suspend fun metricSeries(deviceId: String, key: String, from: String, to: String) =
        dao.metricSeries(deviceId, key, from, to)

    /**
     * Computed ("-noop") [key] series across the active-strap UNION (the active strap's own computed
     * sibling + the canonical "my-whoop-noop"), deduped per day with the active strap winning. This is
     * how the weekly computed scores (fitness_age / vo2max_est / vitality / body_age) MUST be read:
     * IntelligenceEngine writes them under "<activeStrapId>-noop", so a live-BLE strap banks them under
     * "whoop-<mac>-noop", NOT the canonical "my-whoop-noop" a hardcoded read assumes (#349). Import users
     * (activeStrapId == "my-whoop") collapse to the single canonical id, unchanged. Mirrors the computed
     * layer of Swift Repository.exploreSeries.
     */
    suspend fun metricSeriesComputedUnion(
        activeStrapId: String,
        key: String,
        from: String,
        to: String,
    ): List<MetricSeriesRow> {
        val ids = computedSourceIds(activeStrapId)
        if (ids.size == 1) return metricSeries(ids[0], key, from, to)
        return mergeComputedSeriesUnion(ids.map { metricSeries(it, key, from, to) })
    }

    /**
     * The LATEST computed ("-noop") [key] row across the active-strap union, or null — the LIMIT-1
     * twin of [metricSeriesComputedUnion] for "latest value" tiles (Today pinned cards, the Health
     * hub heroes), which were materializing the FULL series just to take `.lastOrNull()`. Reads one
     * indexed row per source id; the newest day wins, and on a shared newest day the ACTIVE strap
     * wins (ids are active-first) — byte-identical to `metricSeriesComputedUnion(...).lastOrNull()`.
     */
    suspend fun latestMetricComputedUnion(activeStrapId: String, key: String): MetricSeriesRow? =
        latestFromPerSourceLatest(
            computedSourceIds(activeStrapId).map { dao.latestMetricSeriesRow(it, key) },
        )

    /** Scalar row count for one (deviceId, key) series — the COUNT twin of [metricSeries]. */
    suspend fun metricSeriesKeyCount(deviceId: String, key: String): Int =
        dao.metricSeriesKeyCount(deviceId, key)

    /** Distinct metric keys present for a [deviceId]/source, sorted ascending. */
    suspend fun metricKeys(deviceId: String): List<String> = dao.metricKeys(deviceId)

    /** Workouts whose startTs falls in [from, to] (unix seconds), oldest first, row-limited. */
    suspend fun workouts(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT): List<WorkoutRow> =
        dao.workouts(deviceId, from, to, limit)

    /** Scalar COUNT twin of [workouts] (exact total, no row limit) for count badges. */
    suspend fun workoutsCount(deviceId: String, from: Long, to: Long): Int =
        dao.workoutsCount(deviceId, from, to)

    /** Journal entries for the inclusive day range [from, to] (YYYY-MM-DD), oldest first. */
    suspend fun journal(deviceId: String, from: String, to: String): List<JournalEntry> =
        dao.journal(deviceId, from, to)

    /** Delete one native journal answer by natural key (only ever called with the "noop-journal"
     *  source id , imported rows are never touched). */
    suspend fun deleteJournalEntry(deviceId: String, day: String, question: String) =
        dao.deleteJournalEntry(deviceId, day, question)

    /** Atomically replace a device's imported journal within a day range (#136) — the WHOOP importer
     *  clears the span it re-writes and upserts in ONE transaction, so the wake-day re-keying leaves no
     *  pre-fix onset-keyed duplicates and a crash mid-import can't drop the range's journal. */
    suspend fun replaceJournalRange(deviceId: String, from: String, to: String, rows: List<JournalEntry>) =
        dao.replaceJournalRange(deviceId, from, to, rows)

    /** Apple-Health daily aggregates for the inclusive day range [from, to] (YYYY-MM-DD), oldest first. */
    suspend fun appleDaily(deviceId: String, from: String, to: String): List<AppleDaily> =
        dao.appleDaily(deviceId, from, to)

    /** Scalar COUNT twin of [appleDaily] for count badges. */
    suspend fun appleDailyCount(deviceId: String, from: String, to: String): Int =
        dao.appleDailyCount(deviceId, from, to)

    /** All cached daily metrics for a device, oldest first. Feeds com.noop.analytics.IllnessWatch. */
    suspend fun days(deviceId: String): List<DailyMetric> = dao.days(deviceId)

    /** Scalar COUNT twin of [days] for count badges. */
    suspend fun daysCount(deviceId: String): Int = dao.daysCount(deviceId)

    /** Every distinct source id with at least one cached daily row. Feeds the Health Connect
     *  backfill's strap-coverage gate (see HealthConnectImporter.isStrapNativeSourceId). */
    suspend fun dailyMetricDeviceIds(): List<String> = dao.dailyMetricDeviceIds()

    /**
     * #112 follow-up heal: delete the Health-Connect-shaped "my-whoop" shadow rows an older import
     * wrote over strap-covered days, back when the backfill's covered-days gate only knew the
     * canonical "my-whoop"/"my-whoop-noop" pair and missed active-strap ("whoop-<mac>") ids.
     *
     *  - Sleep sessions: un-edited, signal-less windows (no efficiency/HR/HRV/motion — the HC shape)
     *    that overlap ANY computed ("-noop") session.
     *  - Daily rows: HC-shaped rows (no efficiency/stages/recovery/strain/steps) on a day a computed
     *    source also covers.
     *
     * The discriminators never match a WHOOP CSV / wearable-export import (those carry efficiency /
     * stage minutes) or user-edited rows, so real data survives. Idempotent — a re-run matches
     * nothing. Returns the TOTAL rows deleted (for the heal log).
     */
    suspend fun purgeHcShadowedStrapDays(): Int =
        dao.purgeHcShadowedSleepSessions() + dao.purgeHcShadowedDailyMetrics()

    /**
     * One-time #34 refile: move legacy Health Connect data out of the shared "apple-health" bucket into
     * its own "health-connect" source, so it stops being shown as Apple Health. HC workouts are tagged
     * `source = "health-connect"` so they move unconditionally; the daily aggregates only move when there
     * is no Apple Health EXPORT (no apple-health metricSeries), since only the export writes metricSeries.
     * Idempotent + safe (runs before this import writes any HC data, so no PK conflict).
     */
    suspend fun refileLegacyHealthConnect() {
        dao.reassignWorkoutsBySource(from = "apple-health", to = "health-connect", source = "health-connect")
        if (dao.metricSeriesCount("apple-health") == 0) {
            dao.reassignAppleDaily(from = "apple-health", to = "health-connect")
            upsertDevice("health-connect", name = "Health Connect")
        }
    }

    // MARK: - Merged reads (imported source wins per day; computed "-noop" gap-fills)
    //
    // Mirrors macOS Repository.mergeDaily / mergeSleep: the IntelligenceEngine persists
    // on-device scores under "<deviceId>-noop"; the dashboard should see BOTH sources so
    // a strap-only user still gets a populated dashboard, while a real WHOOP import always
    // wins on the days it covers. The screens point their "my-whoop" reads at these merged
    // variants (the least invasive correct approach , no DAO/schema change, and the per-day
    // precedence lives in one place).

    /** The computed-source id for a given imported [deviceId] (e.g. "my-whoop" → "my-whoop-noop"). */
    fun computedDeviceId(deviceId: String): String = "$deviceId-noop"

    /** Instance ergonomics for the read-side union ids; delegate to the pure companion forms (see
     *  [importedSourceIdsFor] / [computedSourceIdsFor] for the SPINE / #814 + HIGH-2 rationale). */
    fun importedSourceIds(activeDeviceId: String): List<String> = importedSourceIdsFor(activeDeviceId)
    fun computedSourceIds(activeDeviceId: String): List<String> = computedSourceIdsFor(activeDeviceId)

    /**
     * CAPTURE-D (#797): the on-device DATA VOLUME read FRESH from the store (never the reactive dashboard
     * caches), for the Display & Performance test mode's `dataVolume` line. Kotlin twin of the Swift
     * Repository.dataVolumeSnapshot:
     *   - dbRows = the raw decoded-stream footprint (HR + RR + events + the biometric streams), the dominant cost;
     *   - importedDays = imported daily-metric rows under [strapDeviceId] (the #799 import surface);
     *   - workouts = recorded/detected workout-row count under [strapDeviceId];
     *   - lastRenderRows = the size of the merged DAILY set the dashboard renders: the union of distinct days
     *     across the three daily sources (imported strap + on-device computed + Apple), the read-set whose
     *     size drives post-import list/chart lag.
     * [strapDeviceId] is the registry's ACTIVE strap id (SPINE / #814), so it reads the right source, not the
     * hardcoded legacy id. Pure store reads: no merge, no scoring, nothing reactive mutates, so calling it
     * never perturbs the screens it measures. Best-effort: a read failure contributes 0 rather than throwing.
     */
    suspend fun dataVolumeSnapshot(
        strapDeviceId: String = WHOOP_SOURCE,
    ): com.noop.analytics.DataVolume {
        val dbRows = runCatching {
            dao.countHr() + dao.countRr() + dao.countEvents() + dao.countSpo2() +
                dao.countSkinTemp() + dao.countSteps() + dao.countResp() + dao.countGravity()
        }.getOrDefault(0)
        val imported = runCatching { dao.days(strapDeviceId) }.getOrDefault(emptyList())
        val workouts = runCatching {
            dao.workouts(strapDeviceId, 0L, 4_102_444_800L, 1_000_000)
        }.getOrDefault(emptyList())
        // The merged daily read-set the dashboard renders over: union of distinct days across the three
        // daily sources. Mirrors the Swift renderDays union.
        val computed = runCatching { dao.days(computedDeviceId(strapDeviceId)) }.getOrDefault(emptyList())
        val apple = runCatching { dao.days(APPLE_HEALTH_SOURCE) }.getOrDefault(emptyList())
        val renderDays = HashSet<String>()
        for (m in imported) renderDays.add(m.day)
        for (m in computed) renderDays.add(m.day)
        for (m in apple) renderDays.add(m.day)
        return com.noop.analytics.DataVolume(
            dbRows = dbRows,
            importedDays = imported.size,
            workouts = workouts.size,
            lastRenderRows = renderDays.size,
        )
    }

    /**
     * #1002: per-table row counts for meta.json's storage block, read via the store (the same COUNTs
     * [dataVolumeSnapshot] sums), so a Test Centre export shows the REAL on-device footprint instead of
     * the Phase-1 zeros. Keys mirror the Swift probe (TestCentreReport.storageProbe) so a maintainer
     * reads the same map from either platform. Best-effort: a read failure returns empty (the caller's
     * zeroed fallback stays an honest "unreadable"), never a fabricated figure.
     */
    suspend fun storageRowCounts(): Map<String, Int> = runCatching {
        mapOf(
            "hr" to dao.countHr(), "rr" to dao.countRr(), "events" to dao.countEvents(),
            "battery" to dao.countBattery(), "spo2" to dao.countSpo2(),
            "skinTemp" to dao.countSkinTemp(), "steps" to dao.countSteps(),
            "resp" to dao.countResp(), "gravity" to dao.countGravity(),
        )
    }.getOrDefault(emptyMap())

    /**
     * All cached daily metrics for [deviceId], oldest first, MERGED with the on-device
     * computed scores from "<deviceId>-noop". Imported rows win per day; computed rows
     * fill the days the import doesn't cover. Port of macOS Repository.mergeDaily.
     *
     * [deviceId] is the registry's ACTIVE strap id. Both the imported and computed buckets are read as the
     * UNION of (active id) AND the canonical "my-whoop" (SPINE / #814 + HIGH-2): a re-added strap writes
     * LIVE data under its fresh id while imported/computed HISTORY stays anchored on the canonical id, so a
     * union is what keeps that history visible. A single-WHOOP install resolves to "my-whoop" only, so this
     * is byte-identical there. Active id wins per day inside each bucket ([unionByDay]); imports still win
     * over computed across buckets ([mergeDaily]).
     */
    suspend fun daysMerged(deviceId: String): List<DailyMetric> {
        val imported = unionByDay(importedSourceIds(deviceId).map { dao.days(it) })
        val computed = unionByDay(computedSourceIds(deviceId).map { dao.days(it) })
        val activityFile = dao.days(ACTIVITY_FILE_SOURCE)
        // H5 (#509): days the user hand-edited the sleep of (the edit lives under the computed source); on
        // those days the computed sleep fields win over a re-imported night. Pool the edited sessions across
        // every computed source in the union so a re-add doesn't lose an earlier-id edit's precedence.
        val editedSessions = computedSourceIds(deviceId).flatMap { dao.editedSleepSessions(it) }
        return mergeActivityFileSteps(
            mergeDaily(imported = imported, computed = computed, userEditedDays = userEditedDays(editedSessions)),
            activityFile,
        )
    }

    /**
     * Union ([unionByDay]) of one daily flow per source id, emitting whenever any source changes. For the
     * common single-source (single-WHOOP) case it is the plain source flow (no extra operator). SPINE /
     * #814 + HIGH-2 read-side helper for [daysMergedFlow] / [recentDaysMergedFlow].
     */
    private fun unionDaysFlow(flows: List<Flow<List<DailyMetric>>>): Flow<List<DailyMetric>> =
        if (flows.size == 1) flows[0]
        else combine(flows) { arrays -> unionByDay(arrays.toList()) }

    /**
     * Reactive merged daily metrics (oldest first): imported rows win per day, computed "-noop" rows
     * gap-fill. Emits whenever any contributing source changes.
     *
     * [deviceId] is the registry's ACTIVE strap id. Imported and computed are each the UNION of (active id)
     * AND the canonical "my-whoop" (SPINE / #814 + HIGH-2): live data lands under a re-added strap's fresh
     * id while imported/computed history stays anchored on the canonical id, so the union is what keeps that
     * history on the dashboard after a re-add. Single-WHOOP installs resolve to "my-whoop" only ⇒ byte-
     * identical.
     *
     * H5 (#509): also keys off the computed sources' user-edited sessions so a hand-edited night's sleep
     * figures keep precedence over a re-imported night (and the chart re-emits when an edit lands).
     */
    fun daysMergedFlow(deviceId: String): Flow<List<DailyMetric>> =
        combine(
            unionDaysFlow(importedSourceIds(deviceId).map { dao.daysFlow(it) }),
            unionDaysFlow(computedSourceIds(deviceId).map { dao.daysFlow(it) }),
            dao.daysFlow(ACTIVITY_FILE_SOURCE),
            editedSleepSessionsFlow(deviceId),
        ) { imported, computed, activityFile, edited ->
            mergeActivityFileSteps(
                mergeDaily(imported = imported, computed = computed, userEditedDays = userEditedDays(edited)),
                activityFile,
            )
        }

    /**
     * #797: BOUNDED reactive merged daily metrics for the dashboard. Same per-day merge as
     * [daysMergedFlow] (imported wins, computed gap-fills, edited days keep the correction), but each
     * SOURCE is capped to the most-recent [RECENT_DAYS_CAP] rows before the merge, so a years-deep import
     * stops re-merging the WHOLE history on every DB change (the heavy refresh #797 is about). The cap is
     * generous enough to cover every current dashboard surface (Trends' deepest range, the 7-day Fitness
     * Age / Vitality windows). Rows come back oldest-first, IDENTICAL ordering to [daysMergedFlow], so the
     * consumer (Today / illness watch / Trends) is unchanged apart from no longer carrying ancient days the
     * UI never shows. Edited-day precedence still reads the userEdited sessions (not day-capped: the set is
     * already tiny), so a hand-edited recent night keeps winning.
     *
     * Like [daysMergedFlow] the imported/computed buckets are the active-id ∪ canonical "my-whoop" union
     * (SPINE / #814 + HIGH-2): the cap stays PER SOURCE, so the union is still bounded (at most two capped
     * pages per bucket) and #797's "never re-merge the whole 3000-day history" guarantee holds.
     */
    fun recentDaysMergedFlow(deviceId: String): Flow<List<DailyMetric>> =
        combine(
            unionDaysFlow(importedSourceIds(deviceId).map { dao.recentDaysFlow(it, RECENT_DAYS_CAP) }),
            unionDaysFlow(computedSourceIds(deviceId).map { dao.recentDaysFlow(it, RECENT_DAYS_CAP) }),
            dao.recentDaysFlow(ACTIVITY_FILE_SOURCE, RECENT_DAYS_CAP),
            editedSleepSessionsFlow(deviceId),
        ) { imported, computed, activityFile, edited ->
            // recentDaysFlow returns newest-first (DESC LIMIT); mergeDaily re-sorts ascending by day, so the
            // emitted order matches daysMergedFlow exactly.
            mergeActivityFileSteps(
                mergeDaily(imported = imported, computed = computed, userEditedDays = userEditedDays(edited)),
                activityFile,
            )
        }

    /** Pooled user-edited sleep sessions across every computed source in the active∪canonical union, so a
     *  re-add doesn't drop an earlier-id night's edit precedence (#509 + HIGH-2). Single-source ⇒ the plain
     *  flow. */
    private fun editedSleepSessionsFlow(deviceId: String): Flow<List<SleepSession>> {
        val flows = computedSourceIds(deviceId).map { dao.editedSleepSessionsFlow(it) }
        return if (flows.size == 1) flows[0]
        else combine(flows) { arrays -> arrays.flatMap { it } }
    }

    /**
     * Sleep sessions for [deviceId] in [from, to] (unix seconds) MERGED with the computed
     * "<deviceId>-noop" sessions. Imported sessions win per night-end day; computed sessions
     * gap-fill. Port of macOS Repository.mergeSleep. Sorted by startTs ascending.
     *
     * Both buckets are the UNION of (active id) AND the canonical "my-whoop" (SPINE / #814 + HIGH-2): the
     * WHOOP-export sleep import stays anchored on the canonical id while a re-added strap records live
     * nights under its fresh id, so a union keeps imported nights visible after a re-add. [mergeSleep] keys
     * each bucket by night-end day, LAST entry winning, so within a bucket the source ids are concatenated
     * canonical-FIRST then active-LAST, so the active (re-added/live) night wins a day both ids cover, and the
     * canonical (imported) night fills a day only it has. Single-WHOOP installs resolve to "my-whoop" only
     * ⇒ a single source per bucket and byte-identical behaviour.
     */
    suspend fun sleepSessionsMerged(
        deviceId: String,
        from: Long,
        to: Long,
        limit: Int = DEFAULT_LIMIT,
    ): List<SleepSession> = mergeSleep(
        imported = importedSourceIds(deviceId).reversed().flatMap { dao.sleepSessions(it, from, to, limit) },
        computed = computedSourceIds(deviceId).reversed().flatMap { dao.sleepSessions(it, from, to, limit) },
    )

    /** ALL imported sleep BLOCKS across the active∪canonical union (#814/#1008), keeping every session
     *  per day (a nap + a main night both survive) and dropping only EXACT-duplicate (startTs, endTs)
     *  blocks recorded under both union ids , active strap FIRST so it keeps the surviving copy. The
     *  Sleep tab's chevron walk reads this instead of the single canonical id, so a night recorded under
     *  a re-added strap's fresh id still surfaces (the downstream per-day imported-wins split is the
     *  caller's, exactly as before). Mirrors Swift Repository.unionSleepSessions. */
    suspend fun sleepSessionsUnion(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT):
        List<SleepSession> =
        dedupSleepBlocks(importedSourceIds(deviceId).flatMap { dao.sleepSessions(it, from, to, limit) })

    /** The COMPUTED ("-noop") twin of [sleepSessionsUnion]: all computed sleep blocks across the computed
     *  union ids, exact-duplicate blocks dropped (active's computed sibling first). Mirrors Swift
     *  Repository.unionComputedSleepSessions. */
    suspend fun computedSleepSessionsUnion(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT):
        List<SleepSession> =
        dedupSleepBlocks(computedSourceIds(deviceId).flatMap { dao.sleepSessions(it, from, to, limit) })

    /** Workouts over the read-side UNION of the active strap id AND the canonical "my-whoop" (#814 twin of
     *  [hrSamplesUnion] / [sleepSessionsUnion]): a re-added / newly-paired strap owns "whoop-<uuid>" while
     *  imports + prior data live under "my-whoop", so a read pinned to a SINGLE id strands the other's
     *  workouts — the Workouts screen then reads empty while Data Sources (which queries "my-whoop") shows
     *  them (#28). Exact-duplicate rows are dropped on the (startTs, sport) natural key, active-strap-first. */
    suspend fun workoutsUnion(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT): List<WorkoutRow> =
        dedupWorkoutsByKey(importedSourceIds(deviceId).flatMap { dao.workouts(it, from, to, limit) })

    /** The COMPUTED ("-noop") twin of [workoutsUnion] for detected workouts (the engine writes detected
     *  sessions under "<importedDeviceId>-noop"), across the computed union ids. */
    suspend fun detectedWorkoutsUnion(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT): List<WorkoutRow> =
        dedupWorkoutsByKey(computedSourceIds(deviceId).flatMap { dao.workouts(it, from, to, limit) })

    /** Cached daily metrics for the inclusive day range [from, to] (YYYY-MM-DD), oldest first. */
    suspend fun dailyMetrics(deviceId: String, from: String, to: String): List<DailyMetric> =
        dao.dailyMetricsRange(deviceId, from, to)

    // MARK: - Cross-source resolver (PR#196 , freshest-wins charts/metrics)
    //
    // Product surfaces (Compare/Insights/Stress/Explore/Today) historically read rows under the EXACT
    // requested source, hiding freshly-computed and Apple-compatible data sat under another device id.
    // [resolvedSeries] resolves a metric over an explicit precedence , imported WHOOP wins, NOOP-computed
    // fills the days it doesn't cover, and Apple Health only fills declared-compatible vitals on days
    // neither strap source has. Port of macOS Repository.resolvedSeries / sourceCandidates.

    /** One day's resolved value plus the source that supplied it (so a caption can name it). */
    data class ResolvedMetricPoint(
        val day: String,
        val value: Double,
        val source: String,
        val sourceKey: String,
    )

    /** A candidate (source, key) pair the resolver tries, in precedence order. */
    data class MetricSourceCandidate(val source: String, val key: String)

    /** One candidate's per-day resolver value. [weakSleepTotal] marks a sleep-total that came off a
     *  BARE daily aggregate ([bareSleepAggregate], #993): kept only until a later candidate offers a
     *  REAL scored value for the day , see [resolveFirstWins]. Class-nested (not companion-nested) so
     *  tests address it as `WhoopRepository.CandidateRow`, like [ResolvedMetricPoint]. */
    internal data class CandidateRow(
        val day: String,
        val value: Double,
        val weakSleepTotal: Boolean = false,
    )

    /** The full result of resolving one metric: the sources tried + the merged per-day points. */
    data class MetricSeriesResolution(
        val requestedSource: String,
        val candidates: List<MetricSourceCandidate>,
        val points: List<ResolvedMetricPoint>,
    ) {
        /** Plain (day, value) rows , the shape the chart/correlation code already consumes. */
        val values: List<Pair<String, Double>> get() = points.map { it.day to it.value }

        /** Distinct sources that actually contributed a point, in first-seen order (for a caption). */
        val usedSources: List<String>
            get() {
                val seen = LinkedHashSet<String>()
                for (p in points) seen.add(p.source)
                return seen.toList()
            }
    }

    /**
     * Product-facing daily series for [key] across every COMPATIBLE source, freshest-wins. Use this
     * on surfaces where the user expects the best available signal; use [metricSeries] where one source
     * must be honoured verbatim. Precedence per [sourceCandidates]: imported WHOOP > NOOP-computed >
     * declared-compatible Apple Health. [from]/[to] are YYYY-MM-DD bounds.
     *
     * [strapDeviceId] is the registry's ACTIVE strap id (SPINE / #814) , callers should thread it
     * (`vm.activeStrapId`) rather than lean on the legacy default. [sourceCandidates] unions in the
     * canonical "my-whoop" pair regardless, so history banked before a strap re-add still resolves
     * even from a caller that passes the canonical id (#1008).
     */
    suspend fun resolvedSeries(
        key: String,
        preferredSource: String,
        from: String,
        to: String,
        strapDeviceId: String = "my-whoop",
    ): MetricSeriesResolution {
        val candidates = sourceCandidates(key, preferredSource, strapDeviceId)
        // First candidate wins per day; later candidates only fill days no earlier one covered.
        // #993 exception inside [resolveFirstWins]: a day held only by a WEAK sleep-total (the bare
        // Health Connect aggregate under "my-whoop" , on the reporter's Pixel a constant 450-min
        // bedtime-schedule span) yields to a later candidate's REAL scored night, so Compare / Lab
        // Book / any resolver read agrees with the mergeDaily dashboards instead of re-surfacing the
        // schedule target the merge already rejects.
        val perCandidate = candidates.map { it to resolvedRows(it, from, to) }
        return MetricSeriesResolution(preferredSource, candidates, resolveFirstWins(perCandidate))
    }

    /**
     * Read one candidate's rows for the window: its metricSeries, plus the matching DailyMetric column
     * for any day the metricSeries doesn't carry (a Bluetooth-only WHOOP 5 user has values in the daily
     * columns but not the long-format series). Ascending by day.
     *
     * The DailyMetric read uses a +1-day upper buffer ([bufferDayAfter]). A night is keyed on its LOCAL
     * WAKE day, so the row backing the SELECTED day's Rest can sort on the day AFTER the caller's `to`
     * (a just-after-midnight wake, or a UTC+ user whose wake-day rolls a calendar day ahead of the
     * requested bound). Without the buffer that banked row was excluded and Today fell back to the latest
     * historical Rest (#614). The buffer only WIDENS the daily read; `byDay`'s metricSeries-first
     * precedence is unchanged, so an imported series point still wins its day.
     */
    private suspend fun resolvedRows(
        candidate: MetricSourceCandidate,
        from: String,
        to: String,
    ): List<CandidateRow> {
        val byDay = LinkedHashMap<String, CandidateRow>()
        for (row in dao.metricSeries(candidate.source, candidate.key, from, to)) {
            byDay[row.day] = CandidateRow(row.day, row.value)
        }
        // #993: a sleep-total read off a BARE daily aggregate (no efficiency, no stage minutes , the
        // Health Connect "my-whoop" backfill shape, where a stage-less bedtime-SCHEDULE record makes
        // the total a target like the reporter's constant 450 min) is flagged WEAK so a later
        // candidate's real scored night can supersede it in [resolveFirstWins]. metricSeries points
        // and every other daily column stay strong , byte-identical precedence.
        val sleepTotalKey = candidate.key == "sleep_total_min" || candidate.key == "asleep_min"
        for (row in dao.dailyMetricsRange(candidate.source, from, bufferDayAfter(to))) {
            if (!byDay.containsKey(row.day)) {
                dailyColumn(candidate.key, row)?.let {
                    byDay[row.day] = CandidateRow(row.day, it, sleepTotalKey && bareSleepAggregate(row))
                }
            }
        }
        return byDay.values.sortedBy { it.day }
    }

    /** The "yyyy-MM-dd" day one calendar day AFTER [day], or [day] verbatim when it isn't a parseable
     *  ISO date (e.g. the wide-open "9999-99-99" sentinel Today passes , already past every real day, so
     *  no buffer is needed). The +1-day read buffer in [resolvedRows] so a wake-day-keyed night that sorts
     *  just past the requested upper bound still resolves the selected day (#614). */
    private fun bufferDayAfter(day: String): String =
        runCatching { java.time.LocalDate.parse(day).plusDays(1).toString() }.getOrDefault(day)

    /**
     * A compact snapshot of how much history each source holds, for the Data Sources "Freshness
     * Pipeline" card (PR#196). Counts only , no per-day rows. Port of macOS RepositoryFreshness +
     * Repository.computeFreshness. Covers a wide window (the macOS 4000-day default).
     */
    suspend fun freshness(strapDeviceId: String = "my-whoop"): DataFreshness {
        val to = freshnessDayKey(1)
        val from = freshnessDayKey(-4000)
        val imported = dao.dailyMetricsRange(strapDeviceId, from, to)
        val computed = dao.dailyMetricsRange(computedDeviceId(strapDeviceId), from, to)
        val apple = dao.dailyMetricsRange(APPLE_HEALTH_SOURCE, from, to)
        val now = System.currentTimeMillis() / 1000L
        val lo = now - 4000L * 86_400L
        val hi = now + 86_400L
        val importedSleeps = dao.sleepSessions(strapDeviceId, lo, hi, DEFAULT_LIMIT)
        val computedSleeps = dao.sleepSessions(computedDeviceId(strapDeviceId), lo, hi, DEFAULT_LIMIT)
        val days = (imported + computed + apple).map { it.day }
        return DataFreshness(
            importedDays = imported.size,
            computedDays = computed.size,
            appleDays = apple.size,
            importedSleeps = importedSleeps.size,
            computedSleeps = computedSleeps.size,
            earliestDay = days.minOrNull(),
            latestDay = days.maxOrNull(),
        )
    }

    /** "yyyy-MM-dd" for today offset by [deltaDays], fixed UTC (freshness window bounds). */
    private fun freshnessDayKey(deltaDays: Int): String {
        val cal = java.util.Calendar.getInstance(java.util.TimeZone.getTimeZone("UTC"))
        cal.add(java.util.Calendar.DAY_OF_YEAR, deltaDays)
        return String.format(
            java.util.Locale.US, "%04d-%02d-%02d",
            cal.get(java.util.Calendar.YEAR),
            cal.get(java.util.Calendar.MONTH) + 1,
            cal.get(java.util.Calendar.DAY_OF_MONTH),
        )
    }

    // MARK: - Flows

    /** Reactive daily metrics (oldest first) for a device. */
    fun daysFlow(deviceId: String): Flow<List<DailyMetric>> = dao.daysFlow(deviceId)

    // MARK: - Frontier / convenience

    /** Persist HR samples directly (e.g. a live-tracked workout's 1 Hz series). Dedup-safe:
     *  `insertHr` IGNOREs on the (deviceId, ts) primary key, so re-inserts / a later offload sync
     *  covering the same seconds are no-ops. (#528) */
    suspend fun insertHr(rows: List<HrSample>) = dao.insertHr(rows)

    suspend fun latestHrSampleTs(deviceId: String): Long? = dao.latestHrSampleTs(deviceId)
    suspend fun latestHr(deviceId: String): HrSample? = dao.latestHr(deviceId)
    suspend fun latestBattery(deviceId: String): BatterySample? = dao.latestBattery(deviceId)

    companion object {
        /** A workout row is STRAP-NATIVE when NOOP recorded/scored it from a strap trace: a "manual"
         *  session or a detected bout (source "<id>-noop"). Everything else (Apple Health / Health Connect /
         *  WHOOP CSV / activity file) is IMPORTED and carries its own avg/max. Single source of truth for the
         *  classification shared by [fillWorkoutHrFromStrap] and [workoutHrDeviceIds]. */
        fun isStrapNativeWorkout(source: String): Boolean {
            val s = source.lowercase()
            return s == "manual" || s.endsWith("-noop")
        }

        /** A workout row is DETECTED when the engine scored it from a strap trace it recorded itself
         *  (source "<id>-noop"). This is the strict subset of [isStrapNativeWorkout] whose stored deviceId is
         *  RELIABLY the strap that recorded it. A "manual" row's is not: it holds whatever its creator passed
         *  — the "my-whoop" placeholder from the Workouts screen, or the active strap id from the auto-workout
         *  nudge — so manual rows read the union instead (see [workoutHrDeviceIds]). */
        fun isDetectedWorkout(source: String): Boolean = source.lowercase().endsWith("-noop")

        /** #510/#836: the device id(s) whose `hrSample` rows back a workout's Avg HR / calories / Effort
         *  recompute. A DETECTED row was charted from its OWN strap's trace, so read HR under that strap —
         *  strip the computed "-noop" suffix to reach the raw hrSample id (a detected row lives under
         *  "<id>-noop", its HR under "<id>"). Everything else — a MANUAL row or an IMPORTED one — reads the
         *  #814 UNION via [importedSourceIdsFor] (active strap ∪ canonical "my-whoop", active first), the
         *  same window #77 fills IMPORTED rows from. Byte-identical to the Swift twin
         *  (`Repository.workoutHrDeviceIds`), which has always kept only DETECTED on the single-id path.
         *
         *  Why MANUAL cannot key on its own `rowDeviceId`: [com.noop.ui.WorkoutEditing.buildManualRow]
         *  stores whatever `deviceId` its CALLER passes, and the two callers disagree — the Workouts screen
         *  passes the canonical "my-whoop" placeholder, while [com.noop.ui.AutoWorkoutNudge] deliberately
         *  passes the ACTIVE strap id (mirroring iOS `saveDetectedWorkout`). Both write source "manual", so
         *  the source string cannot tell them apart. Keying on the stored id therefore served the nudge rows
         *  and broke the placeholder ones: a manual workout on a SECOND WHOOP ("whoop-<mac>") or any re-added
         *  strap read the empty "my-whoop" window, leaving Avg HR un-reconciled and a null Effort
         *  un-recomputed (#836).
         *
         *  The union costs a nudge-created row its exact recording strap once the ACTIVE strap changes, which
         *  is deliberate and degrades safely in both directions: an empty window returns the row untouched
         *  (the `stats.n < minSamples` guard below), preserving whatever Avg HR was stored, and a non-empty
         *  one is the same wearer over the same interval — a re-added strap re-banks that history under its
         *  fresh id. A single-WHOOP install still resolves to one id, so nothing changes there.
         *  (This fill only sets avgHr/maxHr/strain; calories come from the detector.) */
        fun workoutHrDeviceIds(source: String, rowDeviceId: String, activeStrapId: String): List<String> =
            if (isDetectedWorkout(source)) listOf(rowDeviceId.removeSuffix("-noop"))
            else importedSourceIdsFor(activeStrapId)

        /** Default row cap on range reads. Matches the Swift call sites' bounded scans. */
        const val DEFAULT_LIMIT = 100_000

        /** #423: rolling retention for the raw-IMU capture table (1 row/strap-second, ~1.2 KB each). One
         *  hour ≈ 3600 rows ≈ 4 MB caps the table hard, so an enabled capture can never balloon the DB
         *  during a multi-day offload replay. Instrument-first bounded window; nothing consumes it yet. */
        const val RAW_IMU_RETENTION_ROWS = 3600

        /**
         * v31: rolling retention for the v18 aux-slot table (Swift twin `WhoopStore.v18AuxRetentionRows`).
         *
         * [RAW_IMU_RETENTION_ROWS] is the closest precedent — raw instrumentation banked as a blob, capped
         * rather than unbounded — and the same reasoning applies: nothing reads these rows yet, so a cap
         * is far cheaper to RELAX later than to impose once users have a year of history. Unbounded, this
         * table is the one genuinely new source of row growth in v31; the four named columns only WIDEN
         * rows that were already being written (~14 B on a gravity/skinTemp/sleepState row that exists
         * either way) and add no rows at all.
         *
         * 604,800 = 7 × 86,400, a week of strap-seconds if the strap emitted v18 every second of every
         * day. At ~85 B/row (a ≤30 B blob plus row and primary-key-index overhead) that is a ~50 MB hard
         * ceiling; in practice v18 seconds are a fraction of a day, so the cap spans considerably longer
         * in wall-clock terms. Applied per device, newest-first.
         */
        const val V18_AUX_RETENTION_ROWS = 604_800

        /** Rows to bank before running the retention sweep again. The sweep walks up to
         *  [V18_AUX_RETENTION_ROWS] index entries, so running it per insert batch was the cost; the table
         *  may sit this many rows (plus the crossing batch) above the cap in exchange, well under a MB
         *  against its ~50 MB ceiling. Swift twin: `WhoopStore.v18AuxPruneEveryRows`. */
        const val V18_AUX_PRUNE_EVERY_ROWS = 10_000

        /** #797: dashboard merge window cap (days). The bounded [recentDaysMergedFlow] keeps at most this
         *  many most-recent days per source, so a years-deep import stops re-merging the whole history on
         *  every DB change. ~2 years comfortably covers the deepest Trends range + the rolling 7-day
         *  Fitness Age / Vitality windows, so no current surface loses data. */
        const val RECENT_DAYS_CAP = 800

        /** Canonical source ids the resolver cross-references. The strap's real id is passed in. */
        const val WHOOP_SOURCE = "my-whoop"
        const val APPLE_HEALTH_SOURCE = "apple-health"
        const val HEALTH_CONNECT_SOURCE = "health-connect"
        const val ACTIVITY_FILE_SOURCE = "activity-file"

        /**
         * The IMPORTED daily-source ids to read for an [activeDeviceId]: the UNION of the active strap id
         * AND the canonical legacy "my-whoop", active FIRST (so a per-day pick takes the active/live row).
         * SPINE / #814 + HIGH-2. A re-added strap writes live data under its fresh id while the WHOOP-export
         * import path ([com.noop.ingest.WhoopCsvImporter]) keeps writing under the canonical "my-whoop"
         * (never drifting), so reading only the active id orphans the import. A single-WHOOP install resolves
         * to "my-whoop" only ⇒ one id, byte-identical reads. Companion form so [com.noop.ui.FusionDayAdapter]
         * (an object) and the instance reads share ONE definition.
         */
        fun importedSourceIdsFor(activeDeviceId: String): List<String> =
            if (activeDeviceId == WHOOP_SOURCE) listOf(WHOOP_SOURCE)
            else listOf(activeDeviceId, WHOOP_SOURCE)

        /** The COMPUTED ("-noop") source ids mirroring [importedSourceIdsFor] (the engine writes computed
         *  scores under "<importedDeviceId>-noop"). */
        fun computedSourceIdsFor(activeDeviceId: String): List<String> =
            importedSourceIdsFor(activeDeviceId).map { "$it-noop" }

        /** Pick the winner among per-source LATEST rows ([computedSourceIdsFor] order, active-strap
         *  first): the strictly newest day wins; a shared newest day keeps the FIRST seen (the active
         *  strap) — byte-identical to what `mergeComputedSeriesUnion(...).lastOrNull()` yields on the
         *  full series, computed from one LIMIT-1 row per source instead of materializing the whole
         *  history (perf: the Today/Health latest-value tiles). Pure companion for [ResolverUnionTest]. */
        internal fun latestFromPerSourceLatest(perSource: List<MetricSeriesRow?>): MetricSeriesRow? {
            var best: MetricSeriesRow? = null
            for (row in perSource) {
                if (row == null) continue
                if (best == null || row.day > best.day) best = row   // strictly newer wins; ties keep first (active)
            }
            return best
        }

        /** Merge per-source computed ("-noop") metricSeries rows into one series, DEDUPED per day: the
         *  ACTIVE strap's value wins over the canonical import's on a shared day. [perSource] is in
         *  [computedSourceIdsFor] order (active-strap first), so keeping the FIRST row seen per day
         *  preserves the active value — the same active-first idiom as [dedupSleepBlocks]. Result is
         *  day-sorted ascending. Pure companion for [ResolverUnionTest]. Mirrors the computed-union layer
         *  of Swift Repository.exploreSeries. (#349) */
        internal fun mergeComputedSeriesUnion(perSource: List<List<MetricSeriesRow>>): List<MetricSeriesRow> {
            val byDay = LinkedHashMap<String, MetricSeriesRow>()
            for (rows in perSource) {
                for (row in rows) byDay.putIfAbsent(row.day, row)   // active-first: first seen per day wins
            }
            return byDay.values.sortedBy { it.day }
        }

        /** Drop sleep blocks sharing an identical (startTs, endTs) , the same physical night recorded
         *  under two #814 union ids , keeping the FIRST seen (the callers pass active-strap-first lists,
         *  so the active copy survives). Genuinely distinct blocks (a nap + a main night) are preserved.
         *  Pure companion form so the JVM tests exercise it without Room ([ResolverUnionTest]). Mirrors
         *  Swift Repository.dedupBlocks. (#1008) */
        internal fun dedupSleepBlocks(sessions: List<SleepSession>): List<SleepSession> {
            val seen = HashSet<Pair<Long, Long>>()
            return sessions.filter { seen.add(it.startTs to it.endTs) }
        }

        /** Drop exact-duplicate workouts sharing an identical (startTs, sport) natural key — the same
         *  session read under two #814 union ids — keeping the FIRST seen (callers pass active-strap-first
         *  lists). Twin of [dedupSleepBlocks]. (#28) */
        internal fun dedupWorkoutsByKey(rows: List<WorkoutRow>): List<WorkoutRow> {
            val seen = HashSet<Pair<Long, String>>()
            return rows.filter { seen.add(it.startTs to it.sport) }
        }

        /** Build a repository backed by the process-wide singleton database. */
        fun from(context: Context): WhoopRepository = WhoopRepository(WhoopDatabase.get(context))

        // MARK: - Compact per-epoch JSON (v18 motionJSON / sleepStateJSON), byte-equivalent with Swift's
        // JSONEncoder/JSONDecoder on [Double] / [Int]: a bare `[..]` array, whole doubles emitted WITHOUT a
        // trailing `.0` (Swift encodes 3.0 as `3`, 1.5 as `1.5`). Hand-built rather than org.json so the
        // string round-trips identically across platforms; decode tolerates either form.

        /** A single double in Swift JSONEncoder's form: an integral value as a bare integer (`3`, `0`),
         *  otherwise its shortest decimal (`1.5`, `12.25`). */
        internal fun encodeDouble(x: Double): String =
            if (x.isFinite() && x == kotlin.math.floor(x) && !x.isInfinite()) x.toLong().toString() else x.toString()

        internal fun encodeDoubleArray(xs: List<Double>): String =
            xs.joinToString(separator = ",", prefix = "[", postfix = "]") { encodeDouble(it) }

        internal fun encodeIntArray(xs: List<Int>): String =
            xs.joinToString(separator = ",", prefix = "[", postfix = "]") { it.toString() }

        /** Parse a bare JSON number array to doubles, or null when unparseable (absent stays absent). */
        internal fun decodeDoubleArray(json: String): List<Double>? = runCatching {
            val arr = org.json.JSONArray(json)
            List(arr.length()) { arr.getDouble(it) }
        }.getOrNull()

        /** Parse a bare JSON number array to ints, or null when unparseable. */
        internal fun decodeIntArray(json: String): List<Int>? = runCatching {
            val arr = org.json.JSONArray(json)
            List(arr.length()) { arr.getInt(it) }
        }.getOrNull()

        /**
         * Candidate (source, key) pairs to try for [key], in precedence order, given the user's
         * [preferredSource]. The strap's real id is [strapDeviceId], so the computed sibling is
         * "$strapDeviceId-noop". Port of macOS Repository.sourceCandidates:
         *  • strap-preferred → [imported strap, computed strap, compatible Apple] (Apple only for
         *    vitals with a declared 1:1 mapping);
         *  • Apple-preferred → [Apple] (+ computed strap ONLY for steps/active_kcal, which the strap
         *    estimates and Apple may not carry);
         *  • any other source → itself only (nutrition/mood are single-source by design).
         */
        internal fun sourceCandidates(
            key: String,
            preferredSource: String,
            strapDeviceId: String,
        ): List<MetricSourceCandidate> {
            val computedSource = "$strapDeviceId-noop"
            fun uniqued(cs: List<MetricSourceCandidate>): List<MetricSourceCandidate> {
                val seen = LinkedHashSet<MetricSourceCandidate>()
                for (c in cs) seen.add(c)
                return seen.toList()
            }
            if (preferredSource == WHOOP_SOURCE || preferredSource == strapDeviceId) {
                // Active strap first (live/measured wins per day), then the CANONICAL "my-whoop" import,
                // THEN the computed siblings, so history banked under the canonical id before a re-add
                // still resolves (the #814/#1008 union model) AND imports outrank computed estimates — the
                // documented `imported WHOOP > NOOP-computed` order. The computed sibling used to sit ahead
                // of the canonical import, so after a device re-add (active != canonical) the new strap's
                // computed estimates shadowed richer imported my-whoop history. uniqued() collapses these
                // to one pair per source on a single-device install (active == canonical), so that path
                // stays byte-identical. Apple is the final cross-source fallback. Mirrors Swift
                // Repository.sourceCandidates (ryanbr/noop#241).
                val candidates = mutableListOf(
                    MetricSourceCandidate(strapDeviceId, key),
                    MetricSourceCandidate(WHOOP_SOURCE, key),
                    MetricSourceCandidate(computedSource, key),
                    MetricSourceCandidate("$WHOOP_SOURCE-noop", key),
                )
                appleCompatibleKey(key)?.let {
                    candidates.add(MetricSourceCandidate(APPLE_HEALTH_SOURCE, it))
                }
                return uniqued(candidates)
            }
            if (preferredSource == APPLE_HEALTH_SOURCE) {
                val candidates = mutableListOf(MetricSourceCandidate(APPLE_HEALTH_SOURCE, key))
                // Health Connect is an Apple-equivalent body-metric source on Android , a real Apple
                // EXPORT still wins per day (it's first), HC fills the rest. This is what makes a
                // Health-Connect-only weight history visible in Compare (#443); HC now emits a "weight"
                // metricSeries under this source from HealthConnectImporter.
                candidates.add(MetricSourceCandidate(HEALTH_CONNECT_SOURCE, key))
                if (noopComputedCanFillAppleMetric(key)) {
                    candidates.add(MetricSourceCandidate(computedSource, key))
                }
                return uniqued(candidates)
            }
            return listOf(MetricSourceCandidate(preferredSource, key))
        }

        /** The Apple-Health series key carrying the SAME quantity as a WHOOP key; null = no fallback. */
        internal fun appleCompatibleKey(key: String): String? = when (key) {
            "rhr" -> "resting_hr"
            "hrv", "spo2", "resp_rate", "avg_hr", "max_hr", "in_bed_min", "active_kcal" -> key
            "sleep_total_min" -> "asleep_min"
            "sleep_deep_min" -> "deep_min"
            "sleep_rem_min" -> "rem_min"
            "sleep_light_min" -> "core_min"
            else -> null
        }

        /** Whether the NOOP-computed strap source may fill an Apple-preferred metric. Only the two
         *  daily totals the strap genuinely estimates (steps, calories) , never a derived score. */
        private fun noopComputedCanFillAppleMetric(key: String): Boolean = when (key) {
            "steps", "active_kcal" -> true
            else -> false
        }

        /**
         * The DailyMetric column backing a resolver key, for days the metricSeries doesn't cover
         * (strap-only WHOOP 5 users). Also handles the Apple-compatible sleep aliases (asleep_min /
         * deep_min / rem_min / core_min) the resolver may request. Keys with no daily column return
         * null. Mirrors macOS Repository.dailyColumn.
         *
         * `sleep_performance` (the Rest composite, 0–100) is NOT a stored column: IntelligenceEngine
         * persists it as a metricSeries point. But a Bluetooth-only WHOOP 5 user , and, crucially, the
         * SELECTED (just-synced) day before the heavy daily pass has projected the series , has the
         * night's totals banked on the DailyMetric row while the metricSeries point is still missing.
         * Without this case the resolver returned no Rest for that day and Today borrowed the latest
         * historical value (#614). Derive it on the fly from the same banked totals via the single
         * source of truth [com.noop.analytics.RestScorer.restFromDaily] (the SAME composite the series
         * carries), so the day resolves to its own Rest. Consistency is left to the scorer's neutral
         * default here (the daily row carries no regularity term).
         */
        internal fun dailyColumn(key: String, d: DailyMetric): Double? = when (key) {
            "recovery" -> d.recovery
            "hrv" -> d.avgHrv
            "rhr", "resting_hr" -> d.restingHr?.toDouble()
            "strain" -> d.strain
            "resp_rate" -> d.respRateBpm
            "spo2" -> d.spo2Pct
            "skin_temp" -> d.skinTempDevC
            "sleep_total_min", "asleep_min" -> d.totalSleepMin
            "sleep_efficiency" -> d.efficiency
            "sleep_deep_min", "deep_min" -> d.deepMin
            "sleep_rem_min", "rem_min" -> d.remMin
            "sleep_light_min", "core_min" -> d.lightMin
            "sleep_performance" -> com.noop.analytics.RestScorer.restFromDaily(d)
            "steps" -> d.steps?.toDouble()
            "active_kcal", "energy_kcal" -> d.activeKcalEst
            else -> null
        }

        /**
         * #993: whether [d]'s sleep block is a BARE aggregate , a totalSleepMin with NO efficiency and
         * NO stage minutes beside it. That is exactly the shape HealthConnectImporter backfills under
         * "my-whoop" (only the aggregates HC carries; sleep detail columns all null), and on a phone
         * whose OS banks a stage-less bedtime-SCHEDULE SleepSessionRecord the total is the SCHEDULE
         * length (the reporter's constant 450 min), a target rather than measured sleep. Session-grade
         * rows (WHOOP CSV / Xiaomi imports, every strap-computed night) always carry efficiency and/or
         * stages, so they never match. Shared by [mergeDaily] and the cross-source resolver so the two
         * read paths apply ONE definition of "not real scored sleep".
         */
        internal fun bareSleepAggregate(d: DailyMetric): Boolean =
            d.totalSleepMin != null && d.efficiency == null &&
                d.deepMin == null && d.remMin == null && d.lightMin == null

        /**
         * The resolver's per-day merge, pure for JVM tests: first candidate wins per day; later
         * candidates only fill days no earlier one covered , byte-identical to the historical loop ,
         * EXCEPT (#993) a day held only by a WEAK sleep-total (a bare imported aggregate, e.g. the
         * Health Connect 450-min schedule span) is REPLACED by a later candidate's real scored value
         * (the strap-computed night). A weak value with no stronger sibling still shows (an HC-only
         * user keeps their sleep, #983) , never fabricate, never blank.
         */
        internal fun resolveFirstWins(
            perCandidate: List<Pair<MetricSourceCandidate, List<CandidateRow>>>,
        ): List<ResolvedMetricPoint> {
            val byDay = LinkedHashMap<String, ResolvedMetricPoint>()
            val weakDays = HashSet<String>()
            for ((candidate, rows) in perCandidate) {
                for (row in rows) {
                    val taken = byDay.containsKey(row.day)
                    if (!taken || (row.day in weakDays && !row.weakSleepTotal)) {
                        byDay[row.day] = ResolvedMetricPoint(row.day, row.value, candidate.source, candidate.key)
                        if (row.weakSleepTotal) weakDays.add(row.day) else weakDays.remove(row.day)
                    }
                }
            }
            return byDay.values.sortedBy { it.day }
        }

        /**
         * Collapse the per-day rows of one logical bucket that is physically split across MORE THAN ONE
         * source id into a single row per day, EARLIER list wins the day (SPINE / #814 + HIGH-2). Used to
         * fold the active strap id's rows together with the canonical "my-whoop" rows BEFORE [mergeDaily]:
         * [lists] arrives in precedence order (active id first, canonical second), so a day the re-added
         * strap has LIVE/measured data for wins over the same day in the canonical import, while a day only
         * the canonical import covers is still surfaced (no longer orphaned). Pure + order-stable: the
         * de-dupe is keyed on `day`, and the result is re-sorted oldest-first downstream by [mergeDaily], so
         * input order across lists only decides the per-day winner, never the emitted order. A single-source
         * caller (single-WHOOP install) passes one list and gets it back unchanged.
         */
        internal fun unionByDay(lists: List<List<DailyMetric>>): List<DailyMetric> {
            if (lists.size == 1) return lists[0]
            val byDay = LinkedHashMap<String, DailyMetric>()
            // First list wins: only fill a day a later (lower-precedence) list covers and an earlier one didn't.
            for (list in lists) for (d in list) byDay.putIfAbsent(d.day, d)
            return byDay.values.toList()
        }

        /**
         * Merge HR sample lists (the active-id ∪ canonical "my-whoop" union) into one time-ordered
         * stream, deduped by ts with the FIRST list (the active strap) winning on a tie. Kotlin twin of
         * the Swift Repository.hrSamples(from:to:) union body. A single-id read (single-WHOOP install)
         * returns that list untouched, so the union is byte-identical there. (#908 / SPINE #814.)
         */
        internal fun mergeHrByTs(lists: List<List<HrSample>>): List<HrSample> {
            if (lists.size == 1) return lists[0]
            val byTs = LinkedHashMap<Long, HrSample>()
            for (list in lists) for (s in list) byTs.putIfAbsent(s.ts, s)
            return byTs.values.sortedBy { it.ts }
        }

        /**
         * Merge HR bucket lists (the active-id ∪ canonical union) into one time-ordered stream, deduped
         * by bucket start with the FIRST list (the active strap) winning on a tie. Kotlin twin of the
         * Swift Repository.hrBuckets(from:to:) union body. Single-id ⇒ byte-identical. (#908 / SPINE #814.)
         */
        internal fun mergeHrBucketsByStart(lists: List<List<HrBucket>>): List<HrBucket> {
            if (lists.size == 1) return lists[0]
            val byStart = LinkedHashMap<Long, HrBucket>()
            for (list in lists) for (b in list) byStart.putIfAbsent(b.bucket, b)
            return byStart.values.sortedBy { it.bucket }
        }

        /**
         * Pure pick of the latest classed @63 activity across the union's per-id step-sample lists: the
         * non-null [com.noop.data.StepSample.activityClass] on the greatest-ts sample, resolving a ts tie in
         * favour of the FIRST list (the active strap, mirroring the union's active-wins rule). Kotlin twin of
         * the Swift Repository.latestActivityClass. A single non-empty list reduces to "last non-null class in
         * that list"; an empty union returns null (no icon). (#908 family / #316.)
         */
        internal fun latestActivityClass(lists: List<List<StepSample>>): Int? {
            var bestTs = Long.MIN_VALUE
            var bestClass: Int? = null
            for (list in lists) for (s in list) {
                // Strict > keeps the FIRST list's sample on an exact ts tie: earlier lists are scanned first,
                // so a later list's equal-ts sample never overwrites the active strap's.
                if (s.activityClass != null && s.ts > bestTs) {
                    bestTs = s.ts
                    bestClass = s.activityClass
                }
            }
            return bestClass
        }

        /**
         * Imported daily rows win per day; computed rows fill the days the import doesn't
         * cover. Returns oldest→newest by day string (lexicographic = chronological for
         * YYYY-MM-DD). Port of macOS Repository.mergeDaily.
         *
         * H5 (#509): a day in [userEditedDays] is one the user hand-edited the sleep of. For those days
         * the COMPUTED row's SLEEP fields (the edit) take precedence over the import , otherwise a
         * re-imported WHOOP/Apple night would silently mask the correction. Non-sleep fields still follow
         * the imports-win merge, and every NON-edited day is unchanged (the default empty set).
         *
         * #993: an imported row whose sleep block is a BARE aggregate (totalSleepMin with no efficiency
         * and no stage minutes , the Health Connect "my-whoop" backfill shape) never overrides a night
         * the strap actually scored: the computed row's WHOLE sleep block wins for that day. Keeps a
         * bedtime-SCHEDULE span (a constant 450 min target on the reporter's Pixel) out of every sleep
         * surface while a session-grade import (WHOOP CSV / Xiaomi) still wins exactly as before.
         */
        internal fun mergeDaily(
            imported: List<DailyMetric>,
            computed: List<DailyMetric>,
            userEditedDays: Set<String> = emptySet(),
        ): List<DailyMetric> {
            val byDay = LinkedHashMap<String, DailyMetric>()
            for (d in computed) byDay[d.day] = d // computed first…
            // …import overwrites, so a real WHOOP import always wins , BUT coalesce the strap-only
            // on-device metrics (steps / calories / RSA resp) from the computed row, since importers
            // (esp. Health Connect) write a "my-whoop" daily row with those columns null and would
            // otherwise blank them on days the import also covers. (#78)
            for (d in imported) {
                val c = byDay[d.day]
                // Per-FIELD coalesce: the imported row wins for every column it actually has, but any
                // column it leaves null is gap-filled from the computed row. A real WHOOP import has
                // its scores/stages set, so "d.x ?: c.x" is a no-op there. A Health Connect import,
                // though, writes a "my-whoop" row with recovery/strain/sleep-stages NULL , without this
                // it would BLANK a strap-computed day (and a stale one already written stays blanked).
                // Coalescing every nullable field both prevents that and HEALS days already shadowed. (#112)
                val merged = if (c == null) d else d.copy(
                    totalSleepMin = d.totalSleepMin ?: c.totalSleepMin,
                    efficiency = d.efficiency ?: c.efficiency,
                    deepMin = d.deepMin ?: c.deepMin,
                    remMin = d.remMin ?: c.remMin,
                    lightMin = d.lightMin ?: c.lightMin,
                    disturbances = d.disturbances ?: c.disturbances,
                    restingHr = d.restingHr ?: c.restingHr,
                    avgHrv = d.avgHrv ?: c.avgHrv,
                    recovery = d.recovery ?: c.recovery,
                    strain = d.strain ?: c.strain,
                    exerciseCount = d.exerciseCount ?: c.exerciseCount,
                    spo2Pct = d.spo2Pct ?: c.spo2Pct,
                    skinTempDevC = d.skinTempDevC ?: c.skinTempDevC,
                    respRateBpm = d.respRateBpm ?: c.respRateBpm,
                    steps = d.steps ?: c.steps,
                    activeKcalEst = d.activeKcalEst ?: c.activeKcalEst,
                    // Raw SpO2 is on-device only (imports never carry it), so the imported row's null
                    // is backfilled from the computed row — otherwise the nightly means would be lost. (#93)
                    spo2Red = d.spo2Red ?: c.spo2Red,
                    spo2Ir = d.spo2Ir ?: c.spo2Ir,
                )
                // #993: a BARE imported sleep total must never override a night the strap actually
                // scored. HealthConnectImporter backfills a "my-whoop" daily row carrying ONLY
                // totalSleepMin (efficiency / deep / rem / light all null , see its DailyMetric
                // construction), and on a phone whose OS banks a bedtime-SCHEDULE SleepSessionRecord
                // (stage-less, so the importer falls back to the raw session span) that total is the
                // SCHEDULE length , the reporter's Pixel wrote a constant 450 min (= the 23:00-06:30
                // default), a TARGET, not measured sleep. The on-open HC auto-sync races the analyze
                // pass (the fresh day has no computed row yet, so the importer's coveredDays guard
                // misses it), and once the 450 landed, the imports-win coalesce above kept it forever:
                // every surface read 7h30, the SleepScreen need floor (450) then made debt 0 and
                // hours-vs-need 100, while the session rows underneath stayed correct. The per-field
                // coalesce could even emit an internally INCONSISTENT row (import's total beside the
                // computed row's stage minutes). Rule: sleep DURATION figures must come from actually
                // scored sleep , when the import's sleep block is a bare aggregate (no efficiency and
                // no stage minutes beside the total) and the computed row scored a real night, the
                // WHOLE sleep block comes from the computed row. A session-grade import (WHOOP CSV /
                // Xiaomi rows always carry efficiency and stages) still wins unchanged, and an
                // HC-only user (no computed night) keeps their bare total (#983). Healing, not just
                // preventing: this is the read-side rollup, so days already shadowed come back right.
                // No Swift twin needed: only Android's HC importer backfills under the strap source
                // (iOS Apple Health rows live under "apple-health" and never enter this bucket).
                // [bareSleepAggregate] is the ONE shared definition (the resolver applies it too).
                val bareImportedSleepTotal = bareSleepAggregate(d)
                // H5: on an edited day, the computed (edit-derived) SLEEP fields win over the import.
                // #993 vs #547 reconciliation: a bare import is only demoted when the computed row is a
                // REAL scored night (non-bare). A bare-vs-bare day keeps imports-win, that is the #547
                // guarantee (Apple's asleep 414 must correct a stage-less computed 721 in-bed total).
                byDay[d.day] = if (c != null &&
                    (d.day in userEditedDays ||
                        (bareImportedSleepTotal && c.totalSleepMin != null && !bareSleepAggregate(c)))
                ) {
                    merged.copy(
                        totalSleepMin = c.totalSleepMin,
                        efficiency = c.efficiency,
                        deepMin = c.deepMin,
                        remMin = c.remMin,
                        lightMin = c.lightMin,
                        disturbances = c.disturbances,
                    )
                } else {
                    merged
                }
            }
            return byDay.values.sortedBy { it.day }
        }

        internal fun mergeActivityFileSteps(
            base: List<DailyMetric>,
            activityFile: List<DailyMetric>,
        ): List<DailyMetric> {
            if (activityFile.isEmpty()) return base
            val byDay = LinkedHashMap<String, DailyMetric>()
            for (row in base) byDay[row.day] = row
            for (row in activityFile) {
                val steps = row.steps ?: continue
                if (steps <= 0) continue
                val existing = byDay[row.day]
                byDay[row.day] = if (existing == null) row else if (existing.steps == null) {
                    existing.copy(steps = steps)
                } else {
                    existing
                }
            }
            return byDay.values.sortedBy { it.day }
        }

        /**
         * The set of LOCAL wake-days that carry a user-edited sleep session , keyed exactly as
         * `DailyMetric.day` (the engine's offset-local-day keyer, matching [mergeSleep]'s endDay). Drives
         * the H5 edit-merge precedence in [mergeDaily]. Port of macOS Repository.userEditedDays.
         */
        internal fun userEditedDays(sessions: List<SleepSession>): Set<String> {
            val days = HashSet<String>()
            for (s in sessions) {
                if (!s.userEdited) continue
                val offsetSec = (java.util.TimeZone.getDefault().getOffset(s.endTs * 1000) / 1000).toLong()
                days.add(com.noop.analytics.AnalyticsEngine.dayString(s.endTs, offsetSec))
            }
            return days
        }

        /**
         * Same precedence for sleep sessions, keyed by the LOCAL day the night ends on (#304).
         * Brought into line with macOS Repository.mergeSleep, which keys on the local wake-day. A
         * UTC key put a night that ends after local-but-before-UTC midnight (a UTC+ user waking
         * early) under yesterday's UTC date, so the dashboard's local "today" read missed it and
         * surfaced the previous night. The local key matches how IntelligenceEngine buckets nights
         * and how the resolver looks up "today". REUSES the existing
         * `AnalyticsEngine.dayString(ts, offsetSec)` overload , do NOT add a new offset overload,
         * it clashes on the JVM signature and breaks the build.
         */
        internal fun mergeSleep(
            imported: List<SleepSession>,
            computed: List<SleepSession>,
        ): List<SleepSession> {
            fun endDay(s: SleepSession): String {
                val offsetSec = (java.util.TimeZone.getDefault().getOffset(s.endTs * 1000) / 1000).toLong()
                return com.noop.analytics.AnalyticsEngine.dayString(s.endTs, offsetSec)
            }
            return mergeSleepRichness(imported, computed, ::endDay).sortedBy { it.startTs }
        }

        /** Imported-wins-per-day sleep merge WITH the #241 richness exception, returned UNSORTED so callers
         *  can apply their own sort/keyer. [mergeSleep] is this keyed by local wake-day + sorted by startTs;
         *  the Sleep screen (SleepScreen) keys the same way but sorts by effectiveStartTs (#395), so it calls
         *  this directly to get the SAME richness rule the browse/CSV path uses.
         *
         *  #715 — preserve EVERY session (a day with a main night + a nap must keep both). Richness exception
         *  (ryanbr/noop#241): a sparse import (no stage data on ANY of its sessions that day) must NOT clobber
         *  a computed day that HAS stage data — otherwise a stage-less WHOOP/Apple/HC re-import blanks the
         *  stage breakdown for a night the strap fully staged. Days where the import carries stages, or where
         *  neither side does, keep the imported-wins rule. Mirrors WhoopStore.SleepMerge (SleepMergeTests). */
        internal fun mergeSleepRichness(
            imported: List<SleepSession>,
            computed: List<SleepSession>,
            endDay: (SleepSession) -> String,
        ): List<SleepSession> {
            val importedByDay = imported.groupBy(endDay)
            val computedByDay = computed.groupBy(endDay)
            val out = ArrayList<SleepSession>(imported.size + computed.size)
            for ((day, imp) in importedByDay) {
                val comp = computedByDay[day]
                if (comp != null && imp.none { hasStages(it) } && comp.any { hasStages(it) }) {
                    out.addAll(comp)   // richer computed day survives a stage-less import
                } else {
                    out.addAll(imp)    // imported wins its day (unchanged rule)
                }
            }
            for ((day, comp) in computedByDay) if (day !in importedByDay) out.addAll(comp)
            return out
        }

        /** True when the session carries a non-empty stage payload; null, "", and "[]" carry none.
         *  Twin of WhoopStore.SleepMerge.hasStages. */
        private fun hasStages(s: SleepSession): Boolean {
            val json = s.stagesJSON?.trim() ?: return false
            return json.isNotEmpty() && json != "[]"
        }
    }
}

/** OnConflictStrategy.IGNORE returns the new rowid, or -1 when the row was skipped. */
private fun List<Long>.countInserted(): Int = count { it != -1L }
