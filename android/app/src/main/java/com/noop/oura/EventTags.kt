package com.noop.oura

// EventTags: the inner-event-record tag dictionary (the `type` byte of a TLV record, OURA_PROTOCOL.md
// s2.3 / s6). Kotlin twin of EventTags.swift. Every tag carries an explicit trust tier so Tier-B
// (UNVERIFIED) layouts can never feed values into scoring silently. Facts cited per OURA_PROTOCOL.md
// s6 / s7.3.

/**
 * Decoder trust tier. Tier A is verified against the byte-for-byte corpus and ships live. Tier B is
 * attested by a single no-license / AI-generated doc and MUST pass a real-capture fixture before
 * scoring trusts it (the OuraDriver gates Tier-B emission behind an explicit flag). Per the brief's
 * TIER DISCIPLINE rule and OURA_PROTOCOL.md s7.3.
 */
enum class TrustTier {
    TIER_A,   // verified, ship now
    TIER_B,   // UNVERIFIED, fixture-gate before use
}

/**
 * The Oura inner-event-record tag. `raw` == the `type` byte (>= 0x41 per OURA_PROTOCOL.md s2.3).
 * Only the tags NOOP actually decodes are enumerated; an unknown byte decodes to null (honest).
 */
enum class OuraEventTag(val raw: Int) {
    // --- Lifecycle / state (Tier A) ---
    RING_START(0x41),         // ring_start_ind, OURA_PROTOCOL.md s6.15
    TIME_SYNC(0x42),          // time-sync ind (primary UTC anchor), OURA_PROTOCOL.md s6.11
    DEBUG_TEXT(0x43),         // debug_event ASCII, OURA_PROTOCOL.md s6.15
    STATE_CHANGE(0x45),       // state_change_ind, OURA_PROTOCOL.md s6.15
    WEAR_EVENT(0x53),         // wear_event (same STATE enum), OURA_PROTOCOL.md s6.15
    RTC_BEACON(0x85),         // rtc_beacon_ind, OURA_PROTOCOL.md s6.15

    // --- HR / IBI (Tier A) ---
    IBI_AMPLITUDE(0x60),      // ibi_and_amplitude_event (bit-packed), OURA_PROTOCOL.md s6.1
    // green_ibi_and_amp_event, OURA_PROTOCOL.md s6.2 — Tier B (#287): §6.2 layout (5 deltas+6 amps)
    // != 0x60; unverified, gated out of live emission. See `tier` below.
    GREEN_IBI_AMP(0x71),
    SPO2_IBI_AMPLITUDE(0x6E), // spo2_ibi_and_amplitude_event (REVERSE byte order), OURA_PROTOCOL.md s6.3
    GREEN_IBI_QUALITY(0x80),  // green_ibi_quality_event (bit-packed across bytes), OURA_PROTOCOL.md s6.4
    IBI(0x44),                // ibi event (Tier-A IBI tag per the brief), OURA_PROTOCOL.md s6 / s0

    // --- HRV / RMSSD (Tier A) ---
    HRV_RMSSD(0x5D),          // hrv_event (ring's own RMSSD-derived HRV), OURA_PROTOCOL.md s6.9

    // --- SpO2 (Tier A) ---
    SPO2_PER_SAMPLE(0x6F),    // spo2_event per-second, OURA_PROTOCOL.md s6.5
    SPO2_STABLE(0x7B),        // spo2_stable_event (uint16 BIG-endian), OURA_PROTOCOL.md s6.6
    SPO2_DC(0x77),            // spo2_dc_event (sign-magnitude deltas), OURA_PROTOCOL.md s6.7

    // --- Temperature (Tier A) ---
    TEMP(0x46),               // temp_event (int16 LE / 100), OURA_PROTOCOL.md s6.8
    TEMP_PERIOD(0x69),        // temp_period (single int16 LE / 100), OURA_PROTOCOL.md s6.8
    SLEEP_TEMP(0x75),         // sleep_temp_event (uint16 LE / 100), OURA_PROTOCOL.md s6.8

    // --- Motion (Tier A) ---
    MOTION(0x47),             // motion_events, OURA_PROTOCOL.md s6.13
    MOTION_PERIOD(0x6B),      // motion_period (2-bit MOTION_STATE codes), OURA_PROTOCOL.md s6.13

