package com.noop.oura

// OuraEvents: the decoded value structs the driver emits (OURA_PROTOCOL.md s6). Kotlin twin of
// OuraEvents.swift. Each carries the record's ringTimestamp (the ring-clock value; the app anchors it
// to UTC via the 0x42 time-sync / 0x85 RTC events) plus the decoded signal. Pure value types, no
// android.bluetooth.
//
// DIVERGENCE FROM SWIFT: Swift's UInt32 ringTimestamp becomes a Long holding the unsigned 32-bit
// value (0..0xFFFFFFFF), and Swift's Int64 epoch becomes Long. Values and layouts are identical.
//
// Per-sample timestamps inside a record (IBI/temp/HRV/SpO2) walk backward from the event time by each
// sample's own duration (OURA_PROTOCOL.md s6); to stay platform-pure and avoid baking a clock model
// into the decoders, the structs carry the raw ring/sample offsets and let the app's mapping layer
// apply the anchor. Honest-data invariant: a short/malformed record decodes to null upstream, so
// these structs only ever hold real decoded values.

/**
 * WHICH optical channel decoded an [OuraIBI] (#1071).
 *
 * The ring reports the SAME heartbeats on more than one tag. They are not different beats and not
 * duplicate records — they are independent measurements of one beat train, so a consumer that folds
 * them together holds two copies of every night and every variability statistic built on successive
 * differences (RMSSD, SDNN) breaks. The tag is the only thing that separates them at ingest; after the
 * fact the two are only separable by the accident that their quantisation grids differ.
 *
 * [code] is the DURABLE cross-platform storage value (it reaches `rrInterval.srcChannel`), pinned to
 * Swift `OuraIBIChannel` / `RRSourceChannel`. Never renumber a case; only append.
 *
 * Byte-identical twin of Swift's `OuraIBIChannel`.
 */
enum class OuraIbiChannel(val code: Int) {
    /**
     * 0x80 `green_ibi_quality_event` (s6.4) — green LED, gated on the ring's own `quality == 1` flag
     * and a 300-2000 ms physiological window, and it runs for the WHOLE wear period.
     */
    GREEN_QUALITY(1),

    /**
     * 0x6E `spo2_ibi_and_amplitude_event` (s6.3) — the SpO2 measurement's own beat train, quantised to
     * an 8 ms grid with NO quality gate, and only present while an SpO2 measurement is running.
     */
    SPO2_IBI(2),

    /** 0x60 `ibi_and_amplitude_event` (s6.1) — the bit-packed IBI + amplitude family. */
    IBI_AMPLITUDE(3),

    /**
     * 0x44 `ibi_event` (s6 / s0) — the SAME bit-packed layout as 0x60 and decoded by the same routine,
     * but a DIFFERENT tag on the wire, so it gets its own code.
     *
     * Both tags stamped [IBI_AMPLITUDE] until now, which made them indistinguishable once stored. That
     * hid the question the scoring-channel choice turns on: when that channel covers 1.25x the
     * wall-clock it spans, is ONE tag repeating beats across its records, or are TWO tags reporting the
     * same beats to each other? No stored night could answer it, because the label collapsed them.
     * Separating the codes costs nothing and makes the next capture decisive. Labelling only — both
     * tags decode and are read exactly as before.
     */
    IBI_BARE(4),
    ;

    companion object {
        /** The channel with this durable storage [code], or null for an unknown/absent one. */
        fun fromCode(code: Int?): OuraIbiChannel? = entries.firstOrNull { it.code == code }
    }
}

/**
 * One decoded inter-beat interval (and optional amplitude), in milliseconds.
 *
 * [channel] is which optical channel measured the beat (#1071). Every decoder stamps its own; null
 * only for a value built by something that is not one of them — never a guess.
 */
data class OuraIBI(
    val ringTimestamp: Long,
    val ibiMs: Int,
    val amplitude: Int? = null,
    val channel: OuraIbiChannel? = null,
)

