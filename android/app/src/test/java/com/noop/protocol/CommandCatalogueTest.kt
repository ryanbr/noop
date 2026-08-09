package com.noop.protocol

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Holds [CommandNames] in lockstep with the shared schema
 * (`Packages/WhoopProtocol/Sources/WhoopProtocol/Resources/whoop_protocol.json`), which iOS reads directly
 * at runtime — the [EventCatalogueTest] treatment of `EventNumber` (#791), applied to the command table it
 * did not cover.
 *
 * Android named only 34 of the schema's 80 commands, so 46 rendered as a bare `0x8B(139)` in an Android
 * strap log while iOS named them, and three more (77, 119, 120) printed a *different* name on each platform.
 * #891 is the case that made it matter: an MG owner's three ECG-toggle replies are the evidence the issue
 * turns on, and its ask is for other owners to run the same probes and post what they see. Half of them
 * would have posted hex.
 *
 * **Why a separate map rather than growing the enum.** [CommandNumber] is the *sender* enum — the 5/MG send
 * path and the 4.0 builders both take one, and it is curated precisely so destructive opcodes cannot be
 * expressed (its own doc comment says so). `EventNumber` could simply be completed because nothing sends an
 * event. Completing `CommandNumber` the same way would have made `FORCE_TRIM` and the firmware-load family
 * constructible, which is the opposite of the safety property. So the reader gets its own dictionary and the
 * sender enum is left alone; [senderEnumStaysCuratedAfterTheLabelFix] pins that separation.
 *
 * The lockstep check `Assume`-skips when the Swift tree is absent, following [EventCatalogueTest] and
 * [DecoderOracleTest]. The targeted checks never skip.
 */
class CommandCatalogueTest {

    private fun bytes(s: String): ByteArray =
        ByteArray(s.length / 2) { ((s[it * 2].digitToInt(16) shl 4) or s[it * 2 + 1].digitToInt(16)).toByte() }

    /** Reads the schema rather than restating it: the bug is "the schema grew and Android did not follow". */
    @Test
    fun everyCommandInTheSharedSchemaIsNamedOnAndroid() {
        val rel = "Packages/WhoopProtocol/Sources/WhoopProtocol/Resources/whoop_protocol.json"
        val userDir = File(System.getProperty("user.dir") ?: ".")
        val schemaFile = listOf(File(userDir, rel), File(userDir, "../../$rel")).firstOrNull { it.exists() }
        org.junit.Assume.assumeTrue(
            "shared schema not found from user.dir=$userDir — skipping the catalogue lockstep check",
            schemaFile != null,
        )
        val cmds = JSONObject(schemaFile!!.readText()).getJSONObject("enums").getJSONObject("CommandNumber")
        val schema = cmds.keys().asSequence().associate { it.toInt() to cmds.getString(it) }
        assertTrue("CommandNumber block parsed empty", schema.isNotEmpty())

        assertEquals(
            "Android is missing commands the schema names",
            emptySet<Int>(), schema.keys - CommandNames.byRaw.keys,
        )
        assertEquals(
            "Android names commands the schema does not",
            emptySet<Int>(), CommandNames.byRaw.keys - schema.keys,
        )
        for ((raw, name) in schema) {
            assertEquals("command $raw", name, CommandNames.byRaw[raw])
        }
    }

    /**
     * The regression this change could itself cause, in the opposite direction.
     *
     * Labels used to come from the sender enum, so every sendable command was named by construction. They
     * now come from the schema, so a command added to the sender enum but not to the schema would render
     * as bare hex — reintroducing, for the commands NOOP actually sends, exactly the defect this fixes for
     * the ones it does not. No opcode is in that state today; this keeps it that way without depending on
     * the Swift tree being present, unlike the lockstep check above.
     */
    @Test
    fun everySendableCommandIsStillNamed() {
        for (cmd in CommandNumber.entries) {
            val label = CommandNames.label(cmd.rawValue)
            assertTrue(
                "${cmd.name}(${cmd.rawValue}) is sendable but would log as $label",
                !label.startsWith("0x"),
            )
        }
    }

    /**
     * The safety property that forced a separate table. Naming an opcode for the reader must never make it
     * sendable: every one of these must stay out of the sender enum while remaining legible in a log.
     *
     * All nine are on the "do not send" list in `docs/PROTOCOL.md` — 142/143/144 only as of this change,
     * which is the point. They were named by the schema, absent from both platforms' sender enums, and
     * missing from that table, so nothing recorded that keeping them out was deliberate. `REBOOT_STRAP`
     * (29) and `POWER_CYCLE_STRAP` (32) are excluded here: both are on the destructive list but are the
     * documented, confirmation-gated restart exceptions, so they legitimately are in the sender enum.
     */
    @Test
    fun senderEnumStaysCuratedAfterTheLabelFix() {
        val destructive = mapOf(
            25 to "FORCE_TRIM",
            36 to "START_FIRMWARE_LOAD",
            37 to "LOAD_FIRMWARE_DATA",
            38 to "PROCESS_FIRMWARE_IMAGE",
            45 to "ENTER_BLE_DFU",
            99 to "RESET_FUEL_GAUGE",
            142 to "START_FIRMWARE_LOAD_NEW",
            143 to "LOAD_FIRMWARE_DATA_NEW",
            144 to "PROCESS_FIRMWARE_IMAGE_NEW",
        )
        for ((raw, name) in destructive) {
            assertNull("opcode $raw must not be sendable", CommandNumber.fromRaw(raw))
            assertEquals("opcode $raw must still be readable", name, CommandNames.byRaw[raw])
        }
    }

    /** The ECG family #891 turns on. None is sendable; all three are now legible. */
    @Test
    fun theMgEcgTogglesAreNamedButNotSendable() {
        assertEquals("TOGGLE_LABRADOR_DATA_GENERATION", CommandNames.byRaw[124])
        assertEquals("TOGGLE_LABRADOR_RAW_SAVE", CommandNames.byRaw[125])
        assertEquals("TOGGLE_LABRADOR_FILTERED", CommandNames.byRaw[139])
        assertNull(CommandNumber.fromRaw(124))
        assertNull(CommandNumber.fromRaw(125))
        assertNull(CommandNumber.fromRaw(139))
    }

    /**
     * Three opcodes where the two platforms printed different names for the same byte, because Android
     * labelled from the sender enum's short case names while iOS asked the schema. The sender enum keeps its
     * own names (they are referenced across the BLE layer on both platforms); only the *label* changes.
     */
    @Test
    fun opcodesThatPrintedDifferentNamesOnEachPlatformNowAgree() {
        assertEquals("SET_ADVERTISING_NAME_HARVARD(77)", CommandNames.label(77))
        assertEquals("SET_DEVICE_CONFIG_VALUE(119)", CommandNames.label(119))
        assertEquals("SET_FF_VALUE(120)", CommandNames.label(120))
        // 140 is the schema's SET_ADVERTISING_NAME — the name Android previously printed for 77.
        assertEquals("SET_ADVERTISING_NAME(140)", CommandNames.label(140))
    }

    /**
     * The labels that are load-bearing, not cosmetic.
     *
     * `WhoopBleClient` reads `parsed["resp_cmd"]` back as a String and branches on `startsWith` — the same
     * shape as the `isRtcStateKind` coupling that made #791's missing event names a behavioural bug rather
     * than a display one. Two of these gate real work: a `GET_DATA_RANGE` + `SUCCESS` pair releases the
     * 5/MG history request during backfill (a drifted label would silently demote that to the 2 s fail-open
     * timer), and the reboot/power-cycle branch is the accept-or-reject signal a 5/MG owner's strap log is
     * read for.
     *
     * Moving the label source from the sender enum to the schema is safe today only because these five
     * names are identical in both. That is currently a coincidence rather than a guarantee, so it is
     * asserted here: if a future schema edit renames one, this fails instead of the backfill quietly
     * getting slower.
     */
    @Test
    fun labelsThatGateBleBehaviourAreUnchangedByTheSchemaSwitch() {
        val loadBearing = mapOf(
            34 to "GET_DATA_RANGE",     // releases the 5/MG history request
            29 to "REBOOT_STRAP",       // reboot accept/reject signal
            32 to "POWER_CYCLE_STRAP",  // same branch
            66 to "SET_ALARM_TIME",     // 4.0 alarm readback
            67 to "GET_ALARM_TIME",     // 4.0 alarm readback
        )
        for ((raw, prefix) in loadBearing) {
            assertTrue(
                "opcode $raw must still label as $prefix — WhoopBleClient branches on this prefix",
                CommandNames.label(raw).startsWith(prefix),
            )
            // The sender enum reaches the same name, which is why the switch is behaviour-preserving.
            assertEquals("opcode $raw", prefix, CommandNumber.fromRaw(raw)?.name)
        }
    }

    /** An opcode neither platform knows must stay hex: a borrowed or invented name is worse than a number. */
    @Test
    fun unknownCommandsAreNotGivenInventedNames() {
        assertNull(CommandNames.byRaw[200])
        assertEquals("0xC8(200)", CommandNames.label(200))
        assertEquals("0xFF(255)", CommandNames.label(255))
    }

    /**
     * The real WHOOP 5 MG (`WS50_r03`) replies posted in #891, decoded end to end.
     *
     * All three are structurally valid — declared length, CRC16-Modbus header and CRC32 tail all verify —
     * and each answers SUCCESS. Before this change `resp_cmd` read `0x8B(139)` / `0x7D(125)` / `0x7C(124)`
     * on Android and the named form on Apple, from the identical bytes. Committed as fixtures because they
     * are the only real 5/MG COMMAND_RESPONSE frames in the tree whose payload is inert: `01 01 00 00`
     * carries no device name, serial or session token.
     */
    @Test
    fun realMgToggleRepliesNameTheirCommand() {
        val replies = listOf(
            Triple("aa010c000100271124148b2f01010000845a1705", "TOGGLE_LABRADOR_FILTERED(139)", 47),
            Triple("aa010c000100271124157d300101000067ab1b82", "TOGGLE_LABRADOR_RAW_SAVE(125)", 48),
            Triple("aa010c000100271124167c3101010000ef4bcf45", "TOGGLE_LABRADOR_DATA_GENERATION(124)", 49),
        )
        for ((hex, label, respSeq) in replies) {
            val f = Framing.parseFrame(bytes(hex), DeviceFamily.WHOOP5)
            assertTrue("frame did not parse: $hex", f.ok)
            assertEquals("CRC must verify: $hex", true, f.crcOk)
            assertEquals("COMMAND_RESPONSE", f.typeName)
            assertEquals(label, f.parsed["resp_cmd"])
            assertEquals(respSeq, f.parsed["resp_seq"])
            assertEquals("SUCCESS(1)", f.parsed["result"])
        }
    }

    /**
     * A real `SELECT_WRIST(123)` pair from the same MG, one accepted and one refused (#891).
     *
     * The refusal is the first REAL 5/MG frame in the tree carrying `result = FAILURE(0)` — every other
     * non-SUCCESS fixture on this family is a synthetic `GET_HELLO`, so that branch of the decode had
     * never been exercised by bytes a strap actually sent. Together they are a success/failure pair on
     * one opcode, the shape that made the 4.0 result mapping credible.
     *
     * Provenance: WHOOP 5 MG `WS50_r03`, build 215, posted with the raw frames in #891. Payload inert.
     * The strap accepted `arg=1` and refused `arg=0` minutes apart in one session, so the refusal is not
     * "unknown opcode"; whether it refuses a real mutation or `0` is simply invalid is open, and nothing
     * here decides it. The Swift twin asserts these identical bytes.
     */
    @Test
    fun realMgSelectWristAcceptedAndRefused() {
        val accepted = Framing.parseFrame(bytes("aa010c000100271124d77b81010100007ce76722"), DeviceFamily.WHOOP5)
        assertEquals(true, accepted.crcOk)
        assertEquals("SELECT_WRIST(123)", accepted.parsed["resp_cmd"])
        assertEquals(129, accepted.parsed["resp_seq"])
        assertEquals("SUCCESS(1)", accepted.parsed["result"])

        val refused = Framing.parseFrame(bytes("aa010c000100271124217bcc000100000213163d"), DeviceFamily.WHOOP5)
        assertEquals(true, refused.crcOk)
        assertEquals("SELECT_WRIST(123)", refused.parsed["resp_cmd"])
        assertEquals(204, refused.parsed["resp_seq"])
        assertEquals("FAILURE(0)", refused.parsed["result"])
    }

    /**
     * The toggles are not battery reads, so nothing may be claimed from the value slot.
     *
     * Byte 13 — the first response-payload byte, where `GET_BATTERY_LEVEL` returns its percent — is `0x01`
     * in all three replies. That is the only positive signal in #891 that a flag took a value, and it is
     * deliberately NOT decoded into a field: whether it echoes the requested value or reads back stored
     * state is exactly what the issue cannot yet distinguish (#194).
     */
    @Test
    fun noValueIsInventedFromTheToggleReplies() {
        val f = Framing.parseFrame(bytes("aa010c000100271124148b2f01010000845a1705"), DeviceFamily.WHOOP5)
        assertNotNull(f.parsed["result"])
        assertNull("no battery percent may be read from a non-battery reply", f.parsed["battery_pct"])
    }
}
