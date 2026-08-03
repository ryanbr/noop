package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Kotlin twin of the `Whoop5EcgProbe` half of WhoopProtocolTests/Whoop5EcgTests.swift. Same runs, same
 * verdicts, so the rule that decides whether a null result gets published as evidence of a firmware
 * block cannot drift between the two platforms.
 */
class Whoop5EcgProbeTest {

    /**
     * Build a step the way the driver does — the label from the opcode, and the role flag DERIVED from
     * opcode + argument rather than hand-set. Every verdict test below therefore exercises the same
     * predicate the app does, so a wrong `requestsRealtimeData` cannot be papered over by a test that
     * simply asserts the flag it wants.
     */
    private fun sent(
        cmd: Int,
        arg: Int,
        outcome: Whoop5EcgProbe.CommandOutcome,
        replyHex: String? = null,
    ): Whoop5EcgProbe.Step {
        val name = when (cmd) {
            Whoop5Ecg.SELECT_WRIST_CMD -> "SELECT_WRIST"
            Whoop5Ecg.MAIN_CONTROL_ECG_DATA_GENERATION_CMD -> "TOGGLE_LABRADOR_DATA_GENERATION"
            Whoop5Ecg.TOGGLE_SAVE_RAW_ECG_CMD -> "TOGGLE_LABRADOR_RAW_SAVE"
            Whoop5Ecg.TOGGLE_REALTIME_FILTERED_ECG_CMD -> "TOGGLE_LABRADOR_FILTERED"
            else -> "CMD"
        }
        return Whoop5EcgProbe.Step(
            label = "$name($cmd)",
            outcome = outcome,
            requestsRealtimeData = Whoop5Ecg.requestsRealtimeData(cmd, arg),
            replyHex = replyHex,
        )
    }

    private fun responseFrame(cmd: Int, result: Int): ByteArray =
        Framing.puffinCommandFrame(
            cmd = cmd, seq = 1,
            payload = byteArrayOf(0x01, result.toByte()),
            type = 36,
        )

    @Test
    fun outcomeReadsTheResultCodeAtFrame12() {
        assertEquals(Whoop5EcgProbe.CommandOutcome.Failure, Whoop5EcgProbe.outcome(responseFrame(0x7C, 0)))
        assertEquals(Whoop5EcgProbe.CommandOutcome.Success, Whoop5EcgProbe.outcome(responseFrame(0x7C, 1)))
        assertEquals(Whoop5EcgProbe.CommandOutcome.Pending, Whoop5EcgProbe.outcome(responseFrame(0x7C, 2)))
        assertEquals(
            Whoop5EcgProbe.CommandOutcome.Unsupported,
            Whoop5EcgProbe.outcome(responseFrame(0x7C, 3)),
        )
        assertEquals(
            Whoop5EcgProbe.CommandOutcome.Unmapped(42),
            Whoop5EcgProbe.outcome(responseFrame(0x7C, 42)),
        )
        assertNull(Whoop5EcgProbe.outcome(byteArrayOf(0xAA.toByte(), 0x01)))
    }

    // Which commands can produce data at all

    @Test
    fun onlyTheStreamAndGenerationVerbsCanProduceRealtimeData() {
        // The ARGUMENT is half the answer: the same opcode asks for data ON and asks for silence OFF.
        assertTrue(Whoop5Ecg.requestsRealtimeData(Whoop5Ecg.TOGGLE_REALTIME_FILTERED_ECG_CMD, 1))
        assertFalse(Whoop5Ecg.requestsRealtimeData(Whoop5Ecg.TOGGLE_REALTIME_FILTERED_ECG_CMD, 0))
        assertTrue(
            Whoop5Ecg.requestsRealtimeData(
                Whoop5Ecg.MAIN_CONTROL_ECG_DATA_GENERATION_CMD,
                Whoop5Ecg.ControlSignal.START.raw,
            ),
        )
        assertTrue(
            Whoop5Ecg.requestsRealtimeData(
                Whoop5Ecg.MAIN_CONTROL_ECG_DATA_GENERATION_CMD,
                Whoop5Ecg.ControlSignal.RESTART.raw,
            ),
        )
        assertFalse(
            Whoop5Ecg.requestsRealtimeData(
                Whoop5Ecg.MAIN_CONTROL_ECG_DATA_GENERATION_CMD,
                Whoop5Ecg.ControlSignal.STOP.raw,
            ),
        )
        // SELECT_WRIST configures which wrist; it starts nothing, on EITHER argument. This is the opcode
        // whose silence was being reported as a firmware block.
        for (wrist in Whoop5Ecg.WristSelection.entries) {
            assertFalse(Whoop5Ecg.requestsRealtimeData(Whoop5Ecg.SELECT_WRIST_CMD, wrist.raw))
        }
        // RAW_SAVE names flash, not a live channel — a realtime window cannot observe it either way, so
        // it must not unlock a verdict that reads realtime silence as evidence (#891 hypothesis (b)).
        assertFalse(Whoop5Ecg.requestsRealtimeData(Whoop5Ecg.TOGGLE_SAVE_RAW_ECG_CMD, 1))
        // An opcode outside the family (an unsolicited reply's, say) is never a data request.
        assertFalse(Whoop5Ecg.requestsRealtimeData(26, 1))
    }

