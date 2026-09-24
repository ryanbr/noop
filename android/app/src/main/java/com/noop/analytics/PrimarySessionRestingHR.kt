package com.noop.analytics

/**
 * #1169: an alternative headline resting-HR definition — the arithmetic MEAN of valid HR samples in the
 * LONGEST (primary) sleep session, rather than the lowest-per-session floor `AnalyticsEngine` ships today.
 *
 * ## Why (issue #1169, artemc)
 * The shipped daily RHR is `restingHRDaily = matched…restingHR.min()` — a nightly HR FLOOR, and the `.min()`
 * lets a short low-HR nap replace the main overnight session. A clean-room, single-participant 5-night
 * experiment (official WHOOP RHR + a Polar H10 ECG mean as independent references, a pre-declared dev/holdout
 * split, no fitted offset) found the primary-session sample mean tracked both far better: rounded MAE vs the
 * official target 6.0->2.0 (dev) / 7.5->0.8 (holdout).
 *
 * ## WIRED as of #2358 — this sets the shipped daily resting HR
 * It was landed pure and unwired, on the reasoning that switching the consumers is a re-baselining of
 * core scores and that the issue asks for a larger multi-participant holdout first. #2358 made the
 * switch anyway, as a maintainer call: `AnalyticsEngine.restingHRDaily` now prefers a device-provided
 * primary-session value, then THIS mean, and falls back to the old `restingHR.min()` floor only when
 * coverage is sparse. So the headline resting HR and everything reading it — recovery, strain, workout
 * detection, energy — come from here on any day with a covered primary session.
 *
 * What that means for the evidence below: the MAE figures are from ONE participant over five nights
 * against a pre-declared split, which is the holdout the issue says is not yet large enough. #2284
 * separately replaces what a session's `restingHR` IS, which moves the fallback under this.
 *
 * ## Definition
 * - **Primary session**: the LONGEST by duration; ties resolve to the FIRST. A nap never replaces the night.
 * - **Valid sample**: bpm within [validBpm] (default 30..220, matching AnalyticsEngine's worn-HR range).
 *   Out-of-range or missing samples are excluded.
 * - **Mean**: arithmetic SAMPLE mean (unweighted). A time-weighted variant behaves differently under
 *   irregular cadence and must be evaluated separately.
 * - **Coverage**: returns null unless the primary session has at least [minValidSamples] valid samples.
 * - An APPROXIMATION, not a clinically validated measurement.
 *
 * Twin of macOS `PrimarySessionRestingHR`. Keep byte-identical.
 */
object PrimarySessionRestingHR {

    /** One sleep session for a wake day: its duration and raw (possibly-invalid) HR samples in bpm. Wake-day
     *  assignment and session building stay in the caller; this is the minimal input the pure metric needs. */
    data class Session(val durationSec: Double, val bpm: List<Int>)

    /** The worn-HR range AnalyticsEngine uses when deciding a sample is real; reused so validity is one rule. */
    val DEFAULT_VALID_BPM = 30..220

    /** Provisional minimum valid-sample coverage before a value is returned. A sample count is cadence-blind;
     *  the exact rule is a tuning parameter for the multi-participant validation the issue calls for. */
    const val DEFAULT_MIN_VALID_SAMPLES = 30

    /** Mean valid HR of the LONGEST session, or null when no session clears [minValidSamples] valid samples. */
    fun meanHR(
        sessions: List<Session>,
        validBpm: IntRange = DEFAULT_VALID_BPM,
        minValidSamples: Int = DEFAULT_MIN_VALID_SAMPLES,
    ): Double? {
        // Primary = longest by duration. `maxByOrNull` keeps the FIRST of equal-duration sessions (only a
        // strictly-longer one replaces it); Swift `max(by:)` resolves ties the same way, so parity holds.
        val primary = sessions.maxByOrNull { it.durationSec } ?: return null
        val valid = primary.bpm.filter { it in validBpm }
        if (valid.size < minValidSamples) return null
        return valid.sum().toDouble() / valid.size
    }

    /** #1169 coverage INPUTS for the same primary session [meanHR] averages: its valid-sample count and its
     *  duration. The fixed [minValidSamples] gate is cadence-blind, so the accruing shadow dataset needs to
     *  weight/filter each night by how well-covered it was — but this records the RAW inputs, not a derived
     *  coverage fraction, so the later multi-participant holdout can pick its own coverage definition. Same
     *  longest-session selection + gate as [meanHR] (null in lockstep with it). Pure + unwired. Twin of the
     *  Swift `PrimarySessionRestingHR.Coverage` / `coverage`. */
    data class Coverage(val validSamples: Int, val durationSec: Double)

    fun coverage(
        sessions: List<Session>,
        validBpm: IntRange = DEFAULT_VALID_BPM,
        minValidSamples: Int = DEFAULT_MIN_VALID_SAMPLES,
    ): Coverage? {
        val primary = sessions.maxByOrNull { it.durationSec } ?: return null
        val valid = primary.bpm.filter { it in validBpm }
        if (valid.size < minValidSamples) return null
        return Coverage(validSamples = valid.size, durationSec = primary.durationSec)
    }
}
