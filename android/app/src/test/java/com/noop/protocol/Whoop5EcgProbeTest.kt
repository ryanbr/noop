package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
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
            sentArgument = arg,
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
            Whoop5EcgProbe.Verdict.DataRequestRefused(listOf("TOGGLE_LABRADOR_DATA_GENERATION(124) arg=1")),
            Whoop5EcgProbe.verdict(listOf(sent(124, 1, Whoop5EcgProbe.CommandOutcome.Failure)), 12, 30),
        )
        assertEquals(
            Whoop5EcgProbe.Verdict.OpcodeUnsupported(listOf("TOGGLE_LABRADOR_FILTERED(139) arg=1")),
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
            Whoop5EcgProbe.Verdict.NoDataRequested(listOf("SELECT_WRIST(123) arg=1")),
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
            Whoop5EcgProbe.Verdict.CommandRefused(listOf("SELECT_WRIST(123) arg=0")),
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
                    "TOGGLE_LABRADOR_DATA_GENERATION(124) arg=0",
                    "TOGGLE_LABRADOR_RAW_SAVE(125) arg=0",
                    "TOGGLE_LABRADOR_FILTERED(139) arg=0",
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
            Whoop5EcgProbe.Verdict.NoDataRequested(listOf("TOGGLE_LABRADOR_RAW_SAVE(125) arg=1")),
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
                listOf("TOGGLE_LABRADOR_FILTERED(139) arg=1", "TOGGLE_LABRADOR_DATA_GENERATION(124) arg=1"),
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
            Whoop5EcgProbe.Verdict.OpcodeUnsupported(listOf("TOGGLE_LABRADOR_FILTERED(139) arg=1")),
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
        assertTrue(text.contains("SELECT_WRIST(123) arg=1: SUCCESS(1)"))
        assertTrue(text.contains("TOGGLE_LABRADOR_DATA_GENERATION(124) arg=1: FAILURE(0)"))
        assertTrue(text.contains("type=0x28 len=220"))
        assertTrue(text.contains("aabb"))
        assertTrue(text.contains("not a medical measurement or a diagnosis"))
    }

    /**
     * Twin of Swift `testStartAndRestartRunsRenderDistinguishably`. A START run and a RESTART run send
     * the SAME three opcodes and differ in exactly one byte, so without the argument annotation their
     * reports are character-for-character identical — and a report is the artefact that gets copied out
     * of an app and pasted into an issue, long after the log that recorded the payload bytes is gone.
     */
    @Test
    fun startAndRestartRunsRenderDistinguishably() {
        fun run(control: Whoop5Ecg.ControlSignal): String = Whoop5EcgProbe.report(
            listOf(
                sent(139, 1, Whoop5EcgProbe.CommandOutcome.Success),
                sent(125, 1, Whoop5EcgProbe.CommandOutcome.Success),
                sent(124, control.raw, Whoop5EcgProbe.CommandOutcome.Success),
            ),
            0, emptyList(), 30,
        )
        val startText = run(Whoop5Ecg.ControlSignal.START)
        val restartText = run(Whoop5Ecg.ControlSignal.RESTART)
        assertTrue(startText.contains("TOGGLE_LABRADOR_DATA_GENERATION(124) arg=1: SUCCESS(1)"))
        assertTrue(restartText.contains("TOGGLE_LABRADOR_DATA_GENERATION(124) arg=2: SUCCESS(1)"))
        assertNotEquals(startText, restartText)
        // Both are still the SAME verdict: restart asks for realtime data exactly like start does, so
        // the annotation records what was sent without changing what the run is read as.
        assertTrue(startText.contains("Accepted but SILENT"))
        assertTrue(restartText.contains("Accepted but SILENT"))
    }

    /**
     * An UNSOLICITED reply has no known argument — nothing in an app layer sent it — and the report must
     * say nothing rather than invent a value.
     */
    @Test
    fun anUnknownArgumentIsOmittedRatherThanGuessed() {
        val step = Whoop5EcgProbe.Step(
            label = "TOGGLE_LABRADOR_DATA_GENERATION(124)",
            outcome = Whoop5EcgProbe.CommandOutcome.Success,
            requestsRealtimeData = false,
        )
        assertNull(step.sentArgument)
        assertEquals("TOGGLE_LABRADOR_DATA_GENERATION(124)", step.labelWithArgument)
        assertFalse(Whoop5EcgProbe.report(listOf(step), 0, emptyList(), 30).contains("arg="))
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

    // MARK: - Unclassified-frame census

    private fun header(samples: Int): List<Int> = listOf(
        2, 0x05, 1, 1, 0, 1, 0, 1, 42, 0, 61, 63, 812 and 0xFF, (812 shr 8) and 0xFF, 17,
        samples and 0xFF, (samples shr 8) and 0xFF,
    )

    private fun puffinFrame(type: Int, payload: List<Int>): ByteArray =
        Framing.puffinCommandFrame(
            cmd = 0x00, seq = 0x01,
            payload = payload.map { it.toByte() }.toByteArray(),
            type = type,
        )

    /**
     * The census exists for the frames the triage says NO to. A heuristic that logs only its own hits
     * destroys the evidence for its own misses: the 2-bytes-per-sample assumption discarded every 3-byte
     * frame, and the report then said, truthfully, that nothing passed.
     */
    @Test
    fun censusRecordsAFrameTheTriageRejects() {
        val frame = puffinFrame(0x1A, List(20) { 0xEE })
        assertFalse("fixture must be a triage MISS", Whoop5Ecg.plausibleFilteredFrame(frame))

        val census = Whoop5EcgProbe.FrameCensus()
        census.record(frame)
        assertEquals(1, census.framesSeen)
        assertEquals(1, census.buckets.size)
        assertEquals(0x1A, census.buckets[0].typeByte)
        assertEquals(1, census.buckets[0].count)

        val sample = census.buckets[0].samples[0]
        assertEquals(frame.size, sample.frameLength)
        assertEquals(21, sample.payloadLength)          // 20 + the envelope's pad4 byte
        assertEquals(0xEEEE, sample.numberOfECGSamples) // read, not believed
        assertTrue(sample.widths.isEmpty())
        assertTrue(sample.headHex.startsWith("aa"))
        assertEquals("  type=0x1a  frames=1", census.lines[0])
        assertTrue(census.lines[1].contains("widths=none"))
        assertTrue(census.lines[1].contains("payload=21"))
    }

    /** A HIT is censused too — the census is the whole record of the window, not a rejects bin. */
    @Test
    fun censusRecordsTriageHitsWithTheWidthThatAgreed() {
        val frame = puffinFrame(0x28, header(samples = 4) + List(12) { 0x11 })
        assertTrue(Whoop5Ecg.plausibleFilteredFrame(frame))
        val census = Whoop5EcgProbe.FrameCensus()
        census.record(frame)
        assertEquals(listOf(3), census.buckets[0].samples[0].widths)
        assertEquals(4, census.buckets[0].samples[0].numberOfECGSamples)
        assertTrue(census.lines[1].contains("widths=3"))
    }

    /** A frame whose CRC does not check out yields no decoded field — only its shape and its bytes. */
    @Test
    fun censusReadsNoFieldOutOfAnUnverifiedFrame() {
        val frame = puffinFrame(0x28, header(samples = 3) + listOf(1, 0, 2, 0, 3, 0))
        frame[frame.size - 1] = (frame[frame.size - 1].toInt() xor 0xFF).toByte()
        val census = Whoop5EcgProbe.FrameCensus()
        census.record(frame)
        assertNull(census.buckets[0].samples[0].payloadLength)
        assertNull(census.buckets[0].samples[0].numberOfECGSamples)
        assertTrue(census.buckets[0].samples[0].widths.isEmpty())
        assertTrue(census.lines[1].contains("payload=? samples=? widths=none"))
    }

    /** A 1 Hz stream must not grow the report without bound — and nothing may be dropped in silence. */
    @Test
    fun censusCapsSamplesPerTypeButKeepsCounting() {
        val frame = puffinFrame(0x30, List(20) { 0xEE })
        val census = Whoop5EcgProbe.FrameCensus()
        repeat(50) { census.record(frame) }
        assertEquals(50, census.framesSeen)
        assertEquals(1, census.buckets.size)
        assertEquals(50, census.buckets[0].count)
        assertEquals(Whoop5EcgProbe.FrameCensus.MAX_SAMPLES_PER_TYPE, census.buckets[0].samples.size)
        assertTrue(census.lines.any { it.contains("+47 more of this type, not recorded") })
    }

    @Test
    fun censusCapsDistinctTypesAndCountsTheOverflow() {
        val census = Whoop5EcgProbe.FrameCensus()
        for (type in 0 until Whoop5EcgProbe.FrameCensus.MAX_TYPES + 4) {
            census.record(puffinFrame(type, List(20) { 0xEE }))
        }
        assertEquals(Whoop5EcgProbe.FrameCensus.MAX_TYPES, census.buckets.size)
        assertEquals(4, census.framesBeyondTypeCap)
        assertEquals(Whoop5EcgProbe.FrameCensus.MAX_TYPES + 4, census.framesSeen)
        assertTrue(census.lines.any { it.contains("4 frame(s) of further type bytes past the") })
    }

    @Test
    fun censusIgnoresBuffersTooShortToCarryATypeByte() {
        val census = Whoop5EcgProbe.FrameCensus()
        census.record(ByteArray(0))
        census.record(ByteArray(8) { 0xAA.toByte() })
        assertTrue(census.isEmpty)
        assertTrue(census.buckets.isEmpty())
    }

    /** The census is only useful if the operator can COPY it: it belongs in the report sheet. */
    @Test
    fun reportCarriesTheCensusBesideTheTriageResult() {
        val census = Whoop5EcgProbe.FrameCensus()
        census.record(puffinFrame(0x1A, List(20) { 0xEE }))
        val text = Whoop5EcgProbe.report(
            steps = listOf(
                sent(139, 1, Whoop5EcgProbe.CommandOutcome.Success),
                sent(124, Whoop5Ecg.ControlSignal.START.raw, Whoop5EcgProbe.CommandOutcome.Success),
            ),
            ecgPacketsSeen = 0,
            candidateFrames = emptyList(),
            windowSeconds = 30,
            census = census,
        )
        assertTrue(text.contains("Candidate packet types: none — no frame passed the structural triage."))
        assertTrue(text.contains("Unclassified-frame census"))
        assertTrue(text.contains("type=0x1a  frames=1"))
        assertTrue(text.contains("widths=none"))
        assertTrue(text.contains(census.buckets[0].samples[0].headHex))
    }

    @Test
    fun reportSaysSoWhenNoUnclassifiedFrameArrivedAtAll() {
        val text = Whoop5EcgProbe.report(emptyList(), 0, emptyList(), 30)
        assertTrue(text.contains("no unclassified frame arrived at all"))
    }
}