    @Test
    fun attestedResultCodesOutrankTheShapeHeuristic() {
        assertEquals(
            Whoop5EcgProbe.Verdict.DataRequestRefused(listOf("TOGGLE_LABRADOR_DATA_GENERATION(124)")),
            Whoop5EcgProbe.verdict(listOf(sent(124, 1, Whoop5EcgProbe.CommandOutcome.Failure)), 12, 30),
        )
        assertEquals(
            Whoop5EcgProbe.Verdict.OpcodeUnsupported(listOf("TOGGLE_LABRADOR_FILTERED(139)")),
            Whoop5EcgProbe.verdict(listOf(sent(139, 1, Whoop5EcgProbe.CommandOutcome.Unsupported)), 12, 30),
        )
        assertEquals(
            Whoop5EcgProbe.Verdict.EcgCandidatesArrived(12),
            Whoop5EcgProbe.verdict(listOf(sent(124, 1, Whoop5EcgProbe.CommandOutcome.Success)), 12, 30),
        )
    }

    @Test
    fun togglesSentThenSilenceIsTheSilentNoOpCase() {
        // The turn-on run: data WAS requested and the strap said SUCCESS. This is the only shape from
        // which "accepted, then not honoured" can be read.
        val steps = listOf(
            sent(139, 1, Whoop5EcgProbe.CommandOutcome.Success),
            sent(125, 1, Whoop5EcgProbe.CommandOutcome.Success),
            sent(124, Whoop5Ecg.ControlSignal.START.raw, Whoop5EcgProbe.CommandOutcome.Success),
        )
        assertEquals(
            Whoop5EcgProbe.Verdict.AcceptedButSilent(30),
            Whoop5EcgProbe.verdict(steps, 0, 30),
        )
    }

    @Test
    fun togglesSentAndPacketsArrivedIsTheCandidateVerdictNotABlock() {
        val steps = listOf(
            sent(139, 1, Whoop5EcgProbe.CommandOutcome.Success),
            sent(125, 1, Whoop5EcgProbe.CommandOutcome.Success),
            sent(124, Whoop5Ecg.ControlSignal.START.raw, Whoop5EcgProbe.CommandOutcome.Success),
        )
        assertEquals(
            Whoop5EcgProbe.Verdict.EcgCandidatesArrived(4),
            Whoop5EcgProbe.verdict(steps, 4, 30),
        )
    }

    // A run that asked for nothing is not a test of anything

    @Test
    fun wristOnlyRunIsNotReportedAsADeviceFlagBlock() {
        // REGRESSION (#891). A SELECT_WRIST-only run sends NO data-generation command, so zero packets is
        // the expected outcome. The old logic classified it AcceptedButSilent and printed "Consistent
        // with a device-flag block applied as a silent no-op" — manufacturing evidence for hypothesis (e)
        // out of a run that could not speak to it.
        val steps = listOf(
            sent(
                123, Whoop5Ecg.WristSelection.LEFT.raw, Whoop5EcgProbe.CommandOutcome.Success,
                replyHex = "aa010c000100271124d77b81010100007ce76722",
            ),
        )
        assertEquals(
            Whoop5EcgProbe.Verdict.NoDataRequested(listOf("SELECT_WRIST(123)")),
            Whoop5EcgProbe.verdict(steps, 0, 30),
        )
        val text = Whoop5EcgProbe.report(steps, 0, emptyList(), 30)
        assertTrue(text.contains("NOT A TEST"))
        assertFalse(text.contains("device-flag block"))
        assertFalse(text.contains("Accepted but SILENT"))
        // The report must say WHY, not just withhold the claim.
        assertTrue(text.contains("cannot produce ECG data"))
        assertTrue(text.contains("Zero is the EXPECTED result here"))
    }

