package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #891: byte-parity twin of the Swift `DeviceConfigWriteGateTests` — the ECG raw-data gate's write
 * allowlist, the body it builds, and the mandatory read-back.
 *
 * The allowlist tests are the point of this file. [DeviceConfigWriteGate.admitsSend] is the SAME predicate
 * the 5/MG send path consults, so proving here that it refuses an opcode or a key is proving it about the
 * real wire path rather than about a copy of the rule.
 */
class DeviceConfigWriteGateTest {

    // Helpers ---------------------------------------------------------------------------------------

    /** The payload the send path would hold for a device-config write of [key]. */
    private fun payload(key: String, value: Int = 0x31): ByteArray =
        byteArrayOf(0x01) + Whoop5Config.deviceConfigBody(key, value)

    /** A real 5/MG COMMAND_RESPONSE frame carrying [record] for command 121, CRC16 header + CRC32 body,
     *  so [DeviceConfigReadProbe.parse] runs its CRC gate on these fixtures rather than being bypassed. */
    private fun readBackFrame(record: ByteArray, cmd: Int = 121, result: Int = 1): ByteArray {
        var inner = byteArrayOf(36, 1, cmd.toByte(), 0x0A, result.toByte()) + record
        val pad = (4 - inner.size % 4) % 4
        if (pad > 0) inner += ByteArray(pad)
        val declLen = inner.size + 4
        val head = byteArrayOf(
            0xAA.toByte(), 0x01, (declLen and 0xFF).toByte(), ((declLen shr 8) and 0xFF).toByte(),
            0x00, 0x01,
        )
        val c16 = Crc.crc16Modbus(head)
        val c32 = Crc.crc32(inner)
        return head + byteArrayOf((c16 and 0xFF).toByte(), ((c16 shr 8) and 0xFF).toByte()) + inner +
            byteArrayOf(
                (c32 and 0xFFL).toByte(), ((c32 shr 8) and 0xFFL).toByte(),
                ((c32 shr 16) and 0xFFL).toByte(), ((c32 shr 24) and 0xFFL).toByte(),
            )
    }

    /** A 121 reply record echoing [key] in a 32-byte NUL-padded field, then [value] as ASCII. */
    private fun echoRecord(key: String, value: String): ByteArray {
        val field = ByteArray(DeviceConfigWriteGate.NAME_FIELD_BYTES)
        val bytes = key.toByteArray(Charsets.UTF_8)
        for (i in 0 until minOf(field.size, bytes.size)) field[i] = bytes[i]
        return field + value.toByteArray(Charsets.US_ASCII)
    }

    private fun parseReadBack(frame: ByteArray): DeviceConfigReadProbe.ValueResponse {
        val parsed = DeviceConfigReadProbe.parse(frame, DeviceFamily.WHOOP5, 121)
        return requireNotNull(parsed.value) { "read-back frame should parse" }
    }

    // The allowlist: what it admits ------------------------------------------------------------------

    @Test
    fun admitsEcgKeyOnlyWhenOptedInOnAnAttestedMG() {
        val p = payload(DeviceConfigWriteGate.ECG_RAW_DATA_KEY)
        assertTrue(DeviceConfigWriteGate.admitsSend(119, p, ecgGateOptIn = true, isMG = true, broadcastHrOptIn = false))
        assertFalse(DeviceConfigWriteGate.admitsSend(119, p, ecgGateOptIn = false, isMG = true, broadcastHrOptIn = false))
        assertFalse(DeviceConfigWriteGate.admitsSend(119, p, ecgGateOptIn = true, isMG = false, broadcastHrOptIn = false))
        // The Broadcast-HR opt-in must NOT carry the ECG key — the hole the key-aware gate closes.
        assertFalse(DeviceConfigWriteGate.admitsSend(119, p, ecgGateOptIn = false, isMG = true, broadcastHrOptIn = true))
    }

