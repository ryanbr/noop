package com.noop.protocol

/**
 * #174: the key-aware allowlist for SET_FF_VALUE (120 / 0x78) — the feature-flag WRITE verb the R22
 * enable and disable sequences share. Direct twin of the Swift `FeatureFlagWriteGate`
 * (Packages/WhoopProtocol/Sources/WhoopProtocol/R22Disable.swift) — keep them byte-identical.
 *
 * Before this file the 5/MG send path admitted opcode 120 on an opcode-only clause (the deep-data opt-in
 * alone), which admits ANY feature-flag key with ANY value for as long as that opt-in happens to be on.
 * The sixteen R22 keys are the only ones NOOP has business writing, and the disable path doubles the
 * number of values travelling through that opcode, so the clause is tightened rather than widened. Same
 * discipline as `DeviceConfigReadProbe.isReadOnlyOpcode`: one pure predicate the send path itself
 * consults, so a unit test proving the predicate rejects something proves it about the real wire path.
 *
 * TWO predicates, not one, because the enable and disable directions have different gates as well as
 * different values:
 *
 *  - [admitsEnableWrite] — opcode 120, an R22 key, that key's own ENABLE value, while the deep-data
 *    opt-in is on.
 *  - [admitsDisableWrite] — opcode 120, an R22 key, [Whoop5Config.FEATURE_FLAG_OFF_VALUE] only, while a
 *    disable run is in flight.
 *
 * The disable direction CANNOT be gated on the opt-in: the Settings switch writes the preference false
 * before the confirmation dialog is raised, so the pref is already false by the time the user confirms the
 * undo — gating on it made the toggle-off path dead. The run is the gate that is actually about this
 * operation, and it is narrower the other way too: a merely-left-on opt-in sends no off value at all.
 * Splitting them makes the invariant exact — an off value on the wire means a run is in flight.
 *
 * Pure: no Bluetooth, no I/O, no preferences. The app layer supplies the gate booleans.
 */
object FeatureFlagWriteGate {

    /** SET_FF_VALUE (120 / 0x78) — the feature-flag write verb. The only opcode this gate admits. */
    const val SET_FEATURE_FLAG_VALUE_CMD = 120

    /** SET_DEVICE_CONFIG_VALUE (119 / 0x77) — the OTHER namespace's write verb. Named here for exactly
     *  one reason: so [admitsSend] can be proved to refuse it. */
    const val SET_DEVICE_CONFIG_VALUE_CMD = 119

    /** GET_FF_VALUE (128 / 0x80) — the read verb the mandatory post-write read-back uses. */
    const val GET_FEATURE_FLAG_VALUE_CMD = 128

    /** Width of the key-name field in a feature-flag body (`Whoop5Config.payloadBody` NUL-pads to this). */
    const val NAME_FIELD_BYTES = 32

    /** Total length of the feature-flag body: 32-byte name, value byte, 7 zero bytes. */
    const val BODY_BYTES = 40

    /** The sixteen keys, taken from the enable sequence rather than restated — one list, one truth. */
    val r22Keys: List<String> get() = Whoop5Config.enableR22Sequence.map { it.name }

    /** The value the enable sequence writes for [key], or null when [key] is not an R22 flag. */
    fun enableValue(key: String): Int? =
        Whoop5Config.enableR22Sequence.firstOrNull { it.name == key }?.value

    /** Whether [value] is the ENABLE value for [key] — the only value the enable direction may write. */
    fun isEnableValue(value: Int, key: String): Boolean {
        val on = enableValue(key) ?: return false
        return value == on
    }

    /** Whether [key] is one of the sixteen AND [value] is the off value — the only pair the disable
     *  direction may write. The key check is what stops the off value reaching an arbitrary flag. */
    fun isOffValue(value: Int, key: String): Boolean {
        enableValue(key) ?: return false
        return value == Whoop5Config.FEATURE_FLAG_OFF_VALUE
    }

    /** One parsed SET_FF_VALUE body. */
    data class KeyValue(val key: String, val value: Int)

