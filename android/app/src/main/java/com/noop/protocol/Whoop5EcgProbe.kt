package com.noop.protocol

/**
 * Kotlin twin of Swift `Whoop5EcgProbe`: formats the WHOOP MG ECG ("Labrador") turn-on attempt into one
 * readable, copyable report — the per-command COMMAND_RESPONSE result codes, whether any ECG-shaped
 * packet actually arrived, and a verdict that describes WHAT THE RUN OBSERVED rather than naming a
 * mechanism behind it.
 *
 * Pure and deterministic, so the JVM unit tests cover it with no strap.
 *
 * The Android client has no ECG app layer to drive this — it takes the decoder ([Whoop5Ecg]) only. It is
 * mirrored anyway because the classification below decides how a null result gets reported, which is the
 * claim this probe exists to make; a rule that important is worth two independent implementations and
 * two test suites, and both suites pin the same runs.
 *
 * ## The verdicts name observations, not mechanisms
 *
 * An earlier version of this type reported a silent run as *"consistent with a device-flag block applied
 * as a silent no-op"* and a refusal as `BlockedByDeviceFlagsLikely`. **Both named a mechanism this probe
 * cannot observe and the protocol does not carry.** `blockedByDeviceFlags` is a CLIENT-SIDE construct: it
 * is never transmitted to a strap, no command in `whoop_protocol.json`'s `CommandNumber` table reads or
 * writes such a flag, and nothing in this repo implements one. It is not a strap capability gate, so a
 * probe that only ever sees result codes and packet counts is in no position to attribute silence to it.
 *
 * That mattered in practice. #891 tested the leading named candidate for a firmware-side gate
 * (`enable_raw_data_w_ecg`, written to `'1'` and read back through `GET_DEVICE_CONFIG_VALUE(121)`) and
 * still got zero packets in 30 s with the electrodes held — so the flag-block reading is not where the
 * evidence points, and it was the probe's own wording that kept lending it weight. Five other
 * explanations fit the same silence: banked to flash rather than streamed, a wrong opcode mapping, no
 * actual start verb among three `TOGGLE_*` commands, an entitlement gate, or an electrode circuit that
 * never closed.
 *
 * So the three signals below are reported as themselves, and the report states which one fired:
 *
 *  1. `UNSUPPORTED(3)` — the firmware does not implement the opcode at all. A different, and more final,
 *     answer than a refusal.
 *  2. `FAILURE(0)` — the firmware KNOWS the opcode and REFUSES to run it. That is a fact about the
 *     opcode; WHY it refused is not on the wire.
 *  3. `SUCCESS(1)` on every command, but ZERO ECG packets across the capture window — acknowledged and
 *     then not honoured. It does not identify what suppressed them.
 *
 * Nothing is ever inferred from silence alone: no reply at all is reported as exactly that, because an
 * in-flight sync or a dropped notification produces the same silence.
 *
 * ## What a run has to contain before silence means anything
 *
 * Signal 3 reads SILENCE as evidence. Silence only carries information when the run actually **asked the
 * strap for data**: a wrist selection changes no data path, and the OFF sequence asks for the silence it
 * gets. So every step records whether the command — *with the argument it was sent with* — could have
 * produced realtime ECG data ([Whoop5Ecg.requestsRealtimeData]), and the two verdicts that interpret
 * silence are unreachable without one:
 *
 *  - [Verdict.AcceptedButSilent] needs a data request that came back `SUCCESS`. Requested-but-
 *    unacknowledged is [Verdict.DataRequestNotAccepted]; nothing requested at all is
 *    [Verdict.NoDataRequested].
 *  - [Verdict.DataRequestRefused] needs the refused command to be a data request. A `FAILURE` on
 *    a configuration write is [Verdict.CommandRefused] — the firmware refused *that write*, which is a
 *    fact about that opcode and not about whether ECG generation is gated.
 *
 * Both defects were live: a `SELECT_WRIST`-only run on a WHOOP 5 MG rendered "Accepted but SILENT …
 * consistent with a device-flag block" having sent no data-generation command at all, and a second
 * `SELECT_WRIST`-only run that came back `FAILURE` rendered "LIKELY blockedByDeviceFlags". Both
 * manufactured evidence for hypothesis (e) of #891 out of runs that could not speak to it.
 */