    @Test
    fun admitsBroadcastHrKeyOnlyUnderItsOwnOptIn() {
        val p = payload(DeviceConfigWriteGate.BROADCAST_HR_KEY)
        assertTrue(DeviceConfigWriteGate.admitsSend(119, p, ecgGateOptIn = false, isMG = false, broadcastHrOptIn = true))
        assertFalse(DeviceConfigWriteGate.admitsSend(119, p, ecgGateOptIn = false, isMG = false, broadcastHrOptIn = false))
        assertFalse(DeviceConfigWriteGate.admitsSend(119, p, ecgGateOptIn = true, isMG = true, broadcastHrOptIn = false))
        // Broadcast HR is not MG-gated: it works on a plain 5.0, and must keep doing so.
        assertTrue(DeviceConfigWriteGate.admitsSend(119, p, ecgGateOptIn = true, isMG = false, broadcastHrOptIn = true))
    }

    @Test
    fun admitsBroadcastHrDisableWriteRegardlessOfOptIn() {
        // #1061: turning the Broadcast-HR flag OFF is the safe UNDO and must NOT be gated on the opt-in — it
        // is already false by the time the user disables, which made the toggle-off path dead (the disable
        // refused here, strap left advertising). The OFF write must be admitted with NO opt-in.
        val off = payload(DeviceConfigWriteGate.BROADCAST_HR_KEY, DeviceConfigWriteGate.DISABLED_VALUE)
        assertTrue(DeviceConfigWriteGate.admitsSend(119, off, ecgGateOptIn = false, isMG = false, broadcastHrOptIn = false))
        assertTrue(DeviceConfigWriteGate.admitsSend(119, off, ecgGateOptIn = false, isMG = false, broadcastHrOptIn = true))
        // The ON write stays gated on the opt-in — the exemption is for OFF only.
        val on = payload(DeviceConfigWriteGate.BROADCAST_HR_KEY, DeviceConfigWriteGate.ENABLED_VALUE)
        assertFalse(DeviceConfigWriteGate.admitsSend(119, on, ecgGateOptIn = false, isMG = false, broadcastHrOptIn = false))
        // The OFF exemption is Broadcast-HR ONLY: the ECG key's OFF write stays gated on its own opt-in (#891).
        val ecgOff = payload(DeviceConfigWriteGate.ECG_RAW_DATA_KEY, DeviceConfigWriteGate.DISABLED_VALUE)
        assertFalse(DeviceConfigWriteGate.admitsSend(119, ecgOff, ecgGateOptIn = false, isMG = true, broadcastHrOptIn = false))
    }

    // The allowlist: what it refuses -----------------------------------------------------------------

    @Test
    fun refusesEveryOtherEnumeratedKeyEvenWithBothOptInsOn() {
        for (key in DeviceConfigWriteGate.OUT_OF_SCOPE_KEYS) {
            assertFalse(
                "$key must never be writable from this path",
                DeviceConfigWriteGate.admitsSend(
                    119, payload(key), ecgGateOptIn = true, isMG = true, broadcastHrOptIn = true,
                ),
            )
        }
        assertEquals(5, DeviceConfigWriteGate.OUT_OF_SCOPE_KEYS.size)
        assertEquals(
            (
                DeviceConfigWriteGate.OUT_OF_SCOPE_KEYS +
                    listOf(DeviceConfigWriteGate.ECG_RAW_DATA_KEY, DeviceConfigWriteGate.BROADCAST_HR_KEY)
                ).toSet(),
            DeviceConfigWriteGate.ENUMERATED_KEYS.toSet(),
        )
        assertEquals(7, DeviceConfigWriteGate.ENUMERATED_KEYS.size)
    }

