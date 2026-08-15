package com.noop.analytics

import com.noop.data.DailyMetric
import java.util.Locale
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.sqrt

/**
 * On-device "Readiness" intelligence.
 *
 * Synthesizes a handful of established, non-medical sports-science signals from the daily-metrics
 * history into a single readiness read plus the drivers behind it. Everything here is a pure,
 * deterministic function of the rows you pass in — no networking, no strap commands, no state.
 *
 * Faithful Kotlin port of
 * Packages/StrandAnalytics/Sources/StrandAnalytics/ReadinessEngine.swift (verified on macOS).
 * Same windows, same thresholds, same outputs.
 *
 * Signals and their references:
 * - **HRV readiness** — z-score of today's HRV against the personal trailing baseline. A drop of
 *   roughly half a standard deviation flags autonomic fatigue (Plews et al. 2013; Buchheit 2014).
 * - **Resting-HR drift** — elevated resting HR vs baseline is a classic overtraining / illness
 *   signal (Lamberts et al. 2004).
 * - **Respiratory-rate drift** — a rise in sleeping respiratory rate is an early illness signal.
 * - **Training Stress Balance (ACWR)** — acute (7-day) vs chronic (28-day) strain. The 0.8–1.3
 *   band is the "sweet spot"; >1.5 is associated with higher injury risk (Gabbett 2016).
 * - **Training monotony** — mean/SD of daily strain over a week; high monotony (low variety) is
 *   associated with higher strain and illness (Foster 1998).
 *
 * Not medical advice. These are approximations from a consumer strap; they describe trends in
 * *your own* data, nothing more.
 */
object ReadinessEngine {

    // MARK: Output types

    enum class Level {
        PRIMED,       // signals aligned, load supported
        BALANCED,     // nothing notable either way
        STRAINED,     // one meaningful signal down / load high
        RUNDOWN,      // several recovery signals down
        INSUFFICIENT, // not enough history yet
    }

    enum class Flag { GOOD, NEUTRAL, WATCH, BAD }

    data class Signal(
        val key: String,            // "hrv" | "rhr" | "respRate" | "acwr" | "monotony"
        val label: String,          // short human label
        val detail: String,         // one-line plain-English read
        val flag: Flag,
        // The numbers behind the signal, e.g. "48 vs 55 ms" or "7d 12.1 / 28d 9.4". Optional and
        // backward-compatible (defaults null); rendered as a small caption under the signal in the UI.
        val evidence: String? = null,
    )

    data class Readiness(
        val level: Level,
        val headline: String,
        val summary: String,
        val signals: List<Signal>,
        /** Acute:chronic workload ratio (null if not enough strain history). */
        val acwr: Double?,
        /** Foster training monotony over the last week (null if not enough strain history). */
        val monotony: Double?,
        /**
         * How much history backs this read (HRV/RHR baseline density) — so the card can show
         * calibrating / building / solid instead of a confident number off a 7-night baseline.
         * Defaults to CALIBRATING to match Swift's default init parameter.
         */
        val confidence: ScoreConfidence = ScoreConfidence.CALIBRATING,
    )

    // MARK: Tunables (named so the thresholds are auditable)

    private const val baselineWindow = 30   // days for HRV / RHR / RR baselines
    private const val minBaseline = 7       // need at least this many baseline nights
    private const val acuteWindow = 7
    private const val chronicWindow = 28
    private const val minChronic = 14       // need at least this much strain history for ACWR

    // Resp-rate signal is sourced from either clean cloud RR or a higher-variance on-device RSA
    // estimate (no source flag on the field), so it uses wider z thresholds than HRV/RHR and a
    // physiologic sanity band. A single noisy RSA night should not reach BAD (which feeds recoveryDown).
    private const val respZWatch = 1.5      // raised vs HRV/RHR (was 1.0) to absorb RSA night-to-night noise
    private const val respZBad = 2.0        // raised vs HRV/RHR (was 1.5) so one off-night can't trigger RUNDOWN
    // Single canonical band, owned by the producer so the stored RSA value can't disagree with this
    // gate (#78): SleepStager.respRateFromRR now NaNs anything outside it before persisting.
    private val respPlausibleRange = SleepStager.respPlausibleRangeBpm // plausible sleeping RR (bpm)

    // MARK: Entry point