object Whoop5EcgProbe {

    /** The 5/MG COMMAND_RESPONSE result code, at `frame[12]`. */
    const val RESULT_CODE_OFFSET = 12

    sealed class CommandOutcome {
        object Success : CommandOutcome()
        object Failure : CommandOutcome()
        object Pending : CommandOutcome()
        object Unsupported : CommandOutcome()
        data class Unmapped(val value: Int) : CommandOutcome()

        /** No COMMAND_RESPONSE arrived inside the probe window. */
        object NoReply : CommandOutcome()

        val token: String
            get() = when (this) {
                is Success -> "SUCCESS(1)"
                is Failure -> "FAILURE(0)"
                is Pending -> "PENDING(2)"
                is Unsupported -> "UNSUPPORTED(3)"
                is Unmapped -> "result$value"
                is NoReply -> "no reply"
            }
    }

    /** Read the result code out of a 5/MG COMMAND_RESPONSE frame. null when the frame is too short. */
    fun outcome(frame: ByteArray): CommandOutcome? {
        if (frame.size <= RESULT_CODE_OFFSET) return null
        return when (val v = frame[RESULT_CODE_OFFSET].toInt() and 0xFF) {
            0 -> CommandOutcome.Failure
            1 -> CommandOutcome.Success
            2 -> CommandOutcome.Pending
            3 -> CommandOutcome.Unsupported
            else -> CommandOutcome.Unmapped(v)
        }
    }

    /**
     * One command in the turn-on sequence and what came back.
     *
     * [requestsRealtimeData] deliberately has NO default: every construction site must state it, because
     * the verdicts that read silence as evidence turn on this flag and a silently-omitted `true` is
     * exactly the bug this field exists to prevent.
     */
    data class Step(
        val label: String,
        val outcome: CommandOutcome,
        val requestsRealtimeData: Boolean,
        val replyHex: String? = null,
    ) {
        /** How the report annotates the step, so a reader can see WHY the verdict is what it is. */
        val roleNote: String
            get() = if (requestsRealtimeData) "asks for realtime ECG data"
                    else "cannot produce ECG data (configuration or OFF)"
    }

    /** The gate verdict, kept separate from the report text so it is assertable in a test. */
    sealed class Verdict {
        /**
         * Frames that PASS THE STRUCTURAL TRIAGE arrived. Not proof: the triage is a shape heuristic run
         * against ordinary live 5/MG traffic, so an unrelated packet can match.
         */
        data class EcgCandidatesArrived(val packets: Int) : Verdict()

        /**
         * At least one command that ASKED FOR DATA came back FAILURE: the opcode exists and execution
         * was refused. WHY it was refused is not on the wire — the reply carries a result code and
         * nothing that names a cause.
         */
        data class DataRequestRefused(val commands: List<String>) : Verdict()

        /**
         * A command that asks for no data came back FAILURE. The firmware refused THAT WRITE, which is a
         * fact about that opcode and says nothing about whether ECG generation is gated.
         */
        data class CommandRefused(val commands: List<String>) : Verdict()

        /** Everything acked SUCCESS, at least one of them a data request, and nothing ever arrived. */
        data class AcceptedButSilent(val windowSeconds: Int) : Verdict()

        /**
         * The run sent nothing that could produce realtime ECG data, so its silence is the expected
         * outcome and is evidence of nothing.
         */
        data class NoDataRequested(val commands: List<String>) : Verdict()

        /**
         * Data WAS requested, but the strap never returned SUCCESS for the request — so the silence
         * cannot be read as "accepted, then not honoured".
         */
        data class DataRequestNotAccepted(val commands: List<String>) : Verdict()

        /** The firmware rejected an opcode as unimplemented. */
        data class OpcodeUnsupported(val commands: List<String>) : Verdict()

        /** Nothing replied at all. */
        object NoReplies : Verdict()

