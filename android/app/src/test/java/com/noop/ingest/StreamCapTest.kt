package com.noop.ingest

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.InputStream

/**
 * The memory-exhaustion guard on user-supplied import files.
 *
 * It existed five times across the importers with identical bodies and no test anywhere — a guard
 * whose boundary nobody had pinned. These pin it once, now that there is one implementation.
 */
class StreamCapTest {

    private fun stream(n: Int): InputStream = ByteArrayInputStream(ByteArray(n) { (it % 251).toByte() })

    /** Content below the cap comes back byte-for-byte — the guard must not corrupt what it allows. */
    @Test fun readsContentUnderTheCapExactly() {
        val src = ByteArray(5_000) { (it % 251).toByte() }
        assertArrayEquals(src, ByteArrayInputStream(src).readCapped(10_000))
    }

    /** Spans many read() calls: the buffer is 64 KiB, so this exercises the accumulate path. */
    @Test fun readsAcrossMultipleChunks() {
        val size = 64 * 1024 * 3 + 17
        assertEquals(size, stream(size).readCapped(1L shl 20).size)
    }

    /** Exactly at the cap is allowed — the check is `total > cap`, not `>=`. */
    @Test fun exactlyAtTheCapIsAllowed() {
        assertEquals(1_000, stream(1_000).readCapped(1_000L).size)
    }

    /** One byte over throws. This is the boundary the five copies all encoded and none tested. */
    @Test fun oneByteOverTheCapThrows() {
        assertThrows(IllegalStateException::class.java) { stream(1_001).readCapped(1_000L) }
    }

    /** An empty stream is not an error — an empty import file should fail in the parser, not here. */
    @Test fun emptyStreamIsAllowed() {
        assertEquals(0, stream(0).readCapped(1_000L).size)
    }

    /**
     * The wording each importer already produced is preserved: everything says "Input" except the
     * zip-entry path, which says "Entry". These messages reach the user through an import failure.
     */
    @Test fun theFailureMessageNamesTheThingAndTheCap() {
        val input = assertThrows(IllegalStateException::class.java) { stream(50).readCapped(10L) }
        assertEquals("Input exceeds 10 bytes", input.message)

        val entry = assertThrows(IllegalStateException::class.java) {
            stream(50).readCapped(10L, what = "Entry")
        }
        assertEquals("Entry exceeds 10 bytes", entry.message)
    }

    /**
     * The guard has to bound PEAK memory, not just the return value — it must refuse before buffering
     * the chunk that crosses the line. Asserted by reading a stream far larger than the cap and
     * checking it fails without having consumed it all: a guard that buffered first would still throw,
     * but only after allocating the whole thing, which is the failure it exists to prevent.
     */
    @Test fun throwsBeforeBufferingTheWholeOversizeStream() {
        var consumed = 0
        val counting = object : InputStream() {
            private val inner = stream(64 * 1024 * 40)   // 2.5 MiB
            override fun read(): Int = inner.read().also { if (it >= 0) consumed += 1 }
            override fun read(b: ByteArray, off: Int, len: Int): Int =
                inner.read(b, off, len).also { if (it > 0) consumed += it }
        }
        assertThrows(IllegalStateException::class.java) { counting.readCapped(128L * 1024) }
        assertTrue(
            "should stop near the cap, consumed $consumed bytes",
            consumed <= 128 * 1024 + 64 * 1024,   // the cap plus at most one buffer
        )
    }
}
