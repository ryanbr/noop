package com.noop.analytics

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sqrt

/*
 * Baselines.kt — personal rolling baselines per nightly metric.
 *
 * Faithful Kotlin port of StrandAnalytics/Baselines.swift (verified on macOS),
 * itself ported from server/ingest/app/analysis/baselines.py.
 *
 * Two paths are provided:
 *   1. Winsorized EWMA (the production model): robust, recency-weighted center
 *      with an EWMA-of-absolute-deviation spread tracker, cold-start gating, hard
 *      outlier rejection, and Winsor clamping. This is [update] / [foldHistory].
 *   2. Trailing-window mean/SD (the task's "trailing 30-day mean/SD"): a simple,
 *      auditable rolling mean and sample SD over the trailing N valid nights.
 *      This is [rollingMeanSD]. Useful for explainability and cross-checking.
 *
 * Both produce a [BaselineState] so RecoveryScorer can consume either uniformly.
 *
 * The value types ([MetricCfg], [BaselineStatus], [BaselineState], [Deviation])
 * are defined in AnalyticsModels.kt and intentionally NOT redefined here. All
 * `ts` are wall-clock unix SECONDS (Long) elsewhere; baselines work on per-night
 * scalar values and carry no timestamps.
 *
 * Outputs are APPROXIMATE and not medical advice.
 */

/** Personal rolling baselines. Mirrors Swift `Baselines` (an enum used as a namespace). */
object Baselines {

    // ─────────────────────────────────────────────────────────────────────────
    // Constants (baselines.py)
    // ─────────────────────────────────────────────────────────────────────────

    /** Winsorization clamp: fold only within ±WINSOR_K × spread. */
    const val winsorK: Double = 3.0

    /** Hard-reject gate: drop the night if > HARD_OUTLIER_K × spread away. */
    const val hardOutlierK: Double = 5.0

    /** Minimum valid nights before "provisionally" trusted. */
    const val minNightsSeed: Int = 4

    /** Minimum valid nights before fully trusted. */
    const val minNightsTrust: Int = 14

    /** Missing-night count after which a baseline is marked stale. */
    const val staleDays: Int = 14

    /**
     * How many days a nightly VITAL may be carried forward and still be presented as the "latest"
     * reading. A carry exists so one missed night doesn't blank a tile — not so a months-old value
     * reads as tonight's measurement. Past this age the tile must show "—": a silent stale number is
     * worse than no number, because the reader takes it for a current measurement (which is exactly
     * what a 14-day-old imported respiratory rate did, surfacing as "Respiratory 15.6" on the Sleep
     * tab's Night detail with no date beside it). A week comfortably covers a missed night or a
     * weekend off-strap while staying decisively short of [staleDays], past which the personal
     * baseline that judges the value is itself stale. Byte-twin of the Swift `vitalCarryDays`.
     */
    const val vitalCarryDays: Int = 7

    /**
     * The freshest `(day, value)` pair still fresh enough to present as "latest", or null when the
     * newest one is older than [carryDays] relative to [todayKey]. Both keys are `yyyy-MM-dd`, which
     * compares chronologically as a string, so no calendar math (or time zone) is involved — [points]
     * need only be sorted oldest→newest. Byte-twin of the Swift `freshestCarried`.
     */
    fun <T> freshestCarried(
        points: List<Pair<String, T>>,
        todayKey: String,
        carryDays: Int = vitalCarryDays,
    ): Pair<String, T>? {
        val newest = points.lastOrNull() ?: return null
        return if (newest.first >= cutoffKey(todayKey, carryDays)) newest else null
    }

    /**
     * The oldest `yyyy-MM-dd` a carried vital may bear: [todayKey] − [carryDays] days. An unparseable
     * key yields [todayKey], which admits only today — fail closed, never carry. Byte-twin of the
     * Swift `cutoffKey`.
     */
    fun cutoffKey(todayKey: String, carryDays: Int = vitalCarryDays): String =
        runCatching {
            java.time.LocalDate.parse(todayKey).minusDays(carryDays.toLong()).toString()
        }.getOrDefault(todayKey)