/** One decoded heart-rate value in BPM (derived from a live-HR push IBI, OURA_PROTOCOL.md s5.6). */
data class OuraHR(val ringTimestamp: Long, val bpm: Int, val ibiMs: Int)

/**
 * One decoded 5-min HRV bucket from the ring's own 0x5D tag: the ring's avg HR (bpm) + avg RMSSD (ms),
 * both u8 (no scaling). The 0x5D body is a run of (u8 hr, u8 rmssd) pairs, one per 5 min; [index] is the
 * pair's position in the record (buckets ~5 min apart). Ring's open summary tag, NOT Oura's readiness
 * score. Twin of Swift OuraHRV.
 */
data class OuraHRV(
    val ringTimestamp: Long,
    /**
     * 0-based pair index within the record, counting from the record's FIRST byte-pair — which is its
     * OLDEST bucket (#1167). The consumer needs [count] as well as [index] to place the bucket:
     * `bucketTs = ts - (count - index) * 300`.
     */
    val index: Int,
    val hrBpm: Int,
    val rmssdMs: Int,
    /**
     * Total pairs in the record this bucket came from — INCLUDING any `00 00` padding pair the decoder
     * dropped (#1128/#1131). [index] is always in `0 until count`. Needed because the record's timestamp
     * marks the END of the span it covers, so a bucket's offset is measured from the record's tail, not
     * its head: dropping a pad without counting it would slide every surviving bucket in the record.
     * Mirrors `OuraSpO2.count`, which the SpO2 path already uses for the same reason. Twin of Swift.
     */
    val count: Int = 1,
)

/**
 * One decoded SpO2 sample. `value` is the raw SpO2 reading; `unit` documents its scale.
 *
 * A single 0x6F / 0x77 record carries MANY samples, all sharing the record's [ringTimestamp].
 * [index]/[count] carry the sample's position within its record so the consumer can give each one its
 * own second — without them the position is lost at decode time and cannot be recovered downstream,
 * which is exactly how 12 of every 13 samples were silently dropped on the (deviceId, ts) primary key
 * (#1070). [ringTimestamp] stays the RECORD's time (the wire anchor); the per-sample offset is applied
 * where the durable row is minted (OuraStreamMapping). [index] mirrors OuraSleepPhase.index. Both default
 * (0 / 1 = "the only sample in its record"), so single-sample decoders like 0x7B are unchanged.
 * Twin of Swift OuraSpO2 — the fields, defaults and resulting seconds are IDENTICAL.
 */
data class OuraSpO2(
    val ringTimestamp: Long,
    val value: Int,
    val unit: String = "raw",
    /** 0-based position of this sample within its record; samples are 1 s apart. */
    val index: Int = 0,
    /** Total samples decoded from the same record. [index] is always in `0 until count`. */
    val count: Int = 1,
)

/** One decoded skin-temperature sample in degrees C (value already / 100). */
data class OuraTemp(val ringTimestamp: Long, val celsius: Double)

/**
 * One decoded battery reading (OURA_PROTOCOL.md s6.10). `percent` is read at body[0]; `voltageMv`
 * is the [4..6] fallback estimate (fixture-validated per generation, may be null).
 */
data class OuraBattery(val percent: Int, val voltageMv: Int? = null, val charging: Boolean? = null)

/**
 * The 2-bit sleep-phase code values, per open_oura's VALIDATED `decode_sleep_phases` mapping
 * (events.rs `PHASE = ["deep", "light", "rem", "awake"]`): 0=deep, 1=light, 2=rem, 3=awake.
 *
 * CORRECTION (2026-07-12, PARITY twin of Swift `OuraSleepStage`): the old mapping
 * (0=awake/2=deep/3=REM) came from the same unverified doc as the rest of s6.12 and was contradicted
 * by live captures — phase records decoded AT WAKE (wearer demonstrably awake) carry code 3, which is
 * awake under open_oura's mapping and "REM" under the old one. The raw wire code persists unchanged
 * (`stage.raw` is what's stored); only these LABELS changed, byte-identical on both platforms.
 */
