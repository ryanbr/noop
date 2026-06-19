package com.noop.analytics

/*
 * MetricArbitrationPolicy (v5 — Local Multi-Device Fusion).
 *
 * Value-for-value Kotlin twin of Packages/StrandAnalytics/.../MetricArbitrationPolicy.swift — the
 * heart of v5 per docs/superpowers/specs/2026-06-19-v5-local-multi-device-fusion-design.md: a DATA
 * table (not if/else branches) keyed by metric × source that yields a trust tier + a plain, published
 * reason string, plus the per-metric cross-validation tolerances. The single place a future
 * Polar/Garmin/Oura source is registered. Pure constants + two lookups.
 *
 * Trust tiers (lower = more trusted), grounded in what a device MEASURES vs ESTIMATES (spec §1):
 *   0 — Direct dedicated sensor for this metric (WHOOP R-R for HRV; a wrist band's pedometer for
 *       steps; chest/PPG strap for avg/max/resting HR; ring/strap temp for skin temp).
 *   1 — Derived on-device from raw by NOOP (computed recovery/strain/sleep from strap streams).
 *   2 — Phone aggregate (Apple Health / Health Connect) of a declared-compatible quantity.
 *   3 — Estimate / proxy (a strap's STEP estimate; a calories estimate).
 *
 * "Best signal" is always backed by a NAMED, VISIBLE reason — never "accurate"/"correct"/"clinical".
 * This is wellness transparency, not a diagnosis.
 */
object MetricArbitrationPolicy {

    /**
     * The canonical fusion metric families. The string keys the resolver uses (e.g. "rhr",
     * "sleep_total_min", "sleep_deep_min") map onto one of these for tiering; raw keys that don't map
     * fall through to [MetricKind.OTHER] (single-source passthrough, tier by source kind only).
     */
    enum class MetricKind {
        RESTING_HR,
        HEART_RATE, // avg/max HR
        HRV,
        SPO2,
        SKIN_TEMP,
        STEPS,
        SLEEP, // any sleep stage/total
        CALORIES,
        OTHER,
    }

    /**
     * Map a resolver series key onto a [MetricKind]. Keys mirror the macOS Repository.appleCompatibleKey
     * vocabulary so the policy lines up with the existing cross-source resolver.
     */
    fun kind(forKey: String): MetricKind = when (forKey) {
        "rhr", "resting_hr" -> MetricKind.RESTING_HR
        "avg_hr", "max_hr" -> MetricKind.HEART_RATE
        "hrv" -> MetricKind.HRV
        "spo2" -> MetricKind.SPO2
        "skin_temp", "skinTemp" -> MetricKind.SKIN_TEMP
        "steps" -> MetricKind.STEPS
        "sleep_total_min", "asleep_min",
        "sleep_deep_min", "deep_min",
        "sleep_rem_min", "rem_min",
        "sleep_light_min", "core_min",
        "in_bed_min" -> MetricKind.SLEEP
        "active_kcal", "energy_kcal" -> MetricKind.CALORIES
        else -> MetricKind.OTHER
    }

