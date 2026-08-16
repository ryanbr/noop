package com.noop.analytics

import com.noop.protocol.RrInterval
import kotlin.math.sqrt

/*
 * RhythmScreener.kt — beat-to-beat regularity DESCRIPTIVE statistics + Poincaré point
 * cloud for an experimental, non-clinical wellness VISUALIZATION.
 *
 * Faithful Kotlin port of StrandAnalytics/RhythmScreener.swift (verified on macOS).
 * Spec: docs/superpowers/specs/2026-06-19-v5-rhythm-screening-design.md (§3, §11).
 * Same constants, same RhythmRegularity / RhythmConfidence enums, same classification,
 * identical results on the shared synthetic fixtures (cross-platform parity gate).
 *
 * SCOPE (deliberately narrow — read §11 of the spec):
 *   This builds ONLY the pure regularity math and a NEUTRAL categorical label scoped to
 *   a visualization ("looked steady" / "some variation" / "varied a lot" / "couldn't
 *   read"). It deliberately does NOT emit any "consider a clinician" verdict, condition
 *   name, probability-of-condition number, or alarm. That screening verdict is HELD per
 *   §11 and gated behind a separate go/no-go + the consent machinery — not in this code.
 *
 * Reuses [HrvAnalyzer] (rangeFilter / rejectEctopic / rmssdRaw / sdnnRaw) exactly — no
 * re-implementation of those primitives.
 *
 * NON-CLINICAL: every label is descriptive and benign. No disease names, no diagnostic
 * claims, and no call-to-action anywhere in this file.
 */
object RhythmScreener {

    // ── Thresholds (named, tunable in one place; tuned only on synthetic fixtures) ────

    /** Minimum clean range-filtered intervals required to read a window at all. */
    const val WINDOW_MIN_BEATS: Int = 60

    /** Resting heart-rate band (bpm) lower bound — outside → unreadable. */
    const val RESTING_HR_MIN_BPM: Double = 40.0

    /** Resting heart-rate band (bpm) upper bound — outside → unreadable. */
    const val RESTING_HR_MAX_BPM: Double = 110.0

    /** SD1:SD2 ratio at/above which the cloud is rounding out (less comet-like). */
    const val TAU_RATIO: Double = 0.55

    /** Normalised-RMSSD at/above which beat-to-beat variation is high. */
    const val TAU_NRMSSD: Double = 0.12

    /** Normalised turning-point rate at/above which direction flips are frequent. */
    const val TAU_TP: Double = 0.90

    /**
     * Ectopic-beat fraction at/above which isolated extra/skipped beats are notable
     * enough to read as "occasional", provided the rhythm is otherwise smooth (low
     * turning-point rate). Kept conservative.
     */
    const val TAU_ECTOPIC_LOW: Double = 0.04

    /** Minimum varied windows before a night is *described* as recurring variation. */
    const val NIGHT_MIN_VARIED_WINDOWS: Int = 3

    /** Minimum span (seconds) over which varied windows must spread to read "recurring". */
    const val NIGHT_MIN_SPAN_SECONDS: Int = 30 * 60

    /** Clean-beat count at/above which a single window's read is "solid". */
    const val SOLID_BEATS: Int = 200

    // ── Types ─────────────────────────────────────────────────────────────────────────

    /**
     * One resting window, already assembled by the caller (app layer). Pure inputs.
     * [rrMs] is the raw successive R-R series (ms); [ts] the matching wall-clock seconds
     * (used only for night-span aggregation, may be empty). [ppgIBIms] is an optional
     * independent PPG-derived inter-beat series; [motionStill] is the caller's motion
     * gate; [meanHR] the window mean rate for the resting-band gate.
     */
    data class WindowInput(
        val rrMs: List<Double>,
        val ts: List<Int> = emptyList(),
        val ppgIBIms: List<Double>? = null,
        val motionStill: Boolean,
        val meanHR: Double,
    ) {
        companion object {
            /**
             * Convenience: assemble from decoded [RrInterval] rows. Computes meanHR from
             * the range-filtered series. [motionStill] still comes from the caller.
             */
            fun fromRr(rr: List<RrInterval>, ppgIBIms: List<Double>? = null,
                       motionStill: Boolean): WindowInput {
                val raw = rr.map { it.rrMs.toDouble() }
                val clean = HrvAnalyzer.rangeFilter(raw)
                val meanNN = if (clean.isEmpty()) 0.0 else clean.sum() / clean.size.toDouble()
                val hr = if (meanNN > 0) 60_000.0 / meanNN else 0.0
                return WindowInput(rrMs = raw, ts = rr.map { it.ts }, ppgIBIms = ppgIBIms,
                    motionStill = motionStill, meanHR = hr)
            }
        }
    }