enum class OuraSleepStage(val raw: Int) {
    DEEP(0),
    LIGHT(1),
    REM(2),
    AWAKE(3);

    companion object {
        private val byRaw = entries.associateBy { it.raw }
        fun fromRaw(raw: Int): OuraSleepStage? = byRaw[raw]
    }
}

/**
 * One decoded sleep-phase code in order within a 0x4E/0x5A record (OURA_PROTOCOL.md s6.12). [unwritten]
 * (#1246) marks an epoch from an UNWRITTEN hypnogram page (a whole record of the erased-flash value 0xFF,
 * which the 2-bit decode would otherwise read as four AWAKE codes). It keeps a placeholder [stage] so it
 * still OCCUPIES its 30 s
 * slot in the burst time axis (dropping it would mis-time the real codes around it), but the assembler
 * EXCLUDES it from the reconstructed hypnogram — a gap, not AWAKE. Defaults false = a written epoch.
 * Byte-parity twin of the Swift OuraSleepPhase.
 */
data class OuraSleepPhase(
    val ringTimestamp: Long,
    val index: Int,
    val stage: OuraSleepStage,
    val unwritten: Boolean = false,
)

/** Motion state (OURA_PROTOCOL.md s6.13): 0 NO_MOTION, 1 RESTLESS, 2 TOSSING, 3 ACTIVE. */
enum class OuraMotionState(val raw: Int) {
    NO_MOTION(0),
    RESTLESS(1),
    TOSSING(2),
    ACTIVE(3);

    companion object {
        private val byRaw = entries.associateBy { it.raw }
        fun fromRaw(raw: Int): OuraMotionState? = byRaw[raw]
    }
}

/** One decoded motion-state code from a 0x6B motion_period record (OURA_PROTOCOL.md s6.13). */
data class OuraMotion(val ringTimestamp: Long, val index: Int, val state: OuraMotionState)

/**
 * One decoded 0x47 motion_events record: the ring's OWN averaged accelerometer vector for the period,
 * plus an orientation code and a high-intensity count (open_oura decode_motion, clean-room fact citation;
 * OURA_PROTOCOL.md s6.13). Same shape as a WHOOP 4.0 gravity sample — an averaged (x, y, z) vector, NOT
 * per-sample raw accel — so it can feed the same motion pipeline. Axis values are the signed record bytes
 * scaled ×8 (open_oura's convention); the LSB→g scale for the sleep stager is a downstream calibration, so
 * this holds the ring's raw ×8 integers, unscaled and honest. Twin of Swift OuraMotionEvent.
 */
data class OuraMotionEvent(
    val ringTimestamp: Long,
    val orientation: Int,     // byte0 >> 5 (0..7)
    val motionSeconds: Int,   // byte0 & 0x1f (0..31): seconds of motion in the window
    val avgX: Int,
    val avgY: Int,
    val avgZ: Int,
    val lowIntensity: Int?,   // byte4 & 0x3f, or null when the record is short
    val highIntensity: Int?,  // byte5 & 0x3f, or null when the record is short
)

/** Device lifecycle state (OURA_PROTOCOL.md s6.15) decoded from a 0x45/0x53 record. */
data class OuraState(val ringTimestamp: Long, val stateCode: Int, val text: String? = null)

/**
 * A decoded feature-status read reply (the `0x2F` sub-op `0x21` response): the ring's own report of a
 * feature's mode / status / state / subscription. Kotlin twin of the Swift `OuraFeatureStatus`. Read-only
 * diagnostic — used to confirm the server-flag gate on SpO2 (`0x04`) / real_steps (`0x0b`): a
 * `subscription == 0` with no emitted records is the ring saying "the cloud has not enabled this", which
 * NOOP cannot override offline. Never scored, never stored.
 */