    /**
     * Evaluate readiness from daily metrics. [days] may be in any order; the most recent day is
     * treated as "today" unless [today] (a YYYY-MM-DD string) is given.
     *
     * #1034 (ryanbr) perf: [evaluateUncached] SORTS the entire daily history and walks trailing windows on
     * every call, and it is read from Compose recompositions (TodayScreen / CoupledScreen) — so a recompose
     * on each ~1 Hz live-HR tick re-ran the full-history sort. Some call sites `remember{}` it; this
     * engine-level memo additionally shields the un-remembered ones and the first/uncached read, mirroring
     * the Swift ReadinessEngine.evaluateCache. Key = [today] + an ORDER-INDEPENDENT fingerprint over ONLY
     * the rows' readiness fields (day + avgHrv/restingHr/respRateBpm/strain), so a new sync re-keys but a
     * cosmetic reorder does not. The cached result is a small immutable [Readiness]; no row arrays retained.
     */
    fun evaluate(days: List<DailyMetric>, today: String? = null): Readiness {
        val key = readinessKey(today, days)
        synchronized(evaluateCacheLock) { evaluateCache[key] }?.let { return it }
        val result = evaluateUncached(days, today)   // computed OUTSIDE the lock (the expensive sort/walk)
        synchronized(evaluateCacheLock) { evaluateCache[key] = result }
        return result
    }

    private data class ReadinessKey(
        val today: String?, val count: Int, val minDay: Int, val maxDay: Int, val checksum: Long,
    )

    private const val EVALUATE_CACHE_CAP = 16