    // ─────────────────────────────────────────────────────────────────────────
    // Early-life anti-anchoring (Reddit HRV report) — mirrors Baselines.swift
    // ─────────────────────────────────────────────────────────────────────────
    //
    // The original model seeds the center on the first valid night with spread pinned at the
    // floor, then becomes "usable" at minNightsSeed. If those first few nights read artificially
    // HIGH (a common cold-start artefact), three things compounded to lock the baseline high for
    // ~2-3 weeks: (a) the seed fixed the mean high while spread sat at the floor; (b) the hard
    // outlier gate then REJECTED the user's genuine LOWER nights (a true 54ms vs an anchored ~85ms
    // baseline is >5× the floor spread → "seen but not folded"); (c) the still-tight spread made
    // the z-score hypersensitive, crushing Charge to 1-2.
    //
    // The fix is conservative: during the baseline's EARLY life let reality pull the center down
    // quickly, THEN settle to the normal long-term smoothing. Long-term behaviour (after
    // earlyAdaptNights, once spread has lifted) is byte-identical to before.

    /** Valid-night count below which the baseline is "young": fast center adaptation + suspended
     *  hard-outlier gate. Chosen so convergence happens in days, not weeks. */
    const val earlyAdaptNights: Int = 8

    /** Center half-life (nights) used while the baseline is young — much faster than halfLifeB. */
    const val earlyHalfLifeB: Double = 3.0

    /** Multiplier on spread for the Winsor clamp while young, so an honest lower night isn't clamped
     *  flat against a floor-tight band before the spread has had a chance to widen. */
    const val earlySpreadInflate: Double = 2.5

    /** SharedPreferences key for the manual HRV-baseline recalibration epoch (epoch SECONDS).
     *  0 / absent = no recalibration. Written by the Settings "Recalibrate HRV baseline" button.
     *  EXACT same key string as the iOS UserDefaults key. */
    const val hrvBaselineEpochKey: String = "noop.hrvBaselineEpoch"

    /** SharedPreferences key for the manual RECOVERY-baseline recalibration epoch (epoch SECONDS).
     *  0 / absent = no recalibration. The Charge-wide sibling of [hrvBaselineEpochKey]: HRV (the
     *  dominant Charge driver) re-anchors on its own epoch today, while the resting-HR / respiration /
     *  skin-temp baselines that also feed Charge re-anchor on THIS epoch. The Settings "Recalibrate
     *  Charge baseline" button writes BOTH keys to now (see [recalibrateRecoveryBaselines]) so the whole
     *  Charge build-up restarts cleanly. EXACT same key string as the iOS UserDefaults key. */
    const val recoveryBaselineEpochKey: String = "noop.recoveryBaselineEpoch"

    /**
     * Default per-metric configurations (HRV, resting HR, respiration, skin temp, daily
     * Effort/strain).
     *
     * "strain" backs the RecoveryScorer Activity-Balance / previous-day-Effort term: bounds
     * match `StrainScorer.maxStrain`'s 0-100 output scale (the Charge/Effort/Rest redesign's
     * rescale of the historical 0-21 axis). floorSpread is wider than the physiological
     * metrics above (5.0 vs ~1-2% of range elsewhere) because day-to-day training load is
     * EXPECTED to swing hard (a rest day vs a hard day is a normal, large delta) — a tight
     * floor would make the z-score hypersensitive to routine training variation. Same
     * half-lives as the other metrics for consistency.
     */
    val metricCfg: Map<String, MetricCfg> = mapOf(
        "hrv" to MetricCfg(
            minVal = 5.0, maxVal = 250.0, floorSpread = 5.0,
            halfLifeB = 14.0, halfLifeS = 21.0,
        ),
        "resting_hr" to MetricCfg(
            minVal = 30.0, maxVal = 120.0, floorSpread = 2.0,
            halfLifeB = 14.0, halfLifeS = 21.0,
        ),
        "resp" to MetricCfg(
            minVal = 4.0, maxVal = 40.0, floorSpread = 0.5,
            halfLifeB = 14.0, halfLifeS = 21.0,
        ),
        "skin_temp" to MetricCfg(
            minVal = 20.0, maxVal = 42.0, floorSpread = 0.3,
            halfLifeB = 14.0, halfLifeS = 21.0,
        ),
        "strain" to MetricCfg(
            minVal = 0.0, maxVal = 100.0, floorSpread = 5.0,
            halfLifeB = 14.0, halfLifeS = 21.0,
        ),
    )

