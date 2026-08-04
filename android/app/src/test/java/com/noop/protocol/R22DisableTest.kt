package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #174: the R22 DISABLE path — the sequence bytes, the key-aware SET_FF_VALUE(120) allowlist, and the
 * staged write→read-back run. Twin of the Swift `R22DisableTests`; keep the assertions in lockstep.
 *
 * Everything here runs with no app, no strap and no Bluetooth. That matters more than usual: the one
 * thing that CANNOT be tested off-strap is whether the firmware accepts the off value, and the design is
 * built so the run itself answers that on first use rather than assuming it.
 */
class R22DisableTest {

    // The sequence ------------------------------------------------------------------------------

    @Test
    fun disableSequenceMirrorsEnableExactly() {
        val enable = Whoop5Config.enableR22Sequence
        val disable = Whoop5Config.disableR22Sequence
        assertEquals("the undo must cover every key the enable sets", enable.size, disable.size)
        assertEquals(enable.map { it.name }, disable.map { it.name })
        assertTrue(disable.all { it.value == Whoop5Config.FEATURE_FLAG_OFF_VALUE })
    }

    @Test
    fun offValueIsAsciiZero() {
        assertEquals(0x30, Whoop5Config.FEATURE_FLAG_OFF_VALUE)
        assertEquals('0'.code, Whoop5Config.FEATURE_FLAG_OFF_VALUE)
    }

    /** The disable frame differs from the enable frame in EXACTLY one byte — the value at frame offset 44
     *  — plus the CRC32 trailer it necessarily changes. */
    @Test
    fun disableFrameDiffersFromEnableInOnlyTheValueByte() {
        val on = Whoop5Config.frame(Whoop5Config.Flag("enable_r22_packets", 0x32), 1)
        val off = Whoop5Config.frame(Whoop5Config.Flag("enable_r22_packets", 0x30), 1)
        assertEquals(on.size, off.size)
        val differing = on.indices.filter { on[it] != off[it] }
        assertEquals("the value byte sits at frame offset 44", 44, differing.first())
        assertEquals("value byte + CRC32 trailer only", 5, differing.size)
        assertEquals(0x30, off[44].toInt() and 0xFF)
    }

    @Test
    fun disableFramesVerifyAndCarryDistinctSeqs() {
        val frames = Whoop5Config.disableSequenceFrames(1)
        assertEquals(16, frames.size)
        assertEquals((1..16).toList(), frames.map { it[9].toInt() and 0xFF })
        for (f in frames) {
            assertTrue("every disable frame must pass 5/MG CRCs", Framing.frameCrcOk(f, DeviceFamily.WHOOP5))
        }
    }

    /** `disable_pip_r26_packets` gets the SAME off byte as the `enable_*` keys: this sequence is the undo
     *  of the enable sequence, not a per-key semantic inversion. Pinned because it is the one line a
     *  reviewer is most likely to "fix". */
    @Test
    fun disablePipR26GetsTheSameOffByteAsTheEnableKeys() {
        val pip = Whoop5Config.disableR22Sequence.firstOrNull { it.name == "disable_pip_r26_packets" }
        assertEquals(Whoop5Config.FEATURE_FLAG_OFF_VALUE, pip?.value)
        assertEquals(
            "and the enable value stays '2' — this key is why boolean semantics are not assumed",
            0x32,
            Whoop5Config.enableR22Sequence.firstOrNull { it.name == "disable_pip_r26_packets" }?.value,
        )
    }

    // The write gate ----------------------------------------------------------------------------

    @Test
    fun gateAdmitsOnlyOpcode120() {
        val off = byteArrayOf(0x01) + Whoop5Config.payloadBody("enable_r22_packets", 0x30)
        // Derived, never hardcoded: enable_r22_packets' enable value is '2', not '1' — the per-key values
        // are exactly what this gate is about, so a literal here would be testing the wrong byte.
        val onValue = FeatureFlagWriteGate.enableValue("enable_r22_packets")!!
        val on = byteArrayOf(0x01) + Whoop5Config.payloadBody("enable_r22_packets", onValue)
        for (opcode in 0..255) {
            assertEquals(
                "enable-direction opcode $opcode admission",
                opcode == 120,
                FeatureFlagWriteGate.admitsEnableWrite(opcode, on, deepDataOptIn = true),
            )
            assertEquals(
                "disable-direction opcode $opcode admission",
                opcode == 120,
                FeatureFlagWriteGate.admitsDisableWrite(opcode, off, disableRunInFlight = true),
            )
        }
    }