    @Test
    fun wristOnlyRunThatFailsIsARefusalNotADeviceFlagBlock() {
        // REGRESSION (#891). The same run with the OTHER wrist came back FAILURE(0) on hardware, and the
        // old logic promoted that to "LIKELY blockedByDeviceFlags". The firmware refused ONE config
        // write; nothing about ECG generation follows from it.
        val steps = listOf(
            sent(
                123, Whoop5Ecg.WristSelection.RIGHT.raw, Whoop5EcgProbe.CommandOutcome.Failure,
                replyHex = "aa010c000100271124217bcc000100000213163d",
            ),
        )
        assertEquals(
            Whoop5EcgProbe.Verdict.CommandRefused(listOf("SELECT_WRIST(123)")),
            Whoop5EcgProbe.verdict(steps, 0, 30),
        )
        val text = Whoop5EcgProbe.report(steps, 0, emptyList(), 30)
        assertTrue(text.contains("REFUSED"))
        assertFalse(text.contains("blockedByDeviceFlags"))
    }

    @Test
    fun offSequenceAsksForSilenceSoItsSilenceIsNotEvidence() {
        // The OFF path sends the same three opcodes with the OFF arguments. It asks for exactly the
        // silence it gets, so it must never render as a block either.
        val steps = listOf(
            sent(124, Whoop5Ecg.ControlSignal.STOP.raw, Whoop5EcgProbe.CommandOutcome.Success),
            sent(125, 0, Whoop5EcgProbe.CommandOutcome.Success),
            sent(139, 0, Whoop5EcgProbe.CommandOutcome.Success),
        )
        assertEquals(
            Whoop5EcgProbe.Verdict.NoDataRequested(
                listOf(
                    "TOGGLE_LABRADOR_DATA_GENERATION(124)",
                    "TOGGLE_LABRADOR_RAW_SAVE(125)",
                    "TOGGLE_LABRADOR_FILTERED(139)",
                ),
            ),
            Whoop5EcgProbe.verdict(steps, 0, 30),
        )
    }

    @Test
    fun rawSaveAloneCannotUnlockTheSilentVerdict() {
        // RAW_SAVE names flash. A realtime listen window observes nothing from it even on total success,
        // so a raw-save-only run cannot be read as "accepted and then silent" (#891 hypothesis (b)).
        assertEquals(
            Whoop5EcgProbe.Verdict.NoDataRequested(listOf("TOGGLE_LABRADOR_RAW_SAVE(125)")),
            Whoop5EcgProbe.verdict(listOf(sent(125, 1, Whoop5EcgProbe.CommandOutcome.Success)), 0, 30),
        )
    }

    @Test
    fun anUnacknowledgedDataRequestIsNotAcceptedButSilent() {
        // "Accepted" needs an ack. The wrist write landed; the request that matters never came back.
        val steps = listOf(
            sent(123, Whoop5Ecg.WristSelection.LEFT.raw, Whoop5EcgProbe.CommandOutcome.Success),
            sent(139, 1, Whoop5EcgProbe.CommandOutcome.NoReply),
            sent(124, Whoop5Ecg.ControlSignal.START.raw, Whoop5EcgProbe.CommandOutcome.NoReply),
        )
        assertEquals(
            Whoop5EcgProbe.Verdict.DataRequestNotAccepted(
                listOf("TOGGLE_LABRADOR_FILTERED(139)", "TOGGLE_LABRADOR_DATA_GENERATION(124)"),
            ),
            Whoop5EcgProbe.verdict(steps, 0, 30),
        )
    }

    @Test
    fun noVerdictClaimsAFlagBlockWithoutADataRequest() {
        // The invariant, stated once over every reachable outcome: a run that asked for no realtime data
        // can never produce a headline that reads as evidence about the block question.
        val outcomes = listOf(
            Whoop5EcgProbe.CommandOutcome.Success,
            Whoop5EcgProbe.CommandOutcome.Failure,
            Whoop5EcgProbe.CommandOutcome.Pending,
            Whoop5EcgProbe.CommandOutcome.Unsupported,
            Whoop5EcgProbe.CommandOutcome.Unmapped(42),
            Whoop5EcgProbe.CommandOutcome.NoReply,
        )
        val noDataArgs = listOf(
            123 to 0, 123 to 1, 125 to 1, 125 to 0,
            139 to 0, 124 to Whoop5Ecg.ControlSignal.STOP.raw,
        )
        // The two AFFIRMATIVE claims. Matched exactly, because OpcodeUnsupported legitimately contains
        // the words "not a device-flag block" — denying the claim is the opposite of making it.
        val asserts = listOf("LIKELY blockedByDeviceFlags", "Consistent with a device-flag block")
        for ((cmd, arg) in noDataArgs) {
            for (outcome in outcomes) {
                val headline = Whoop5EcgProbe.verdict(listOf(sent(cmd, arg, outcome)), 0, 30).headline
                for (claim in asserts) {
                    assertFalse(
                        "cmd $cmd arg $arg outcome ${outcome.token} claimed: $claim",
                        headline.contains(claim),
                    )
                }
            }
        }
    }