    /** Access-order LRU (cap [EVALUATE_CACHE_CAP]); every access is under [evaluateCacheLock] because a
     *  LinkedHashMap in access order mutates on `get`. Twin of Swift's AnalyticsMemoCache(capacity: 16). */
    private val evaluateCache: LinkedHashMap<ReadinessKey, Readiness> =
        object : LinkedHashMap<ReadinessKey, Readiness>(EVALUATE_CACHE_CAP, 0.75f, true) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<ReadinessKey, Readiness>): Boolean =
                size > EVALUATE_CACHE_CAP
        }
    private val evaluateCacheLock = Any()

    /** Order-independent fingerprint of the readiness-relevant columns — a new sync re-keys, a cosmetic
     *  reorder does not. Internal to this process's cache only (never compared cross-platform), so it need
     *  NOT match the Swift hash byte-for-byte; a collision only costs one extra recompute. Mirrors Swift
     *  `rowsFingerprint`: FNV-style commutative fold over (day, avgHrv, restingHr, respRateBpm, strain). */
    private fun readinessKey(today: String?, days: List<DailyMetric>): ReadinessKey {
        var sum = 1469598103934665603L
        var minDay = 0
        var maxDay = 0
        for ((i, d) in days.withIndex()) {
            var h = d.day.hashCode().toLong()
            h = h * 1099511628211L xor (d.avgHrv ?: -1.0).toRawBits()
            h = h * 1099511628211L xor (d.restingHr?.toLong() ?: Long.MAX_VALUE)
            h = h * 1099511628211L xor (d.respRateBpm ?: -1.0).toRawBits()
            h = h * 1099511628211L xor (d.strain ?: -1.0).toRawBits()
            sum = sum xor h   // commutative fold → order-independent
            val dh = d.day.hashCode()
            if (i == 0) { minDay = dh; maxDay = dh } else { minDay = minOf(minDay, dh); maxDay = maxOf(maxDay, dh) }
        }
        return ReadinessKey(today, days.size, minDay, maxDay, sum)
    }

    /** The uncached readiness synthesis (formerly the body of [evaluate]). [days] may be in any order; the
     *  most recent day is "today" unless [today] is given. */
    private fun evaluateUncached(days: List<DailyMetric>, today: String? = null): Readiness {
        val sorted = days.sortedBy { it.day }
        // When an explicit [today] is given (the dashboard passes the device's real local day key), use
        // the row for THAT day and nothing else: a stale historical import has no row for today, so the
        // readiness card reads "insufficient" rather than synthesizing off the newest stored — possibly
        // months-old — row (issue #23/#24). With no [today] (live-strap default callers) fall back to the
        // most recent row exactly as before, so nothing wearing the strap nightly changes.
        val latest = if (today != null) sorted.firstOrNull { it.day == today } else sorted.lastOrNull()
        if (latest == null) {
            return Readiness(
                level = Level.INSUFFICIENT,
                headline = "Readiness",
                summary = "Wear the strap for a few nights and your readiness read will appear here.",
                signals = emptyList(), acwr = null, monotony = null,
            )
        }
        val history = sorted.filter { it.day < latest.day }   // everything before today

        val signals = mutableListOf<Signal>()

        // HRV readiness ------------------------------------------------------
        val hrvSignal = zSignal(
            value = latest.avgHrv,
            baseline = history.takeLast(baselineWindow).mapNotNull { it.avgHrv },
            key = "hrv", label = "HRV",
            unit = "ms", decimals = 0,
            higherIsBetter = true,
            cfg = Baselines.readinessHRVLnCfg,   // RD2: ln-space spine, reject off
            logDomain = true,   // RD1: lnRMSSD — HRV is right-skewed
            goodText = "above your baseline - well recovered",
            neutralText = "in your normal range",
            watchText = "a touch below baseline",
            badText = "suppressed - a sign of autonomic fatigue",
        )
        if (hrvSignal != null) signals.add(hrvSignal)

        // Resting-HR drift ---------------------------------------------------
        val rhrSignal = zSignal(
            value = latest.restingHr?.toDouble(),
            baseline = history.takeLast(baselineWindow).mapNotNull { it.restingHr?.toDouble() },
            key = "rhr", label = "Resting HR",
            unit = "bpm", decimals = 0,
            higherIsBetter = false,
            cfg = Baselines.restingHRCfg,   // RD2: raw-bpm spine, reject off
            goodText = "at or below baseline",
            neutralText = "in your normal range",
            watchText = "running a little high",
            badText = "elevated - overtraining or illness can do this",
        )
        if (rhrSignal != null) signals.add(rhrSignal)

        // Respiratory-rate drift (illness early signal) ----------------------
        // respRateBpm may be a clean cloud value OR a higher-variance on-device RSA estimate
        // (WHOOP5 BLE-only) and carries no source flag, so gate conservatively for BOTH: keep the
        // minBaseline + sd>0 guard, only act on physiologically plausible sleeping-RR (~8-25 bpm),
        // and use wider resp-only z thresholds (WATCH 1.5 / BAD 2.0) so a single noisy night can't
        // reach BAD (which would feed recoveryDown), while a sustained genuine rise still flags.
        val rr = latest.respRateBpm
        if (rr != null && rr in respPlausibleRange) {
            val base = history.takeLast(baselineWindow).mapNotNull { it.respRateBpm }
            val m = mean(base)
            val sd = sampleSD(base)
            if (base.size >= minBaseline && m != null && m in respPlausibleRange && sd != null && sd > 0) {
                val z = (rr - m) / sd
                val respEvidence = "${fmt(rr, 1)} vs ${fmt(m, 1)} rpm"
                if (z >= respZBad) {
                    signals.add(
                        Signal(
                            key = "respRate", label = "Respiratory rate",
                            detail = "up vs baseline - sometimes an early sign of getting sick", flag = Flag.BAD,
                            evidence = respEvidence,
                        )
                    )
                } else if (z >= respZWatch) {
                    signals.add(
                        Signal(
                            key = "respRate", label = "Respiratory rate",
                            detail = "slightly raised vs baseline", flag = Flag.WATCH,
                            evidence = respEvidence,
                        )
                    )
                }
            }
        }

        // Training Stress Balance (ACWR) + monotony --------------------------
        val strainSeries = sorted.mapNotNull { it.strain }
        var acwr: Double? = null
        var monotony: Double? = null
        if (strainSeries.size >= minChronic) {
            val acute = mean(strainSeries.takeLast(acuteWindow))!!
            val chronic = mean(strainSeries.takeLast(chronicWindow))!!
            if (chronic > 0) {
                val ratio = acute / chronic
                acwr = ratio
                signals.add(acwrSignal(ratio, acute = acute, chronic = chronic))
            }
            // Foster monotony over the last week of strain.
            val week = strainSeries.takeLast(acuteWindow)
            val sd = sampleSD(week)
            val m = mean(week)
            if (week.size >= 4 && sd != null && sd > 0 && m != null) {
                val mono = m / sd
                monotony = mono
                if (mono >= 2.0) {
                    signals.add(
                        Signal(
                            key = "monotony", label = "Training variety",
                            detail = "low - similar strain every day raises strain/illness risk", flag = Flag.WATCH,
                            evidence = "monotony ${fmt(mono, 1)}",
                        )
                    )
                }
            }
        }

        val (level, headline, summary) = synthesize(
            signals = signals,
            hasHistory = history.isNotEmpty() || acwr != null,
        )
        // RD-confidence: surface how much history backs the read (HRV baseline density, the primary
        // readiness driver). A read off a 7-night baseline must not look as certain as one off the full
        // 30-night window. Insufficient reads carry CALIBRATING.
        val hrvBaselineNights = history.takeLast(baselineWindow).mapNotNull { it.avgHrv }.count()
        val confidence = ScoreConfidence.readiness(
            hasRead = level != Level.INSUFFICIENT,
            baselineNights = hrvBaselineNights,
            fullWindow = baselineWindow,
        )
        return Readiness(
            level = level, headline = headline, summary = summary,
            signals = signals, acwr = acwr, monotony = monotony,
            confidence = confidence,
        )
    }

    // MARK: Signal builders

    /** Build a z-score signal for a metric where the baseline is the trailing window. */
    private fun zSignal(
        value: Double?, baseline: List<Double>,
        key: String, label: String, unit: String, decimals: Int, higherIsBetter: Boolean,
        cfg: MetricCfg,
        logDomain: Boolean = false,
        goodText: String, neutralText: String,
        watchText: String, badText: String,
    ): Signal? {
        if (value == null || baseline.size < minBaseline) return null
        // RD1: right-skewed metrics (HRV/RMSSD) are z-scored in the LOG domain — lnRMSSD is closer to
        // normal, so a symmetric z is statistically valid, whereas a raw-ms z over-weights the long
        // upper tail and misstates tail rarity (Plews/Altini; the app's own HRVReadiness works this
        // way). RHR/resp are ~normal and stay linear. Evidence stays in the metric's own units, but the
        // baseline shown is then the GEOMETRIC mean (exp of the log-mean) — a typical night, not an
        // outlier-inflated arithmetic mean.
        val tv = if (logDomain) ln(maxOf(value, 1.0)) else value
        val tb = if (logDomain) baseline.map { ln(maxOf(it, 1.0)) } else baseline
        // RD2: fold the trailing baseline through the shared Winsorized-EWMA spine — recency-weighted,
        // σ-floored (a tight baseline can't saturate the z), and Winsor-clamped so a single freak night
        // is DAMPED not folded raw — instead of a flat mean + sample SD. Hard-outlier REJECTION is off
        // (`rejectHardOutliers = false`): a re-folded trailing window must ADAPT to a recent sustained
        // shift (fitness change / device swap) rather than reject the new normal as a run of outliers —
        // the window-fold vs incremental-fold distinction, validated on real HRV history. `cfg` is in
        // the SAME space as `tb` (ln for HRV, linear for RHR); center + spread come back σ-floored.
        // Mirrors Swift ReadinessEngine.zSignal.
        val state = Baselines.foldHistory(tb, cfg, rejectHardOutliers = false)
        if (!state.usable) return null
        val sigma = maxOf(1.253 * state.spread, 1e-9)   // robust σ from the EWMA-abs-dev spread
        if (sigma <= 0) return null
        val m = state.baseline
        // Orient z so positive always means "better".
        val z = (if (higherIsBetter) (tv - m) else (m - tv)) / sigma
        val flag: Flag
        val text: String
        when {
            z >= 0.5 -> { flag = Flag.GOOD; text = goodText }
            z >= -0.5 -> { flag = Flag.NEUTRAL; text = neutralText }
            z >= -1.0 -> { flag = Flag.WATCH; text = watchText }
            else -> { flag = Flag.BAD; text = badText }
        }
        // The numbers behind the read: today's value vs the baseline mean, in the metric's units. In the
        // log domain the baseline shown is the geometric mean (exp of the log-mean), not arithmetic.
        val baselineShown = if (logDomain) exp(m) else m
        val evidence = "${fmt(value, decimals)} vs ${fmt(baselineShown, decimals)} $unit"
        return Signal(key = key, label = label, detail = text, flag = flag, evidence = evidence)
    }

    /**
     * Format a metric value with the given number of decimals. Mirrors Swift's helper char-for-char:
     * the 0-decimal case uses round-half-AWAY-from-zero (Swift `Int(x.rounded())`, here `Math.round`)
     * — NOT printf's "%.0f" which is round-half-to-EVEN and would disagree at an exact .5; the >0 case
     * uses "%.Nf" (round-half-to-even) to match Swift's `String(format:)`. Locale.US so the separator
     * is always ".".
     */
    private fun fmt(x: Double, decimals: Int): String =
        if (decimals == 0) Math.round(x).toString()
        else String.format(Locale.US, "%.${decimals}f", x)

    private fun acwrSignal(ratio: Double, acute: Double, chronic: Double): Signal {
        // #1033 (ryanbr): route the acute:chronic ratio through the Locale.US-pinned [fmt] helper (matching
        // the evidence line below) so a comma-decimal device locale can't render "1,15" — iOS's
        // String(format:) is already locale-independent. Pure separator fix, no behavior change.
        val pct = fmt(ratio, 2)
        // Evidence: the two strain loads the ratio is built from, 1 dp each.
        val evidence = "7d ${fmt(acute, 1)} / 28d ${fmt(chronic, 1)}"
        return when {
            ratio < 0.8 -> Signal(
                key = "acwr", label = "Training load",
                detail = "ramping down (acute:chronic $pct) - room to build", flag = Flag.WATCH,
                evidence = evidence,
            )
            ratio < 1.3 -> Signal(
                key = "acwr", label = "Training load",
                detail = "in the sweet spot (acute:chronic $pct)", flag = Flag.GOOD,
                evidence = evidence,
            )
            ratio < 1.5 -> Signal(
                key = "acwr", label = "Training load",
                detail = "building fast (acute:chronic $pct) - watch fatigue", flag = Flag.WATCH,
                evidence = evidence,
            )
            else -> Signal(
                key = "acwr", label = "Training load",
                detail = "spiking (acute:chronic $pct) - higher injury risk", flag = Flag.BAD,
                evidence = evidence,
            )
        }
    }

    // MARK: Synthesis

    private fun synthesize(signals: List<Signal>, hasHistory: Boolean): Triple<Level, String, String> {
        if (!hasHistory || signals.isEmpty()) {
            return Triple(
                Level.INSUFFICIENT, "Readiness",
                "A few more nights of data and your readiness read will sharpen.",
            )
        }
        val bad = signals.filter { it.flag == Flag.BAD }
        val watch = signals.filter { it.flag == Flag.WATCH }
        val good = signals.filter { it.flag == Flag.GOOD }
        val recoveryDown = signals.any { it.key in listOf("hrv", "rhr", "respRate") && it.flag == Flag.BAD }
        val loadHigh = signals.any { it.key == "acwr" && it.flag == Flag.BAD }

        if (bad.size >= 2 || (recoveryDown && loadHigh)) {
            return Triple(
                Level.RUNDOWN, "Run down",
                "Several signals are down at once. Treat today as recovery - easy movement, real sleep tonight.",
            )
        }
        if (recoveryDown || loadHigh || bad.size >= 1) {
            return Triple(
                Level.STRAINED, "Strained",
                "One of your signals is flagging. You can train, but keep it controlled and bank the recovery.",
            )
        }
        if (good.size >= 2 && watch.isEmpty()) {
            return Triple(
                Level.PRIMED, "Primed",
                "Your signals are aligned and your load is supported. A harder session is well backed today.",
            )
        }
        return Triple(
            Level.BALANCED, "Balanced",
            "Nothing's flagging. Train to feel - your body's holding steady.",
        )
    }

    // MARK: Stats helpers

    fun mean(xs: List<Double>): Double? =
        if (xs.isEmpty()) null else xs.sum() / xs.size

    /** Sample standard deviation (n-1). null for fewer than 2 points. */
    fun sampleSD(xs: List<Double>): Double? {
        if (xs.size < 2) return null
        val m = mean(xs) ?: return null
        val ss = xs.fold(0.0) { acc, x -> acc + (x - m) * (x - m) }
        return sqrt(ss / (xs.size - 1))
    }
}