    @Test
    fun gateRefusesDeviceConfigWriteVerb() {
        val off = byteArrayOf(0x01) + Whoop5Config.payloadBody("enable_r22_packets", 0x30)
        val onValue = FeatureFlagWriteGate.enableValue("enable_r22_packets")!!
        val on = byteArrayOf(0x01) + Whoop5Config.payloadBody("enable_r22_packets", onValue)
        assertFalse(
            "119 keeps its own Broadcast-HR clause and must never be reachable from here",
            FeatureFlagWriteGate.admitsEnableWrite(119, on, deepDataOptIn = true),
        )
        assertFalse(
            "119 must be unreachable from the disable direction too",
            FeatureFlagWriteGate.admitsDisableWrite(119, off, disableRunInFlight = true),
        )
    }

    @Test
    fun enableDirectionRefusesEverythingWithoutTheOptIn() {
        for (flag in Whoop5Config.enableR22Sequence) {
            for (value in listOf(flag.value, Whoop5Config.FEATURE_FLAG_OFF_VALUE)) {
                val payload = byteArrayOf(0x01) + Whoop5Config.payloadBody(flag.name, value)
                assertFalse(
                    "${flag.name}=$value must be refused with the opt-in off",
                    FeatureFlagWriteGate.admitsEnableWrite(120, payload, deepDataOptIn = false),
                )
            }
        }
    }

    @Test
    fun disableDirectionRefusesEverythingWithoutARunInFlight() {
        for (flag in Whoop5Config.enableR22Sequence) {
            for (value in listOf(flag.value, Whoop5Config.FEATURE_FLAG_OFF_VALUE)) {
                val payload = byteArrayOf(0x01) + Whoop5Config.payloadBody(flag.name, value)
                assertFalse(
                    "${flag.name}=$value must be refused with no disable run walking its plan",
                    FeatureFlagWriteGate.admitsDisableWrite(120, payload, disableRunInFlight = false),
                )
            }
        }
    }

    @Test
    fun enableDirectionAdmitsEveryR22KeyAtItsOwnEnableValue() {
        for (flag in Whoop5Config.enableR22Sequence) {
            val payload = byteArrayOf(0x01) + Whoop5Config.payloadBody(flag.name, flag.value)
            assertTrue(
                "${flag.name}=${flag.value} must be admitted",
                FeatureFlagWriteGate.admitsEnableWrite(120, payload, deepDataOptIn = true),
            )
        }
    }

    @Test
    fun disableDirectionAdmitsEveryR22KeyAtTheOffValue() {
        for (flag in Whoop5Config.enableR22Sequence) {
            val payload = byteArrayOf(0x01) + Whoop5Config.payloadBody(flag.name, Whoop5Config.FEATURE_FLAG_OFF_VALUE)
            assertTrue(
                "${flag.name}='0' must be admitted while a run is in flight",
                FeatureFlagWriteGate.admitsDisableWrite(120, payload, disableRunInFlight = true),
            )
        }
    }

    /**
     * **The regression test for the defect this split fixes.** The Settings switch writes the preference
     * false BEFORE it raises the confirmation dialog, so every off-value write reaches the send path with
     * `deepDataOptIn == false` and the single old predicate refused all sixteen — the user tapped "Clear
     * flags on strap" and nothing left the app. The disable direction must be admitted on the run alone.
     */
    @Test
    fun offValueWritesAreAdmittedWithTheOptInOffWhileARunIsInFlight() {
        for (flag in Whoop5Config.enableR22Sequence) {
            val payload = byteArrayOf(0x01) + Whoop5Config.payloadBody(flag.name, Whoop5Config.FEATURE_FLAG_OFF_VALUE)
            assertTrue(
                "${flag.name}='0' must be admitted by the run gate — the opt-in is already false here",
                FeatureFlagWriteGate.admitsDisableWrite(120, payload, disableRunInFlight = true),
            )
            assertFalse(
                "and the enable direction must not be what admits it",
                FeatureFlagWriteGate.admitsEnableWrite(120, payload, deepDataOptIn = false),
            )
        }
    }