    /**
     * The key name and value carried by a SET_FF_VALUE payload, or null when the payload is not shaped
     * like one. The payload the send path holds is `[0x01] + payloadBody(...)`. A name is only returned
     * when it is printable ASCII and the remainder of the field is genuine NUL padding, so a short,
     * mis-shaped or binary-carrying body yields null and is refused rather than guessed at.
     */
    fun keyAndValue(sendPayload: ByteArray): KeyValue? {
        if (sendPayload.size < 1 + BODY_BYTES) return null
        if (sendPayload[0].toInt() != 0x01) return null
        val name = StringBuilder()
        for (i in 0 until NAME_FIELD_BYTES) {
            val b = sendPayload[1 + i].toInt() and 0xFF
            if (b == 0) {
                // Everything after the name must be NUL, or this is not a NUL-padded name field.
                for (j in i until NAME_FIELD_BYTES) {
                    if ((sendPayload[1 + j].toInt() and 0xFF) != 0) return null
                }
                break
            }
            if (b < 0x20 || b > 0x7E) return null
            name.append(b.toChar())
        }
        if (name.isEmpty()) return null
        return KeyValue(name.toString(), sendPayload[1 + NAME_FIELD_BYTES].toInt() and 0xFF)
    }

    /**
     * **The enable direction's send allowlist.** True only for SET_FF_VALUE(120) carrying a well-formed
     * body whose key is one of the sixteen and whose value is that key's own enable value, while the
     * deep-data opt-in is on. Every other opcode is false — explicitly including
     * SET_DEVICE_CONFIG_VALUE(119), which keeps its own clause. The off value is NOT admitted here.
     */
    fun admitsEnableWrite(opcode: Int, payload: ByteArray, deepDataOptIn: Boolean): Boolean {
        if (!deepDataOptIn) return false
        if (opcode != SET_FEATURE_FLAG_VALUE_CMD) return false
        val kv = keyAndValue(payload) ?: return false
        return isEnableValue(kv.value, kv.key)
    }

    /**
     * **The disable direction's send allowlist.** True only for SET_FF_VALUE(120) carrying a well-formed
     * body whose key is one of the sixteen and whose value is [Whoop5Config.FEATURE_FLAG_OFF_VALUE], while
     * a disable run is actually in flight.
     *
     * [disableRunInFlight] is `r22DisableRun != null` at the call site — deliberately NOT the deep-data
     * preference, which is already false by the time a user confirms the undo the switch itself offered.
     */
    fun admitsDisableWrite(opcode: Int, payload: ByteArray, disableRunInFlight: Boolean): Boolean {
        if (!disableRunInFlight) return false
        if (opcode != SET_FEATURE_FLAG_VALUE_CMD) return false
        val kv = keyAndValue(payload) ?: return false
        return isOffValue(kv.value, kv.key)
    }

    /** The read verb the post-write verification is allowed to send, and only that one. */
    fun isReadBackOpcode(opcode: Int): Boolean = opcode == GET_FEATURE_FLAG_VALUE_CMD
}

/**
 * #174: one R22 DISABLE run — write '0' to the sixteen feature flags, then read every one of them back
 * and report the value the strap actually stores. Twin of the Swift `R22DisableReport`; the rendered text
 * is byte-identical across platforms so a shared strap log reads the same either side.
 *
 * The run is staged because the off value is inferred (see [Whoop5Config.FEATURE_FLAG_OFF_VALUE]):
 *  1. Probe — write '0' to ONE flag, read it back with GET_FF_VALUE(128).
 *  2. Gate — if the strap did not stop reporting the old value, STOP. Fifteen keys stay untouched and the
 *     report says '0' is not how this namespace spells off, which is a real, publishable answer.
 *  3. Clear — only on a good probe, write '0' to the remaining fifteen.
 *  4. Verify — read all sixteen back and tabulate.
 *
 * Every write's own COMMAND_RESPONSE is recorded and NOT believed: SELECT_WRIST returns SUCCESS for a
 * no-op and FAILURE for a real mutation on this firmware, so a result byte says nothing reliable about
 * whether state moved. Only the value a 128 read returns is reported as state (#907/#891).
 *
 * Pure and order-dependent (nextStep -> note... -> nextStep), so the whole verdict table is unit-testable
 * without a strap.
 */
