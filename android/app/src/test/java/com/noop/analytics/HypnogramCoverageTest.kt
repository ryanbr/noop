package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [HypnogramCoverage] — the ratio that tells a well-formed-looking stage timeline from one that
 * describes only part of the night it claims.
 *
 * BYTE-PARITY BY ORACLE, not by eye (CLAUDE.md). [swiftOracle] below is the VERBATIM stdout of the
 * Swift twin's arithmetic compiled standalone (`swiftc -O main.swift -o oracle && ./oracle`) over the
 * whole input space that matters: tiling, an interior hole, the measured 2026-08-18 night, the gate
 * boundary from both sides and exactly on it, overlap/overhang, every unmeasurable payload shape, and
 * degenerate spans. Reading the two implementations side by side would not catch a divergence in the
 * clamp, the null rules, or the boundary comparison; this does.
 *
 * Note the `gate-exact` row: 950/1000 prints as 0.94999999999999996 because that is the nearest double
 * to 0.95 — the SAME double the threshold literal denotes — so `< minCoverage` is false and the night is
 * not holed. Both platforms must agree on that, which is exactly why the row is pinned.
 */
class HypnogramCoverageTest {

    /** VERBATIM Swift stdout. Format: label|fraction (17 significant digits, or "null")|isHoled. */
    private val swiftOracle = """
        tiling|1|false
        two-seg tiling|1|false
        interior hole|0.5|true
        night-0818|0.23294509151414308|true
        gate-exact|0.94999999999999996|false
        gate-under|0.94899999999999995|true
        gate-over|0.95099999999999996|false
        overhang|1|false
        overlap|1|false
        zero-len segs|null|false
        neg-len seg|null|false
        empty-array|null|false
        blank|null|false
        nil|null|false
        not-json|null|false
        minute-dict|null|false
        zero-span|null|false
        neg-span|null|false
        mixed-nonobject|null|false
        array-with-null|null|false
        string-numbers|null|false
        bool-start|0.099|true
        timestamped-import|0.125|true
        hc-stage-min|null|false
        null-bound|null|false
    """.trimIndent()

    private fun seg(vararg r: Pair<Int, Int>): String =
        r.joinToString(",", "[", "]") { """{"start":${it.first},"end":${it.second},"stage":"deep"}""" }

    /** The same cases the Swift oracle enumerated, in the same order. */
    private val cases: List<Triple<String, String?, Double>> = listOf(
        Triple("tiling", seg(0 to 28800), 28800.0),
        Triple("two-seg tiling", seg(0 to 14400, 14400 to 28800), 28800.0),
        Triple("interior hole", seg(0 to 300, 900 to 1200), 1200.0),
        Triple("night-0818", seg(0 to 4200, 4200 to 8400), 601 * 60.0),
        Triple("gate-exact", seg(0 to 950), 1000.0),
        Triple("gate-under", seg(0 to 949), 1000.0),
        Triple("gate-over", seg(0 to 951), 1000.0),
        Triple("overhang", seg(0 to 1200), 600.0),
        Triple("overlap", seg(0 to 600, 300 to 900), 900.0),
        Triple("zero-len segs", seg(500 to 500, 600 to 600), 1000.0),
        Triple("neg-len seg", """[{"start":900,"end":300,"stage":"deep"}]""", 1000.0),
        Triple("empty-array", "[]", 1000.0),
        Triple("blank", "   ", 1000.0),
        Triple("nil", null, 1000.0),
        Triple("not-json", "not json", 1000.0),
        Triple("minute-dict", """{"light":300,"deep":100,"rem":80,"awake":40}""", 3600.0),
        Triple("zero-span", seg(0 to 300), 0.0),
        Triple("neg-span", seg(0 to 300), -1.0),
        // The four shapes on which the two readers originally DISAGREED, measured rather than read:
        // Swift's whole-array cast returns nil for a non-object element, where this side used to skip
        // it and measure the remainder (0.1, HOLED). A string start used to parse via optDouble and
        // count; Swift's `as? NSNumber` rejects it. A bool start converts on BOTH sides, because
        // JSONSerialization bridges it to NSNumber — the one case where "reject anything odd" would
        // have been the wrong alignment, and `{"start":0}` reporting `is Bool == true` under Foundation
        // is why a bool exclusion could not be used to express it.
        Triple("mixed-nonobject", """[{"start":0,"end":100,"stage":"deep"},5]""", 1000.0),
        Triple("array-with-null", """[{"start":0,"end":100,"stage":"deep"},null]""", 1000.0),
        Triple("string-numbers", """[{"start":"0","end":"100","stage":"deep"}]""", 1000.0),
        Triple("bool-start", """[{"start":true,"end":100,"stage":"deep"}]""", 1000.0),
        // A Xiaomi-shaped import: real timestamped segments that do not reach the session's own
        // bed/wake span. Unlike the timestamp-free imports this IS judged, which is the scope the
        // module doc now states outright.
        Triple("timestamped-import", seg(0 to 3600), 28800.0),
        // Health Connect's REAL shape. The oracle's `minute-dict` row is the throwing `{light,deep,...}`
        // object; HC emits an ARRAY of `{stage,min}` objects, which parses cleanly and reaches the loop.
        // It is the live producer shape this gate claims to be exempt from, so it is pinned rather than
        // argued: every element is an object (no bail), none carries bounds (every segment skipped),
        // covered stays 0, and zero cover is unmeasurable rather than bad.
        Triple("hc-stage-min", """[{"stage":"light","min":300},{"stage":"deep","min":100}]""", 3600.0),
        // A JSON null BOUND inside an otherwise well-formed object: the object itself is fine, so
        // neither side bails; both fail to read the bound and skip the segment.
        Triple("null-bound", """[{"start":null,"end":100,"stage":"deep"}]""", 1000.0),
    )

