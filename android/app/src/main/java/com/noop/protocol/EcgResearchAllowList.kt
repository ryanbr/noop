package com.noop.protocol

/**
 * #891 / #1100: the ALLOW-LIST that bounds what the MG ECG Research panel may put on the wire, and the
 * named DENY-LIST of opcodes it must never be able to form.
 *
 * ## Why an allow-list, and why here
 *
 * The research panel exists to gather protocol evidence about the MG's ECG ("Labrador") subsystem — NOT to
 * sweep the command space. The single most dangerous thing a hand-run ECG probe could do is wander into a
 * neighbouring opcode: `TOGGLE_LABRADOR_FILTERED` is **139 (0x8B)**, and three codes above it sit
 * **142/143/144 — `START_FIRMWARE_LOAD_NEW` / `LOAD_FIRMWARE_DATA_NEW` / `PROCESS_FIRMWARE_IMAGE_NEW`**, the
 * destructive firmware-load family (`docs/PROTOCOL.md` §9.1). So this file states the *entire* set of
 * opcodes the panel can dispatch as a literal, testable predicate, rather than trusting a UI never to build
 * anything else.
 *
 * This mirrors the discipline the rest of the 5/MG send path already follows — `DeviceConfigWriteGate`
 * (key-aware SET allow-list), `DeviceConfigReadProbe.isReadOnlyOpcode`, `FeatureFlagWriteGate`. Like those,
 * it is a pure predicate the real BLE send path consults ([WhoopBleClient.ecgSendAdmitted] calls
 * [isProbeOpcode]), so a unit test proving this rejects an opcode is proving it about the wire path and not
 * a parallel copy of the rule.
 *
 * Pure: no Android, no I/O. Twin-free — Android is the platform growing an ECG *app* layer first (the Apple
 * probe drives the same four opcodes but expresses its allow-list inline in `BLEManager.send`).
 */
object EcgResearchAllowList {

    // ---- The four ECG ("Labrador") probe opcodes — the ONLY commands the panel dispatches ----------

    /**
     * The four opcodes the panel may send, each a documented WORKING HYPOTHESIS (not a confirmed mapping —
     * see `docs/PROTOCOL.md` §9.1). Every one is a plain toggle/config write with a `[revision, arg]`
     * payload; none loads firmware, wipes flash, or resets a bond. Kept in [Whoop5Ecg] so the numbers live
     * with the command builders and this set can never drift from what [Whoop5Ecg.commandFrame] forms.
     */
    val PROBE_OPCODES: Set<Int> = setOf(
        Whoop5Ecg.SELECT_WRIST_CMD,                      // 123 (0x7B) — PERSISTENT wrist config (own action)
        Whoop5Ecg.TOGGLE_REALTIME_FILTERED_ECG_CMD,      // 139 (0x8B) — live filtered stream toggle
        Whoop5Ecg.TOGGLE_SAVE_RAW_ECG_CMD,               // 125 (0x7D) — persist-to-flash toggle
        Whoop5Ecg.MAIN_CONTROL_ECG_DATA_GENERATION_CMD,  // 124 (0x7C) — start/stop generation
    )

    /**
     * The two DEVICE-CONFIG opcodes the panel's persistent `enable_raw_data_w_ecg` gate uses — a WRITE
     * (119) and its mandatory read-back (121). These are NOT dispatched as ECG commands; they go through
     * the pre-existing, key-aware [DeviceConfigWriteGate] path ([WhoopBleClient.setEcgRawDataGate]). Named
     * here only so a reader sees the panel's complete wire surface in one place.
     */
    val GATE_OPCODES: Set<Int> = setOf(
        DeviceConfigWriteGate.SET_DEVICE_CONFIG_VALUE_CMD,   // 119 (0x77)
        DeviceConfigWriteGate.GET_DEVICE_CONFIG_VALUE_CMD,   // 121 (0x79)
    )

    /** True only for one of the four ECG probe opcodes. The predicate the BLE send allow-list consults. */
    fun isProbeOpcode(opcode: Int): Boolean = opcode in PROBE_OPCODES

    /** True for the two device-config gate opcodes (write + read-back). */
    fun isGateOpcode(opcode: Int): Boolean = opcode in GATE_OPCODES

    /** The complete set of opcodes reachable from the panel, ECG toggles plus the gate's two verbs. */
    val DISPATCHABLE_OPCODES: Set<Int> = PROBE_OPCODES + GATE_OPCODES

    // ---- The deny-list: opcodes this panel must NEVER be able to form (Phase 11) -------------------

    /**
     * Named dangerous / persistent-state / recovery-defeating opcodes the ECG research panel must never
     * dispatch. This is defence-in-depth documentation, NOT the enforcement mechanism — enforcement is the
     * positive allow-list ([isProbeOpcode]); nothing here can be sent because it is not in [PROBE_OPCODES],
     * and most are not even in the curated [CommandNumber] SENDER enum so no builder can express them.
     *
     * Listed (rather than merely omitted) so a unit test can assert every one of them is refused by
     * [isProbeOpcode] and is absent from [DISPATCHABLE_OPCODES] — the "no opcode sweep, no DFU" guarantee
     * made checkable. Values are the schema numbers from [CommandNames].
     */
    val FORBIDDEN: Map<Int, String> = mapOf(
        // Firmware load / DFU — the family that sits just above 139 in opcode space, and the reason an
        // ECG sweep is dangerous. NOOP's curated CommandNumber enum omits all of these entirely.
        36 to "START_FIRMWARE_LOAD",
        37 to "LOAD_FIRMWARE_DATA",
        38 to "PROCESS_FIRMWARE_IMAGE",
        45 to "ENTER_BLE_DFU",
        83 to "VERIFY_FIRMWARE_IMAGE",
        142 to "START_FIRMWARE_LOAD_NEW",
        143 to "LOAD_FIRMWARE_DATA_NEW",
        144 to "PROCESS_FIRMWARE_IMAGE_NEW",
        // Data-wipe / fuel-gauge / factory-adjacent.
        25 to "FORCE_TRIM",
        99 to "RESET_FUEL_GAUGE",
        100 to "CALIBRATE_CAPSENSE",
        // Reboot / power-cycle — recovery is via the app's ordinary reconnect, never a strap reset from
        // this panel.
        29 to "REBOOT_STRAP",
        32 to "POWER_CYCLE_STRAP",
        // High-frequency sync entry — an uncertain, battery-heavy mode NOOP deliberately never enters
        // (docs/PROTOCOL.md note on 96); the panel does not offer it.
        96 to "ENTER_HIGH_FREQ_SYNC",
        97 to "EXIT_HIGH_FREQ_SYNC",
        // Optical / AFE / bias front-end writes — persistent sensor calibration, out of scope for ECG.
        39 to "SET_LED_DRIVE",
        41 to "SET_TIA_GAIN",
        43 to "SET_BIAS_OFFSET",
        61 to "SET_AFE_PARAMETERS",
    )

    /** True if [opcode] is a named-forbidden opcode. Used by the census test; never a dispatch input. */
    fun isForbidden(opcode: Int): Boolean = FORBIDDEN.containsKey(opcode)

    /** Schema label for any opcode, e.g. `"TOGGLE_LABRADOR_FILTERED(139)"`, for logs/reports. */
    fun label(opcode: Int): String = CommandNames.label(opcode)
}
