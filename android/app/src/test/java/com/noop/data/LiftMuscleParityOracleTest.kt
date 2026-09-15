package com.noop.data

import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins [LiftMuscle]'s stored-list codec against the Swift source of truth by ORACLE.
 *
 * The expected block is the verbatim stdout of `Packages/WhoopStore/Sources/WhoopStore/
 * LiftMuscle.swift` compiled standalone (`swiftc -O twin.swift main.swift -o oracle && ./oracle`).
 *
 * This codec is the one piece of the Lift Log that is a STORED-DATA CONTRACT: its output lands in
 * the `secondaryMuscles` column and crosses the `.noopbak` boundary to an Apple install, so a
 * divergence here is silent data corruption on restore rather than a wrong number on a screen.
 *
 * The cases are chosen where the two languages' string handling genuinely differs:
 *
 *  - Swift's `split(separator:)` omits empty subsequences by default; Kotlin's `split(",")` KEEPS
 *    them. `"chest,,biceps"`, `","`, `"chest,"` and `",chest"` all pin that the two agree anyway,
 *    because an empty token resolves to no case on either side. This was reasoned to be safe when
 *    the twin was written. Reasoning is not evidence, so it is pinned.
 *  - Decoding does NOT deduplicate: `"chest,chest"` yields two entries on both sides. Only
 *    `encodeList` strips duplicates, and pinning both halves keeps that asymmetry deliberate.
 *  - Tokens are matched exactly: `" chest"` is not trimmed and `"CHEST"` is not case-folded, so
 *    neither resolves.
 */
class LiftMuscleParityOracleTest {

    private fun s(v: String?) = v ?: "nil"
    private fun l(v: List<LiftMuscle>) = if (v.isEmpty()) "[]" else v.joinToString(",") { it.name }

    /** Verbatim stdout of the Swift build. Do not hand-edit: regenerate from the oracle. */
    private val expected = """
        == encodeList ==
        nil
        triceps,frontDelts
        triceps
        nil
        triceps,biceps
        triceps,biceps
        biceps,triceps
        chest
        == decodeList ==
        []
        []
        chest
        chest,biceps
        chest,biceps
        []
        chest
        chest
        chest,biceps
        []
        []
        chest,chest
        == roundTrip ==
        triceps,frontDelts
        triceps,frontDelts
        == credits ==
        1.000000
        0.500000
    """.trimIndent()

    private fun render(): String {
        val out = StringBuilder()
        out.appendLine("== encodeList ==")
        out.appendLine(s(LiftMuscle.encodeList(emptyList())))
        out.appendLine(s(LiftMuscle.encodeList(listOf(LiftMuscle.triceps, LiftMuscle.frontDelts))))
        out.appendLine(s(LiftMuscle.encodeList(listOf(LiftMuscle.chest, LiftMuscle.triceps), LiftMuscle.chest)))
        out.appendLine(s(LiftMuscle.encodeList(listOf(LiftMuscle.chest), LiftMuscle.chest)))
        out.appendLine(s(LiftMuscle.encodeList(listOf(LiftMuscle.triceps, LiftMuscle.triceps, LiftMuscle.biceps))))
        out.appendLine(s(LiftMuscle.encodeList(listOf(LiftMuscle.triceps, LiftMuscle.biceps), LiftMuscle.lats)))
        out.appendLine(s(LiftMuscle.encodeList(listOf(LiftMuscle.biceps, LiftMuscle.triceps))))
        out.appendLine(s(LiftMuscle.encodeList(listOf(LiftMuscle.chest, LiftMuscle.chest), null)))

        out.appendLine("== decodeList ==")
        for (stored in listOf(
            null, "", "chest", "chest,biceps", "chest,,biceps", ",", "chest,", ",chest",
            "chest,nosuchmuscle,biceps", " chest", "CHEST", "chest,chest",
        )) {
            out.appendLine(l(LiftMuscle.decodeList(stored)))
        }

        out.appendLine("== roundTrip ==")
        val rt = LiftMuscle.encodeList(
            listOf(LiftMuscle.triceps, LiftMuscle.frontDelts, LiftMuscle.triceps), LiftMuscle.chest,
        )
        out.appendLine(s(rt))
        out.appendLine(l(LiftMuscle.decodeList(rt)))

        out.appendLine("== credits ==")
        out.appendLine(String.format(Locale.ROOT, "%.6f", LiftMuscle.directSetCredit))
        out.appendLine(String.format(Locale.ROOT, "%.6f", LiftMuscle.indirectSetCredit))
        return out.toString().trimEnd()
    }

    @Test
    fun kotlinMatchesTheSwiftOracleExactly() {
        assertEquals(expected, render())
    }
}