    /**
     * Trust tier for a (metric, source) pair — lower is more trusted. Encodes the spec's
     * measure-vs-estimate intuition as data, e.g. a wrist band's pedometer (tier 0) beats the strap's
     * step ESTIMATE (tier 3); WHOOP sleep stages (tier 0) beat phone sleep buckets (tier 2). The
     * OTHER/unmapped keys tier purely by source kind (import vs computed vs phone vs cache).
     */
    fun tier(metric: MetricKind, source: FusionSource): Int = when (metric) {
        MetricKind.RESTING_HR, MetricKind.HEART_RATE, MetricKind.HRV, MetricKind.SPO2 ->
            // Worn-sensor vitals: the strap measures them directly; the phone aggregates them.
            when (source) {
                FusionSource.WHOOP_IMPORT -> 0   // direct dedicated sensor (R-R / PPG)
                FusionSource.XIAOMI_BAND -> 0    // dedicated wrist PPG
                FusionSource.NOOP_COMPUTED -> 1  // derived on-device from raw strap streams
                FusionSource.APPLE_HEALTH -> 2   // phone aggregate
                FusionSource.HEALTH_CONNECT -> 2
                FusionSource.NUTRITION_CSV -> 3
                FusionSource.LOCAL_CACHE -> 3
            }

        MetricKind.SKIN_TEMP ->
            // Redundancy metric: the strap/ring measures it; the phone rarely carries it.
            when (source) {
                FusionSource.WHOOP_IMPORT -> 0
                FusionSource.XIAOMI_BAND -> 0
                FusionSource.NOOP_COMPUTED -> 1
                FusionSource.APPLE_HEALTH -> 2
                FusionSource.HEALTH_CONNECT -> 2
                FusionSource.NUTRITION_CSV -> 3
                FusionSource.LOCAL_CACHE -> 3
            }

        MetricKind.STEPS ->
            // The device that ACTUALLY COUNTS steps wins; the strap only ESTIMATES from motion.
            when (source) {
                FusionSource.XIAOMI_BAND -> 0    // wrist pedometer — counts directly
                FusionSource.APPLE_HEALTH -> 0   // phone pedometer — counts directly
                FusionSource.HEALTH_CONNECT -> 0
                FusionSource.WHOOP_IMPORT -> 3   // strap step estimate is a last resort
                FusionSource.NOOP_COMPUTED -> 3  // NOOP step estimate from motion
                FusionSource.NUTRITION_CSV -> 3
                FusionSource.LOCAL_CACHE -> 3
            }

        MetricKind.SLEEP ->
            // The best STAGER wins: imported WHOOP stages > NOOP-computed stages > phone sleep buckets.
            when (source) {
                FusionSource.WHOOP_IMPORT -> 0
                FusionSource.NOOP_COMPUTED -> 1
                FusionSource.XIAOMI_BAND -> 1    // a band with its own staging, below WHOOP's
                FusionSource.APPLE_HEALTH -> 2   // phone sleep buckets
                FusionSource.HEALTH_CONNECT -> 2
                FusionSource.NUTRITION_CSV -> 3
                FusionSource.LOCAL_CACHE -> 3
            }

        MetricKind.CALORIES ->
            // Active energy is an estimate everywhere; phone aggregate slightly over a strap estimate.
            when (source) {
                FusionSource.APPLE_HEALTH -> 2
                FusionSource.HEALTH_CONNECT -> 2
                FusionSource.WHOOP_IMPORT -> 3
                FusionSource.NOOP_COMPUTED -> 3
                FusionSource.XIAOMI_BAND -> 3
                FusionSource.NUTRITION_CSV -> 3
                FusionSource.LOCAL_CACHE -> 3
            }

        MetricKind.OTHER ->
            // Unmapped keys (nutrition/mood/passthrough): tier by source kind only.
            when (source) {
                FusionSource.WHOOP_IMPORT -> 0
                FusionSource.XIAOMI_BAND -> 0
                FusionSource.NOOP_COMPUTED -> 1
                FusionSource.APPLE_HEALTH -> 2
                FusionSource.HEALTH_CONNECT -> 2
                FusionSource.NUTRITION_CSV -> 0  // its own single-source metric
                FusionSource.LOCAL_CACHE -> 3
            }
    }

    /**
     * Stable tiebreak WITHIN a tier (lower wins). Mirrors the existing precedence baked into
     * sourceCandidates: imported WHOOP first, then NOOP-computed, then phone (Apple before Health
     * Connect, matching the #443 ordering), then a dedicated band, then single-source, then cache.
     * Used only when two sources land on the SAME tier, so the resolver stays deterministic.
     */
    fun sourcePriority(source: FusionSource): Int = when (source) {
        FusionSource.WHOOP_IMPORT -> 0
        FusionSource.NOOP_COMPUTED -> 1
        FusionSource.APPLE_HEALTH -> 2
        FusionSource.HEALTH_CONNECT -> 3
        FusionSource.XIAOMI_BAND -> 4
        FusionSource.NUTRITION_CSV -> 5
        FusionSource.LOCAL_CACHE -> 6
    }