    @Test
    fun verdictUnsupportedIsReportedAsItselfNotAsABlock() {
        assertEquals(
            Whoop5EcgProbe.Verdict.OpcodeUnsupported(listOf("TOGGLE_LABRADOR_FILTERED(139)")),
            Whoop5EcgProbe.verdict(listOf(sent(139, 1, Whoop5EcgProbe.CommandOutcome.Unsupported)), 0, 30),
        )
    }

    @Test
    fun verdictSilenceIsNeverCalledABlock() {
        val steps = listOf(
            sent(139, 1, Whoop5EcgProbe.CommandOutcome.NoReply),
            sent(124, Whoop5Ecg.ControlSignal.START.raw, Whoop5EcgProbe.CommandOutcome.NoReply),
        )
        assertEquals(Whoop5EcgProbe.Verdict.NoReplies, Whoop5EcgProbe.verdict(steps, 0, 30))
        assertEquals(Whoop5EcgProbe.Verdict.NoReplies, Whoop5EcgProbe.verdict(emptyList(), 0, 30))
    }

    @Test
    fun verdictMixedCodesAreInconclusive() {
        val steps = listOf(
            sent(139, 1, Whoop5EcgProbe.CommandOutcome.Success),
            sent(124, Whoop5Ecg.ControlSignal.START.raw, Whoop5EcgProbe.CommandOutcome.Pending),
        )
        assertEquals(Whoop5EcgProbe.Verdict.Inconclusive, Whoop5EcgProbe.verdict(steps, 0, 30))
    }

    /**
     * #896 review, twin of Swift `testAZeroPacketRunThatAskedForDataQuestionsTheElectrodeCircuit`.
     * Nobody is told to hold the clasp. An MG measures across the wrist electrode AND the two clasp
     * indents, and lead state is not on the wire — so a run where the clasp was never touched returns
     * zero packets for a reason that has nothing to do with the firmware. #891 asks other MG owners to
     * run this; without the line they report "nothing happened" and the thread reads it as evidence
     * about the gate.
     */
    @Test
    fun aZeroPacketRunThatAskedForDataQuestionsTheElectrodeCircuit() {
        val steps = listOf(
            sent(123, Whoop5Ecg.WristSelection.LEFT.raw, Whoop5EcgProbe.CommandOutcome.Success, "aabb"),
            sent(124, Whoop5Ecg.ControlSignal.START.raw, Whoop5EcgProbe.CommandOutcome.Success, "ccdd"),
        )
        val text = Whoop5EcgProbe.report(steps, 0, emptyList(), 30)
        assertTrue(text.contains("Were the leads closed?"))
        assertTrue(text.contains("two indents on the clasp"))
        assertTrue(text.contains("OTHER hand"))
        // It must stay a QUESTION about the run. Claiming the leads WERE open would be the same
        // manufactured-cause error as the retired device-flag wording.
        assertTrue(text.contains("cannot tell an open circuit from a strap that ignored the command"))
    }

    /**
     * The line is about a zero that MIGHT have a mundane cause, so it is silent when there is no zero to
     * explain and when the run never asked for data (that case has its own, different sentence).
     */
    @Test
    fun theElectrodeQuestionIsAbsentWhenPacketsArrivedOrNoDataWasAsked() {
        val asked = listOf(
            sent(123, Whoop5Ecg.WristSelection.LEFT.raw, Whoop5EcgProbe.CommandOutcome.Success, "aabb"),
            sent(124, Whoop5Ecg.ControlSignal.START.raw, Whoop5EcgProbe.CommandOutcome.Success, "ccdd"),
        )
        assertFalse(Whoop5EcgProbe.report(asked, 4, emptyList(), 30).contains("Were the leads closed?"))

        val wristOnly = listOf(
            sent(123, Whoop5Ecg.WristSelection.LEFT.raw, Whoop5EcgProbe.CommandOutcome.Success, "aabb"),
        )
        val noRequest = Whoop5EcgProbe.report(wristOnly, 0, emptyList(), 30)
        assertFalse(noRequest.contains("Were the leads closed?"))
        assertTrue(noRequest.contains("Zero is the EXPECTED result here"))
    }

