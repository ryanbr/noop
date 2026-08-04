package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #103: byte-parity twin of the Swift `DeviceConfigReadProbeTests` — same synthetic fixtures, same
 * expectations — for the read-only device-config read probe. Fixtures are SYNTHETIC (built here with
 * real CRCs) because no strap has ever answered opcode 121 or 128 in this project's hands; establishing
 * whether one does is what the probe is for. They pin the allowlist, the decode, the plan and the
 * report, including every "the verb is not implemented" path the BLE handler must survive.
 */
class DeviceConfigReadProbeTest {

    /** WHOOP 4.0 COMMAND_RESPONSE: [0xAA][len u16 LE][crc8(len)][type=36][seq][cmd][payload…][crc32 LE]. */
    private fun whoop4Response(cmd: Int, payload: ByteArray, seq: Int = 1): ByteArray {
        val inner = byteArrayOf(36, seq.toByte(), cmd.toByte()) + payload
        val length = inner.size + 4
        val lenBytes = byteArrayOf((length and 0xFF).toByte(), ((length shr 8) and 0xFF).toByte())
        val c = Crc.crc32(inner)
        return byteArrayOf(0xAA.toByte()) + lenBytes + byteArrayOf(Crc.crc8(lenBytes).toByte()) + inner +
            byteArrayOf(
                (c and 0xFFL).toByte(), ((c shr 8) and 0xFFL).toByte(),
                ((c shr 16) and 0xFFL).toByte(), ((c shr 24) and 0xFFL).toByte(),
            )
    }

