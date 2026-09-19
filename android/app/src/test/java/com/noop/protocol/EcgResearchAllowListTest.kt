package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The panel's dispatch surface is a positive allow-list of four ECG opcodes. These tests pin that it can
 * NEVER form anything else — most importantly the firmware-load family that sits three codes above 139.
 */
class EcgResearchAllowListTest {

    @Test
    fun theFourProbeOpcodesAreExactlyTheLabradorCommands() {
        assertEquals(
            setOf(123, 124, 125, 139),
            EcgResearchAllowList.PROBE_OPCODES,
        )
        assertTrue(EcgResearchAllowList.isProbeOpcode(Whoop5Ecg.SELECT_WRIST_CMD))
        assertTrue(EcgResearchAllowList.isProbeOpcode(Whoop5Ecg.TOGGLE_REALTIME_FILTERED_ECG_CMD))
        assertTrue(EcgResearchAllowList.isProbeOpcode(Whoop5Ecg.TOGGLE_SAVE_RAW_ECG_CMD))
        assertTrue(EcgResearchAllowList.isProbeOpcode(Whoop5Ecg.MAIN_CONTROL_ECG_DATA_GENERATION_CMD))
    }

    @Test
    fun noOpcodeOutsideTheFourIsDispatchableAsAProbeCommand() {
        // The whole "no opcode sweep" guarantee, as a census: every byte value 0..255 except the four is
        // refused by the predicate the real BLE send path consults.
        for (op in 0..255) {
            val expected = op in setOf(123, 124, 125, 139)
            assertEquals("opcode $op", expected, EcgResearchAllowList.isProbeOpcode(op))
        }
    }

    @Test
    fun theFirmwareLoadFamilyIsRefusedAndNamed() {
        // 139 is TOGGLE_LABRADOR_FILTERED; 142/143/144 are the destructive firmware-load family right above
        // it. They must be refused AND named in the deny-list so the refusal is testable.
        for (op in listOf(142, 143, 144, 36, 37, 38, 45, 83)) {
            assertFalse("must not dispatch $op", EcgResearchAllowList.isProbeOpcode(op))
            assertFalse(EcgResearchAllowList.DISPATCHABLE_OPCODES.contains(op))
            assertTrue("must name $op as forbidden", EcgResearchAllowList.isForbidden(op))
        }
    }

    @Test
    fun rebootWipeDfuAndHighFreqAreAllForbidden() {
        for (op in listOf(29, 32, 25, 99, 96, 97, 100)) {
            assertTrue("forbidden: $op", EcgResearchAllowList.isForbidden(op))
            assertFalse(EcgResearchAllowList.isProbeOpcode(op))
        }
    }

    @Test
    fun noForbiddenOpcodeIsEverDispatchable() {
        for (op in EcgResearchAllowList.FORBIDDEN.keys) {
            assertFalse("forbidden $op leaked into dispatch set", EcgResearchAllowList.DISPATCHABLE_OPCODES.contains(op))
        }
    }

    @Test
    fun theGateOpcodesAreThe119And121DeviceConfigVerbsOnly() {
        assertEquals(setOf(119, 121), EcgResearchAllowList.GATE_OPCODES)
        // The FEATURE-FLAG SET verb (120) is NOT a gate opcode — the gate is device-config only.
        assertFalse(EcgResearchAllowList.isGateOpcode(120))
    }

    @Test
    fun dispatchableIsExactlyTheFourProbesPlusTwoGateVerbs() {
        assertEquals(setOf(123, 124, 125, 139, 119, 121), EcgResearchAllowList.DISPATCHABLE_OPCODES)
    }

    /**
     * The send-path invariant this allow-list depends on: `send()` forms a frame from a [CommandNumber],
     * so an allow-listed opcode the enum cannot express could not be dispatched at all. Guards against an
     * enum entry being removed and the allow-list silently admitting an opcode the sender cannot form.
     *
     * This is the assertion the pure-modules split deliberately deferred: 124/125/139 were absent from
     * `CommandNumber` on purpose, so it would have failed there for the correct reason. The change that
     * widens the enum is the change that gets to make it true.
     */
    @Test
    fun everyDispatchableOpcodeIsAConstructibleCommandNumber() {
        for (op in EcgResearchAllowList.DISPATCHABLE_OPCODES) {
            assertNotNull("CommandNumber must carry opcode $op", CommandNumber.fromRaw(op))
        }
    }

    /** The forbidden set and the probe set are disjoint: no never-send opcode is reachable through a probe case. */
    @Test
    fun noForbiddenOpcodeIsReachableThroughTheProbeCases() {
        for (op in EcgResearchAllowList.FORBIDDEN.keys) {
            assertFalse(EcgResearchAllowList.PROBE_OPCODES.contains(op))
        }
    }

    @Test
    fun theFirmwareLoadNewFamilyIsNotEvenInTheDispatchSet() {
        // 142/143/144 sit three codes above 139 in opcode space; the census must show they cannot be formed.
        assertNull(EcgResearchAllowList.FORBIDDEN[139])   // 139 is a PROBE opcode, not forbidden
        assertEquals("START_FIRMWARE_LOAD_NEW", EcgResearchAllowList.FORBIDDEN[142])
        assertEquals("LOAD_FIRMWARE_DATA_NEW", EcgResearchAllowList.FORBIDDEN[143])
        assertEquals("PROCESS_FIRMWARE_IMAGE_NEW", EcgResearchAllowList.FORBIDDEN[144])
    }
}
