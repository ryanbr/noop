package com.noop.analytics

import com.noop.data.LiftMuscle
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins [LiftMetrics] against the Swift source of truth by ORACLE, not by eye.
 *
 * The expected block below is the verbatim stdout of the Swift implementation compiled standalone
 * (`swiftc -O twin.swift main.swift -o oracle && ./oracle`) from
 * `Packages/StrandAnalytics/Sources/StrandAnalytics/LiftMetrics.swift`. Reading the two files side
 * by side does not catch what this does: the cases below were chosen for the edges where a port
 * silently diverges.
 *
 *  - Bench ranks a 1RM TIE between 90x10 and 120x1, both estimating 120.0. Swift's `max(by:)` keeps
 *    the FIRST of equals and Kotlin's `maxWithOrNull` does the same; a port using `maxByOrNull` on
 *    the estimate would return the last and report 120 kg x 1 instead of 90 kg x 10.
 *  - Row has no set under the rep ceiling, so the comparator must fall through to raw weight while
 *    still preferring any set that DOES support an estimate.
 *  - Curl has one set with no weight and one with no reps, so the fallback compares 0.0 against 20.
 *  - Set 2 lists `chest` as both primary and secondary; it must be counted once.
 *  - Set 4 is 13 reps, one past the ceiling, so it estimates nil rather than a number.
 *  - Sets 8 and 10 have ZERO reps, which is how a discarded set is saved: not performed, so they
 *    count nowhere. Set 10 carries muscles and an RPE, so a port that skips `isPerformed` in
 *    `muscleCounts` or `rpeProfile` shows up as an extra chest set or rating, not just a missing row.
 *  - Dip lists `triceps` three times and the primary `chest` once. Swift's `LiftSetRow.init`
 *    normalises a row's secondaries at construction, so `LiftMetrics` never sees a repeat;
 *    `LiftMetrics.Row` has to carry the same invariant or the muscle is counted once per
 *    mention. Unnormalised, this row credited triceps 1.0 across two indirect sets where
 *    Swift credits 0.5 across one. The `normalisedSecondaries` block pins the list itself,
 *    not just the totals it feeds, so a regression names the cause rather than a stray sum.
 *
 * The oracle only guards this direction. `LiftMetricsTests` on the Swift side is what stops Swift
 * drifting away from Kotlin.
 */
class LiftMetricsParityOracleTest {

    private fun row(
        ord: Int, ex: String, w: Double?, r: Int?, rpe: Double?, warm: Boolean,
        p: LiftMuscle?, sec: List<LiftMuscle>,
    ) = LiftMetrics.Row(
        ord = ord, exercise = ex, isWarmup = warm, weightKg = w, reps = r, rpe = rpe,
        primaryMuscle = p, secondaryMuscles = sec,
    )

    private val sets = listOf(
        row(0, "Bench", 60.0, 12, 7.0, true, LiftMuscle.chest, listOf(LiftMuscle.triceps, LiftMuscle.frontDelts)),
        row(1, "Bench", 100.0, 5, 8.0, false, LiftMuscle.chest, listOf(LiftMuscle.triceps, LiftMuscle.frontDelts)),
        row(2, "Bench", 90.0, 10, 9.5, false, LiftMuscle.chest, listOf(LiftMuscle.triceps, LiftMuscle.chest)),
        row(3, "Bench", 120.0, 1, null, false, LiftMuscle.chest, emptyList()),
        row(4, "Row", 80.0, 13, 6.0, false, LiftMuscle.lats, listOf(LiftMuscle.biceps)),
        row(5, "Row", 70.0, 8, null, false, LiftMuscle.lats, listOf(LiftMuscle.biceps)),
        row(6, "Curl", null, 10, 8.0, false, LiftMuscle.biceps, emptyList()),
        row(7, "Curl", 20.0, null, 8.0, false, LiftMuscle.biceps, emptyList()),
        row(8, "Plank", 0.0, 0, null, false, null, emptyList()),
        row(9, "Dip", 50.0, 6, 8.5, false, LiftMuscle.chest,
            listOf(LiftMuscle.triceps, LiftMuscle.triceps, LiftMuscle.chest,
                LiftMuscle.frontDelts, LiftMuscle.triceps)),
        row(10, "Bench", 100.0, 0, 9.0, false, LiftMuscle.chest, listOf(LiftMuscle.triceps)),
    )

    private fun f(d: Double?) = if (d == null) "nil" else String.format(Locale.ROOT, "%.6f", d)
    private fun i(v: Int?) = v?.toString() ?: "nil"

