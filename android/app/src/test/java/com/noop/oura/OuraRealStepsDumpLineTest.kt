package com.noop.oura

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Tier-B real_steps research-corpus JSONL line encoder. The line is asserted verbatim so the format
 * is pinned byte-for-byte AND stays interchangeable with the Swift `OuraRealStepsDumpLine` corpus (same
 * key order, same `fields` formatting).
 */
class OuraRealStepsDumpLineTest {

    @Test
    fun encodesFixedShapeVerbatim() {
        val line = OuraRealStepsDumpLine.encode(
            deviceId = "oura-2H3B2405003655", tag = "0x7e", ringTs = 3_499_176, utc = 1_753_440_000,
            iso = "2026-07-30T09:09:01Z",
            fields = listOf(222, 470, 188, 10, 99, 62, 16, 104, 202, 436, 152, 19, 101, 113),
        )
        assertEquals(
            "{\"schema\":1,\"deviceId\":\"oura-2H3B2405003655\",\"tag\":\"0x7e\",\"ringTs\":3499176," +
                "\"utc\":1753440000,\"iso\":\"2026-07-30T09:09:01Z\"," +
                "\"fields\":[222,470,188,10,99,62,16,104,202,436,152,19,101,113]}",
            line,
        )
    }

    @Test
    fun emptyFieldsIsEmptyArray() {
        val line = OuraRealStepsDumpLine.encode("d", "0x7f", 1, 2, "x", emptyList())
        assertTrue(line.endsWith("\"fields\":[]}"))
    }
}
