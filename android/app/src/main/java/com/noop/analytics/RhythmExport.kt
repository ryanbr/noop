package com.noop.analytics

import java.util.Locale

/**
 * A plain-text (CSV) export of the DESCRIPTIVE rhythm-screening data for #1298: the §11
 * "share with my clinician" path. It formats the already-computed, on-device [RhythmScreener]
 * output (per-window regularity statistics + the night roll-up) so a user can hand the actual
 * timing data to a qualified professional.
 *
 * NON-CLINICAL, by construction and on purpose (read [RhythmScreener] + spec §11): it carries the
 * exact non-diagnostic disclaimer as a header on the artifact itself, and emits ONLY the neutral
 * labels the engine already produces (steady / occasionalEctopy / varied / unreadable). It names NO
 * condition, emits NO verdict, NO probability, NO "consider a clinician" call-to-action, NO alarm.
 * The judgement is the clinician's; this hands them the data, not a guess.
 *
 * A user-facing EXPORT artifact, not a stored/analytics value, but nonetheless byte-identical across
 * platforms: the numbers come from the same pure [RhythmScreener], and `num` pre-rounds so the
 * FORMATTING matches too (a user comparing an iPhone and an Android export of the same night sees the
 * same file). Pure + deterministic. Twin of Swift `RhythmExport`.
 */
object RhythmExport {

    /** The disclaimer stamped on every export, verbatim from the Rhythm screen's own copy, so a
     *  shared file can never be read as a medical assessment on its own. */
    const val disclaimer: String =
        "NOOP Rhythm export — experimental wellness visualization, NOT a diagnosis. Not an ECG and " +
            "not a medical device; it cannot detect any heart condition. Beat-to-beat variation has many " +
            "ordinary, benign causes (breathing, movement, an imperfect optical reading, or the occasional " +
            "extra or skipped beat most healthy people have). Everything was computed on your device. " +
            "Share with a qualified professional if you wish; in an emergency, contact your local emergency service."

    const val header: String =
        "window,beats,sd1_ms,sd2_ms,sd1_sd2,norm_rmssd,turning_point_rate,ectopic_fraction,label,confidence"

    /** Build the CSV text for a night: a commented disclaimer + summary block, then one row per
     *  window (1-indexed in night order; the engine's WindowResult carries no wall-clock stamp). A
     *  null statistic (an unreadable window) exports as an empty field, never a fabricated 0. */
    fun csv(summary: RhythmScreener.NightRhythmSummary, windows: List<RhythmScreener.WindowResult>): String {
        val lines = ArrayList<String>()
        for (chunk in disclaimer.split("\n")) lines.add("# $chunk")
        lines.add("#")
        lines.add(
            "# summary: readableWindows=${summary.readableWindows} steady=${summary.steadyWindows} " +
                "occasional=${summary.occasionalWindows} varied=${summary.variedWindows} " +
                "overall=${summary.overall.raw} variationRecurred=${summary.variationRecurred}",
        )
        lines.add("#")
        lines.add(header)
        windows.forEachIndexed { i, w ->
            lines.add(
                listOf(
                    (i + 1).toString(),
                    w.nBeats.toString(),
                    num(w.sd1), num(w.sd2), num(w.sd1sd2), num(w.normRmssd),
                    num(w.turningPointRate), num(w.ectopicFraction),
                    w.label.raw, w.confidence.raw,
                ).joinToString(","),
            )
        }
        return lines.joinToString("\n")
    }

    /** Format an optional statistic to 3 decimals, or "" when the window was unreadable. Pre-rounds
     *  with half-away-from-zero (Math.round, matching Swift `.rounded()` for the non-negative inputs
     *  here) BEFORE `%.3f`, so the export is byte-identical to iOS — Java's `%.3f` rounds half-up and
     *  would diverge from Swift/C's half-to-even on an exact half (e.g. 0.0625 → 0.063 vs 0.062). */
    private fun num(x: Double?): String =
        if (x == null) "" else String.format(Locale.US, "%.3f", Math.round(x * 1000).toDouble() / 1000)
}