    @Test
    fun matchesTheSwiftOracleExactly() {
        val expected = swiftOracle.lines().map { it.trim() }.filter { it.isNotEmpty() }
        assertEquals("oracle row count must match the case list", cases.size, expected.size)
        for ((i, c) in cases.withIndex()) {
            val (label, json, span) = c
            val parts = expected[i].split("|")
            assertEquals("oracle row $i is for a different case", label, parts[0])

            val f = HypnogramCoverage.fraction(json, span)
            if (parts[1] == "null") {
                assertNull("$label: expected unmeasurable", f)
            } else {
                assertEquals("$label: fraction", parts[1].toDouble(), f!!, 0.0)
            }
            assertEquals("$label: isHoled", parts[2].toBoolean(),
                HypnogramCoverage.isHoled(json, span))
        }
    }

    /** nil is "not measured", never "measured badly" — the distinction every guard fails open on. */
    @Test
    fun unmeasurableIsNeverHoled() {
        for (payload in listOf(null, "", "   ", "[]", "not json",
            """{"light":300,"deep":100,"rem":80,"awake":40}""")) {
            assertNull(HypnogramCoverage.fraction(payload, 3600.0))
            assertFalse(HypnogramCoverage.isHoled(payload, 3600.0))
        }
    }

    @Test
    fun ratioOverloadMatchesSwift() {
        assertEquals(0.5, HypnogramCoverage.fraction(300.0, 600.0)!!, 0.0)
        assertEquals(1.0, HypnogramCoverage.fraction(600.0, 600.0)!!, 0.0)
        assertEquals(1.0, HypnogramCoverage.fraction(900.0, 600.0)!!, 0.0)  // clamped
        assertNull(HypnogramCoverage.fraction(300.0, 0.0))
        assertNull(HypnogramCoverage.fraction(0.0, 600.0))
    }

    /** The threshold itself is a stored cross-platform constant; a silent drift would move the gate. */
    @Test
    fun thresholdMatchesSwift() {
        assertEquals(0.95, HypnogramCoverage.minCoverage, 0.0)
    }

    /**
     * The measured night this whole change exists for (2026-08-18, Oura ring vs a paired WHOOP strap):
     * 140 minutes of segments across a 601-minute span, stored as 70 minutes of sleep where the strap
     * recorded 494.
     */
    @Test
    fun theMeasuredHoledNightIsFlagged() {
        val span = 601 * 60.0
        assertTrue(HypnogramCoverage.isHoled(seg(0 to 4200, 4200 to 8400), span))
        assertEquals(8400.0 / span, HypnogramCoverage.fraction(seg(0 to 4200, 4200 to 8400), span)!!, 1e-12)
    }

    /**
     * The ENGINE call site sums coverage off decoded segments, not off `stagesJson`, so the payload
     * shape rule that exempts timestamp-free imports at the merge does not run there. What actually
     * protects them is this: a group with no timestamped stages at all covers zero, and zero cover is
     * unmeasurable rather than bad. Holds only while a group is single-sourced — a group mixing a
     * staged fragment with a minute-dict one covers part of its total span and reads as holed.
     */
    @Test fun groupWithNoTimestampedStagesIsUnmeasurableNotHoled() {
        assertNull(HypnogramCoverage.fraction(0.0, 8 * 3600.0))
    }

    @Test fun mixedSourceGroupReadsAsHoled() {
        // 8 h fully-staged fragment + a 2 h minute-dict fragment that decodes to no segments.
        assertEquals(0.8, HypnogramCoverage.fraction(8 * 3600.0, 10 * 3600.0)!!, 1e-12)
        assertTrue(0.8 < HypnogramCoverage.minCoverage)
    }
}