    /** A single (NN[i], NN[i+1]) pair on the Poincaré plot (ms, ms). */
    data class PoincarePoint(val x: Double, val y: Double)

    /**
     * Descriptive statistics + neutral label for one window. Mirrors Swift `WindowResult`.
     * Optional stats are null when the window was unreadable. Nothing is a clinical metric.
     */
    data class WindowResult(
        val label: RhythmRegularity,
        val sd1: Double?,
        val sd2: Double?,
        val sd1sd2: Double?,
        val normRmssd: Double?,
        val turningPointRate: Double?,
        val ectopicFraction: Double?,
        val nBeats: Int,
        val confidence: RhythmConfidence,
        val agreedAcrossSources: Boolean,
        val poincare: List<PoincarePoint>,
    ) {
        companion object {
            /** An unreadable window — all stats null, no cloud. */
            fun unreadable(nBeats: Int,
                           confidence: RhythmConfidence = RhythmConfidence.CALIBRATING): WindowResult =
                WindowResult(label = RhythmRegularity.UNREADABLE, sd1 = null, sd2 = null,
                    sd1sd2 = null, normRmssd = null, turningPointRate = null,
                    ectopicFraction = null, nBeats = nBeats, confidence = confidence,
                    agreedAcrossSources = false, poincare = emptyList())
        }
    }

    /**
     * Descriptive roll-up of a night's readable windows for the visualization's night
     * view. Counting only — NO verdict, NO notification trigger, NO call-to-action.
     */
    data class NightRhythmSummary(
        val readableWindows: Int,
        val steadyWindows: Int,
        val occasionalWindows: Int,
        val variedWindows: Int,
        val variationRecurred: Boolean,
        val overall: RhythmRegularity,
    )

    // ── Public API ────────────────────────────────────────────────────────────────────

    /**
     * Screen one resting window: apply the gates, then compute descriptive stats and a
     * neutral regularity label. Pure — plain inputs, plain result.
     */
    fun screenWindow(input: WindowInput): WindowResult {
        // Gate 1: motion. Only a firmly-still window is read; movement masquerades as
        // irregularity and is the single biggest false signal.
        if (!input.motionStill) {
            return WindowResult.unreadable(nBeats = 0)
        }

        // Range-filter (keep ectopy — only drop physiologically impossible jumps).
        val clean = HrvAnalyzer.rangeFilter(input.rrMs)

        // Gate 2: signal quality — need a dense enough clean window.
        if (clean.size < WINDOW_MIN_BEATS) {
            return WindowResult.unreadable(nBeats = clean.size)
        }

        // Gate 3: plausible resting rate.
        if (input.meanHR < RESTING_HR_MIN_BPM || input.meanHR > RESTING_HR_MAX_BPM) {
            return WindowResult.unreadable(nBeats = clean.size, confidence = confidence(clean.size))
        }

        // Gate 4: beat-time integrity. Every statistic below is a SPREAD over the interval cloud — SD2
        // is built from SDNN outright — so a window whose beats are partly held twice describes a rhythm
        // the heart never had, and describes it as MORE varied than it was. That is the wrong direction
        // to be wrong in for a label a person reads. `unreadable` is the honest answer: the capture
        // cannot support the read, which is exactly what this state exists for.
        //
        // Timestamps are optional on [WindowInput], and without them coverage is not measurable — the
        // verdict is then UNMEASURABLE, which stays readable (a live spot capture has no timestamps and
        // is perfectly time-accurate). Only a MEASURED over-count gates. Twin of the Swift gate.
        if (input.ts.size == input.rrMs.size && input.ts.isNotEmpty()) {
            val tsLong = input.ts.map { it.toLong() }
            val coverage = HrvAnalyzer.rrCoverage(tsLong, input.rrMs)
            val collapsed = HrvAnalyzer.collapsedCoverage(tsLong, input.rrMs)
            val verdict = HrvAnalyzer.classifyCoverage(coverage, collapsed)
            if (!HrvAnalyzer.beatSpreadIsTrustworthy(verdict)) {
                return WindowResult.unreadable(nBeats = clean.size, confidence = confidence(clean.size))
            }
            // Same gate, second fault: a BANKED stream stamps a whole record of intervals on one
            // timestamp, so its stored values are a decomposition of a record period rather than
            // beat-to-beat measurements. Coverage cannot see that — such a night can measure a
            // textbook 1.03 — but every spread below is built from those values. Twin of the Swift gate.
            val accurate = HrvAnalyzer.beatAccurateFraction(tsLong, input.rrMs)
            if (!HrvAnalyzer.beatValuesAreTrustworthy(accurate)) {
                return WindowResult.unreadable(nBeats = clean.size, confidence = confidence(clean.size))
            }
        }

        // Core descriptive statistics over the clean (range-filtered, ectopy-kept) series.
        val stats = computeStats(clean)
        val rrLabel = classify(stats)

        // Optional independent PPG IBI channel: same stats + label; report agreement.
        var agreed = false
        val ppg = input.ppgIBIms
        if (ppg != null) {
            val ppgClean = HrvAnalyzer.rangeFilter(ppg)
            if (ppgClean.size >= WINDOW_MIN_BEATS) {
                val ppgStats = computeStats(ppgClean)
                val ppgLabel = classify(ppgStats)
                agreed = (ppgLabel == rrLabel)
            }
        }

        val cloud = poincareCloud(clean)
        return WindowResult(
            label = rrLabel,
            sd1 = stats.sd1, sd2 = stats.sd2, sd1sd2 = stats.sd1sd2,
            normRmssd = stats.normRmssd, turningPointRate = stats.turningPointRate,
            ectopicFraction = stats.ectopicFraction,
            nBeats = clean.size, confidence = confidence(clean.size),
            agreedAcrossSources = agreed, poincare = cloud,
        )
    }

