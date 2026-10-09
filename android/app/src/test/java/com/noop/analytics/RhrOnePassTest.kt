package com.noop.analytics

import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Test

// Oracle: unchanged Swift SleepStager at 8e94d559, compiled with the same fixtures. Swift twin:
// RhrOnePassTests. Includes closed endpoints, unordered duplicates, gaps and custom diagnostic gates.
class RhrOnePassTest {
    private data class RhrOnePassFixture(
        val name: String, val start: Long, val end: Long, val rows: List<HrSample>,
        val minN: Int = 5, val minBpm: Double = 25.0,
    )

    private fun rhrOnePassFixtures(): List<RhrOnePassFixture> {
        val rows = (0 until 600).map { HrSample("d", 1000L + it, if (it < 300) 60 else 20) }
        return listOf(
            RhrOnePassFixture("empty", 0, 600, emptyList()),
            RhrOnePassFixture("reversed-span", 600, 0, listOf(HrSample("d", 300, 50))),
            RhrOnePassFixture("zero-span", 1000, 1000, listOf(HrSample("d", 1000, 58))),
            RhrOnePassFixture("aligned-end", 0, 300, listOf(HrSample("d", 0, 80), HrSample("d", 300, 40))),
            RhrOnePassFixture("next-aligned-end", 0, 600, listOf(HrSample("d", 0, 80), HrSample("d", 300, 60), HrSample("d", 600, 20))),
            RhrOnePassFixture("negative-times", -600, 0, listOf(HrSample("d", -601, 0), HrSample("d", -600, 80), HrSample("d", -300, 60), HrSample("d", 0, 20), HrSample("d", 1, 0))),
            RhrOnePassFixture("implausible", 1000, 1600, rows),
            RhrOnePassFixture("unsorted-duplicates", 1000, 1600, rows.reversed() + listOf(HrSample("d", 1000, 60), HrSample("d", 1600, 20))),
            RhrOnePassFixture("thin", 1000, 1900, rows.filter { it.ts < 1300 } + listOf(HrSample("d", 1800, 30))),
            RhrOnePassFixture("custom-gate", 0, 600, (0 until 7).map { HrSample("d", it.toLong(), 30) } + (0 until 8).map { HrSample("d", 300L + it, 60) }, 8, 35.0),
            RhrOnePassFixture("round-half", 0, 301, listOf(HrSample("d", 0, 60), HrSample("d", 300, 60), HrSample("d", 301, 61))),
            RhrOnePassFixture("tie-count", 0, 900, listOf(HrSample("d", 0, 30), HrSample("d", 300, 30), HrSample("d", 301, 30)) + (0 until 5).map { HrSample("d", 600L + it, 60) }),
        )
    }

    @Test fun floorsAndDiagnosticsMatchOriginalSwiftOracle() {
        val actual = rhrOnePassFixtures().joinToString("\n") { f ->
            val floor = SleepStager.sessionRestingHR(f.start, f.end, f.rows)
            val line = SleepStager.rhrBinGateLogLine("synthetic", listOf(f.start to f.end), f.rows,
                floor ?: 0, f.minN, f.minBpm)
            "${f.name}|${floor ?: "nil"}|${line ?: "nil"}"
        }
        // Pasted verbatim from compiled, unchanged Swift production stdout.
        val expected = """
            empty|nil|nil
            reversed-span|nil|nil
            zero-span|58|nil
            aligned-end|60|nil
            next-aligned-end|40|nil
            negative-times|40|nil
            implausible|60|rhr bins day=synthetic bins=2 thin=0 implausible=1 winnerN=300 ungated=20 gated=60 shipped=60 gateMoved=true
            unsorted-duplicates|60|rhr bins day=synthetic bins=2 thin=0 implausible=1 winnerN=301 ungated=20 gated=60 shipped=60 gateMoved=true
            thin|60|rhr bins day=synthetic bins=2 thin=1 implausible=0 winnerN=1 ungated=30 gated=60 shipped=60 gateMoved=true
            custom-gate|30|nil
            round-half|60|nil
            tie-count|60|rhr bins day=synthetic bins=3 thin=2 implausible=0 winnerN=1 ungated=30 gated=60 shipped=60 gateMoved=true
        """.trimIndent()
        assertEquals(expected, actual)
    }

    private fun rhrOnePassSweepRow(i: Int): String {
        val spans = listOf(-1L, 0L, 1L, 299L, 300L, 301L, 599L, 600L, 601L, 899L, 900L, 1201L)
        val start = (i % 3 - 1) * 1000L
        val end = start + spans[i % spans.size]
        var rows = (0 until i % 83).map { j ->
            HrSample("d", start + ((j * 137 + i * 17) % 1800) - 300, (j * 31 + i * 7) % 121)
        } + listOf(HrSample("d", start, 60), HrSample("d", end, 20), HrSample("d", end, 20))
        if (i % 2 == 0) rows = rows.reversed()
        val floor = SleepStager.sessionRestingHR(start, end, rows)
        val line = SleepStager.rhrBinGateLogLine("synthetic", listOf(start to end, start + 300 to end + 300),
            rows, floor ?: 0, 1 + i % 9, (20 + i % 20).toDouble())
        return "$i|${floor ?: "nil"}|${line ?: "nil"}\n"
    }

    @Test fun unorderedDuplicateAndOverlappingSessionSweepMatchesOriginalSwiftDigest() {
        var digest = 2166136261L.toInt()
        for (i in 0 until 768) {
            for (byte in rhrOnePassSweepRow(i).toByteArray(Charsets.UTF_8)) {
                digest = (digest xor byte.toInt()) * 16777619
            }
        }
        assertEquals("sweep768|a9770363", "sweep768|${digest.toUInt().toString(16).padStart(8, '0')}")
    }

    @Test fun sparseLongSpanKeepsOnlyOccupiedBinsAndClosesItsEndpoint() {
        val end = 30L * 365 * 86400
        val rows = listOf(HrSample("d", end, 40), HrSample("d", 0, 80),
            HrSample("d", end - 1, 60), HrSample("d", end + 1, 1))
        val bins = SleepStager.restingHRBins(0, end, rows)
        assertEquals(listOf(80, 100), bins.map { it.first })
        assertEquals(listOf(1, 2), bins.map { it.second })
        assertEquals(50, SleepStager.sessionRestingHR(0, end, rows))
    }
}