data class OuraFeatureStatus(
    val feature: Int,
    val mode: Int,
    val status: Int,
    val state: Int,
    val subscription: Int,
)

/** A UTC anchor / time-sync event (OURA_PROTOCOL.md s6.11): epoch ms + timezone offset seconds. */
data class OuraTimeSync(val ringTimestamp: Long, val epochMs: Long, val tzOffsetSeconds: Int)

/** A secondary 1-second-granularity RTC beacon (OURA_PROTOCOL.md s6.15, tag 0x85). */
data class OuraRtcBeacon(val ringTimestamp: Long, val unixSeconds: Long)

// MARK: - Tier-B (UNVERIFIED) decoded events

/**
 * A Tier-B sleep summary value (OURA_PROTOCOL.md s6.12). UNVERIFIED layout; carries the raw payload
 * bytes plus the tag so a fixture test can validate before scoring trusts it. The driver only emits
 * this when allowTierB is set, and it is never folded into scoring silently.
 */
data class OuraTierBSummary(
    val tag: Int,
    val ringTimestamp: Long,
    val rawPayload: IntArray,
    val kind: String,          // "sleep_summary" / "activity" / "real_steps" / "spo2_smoothed"
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is OuraTierBSummary) return false
        return tag == other.tag && ringTimestamp == other.ringTimestamp &&
            rawPayload.contentEquals(other.rawPayload) && kind == other.kind
    }

    override fun hashCode(): Int {
        var h = tag
        h = 31 * h + ringTimestamp.hashCode()
        h = 31 * h + rawPayload.contentHashCode()
        h = 31 * h + kind.hashCode()
        return h
    }
}

/**
 * One decoded `0x50` activity_info record: a `state` code (activity-category; meaning unconfirmed)
 * plus a per-sample MET (metabolic-equivalent) series. THIRD-PARTY FORMULA (OURA_PROTOCOL.md s6.13,
 * [oura-rs] - clean-room fact citation, no code copied): plausible against six real Gen 3 captures
 * from PR #960's investigation (resting ~0.9 MET through a vigorous-activity burst at 7.4 MET, all
 * physiologically sane), but NOT independently ground-truth-validated against the Oura app's own
 * numbers. It therefore stays Tier B: emitted only behind `OuraDriver.allowTierB`, and NEVER folded
 * into `OuraStreamMapping`/`Streams`/scoring (steps stay honest - no step count is minted from MET).
 * Kotlin twin of the Swift `OuraActivityInfo` (met as List<Double> keeps structural equality).
 */
data class OuraActivityInfo(val ringTimestamp: Long, val state: Int, val met: List<Double>)

/**
 * One decoded `0x7E`/`0x7F` real_steps_features record: 14 unpacked feature values from a 14-byte
 * bit-packed body. THIRD-PARTY FORMULA ([oura-rs] - Th0rgal/open_oura `crates/oura-protocol/src/
 * events.rs`, clean-room fact citation, no code copied; the source itself marks this decode
 * `"_status": "unvalidated"`): two of the 14 fields (index 0 and 8) are genuine 9-bit values built as
 * `byte*2 + carry_bit`, where the carry bit is stolen from the MSB of a neighboring byte (index 3 for
 * field 0, index 11 for field 8); the rest are either plain bytes or a bare `byte<<1` with no carry.
 * NOOP's OWN investigation (2026-07-30, a 2661-pair real Gen 3 capture cross-correlated against the
 * already-anchored 0x50 MET corpus) found `fields[0]` and `fields[8]` - the two carry-completed 9-bit
 * values - are also the ONLY fields with a consistent movement correlation (r~+0.3 vs mean MET, effect
 * size +1.5/+1.25 resting-vs-moving), a real convergence between the bit-layout hint and the empirical
 * signal.
 *
 * NO FIELD IS A STEP COUNT - settled by ground truth, not left open (OURA_PROTOCOL.md s6.13): a
 * measured 13,349-step day tested against 805 paired records found every one of the 14 fields large and
 * non-zero during sleep (`fields[3]` sums HIGHER asleep than walking), and no byte offset on either tag
 * yields a monotonic counter across 5,122 records. What these ARE is what the tag name says -
 * `real_steps_FEATURES`, the *inputs* to Oura's step model, computed every 30 s whether walking or
 * asleep. `f0`/`f8` rank top by movement discrimination (Cohen's d +2.35/+2.37), which is why they
 * correlated: genuine movement-intensity features, useless as a count. A count would require
 * reimplementing Oura's model over them - unvalidatable, and the s194 precedent forbids fitting one.
 *
 * Stays Tier B end to end: emitted only behind `OuraDriver.allowTierB`, and NEVER folded into
 * `OuraStreamMapping`/scoring - not even from `fields[0]`/`fields[8]`. `fields` holds all values
 * verbatim, in the source's own order, as an activity-signal corpus. Kotlin twin of the Swift
 * `OuraRealStepsFields`.
 */