    /**
     * Aggregate a night's window results into a descriptive summary for the night view.
     * Counting only — produces no verdict and triggers nothing.
     */
    fun summarizeNight(windows: List<WindowResult>): NightRhythmSummary {
        val readable = windows.filter { it.label != RhythmRegularity.UNREADABLE }
        val steady = readable.count { it.label == RhythmRegularity.STEADY }
        val occasional = readable.count { it.label == RhythmRegularity.OCCASIONAL_ECTOPY }
        val varied = readable.count { it.label == RhythmRegularity.VARIED }

        val recurred = varied >= NIGHT_MIN_VARIED_WINDOWS

        val overall = when {
            readable.isEmpty() -> RhythmRegularity.UNREADABLE
            varied >= NIGHT_MIN_VARIED_WINDOWS -> RhythmRegularity.VARIED
            varied > 0 || occasional > 0 -> RhythmRegularity.OCCASIONAL_ECTOPY
            else -> RhythmRegularity.STEADY
        }

        return NightRhythmSummary(
            readableWindows = readable.size,
            steadyWindows = steady, occasionalWindows = occasional,
            variedWindows = varied, variationRecurred = recurred,
            overall = overall,
        )
    }

    // ── Empty-state diagnosis (#1360 — a TRUTHFUL empty state) ────────────────────────
    //
    // When a night produces nothing to plot, the screen must say WHY honestly. A device that can NEVER
    // satisfy the read (a structural capture limit) is not the same as a night that merely lacked a calm,
    // still window — and telling a ring owner "try again tomorrow" every night, when tomorrow is identical,
    // is the misleading empty state #1360 fixes. These helpers name the refusal WITHOUT relaxing any gate.
    // Twins of the Swift helpers.

    /**
     * Measured over the whole night: are the stored beats BANKED onto record timestamps, so the exact
     * per-beat spacing isn't recoverable? Reuses [HrvAnalyzer.beatAccurateFraction] — the fill ratio comes
     * from the RECORD TIMESTAMPS, never from the interval values being judged, so it can't be gamed by
     * laying beats out cumulatively (the #194 trap the gate exists to avoid). Returns false when timestamps
     * are absent or length-mismatched: a live spot capture carries none and is perfectly time-accurate, not
     * "banked". The device-class (#1108) signal, independent of the motion gate. Twin of the Swift helper.
     */
    fun nightBeatsAreBanked(rrMs: List<Double>, tsSec: List<Int>): Boolean {
        if (tsSec.size != rrMs.size || tsSec.isEmpty()) return false
        val accurate = HrvAnalyzer.beatAccurateFraction(tsSec.map { it.toLong() }, rrMs)
        return !HrvAnalyzer.beatValuesAreTrustworthy(accurate)
    }