class R22DisableReport(
    val keys: List<String> = Whoop5Config.enableR22Sequence.map { it.name },
) {

    companion object {
        /**
         * The flag the probe stage writes first.
         *
         * `enable_sig12` is chosen because it is the ONLY key with a hardware demonstration that a write
         * to it changes stored state: the enable sequence moved it from '2' (0x32) to '1' (0x31),
         * confirmed by a GET_FF_VALUE(128) read before and after (#423, #103). If a '0' write to THIS key
         * does not move the stored value, the failure is attributable to the VALUE rather than to the key
         * or the verb — every other key would leave that ambiguity open. It is also the flag with the
         * least to lose: its effect is undocumented and it gates no stream NOOP reads.
         */
        const val PROBE_KEY = "enable_sig12"

        /** The standing caveats, kept in one place so the UI, the log and the report cannot drift. */
        val CAVEATS = """
            What this does and does not establish:
              • '0' as the off value is INFERRED. It is the confirmed off value in the device-config
                namespace (SET_DEVICE_CONFIG_VALUE/119, hardware-validated on the Broadcast-HR flag, #181)
                and that namespace shares this one's whole wire idiom — but no feature flag had ever been
                observed holding '0' before this run. The read-back above is what turns that inference
                into a measurement.
              • A cleared flag is not the same as reverted BEHAVIOUR. This reports what the strap STORES.
                Whether the deep records actually stop is a separate question, answered by wearing the
                strap and watching the type-0x2F deep-buffer capture stop, not by this report.
              • This does not restore a snapshot. NOOP never read these values before first writing them,
                so the strap's pre-NOOP state is unknown. The honest claim is "cleared the flags NOOP set".
              • disable_pip_r26_packets inverts: clearing it is expected to let PIP R26 packets flow AGAIN.
                That is the pre-R22 behaviour and is intended.
        """.trimIndent()
    }

    /** Which stage of the run a step belongs to. */
    enum class Stage { PROBE_WRITE, PROBE_READ, CLEAR_WRITE, VERIFY_READ }

    /** One planned round-trip. */
    data class Step(val opcode: Int, val key: String, val stage: Stage) {
        val isWrite: Boolean get() = stage == Stage.PROBE_WRITE || stage == Stage.CLEAR_WRITE
    }

    /** What one key ended up in. CLEARED and UNSET are both successes. */
    enum class KeyOutcome(val label: String) {
        /** Read back as '0': the key exists and now holds the off value. */
        CLEARED("cleared"),
        /** The strap answered FAILURE for the key: it no longer has a stored value. The stronger result. */
        UNSET("unset"),
        /** Read back as something other than '0' — the write did not take. */
        UNCHANGED("unchanged"),
        /** The strap answered but did not echo the key, so no value can be claimed. */
        NOT_CLAIMED("notClaimed"),
        /** No reply inside the step's window. */
        SILENT("silent"),
        /** A reply arrived that could not be decoded. */
        UNDECODABLE("undecodable"),
        /** The run stopped before this key was written. */
        SKIPPED("skipped");

        val isSuccess: Boolean get() = this == CLEARED || this == UNSET
    }

    /** The overall verdict. */
    enum class Verdict(val label: String) {
        PENDING("pending"),
        ALL_CLEARED("allCleared"),
        PARTIAL("partial"),
        /** The probe read-back showed the OLD value: '0' is not how this firmware clears a flag. */
        OFF_VALUE_REJECTED("offValueRejected"),
        /** The probe read-back produced no usable answer. Distinct from a rejection on purpose: nothing
         *  was learned about the off value, so it must not be reported as evidence against it. */
        PROBE_INCONCLUSIVE("probeInconclusive"),
        /** The run refused to start because the key list does not contain PROBE_KEY, so the off value
         *  could not be tested on one flag first. Nothing was sent. Distinct from PROBE_INCONCLUSIVE:
         *  there the probe ran and answered nothing, here it could not run at all. */
        PROBE_UNAVAILABLE("probeUnavailable"),
        ABANDONED("abandoned"),
    }

    /** One recorded read-back. */
    data class Reading(
        val key: String,
        val stage: Stage,
        val value: Int?,
        val resultCode: Int?,
        val recordHex: String,
        val outcome: KeyOutcome,
    )

    private var cursor = 0
    private var plan: MutableList<Step> = mutableListOf()
    private var planBuilt = false
    private var stopped = false

    val outcomes: MutableMap<String, KeyOutcome> = linkedMapOf()
    val readings: MutableList<Reading> = mutableListOf()
    val writeAcks: MutableMap<String, Int> = linkedMapOf()
    val trace: MutableList<String> = mutableListOf()
    var verdict: Verdict = Verdict.PENDING
        private set
    var probePassed = false
        private set

    init {
        trace.add(
            "R22 disable: writing '0' (0x30) to ${keys.size} feature flags via SET_FF_VALUE(120), " +
                "each verified with GET_FF_VALUE(128). The write acks are recorded and NOT trusted."
        )
        trace.add(
            "Probe first: $PROBE_KEY is written and read back alone; the other " +
                "${maxOf(0, keys.size - 1)} are only written if the strap stops reporting the old value."
        )
    }

    /**
     * The next round-trip, or null when the run is over. Built lazily in two halves so the gate is
     * expressible: the probe pair up front, and the clear+verify tail only once the probe has passed.
     */
    fun nextStep(): Step? {
        if (plan.isEmpty() && !planBuilt) {
            planBuilt = true
            if (!keys.contains(PROBE_KEY)) {
                // FAIL CLOSED. This used to plan a blanket sequential run and set probePassed = true, which
                // defeated the point of the design: the safety argument for writing an INFERRED value to
                // sixteen persistent flags is that one flag is written and read back first, and a key list
                // without the probe key cannot make that argument. Writing all sixteen unprobed is the one
                // outcome the staging exists to prevent, and probePassed recorded a probe that never ran.
                // Unreachable from either shipped call site (both use the default key list), but fail-open
                // on a write path is not a defensible default whatever the current call sites do.
                stopped = true
                keys.forEach { outcomes[it] = KeyOutcome.SKIPPED }
                verdict = Verdict.PROBE_UNAVAILABLE
                trace.add(
                    "REFUSED: the key list does not contain the probe key $PROBE_KEY, so '0' cannot be " +
                        "tested on one flag before the other ${maxOf(0, keys.size - 1)} are written. " +
                        "Nothing was sent."
                )
                return null
            }
            plan.add(Step(FeatureFlagWriteGate.SET_FEATURE_FLAG_VALUE_CMD, PROBE_KEY, Stage.PROBE_WRITE))
            plan.add(Step(FeatureFlagWriteGate.GET_FEATURE_FLAG_VALUE_CMD, PROBE_KEY, Stage.PROBE_READ))
        }
        if (stopped) return null
        if (cursor >= plan.size) {
            if (probePassed && plan.none { it.stage == Stage.CLEAR_WRITE }) {
                keys.filter { it != PROBE_KEY }.forEach {
                    plan.add(Step(FeatureFlagWriteGate.SET_FEATURE_FLAG_VALUE_CMD, it, Stage.CLEAR_WRITE))
                }
                keys.forEach { plan.add(Step(FeatureFlagWriteGate.GET_FEATURE_FLAG_VALUE_CMD, it, Stage.VERIFY_READ)) }
            } else {
                return null
            }
        }
        if (cursor >= plan.size) return null
        return plan[cursor++]
    }

    /** Record a write's own ack. Logged, never used to decide anything. */
    fun noteWriteAck(resultCode: Int?, step: Step) {
        if (resultCode != null) writeAcks[step.key] = resultCode
        val label = if (resultCode != null) "${FeatureFlagProbe.resultLabel(resultCode)}($resultCode)" else "(unlabelled)"
        trace.add("SET_FF_VALUE(120) ${step.key}='0' → ack $label — recorded, not proof")
    }

    /** Record a decoded read-back and score the key. */
    fun noteReadBack(r: DeviceConfigReadProbe.ValueResponse, step: Step) {
        val value = r.valueFor(step.key)
        val outcome = when {
            r.isUnsupported -> KeyOutcome.UNCHANGED     // the verb is refused; nothing can be claimed cleared
            r.isFailure -> KeyOutcome.UNSET             // no stored value for this key any more
            value != null ->
                if (value == Whoop5Config.FEATURE_FLAG_OFF_VALUE) KeyOutcome.CLEARED else KeyOutcome.UNCHANGED
            else -> KeyOutcome.NOT_CLAIMED
        }
        record(Reading(step.key, step.stage, value, r.resultCode, r.recordHex, outcome), step)
    }

    /** Record a read-back reply that could not be decoded. */
    fun noteReadFailure(f: DeviceConfigReadProbe.ParseFailure, step: Step) {
        val why = when (f) {
            DeviceConfigReadProbe.ParseFailure.CRC -> "CRC failed — frame rejected (never decoded)"
            DeviceConfigReadProbe.ParseFailure.ENVELOPE -> "not a COMMAND_RESPONSE envelope"
            DeviceConfigReadProbe.ParseFailure.WRONG_COMMAND -> "COMMAND_RESPONSE for a different command"
            DeviceConfigReadProbe.ParseFailure.TRUNCATED -> "record too short to hold a response"
        }
        trace.add("GET_FF_VALUE(128) ${step.key} → reply not decoded: $why")
        record(Reading(step.key, step.stage, null, null, "(undecodable)", KeyOutcome.UNDECODABLE), step)
    }

    /** Record the strap answering nothing at all. */
    fun noteTimeout(step: Step, seconds: Int) {
        val verb = if (step.isWrite) "SET_FF_VALUE(120)" else "GET_FF_VALUE(128)"
        trace.add("$verb ${step.key} → no COMMAND_RESPONSE within ${seconds}s")
        if (step.isWrite) return   // a silent WRITE is fine; the read-back is what decides
        record(Reading(step.key, step.stage, null, null, "(no reply)", KeyOutcome.SILENT), step)
    }

    /** The link dropped, or the caller stopped the run. */
    fun noteAbandoned(why: String) {
        trace.add("Run abandoned: $why")
        stopped = true
        keys.forEach { if (outcomes[it] == null) outcomes[it] = KeyOutcome.SKIPPED }
        verdict = Verdict.ABANDONED
    }

    private fun record(reading: Reading, step: Step) {
        readings.add(reading)
        var line = "GET_FF_VALUE(128) ${step.key}"
        line += if (reading.resultCode != null) {
            " → result=${FeatureFlagProbe.resultLabel(reading.resultCode)}(${reading.resultCode})"
        } else " →"
        if (reading.value != null) line += " value=${DeviceConfigReadProbe.valueLabel(reading.value)}"
        line += " record=[${reading.recordHex}] ⇒ ${reading.outcome.label}"
        trace.add(line)

        outcomes[step.key] = reading.outcome

        if (step.stage == Stage.PROBE_READ) {
            probePassed = reading.outcome.isSuccess
            if (!probePassed) {
                stopped = true
                keys.forEach { if (it != step.key) outcomes[it] = KeyOutcome.SKIPPED }
                // ONLY an unmoved value is evidence against '0'. Silence, an undecodable frame and a reply
                // that never echoed the key all mean "no usable answer".
                verdict = if (reading.outcome == KeyOutcome.UNCHANGED) {
                    Verdict.OFF_VALUE_REJECTED
                } else Verdict.PROBE_INCONCLUSIVE
                trace.add(probeStopExplanation(reading.outcome))
            } else {
                trace.add(
                    "Probe passed (${reading.outcome.label}) — '0' moves a feature flag on this firmware. " +
                        "Clearing the remaining ${maxOf(0, keys.size - 1)}."
                )
            }
        }

        if (!stopped && outcomes.size == keys.size && readings.any { it.stage == Stage.VERIFY_READ }) {
            val cleared = keys.count { outcomes[it]?.isSuccess == true }
            verdict = if (cleared == keys.size) Verdict.ALL_CLEARED else Verdict.PARTIAL
        }
    }

    private fun probeStopExplanation(outcome: KeyOutcome): String = when (outcome) {
        KeyOutcome.UNCHANGED ->
            "STOPPED: the strap still reports the old value for $PROBE_KEY, so '0' (0x30) is NOT how this " +
                "firmware clears a feature flag. The other ${maxOf(0, keys.size - 1)} flags were left " +
                "untouched. This is a real finding — please share this report on #174."
        KeyOutcome.NOT_CLAIMED ->
            "STOPPED: the strap answered but did not echo $PROBE_KEY, so no value can be claimed either " +
                "way. Nothing further was written."
        KeyOutcome.SILENT, KeyOutcome.UNDECODABLE ->
            "STOPPED: no usable read-back for $PROBE_KEY, so whether the write landed is unknown. Nothing " +
                "further was written."
        else -> "STOPPED before clearing the remaining flags."
    }

    /** One-line summary, suitable for a Settings row. */
    val summary: String
        get() {
            val cleared = keys.count { outcomes[it]?.isSuccess == true }
            return when (verdict) {
                Verdict.PENDING -> "Clearing R22 flags…"
                Verdict.ALL_CLEARED -> "All ${keys.size} R22 flags cleared on the strap (read back, not just acked)."
                Verdict.PARTIAL -> "$cleared of ${keys.size} R22 flags cleared — the rest did not take."
                Verdict.OFF_VALUE_REJECTED -> "The strap refused '0' for $PROBE_KEY; the other flags were left alone."
                Verdict.PROBE_INCONCLUSIVE -> "No usable read-back for $PROBE_KEY — nothing further was written."
                Verdict.PROBE_UNAVAILABLE -> "Refused to run: $PROBE_KEY is not in the key list, so the off value could not be probed first. Nothing was sent."
                Verdict.ABANDONED -> "Disable run interrupted — $cleared of ${keys.size} flags confirmed cleared."
            }
        }

    /** The full copyable report. */
    fun render(): String {
        val sb = StringBuilder()
        sb.append("#174 R22 DEEP-DATA DISABLE — WHOOP 5/MG\n")
        sb.append("Wrote '0' (0x30) via SET_FF_VALUE(120) and read every key back with GET_FF_VALUE(128).\n")
        sb.append("The write acks are recorded and NOT treated as proof: on this firmware a SUCCESS result byte\n")
        sb.append("does not establish that state changed. Only the read-back is reported as state.\n")
        sb.append("\nVerdict: ${verdict.label} — $summary\n")
        sb.append("\nPer key:\n")
        for (key in keys) {
            val outcome = outcomes[key] ?: KeyOutcome.SKIPPED
            val reading = readings.lastOrNull { it.key == key && it.stage == Stage.VERIFY_READ }
                ?: readings.lastOrNull { it.key == key }
            val was = Whoop5Config.enableR22Sequence.firstOrNull { it.name == key }
                ?.let { DeviceConfigReadProbe.valueLabel(it.value) } ?: "?"
            val now = reading?.value?.let { DeviceConfigReadProbe.valueLabel(it) }
                ?: if (outcome == KeyOutcome.UNSET) "(no stored value)" else "(not claimed)"
            sb.append("  ${DeviceConfigReadProbe.padded(key, 30)} enable wrote $was → now $now  [${outcome.label}]\n")
        }
        sb.append("\nExchange:\n")
        for (line in trace) sb.append("  ").append(line).append("\n")
        sb.append("\n").append(CAVEATS)
        return sb.toString()
    }
}
