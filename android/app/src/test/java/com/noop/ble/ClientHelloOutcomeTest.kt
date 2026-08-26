package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the CLIENT_HELLO outcome line (#1635). Swift twin: `ClientHelloOutcomeTests`.
 *
 * In one field capture, 14 of 16 CLIENT_HELLO writes went out and were never acked, 1 was rejected, and
 * 1 produced an "ack" from a completion whose characteristic was never checked. All three looked the
 * same from a log: silence, then a link drop.
 */
class ClientHelloOutcomeTest {

    private val hello = "fd4b0002-cce1-4033-93ce-002d5875f58a"

    @Test
    fun `a completion from the hello characteristic is a real ack`() {
        assertEquals(
            "CLIENT_HELLO outcome: acked by $hello after 120ms status=SUCCESS(0)",
            clientHelloOutcomeLine(true, hello, 120, "status=SUCCESS(0)"),
        )
    }

    @Test
    fun `a completion from another characteristic is named, not counted as an ack`() {
        // The reported false bond: the branch matches on family alone, so DISABLE_ALARM's completion was
        // taken as the hello ack. The line must name the characteristic and refuse the word "acked".
        val line = clientHelloOutcomeLine(false, "00002a19-0000-1000-8000-00805f9b34fb", 40, "status=SUCCESS(0)")
        assertTrue(line, line.contains("DIFFERENT characteristic 00002a19-0000-1000-8000-00805f9b34fb"))
        assertTrue(line, line.contains("NOT a CLIENT_HELLO ack"))
        assertTrue(line, !line.contains("outcome: acked"))
    }

    @Test
    fun `no callback at all is reported with the elapsed time`() {
        // The dominant field case, and the one that previously produced no line whatsoever.
        assertEquals(
            "CLIENT_HELLO outcome: NO write callback after 3200ms — the link dropped before the stack" +
                " reported, so the strap may never have seen it",
            clientHelloOutcomeLine(false, null, 3200, null),
        )
    }

    @Test
    fun `a null characteristic wins over the isHelloChar flag`() {
        // Defensive: "no callback" is decided by the absent characteristic, so a stale true flag cannot
        // turn silence into a reported ack.
        assertTrue(clientHelloOutcomeLine(true, null, 10, "status=SUCCESS(0)").contains("NO write callback"))
    }

    @Test
    fun `a blank characteristic and a blank status degrade without punctuation debris`() {
        assertEquals(
            "CLIENT_HELLO outcome: acked by unknown after 5ms",
            clientHelloOutcomeLine(true, "   ", 5, "  "),
        )
    }
}