    @Test
    fun refusesSetFeatureFlagValue120ForEveryKeyAndEveryOptIn() {
        val keys = DeviceConfigWriteGate.ENUMERATED_KEYS + Whoop5Config.enableR22Sequence.map { it.name }
        for (key in keys) {
            for (ecg in listOf(true, false)) {
                for (hr in listOf(true, false)) {
                    assertFalse(
                        "SET_FF_VALUE(120) must never be admitted (key=$key)",
                        DeviceConfigWriteGate.admitsSend(
                            DeviceConfigWriteGate.SET_FF_VALUE_CMD, payload(key),
                            ecgGateOptIn = ecg, isMG = true, broadcastHrOptIn = hr,
                        ),
                    )
                }
            }
        }
    }

    @Test
    fun refusesEveryOtherOpcodeInTheWholeByteRange() {
        val p = payload(DeviceConfigWriteGate.ECG_RAW_DATA_KEY)
        val admitted = (0..255).filter {
            DeviceConfigWriteGate.admitsSend(it, p, ecgGateOptIn = true, isMG = true, broadcastHrOptIn = true)
        }
        assertEquals(listOf(DeviceConfigWriteGate.SET_DEVICE_CONFIG_VALUE_CMD), admitted)
    }

    @Test
    fun refusesUnknownAndMalformedKeys() {
        for ((ecg, hr) in listOf(true to true, true to false, false to true, false to false)) {
            assertFalse(
                DeviceConfigWriteGate.admitsSend(
                    119, payload("enable_something_invented"), ecgGateOptIn = ecg, isMG = true, broadcastHrOptIn = hr,
                ),
            )
            for (near in listOf("enable_raw_data_w_ec", "enable_raw_data_w_ecg2", "ENABLE_RAW_DATA_W_ECG")) {
                assertFalse(
                    "$near must not pass",
                    DeviceConfigWriteGate.admitsSend(
                        119, payload(near), ecgGateOptIn = ecg, isMG = true, broadcastHrOptIn = hr,
                    ),
                )
            }
        }
        val good = payload(DeviceConfigWriteGate.ECG_RAW_DATA_KEY)
        val malformed = listOf(
            ByteArray(0),
            byteArrayOf(0x01),
            good.copyOfRange(1, good.size),
            byteArrayOf(0x02) + good.copyOfRange(1, good.size),
            good.copyOfRange(0, 20),
        )
        for (bad in malformed) {
            assertFalse(
                DeviceConfigWriteGate.admitsSend(119, bad, ecgGateOptIn = true, isMG = true, broadcastHrOptIn = true),
            )
        }
    }

    @Test
    fun keyNameParsingRejectsNonNulPaddingAndNonAscii() {
        // Junk AFTER the NUL terminator is not a NUL-padded name field — nothing is claimed.
        val body = payload(DeviceConfigWriteGate.ECG_RAW_DATA_KEY)
        body[1 + DeviceConfigWriteGate.ECG_RAW_DATA_KEY.length + 2] = 0x41
        assertNull(DeviceConfigWriteGate.keyNameInSendPayload(body))
        assertFalse(
            DeviceConfigWriteGate.admitsSend(119, body, ecgGateOptIn = true, isMG = true, broadcastHrOptIn = true),
        )
        // Extending the name itself yields a DIFFERENT name, which the key allowlist then refuses.
        val extended = payload(DeviceConfigWriteGate.ECG_RAW_DATA_KEY)
        extended[1 + DeviceConfigWriteGate.ECG_RAW_DATA_KEY.length] = 0x41
        assertEquals("enable_raw_data_w_ecgA", DeviceConfigWriteGate.keyNameInSendPayload(extended))
        assertFalse(
            DeviceConfigWriteGate.admitsSend(119, extended, ecgGateOptIn = true, isMG = true, broadcastHrOptIn = true),
        )
        // Binary in the name field is refused, not transliterated.
        val binary = payload(DeviceConfigWriteGate.ECG_RAW_DATA_KEY)
        binary[3] = 0xFF.toByte()
        assertNull(DeviceConfigWriteGate.keyNameInSendPayload(binary))
        assertEquals("enable_rfid", DeviceConfigWriteGate.keyNameInSendPayload(payload("enable_rfid")))
    }

