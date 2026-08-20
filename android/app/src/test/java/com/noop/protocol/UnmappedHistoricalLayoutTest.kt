package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The archive decision for a WHOOP 5/MG type-47 record must be made on its LAYOUT VERSION, not on what
 * the record happened to decode to. Twin of the Swift `UnmappedHistoricalLayoutTests`.
 *
 * [rejectedHistoricalRecords] used to ask only "did [decodeHistorical] produce a record?". That screen is
 * the wrong QUESTION for a layout NOOP has no field map for: a record from an unmapped version that
 * answered yes would be kept NOWHERE — not as rows (nothing mapped it) and not as bytes (it passed the
 * archive filter) — and the strap frees it on the very next trim ack. A record type NOOP has not mapped
 * yet — banked to flash by a newer firmware and pulled back in a later offload — is exactly the shape
 * that can look well-formed enough to pass.
 *
 * The screen survives in practice only because of an accident: [decodeWhoop5Historical] returns null for
 * every version but 18 (`unmappedLayoutsDecodeNothing` pins that this is true right now). One added
 * static field for type 47, or one partially-mapped new version, would silently reopen the hole. These
 * pin the version-based decision instead, so the archive no longer depends on that accident holding.
 */
class UnmappedHistoricalLayoutTest {

    private fun bytes(s: String): ByteArray = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    // A real WHOOP 5/MG type-47 v18 record (from Whoop5HistoricalDecodeTest): decodes a real unix, a
    // plausible heart rate and a ~1 g gravity vector — i.e. it PASSES the old decode-outcome screen.
    private val whoop5V18Hex =
        "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817"

    /**
     * Re-stamp the WHOOP 5 CRC32 trailer after mutating the version byte, so the frame stays CRC-VALID.
     * Load-bearing for every test here: a CRC failure is archived on its own, which would make the
     * version-based path untestable.
     */
    private fun whoop5FrameWithVersion(version: Int): ByteArray {
        val f = bytes(whoop5V18Hex)
        f[9] = version.toByte()
        val payloadEnd = f.size - 4
        val c = Crc.crc32(f, 8, payloadEnd)
        for (b in 0 until 4) f[payloadEnd + b] = ((c shr (8 * b)) and 0xFF).toByte()
        return f
    }

    // MARK: - defect: an unmapped layout that decodes real biometrics must still be archived

    /**
     * The headline case. The frame's BYTES are a real v18 record — at the v18 offsets they carry a valid
     * unix, a plausible heart rate and a ~1 g gravity vector, the exact combination that made the old
     * screen say "decodable, nothing lost". Only the layout-version byte differs. Whatever such a record
     * decodes to, its bytes must reach the archive.
     */
    @Test fun unmappedLayoutIsArchivedEvenThoughItsBytesDecodeCleanlyAsV18() {
        // Precondition: read as its true version, this record decodes everything the old screen wanted.
        val asV18 = decodeHistorical(bytes(whoop5V18Hex), DeviceFamily.WHOOP5)!!
        // #869 widened the decoded `unix` from Int to Long — a u32 with bit 31 set narrowed to a NEGATIVE
        // Int, which the #547 plausibility gate then dropped, silently losing all history from 2038-01-19
        // (and today on a future-dated strap). The value here is unchanged; only its type is wider, so the
        // literal needs the L or assertEquals compares Integer against Long and fails on the box.
        assertEquals("precondition: these bytes DO decode a unix", 1780916150L, asV18["unix"])
        assertEquals("precondition: these bytes DO decode a heart rate", 102, asV18["heart_rate"])
        assertTrue("precondition: these bytes DO decode a gravity vector", asV18["gravity_x"] is Double)

        val unmapped = whoop5FrameWithVersion(22)
        assertEquals(
            "precondition: the record is CRC-VALID, so only the layout decision can archive it",
            true, Framing.parseFrame(unmapped, DeviceFamily.WHOOP5).crcOk,
        )
        assertTrue(isUnmappedWhoop5HistoricalRecord(unmapped))
        assertEquals(
            "a record from a layout NOOP cannot map must be archived whatever it decoded",
            listOf(unmapped.toList()),
            rejectedHistoricalRecords(listOf(unmapped), DeviceFamily.WHOOP5).map { it.toList() },
        )
    }

