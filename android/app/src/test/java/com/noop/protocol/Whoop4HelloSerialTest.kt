package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/** The 4.0 serial decode (#1193) — twin of the Swift `Whoop4HelloSerialTests`, same cases, same values. */
class Whoop4HelloSerialTest {

    /**
     * A 131-byte cmd-35 response shaped like the captured one: a 9-char serial at 14, and the 54-char
     * DEVICE KEY at 24 that must stay unreachable.
     */
    private fun capturedShape(
        serial: String = "WBB5AP053",
        key: String = "K".repeat(54),
    ): ByteArray {
        val p = ByteArray(131)
        serial.forEachIndexed { i, c -> p[14 + i] = c.code.toByte() }
        key.forEachIndexed { i, c -> p[24 + i] = c.code.toByte() }
        return p
    }

    @Test fun `reads the serial from the captured shape`() {
        assertEquals("WBB5AP053", Whoop4HelloSerial.decode(capturedShape()))
    }

    /**
     * The headline safety property: the decoder reads a fixed 9-byte window, so the device key beside
     * the serial cannot be returned no matter what it contains.
     */
    @Test fun `never returns the device key`() {
        val out = Whoop4HelloSerial.decode(capturedShape())
        assertEquals(9, out?.length)
        assertFalse(out!!.contains("K"))
    }

    /**
     * A window that is not a clean alnum run is refused rather than guessed at — a moved field must
     * cost a strap its stable id, never migrate its history onto junk.
     */
    @Test fun `refuses a non-alphanumeric window`() {
        val a = capturedShape().also { it[18] = 0 }
        assertNull(Whoop4HelloSerial.decode(a))
        val b = capturedShape().also { it[14] = 0x2D }
        assertNull(Whoop4HelloSerial.decode(b))
    }

    @Test fun `refuses a short payload`() {
        assertNull(Whoop4HelloSerial.decode(ByteArray(22) { 0x41 }))
        assertNull(Whoop4HelloSerial.decode(ByteArray(0)))
    }

    /** Exactly long enough is enough — the window ends at 23, so a 23-byte payload decodes. */
    @Test fun `accepts the minimum length`() {
        val p = ByteArray(23) { 0x41 }
        "ABC123XYZ".forEachIndexed { i, c -> p[14 + i] = c.code.toByte() }
        assertEquals("ABC123XYZ", Whoop4HelloSerial.decode(p))
    }
}

/** The two-sighting gate (#1193) — twin of the Swift `RepeatedSerialGateTests`. */
class RepeatedSerialGateTest {

    /** The point of the gate: one sighting is never enough to act on. */
    @Test fun `withholds until the same value repeats`() {
        val g = RepeatedSerialGate()
        assertNull(g.offer("WBB5AP053"))
        assertEquals("WBB5AP053", g.offer("WBB5AP053"))
    }

    /**
     * The failure this exists to prevent: a per-session value never confirms, so it can never migrate a
     * history onto a fresh id per connect.
     */
    @Test fun `a value that keeps changing never confirms`() {
        val g = RepeatedSerialGate()
        listOf("AAA111AAA", "BBB222BBB", "CCC333CCC", "DDD444DDD").forEach {
            assertNull("a changing value must never confirm", g.offer(it))
        }
    }

    /**
     * Confirms once, not on every later sighting — the caller adopts on a non-null return, and adopting
     * repeatedly would redo the migration on every connect.
     */
    @Test fun `confirms exactly once`() {
        val g = RepeatedSerialGate()
        g.offer("WBB5AP053")
        assertEquals("WBB5AP053", g.offer("WBB5AP053"))
        assertNull(g.offer("WBB5AP053"))
        assertNull(g.offer("WBB5AP053"))
    }

    /**
     * An interruption resets the run: two sightings must be consecutive, so alternating values cannot
     * accumulate their way to a false confirmation.
     */
    @Test fun `alternating values do not confirm`() {
        val g = RepeatedSerialGate()
        assertNull(g.offer("AAA111AAA"))
        assertNull(g.offer("BBB222BBB"))
        assertNull(g.offer("AAA111AAA"))
        assertEquals("AAA111AAA", g.offer("AAA111AAA"))
    }
}
