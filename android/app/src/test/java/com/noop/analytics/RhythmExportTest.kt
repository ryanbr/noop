package com.noop.analytics

import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the #1298 clinician-share export: a disclaimer-stamped, non-diagnostic CSV of the
 * descriptive [RhythmScreener] output. Swift twin: `RhythmExportTests`.
 */
class RhythmExportTest {

    private val summary = RhythmScreener.NightRhythmSummary(
        readableWindows = 2, steadyWindows = 1, occasionalWindows = 1, variedWindows = 0,
        variationRecurred = false, overall = RhythmRegularity.OCCASIONAL_ECTOPY,
    )
    private val steady = RhythmScreener.WindowResult(
        label = RhythmRegularity.STEADY, sd1 = 24.5, sd2 = 60.0, sd1sd2 = 0.408,
        normRmssd = 0.031, turningPointRate = 0.62, ectopicFraction = 0.0,
        nBeats = 72, confidence = RhythmConfidence.SOLID, agreedAcrossSources = true, poincare = emptyList(),
    )
    private val occasional = RhythmScreener.WindowResult(
        label = RhythmRegularity.OCCASIONAL_ECTOPY, sd1 = 40.0, sd2 = 70.0, sd1sd2 = 0.571,
        normRmssd = 0.05, turningPointRate = 0.8, ectopicFraction = 0.03,
        nBeats = 66, confidence = RhythmConfidence.BUILDING, agreedAcrossSources = false, poincare = emptyList(),
    )

    @Test
    fun csvCarriesDisclaimerSummaryAndPerWindowRows() {
        val csv = RhythmExport.csv(summary, listOf(steady, occasional, RhythmScreener.WindowResult.unreadable(10)))
        val lines = csv.split("\n")

        // The disclaimer is on the ARTIFACT, and it is explicitly non-diagnostic.
        assertTrue(lines[0].startsWith("# NOOP Rhythm export"))
        assertTrue(csv.contains("NOT a diagnosis"))
        assertTrue(
            csv.contains(
                "# summary: readableWindows=2 steady=1 occasional=1 varied=0 " +
                    "overall=occasionalEctopy variationRecurred=false",
            ),
        )
        assertTrue(csv.contains(RhythmExport.header))
        // Per-window rows: 1-indexed, neutral engine label + confidence, 3-decimal stats.
        assertTrue(csv.contains("1,72,24.500,60.000,0.408,0.031,0.620,0.000,steady,solid"))
        assertTrue(csv.contains("2,66,40.000,70.000,0.571,0.050,0.800,0.030,occasionalEctopy,building"))
        // An unreadable window exports EMPTY stat fields, never fabricated zeros.
        assertTrue(csv.contains("3,10,,,,,,,unreadable,calibrating"))
    }

    @Test
    fun formattingPreRoundsSoTheExportCannotDivergeByDevice() {
        // A stat sitting exactly on a 3-decimal half (0.0625) must format identically to iOS. Java's
        // %.3f rounds half-up (0.063), Swift/C's half-even (0.062); num() pre-rounds so BOTH land on
        // 0.063. Pins that the same night can't export differently on Android vs iPhone.
        val csv = RhythmExport.csv(summary, listOf(steady.copy(sd1 = 0.0625)))
        assertTrue(csv.contains(",0.063,"))
    }

    @Test
    fun exportNamesNoConditionAndCarriesNoVerdict() {
        // The whole point of #1298: hand over the data, never a diagnosis. Guard that no condition
        // name or clinical call-to-action can leak into the artifact.
        val csv = RhythmExport.csv(summary, listOf(steady, occasional)).lowercase()
        for (banned in listOf("mobitz", "afib", "atrial fibrillation", "arrhythmia", "block", "consider a clinician", "see a doctor")) {
            assertTrue("export must not contain \"$banned\"", !csv.contains(banned))
        }
    }
}