    /**
     * The published "best signal" reason a source wins (or appears) for a metric. Plain English,
     * wellness-only — never asserts a value is true or medically valid. Drives the one-line caption on
     * the fused row.
     */
    fun reason(metric: MetricKind, source: FusionSource): String {
        if (metric == MetricKind.STEPS &&
            (source == FusionSource.XIAOMI_BAND || source == FusionSource.APPLE_HEALTH ||
                source == FusionSource.HEALTH_CONNECT)
        ) {
            return "counts directly"
        }
        if (metric == MetricKind.STEPS &&
            (source == FusionSource.WHOOP_IMPORT || source == FusionSource.NOOP_COMPUTED)
        ) {
            return "step estimate"
        }
        if (metric == MetricKind.SLEEP && source == FusionSource.WHOOP_IMPORT) return "best stager"
        if (metric == MetricKind.SLEEP && source == FusionSource.NOOP_COMPUTED) return "computed stages"
        if (metric == MetricKind.SLEEP &&
            (source == FusionSource.APPLE_HEALTH || source == FusionSource.HEALTH_CONNECT)
        ) {
            return "phone sleep buckets"
        }
        if (metric == MetricKind.SKIN_TEMP) return "worn sensor"

        return when (tier(metric, source)) {
            0 -> "direct sensor"
            1 -> "computed on device"
            2 -> "phone aggregate"
            else -> "estimate"
        }
    }

    // Cross-validation tolerances ------------------------------------------------------------------
    //
    // Per-metric hand-set bands for the agreement classifier (spec §2). A delta inside [agree] is
    // agreement; inside [minorDelta] is a plausible measurement spread (show both, no alarm); anything
    // larger is a conflict (flag, never merge). Both platforms read the SAME constants. Some metrics
    // use a percentage band (steps), most use an absolute band; [Tolerance] carries both and the
    // classifier picks per [isPercent].

    data class Tolerance(
        /** Within this delta from the winning value → agree. */
        val agree: Double,
        /** Within this delta (but beyond [agree]) → minorDelta; beyond it → conflict. */
        val minorDelta: Double,
        /** When true the deltas are FRACTIONS of the winning value (e.g. 0.10 = ±10%), else absolute. */
        val isPercent: Boolean,
    )

    /**
     * The tolerance band for a metric. Defaults (spec §2 / Open question 3): RHR ±3 bpm, asleep ±20
     * min, steps ±10%. [Tolerance.minorDelta] is the outer plausible-spread edge before a conflict.
     */
    fun tolerance(metric: MetricKind): Tolerance = when (metric) {
        MetricKind.RESTING_HR -> Tolerance(agree = 3.0, minorDelta = 8.0, isPercent = false)    // bpm
        MetricKind.HEART_RATE -> Tolerance(agree = 5.0, minorDelta = 12.0, isPercent = false)   // bpm
        MetricKind.HRV -> Tolerance(agree = 8.0, minorDelta = 20.0, isPercent = false)          // ms
        MetricKind.SPO2 -> Tolerance(agree = 2.0, minorDelta = 4.0, isPercent = false)          // %
        MetricKind.SKIN_TEMP -> Tolerance(agree = 0.5, minorDelta = 1.5, isPercent = false)     // °C
        MetricKind.STEPS -> Tolerance(agree = 0.10, minorDelta = 0.30, isPercent = true)        // ±10/30%
        MetricKind.SLEEP -> Tolerance(agree = 20.0, minorDelta = 60.0, isPercent = false)       // min
        MetricKind.CALORIES -> Tolerance(agree = 0.15, minorDelta = 0.40, isPercent = true)     // ±15/40%
        MetricKind.OTHER -> Tolerance(agree = 0.10, minorDelta = 0.30, isPercent = true)
    }

    /** Convenience: tolerance for a raw resolver key (maps via [kind]). */
    fun toleranceForKey(key: String): Tolerance = tolerance(kind(key))
}