    /** Verbatim stdout of the Swift build. Do not hand-edit: regenerate from the oracle. */
    private val expected = """
        == volumeLoadKg ==
        3420.000000
        nil
        nil
        == sessionLoad ==
        480.000000
        nil
        nil
        9.000000
        nil
        == estimatedOneRepMaxKg ==
        100.000000
        116.666667
        120.000000
        112.000000
        nil
        nil
        nil
        nil
        nil
        == isPerformed ==
        false
        true
        true
        9
        == normalisedSecondaries ==
        0|triceps,frontDelts
        1|triceps,frontDelts
        2|triceps
        3|[]
        4|biceps
        5|biceps
        6|[]
        7|[]
        8|[]
        9|triceps,frontDelts
        10|triceps
        == perExercise ==
        Bench|3|1|1520.000000|90.000000|10|120.000000
        Row|2|0|1600.000000|70.000000|8|88.666667
        Curl|2|0|nil|20.000000|nil|nil
        Dip|1|0|300.000000|50.000000|6|60.000000
        == rpeProfile ==
        8.000000|6|2|5|8.000000
        8.000000|6|2|5|7.000000
        nil|0|0|0|8.000000
        == muscleCounts ==
        chest|4.000000|4|nil
        frontDelts|1.000000|nil|2
        triceps|1.500000|nil|3
        lats|2.000000|2|nil
        biceps|3.000000|2|2
        == constants ==
        12
        8.000000
        4.000000
        1.000000
        4.000000
    """.trimIndent()

    private fun render(): String {
        val out = StringBuilder()
        out.appendLine("== volumeLoadKg ==")
        out.appendLine(f(LiftMetrics.volumeLoadKg(sets)))
        out.appendLine(f(LiftMetrics.volumeLoadKg(emptyList())))
        out.appendLine(f(LiftMetrics.volumeLoadKg(listOf(sets[0]))))

        out.appendLine("== sessionLoad ==")
        for ((r, d) in listOf(8.0 to 3600, 0.0 to 3600, 7.5 to 0, 6.0 to 90)) {
            out.appendLine(f(LiftMetrics.sessionLoad(r, d)))
        }
        out.appendLine(f(LiftMetrics.sessionLoad(null, 3600)))

        out.appendLine("== estimatedOneRepMaxKg ==")
        for ((w, r) in listOf(
            100.0 to 1, 100.0 to 5, 90.0 to 10, 80.0 to 12, 80.0 to 13, 0.0 to 5, 100.0 to 0,
        )) {
            out.appendLine(f(LiftMetrics.estimatedOneRepMaxKg(w, r)))
        }
        out.appendLine(f(LiftMetrics.estimatedOneRepMaxKg(null, 5)))
        out.appendLine(f(LiftMetrics.estimatedOneRepMaxKg(100.0, null)))

        out.appendLine("== isPerformed ==")
        for (r in listOf(0, null, 5)) {
            out.appendLine(LiftMetrics.isPerformed(r).toString())
        }
        out.appendLine(sets.count { LiftMetrics.isPerformed(it.reps) }.toString())

        out.appendLine("== normalisedSecondaries ==")
        for (s in sets) {
            val sec = s.secondaryMuscles
            out.appendLine("${s.ord}|" + if (sec.isEmpty()) "[]" else sec.joinToString(",") { it.name })
        }

        out.appendLine("== perExercise ==")
        for (s in LiftMetrics.perExercise(sets)) {
            out.appendLine(
                "${s.exercise}|${s.workingSets}|${s.warmupSets}|${f(s.volumeKg)}|" +
                    "${f(s.bestWeightKg)}|${i(s.bestReps)}|${f(s.bestEstimatedOneRepMaxKg)}"
            )
        }

        out.appendLine("== rpeProfile ==")
        for (p in listOf(
            LiftMetrics.rpeProfile(sets),
            LiftMetrics.rpeProfile(sets, 7.0),
            LiftMetrics.rpeProfile(emptyList()),
        )) {
            out.appendLine(
                "${f(p.mean)}|${p.ratedSets}|${p.unratedSets}|${p.setsAtOrAboveThreshold}|${f(p.threshold)}"
            )
        }

        out.appendLine("== muscleCounts ==")
        val mc = LiftMetrics.muscleCounts(sets)
        for (m in LiftMuscle.entries) {
            val fr = mc.fractional[m]
            val di = mc.direct[m]
            val ind = mc.indirect[m]
            if (fr == null && di == null && ind == null) continue
            out.appendLine("${m.name}|${f(fr)}|${i(di)}|${i(ind)}")
        }

        out.appendLine("== constants ==")
        out.appendLine(LiftMetrics.oneRepMaxRepCeiling.toString())
        out.appendLine(f(LiftMetrics.hardSetRpeThreshold))
        out.appendLine(f(LiftMetrics.ReferenceDose.hypertrophyMinimumSetsPerWeek))
        out.appendLine(f(LiftMetrics.ReferenceDose.strengthMinimumSetsPerWeek))
        out.appendLine(f(LiftMetrics.ReferenceDose.strengthPlateauSetsPerWeek))
        return out.toString().trimEnd()
    }

    @Test
    fun kotlinMatchesTheSwiftOracleExactly() {
        assertEquals(expected, render())
    }
}
