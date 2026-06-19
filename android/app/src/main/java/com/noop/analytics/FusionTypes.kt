package com.noop.analytics

/*
 * Fusion value types (v5 — Local Multi-Device Fusion).
 *
 * Value-for-value Kotlin twin of Packages/StrandAnalytics/.../FusionTypes.swift. The plain
 * inputs/outputs for the pure fusion engine in
 * docs/superpowers/specs/2026-06-19-v5-local-multi-device-fusion-design.md. No I/O, no model, no
 * network — the repository feeds these rows it already loads, the engine returns a resolved point.
 * Mirrors the existing DailyMetricSource / SourcedDailyMetric provenance vocabulary, generalised so a
 * future Polar/Garmin/Oura is a table entry, not a type change.
 */

/**
 * Where a fused number came from — a superset of the legacy macOS DailyMetricSource, extended to every
 * source the importers already write. [id] is the canonical source id ("my-whoop" etc.) so a
 * FusionSource round-trips to/from the stored deviceId / source string without a lookup table.
 */
enum class FusionSource(val id: String, val displayName: String) {
    /** Imported WHOOP record (CSV/zip export under the strap's deviceId, e.g. "my-whoop"). */
    WHOOP_IMPORT("my-whoop", "WHOOP"),

    /** NOOP-computed score derived on-device from raw strap streams (the "$deviceId-noop" sibling). */
    NOOP_COMPUTED("my-whoop-noop", "NOOP"),

    /** Apple Health aggregate of a declared-compatible quantity. */
    APPLE_HEALTH("apple-health", "Apple Health"),

    /** Health Connect aggregate (Android's Apple-equivalent body-metric source). */
    HEALTH_CONNECT("health-connect", "Health Connect"),

    /** Mi Band / Xiaomi import — a dedicated wrist band (counts steps directly). */
    XIAOMI_BAND("xiaomi-band", "Mi Band"),

    /** Nutrition CSV import (single-source passthrough — calories/macros). */
    NUTRITION_CSV("nutrition-csv", "Nutrition"),

    /** Locally-cached fallback row with no richer provenance. */
    LOCAL_CACHE("local-cache", "Cached"),
}

/**
 * How well a metric's value agrees across the sources that reported it on the same day. agree → quiet
 * parenthetical; minorDelta → show both, neutral; conflict → flag, never merge. Deterministic
 * threshold output (no statistics beyond a clamp + a percentage); see
 * [MetricArbitrationPolicy.tolerance].
 */
enum class AgreementState {
    /** Only one source reported the metric — nothing to cross-check, no chip shown. */
    SINGLE,

    /** Within the metric's tolerance — sources agree. */
    AGREE,

    /** Outside tolerance but inside the plausible-spread band — show both, no alarm. */
    MINOR_DELTA,

    /** Large divergence — flag prominently, keep both, never silently average. */
    CONFLICT,
}

/**
 * One source's value for a (metric, day), with the trust tier the policy assigned it. The winner is
 * the lowest [tier] (most trusted), ties broken by [sourcePriority] (stable). [reason] is the
 * published, plain-English justification ("counts directly", "best stager") — the honesty contract.
 */
data class ContributingSource(
    val source: FusionSource,
    val value: Double,
    /** Trust tier (lower = more trusted); from [MetricArbitrationPolicy.tier]. */
    val tier: Int,
    /** Stable tiebreak within a tier (lower wins); from the policy's source ordering. */
    val sourcePriority: Int,
    /** The visible "best signal" reason for this source on this metric. Never "accurate"/"correct". */
    val reason: String,
)

/**
 * The fused result for one (metric, day): the winning value, the source that supplied it, every
 * contributor (for the compare sheet), and the agreement classification. Pure data — existing
 * consumers that ignore [agreement] are unaffected.
 */
data class FusedMetricPoint(
    /** The metric key this point resolves (matches the resolver's series keys, e.g. "rhr", "steps"). */
    val metric: String,
    /** The chosen value (verbatim from [winningSource]'s row — never an average). */
    val value: Double,
    /** The source that supplied [value] (highest trust, stable tiebreak). */
    val winningSource: FusionSource,
    /** Every source that reported this metric for the day, winner first, then by tier/priority. */
    val contributors: List<ContributingSource>,
    /** Cross-validation outcome across [contributors]. */
    val agreement: AgreementState,
)

/**
 * A single source's raw input to the fusion engine: a value for a metric on a day. The repository
 * builds these from rows it already reads (it does the I/O); the engine stays pure.
 */
data class FusionInput(
    val source: FusionSource,
    val value: Double,
)