    // Battery (0x0D) is an OUTER command response, not a TLV inner record; see Decoders.decodeBattery.

    // --- Sleep summaries (Tier B, UNVERIFIED) ---
    SLEEP_SUMMARY_1(0x49),    // sleep_summary_1, OURA_PROTOCOL.md s6.12 (UNVERIFIED)
    SLEEP_SUMMARY_C(0x4C),    // sleep summary variant, OURA_PROTOCOL.md s6.12 (UNVERIFIED)
    SLEEP_SUMMARY_D(0x4F),    // sleep summary variant, OURA_PROTOCOL.md s6.12 (UNVERIFIED)
    SLEEP_SUMMARY_E(0x57),    // sleep summary variant, OURA_PROTOCOL.md s6.12 (UNVERIFIED)
    SLEEP_SUMMARY_F(0x58),    // sleep summary variant, OURA_PROTOCOL.md s6.12 (UNVERIFIED)

    // --- Sleep period info (Tier B, UNVERIFIED) ---
    SLEEP_PERIOD_INFO(0x6A),  // sleep_period_info (avg HR + breath rate), OURA_PROTOCOL.md s6.12 (UNVERIFIED)

    // --- Sleep phase codes (Tier A: 2-bit phase codes are byte-for-byte verified) ---
    // 0x4B/0x4E/0x5A are the three aliases the ring emits for the SAME hypnogram layout — a header
    // byte then 2-bit stage codes, 4/byte MSB-first (open_oura decode_sleep_phases routes all three,
    // events.rs). 0x4B was previously misfiled as a Tier-B "sleep summary"; it is the same validated
    // phase record. Parity with Swift's sleepPhaseB reclassification (dddbe952).
    SLEEP_PHASE_B(0x4B),      // sleep_phase_details alias (was SLEEP_SUMMARY_B), OURA_PROTOCOL.md s6.12
    SLEEP_PHASE(0x4E),        // sleep_phase_details (2-bit codes), OURA_PROTOCOL.md s6.12
    SLEEP_PHASE_ALT(0x5A),    // sleep_phase_details alias, OURA_PROTOCOL.md s6.12

    // --- Activity / MET (Tier B, UNVERIFIED) ---
    ACTIVITY_INFO(0x50),      // activity_info (MET-class), OURA_PROTOCOL.md s6.13 (UNVERIFIED)
    ACTIVITY_SUMMARY_1(0x51), // activity_summary, OURA_PROTOCOL.md s6.13 (UNVERIFIED)
    ACTIVITY_SUMMARY_2(0x52), // activity_summary, OURA_PROTOCOL.md s6.13 (UNVERIFIED)

    // --- Real steps (Tier B, UNVERIFIED) ---
    REAL_STEPS_1(0x7E),       // real_steps_features_1, OURA_PROTOCOL.md s6.13 (UNVERIFIED)
    REAL_STEPS_2(0x7F),       // real_steps_features_2, OURA_PROTOCOL.md s6.13 (UNVERIFIED)

    // --- Smoothed SpO2 (Tier B, UNVERIFIED) ---
    SPO2_SMOOTHED(0x70);      // spo2_smoothed, OURA_PROTOCOL.md s6.6 (UNVERIFIED)