    /** WHOOP 5/MG COMMAND_RESPONSE in the puffin envelope: type @8, seq @9, cmd @10, record from @11. */
    private fun whoop5Response(cmd: Int, payload: ByteArray, seq: Int = 1): ByteArray {
        var inner = byteArrayOf(36, seq.toByte(), cmd.toByte()) + payload
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

    /** The 2-byte response header every COMMAND_RESPONSE carries, then the record. */
    private fun payload(result: Int, record: ByteArray): ByteArray =
        byteArrayOf(0x0A, result.toByte()) + record

    /** A record shaped like the SET side's body: the key NUL-padded to 32 bytes, then the value byte. */
    private fun echoRecord(key: String, value: Int, lead: ByteArray = ByteArray(0)): ByteArray {
        val field = ByteArray(DeviceConfigReadProbe.NAME_FIELD_BYTES)
        val bytes = key.toByteArray(Charsets.UTF_8)
        for (i in 0 until minOf(field.size, bytes.size)) field[i] = bytes[i]
        return lead + field + byteArrayOf(value.toByte())
    }

    private val flagKeys: List<String> get() = Whoop5Config.enableR22Sequence.map { it.name }

    private fun report(
        family: DeviceFamily = DeviceFamily.WHOOP5,
        flags: List<String> = flagKeys,
        candidates: List<String> = DeviceConfigReadProbe.OXYGEN_CANDIDATE_KEYS,
    ) = DeviceConfigReadProbeReport(family, flags, candidates)

    // MARK: - The read-only allowlist (the hard safety constraint)

    @Test
    fun allowlistAdmitsOnlyTheTwoReadVerbs() {
        assertEquals(121, DeviceConfigReadProbe.GET_DEVICE_CONFIG_VALUE_CMD)   // 0x79
        assertEquals(128, DeviceConfigReadProbe.GET_FEATURE_FLAG_VALUE_CMD)    // 0x80
        assertEquals(setOf(121, 128), DeviceConfigReadProbe.READ_ONLY_OPCODES)
        assertTrue(DeviceConfigReadProbe.isReadOnlyOpcode(121))
        assertTrue(DeviceConfigReadProbe.isReadOnlyOpcode(128))
    }

    /**
     * The load-bearing safety test: the two config WRITE verbs must be rejected by the same predicate
     * the BLE send path consults while a probe is in flight.
     */
    @Test
    fun allowlistRejectsBothConfigWriteVerbs() {
        assertEquals(119, DeviceConfigReadProbe.SET_DEVICE_CONFIG_VALUE_CMD)   // 0x77
        assertEquals(120, DeviceConfigReadProbe.SET_FEATURE_FLAG_VALUE_CMD)    // 0x78
        assertFalse(DeviceConfigReadProbe.isReadOnlyOpcode(119))
        assertFalse(DeviceConfigReadProbe.isReadOnlyOpcode(120))
        assertFalse(DeviceConfigReadProbe.isReadOnlyOpcode(Whoop5Config.SET_CONFIG_CMD))         // 0x78
        assertFalse(DeviceConfigReadProbe.isReadOnlyOpcode(Whoop5Config.SET_DEVICE_CONFIG_CMD))  // 0x77
        for (op in DeviceConfigReadProbe.WRITE_OPCODES) {
            assertFalse(DeviceConfigReadProbe.isReadOnlyOpcode(op))
        }
        assertTrue(
            DeviceConfigReadProbe.READ_ONLY_OPCODES.intersect(DeviceConfigReadProbe.WRITE_OPCODES).isEmpty(),
        )
    }

    /** Nothing outside the pair passes either — including the #761 enumerate verbs and the destructive
     *  opcodes that must never come near this path. */
    @Test
    fun allowlistRejectsEveryOtherOpcode() {
        for (op in 0..255) {
            if (DeviceConfigReadProbe.READ_ONLY_OPCODES.contains(op)) continue
            assertFalse("opcode $op must not pass", DeviceConfigReadProbe.isReadOnlyOpcode(op))
        }
        assertFalse(DeviceConfigReadProbe.isReadOnlyOpcode(FeatureFlagProbe.START_KEY_EXCHANGE_CMD))
        assertFalse(DeviceConfigReadProbe.isReadOnlyOpcode(FeatureFlagProbe.SEND_NEXT_FLAG_CMD))
        assertFalse(DeviceConfigReadProbe.isReadOnlyOpcode(25))   // FORCE_TRIM
        assertFalse(DeviceConfigReadProbe.isReadOnlyOpcode(29))   // REBOOT_STRAP
    }

    // MARK: - Request body

    @Test
    fun requestBodyIsTheB3ByteThenA32ByteNulPaddedName() {
        val body = DeviceConfigReadProbe.requestBody("enable_spo2")
        assertEquals(33, body.size)
        assertEquals(0x01, body[0].toInt())
        assertEquals("enable_spo2", String(body.copyOfRange(1, 12), Charsets.UTF_8))
        assertTrue(body.copyOfRange(12, body.size).all { it.toInt() == 0 })
        // It carries no value byte — that is exactly what separates it from the SET bodies.
        assertEquals(33, Whoop5Config.deviceConfigBody("enable_spo2", 0x31).size)
        assertFalse(
            body.copyOfRange(1, body.size).contentEquals(Whoop5Config.deviceConfigBody("enable_spo2", 0x31)),
        )
    }

    @Test
    fun requestBodyTruncatesAnOverlongNameLikeTheSetSide() {
        val body = DeviceConfigReadProbe.requestBody("z".repeat(40))
        assertEquals(33, body.size)
        assertTrue(body.copyOfRange(1, body.size).all { (it.toInt() and 0xFF) == 0x7A })
    }

    // MARK: - Parsing

    @Test
    fun parseDecodesTheRecordAndResultCodeOnWhoop5() {
        val record = echoRecord("enable_r22_packets", 0x32, byteArrayOf(0x01))
        val frame = whoop5Response(128, payload(1, record))
        val r = DeviceConfigReadProbe.parse(frame, DeviceFamily.WHOOP5, 128).value
        assertNotNull(r)
        assertEquals(1, r!!.resultCode)
        assertFalse(r.isUnsupported)
        assertEquals(0x32, r.valueFor("enable_r22_packets"))
        assertEquals(1, r.echoOffset("enable_r22_packets"))
    }

    @Test
    fun parseOnWhoop4LeavesTheResultCodeUnlabelled() {
        val frame = whoop4Response(121, payload(1, echoRecord("k", 0x31)))
        val r = DeviceConfigReadProbe.parse(frame, DeviceFamily.WHOOP4, 121).value
        assertNotNull(r)
        assertNull(r!!.resultCode)
        assertEquals(0x31, r.valueFor("k"))
    }

    @Test
    fun unsupportedResultIsRecognised() {
        val frame = whoop5Response(121, payload(3, byteArrayOf(0, 0, 0)))
        val r = DeviceConfigReadProbe.parse(frame, DeviceFamily.WHOOP5, 121).value
        assertNotNull(r)
        assertTrue(r!!.isUnsupported)
        assertNull(r.valueFor("whatever"))
    }

    @Test
    fun noValueIsClaimedWhenTheReplyDoesNotEchoTheKey() {
        val frame = whoop5Response(128, payload(1, echoRecord("some_other_key", 0x32)))
        val r = DeviceConfigReadProbe.parse(frame, DeviceFamily.WHOOP5, 128).value
        assertNotNull(r)
        assertNull(r!!.valueFor("enable_spo2"))
        assertNull(r.echoOffset("enable_spo2"))
    }

    @Test
    fun keyMustSitInARealNulPaddedFieldNotJustAppearInTheBytes() {
        // "enable_spo2" appears, but immediately followed by more text — so it is not the 32-byte field.
        val record = "enable_spo2_extra_suffix_bytes__".toByteArray(Charsets.UTF_8) + byteArrayOf(0x31)
        val frame = whoop5Response(121, payload(1, record))
        val r = DeviceConfigReadProbe.parse(frame, DeviceFamily.WHOOP5, 121).value
        assertNotNull(r)
        assertNull("a substring match is not a name field", r!!.valueFor("enable_spo2"))
    }

    /**
     * On WHOOP 4.0, where the envelope adds no padding, a record that ends at the name field yields no
     * value at all. (On 5/MG the puffin envelope pads the inner payload to a 4-byte boundary, so the
     * same record would carry up to three trailing NULs that are envelope padding, not data.)
     */
    @Test
    fun valueIsNotClaimedWhenTheRecordStopsAtTheNameField() {
        val field = ByteArray(32)
        "enable_spo2".toByteArray(Charsets.UTF_8).forEachIndexed { i, b -> field[i] = b }
        val frame = whoop4Response(121, payload(1, field))
        val r = DeviceConfigReadProbe.parse(frame, DeviceFamily.WHOOP4, 121).value
        assertNotNull(r)
        assertEquals(0, r!!.echoOffset("enable_spo2"))
        assertNull("null is 'no value claimed', never 'value is zero'", r.valueFor("enable_spo2"))
    }

    // MARK: - Failure paths (the handler must survive every one)

    @Test
    fun badCrcIsRejected() {
        val frame = whoop4Response(121, payload(1, echoRecord("k", 0x31)))
        frame[frame.size - 1] = (frame[frame.size - 1].toInt() xor 0xFF).toByte()
        assertEquals(
            DeviceConfigReadProbe.ParseFailure.CRC,
            DeviceConfigReadProbe.parse(frame, DeviceFamily.WHOOP4, 121).failure,
        )

        val five = whoop5Response(128, payload(1, echoRecord("k", 0x31)))
        five[7] = (five[7].toInt() xor 0xFF).toByte()
        assertEquals(
            DeviceConfigReadProbe.ParseFailure.CRC,
            DeviceConfigReadProbe.parse(five, DeviceFamily.WHOOP5, 128).failure,
        )

        assertEquals(
            DeviceConfigReadProbe.ParseFailure.CRC,
            DeviceConfigReadProbe.parse(ByteArray(0), DeviceFamily.WHOOP4, 121).failure,
        )
    }

    @Test
    fun wrongCommandAndWrongTypeAreRejected() {
        val frame = whoop4Response(128, payload(1, echoRecord("k", 0x31)))
        assertEquals(
            DeviceConfigReadProbe.ParseFailure.WRONG_COMMAND,
            DeviceConfigReadProbe.parse(frame, DeviceFamily.WHOOP4, 121).failure,
        )

        // Same bytes, but the packet type is COMMAND (35) rather than COMMAND_RESPONSE (36).
        val inner = byteArrayOf(35, 1, 121.toByte()) + payload(1, byteArrayOf(0x01, 0x02))
        val length = inner.size + 4
        val lenBytes = byteArrayOf((length and 0xFF).toByte(), ((length shr 8) and 0xFF).toByte())
        val c = Crc.crc32(inner)
        val wrong = byteArrayOf(0xAA.toByte()) + lenBytes + byteArrayOf(Crc.crc8(lenBytes).toByte()) +
            inner + byteArrayOf(
            (c and 0xFFL).toByte(), ((c shr 8) and 0xFFL).toByte(),
            ((c shr 16) and 0xFFL).toByte(), ((c shr 24) and 0xFFL).toByte(),
        )
        assertEquals(
            DeviceConfigReadProbe.ParseFailure.ENVELOPE,
            DeviceConfigReadProbe.parse(wrong, DeviceFamily.WHOOP4, 121).failure,
        )
    }

    @Test
    fun truncatedRecordIsRejected() {
        val header = whoop4Response(121, byteArrayOf(0x0A, 0x01))
        assertEquals(
            DeviceConfigReadProbe.ParseFailure.TRUNCATED,
            DeviceConfigReadProbe.parse(header, DeviceFamily.WHOOP4, 121).failure,
        )
    }

    // MARK: - The plan

    @Test
    fun discoveryTriesEachVerbOnceBeforeAnythingElse() {
        val rep = report()
        val first = rep.nextStep()!!
        assertEquals(128, first.opcode)
        assertEquals("enable_r22_packets", first.key)
        assertEquals(DeviceConfigReadProbeReport.Group.DISCOVERY, first.group)

        val second = rep.nextStep()!!
        assertEquals(121, second.opcode)
        assertEquals(DeviceConfigReadProbe.DEVICE_CONFIG_DISCOVERY_KEY, second.key)
        assertEquals(DeviceConfigReadProbeReport.Group.DISCOVERY, second.group)
    }

    @Test
    fun bothVerbsUnsupportedEndsTheProbeAfterTwoRoundTrips() {
        val rep = report()
        repeat(2) {
            val step = rep.nextStep()!!
            val frame = whoop5Response(step.opcode, payload(3, byteArrayOf(0, 0, 0)))
            val r = DeviceConfigReadProbe.parse(frame, DeviceFamily.WHOOP5, step.opcode).value!!
            rep.noteReply(r, step)
        }
        assertNull("a refused verb must not drive sixteen more round-trips", rep.nextStep())
        assertEquals(2, rep.steps)
        assertEquals(DeviceConfigReadProbeReport.VerbStatus.UNSUPPORTED, rep.featureFlagVerb)
        assertEquals(DeviceConfigReadProbeReport.VerbStatus.UNSUPPORTED, rep.deviceConfigVerb)
        // The one run that supports the strong sentence: the firmware itself refused both verbs.
        assertEquals(
            "neither GET_FF_VALUE(128) nor GET_DEVICE_CONFIG_VALUE(121) is served by this " +
                "firmware — rejected as UNSUPPORTED",
            rep.verdict,
        )
        assertTrue(rep.render().contains("neither GET_FF_VALUE(128) nor GET_DEVICE_CONFIG_VALUE(121)"))
    }

    /**
     * Two timeouts are two timeouts. The send path returns without transmitting when the command
     * characteristic is missing and again when the 5/MG allowlist does not carry the opcode, so a run in
     * which nothing reached the strap must not print a claim about what the firmware serves.
     */
    @Test
    fun silentVerbsEndTheProbeAndAreSaidPlainly() {
        val rep = report()
        repeat(2) { rep.noteTimeout(rep.nextStep()!!, 8) }
        assertNull(rep.nextStep())
        assertEquals(DeviceConfigReadProbeReport.VerbStatus.SILENT, rep.featureFlagVerb)
        assertEquals(DeviceConfigReadProbeReport.VerbStatus.SILENT, rep.deviceConfigVerb)
        assertEquals(
            "no read verb answered — GET_FF_VALUE(128) served no reply in 8s — unconfirmed; " +
                "GET_DEVICE_CONFIG_VALUE(121) served no reply in 8s — unconfirmed",
            rep.verdict,
        )
        val text = rep.render()
        assertFalse(
            "silence is not the firmware answering — it is not even proof a frame was sent",
            text.contains("served by this firmware"),
        )
        assertFalse("nothing was refused; nothing replied at all", text.contains("UNSUPPORTED"))
        assertTrue(text.contains("no COMMAND_RESPONSE within 8s"))
        assertTrue(text.contains("(none — the verb that would carry them did not answer)"))
    }

    /**
     * One verb refused and the other timed out: the refusal belongs to the verb that was refused. The old
     * `||` printed "neither … is served by this firmware — rejected as UNSUPPORTED" over a 121 that was
     * never refused, only never heard from.
     */
    @Test
    fun oneRefusalIsNotGeneralisedToTheVerbThatWasNeverHeardFrom() {
        val rep = report()
        val s128 = rep.nextStep()!!
        assertEquals(128, s128.opcode)
        rep.noteReply(DeviceConfigReadProbe.ValueResponse(3, byteArrayOf(0)), s128)
        val s121 = rep.nextStep()!!
        assertEquals(121, s121.opcode)
        rep.noteTimeout(s121, 8)

        assertNull(rep.nextStep())
        assertEquals(DeviceConfigReadProbeReport.VerbStatus.UNSUPPORTED, rep.featureFlagVerb)
        assertEquals(DeviceConfigReadProbeReport.VerbStatus.SILENT, rep.deviceConfigVerb)
        assertEquals(
            "no read verb answered — GET_FF_VALUE(128) refused by firmware (UNSUPPORTED); " +
                "GET_DEVICE_CONFIG_VALUE(121) served no reply in 8s — unconfirmed",
            rep.verdict,
        )
        assertFalse(
            "one refusal does not speak for the other verb",
            rep.render().contains("neither GET_FF_VALUE(128) nor GET_DEVICE_CONFIG_VALUE(121)"),
        )
    }

    /**
     * An undecodable reply is affirmative evidence the strap DID transmit, so "not served by this
     * firmware" states the opposite of what the run observed.
     */
    @Test
    fun anUndecodableReplyIsNotReportedAsUnserved() {
        val rep = report(candidates = emptyList())
        rep.noteFailure(DeviceConfigReadProbe.ParseFailure.CRC, rep.nextStep()!!)
        rep.noteFailure(DeviceConfigReadProbe.ParseFailure.ENVELOPE, rep.nextStep()!!)

        assertEquals(DeviceConfigReadProbeReport.VerbStatus.UNDECODABLE, rep.featureFlagVerb)
        assertEquals(DeviceConfigReadProbeReport.VerbStatus.UNDECODABLE, rep.deviceConfigVerb)
        assertEquals(
            "no read verb answered — " +
                "GET_FF_VALUE(128) replied but the frame did not decode — unconfirmed; " +
                "GET_DEVICE_CONFIG_VALUE(121) replied but the frame did not decode — unconfirmed",
            rep.verdict,
        )
        assertFalse(rep.render().contains("served by this firmware"))
    }

    /**
     * A probe that ended before either verb went out says so, rather than reporting an empty run as a
     * finding about the firmware.
     */
    @Test
    fun aProbeThatAskedNothingClaimsNothing() {
        val rep = report(candidates = emptyList())
        assertEquals(DeviceConfigReadProbeReport.VerbStatus.UNTRIED, rep.featureFlagVerb)
        assertEquals(DeviceConfigReadProbeReport.VerbStatus.UNTRIED, rep.deviceConfigVerb)
        assertEquals(
            "no read verb answered — GET_FF_VALUE(128) not asked; GET_DEVICE_CONFIG_VALUE(121) not asked",
            rep.verdict,
        )
    }

    @Test
    fun anAnsweringFeatureFlagVerbWalksTheFifteenRemainingKnownFlags() {
        val rep = report()
        val s128 = rep.nextStep()!!
        rep.noteReply(
            DeviceConfigReadProbe.ValueResponse(1, echoRecord(s128.key, 0x32, byteArrayOf(0x01))), s128,
        )
        val s121 = rep.nextStep()!!
        rep.noteReply(DeviceConfigReadProbe.ValueResponse(3, byteArrayOf(0)), s121)

        val flagSteps = mutableListOf<String>()
        val candidateSteps = mutableListOf<String>()
        while (true) {
            val step = rep.nextStep() ?: break
            assertEquals("the refused verb must never be sent again", 128, step.opcode)
            when (step.group) {
                DeviceConfigReadProbeReport.Group.KNOWN_FLAG -> flagSteps.add(step.key)
                DeviceConfigReadProbeReport.Group.CANDIDATE -> candidateSteps.add(step.key)
                DeviceConfigReadProbeReport.Group.DISCOVERY -> throw AssertionError("discovery is over")
            }
            rep.noteReply(
                DeviceConfigReadProbe.ValueResponse(1, echoRecord(step.key, 0x31, byteArrayOf(0x01))), step,
            )
        }
        assertEquals(flagKeys.drop(1), flagSteps)
        assertEquals(DeviceConfigReadProbe.OXYGEN_CANDIDATE_KEYS, candidateSteps)
        assertEquals(2 + 15 + DeviceConfigReadProbe.OXYGEN_CANDIDATE_KEYS.size, rep.steps)
    }

    @Test
    fun candidatesPreferTheDeviceConfigVerbWhenBothAnswer() {
        val rep = report(flags = listOf("only_flag"), candidates = listOf("enable_spo2"))
        val a = rep.nextStep()!!
        rep.noteReply(DeviceConfigReadProbe.ValueResponse(1, echoRecord(a.key, 0x32)), a)
        val b = rep.nextStep()!!
        rep.noteReply(DeviceConfigReadProbe.ValueResponse(1, echoRecord(b.key, 0x31)), b)

        val c = rep.nextStep()!!
        assertEquals(DeviceConfigReadProbeReport.Group.CANDIDATE, c.group)
        assertEquals(121, c.opcode)
        assertEquals("enable_spo2", c.key)
    }

    @Test
    fun thePlanIsCappedEvenWithAnAbsurdKeyList() {
        val many = (0 until 500).map { "key_$it" }
        val rep = report(family = DeviceFamily.WHOOP4, flags = many, candidates = many)
        var seen = 0
        while (true) {
            val step = rep.nextStep() ?: break
            seen += 1
            assertTrue("the plan must terminate", seen <= DeviceConfigReadProbe.MAX_STEPS + 1)
            rep.noteReply(DeviceConfigReadProbe.ValueResponse(null, echoRecord(step.key, 0x31)), step)
        }
        assertEquals(DeviceConfigReadProbe.MAX_STEPS, seen)
        assertEquals("safety cap of 64 round-trips reached", rep.stopReason)
    }

    @Test
    fun anUndecodableReplyRetiresTheVerb() {
        val rep = report(candidates = emptyList())
        val step = rep.nextStep()!!
        rep.noteFailure(DeviceConfigReadProbe.ParseFailure.CRC, step)
        assertEquals(DeviceConfigReadProbeReport.VerbStatus.UNDECODABLE, rep.featureFlagVerb)
        val next = rep.nextStep()!!
        assertEquals("the undecodable verb is not retried", 121, next.opcode)
        rep.noteTimeout(next, 8)
        assertNull(rep.nextStep())
        assertEquals("CRC failed — frame rejected (never decoded)", rep.stopReason)
    }

    @Test
    fun aVerdictAlreadyReachedIsNotRewrittenByALaterReply() {
        val rep = report(flags = listOf("a", "b"), candidates = emptyList())
        val first = rep.nextStep()!!
        rep.noteReply(DeviceConfigReadProbe.ValueResponse(1, echoRecord("a", 0x31)), first)
        assertEquals(DeviceConfigReadProbeReport.VerbStatus.ANSWERED, rep.featureFlagVerb)
        val second = rep.nextStep()!!
        rep.noteReply(DeviceConfigReadProbe.ValueResponse(3, byteArrayOf(0)), second)
        assertEquals(DeviceConfigReadProbeReport.VerbStatus.UNSUPPORTED, rep.deviceConfigVerb)
        rep.noteReply(DeviceConfigReadProbe.ValueResponse(1, byteArrayOf(0)), second)
        assertEquals(
            "a refusal is not upgraded away",
            DeviceConfigReadProbeReport.VerbStatus.UNSUPPORTED, rep.deviceConfigVerb,
        )
    }

    // MARK: - Report

    @Test
    fun candidateKeysAreLabelledAsGuesses() {
        val rep = report(flags = listOf("f"), candidates = listOf("enable_spo2"))
        val a = rep.nextStep()!!
        rep.noteReply(DeviceConfigReadProbe.ValueResponse(1, echoRecord("f", 0x32)), a)
        val b = rep.nextStep()!!
        rep.noteReply(DeviceConfigReadProbe.ValueResponse(1, echoRecord(b.key, 0x31)), b)
        val c = rep.nextStep()!!
        rep.noteReply(DeviceConfigReadProbe.ValueResponse(0, byteArrayOf(0)), c)
        val text = rep.render()
        assertTrue(text.contains("Candidate oxygen keys — GUESSES, never observed on a wire or in any table"))
        assertTrue(text.contains("enable_spo2"))
        assertTrue(text.contains("no value (result=FAILURE(0))"))
    }

    @Test
    fun oxygenCandidateListIsShortAndOxygenNamed() {
        val keys = DeviceConfigReadProbe.OXYGEN_CANDIDATE_KEYS
        assertTrue(keys.isNotEmpty())
        assertTrue("keep the guess list short — it is a guess list", keys.size <= 12)
        assertEquals(keys.size, keys.toSet().size)
        for (k in keys) {
            assertTrue(
                "$k does not read as oxygen-related",
                k.contains("spo2") || k.contains("oxygen") || k.contains("pulse_ox"),
            )
            assertTrue(
                "$k would be truncated by the 32-byte name field",
                k.toByteArray(Charsets.UTF_8).size <= DeviceConfigReadProbe.NAME_FIELD_BYTES,
            )
        }
    }

    /**
     * GOLDEN: the exact rendered report, byte-for-byte. Its Swift twin
     * (`DeviceConfigReadProbeTests.testGoldenReportIsByteIdenticalAcrossPlatforms`) asserts the SAME
     * literal, so a strap log reads identically on either platform.
     *
     * The first record's trailing `00`, and the seven-byte UNSUPPORTED record, are the puffin envelope's
     * 4-byte inner padding showing through — which is exactly why the value is read as "the byte after
     * the echoed name field" and not "the last byte of the record".
     */
    @Test
    fun goldenReportIsByteIdenticalAcrossPlatforms() {
        val rep = report(flags = listOf("enable_r22_packets", "hr_ch_switching"), candidates = listOf("enable_spo2"))

        val s1 = rep.nextStep()!!
        val f1 = whoop5Response(128, payload(1, echoRecord("enable_r22_packets", 0x32, byteArrayOf(0x01))))
        rep.noteReply(DeviceConfigReadProbe.parse(f1, DeviceFamily.WHOOP5, 128).value!!, s1)

        val s2 = rep.nextStep()!!
        val f2 = whoop5Response(121, payload(3, byteArrayOf(0, 0, 0, 0)))
        rep.noteReply(DeviceConfigReadProbe.parse(f2, DeviceFamily.WHOOP5, 121).value!!, s2)

        val s3 = rep.nextStep()!!
        rep.noteReply(
            DeviceConfigReadProbe.ValueResponse(1, echoRecord("hr_ch_switching", 0x32, byteArrayOf(0x01))), s3,
        )

        val s4 = rep.nextStep()!!
        rep.noteReply(DeviceConfigReadProbe.ValueResponse(0, byteArrayOf(0x01, 0x00)), s4)
        assertNull(rep.nextStep())

        val golden = "#103 DEVICE-CONFIG READ PROBE — WHOOP 5/MG\n" +
            "Read-only: GET_DEVICE_CONFIG_VALUE(121) + GET_FF_VALUE(128). No value is written; " +
            "SET_DEVICE_CONFIG_VALUE(119) and SET_FF_VALUE(120) are never sent from this path.\n" +
            "Follow-up to the #761 enumeration probe: that one asked for key NAMES, this asks for VALUES.\n" +
            "\n" +
            "Verdict: 1 of 2 read verbs answered; read 2 config value(s)\n" +
            "\n" +
            "Read verbs:\n" +
            "  GET_FF_VALUE(128)             answered\n" +
            "  GET_DEVICE_CONFIG_VALUE(121)  unsupported\n" +
            "\n" +
            "Discovery — one round-trip per verb against a key it should know (2):\n" +
            "   1. enable_r22_packets              = '2' (0x32)\n" +
            "   2. whoop_live_hr_in_adv_ind_pkt    — no value (result=UNSUPPORTED(3))\n" +
            "\n" +
            "Known feature-flag values (names NOOP already writes; values never read before) (1):\n" +
            "   1. hr_ch_switching                 = '2' (0x32)\n" +
            "\n" +
            "Candidate oxygen keys — GUESSES, never observed on a wire or in any table (1):\n" +
            "   1. enable_spo2                     — no value (result=FAILURE(0))\n" +
            "\n" +
            "Exchange:\n" +
            "  GET_FF_VALUE(128) key=\"enable_r22_packets\" → result=SUCCESS(1) value='2' (0x32) " +
            "record=[01 65 6e 61 62 6c 65 5f 72 32 32 5f 70 61 63 6b 65 74 73 00 00 00 00 00 00 00 00 00 " +
            "00 00 00 00 00 32 00]\n" +
            "  GET_DEVICE_CONFIG_VALUE(121) key=\"whoop_live_hr_in_adv_ind_pkt\" → " +
            "result=UNSUPPORTED(3) record=[00 00 00 00 00 00 00]\n" +
            "  GET_FF_VALUE(128) key=\"hr_ch_switching\" → result=SUCCESS(1) value='2' (0x32) " +
            "record=[01 68 72 5f 63 68 5f 73 77 69 74 63 68 69 6e 67 00 00 00 00 00 00 00 00 00 00 00 00 " +
            "00 00 00 00 00 32]\n" +
            "  GET_FF_VALUE(128) key=\"enable_spo2\" → result=FAILURE(0) record=[01 00]\n"
        assertEquals(golden, rep.render())
    }
}