    @Test
    fun readBackOpcodeIsOnly121() {
        assertEquals(listOf(121), (0..255).filter { DeviceConfigWriteGate.isReadBackOpcode(it) })
        assertFalse(DeviceConfigWriteGate.isReadBackOpcode(119))
        assertFalse(DeviceConfigWriteGate.isReadBackOpcode(120))
        assertFalse(DeviceConfigWriteGate.isReadBackOpcode(128))
    }

    // The bytes on the wire --------------------------------------------------------------------------

    @Test
    fun writePayloadIsTheHardwareValidatedBroadcastHrShape() {
        val on = DeviceConfigWriteGate.writePayload(true)
        assertEquals(1 + 32 + 1, on.size)
        assertEquals(0x01, on[0].toInt())
        assertEquals("enable_raw_data_w_ecg", DeviceConfigWriteGate.keyNameInSendPayload(on))
        assertEquals(0x31, on.last().toInt() and 0xFF)
        val off = DeviceConfigWriteGate.writePayload(false)
        assertEquals(0x30, off.last().toInt() and 0xFF)
        // Both directions differ ONLY in the value byte — reversibility is one byte, not a second path.
        assertTrue(on.copyOfRange(0, on.size - 1).contentEquals(off.copyOfRange(0, off.size - 1)))
    }

    @Test
    fun readBackPayloadMatchesTheReadProbesRequestShape() {
        assertTrue(
            DeviceConfigWriteGate.readBackPayload()
                .contentEquals(DeviceConfigReadProbe.requestBody("enable_raw_data_w_ecg")),
        )
    }

    // The single-digit value the read-back reads -----------------------------------------------------

    @Test
    fun valueReadsTheSingleDigitGateValue() {
        // The gate stores one ASCII digit, so the report reads exactly the byte after the echoed name
        // field (main's single-byte valueFor). Multi-character values belong to the read probe.
        val one = DeviceConfigReadProbe.ValueResponse(1, echoRecord("enable_raw_data_w_ecg", "1"))
        assertEquals(0x31, one.valueFor("enable_raw_data_w_ecg"))
        // Trailing envelope NUL padding after the value byte is not part of it.
        val padded = DeviceConfigReadProbe.ValueResponse(1, echoRecord("enable_raw_data_w_ecg", "0") + ByteArray(3))
        assertEquals(0x30, padded.valueFor("enable_raw_data_w_ecg"))
        // A record that stops at the name field claims no value.
        assertNull(DeviceConfigReadProbe.ValueResponse(1, ByteArray(32)).valueFor("enable_raw_data_w_ecg"))
        // The key not being echoed at all claims nothing either.
        assertNull(
            DeviceConfigReadProbe.ValueResponse(1, echoRecord("enable_rfid", "0"))
                .valueFor("enable_raw_data_w_ecg"),
        )
    }

    // The verdict table: the ack never decides, the read-back does -----------------------------------

    @Test
    fun confirmedOnlyWhenTheReadBackReturnsWhatWasAsked() {
        val report = EcgRawDataGateReport(true)
        assertEquals(EcgRawDataGateReport.Verdict.PENDING, report.verdict)
        report.noteWriteAck(1)
        // A SUCCESS ack alone must NOT reach a verdict — #891's whole lesson.
        assertEquals(EcgRawDataGateReport.Verdict.PENDING, report.verdict)
        report.noteReadBack(parseReadBack(readBackFrame(echoRecord("enable_raw_data_w_ecg", "1"))))
        assertEquals(EcgRawDataGateReport.Verdict.CONFIRMED, report.verdict)
        assertEquals("1", report.storedValue)
        assertTrue(report.render().contains("enable_raw_data_w_ecg"))
    }

