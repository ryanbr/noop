package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Test

class PhysiologicalStepsClassificationTest {
    // Verbatim stdout from swiftc -O over the production Swift classifier and SleepStageTotals.
    @Test fun classificationMatchesSwiftOracle() {
        assertEquals("""
            -18000:NNNNNNNNNNNNNNNNNNNNNCNCNCNCNCNCNNNNNNNNNNNNNCCCCCCCCCCCCCCCCCCCCCCCNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN
            0:NNNNNNNNNNNNNNNNNNNNNCNCNCNCNCNCNNNNNNNNNNNNNCCCCCCCCCCCCCCCCCCCCCCCNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN
            46800:NNNNNNNNNNNNNNNNNNNNNCNCNCNCNCNCNNNNNNNNNNNNNCCCCCCCCCCCCCCCCCCCCCCCNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN
            early1945:M:1799100
            early1900:M:1796400
            overnight:M:1807200
            shift:M:1771200
            short:N:-
            floor:M:1796400
            nap:N:-
            explicit:M:1771200
            edited:M:1796400
            bridge:MM:1796400
        """.trimIndent(), classificationOracle())
    }

    @Test fun consecutiveEarlyBedtimesCreateDailyBoundaries() {
        val boundaries = (20L..22L).flatMap { day ->
            val onset = day * 86_400 + 19 * 3_600
            PhysiologicalSteps.classifyForCycle(
                listOf(PhysiologicalSteps.SleepBlock(onset, onset + 8 * 3_600, id = day.toString())),
                0, null,
            ).filter { it.kind == PhysiologicalSteps.SleepKind.MAIN_SLEEP }
                .map { PhysiologicalSteps.CycleBoundary(it.id, it.effectiveOnset) }
        }
        val windows = PhysiologicalSteps.cycleWindows(boundaries, now = 23 * 86_400L + 19 * 3_600)
        assertEquals(3, windows.size)
        assertEquals(listOf(86_400L, 86_400L, 86_400L), windows.map { it.endExclusive - it.onset })
    }

    private fun classificationOracle(): String {
        val lines = mutableListOf<String>()
        val base = 20 * 86_400L
        for (offset in listOf(-18_000L, 0L, 46_800L)) {
            val signature = StringBuilder()
            for (minute in 0 until 1_440 step 15) {
                val blocks = listOf(
                    PhysiologicalSteps.SleepBlock(base + 3_600 - offset, base + 5 * 3_600 - offset, id = "N"),
                    PhysiologicalSteps.SleepBlock(base + minute * 60 - offset,
                        base + minute * 60 + 3 * 3_600 - offset, id = "C"),
                )
                val result = PhysiologicalSteps.classifyForCycle(blocks, offset, 14 * 3_600L)
                signature.append(result.filter { it.kind == PhysiologicalSteps.SleepKind.MAIN_SLEEP }
                    .joinToString("") { it.id })
            }
            lines.add("$offset:$signature")
        }
        val cases = listOf(
            Triple("early1945", listOf(PhysiologicalSteps.SleepBlock(base + 19 * 3_600 + 45 * 60,
                base + 28 * 3_600 + 15 * 60)), null),
            Triple("early1900", listOf(PhysiologicalSteps.SleepBlock(base + 19 * 3_600,
                base + 27 * 3_600 + 45 * 60)), null),
            Triple("overnight", listOf(PhysiologicalSteps.SleepBlock(base + 22 * 3_600,
                base + 30 * 3_600)), null),
            Triple("shift", listOf(PhysiologicalSteps.SleepBlock(base + 12 * 3_600,
                base + 20 * 3_600)), 16 * 3_600L),
            Triple("short", listOf(PhysiologicalSteps.SleepBlock(base + 19 * 3_600,
                base + 22 * 3_600 - 1)), null),
            Triple("floor", listOf(PhysiologicalSteps.SleepBlock(base + 19 * 3_600,
                base + 22 * 3_600)), null),
            Triple("nap", listOf(PhysiologicalSteps.SleepBlock(base + 19 * 3_600,
                base + 28 * 3_600, kind = PhysiologicalSteps.SleepKind.NAP)), null),
            Triple("explicit", listOf(PhysiologicalSteps.SleepBlock(base + 12 * 3_600,
                base + 13 * 3_600, kind = PhysiologicalSteps.SleepKind.MAIN_SLEEP)), null),
            Triple("edited", listOf(PhysiologicalSteps.SleepBlock(base + 20 * 3_600,
                base + 28 * 3_600, editedOnset = base + 19 * 3_600)), null),
            Triple("bridge", listOf(PhysiologicalSteps.SleepBlock(base + 19 * 3_600, base + 21 * 3_600),
                PhysiologicalSteps.SleepBlock(base + 21 * 3_600 + 30 * 60, base + 23 * 3_600)), null),
        )
        for ((name, blocks, habitual) in cases) {
            val result = PhysiologicalSteps.classifyForCycle(blocks, 0, habitual)
            val kinds = result.joinToString("") { if (it.kind == PhysiologicalSteps.SleepKind.MAIN_SLEEP) "M" else "N" }
            val onset = result.filter { it.kind == PhysiologicalSteps.SleepKind.MAIN_SLEEP }
                .minOfOrNull { it.effectiveOnset }
            lines.add("$name:$kinds:${onset ?: "-"}")
        }
        return lines.joinToString("\n")
    }
}
