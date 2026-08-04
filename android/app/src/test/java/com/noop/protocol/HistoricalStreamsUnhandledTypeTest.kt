package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #891 — a history offload must not silently discard a packet type nobody has mapped.
 *
 * [extractHistoricalStreams] switches on four of the schema's sixteen packet types and drops the rest at
 * `else`, and [rejectedHistoricalRecords] archives only type-47 — non-47 frames are excluded from it by
 * construction. So before this census an unmapped record was dropped twice and counted zero times, and the
 * sync reported clean.
 *
 * That is not a hypothetical gap. `HISTORICAL_IMU_DATA_STREAM(52)` is a banked raw-stream type the schema
 * already names and the funnel does not handle. It is also the shape #891's leading hypothesis predicts: if
 * a 5/MG banks ECG to flash after the Labrador toggles, the experiment that would find it cannot currently
 * produce a finding, because nothing would report the record.
 *
 * The Android twin of `UnhandledPacketTypeTests.swift` — SAME exclusions, SAME rendered names.
 */
class HistoricalStreamsUnhandledTypeTest {

    private val wallNow = (System.currentTimeMillis() / 1000L).toInt() - 7 * 86_400

    /**
     * A CRC-valid WHOOP 4.0 frame of packet type [t] with an empty body — the shape of a record whose
     * envelope decodes but whose body this decoder has no rows for. The census keys off the type byte at
     * `frame[4]`, which is all these need to carry.
     */
    private fun frameOfType(t: Int): ByteArray {
        val inner = byteArrayOf(t.toByte(), 0, 0)
        // Length covers the inner record PLUS the 4-byte CRC32 trailer, not the record alone. Getting this
        // wrong leaves crcOk null rather than true — the frame still reaches the census, so the test passes
        // while feeding the decoder something malformed. Swift's twin caught it; pinned here too.
        val declaredLen = (inner.size + 4).toByte()
        val out = ArrayList<Byte>()
        out.add(0xAA.toByte())
        out.add(declaredLen)
        out.add(0)
        out.add(Crc.crc8(byteArrayOf(declaredLen, 0)).toByte())
        inner.forEach { out.add(it) }
        val c32 = Crc.crc32(inner)
        out.add((c32 and 0xFF).toByte())
        out.add(((c32 shr 8) and 0xFF).toByte())
        out.add(((c32 shr 16) and 0xFF).toByte())
        out.add(((c32 shr 24) and 0xFF).toByte())
        return out.toByteArray()
    }

    private fun extract(frames: List<ByteArray>) =
        extractHistoricalStreams(frames, wallNow, wallNow, DeviceFamily.WHOOP4)

    // --- the gap this closes ---

    /**
     * A schema-NAMED type the funnel has no branch for is counted, not silently dropped. This is the
     * banked-raw-stream type behind #891 hypothesis (b).
     */
    @Test
    fun namedButUnhandledTypeIsCounted() {
        val t = PacketType.HISTORICAL_IMU_DATA_STREAM.rawValue
        val b = extract(listOf(frameOfType(t), frameOfType(t)))
        assertEquals(mapOf("HISTORICAL_IMU_DATA_STREAM" to 2), b.unhandledPacketTypes)
        assertTrue("it still yields no rows — this is a census, not a decoder", b.isEmpty)
    }

    /** Distinct unhandled types are tallied separately, so a report can name each. */
    @Test
    fun distinctTypesAreTalliedSeparately() {
        val imu = PacketType.HISTORICAL_IMU_DATA_STREAM.rawValue
        val evts = PacketType.PUFFIN_EVENTS_FROM_STRAP.rawValue
        val b = extract(listOf(frameOfType(imu), frameOfType(evts), frameOfType(imu)))
        assertEquals(
            mapOf("HISTORICAL_IMU_DATA_STREAM" to 2, "PUFFIN_EVENTS_FROM_STRAP" to 1),
            b.unhandledPacketTypes,
        )
    }

    /**
     * A byte no enum names renders `type<N>` and is counted under that name, so the number still reaches
     * the strap log with no vocabulary for it.
     */
    @Test
    fun unmappedByteIsCountedUnderItsRenderedName() {
        assertEquals(mapOf("type99" to 1), extract(listOf(frameOfType(99))).unhandledPacketTypes)
    }

    // --- and does not cry wolf ---

    /**
     * METADATA and CONSOLE_LOGS reach `else` on a normal sync and decode to zero rows BY DESIGN. Counting
     * them would put a scary line in every strap log and train people to ignore the one that matters.
     */
    @Test
    fun expectedUnhandledTypesAreNotCounted() {
        val b = extract(
            listOf(
                frameOfType(PacketType.CONSOLE_LOGS.rawValue),
                frameOfType(PacketType.METADATA.rawValue),
                frameOfType(PacketType.CONSOLE_LOGS.rawValue),
            ),
        )
        assertTrue(b.unhandledPacketTypes.isEmpty())
    }

    /**
     * The exclusion set is pinned and must stay in lockstep with Swift's `expectedUnhandledHistoricalTypes`.
     * Adding to it is how this census would quietly stop reporting the thing it was built for.
     */
    @Test
    fun exclusionSetIsExactlyMetadataAndConsole() {
        assertEquals(setOf("METADATA", "CONSOLE_LOGS"), EXPECTED_UNHANDLED_HISTORICAL_TYPES)
    }

    /**
     * Packet-type NAMES must match Swift for every byte the census can render, or the same strap produces
     * two different report lines. 53-56 were missing from the Kotlin enum until #891.
     */
    @Test
    fun packetTypeNamesMatchTheSwiftSchema() {
        assertEquals("REALTIME_IMU_DATA_STREAM", Framing.typeName(51))
        assertEquals("HISTORICAL_IMU_DATA_STREAM", Framing.typeName(52))
        assertEquals("RELATIVE_PUFFIN_EVENTS", Framing.typeName(53))
        assertEquals("PUFFIN_EVENTS_FROM_STRAP", Framing.typeName(54))
        assertEquals("RELATIVE_BATTERY_PACK_CONSOLE_LOGS", Framing.typeName(55))
        assertEquals("METADATA", Framing.typeName(56))   // 5/MG puffin alias, both platforms
        assertEquals("type99", Framing.typeName(99))     // nothing names it
    }

    /**
     * The rendering is FAMILY-AWARE, mirroring Swift's `frameTypeName`: a WHOOP 4.0 frame renders through
     * the plain enum, a 5/MG frame through the puffin aliasing.
     *
     * Type 56 is where that bites. Apple parses a 4.0 frame with `schema.typeName` (no alias) and counts it
     * as PUFFIN_METADATA; if this side always aliased, it would become METADATA and be silently EXCLUDED —
     * the two platforms disagreeing about an anomalous frame, which is the single case the census exists
     * for. A puffin type arriving on a 4.0 is exactly the kind of thing worth reporting, not swallowing.
     */
    @Test
    fun puffinMetadataOnWhoop4IsCountedNotAliasedIntoTheExclusion() {
        val b = extract(listOf(frameOfType(PacketType.PUFFIN_METADATA.rawValue)))
        assertEquals(mapOf("PUFFIN_METADATA" to 1), b.unhandledPacketTypes)
    }

    /** The 4.0 rendering never aliases 38 either — same rule, the other puffin type. */
    @Test
    fun puffinCommandResponseOnWhoop4KeepsItsOwnName() {
        val b = extract(listOf(frameOfType(PacketType.PUFFIN_COMMAND_RESPONSE.rawValue)))
        assertEquals(mapOf("PUFFIN_COMMAND_RESPONSE" to 1), b.unhandledPacketTypes)
    }
}