    @Test
    fun successAckWithAnUnmovedValueIsUnchangedNotSuccess() {
        // The exact failure mode this design exists for: the strap acks SUCCESS and the value did not move.
        val report = EcgRawDataGateReport(true)
        report.noteWriteAck(1)
        report.noteReadBack(parseReadBack(readBackFrame(echoRecord("enable_raw_data_w_ecg", "0"))))
        assertEquals(EcgRawDataGateReport.Verdict.UNCHANGED, report.verdict)
        assertEquals("0", report.storedValue)
        assertTrue(report.summary.contains("did NOT take"))
    }

    @Test
    fun turningTheGateBackOffConfirmsOnZero() {
        val report = EcgRawDataGateReport(false)
        assertEquals("0", report.requested)
        report.noteReadBack(parseReadBack(readBackFrame(echoRecord("enable_raw_data_w_ecg", "0"))))
        assertEquals(EcgRawDataGateReport.Verdict.CONFIRMED, report.verdict)
    }

    @Test
    fun refusedSilentNotClaimedAndUndecodableAreNeverSuccess() {
        val refused = EcgRawDataGateReport(true)
        refused.noteReadBack(DeviceConfigReadProbe.ValueResponse(0, ByteArray(0)))
        assertEquals(EcgRawDataGateReport.Verdict.REFUSED, refused.verdict)

        val unsupported = EcgRawDataGateReport(true)
        unsupported.noteReadBack(DeviceConfigReadProbe.ValueResponse(3, ByteArray(0)))
        assertEquals(EcgRawDataGateReport.Verdict.REFUSED, unsupported.verdict)

        val notClaimed = EcgRawDataGateReport(true)
        notClaimed.noteReadBack(DeviceConfigReadProbe.ValueResponse(1, echoRecord("enable_rfid", "1")))
        assertEquals(EcgRawDataGateReport.Verdict.NOT_CLAIMED, notClaimed.verdict)

        val silent = EcgRawDataGateReport(true)
        silent.noteReadBackTimeout(8)
        assertEquals(EcgRawDataGateReport.Verdict.SILENT, silent.verdict)

        val undecodable = EcgRawDataGateReport(true)
        undecodable.noteReadBackFailure(DeviceConfigReadProbe.ParseFailure.CRC)
        assertEquals(EcgRawDataGateReport.Verdict.UNDECODABLE, undecodable.verdict)

        for (r in listOf(refused, unsupported, notClaimed, silent, undecodable)) {
            assertNotEquals(EcgRawDataGateReport.Verdict.CONFIRMED, r.verdict)
            assertTrue(r.summary.isNotEmpty())
        }
    }

    @Test
    fun readBackIsCrcGatedLikeEveryOtherDecode() {
        val frame = readBackFrame(echoRecord("enable_raw_data_w_ecg", "1"))
        frame[frame.size - 1] = (frame[frame.size - 1].toInt() xor 0xFF).toByte()
        val parsed = DeviceConfigReadProbe.parse(frame, DeviceFamily.WHOOP5, 121)
        assertNull(parsed.value)
        assertEquals(DeviceConfigReadProbe.ParseFailure.CRC, parsed.failure)
    }

    @Test
    fun renderNamesTheKeyTheVerbsAndTheOpenQuestion() {
        val report = EcgRawDataGateReport(true)
        report.noteWriteAck(1)
        report.noteReadBackTimeout(8)
        val text = report.render()
        assertTrue(text.contains("SET_DEVICE_CONFIG_VALUE(119)"))
        assertTrue(text.contains("GET_DEVICE_CONFIG_VALUE(121)"))
        assertTrue(text.contains("SET_FF_VALUE(120) is never sent"))
        // The honest framing has to survive into the copyable report a user pastes into an issue.
        assertTrue(text.contains("UNKNOWN"))
        assertTrue(text.contains("#891"))
    }
}