    /**
     * Diagnose WHY a night has nothing to show, so the empty state reads truthfully (#1360). Names the
     * refusal the gates already made — consults no gate and relaxes none:
     *   • [RhythmEmptyState.NONE]           — a window was readable; the caller shows the plot.
     *   • [RhythmEmptyState.GATHERING_DATA] — the honest default: a device that DOES record a stillness
     *                                         signal (so it can read in principle), a no-data night, or a
     *                                         genuine restless one. The only "try again" state.
     *   • [RhythmEmptyState.DEVICE_BANKS_BEATS] / [RhythmEmptyState.DEVICE_NO_MOTION] — a STRUCTURAL limit,
     *                                         reached ONLY when the device recorded dense R-R yet NO stillness
     *                                         signal at ALL (gravitySample empty for the whole DB, #804 — the
     *                                         ring signature). Gating both on !hadMotionSignal is deliberate:
     *                                         a WHOOP always writes an accelerometer track, so a WHOOP night
     *                                         whose banked R-R measures over-counted (#1118) is NEVER
     *                                         mislabelled "can't support it". When structurally incapable,
     *                                         [beatsAreBanked] picks the more informative copy.
     * [hadMotionSignal] = any stillness/gravity sample existed; [beatsAreBanked] = [nightBeatsAreBanked].
     * Twin of the Swift helper.
     */
    fun classifyEmptyState(
        windows: List<WindowResult>,
        hadMotionSignal: Boolean,
        beatsAreBanked: Boolean,
    ): RhythmEmptyState {
        if (windows.any { it.label != RhythmRegularity.UNREADABLE }) return RhythmEmptyState.NONE
        // A device WITH a motion signal (WHOOP), or a night with no dense window yet, gets the honest
        // "try again" — never a permanent "can't support" verdict. Only the ring signature is structural.
        if (hadMotionSignal || windows.isEmpty()) return RhythmEmptyState.GATHERING_DATA
        return if (beatsAreBanked) RhythmEmptyState.DEVICE_BANKS_BEATS else RhythmEmptyState.DEVICE_NO_MOTION
    }

    // ── Statistics ──────────────────────────────────────────────────────────────────

    /** Bundle of the descriptive statistics over a clean window. Mirrors Swift `Stats`. */
    data class Stats(
        val sd1: Double?,
        val sd2: Double?,
        val sd1sd2: Double?,
        val normRmssd: Double?,
        val turningPointRate: Double?,
        val ectopicFraction: Double?,
    )

    /**
     * Compute SD1/SD2/ratio, normalised RMSSD, turning-point rate and ectopic fraction
     * over an already range-filtered (ectopy-kept) NN series. Reuses [HrvAnalyzer].
     */
    fun computeStats(nn: List<Double>): Stats {
        if (nn.size < 2) {
            return Stats(sd1 = null, sd2 = null, sd1sd2 = null, normRmssd = null,
                turningPointRate = null, ectopicFraction = ectopicFraction(nn))
        }
        val rmssd = HrvAnalyzer.rmssdRaw(nn)
        val sdnn = HrvAnalyzer.sdnnRaw(nn)
        val meanNN = nn.sum() / nn.size.toDouble()

        // SD1 = RMSSD/√2 (Poincaré short axis). SD2 = sqrt(2·SDNN² − SD1²).
        val sd1: Double? = rmssd?.let { it / sqrt(2.0) }
        var sd2: Double? = null
        if (sd1 != null && sdnn != null) {
            val v = 2.0 * sdnn * sdnn - sd1 * sd1
            sd2 = if (v > 0) sqrt(v) else 0.0
        }
        val ratio: Double? = if (sd1 != null && (sd2 ?: 0.0) > 0) sd1 / sd2!! else null

        val normRmssd: Double? = if (rmssd != null && meanNN > 0) rmssd / meanNN else null
        val tp = turningPointRate(nn)
        val ect = ectopicFraction(nn)

        return Stats(sd1 = sd1, sd2 = sd2, sd1sd2 = ratio,
            normRmssd = normRmssd, turningPointRate = tp, ectopicFraction = ect)
    }

    /**
     * Normalised turning-point rate: fraction of interior points that are local extrema
     * (a sign change in successive Δ), divided by the 2/3 expected for a random series.
     */
    fun turningPointRate(nn: List<Double>): Double? {
        if (nn.size < 3) return null
        var turns = 0
        for (i in 1 until nn.size - 1) {
            val a = nn[i] - nn[i - 1]
            val b = nn[i + 1] - nn[i]
            if (a * b < 0) turns += 1   // direction reversed → a turning point
        }
        val interior = (nn.size - 2).toDouble()
        if (interior <= 0) return null
        val rate = turns.toDouble() / interior
        val expectedRandom = 2.0 / 3.0
        return rate / expectedRandom
    }

    /**
     * Ectopic-beat fraction: the fraction of beats [HrvAnalyzer.rejectEctopic] WOULD
     * drop, used here as a COUNTER (HRV discards these; we count them). 0 when empty.
     */
    fun ectopicFraction(nn: List<Double>): Double {
        if (nn.isEmpty()) return 0.0
        val kept = HrvAnalyzer.rejectEctopic(nn)
        val dropped = nn.size - kept.size
        return dropped.toDouble() / nn.size.toDouble()
    }