    /** The two directions are disjoint on value, which is what makes "an off value on the wire means a
     *  disable run is in flight" an exact invariant rather than an approximate one. */
    @Test
    fun theTwoDirectionsAreDisjointOnValue() {
        for (flag in Whoop5Config.enableR22Sequence) {
            val on = byteArrayOf(0x01) + Whoop5Config.payloadBody(flag.name, flag.value)
            val off = byteArrayOf(0x01) + Whoop5Config.payloadBody(flag.name, Whoop5Config.FEATURE_FLAG_OFF_VALUE)
            assertFalse(
                "${flag.name}: the enable direction must not admit the off value",
                FeatureFlagWriteGate.admitsEnableWrite(120, off, deepDataOptIn = true),
            )
            assertFalse(
                "${flag.name}: the disable direction must not admit the enable value",
                FeatureFlagWriteGate.admitsDisableWrite(120, on, disableRunInFlight = true),
            )
        }
    }

    /** The tightening this gate exists for: before it, opcode 120 was admitted on the opt-in alone, so ANY
     *  feature-flag key with ANY value could travel. Both halves are closed, in both directions. */
    @Test
    fun gateRefusesUnknownKeysAndUnknownValues() {
        for (key in listOf("general_ab_test", "enable_pdaf_walk_det", "enable_maverick_model", "enable_r22_v7_packets")) {
            val off = byteArrayOf(0x01) + Whoop5Config.payloadBody(key, 0x30)
            val on = byteArrayOf(0x01) + Whoop5Config.payloadBody(key, 0x31)
            assertFalse(
                "$key is not an R22 key and must be refused even at the off value",
                FeatureFlagWriteGate.admitsDisableWrite(120, off, disableRunInFlight = true),
            )
            assertFalse("$key is not an R22 key", FeatureFlagWriteGate.admitsEnableWrite(120, on, deepDataOptIn = true))
        }
        for (value in listOf(0x00, 0x29, 0x33, 0x39, 0x41, 0xFF)) {
            val payload = byteArrayOf(0x01) + Whoop5Config.payloadBody("enable_r22_packets", value)
            assertFalse(
                "value 0x%02x is not the enable value".format(value),
                FeatureFlagWriteGate.admitsEnableWrite(120, payload, deepDataOptIn = true),
            )
            assertFalse(
                "value 0x%02x is not the off value".format(value),
                FeatureFlagWriteGate.admitsDisableWrite(120, payload, disableRunInFlight = true),
            )
        }
        // enable_r22_v4_packets' enable value is '1', so '2' must be refused for THAT key specifically.
        val wrongForV4 = byteArrayOf(0x01) + Whoop5Config.payloadBody("enable_r22_v4_packets", 0x32)
        assertFalse(
            "the admitted value is per-key, not a shared pair",
            FeatureFlagWriteGate.admitsEnableWrite(120, wrongForV4, deepDataOptIn = true),
        )
    }

    @Test
    fun gateRefusesMalformedBodies() {
        val good = Whoop5Config.payloadBody("enable_r22_packets", 0x30)
        fun refusedBothWays(payload: ByteArray, why: String) {
            assertFalse(why, FeatureFlagWriteGate.admitsEnableWrite(120, payload, deepDataOptIn = true))
            assertFalse(why, FeatureFlagWriteGate.admitsDisableWrite(120, payload, disableRunInFlight = true))
        }
        refusedBothWays(byteArrayOf(0x02) + good, "wrong inner b3 byte")
        refusedBothWays(byteArrayOf(0x01) + good.copyOfRange(0, good.size - 1), "truncated")
        refusedBothWays(ByteArray(0), "empty")
        val dirty = good.copyOf(); dirty[25] = 0x41
        refusedBothWays(byteArrayOf(0x01) + dirty, "a name field whose padding is not NUL is not a name field")
        val binary = good.copyOf(); binary[3] = 0x01
        refusedBothWays(byteArrayOf(0x01) + binary, "binary in the name field")
    }