    /** Convenience accessor for the standard HRV config. */
    val hrvCfg: MetricCfg get() = metricCfg.getValue("hrv")

    /** Convenience accessor for the standard resting-HR config. */
    val restingHRCfg: MetricCfg get() = metricCfg.getValue("resting_hr")

    /** Convenience accessor for the standard respiration config. */
    val respCfg: MetricCfg get() = metricCfg.getValue("resp")

    /** Baseline config for the RecoveryScorer Activity-Balance / previous-day-Effort term. */
    val strainCfg: MetricCfg get() = metricCfg.getValue("strain")

    /** Convert a half-life in nights to an EWMA smoothing factor. */
    internal fun lambda(halfLife: Double): Double = 1.0 - 0.5.pow(1.0 / halfLife)

    internal fun computeStatus(nValid: Int, nightsSinceUpdate: Int): BaselineStatus {
        if (nightsSinceUpdate > staleDays && nValid >= minNightsSeed) return BaselineStatus.STALE
        if (nValid < minNightsSeed) return BaselineStatus.CALIBRATING
        if (nValid < minNightsTrust) return BaselineStatus.PROVISIONAL
        return BaselineStatus.TRUSTED
    }

    /** #612: calendar days since the newest night that carried a usable HRV reading (the baseline's input),
     *  or null when there is none / a key can't be parsed. DISTINCT from `calibrationNights` (which counts
     *  progress TOWARD a usable baseline) — this measures staleness, so a surface can say "no new nights from
     *  your strap for N days" when the baseline aged out silently instead of only "building your baseline".
     *  Pure and TZ-free (civil-day arithmetic); byte-identical mirror of the Swift twin. `dayKeys`/`nightlyHrv`
     *  are parallel (same night per index); `today` is an ISO `yyyy-MM-dd` key. */
    fun nightsSinceNewestValidNight(dayKeys: List<String>, nightlyHrv: List<Double?>, today: String): Int? {
        var newest: String? = null
        for (i in 0 until minOf(dayKeys.size, nightlyHrv.size)) {
            if (nightlyHrv[i] == null) continue
            val k = dayKeys[i]
            if (newest == null || k > newest) newest = k
        }
        val n = newest ?: return null
        val a = isoEpochDay(n) ?: return null
        val b = isoEpochDay(today) ?: return null
        val d = b - a
        return if (d >= 0) d else null
    }