    /** Every version outside [MAPPED_WHOOP5_HISTORICAL_VERSIONS] is archived — no gaps, no lucky values. */
    @Test fun everyUnmappedVersionIsArchived() {
        for (v in 0..255) {
            if (v in MAPPED_WHOOP5_HISTORICAL_VERSIONS) continue
            val f = whoop5FrameWithVersion(v)
            assertEquals(
                "hist_version $v has no field map, so its bytes must be archived",
                1, rejectedHistoricalRecords(listOf(f), DeviceFamily.WHOOP5).size,
            )
        }
    }

    // MARK: - lockstep: the version set and the decoder's dispatch cannot drift apart

    /**
     * [MAPPED_WHOOP5_HISTORICAL_VERSIONS] is the single source of truth for the archive decision, so it
     * must not claim more (or fewer) versions than the decoder actually maps. Proved from the decoder's
     * own behaviour: EVERY version outside the set decodes to nothing at all.
     */
    @Test fun unmappedLayoutsDecodeNothing() {
        for (v in 0..255) {
            if (v in MAPPED_WHOOP5_HISTORICAL_VERSIONS) continue
            assertNull(
                "v$v is outside the mapped set but the decoder produced a record for it — the set and " +
                    "the version gate in decodeWhoop5Historical have drifted",
                decodeHistorical(whoop5FrameWithVersion(v), DeviceFamily.WHOOP5),
            )
        }
    }

    /**
     * The mapped versions ARE recognised as mapped (the other direction of the lockstep).
     *
     * ⚠️ This set is {18, 26}, NOT the Swift `[18, 20, 21, 26]`. Swift dispatches v20 (raw optical) and
     * v21 (raw 6-axis IMU) through `decodeWhoop5HistoricalV2021`; the Kotlin historical path has no such
     * branch — `Whoop5RawOptical`/`Whoop5RawImu` are wired to the LIVE deep-buffer route, not to the
     * type-47 historical dispatch. Claiming 20/21 here would assert a field map Android does not have.
     * Update BOTH this assertion and the constant when a v20/v21 historical decoder lands on this side.
     */
    @Test fun mappedVersionsAreNotTreatedAsUnmapped() {
        assertEquals(setOf(18, 26), MAPPED_WHOOP5_HISTORICAL_VERSIONS)
        for (v in MAPPED_WHOOP5_HISTORICAL_VERSIONS) {
            assertFalse(
                "v$v has a field map and must not be archived on layout grounds",
                isUnmappedWhoop5HistoricalRecord(whoop5FrameWithVersion(v)),
            )
        }
    }

    /**
     * A cleanly-decoding v18 record is still NOT archived — widening the screen must not start archiving
     * the layouts NOOP already understands wholesale. v26 keeps its own exclusion (raw PPG has a durable
     * `ppgWaveformSample` stream; it is known-skipped, not lost).
     */
    @Test fun mappedRecordsAreStillNotArchived() {
        assertTrue(rejectedHistoricalRecords(listOf(bytes(whoop5V18Hex)), DeviceFamily.WHOOP5).isEmpty())
        assertTrue(rejectedHistoricalRecords(listOf(whoop5FrameWithVersion(26)), DeviceFamily.WHOOP5).isEmpty())
    }

    /**
     * The layout rule is WHOOP 5-only: it keys off `frame[9]`, which on a WHOOP 4 frame is a payload byte,
     * not a version. WHOOP 4's unmapped versions go through the validated v24 fallback in
     * [decodeHistorical], which keeps a record only when it decodes to a ~1 g gravity vector and a
     * plausible HR and otherwise drops the biometrics — so those records reach the archive by the
     * decode-outcome route and must not be dragged in by this one.
     */
    @Test fun whoop4FramesAreUnaffectedByTheWhoop5LayoutRule() {
        // A synthetic WHOOP 4 V24 type-47 record (HR=63) that decodes cleanly.
        val v24Hex =
            "aa5a008e2f18000000000000f153650000000000003f0152030000000000000000dc053075" +
                "000000cdcc4c3dcdcccc3d5a657e3f00000040cdcc4c3dcdcccc3d5a657e3f504668428403" +
                "200364006400b80bb80b000000000000c25c1a88"
        assertTrue(rejectedHistoricalRecords(listOf(bytes(v24Hex)), DeviceFamily.WHOOP4).isEmpty())
        assertFalse(
            "a WHOOP 4 frame has no type-47 byte at index 8 — the rule must not fire on it",
            isUnmappedWhoop5HistoricalRecord(bytes(v24Hex)),
        )
    }
}