    @Test
    fun keyAndValueRoundTripsEveryR22Key() {
        for (flag in Whoop5Config.enableR22Sequence) {
            val payload = byteArrayOf(0x01) + Whoop5Config.payloadBody(flag.name, Whoop5Config.FEATURE_FLAG_OFF_VALUE)
            val parsed = FeatureFlagWriteGate.keyAndValue(payload)
            assertEquals(flag.name, parsed?.key)
            assertEquals(0x30, parsed?.value)
        }
    }

    @Test
    fun readBackOpcodeIsOnly128() {
        for (opcode in 0..255) {
            assertEquals(opcode == 128, FeatureFlagWriteGate.isReadBackOpcode(opcode))
        }
    }

    // The staged run ----------------------------------------------------------------------------

    /** A synthetic GET_FF_VALUE reply record: the key NUL-padded to 32 bytes, then the value byte. */
    private fun reply(key: String, value: Int, resultCode: Int = 1): DeviceConfigReadProbe.ValueResponse {
        val record = ByteArray(33)
        val bytes = key.toByteArray(Charsets.US_ASCII)
        for (i in bytes.indices) if (i < 32) record[i] = bytes[i]
        record[32] = (value and 0xFF).toByte()
        return DeviceConfigReadProbe.ValueResponse(resultCode, record)
    }

    private fun failureReply() = DeviceConfigReadProbe.ValueResponse(0, ByteArray(0))

    @Test
    fun planStartsWithTheProbeWriteThenItsReadBack() {
        val r = R22DisableReport()
        val first = r.nextStep()
        assertEquals(R22DisableReport.Stage.PROBE_WRITE, first?.stage)
        assertEquals(R22DisableReport.PROBE_KEY, first?.key)
        assertEquals(120, first?.opcode)
        val second = r.nextStep()
        assertEquals(R22DisableReport.Stage.PROBE_READ, second?.stage)
        assertEquals(128, second?.opcode)
    }

    /** The gate: a probe read-back still showing the old value STOPS the run with fifteen keys untouched. */
    @Test
    fun probeRejectionStopsTheRunAndLeavesFifteenKeysUntouched() {
        val r = R22DisableReport()
        val write = r.nextStep()!!
        r.noteWriteAck(1, write)                     // SUCCESS ack — deliberately not believed
        val read = r.nextStep()!!
        r.noteReadBack(reply(R22DisableReport.PROBE_KEY, 0x31), read)

        assertNull("no further steps once the off value is rejected", r.nextStep())
        assertEquals(R22DisableReport.Verdict.OFF_VALUE_REJECTED, r.verdict)
        assertEquals(R22DisableReport.KeyOutcome.UNCHANGED, r.outcomes[R22DisableReport.PROBE_KEY])
        assertEquals(15, r.keys.count { r.outcomes[it] == R22DisableReport.KeyOutcome.SKIPPED })
        assertTrue(r.render().contains("is NOT how this firmware clears a feature flag"))
        assertEquals(1, r.writeAcks[R22DisableReport.PROBE_KEY])
    }

    @Test
    fun fullRunClearsAllSixteen() {
        val r = R22DisableReport()
        var steps = 0
        while (true) {
            val step = r.nextStep() ?: break
            steps++
            assertTrue("plan must terminate", steps < 100)
            if (step.isWrite) {
                assertEquals(120, step.opcode)
                r.noteWriteAck(1, step)
            } else {
                assertEquals(128, step.opcode)
                r.noteReadBack(reply(step.key, 0x30), step)
            }
        }
        assertEquals(R22DisableReport.Verdict.ALL_CLEARED, r.verdict)
        assertEquals(16, r.keys.size)
        for (key in r.keys) assertEquals("$key should be cleared", R22DisableReport.KeyOutcome.CLEARED, r.outcomes[key])
        // 1 probe write + 1 probe read + 15 clear writes + 16 verify reads
        assertEquals(33, steps)
        assertTrue(r.summary.contains("All 16 R22 flags cleared"))
    }

