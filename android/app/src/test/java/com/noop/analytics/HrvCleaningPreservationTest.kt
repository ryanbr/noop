package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Test

class HrvCleaningPreservationTest {
    // Verbatim original Swift stdout at 8e94d559: Double bits and removed-beat adjacency.
    private val originalOracle = """
0|0|cbf29ce484222325|cbf29ce484222325|cbf29ce484222325
1|0|cbf29ce484222325|cbf29ce484222325|cbf29ce484222325
2|1|2568834c8601b7df|2568834c8601b7df|af63bd4c8601b7df
3|2|205d8607b4eb6fed|205d8607b4eb6fed|8328707b4eb6e3a
4|3|75289a186c0f2fb7|75289a186c0f2fb7|d949ad186c0c4e41
5|4|2fe1767f9dce13f5|2fe1767f9dce13f5|447f607f98e8f6c0
6|5|1d42a1d9252be94f|1d42a1d9252be94f|4d67b9d0d3db49f3
7|6|8cf0b8fa299d713d|8cf0b8fa299d713d|628aafd7fd9ea636
8|7|1016fa14b6876aa7|1016fa14b6876aa7|104f0303f4946f75
9|3|34c79a186c0f2fb7|34c79a186c0f2fb7|d949ad186c0c4e41
10|1|2532234c8601b7df|2532234c8601b7df|af63bd4c8601b7df
11|7|585f1a14b6876aa7|585f1a14b6876aa7|104f0303f4946f75
12|3|30cc12186c0f2fb7|30cc12186c0f2fb7|d94d12186c0f2fb7
13|4|c532367f9dce13f5|c532367f9dce13f5|4d25757f9dce1242
14|300|ada53892fe7f4315|ada53892fe7f4315|ca507bed0f106018
15|284|53f2a91c3fc4d5d5|53f2a91c3fc4d5d5|ea13e2a443f8348a
16|36000|39399142eeffafa5|39399142eeffafa5|66887b7d4316484
17|34097|b9d60d46a4931f|b9d60d46a4931f|e1011fbbd685b430
18|108000|4529d5bc622088a5|4529d5bc622088a5|275d0339a0103744
19|102293|d16cc7e6a7b2c70f|d16cc7e6a7b2c70f|f9ef4947521f3074
""".trimIndent()

    private fun cleaningOracleHash(words: List<ULong>): String {
        var hash = 14695981039346656037uL
        for (word in words) hash = (hash xor word) * 1099511628211uL
        return hash.toString(16)
    }

    private fun cleaningOracleInput(count: Int, mixed: Boolean): List<Double> = (0 until count).map { i ->
        when {
            mixed && i % 31 == 0 -> 50.0
            mixed && i % 47 == 0 -> 1500.0
            else -> 800.0 + ((i * 17) % 101).toDouble() / 4.0
        }
    }

    private fun cleaningOracleFixtures(): List<List<Double>> {
        val fixtures = (0..8).map { cleaningOracleInput(it, true) }.toMutableList()
        fixtures += listOf(
            listOf(Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY, 800.0, 801.0, 802.0),
            listOf(300.0, 299.0, 800.25, 1500.0, 801.5, 2000.0, 2001.0),
            listOf(800.0, 960.0, 800.0, 960.0, 800.0, 960.0, 800.0),
            listOf(800.0, 960.0000000000001, 800.0, 960.0000000000001, 800.0),
            listOf(2000.0, 2000.0, 1600.0, 1600.0, 300.0, 300.0, 300.0),
        )
        for (count in listOf(300, 36000, 108000)) {
            fixtures.add(cleaningOracleInput(count, false))
            fixtures.add(cleaningOracleInput(count, true))
        }
        return fixtures
    }

    @Test
    fun cleanRRPreservesOriginalBits() {
        val expected = originalOracle.lines().map { it.split("|") }
        val fixtures = cleaningOracleFixtures()
        assertEquals(expected.size, fixtures.size)
        for ((index, input) in fixtures.withIndex()) {
            val before = input.map { it.toRawBits() }
            val clean = HrvAnalyzer.cleanRR(input)
            assertEquals("case $index", expected[index][1], clean.size.toString())
            assertEquals("case $index", expected[index][2], cleaningOracleHash(clean.map { it.toRawBits().toULong() }))
            assertEquals(before, input.map { it.toRawBits() })
        }
    }

    @Test
    fun gapAwareCleaningPreservesOriginalBitsAndAdjacency() {
        val expected = originalOracle.lines().map { it.split("|") }
        val fixtures = cleaningOracleFixtures()
        assertEquals(expected.size, fixtures.size)
        for ((index, input) in fixtures.withIndex()) {
            val before = input.map { it.toRawBits() }
            val clean = HrvAnalyzer.cleanRRGapAware(input)
            assertEquals("case $index", expected[index][1], clean.nn.size.toString())
            assertEquals("case $index", expected[index][3], cleaningOracleHash(clean.nn.map { it.toRawBits().toULong() }))
            assertEquals("case $index", expected[index][4], cleaningOracleHash(clean.contiguous.map { if (it) 1uL else 0uL }))
            assertEquals(before, input.map { it.toRawBits() })
        }
    }
}