        /** A mixed or unmapped set of codes that none of the above describes. */
        object Inconclusive : Verdict()

        val headline: String
            get() = when (this) {
                is EcgCandidatesArrived ->
                    "$packets frame(s) matched the ECG structural triage. That is a CANDIDATE, not proof: " +
                        "the triage is a shape heuristic and unrelated traffic can match it. Confirm against " +
                        "the raw bytes below before concluding anything about whether the feature is blocked."
                is DataRequestRefused ->
                    "DATA REQUEST REFUSED — the firmware returned FAILURE for " +
                        "${commands.joinToString(", ")}, which asked it to produce ECG data: it knows the " +
                        "opcode and refused to run it. The reply says THAT it refused, not WHY — no cause " +
                        "is carried on the wire."
                is CommandRefused ->
                    "REFUSED — the firmware returned FAILURE for ${commands.joinToString(", ")}. " +
                        "That command asks for no ECG data, so this is a fact about that write and NOT " +
                        "evidence that ECG generation is blocked. Nothing here speaks to the block question."
                is AcceptedButSilent ->
                    "Accepted but SILENT — a command that asks for realtime ECG data returned SUCCESS, every " +
                        "other command did too, yet no ECG packet arrived in ${windowSeconds}s. " +
                        "That is the observation; it does not identify a cause. Data banked to flash rather " +
                        "than streamed, a wrong opcode mapping, no start verb among these commands, an " +
                        "entitlement gate and an open electrode circuit all produce this same silence."
                is NoDataRequested ->
                    "NOT A TEST of whether ECG is blocked — this run sent no command that could produce " +
                        "realtime ECG data (${commands.joinToString(", ")}), so zero packets is the EXPECTED " +
                        "outcome and says nothing either way. Run the turn-on sequence to test the block question."
                is DataRequestNotAccepted ->
                    "INCONCLUSIVE — data was requested (${commands.joinToString(", ")}) but the strap never " +
                        "returned SUCCESS for it, so the silence cannot be read as 'accepted, then not " +
                        "honoured'. Retry idle."
                is OpcodeUnsupported ->
                    "Opcode UNSUPPORTED on this firmware for ${commands.joinToString(", ")} — the command " +
                        "is not implemented, which is a different and more final answer than a refusal."
                is NoReplies ->
                    "No COMMAND_RESPONSE at all — the strap answered nothing. Silence is not evidence of a " +
                        "block (a mid-flight sync or a missed notification looks identical); retry idle."
                is Inconclusive ->
                    "INCONCLUSIVE — the result codes do not match a known pattern. The raw replies below are " +
                        "the record."
            }
    }

    /**
     * Classify the run.
     *
     * Order matters, and it puts the ATTESTED signals first: the COMMAND_RESPONSE result codes are real
     * wire semantics, whereas the packet count comes from a shape heuristic that unrelated traffic can
     * trip. So an explicit FAILURE or UNSUPPORTED from the firmware outranks a candidate count.
     *
     * The SECOND rule the order encodes is SCOPE: a claim about "is the ECG feature blocked" is only made
     * when the run exercised the ECG data path. A `FAILURE` on a command that asks for no data is a
     * refusal of that write; silence after a run that asked for no data is the expected outcome. Both get
     * their own verdict rather than being folded into the block case.
     */
    fun verdict(steps: List<Step>, ecgPacketsSeen: Int, windowSeconds: Int): Verdict {
        val failures = steps.filter { it.outcome is CommandOutcome.Failure }
        if (failures.isNotEmpty()) {
            // A refusal is only evidence about the BLOCK question when what was refused asked for data.
            val dataFailures = failures.filter { it.requestsRealtimeData }.map { it.label }
            if (dataFailures.isNotEmpty()) return Verdict.DataRequestRefused(dataFailures)
            return Verdict.CommandRefused(failures.map { it.label })
        }
        val unsupported = steps.filter { it.outcome is CommandOutcome.Unsupported }.map { it.label }
        if (unsupported.isNotEmpty()) return Verdict.OpcodeUnsupported(unsupported)
        if (ecgPacketsSeen > 0) return Verdict.EcgCandidatesArrived(ecgPacketsSeen)
        if (steps.isEmpty()) return Verdict.NoReplies
        if (steps.all { it.outcome is CommandOutcome.NoReply }) return Verdict.NoReplies
        // Past this point the verdict INTERPRETS SILENCE, which only carries information about the ECG
        // data path when the run asked that path for something and the strap said yes.
        val requests = steps.filter { it.requestsRealtimeData }
        if (requests.isEmpty()) return Verdict.NoDataRequested(steps.map { it.label })
        if (requests.none { it.outcome is CommandOutcome.Success }) {
            return Verdict.DataRequestNotAccepted(requests.map { it.label })
        }
        if (steps.all { it.outcome is CommandOutcome.Success }) {
            return Verdict.AcceptedButSilent(windowSeconds)
        }
        return Verdict.Inconclusive
    }