    /** FAILURE on a read-back means the key no longer has a stored value at all — its own state, not
     *  folded into "cleared". */
    @Test
    fun failureReadBackIsReportedAsUnsetNotCleared() {
        val r = R22DisableReport()
        r.noteWriteAck(1, r.nextStep()!!)
        r.noteReadBack(failureReply(), r.nextStep()!!)
        assertEquals(R22DisableReport.KeyOutcome.UNSET, r.outcomes[R22DisableReport.PROBE_KEY])
        assertTrue("an unset key is a success — the run should continue", r.probePassed)
        assertNotNull("the clear stage must follow a passing probe", r.nextStep())
    }

    @Test
    fun partialRunIsReportedAsPartialNotSuccess() {
        val r = R22DisableReport()
        while (true) {
            val step = r.nextStep() ?: break
            when {
                step.isWrite -> r.noteWriteAck(1, step)
                step.key == "wear_detect_bias" -> r.noteReadBack(reply(step.key, 0x32), step)
                else -> r.noteReadBack(reply(step.key, 0x30), step)
            }
        }
        assertEquals(R22DisableReport.Verdict.PARTIAL, r.verdict)
        assertEquals(R22DisableReport.KeyOutcome.UNCHANGED, r.outcomes["wear_detect_bias"])
        assertTrue(r.summary.contains("15 of 16"))
    }

    /** A SUCCESS ack whose read-back did not move must never render as success — the #907/#891 rule. */
    @Test
    fun successAckWithUnmovedValueIsNeverReportedAsSuccess() {
        val r = R22DisableReport()
        r.noteWriteAck(1, r.nextStep()!!)
        r.noteReadBack(reply(R22DisableReport.PROBE_KEY, 0x31), r.nextStep()!!)
        val text = r.render()
        assertFalse(r.verdict == R22DisableReport.Verdict.ALL_CLEARED)
        assertTrue(text.contains("recorded, not proof"))
        assertTrue(text.contains("NOT treated as proof"))
    }

    @Test
    fun silentProbeStopsTheRun() {
        val r = R22DisableReport()
        val write = r.nextStep()!!
        r.noteTimeout(write, 8)
        assertNull("a silent WRITE decides nothing — only the read-back does", r.outcomes[R22DisableReport.PROBE_KEY])
        r.noteTimeout(r.nextStep()!!, 8)
        assertEquals(R22DisableReport.Verdict.PROBE_INCONCLUSIVE, r.verdict)
        assertNull(r.nextStep())
    }

    @Test
    fun abandonMarksRemainingKeysSkipped() {
        val r = R22DisableReport()
        r.noteWriteAck(1, r.nextStep()!!)
        r.noteAbandoned("link dropped")
        assertEquals(R22DisableReport.Verdict.ABANDONED, r.verdict)
        assertNull(r.nextStep())
        assertEquals(16, r.keys.count { r.outcomes[it] == R22DisableReport.KeyOutcome.SKIPPED })
    }

    @Test
    fun undecodableReadBackIsNotTreatedAsCleared() {
        val r = R22DisableReport()
        r.noteWriteAck(1, r.nextStep()!!)
        r.noteReadFailure(DeviceConfigReadProbe.ParseFailure.CRC, r.nextStep()!!)
        assertEquals(R22DisableReport.KeyOutcome.UNDECODABLE, r.outcomes[R22DisableReport.PROBE_KEY])
        assertFalse(r.probePassed)
        assertEquals(R22DisableReport.Verdict.PROBE_INCONCLUSIVE, r.verdict)
    }