data class OuraRealStepsFields(val tag: Int, val ringTimestamp: Long, val fields: List<Int>)

/**
 * One decoded `0x6A` sleep_period_info record: the ring's OWN per-window sleep summary - an average
 * heart rate and, notably, a **breath rate**. THIRD-PARTY FIELD NAMES ([open_ring]
 * `decode_sleep_period_info_2` / native `parse_api_sleep_period_info`, clean-room fact citation, no code
 * copied; the multipliers are its `.rodata` constants). Our own s6.12 already carried the right OFFSETS
 * and the right `/8.0` from [ringverse] but no names, and mistyped `average_hr` as an `int8` with no
 * `* 0.5`.
 *
 * STRUCTURALLY VERIFIED on four consecutive real Gen 3 overnights (2026-08-05->09, 3,493 records): every
 * body is exactly 10 bytes; every record satisfies the source's own declared invariants
 * (`motionCount < 121`, `sleepState in {0,1,2}` - only 0 and 1 ever observed); every `breath` is an exact
 * multiple of 0.125, which confirms the `/8.0` fixed point FROM THE DATA rather than assuming it; and
 * `averageHrBpm` medians 53.0-54.0 bpm across the four nights, agreeing with the 54 bpm median the
 * independently-decoded banked-IBI channel gives for the same wearer (#511, itself WHOOP-validated
 * against RHR 55). The `* 0.5` scale is settled by its falsifier: read as `* 1.0` the same records sit
 * +56 ... +62 bpm above every other HR channel we hold.
 *
 * WHOSE measurement this is decides which bar applies. `breath` is computed BY THE RING and read off
 * the wire - it is not a signal NOOP derives from raw sensor data. The #194 rule is written for the
 * opposite case (PPG->HR autocorrelation, RSA-from-R-R: methods where NOOP invents the number and can
 * manufacture a peak that looks physiological), so what has to be right here is the DECODE, which is
 * what the structural verification above establishes. On decode provenance it has the same standing as
 * the ring's own SleepNet hypnogram, which NOOP already persists (#773 / #877).
 *
 * Independent support that byte 4 is the quantity Oura's own app calls respiratory rate: these records
 * median 14.75/min against the SAME wearer's 851-night Oura app export at 15.250 (IQR 14.875-15.625) -
 * same quantity, same band, though the two corpora do not overlap in date so this is a distribution
 * check, not a paired one. Against a WHOOP worn on the same nights the decode also reproduces the
 * VENDOR's own offset (Oura reads below WHOOP 18/18 nights, delta -1.158; ours delta -1.458,
 * sign-stable 6/6), and mapping each night to the wrong date collapses the agreement (r +0.591 ->
 * -0.151), so it is date-aligned rather than coincidental.
 *
 * It stays Tier B because the field NAMES come from third-party reverse engineering, not from Oura
 * documentation - a decode-provenance caveat, not a doubt about whether the ring measures respiration.
 *
 * `OuraStreamMapping` maps `breathsPerMin` - and nothing else from this record - to a `respSample` row
 * in milli-bpm under the ring's own deviceId, as INSTRUMENTATION: the row is stored and plotted on the
 * respiration track beside the incumbent, and NOTHING scores from it. In particular nothing writes
 * `dailyMetric.respRateBpm` from it - that is the scored slot (recovery's respiration term, the illness
 * signal), and the same measurements that make this decode believable also place it AT the vendor
 * ceiling rather than past it (r = +0.680 is what Oura's OWN app manages against WHOOP), which is
 * precisely the case CLAUDE.md's #194 rule says to instrument rather than make the default. It also
 * never reaches the sleep STAGER (`OuraRespScale.forScoring`): that stream is read there as a ~1 Hz raw
 * ADC waveform and a per-window rate is the wrong shape for a peak detector, however good the rate.
 * `averageHrBpm` stays diagnostic-only: it must not join the beat-derived HR series at a different
 * cadence and a different provenance.
 *
 * `mzci` / `dzci` keep the source's opaque names deliberately - we do not know what they measure, and
 * inventing a friendlier name would assert an interpretation the evidence does not support. Kotlin twin
 * of the Swift `OuraSleepPeriodInfo`.
 */