    /** The Poincaré point cloud: successive (NN[i], NN[i+1]) pairs. */
    fun poincareCloud(nn: List<Double>): List<PoincarePoint> {
        if (nn.size < 2) return emptyList()
        val pts = ArrayList<PoincarePoint>(nn.size - 1)
        for (i in 1 until nn.size) {
            pts.add(PoincarePoint(x = nn[i - 1], y = nn[i]))
        }
        return pts
    }

    // ── Classification (neutral, visualization-scoped — NO clinical verdict) ──────────

    /**
     * Map descriptive stats to a NEUTRAL regularity label. The "varied" condition is a
     * conservative AND of high scatter, high beat-to-beat variation AND choppy turning (a
     * round, disorganised cloud). Isolated extra/skipped beats — a notable ectopic
     * fraction with an otherwise SMOOTH rhythm (low turning-point rate) — read separately
     * as "occasional", discriminating sparse couplets (large scatter but not choppy) from
     * genuinely disorganised timing. Everything else reads "steady". No condition is ever
     * named, and there is no call-to-action.
     */
    fun classify(s: Stats): RhythmRegularity {
        val ratio = s.sd1sd2 ?: return RhythmRegularity.UNREADABLE
        val nrmssd = s.normRmssd ?: return RhythmRegularity.UNREADABLE
        val tp = s.turningPointRate ?: return RhythmRegularity.UNREADABLE

        val scatterHigh = ratio >= TAU_RATIO
        val variationHigh = nrmssd >= TAU_NRMSSD
        val turningHigh = tp >= TAU_TP

        // Conservative AND: only round AND variable AND choppy reads "varied a lot".
        if (scatterHigh && variationHigh && turningHigh) {
            return RhythmRegularity.VARIED
        }

        // Occasional extra/skipped beats: notable ectopic fraction but NOT choppy — the
        // rhythm is otherwise smooth, so this is sparse couplets, not disorganised timing.
        val ect = s.ectopicFraction ?: 0.0
        if (ect >= TAU_ECTOPIC_LOW && !turningHigh) {
            return RhythmRegularity.OCCASIONAL_ECTOPY
        }

        return RhythmRegularity.STEADY
    }

    /** Read certainty from the clean-beat count, mirroring [RhythmConfidence] tiers. */
    fun confidence(nBeats: Int): RhythmConfidence {
        if (nBeats < WINDOW_MIN_BEATS) return RhythmConfidence.CALIBRATING
        return if (nBeats >= SOLID_BEATS) RhythmConfidence.SOLID else RhythmConfidence.BUILDING
    }
}

/**
 * Neutral, visualization-scoped regularity category. Strings are deliberately benign:
 * no disease names, no diagnostic terms, no call-to-action. Backs an experimental
 * wellness PLOT, not a screening verdict. The [raw] string matches Swift's enum raw value.
 */
enum class RhythmRegularity(val raw: String) {
    STEADY("steady"),
    OCCASIONAL_ECTOPY("occasionalEctopy"),
    VARIED("varied"),
    UNREADABLE("unreadable"),
}

/**
 * Read certainty for a regularity result — mirrors [ScoreConfidence] tiers so a thin
 * window reads truthfully. The [raw] string matches Swift's enum raw value.
 */
enum class RhythmConfidence(val raw: String) {
    CALIBRATING("calibrating"),
    BUILDING("building"),
    SOLID("solid"),
}

/**
 * Why the Rhythm screen has nothing to plot, so its empty state can be TRUTHFUL instead of always
 * reading "try again tomorrow" (#1360). A structural capture limit ([DEVICE_BANKS_BEATS] /
 * [DEVICE_NO_MOTION]) is PERMANENT for that device and must not be phrased as a one-off bad night;
 * [GATHERING_DATA] is the only state that means "try again". Produced by [RhythmScreener.classifyEmptyState].
 * The [raw] string matches Swift's enum raw value.
 */
enum class RhythmEmptyState(val raw: String) {
    /** A window was readable — the caller shows the plot, not an empty state. */
    NONE("none"),
    /** Not enough evidence yet, or a genuine restless night. The only "try again" state. */
    GATHERING_DATA("gatheringData"),
    /** The device records no stillness signal at all, so the motion gate can never pass (#804). */
    DEVICE_NO_MOTION("deviceNoMotion"),
    /** The device banks its beats onto record timestamps, so per-beat spacing is unrecoverable (#1108). */
    DEVICE_BANKS_BEATS("deviceBanksBeats"),
}