    /**
     * The full report: verdict, per-command outcomes, the ECG-packet tally, and the raw replies.
     *
     * [candidateFrames] are the type/length lines for frames that passed the structural triage in
     * [Whoop5Ecg.plausibleFilteredPayload].
     */
    fun report(
        steps: List<Step>,
        ecgPacketsSeen: Int,
        candidateFrames: List<String>,
        windowSeconds: Int,
    ): String {
        val sb = StringBuilder()
        sb.append("WHOOP MG ECG (Labrador) TURN-ON PROBE\n")
        sb.append("Verdict: ${verdict(steps, ecgPacketsSeen, windowSeconds).headline}\n")
        sb.append("\nCommands sent:\n")
        if (steps.isEmpty()) {
            sb.append("  (none)\n")
        } else {
            // Each step carries WHY it does or does not bear on the block question, so the verdict above
            // can be checked against its own inputs without reading the source.
            for (step in steps) sb.append("  ${step.label}: ${step.outcome.token} — ${step.roleNote}\n")
        }
        sb.append("\nECG-shaped packets seen in ${windowSeconds}s: $ecgPacketsSeen\n")
        if (steps.isNotEmpty() && steps.none { it.requestsRealtimeData }) {
            sb.append(
                "Zero is the EXPECTED result here: nothing in this run asked the strap for realtime ECG data.\n"
            )
        }
        // The ELECTRODE CIRCUIT is the one confound this probe cannot see and the runner can. An MG's ECG
        // needs a closed loop: the wrist electrode plus the two clasp indents held with the OPPOSITE hand.
        // Nothing on the wire reports lead state, so a run where the clasp was never touched is
        // indistinguishable here from a run the firmware ignored — and #891 asks other MG owners to run
        // this, who have no reason to know that. Reported as a QUESTION about the run, never as a finding:
        // it does not claim the leads were open, only that this report cannot rule it out.
        // Twin of the Swift `Whoop5EcgProbe.report` line; the wording is byte-identical.
        if (ecgPacketsSeen == 0 && steps.any { it.requestsRealtimeData }) {
            sb.append(
                "Were the leads closed? An MG measures across the wrist electrode AND the two indents on " +
                    "the clasp, held with the fingers of your OTHER hand for the whole window. Lead state is " +
                    "not on the wire, so this report cannot tell an open circuit from a strap that ignored " +
                    "the command — if the clasp was not held, re-run holding it before reading anything into " +
                    "the zero.\n"
            )
        }
        if (candidateFrames.isEmpty()) {
            sb.append("Candidate packet types: none — no frame passed the structural triage.\n")
        } else {
            sb.append("Candidate packet types (structural triage only, NOT a confirmed mapping):\n")
            for (line in candidateFrames) sb.append("  $line\n")
        }
        val replies = steps.mapNotNull { step -> step.replyHex?.let { "  ${step.label}: $it" } }
        if (replies.isNotEmpty()) {
            sb.append("\nRaw replies:\n")
            sb.append(replies.joinToString("\n") + "\n")
        }
        sb.append("\nThis is unvalidated instrumentation, not a medical measurement or a diagnosis.\n")
        return sb.toString()
    }
}