data class OuraSleepPeriodInfo(
    val ringTimestamp: Long,
    /** Wire `u8 * 0.5`, so the channel has half-bpm resolution (~50 % of real records carry an odd byte). */
    val averageHrBpm: Double,
    /** Wire `s8 * 0.0625` - signed; the only signed field in the body. */
    val hrTrend: Double,
    /** Wire `u8 * 0.0625`. Meaning unknown (source's name kept verbatim). */
    val mzci: Double,
    /** Wire `u8 * 0.0625`. Meaning unknown (source's name kept verbatim). */
    val dzci: Double,
    /** Wire `u8 / 8.0` - CANDIDATE breaths per minute. See the type doc: named, not validated. */
    val breathsPerMin: Double,
    /** Wire `u8 / 8.0` - CANDIDATE breath variability, same units as [breathsPerMin]. */
    val breathVariability: Double,
    /** Wire `u8`, declared `< 121` by the source (upheld by every record we hold). */
    val motionCount: Int,
    /** Wire `u8`, declared `in {0,1,2}` (only 0 and 1 observed). Code meanings undocumented - no enum. */
    val sleepState: Int,
    /** Wire `u16 LE / 65536`, so `[0, 1)`. Meaning unknown (source's name kept verbatim). */
    val cv: Double,
)

// MARK: - The emitted event union

/**
 * What OuraDriver.ingest(record:) emits. A single record can yield several events (e.g. an IBI+amp
 * record carries up to 6 IBIs). Tier-B events are wrapped in TierB (or ActivityInfo) and only emitted
 * when the driver is configured to allow them; they must never feed scoring without passing a
 * real-capture fixture.
 *
 * Kotlin twin of the Swift `OuraEvent` enum-with-associated-values, modelled as a sealed class.
 */
sealed class OuraEvent {
    data class Hr(val value: OuraHR) : OuraEvent()
    data class Ibi(val value: OuraIBI) : OuraEvent()
    data class Hrv(val value: OuraHRV) : OuraEvent()
    data class Spo2(val value: OuraSpO2) : OuraEvent()
    data class Temp(val value: OuraTemp) : OuraEvent()
    data class Battery(val value: OuraBattery) : OuraEvent()
    data class SleepPhaseEvent(val value: OuraSleepPhase) : OuraEvent()
    data class MotionEvent(val value: OuraMotion) : OuraEvent()

    /**
     * A decoded 0x47 motion_events record: the ring's averaged accel vector (Tier-A). Distinct from
     * [MotionEvent] (the 0x6B period's 2-bit state codes). Twin of Swift OuraEvent.motionEvent.
     */
    data class MotionVectorEvent(val value: OuraMotionEvent) : OuraEvent()
    data class StateEvent(val value: OuraState) : OuraEvent()
    data class TimeSyncEvent(val value: OuraTimeSync) : OuraEvent()
    data class RtcBeaconEvent(val value: OuraRtcBeacon) : OuraEvent()
    data class DebugTextEvent(val ringTimestamp: Long, val text: String) : OuraEvent()

