package com.noop.data

/**
 * Honest live-BLE capability set for a WHOOP strap that NOOP can actually drive **without** a CSV /
 * Health Connect import.
 *
 * Calibrated SpO₂ **%** is deliberately **excluded**: AnalyticsEngine nulls `spo2Pct` for every WHOOP
 * live path (see [com.noop.analytics.Spo2ReTrace] — fabricating a % from raw ADC needs WHOOP's
 * proprietary curve). The registry used to advertise `spo2` on every paired WHOOP, which made an empty
 * Blood Oxygen tile look like a bug rather than import-only design (#548).
 *
 * Steps are 5.0 / MG only over BLE. Twin of Swift `WhoopLiveCapabilities`. Pure — unit-tested.
 */
object WhoopLiveCapabilities {

    /** Core metrics every WHOOP generation can feed in NOOP over BLE (no calibrated SpO₂ %). */
    val base: Set<Metric> = setOf(
        Metric.hr, Metric.hrv, Metric.skinTemp, Metric.sleep, Metric.strainLoad,
    )

    /** True when the model label names a 5.0 or MG (wizard labels: "4.0", "5.0 MG", …). */
    fun isFiveOrMG(model: String): Boolean {
        val m = model.lowercase()
        return m.contains("5") || m.contains("mg")
    }

    /** Capability set for a freshly paired WHOOP with the given model label. */
    fun metrics(forModel: String): Set<Metric> {
        val caps = base.toMutableSet()
        if (isFiveOrMG(forModel)) caps.add(Metric.steps)
        return caps
    }

    /** Comma-joined, sorted encoding used in `pairedDevice.capabilities`. */
    fun encoded(forModel: String): String =
        metrics(forModel).map { it.name }.sorted().joinToString(",")

    /** Drop calibrated SpO₂ from a stored set — when reading old registry rows that still list it. */
    fun withoutCalibratedSpo2(caps: Set<Metric>): Set<Metric> = caps - Metric.spo2

    /** Remove bare `spo2` tokens from a comma-joined capabilities string. */
    fun stripSpo2Token(fromEncoded: String): String =
        fromEncoded.split(',')
            .map { it.trim() }
            .filter { it.isNotEmpty() && it != Metric.spo2.name }
            .joinToString(",")
}
