package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Byte-identical parity oracle for [gattTreeLines] against `GattCapability.treeLines`.
 *
 * The expected block is the verbatim stdout of the compiled Swift twin over the same four cases, not a
 * reading of it. That is the only form of "byte-identical" worth asserting — and it is why the Swift
 * helper takes a raw property bitmask and does not import CoreBluetooth: a twin that cannot be compiled
 * on Linux cannot be an oracle, and the check degrades to two people agreeing they look similar.
 */
class GattTreeParityTest {
    @Test
    fun `all four renderings match the Swift twin exactly`() {
        val cases: List<List<Pair<String, List<Pair<String, Int>>>>> = listOf(
            emptyList(),
            listOf(
                "fd4b0001" to listOf("fd4b0002" to 0xc, "fd4b0003" to 0x10),
                "0000180a" to listOf("00002a26" to 0x2),
            ),
            listOf("svc" to listOf("ch" to 0)),
            listOf("s" to listOf("a" to 0xff)),
        )
        val out = buildString {
            for (c in cases) {
                gattTreeLines(c).forEach { append(it).append('\n') }
                append("--\n")
            }
        }
        assertEquals(SWIFT.trimStart('\n'), out)
    }

    private companion object {
        const val SWIFT = """
GATT tree: no services discovered
--
GATT tree: 2 service(s)
  service fd4b0001 (2 char)
    fd4b0002 props=0xc (WriteNoResponse+Write)
    fd4b0003 props=0x10 (Notify)
  service 0000180a (1 char)
    00002a26 props=0x2 (Read)
--
GATT tree: 1 service(s)
  service svc (1 char)
    ch props=0x0 (none)
--
GATT tree: 1 service(s)
  service s (1 char)
    a props=0xff (Broadcast+Read+WriteNoResponse+Write+Notify+Indicate+SignedWrite+Extended)
--
"""
    }
}