    /** Days from civil epoch (proleptic Gregorian) for an ISO `yyyy-MM-dd`, or null if unparseable. TZ-free
     *  (Howard Hinnant's algorithm), so Kotlin and Swift agree bit-for-bit on the day difference. */
    internal fun isoEpochDay(iso: String): Int? {
        val p = iso.split("-")
        if (p.size != 3) return null
        val y = p[0].toIntOrNull() ?: return null
        val m = p[1].toIntOrNull() ?: return null
        val d = p[2].toIntOrNull() ?: return null
        if (m < 1 || m > 12) return null
        val yy = if (m <= 2) y - 1 else y
        val era = (if (yy >= 0) yy else yy - 399) / 400
        val yoe = yy - era * 400
        val doy = (153 * (if (m > 2) m - 3 else m + 9) + 2) / 5 + d - 1
        val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Winsorized EWMA update (production model)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Incorporate one new nightly value into the baseline state.
     *
     * - `state == null`: seed the first night.
     * - `value == null` or out-of-range: skip-and-hold (carry forward).
     * - hard outlier (> HARD_OUTLIER_K × spread): seen but not folded.
     * - otherwise: Winsorized EWMA center + EWMA-abs-dev spread update.
     */
    fun update(state: BaselineState?, value: Double?, cfg: MetricCfg): BaselineState {
        val lb = lambda(cfg.halfLifeB)
        val ls = lambda(cfg.halfLifeS)

        // First night ever.
        if (state == null) {
            if (value != null && cfg.minVal <= value && value <= cfg.maxVal) {
                return BaselineState(
                    baseline = value, spread = cfg.floorSpread, nValid = 1,
                    nightsSinceUpdate = 0, status = BaselineStatus.CALIBRATING,
                )
            }
            val seed = (cfg.minVal + cfg.maxVal) / 2.0
            return BaselineState(
                baseline = seed, spread = cfg.floorSpread, nValid = 0,
                nightsSinceUpdate = 1, status = BaselineStatus.CALIBRATING,
            )
        }

        // Missing night: skip-and-hold.
        if (value == null) {
            val m = state.nightsSinceUpdate + 1
            return BaselineState(
                baseline = state.baseline, spread = state.spread,
                nValid = state.nValid, nightsSinceUpdate = m,
                status = computeStatus(state.nValid, m),
            )
        }

        // Step 0: sanity gate — physiologically implausible → skip-and-hold.
        if (!(cfg.minVal <= value && value <= cfg.maxVal)) {
            val m = state.nightsSinceUpdate + 1
            return BaselineState(
                baseline = state.baseline, spread = state.spread,
                nValid = state.nValid, nightsSinceUpdate = m,
                status = computeStatus(state.nValid, m),
            )
        }

        // Is the baseline still "young"? While young we adapt faster and suspend the hard-outlier
        // gate so genuine lower nights are never discarded before the spread reflects them. Tied to
        // the valid-night count (NOT spread): a long flat history is settled even though its spread
        // never lifted off the floor, and must still reject a wild one-off outlier.
        val isYoung = state.nValid < earlyAdaptNights

        // Hard outlier rejection (only once seeded AND no longer young): seen, but not folded.
        // Suspending this during early life is the core anti-anchoring fix — a high seed with a
        // floor-tight spread would otherwise reject the user's real, lower readings as "outliers"
        // (a true 54ms vs an anchored ~90ms baseline is >5× the floor spread).
        if (state.nValid >= minNightsSeed && !isYoung) {
            val dev = abs(value - state.baseline)
            if (dev > hardOutlierK * state.spread) {
                return BaselineState(
                    baseline = state.baseline, spread = state.spread,
                    nValid = state.nValid, nightsSinceUpdate = 0,
                    status = computeStatus(state.nValid, 0),
                )
            }
        }

        // First real value after a None-placeholder seed: treat as clean first night.
        if (state.nValid == 0) {
            return BaselineState(
                baseline = value, spread = cfg.floorSpread, nValid = 1,
                nightsSinceUpdate = 0, status = BaselineStatus.CALIBRATING,
            )
        }

        // Step 1: Winsorized EWMA update.
        // While young, widen the clamp band (inflate the effective spread) so an honest lower night
        // isn't clamped flat against a floor-tight band, and use the faster early center half-life so
        // the center tracks reality in days. Both relax to the normal values once settled.
        val effSpread = if (isYoung) state.spread * earlySpreadInflate else state.spread
        val effLb = if (isYoung) lambda(earlyHalfLifeB) else lb
        val lo = state.baseline - winsorK * effSpread
        val hi = state.baseline + winsorK * effSpread
        val clamped = max(lo, min(hi, value))
        val newBaseline = effLb * clamped + (1.0 - effLb) * state.baseline

        // Spread uses the UNCLAMPED value so true deviations are tracked.
        val absDev = abs(value - newBaseline)
        val newSpread = max(cfg.floorSpread, ls * absDev + (1.0 - ls) * state.spread)
        val newN = state.nValid + 1

        return BaselineState(
            baseline = newBaseline, spread = newSpread, nValid = newN,
            nightsSinceUpdate = 0,
            status = computeStatus(newN, 0),
        )
    }

    /**
     * Replay an ordered sequence of nightly values (oldest first) to build state.
     * `null` entries are treated as missing nights (skip-and-hold).
     */
    fun foldHistory(values: List<Double?>, cfg: MetricCfg): BaselineState {
        var state: BaselineState? = null
        for (v in values) state = update(state, v, cfg)
        state?.let { return it }
        val seed = (cfg.minVal + cfg.maxVal) / 2.0
        return BaselineState(
            baseline = seed, spread = cfg.floorSpread, nValid = 0,
            nightsSinceUpdate = 0, status = BaselineStatus.CALIBRATING,
        )
    }

    /**
     * Replay an ordered sequence of nightly values (oldest first) to build state, honouring a manual
     * recalibration [baselineEpoch] (epoch SECONDS; 0 = no recalibration).
     *
     * [dayKeys] runs parallel to [values] ("yyyy-MM-dd", same order/length). Any night whose day
     * STARTS (UTC) before [baselineEpoch] is ignored entirely (NOT a skip-and-hold — it is dropped,
     * so the baseline re-seeds from the first on-or-after-epoch night). This lets the user reset a
     * baseline that anchored too high: tap "Recalibrate HRV baseline" in Settings (which writes
     * `now-seconds` to the [hrvBaselineEpochKey] pref) and the Charge baseline re-learns from tonight.
     *
     * When [baselineEpoch] <= 0 (the default / no recalibration) this is byte-identical to the plain
     * [foldHistory]. The caller reads the persisted epoch from SharedPreferences (the analytics layer
     * is Context-free) — exact same key string as the iOS UserDefaults key. Mirrors the Swift overload.
     */
    fun foldHistory(
        values: List<Double?>,
        dayKeys: List<String>,
        cfg: MetricCfg,
        baselineEpoch: Double,
    ): BaselineState {
        if (baselineEpoch <= 0.0) return foldHistory(values, cfg)

        var state: BaselineState? = null
        for (i in values.indices) {
            // Drop (not skip-and-hold) any night dated before the recalibration epoch.
            if (i < dayKeys.size) {
                val dayStart = runCatching {
                    java.time.LocalDate.parse(dayKeys[i])
                        .atStartOfDay(java.time.ZoneOffset.UTC).toEpochSecond().toDouble()
                }.getOrNull()
                if (dayStart != null && dayStart < baselineEpoch) continue
            }
            state = update(state, values[i], cfg)
        }
        state?.let { return it }
        val seed = (cfg.minVal + cfg.maxVal) / 2.0
        return BaselineState(
            baseline = seed, spread = cfg.floorSpread, nValid = 0,
            nightsSinceUpdate = 0, status = BaselineStatus.CALIBRATING,
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Device-era boundary (#459)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * The recalibration epoch (seconds, UTC start-of-day) at the LATEST device-era boundary in a
     * source-tagged nightly history, for feeding [foldHistory]'s `baselineEpoch` so a baseline can't
     * mix two brands' incompatible HRV scales (#459: an Oura→WHOOP switch has Oura RMSSD ~120–155 ms
     * vs WHOOP ~72–112 ms with no overlap nights, so a straddling 30-night window reads the first
     * WHOOP nights as "suppressed" against an Oura-inflated mean — a device artifact, not physiology).
     *
     * CONTRACT: [sourceDays] is exactly ONE `(dayKey "yyyy-MM-dd", sourceId)` per night — the day's
     * WINNING source (the same per-day merge winner whose value the fold uses), NOT one row per source.
     * The "current era" is read off the NEWEST day's brand, so an overlap day carrying two brands would,
     * under the deterministic (day, sourceId) sort, let the lexically-later source (e.g. "oura-import" >
     * "my-whoop") masquerade as the current brand. Passing one-per-day-winner makes that impossible; the
     * same-day-tie handling below is only a determinism backstop, not a licence to pass raw multi-source
     * rows. Any order is fine (it is sorted here).
     *
     * The epoch is the start of the first day of the LATEST contiguous single-brand era: walk
     * newest→oldest while the brand matches the newest night's brand, and return that run's first day's
     * start (a lone off-brand day inside the current era truncates it — fail-safe: it drops MORE history,
     * never mixes scales). Returns 0.0 (no recalibration → [foldHistory] is byte-identical) when the
     * whole history is ONE brand — so a single-device user, and a WHOOP user whose imported + computed +
     * strap ids all bucket to "whoop", is completely unaffected.
     *
     * The brand bucket is intentionally coarse and NOT [DeviceFamily] (that only splits WHOOP 4 vs 5,
     * both the same HRV scale): every WHOOP-origin id (the canonical import, the active strap, the
     * "-noop" computed sibling, Health-Connect/Apple rows that ride the strap source) is ONE brand;
     * each wearable-export brand (oura/fitbit/garmin) is its own. Pure + unit-pinned; the caller
     * assembles [sourceDays] from the ORIGINAL per-source reads (brand is lost once a wearable day is
     * re-homed under the computed WHOOP id, so detection must precede the merge). Mirrors the Swift twin.
     */
    fun deviceEraEpoch(sourceDays: List<Pair<String, String>>): Double {
        if (sourceDays.isEmpty()) return 0.0
        // Total order by (day, sourceId) — a same-day mixed-brand row (an overlap night) must break the
        // tie IDENTICALLY to the Swift twin, so a plain by-day sort (stable in Kotlin, unstable in Swift)
        // can't diverge the computed epoch across platforms.
        val sorted = sourceDays.sortedWith(compareBy({ it.first }, { it.second }))
        val currentBrand = brandBucket(sorted.last().second)
        // No brand change anywhere → no epoch (byte-identical fold for every single-brand user).
        if (sorted.none { brandBucket(it.second) != currentBrand }) return 0.0
        // Walk back over the contiguous current-brand suffix; its first day opens the current era.
        var eraStartDay = sorted.last().first
        for (i in sorted.indices.reversed()) {
            if (brandBucket(sorted[i].second) != currentBrand) break
            eraStartDay = sorted[i].first
        }
        return runCatching {
            java.time.LocalDate.parse(eraStartDay)
                .atStartOfDay(java.time.ZoneOffset.UTC).toEpochSecond().toDouble()
        }.getOrDefault(0.0)
    }

    /**
     * Coarse HRV-scale brand for a source id (#459). Every WHOOP-origin id shares ONE scale; each
     * wearable-export brand is its own. Unknown ids bucket to "whoop" (the strap source and its Apple/
     * Health-Connect riders), so only a positively-identified wearable export changes the era. Mirrors
     * the Swift twin.
     */
    internal fun brandBucket(sourceId: String): String = when {
        // `startsWith` deliberately catches BOTH the export id ("oura-import") and the cloud id
        // ("oura-api"), so an Oura-cloud era and an Oura-export era read as the same brand.
        sourceId.startsWith("oura") -> "oura"
        sourceId.startsWith("fitbit") -> "fitbit"
        sourceId.startsWith("garmin") -> "garmin"
        // "apple-health" / "health-connect" fall through to "whoop" ON PURPOSE: NOOP's Apple/HC daily
        // rows ride the strap source's scale, and HC is a pass-through whose true origin is unknowable,
        // so they must NOT open a false era boundary against WHOOP nights.
        else -> "whoop"
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Deviation
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Compute z / delta / ratio / in-normal-range for a value vs a baseline.
     * z uses (value − baseline) / (1.253 × spread); 1.253 converts EWMA-abs-dev
     * to an approximate Gaussian σ (E[|X−μ|] = σ·√(2/π) ≈ σ/1.253).
     */
    fun deviation(value: Double, state: BaselineState): Deviation {
        val sigma = max(1.253 * state.spread, 1e-9)
        val z = (value - state.baseline) / sigma
        val delta = value - state.baseline
        val ratio = if (state.baseline != 0.0) (value / state.baseline - 1.0) else 0.0
        return Deviation(z = z, delta = delta, ratio = ratio, inNormalRange = abs(z) <= 1.0)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Trailing-window mean/SD (simple, auditable)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Rolling personal baseline from the trailing [window] valid nights, as a
     * plain mean and sample SD (ddof=1). This is the task's "trailing 30-day
     * mean/SD" path: no recency weighting, maximally explainable.
     *
     * Physiologically implausible values (outside cfg bounds) and nulls are
     * dropped. The spread returned is stored in the SAME internal units the
     * Winsor EWMA uses (abs-dev space), i.e. SD / 1.253, so that [deviation]
     * recovers the intended Gaussian σ unchanged.
     *
     * @param values ordered nightly values (oldest → newest); nulls allowed.
     * @param cfg metric config (bounds + floor spread).
     * @param window number of trailing valid nights to use (default 30).
     */
    fun rollingMeanSD(values: List<Double?>, cfg: MetricCfg, window: Int = 30): BaselineState {
        val valid = values.mapNotNull { v ->
            if (v != null && cfg.minVal <= v && v <= cfg.maxVal) v else null
        }
        if (valid.isEmpty()) {
            val seed = (cfg.minVal + cfg.maxVal) / 2.0
            return BaselineState(
                baseline = seed, spread = cfg.floorSpread, nValid = 0,
                nightsSinceUpdate = 0, status = BaselineStatus.CALIBRATING,
            )
        }
        val trailing = valid.takeLast(window)
        val n = trailing.size
        val mean = trailing.sum() / n.toDouble()

        val sd: Double
        if (n >= 2) {
            var ss = 0.0
            for (v in trailing) {
                val d = v - mean
                ss += d * d
            }
            sd = sqrt(ss / (n - 1).toDouble())
        } else {
            // Single sample: no dispersion estimate; fall back to the σ floor.
            sd = cfg.floorSpread * 1.253
        }

        // Apply the σ floor in σ-space, then convert to internal abs-dev space.
        val sigmaFloored = max(cfg.floorSpread, sd)
        val spreadInternal = sigmaFloored / 1.253

        return BaselineState(
            baseline = mean, spread = spreadInternal, nValid = n,
            nightsSinceUpdate = 0,
            status = computeStatus(n, 0),
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Manual recalibration ("Recalibrate Charge baseline")
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Recalibrate every baseline that feeds Charge: drop the anchor so the ~4-night build-up restarts
     * from [nowSeconds]. This is the single source of truth behind the Settings "Recalibrate Charge
     * baseline" button — it writes [nowSeconds] (epoch SECONDS, whole) to BOTH the HRV epoch and the
     * recovery epoch, so HRV (the dominant driver, already wired) and the resting-HR / respiration /
     * skin-temp baselines re-anchor together. It does NOT delete any stored day: only the day from
     * which the baselines re-learn moves. After this the next foldHistory re-seeds from the first
     * on-or-after-[nowSeconds] night, so Today honestly shows the calibrating/building state again.
     *
     * The analytics layer is Context-free, so the caller passes in the prefs editor. Epochs are stored
     * as whole seconds in a Long (SharedPreferences has no putDouble; the readers do getLong→toDouble),
     * matching the "epoch SECONDS" the keys document and the iOS UserDefaults values byte-for-byte.
     */
    fun recalibrateRecoveryBaselines(editor: android.content.SharedPreferences.Editor, nowSeconds: Long) {
        editor.putLong(hrvBaselineEpochKey, nowSeconds)
        editor.putLong(recoveryBaselineEpochKey, nowSeconds)
    }
}