    /**
     * A Tier-B (UNVERIFIED) decoded value. Gated behind OuraDriver.allowTierB. Per the brief's TIER
     * DISCIPLINE: do not let Tier B feed values silently.
     */
    data class TierB(val value: OuraTierBSummary) : OuraEvent()

    /**
     * A decoded `0x50` activity_info record (state + MET series). Still Tier-B (see [OuraActivityInfo]
     * doc) - split out of the raw-bytes [TierB] wrapper because this ONE tag has a plausible decode
     * formula, so an investigating consumer can log real MET numbers instead of hex. Same gate
     * (`allowTierB`), same discipline (never reaches `OuraStreamMapping`).
     */
    data class ActivityInfo(val value: OuraActivityInfo) : OuraEvent()

    /**
     * A decoded `0x7E`/`0x7F` real_steps_features record (14 unpacked fields). Still Tier-B (see
     * [OuraRealStepsFields] doc) - split out of the raw-bytes [TierB] wrapper for the same reason
     * [ActivityInfo] was: a cited third-party unpack formula worth surfacing as real numbers instead of
     * hex. Same gate (`allowTierB`), same discipline (never reaches `OuraStreamMapping`).
     */
    data class RealStepsFields(val value: OuraRealStepsFields) : OuraEvent()

    /**
     * A decoded `0x6A` sleep_period_info record (avg HR + the ring's own breath rate). Still Tier-B
     * (see [OuraSleepPeriodInfo] doc) - split out of the raw-bytes [TierB] wrapper for the same reason
     * [ActivityInfo] was: a cited third-party layout worth surfacing as real numbers instead of hex.
     * Same gate (`allowTierB`); its `breathsPerMin` - alone among the record's fields - is mapped to a
     * durable `respSample` row and shown on the respiration track. It is NOT scored: `dailyMetric.respRateBpm`
     * is untouched, and `OuraRespScale.forScoring` refuses the ring's rows at every scoring read (see the
     * type doc). Every other field of the record stays diagnostic-only.
     */
    data class SleepPeriodInfo(val value: OuraSleepPeriodInfo) : OuraEvent()

    /** True for Tier-B events, so a consumer can assert none leaked into a Tier-A-only sink. */
    val isTierB: Boolean
        get() = this is TierB || this is ActivityInfo || this is RealStepsFields ||
            this is SleepPeriodInfo

    /**
     * The record's envelope ring-time, when it carries one (battery is a plain response, not a log
     * record). Feeds the history drain's in-session continuation cursor: open_oura's `drain_events`
     * advances `start` past the max timestamp of EVERY event in a batch, whatever its tag.
     * Byte-identical twin of Swift's envelopeRingTimestamp.
     */
    val envelopeRingTimestamp: Long?
        get() = when (this) {
            is Hr -> value.ringTimestamp
            is Ibi -> value.ringTimestamp
            is Hrv -> value.ringTimestamp
            is Spo2 -> value.ringTimestamp
            is Temp -> value.ringTimestamp
            is Battery -> null
            is SleepPhaseEvent -> value.ringTimestamp
            is MotionEvent -> value.ringTimestamp
            is MotionVectorEvent -> value.ringTimestamp
            is StateEvent -> value.ringTimestamp
            is TimeSyncEvent -> value.ringTimestamp
            is RtcBeaconEvent -> value.ringTimestamp
            is DebugTextEvent -> ringTimestamp
            is TierB -> value.ringTimestamp
            is ActivityInfo -> value.ringTimestamp
            is RealStepsFields -> value.ringTimestamp
            is SleepPeriodInfo -> value.ringTimestamp
        }
}