    /** The report must state the four standing caveats, so the log, the UI and the PR cannot drift on what
     *  was actually established. */
    @Test
    fun renderCarriesTheCaveats() {
        val r = R22DisableReport()
        while (true) {
            val step = r.nextStep() ?: break
            if (step.isWrite) r.noteWriteAck(1, step) else r.noteReadBack(reply(step.key, 0x30), step)
        }
        val text = r.render()
        assertTrue(text.contains("'0' as the off value is INFERRED"))
        assertTrue(text.contains("not the same as reverted BEHAVIOUR"))
        assertTrue(text.contains("does not restore a snapshot"))
        assertTrue(text.contains("disable_pip_r26_packets inverts"))
        for (key in r.keys) assertTrue("$key missing from the report", text.contains(key))
    }

    @Test
    fun probeKeyIsTheOneWithAHardwareWriteDemonstration() {
        assertEquals("enable_sig12", R22DisableReport.PROBE_KEY)
        assertTrue(Whoop5Config.enableR22Sequence.any { it.name == R22DisableReport.PROBE_KEY })
    }

    // Fail-closed when the probe key is absent --------------------------------------------------

    /**
     * A key list without the probe key used to plan a blanket sixteen-write and set probePassed = true.
     * That is fail-open on the one write path whose entire safety argument is the probe: it would write an
     * INFERRED value to every persistent flag without ever testing it on one, and record a passed gate for
     * a probe that never ran. It must refuse instead.
     */
    @Test
    fun aKeyListWithoutTheProbeKeyRefusesToWriteAnything() {
        val r = R22DisableReport(listOf("enable_r22_packets", "enable_r22_v4_packets", "enable_r22_v5_packets"))
        assertNull("no step may be planned without the probe key", r.nextStep())
        assertFalse("probePassed must not record a probe that never ran", r.probePassed)
        assertEquals(R22DisableReport.Verdict.PROBE_UNAVAILABLE, r.verdict)
        for (key in r.keys) {
            assertEquals("$key must be reported as skipped, not written", R22DisableReport.KeyOutcome.SKIPPED, r.outcomes[key])
        }
        assertTrue("the report must say nothing was sent", r.render().contains("REFUSED"))
        assertNull(r.nextStep())
    }

    /** An empty key list is the degenerate case of the same thing. */
    @Test
    fun anEmptyKeyListRefusesToWriteAnything() {
        val r = R22DisableReport(emptyList())
        assertNull(r.nextStep())
        assertFalse(r.probePassed)
        assertEquals(R22DisableReport.Verdict.PROBE_UNAVAILABLE, r.verdict)
    }

    /** The shipped call sites are unaffected: the default key list contains the probe key. */
    @Test
    fun theDefaultKeyListStillPlansTheProbe() {
        val r = R22DisableReport()
        assertEquals(R22DisableReport.Stage.PROBE_WRITE, r.nextStep()?.stage)
        assertNotEquals(R22DisableReport.Verdict.PROBE_UNAVAILABLE, r.verdict)
    }

    /** Cross-platform parity: the Swift and Kotlin reports must render the same verdict labels, or a
     *  shared strap log reads differently on the two platforms. */
    @Test
    fun verdictAndOutcomeLabelsMatchTheSwiftSpelling() {
        assertEquals("allCleared", R22DisableReport.Verdict.ALL_CLEARED.label)
        assertEquals("partial", R22DisableReport.Verdict.PARTIAL.label)
        assertEquals("offValueRejected", R22DisableReport.Verdict.OFF_VALUE_REJECTED.label)
        assertEquals("probeInconclusive", R22DisableReport.Verdict.PROBE_INCONCLUSIVE.label)
        assertEquals("probeUnavailable", R22DisableReport.Verdict.PROBE_UNAVAILABLE.label)
        assertEquals("abandoned", R22DisableReport.Verdict.ABANDONED.label)
        assertEquals("cleared", R22DisableReport.KeyOutcome.CLEARED.label)
        assertEquals("unset", R22DisableReport.KeyOutcome.UNSET.label)
        assertEquals("unchanged", R22DisableReport.KeyOutcome.UNCHANGED.label)
        assertEquals("notClaimed", R22DisableReport.KeyOutcome.NOT_CLAIMED.label)
        assertEquals("skipped", R22DisableReport.KeyOutcome.SKIPPED.label)
    }
}
