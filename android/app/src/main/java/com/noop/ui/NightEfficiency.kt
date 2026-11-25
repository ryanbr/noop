package com.noop.ui

/** Display-only efficiency: session, matching day, then reconstructed stages. Swift: nightEfficiencyPct. */
internal fun nightEfficiencyPct(
    sessionEfficiency: Double?, dayEfficiency: Double?, asleep: Double, timeInBed: Double,
): Double? {
    val stored = sessionEfficiency ?: dayEfficiency
    if (stored != null) return if (stored <= 1.0) stored * 100.0 else stored
    if (timeInBed <= 0.0) return null
    return minOf(100.0, asleep / timeInBed * 100.0)
}
