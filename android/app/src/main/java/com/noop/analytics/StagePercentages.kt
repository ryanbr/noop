package com.noop.analytics

import kotlin.math.floor

/**
 * Largest-remainder ("Hamilton") apportionment of parts into whole percentages.
 *
 * Rounding each part's share of the whole on its own — `round(part / total * 100)` — does NOT preserve
 * the sum: four stages of one night land on 99 or 101 as often as 100, and two views that each round
 * independently can disagree on the same part. This apportions ONCE: floor every share, then hand the
 * leftover whole-percent units to the parts with the largest fractional remainders, so the results sum
 * to exactly 100. Every call site reads the one result, so they agree with each other and add up.
 *
 * Swift twin: `StrandAnalytics.StagePercentages.wholePercentages` — byte-identical, including the
 * leftover tie-break (larger remainder first, then lower index), so both platforms return the same ints.
 */
object StagePercentages {

    /**
     * [parts] are raw non-negative magnitudes (e.g. stage minutes) in a FIXED order; the returned whole
     * percentages line up with them and sum to exactly 100. Returns null when the total is <= 0 — there is
     * nothing to apportion, and the caller should show no share rather than a `0%` it never measured.
     */
    fun wholePercentages(parts: List<Double>): List<Int>? {
        val clamped = parts.map { maxOf(0.0, it) }
        val total = clamped.sum()
        if (total <= 0.0) return null

        val raw = clamped.map { it / total * 100.0 }
        val whole = raw.map { floor(it).toInt() }.toIntArray()
        var remaining = 100 - whole.sum()   // the fractional units the floors dropped; in 0..<count
        if (remaining <= 0) return whole.toList()

        // Largest fractional remainder first; ties broken by lower index so the twin can match exactly.
        val order = raw.indices.sortedWith(
            compareByDescending<Int> { raw[it] - whole[it] }.thenBy { it },
        )
        var k = 0
        while (remaining > 0 && k < order.size) {
            whole[order[k]]++
            remaining--
            k++
        }
        return whole.toList()
    }
}
