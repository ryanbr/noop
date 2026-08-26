package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Byte-identical parity oracle for [clientHelloDeclinedLine] against the Swift
 * `ClientHelloOutcome.declinedLine`. The expected block is the verbatim stdout of the compiled Swift twin,
 * so a one-sided wording or trimming change fails here rather than drifting apart in the field logs the
 * two platforms are meant to be read side by side.
 */
class ClientHelloDeclinedLineTest {
    @Test
    fun `every rendering matches the Swift twin`() {
        val cases = listOf<Pair<String?, String?>>(
            "fd4b0002-cce1-4033-93ce-002d5875f58a" to "status=GATT_SUCCESS(0)",
            "fd4b0002-cce1-4033-93ce-002d5875f58a" to null,
            null to "status=GATT_SUCCESS(0)",
            "" to "  ",
            "  fd4b0002  " to "",
        )
        val out = cases.joinToString("\n") { (u, s) -> clientHelloDeclinedLine(u, s) }
        assertEquals(SWIFT.trim('\n'), out)
    }

    private companion object {
        const val SWIFT = """
CLIENT_HELLO outcome: completion from fd4b0002-cce1-4033-93ce-002d5875f58a status=GATT_SUCCESS(0) with NO hello outstanding — not a bond, so the link stays unbonded (#1635)
CLIENT_HELLO outcome: completion from fd4b0002-cce1-4033-93ce-002d5875f58a with NO hello outstanding — not a bond, so the link stays unbonded (#1635)
CLIENT_HELLO outcome: completion from unknown status=GATT_SUCCESS(0) with NO hello outstanding — not a bond, so the link stays unbonded (#1635)
CLIENT_HELLO outcome: completion from unknown with NO hello outstanding — not a bond, so the link stays unbonded (#1635)
CLIENT_HELLO outcome: completion from fd4b0002 with NO hello outstanding — not a bond, so the link stays unbonded (#1635)
"""
    }
}