    /**
     * The trust tier for this tag. Tier B tags are decoded but the OuraDriver gates their emission
     * behind an explicit allowTierB flag. Per OURA_PROTOCOL.md s7.3 and the brief's TIER DISCIPLINE.
     */
    val tier: TrustTier
        get() = when (this) {
            SLEEP_SUMMARY_1, SLEEP_SUMMARY_C, SLEEP_SUMMARY_D, SLEEP_SUMMARY_E,
            SLEEP_SUMMARY_F, ACTIVITY_INFO, ACTIVITY_SUMMARY_1, ACTIVITY_SUMMARY_2,
            REAL_STEPS_1, REAL_STEPS_2, SPO2_SMOOTHED,
            // 0x6A sleep_period_info: the field NAMES come from a single decompiled-binary source
            // ([open_ring]); NOOP's own captures confirm the layout's declared invariants and the
            // fixed-point scales. Tier B on DECODE PROVENANCE - third-party names, not Oura
            // documentation - not on doubt that the ring measures respiration: `breath` is the ring's
            // own value read off the wire. It is INSTRUMENTATION - stored as a `respSample` row and shown
            // on the respiration track, but NOT scored: `dailyMetric.respRateBpm` is untouched (see
            // OuraSleepPeriodInfo).
            SLEEP_PERIOD_INFO,
            // #287: 0x71 green_ibi_and_amp is NOT corpus-verified — no captured 0x71 fixture, and
            // OURA_PROTOCOL.md §6.2 documents a DIFFERENT layout (5 IBI deltas + 6 amplitudes, shift
            // [2:0]) than the 0x60 decoder it was wired to (6 absolute IBIs, 4-bit shift). Decoding it
            // with the 0x60 layout fabricates a 6th phantom R-R and reads deltas as absolute intervals,
            // silently corrupting reconstructed HRV. Demote to Tier B (gated out of live emission) until
            // a real 0x71 capture lets us write + verify a dedicated decoder. (TIER_A == corpus-verified.)
            GREEN_IBI_AMP -> TrustTier.TIER_B
            else -> TrustTier.TIER_A
        }

    /** A short, stable, human-facing name for the tag (used by the CLI dump and event kinds). */
    val tagName: String
        get() = when (this) {
            RING_START -> "RING_START"
            TIME_SYNC -> "TIME_SYNC"
            DEBUG_TEXT -> "DEBUG_TEXT"
            STATE_CHANGE -> "STATE_CHANGE"
            WEAR_EVENT -> "WEAR_EVENT"
            RTC_BEACON -> "RTC_BEACON"
            IBI_AMPLITUDE -> "IBI_AMPLITUDE"
            GREEN_IBI_AMP -> "GREEN_IBI_AMP"
            SPO2_IBI_AMPLITUDE -> "SPO2_IBI_AMPLITUDE"
            GREEN_IBI_QUALITY -> "GREEN_IBI_QUALITY"
            IBI -> "IBI"
            HRV_RMSSD -> "HRV_RMSSD"
            SPO2_PER_SAMPLE -> "SPO2_PER_SAMPLE"
            SPO2_STABLE -> "SPO2_STABLE"
            SPO2_DC -> "SPO2_DC"
            TEMP -> "TEMP"
            TEMP_PERIOD -> "TEMP_PERIOD"
            SLEEP_TEMP -> "SLEEP_TEMP"
            MOTION -> "MOTION"
            MOTION_PERIOD -> "MOTION_PERIOD"
            SLEEP_PERIOD_INFO -> "SLEEP_PERIOD_INFO"
            SLEEP_SUMMARY_1 -> "SLEEP_SUMMARY_1"
            SLEEP_PHASE_B -> "SLEEP_PHASE_4B"
            SLEEP_SUMMARY_C -> "SLEEP_SUMMARY_4C"
            SLEEP_SUMMARY_D -> "SLEEP_SUMMARY_4F"
            SLEEP_SUMMARY_E -> "SLEEP_SUMMARY_57"
            SLEEP_SUMMARY_F -> "SLEEP_SUMMARY_58"
            SLEEP_PHASE -> "SLEEP_PHASE"
            SLEEP_PHASE_ALT -> "SLEEP_PHASE_ALT"
            ACTIVITY_INFO -> "ACTIVITY_INFO"
            ACTIVITY_SUMMARY_1 -> "ACTIVITY_SUMMARY_1"
            ACTIVITY_SUMMARY_2 -> "ACTIVITY_SUMMARY_2"
            REAL_STEPS_1 -> "REAL_STEPS_1"
            REAL_STEPS_2 -> "REAL_STEPS_2"
            SPO2_SMOOTHED -> "SPO2_SMOOTHED"
        }

    companion object {
        private val byRaw: Map<Int, OuraEventTag> = entries.associateBy { it.raw }

        /** Map a `type` byte to its tag, or null when the byte is not in the dictionary (honest). */
        fun fromRaw(raw: Int): OuraEventTag? = byRaw[raw]
    }
}
