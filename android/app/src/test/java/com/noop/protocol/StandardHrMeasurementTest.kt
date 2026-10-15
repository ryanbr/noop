package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

class StandardHrMeasurementTest {
    @Test fun completeFieldVerdictMatchesSwiftOracleForEveryFlagAndLength() {
        // Verbatim production Swift stdout, independently checked against the SIG layout table.
        val oracle = """
            00|00111111111111111111111111111111111111111111111111111111111111111
            01|00011111111111111111111111111111111111111111111111111111111111111
            08|00001111111111111111111111111111111111111111111111111111111111111
            09|00000111111111111111111111111111111111111111111111111111111111111
            10|00101010101010101010101010101010101010101010101010101010101010101
            11|00010101010101010101010101010101010101010101010101010101010101010
            18|00001010101010101010101010101010101010101010101010101010101010101
            19|00000101010101010101010101010101010101010101010101010101010101010
        """.trimIndent()
        val masks = oracle.lines().associate { row ->
            val columns = row.split("|")
            assertEquals(65, columns.last().length)
            columns.first().toInt(16) to columns.last()
        }
        for (flags in 0..255) {
            val bits = masks.getValue(flags and 0x19)
            bits.forEachIndexed { length, bit ->
                val bytes = ByteArray(length)
                if (bytes.isNotEmpty()) bytes[0] = flags.toByte()
                assertEquals("flags=$flags, length=$length", bit == '1',
                    StandardHrMeasurement.hasCompleteFields(bytes))
            }
        }
    }
}
