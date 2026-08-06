package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The blob-offset question, pinned. Twin of the Swift `V18AuxCodecOffsetTests`.
 *
 * The cloud reader takes `fields[23]` of the STORED `v18AuxSample.fields` blob and gets physiologically
 * valid SpO2 out of it. That works — but it is an ARITHMETIC COINCIDENCE of a fully-populated record, not
 * a property of the format. [V18AuxCodec] is a presence-bitmap codec: absent slots are omitted from the
 * body entirely, so every slot's byte offset depends on which slots ahead of it were present.
 *
 * These tests establish both halves, because only the pair is decisive. The first alone would license the
 * fragile read; the second is what says the device write path must not use it — which is why
 * `WhoopRepository.insert` forks `spo2PctSample` rows off `V18AuxRow.auxByte82`, the DECODED value, and
 * never indexes the blob.
 */
class V18AuxCodecOffsetTest {

    /** A record carrying every slot, with distinguishable values. */
    private fun fullRow(): V18AuxRow = V18AuxRow(
        ts = 1L,
        recordIndex = 0x11223344L, rrCount = 4L, cardiacFlags = 0x21L, hrQualityFlags = 0x82L,
        heartRateAlt = 58L, rrPacked = 0x0505L, cardiacStatus = 0x31L, stepCadence = 0x41L,
        statusWord = 0x0606L, statusWord1 = 0x0707L, statusWord2 = 0x0808L, auxByte82 = 93L,
        opticalBaselineA = 0x51L, opticalBaselineB = 0x52L, opticalAmpA = 0x53L, opticalAmpB = 0x54L,
        unknownF32Bits = 0x55667788L,
    )

    private fun ByteArray.u8(i: Int): Int = this[i].toInt() and 0xFF

    /**
     * A record carrying every slot: `auxByte82` lands at blob byte 23. Header is 5 bytes (version + u32
     * bitmap), then the eleven slots ahead of it occupy 4+1+1+1+1+2+1+1+2+2+2 = 18 bytes, so it sits at
     * 5 + 18 = 23 and the whole blob is 32 bytes. THIS is why the cloud's `fields[23]` reads real
     * percentages: in production every one of those slots is present.
     */
    @Test fun fullyPopulatedRecordPutsAuxByte82AtBlobByte23() {
        val blob = V18AuxCodec.pack(fullRow())

        assertEquals("5-byte header + 27 body bytes", 32, blob.size)
        assertEquals("byte 23 of a fully-populated blob IS @82", 93, blob.u8(23))
        // And it agrees with the decoded row, which is the only contract that actually holds.
        assertEquals(93L, V18AuxCodec.unpack(blob, 1L).auxByte82)
        // Derive the offset from the slot table rather than trusting the literal, so a future slot
        // inserted ahead of @82 fails HERE with a readable number instead of silently moving the cloud's
        // read onto a neighbouring byte.
        val ahead = V18AuxSlot.entries
            .filter { it.index < V18AuxSlot.AUX_BYTE_82.index }
            .sumOf { it.width }
        assertEquals(23, V18AuxCodec.HEADER_BYTES + ahead)
    }

    /**
     * ONE absent slot ahead of it and byte 23 is a different field entirely — while the decoded value is
     * still correct. The blob read does not degrade loudly; it returns a neighbouring byte that can look
     * exactly like a plausible saturation.
     */
    @Test fun oneAbsentEarlierSlotMovesAuxByte82OffByte23() {
        // Identical to the record above except `recordIndex` (4 bytes, slot 0) is absent.
        val blob = V18AuxCodec.pack(fullRow().copy(recordIndex = null))

        assertEquals("four fewer body bytes without recordIndex", 28, blob.size)
        // @82 has slid four bytes earlier...
        assertEquals(93, blob.u8(19))
        // ...and byte 23 now holds opticalAmpB, four slots further along. Reading it as a percentage would
        // yield 0x54 = 84: in band, unremarkable, and completely fabricated. Note it does NOT fail loudly
        // — an optical amplitude byte and a saturation percentage occupy the same numeric range, so the
        // bad read is indistinguishable from a good one at the call site.
        assertEquals(0x54, blob.u8(23))
        assertNotEquals(93, blob.u8(23))
        assertTrue(
            "the wrong byte is still 'in band' — which is exactly why this read is unsafe",
            blob.u8(23) in SPO2_CANDIDATE_IN_BAND,
        )
        // The decoded read is unaffected — it is driven by the bitmap, not by an offset.
        assertEquals(93L, V18AuxCodec.unpack(blob, 1L).auxByte82)
    }
}