    @Test
    fun reportCarriesTheVerdictTheOutcomesAndTheNonMedicalFraming() {
        val steps = listOf(
            sent(123, Whoop5Ecg.WristSelection.LEFT.raw, Whoop5EcgProbe.CommandOutcome.Success, "aabb"),
            sent(124, Whoop5Ecg.ControlSignal.START.raw, Whoop5EcgProbe.CommandOutcome.Failure, "ccdd"),
        )
        val text = Whoop5EcgProbe.report(steps, 0, listOf("type=0x28 len=220"), 30)
        assertTrue(text.contains("DATA REQUEST REFUSED"))
        assertTrue(text.contains("SELECT_WRIST(123): SUCCESS(1)"))
        assertTrue(text.contains("TOGGLE_LABRADOR_DATA_GENERATION(124): FAILURE(0)"))
        assertTrue(text.contains("type=0x28 len=220"))
        assertTrue(text.contains("aabb"))
        assertTrue(text.contains("not a medical measurement or a diagnosis"))
    }

    /**
     * REGRESSION (#891), twin of Swift `testNoVerdictMentionsDeviceFlagsAtAll`. No verdict may name
     * `blockedByDeviceFlags` or a "device-flag block" AT ALL — not to assert it, and not to deny it.
     *
     * The scoping fix made the two offending verdicts unreachable without a data request; it left the
     * WORDING in place, and the wording is independently wrong. `blockedByDeviceFlags` is a client-side
     * construct: no command in the `CommandNumber` table reads or writes such a flag, nothing in this
     * repo implements one, and it is never transmitted to a strap. #891 then wrote the leading named
     * firmware-side candidate (`enable_raw_data_w_ecg`) to `'1'`, confirmed the read-back, and still saw
     * zero packets.
     *
     * Enumerated over EVERY verdict case rather than every input, so a new case cannot be added with the
     * old vocabulary and slip through on the grounds that no input reaches it.
     */
    @Test
    fun noVerdictMentionsDeviceFlagsAtAll() {
        val cmds = listOf("TOGGLE_LABRADOR_DATA_GENERATION(124)")
        val every = listOf(
            Whoop5EcgProbe.Verdict.EcgCandidatesArrived(3),
            Whoop5EcgProbe.Verdict.DataRequestRefused(cmds),
            Whoop5EcgProbe.Verdict.CommandRefused(cmds),
            Whoop5EcgProbe.Verdict.AcceptedButSilent(30),
            Whoop5EcgProbe.Verdict.NoDataRequested(cmds),
            Whoop5EcgProbe.Verdict.DataRequestNotAccepted(cmds),
            Whoop5EcgProbe.Verdict.OpcodeUnsupported(cmds),
            Whoop5EcgProbe.Verdict.NoReplies,
            Whoop5EcgProbe.Verdict.Inconclusive,
        )
        for (verdict in every) {
            val headline = verdict.headline.lowercase()
            assertFalse("leaked the identifier: ${verdict.headline}", headline.contains("deviceflag"))
            assertFalse("leaked the phrase: ${verdict.headline}", headline.contains("device-flag"))
        }
    }

    /**
     * The silent verdict must still say something useful — removing the false cause must not leave the
     * report mute about what else explains the silence.
     */
    @Test
    fun acceptedButSilentNamesTheAlternativesInsteadOfACause() {
        val headline = Whoop5EcgProbe.Verdict.AcceptedButSilent(30).headline
        assertTrue(headline.contains("does not identify a cause"))
        assertTrue(headline.contains("flash"))
        assertTrue(headline.contains("entitlement gate"))
    }

    @Test
    fun reportNeverPresentsAnArrhythmiaResultAsAFinding() {
        // The report is the only text the probe surfaces; it must not name a classifier verdict at all.
        val text = Whoop5EcgProbe.report(emptyList(), 0, emptyList(), 30)
        for (token in EcgArrhythmiaCheckResult.entries.map { it.token }) {
            assertFalse("report must not name $token", text.lowercase().contains(token.lowercase()))
        }
    }
}
