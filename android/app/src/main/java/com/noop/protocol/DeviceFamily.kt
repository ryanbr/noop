package com.noop.protocol

/** Which checksum guards the frame header for a given device family. */
enum class HeaderCRCKind {
    /** CRC8 (poly 0x07) over the two declared-length bytes — Whoop 4.0. */
    CRC8,

    /** CRC16-Modbus (poly 0xA001, init 0xFFFF, reflected) over the header prefix — Whoop 5.0. */
    CRC16_MODBUS,
}

/**
 * Which WHOOP hardware generation a connection / capture belongs to.
 *
 * This module is platform-pure: it never imports Android Bluetooth types. The BLE layer is
 * responsible for turning the UUID *strings* exposed here into `UUID`/`ParcelUuid` values. Keeping
 * platform UUID types out of this module lets the protocol code run on a plain JVM (and in tests).
 */
enum class DeviceFamily {
    /** Whoop 4.0 — 0x07 CRC8 header check. */
    WHOOP4,

    /** Whoop 5.0 / MG — CRC16-Modbus header check, "puffin" packet types. */
    WHOOP5;

    /** The header-CRC algorithm this family uses; the payload CRC32 is identical for both. */
    val headerCRCKind: HeaderCRCKind
        get() = when (this) {
            WHOOP4 -> HeaderCRCKind.CRC8
            WHOOP5 -> HeaderCRCKind.CRC16_MODBUS
        }

    /** Primary GATT service UUID *string* for this family (lowercase, as advertised). */
    val serviceUuidString: String
        get() = when (this) {
            WHOOP4 -> "61080001-8d6d-82b8-614a-1c8cb0f8dcc6"
            WHOOP5 -> "fd4b0001-cce1-4033-93ce-002d5875f58a"
        }

    /** Characteristic UUID *strings* this family uses, in stable ascending order. */
    val characteristicUuidStrings: List<String>
        get() = when (this) {
            WHOOP4 -> listOf(
                "61080002-8d6d-82b8-614a-1c8cb0f8dcc6",
                "61080003-8d6d-82b8-614a-1c8cb0f8dcc6",
                "61080004-8d6d-82b8-614a-1c8cb0f8dcc6",
                "61080005-8d6d-82b8-614a-1c8cb0f8dcc6",
            )
            WHOOP5 -> listOf(
                "fd4b0002-cce1-4033-93ce-002d5875f58a",
                "fd4b0003-cce1-4033-93ce-002d5875f58a",
                "fd4b0004-cce1-4033-93ce-002d5875f58a",
                "fd4b0005-cce1-4033-93ce-002d5875f58a",
                "fd4b0007-cce1-4033-93ce-002d5875f58a",
            )
        }

    /**
     * The command/write characteristic UUID *string* for this family (the …0002 endpoint that
     * CLIENT_HELLO and command frames are written to). A single confirmed write here is the bond.
     */
    val commandCharacteristicUuidString: String
        get() = when (this) {
            WHOOP4 -> "61080002-8d6d-82b8-614a-1c8cb0f8dcc6"
            WHOOP5 -> "fd4b0002-cce1-4033-93ce-002d5875f58a"
        }

    /**
     * Static CLIENT_HELLO frame this family writes immediately after GATT discovery to start a
     * session, or `null` for families that do not use a fixed hello.
     *
     * The Whoop 5.0 hello is a fully-formed type-35 (COMMAND) frame with CRC16-Modbus header and
     * CRC32 payload trailer. Transcribed verbatim from the Goose reverse-engineering
     * (`GooseHello.clientHelloFrameHex` = "aa0108000001e67123019101363e5c8d").
     */
    val clientHello: ByteArray?
        get() = when (this) {
            WHOOP4 -> null
            WHOOP5 -> WHOOP5_CLIENT_HELLO.copyOf()
        }

    companion object {
        /**
         * Resolve a device-registry `model` label to the strap family that wrote its rows (#171).
         *
         * The registry holds several historical spellings for the same hardware: the Add-Device
         * wizard stores bare "4.0" / "5.0 MG", other paths match the full picker labels
         * ("WHOOP 4.0" / "WHOOP 5.0 / MG"), and the legacy seeded "my-whoop" row stores just
         * "WHOOP". Matching any single spelling silently misses the others (#171), so this is
         * the ONE place allowed to interpret registry model labels.
         *
         * "WHOOP" predates the wizard and was written identically for 4.0 and 5/MG installs, so
         * it carries no family information; it keeps the prior WHOOP5 fallback, as do
         * null/unknown labels (non-WHOOP imports whose skin temp is already °C) — only a
         * positively-identified 4.0 changes scale (#938). Mirrors the Swift
         * `DeviceFamily.forRegistryModel`.
         */
        fun forRegistryModel(model: String?): DeviceFamily = when (model) {
            "4.0", "WHOOP 4.0" -> WHOOP4
            else -> WHOOP5
        }

        /**
         * Brand-aware family resolution (#1086). Returns `null` for a positively non-WHOOP brand
         * (e.g. "Oura", "Apple") — [DeviceFamily] has only [WHOOP4]/[WHOOP5], so it cannot represent
         * "not a WHOOP", and letting such a device fall through to [WHOOP5] is exactly the #171
         * mistake (a family question answered by a fall-through rather than by evidence). The row
         * already carries the answer: `PairedDevice.brand` is set from `DeviceBrandCatalog`.
         *
         * A null/empty brand or the legacy "WHOOP" label (written identically for 4.0 and 5/MG)
         * carries no non-WHOOP signal, so it defers to [forRegistryModel]. Callers that need a
         * concrete family for a non-WHOOP device (e.g. the skin-temp raw→°C scale, where a non-WHOOP
         * reading shares the non-4.0 branch) coalesce the null to [WHOOP5], matching the prior
         * behaviour exactly. Mirrors the Swift `DeviceFamily.forRegistryDevice`.
         */
        fun forRegistryDevice(model: String?, brand: String?): DeviceFamily? {
            if (!brand.isNullOrEmpty() && !brand.equals("WHOOP", ignoreCase = true)) return null
            return forRegistryModel(model)
        }

        /**
         * Is this registry row positively a 5.0/MG-family WHOOP? For callers asking a YES/NO
         * *identity* question rather than needing a concrete family to compute with.
         *
         * The distinction matters because the two kinds of caller must treat [forRegistryDevice]'s
         * `null` oppositely, and only one of them may coalesce it:
         *
         *  - **Needs a concrete family** (the skin-temp raw→°C scale): a non-WHOOP reading genuinely
         *    shares the non-4.0 branch, so `?: WHOOP5` picks the right arithmetic and preserves the
         *    prior behaviour.
         *  - **Asks "is it a 5/MG?"** (this): `?: WHOOP5` answers **yes** for an Oura ring, which is
         *    the #171 fall-through mistake wearing #1086's clothes — the brand said "not a WHOOP"
         *    and the coalesce threw that evidence away.
         *
         * Exists so the second kind cannot be written as
         * `(forRegistryDevice(…) ?: WHOOP5) == WHOOP5`, which reads plausible and is wrong.
         * Mirrors the Swift `DeviceFamily.isWhoop5Registry`.
         */
        fun isWhoop5Registry(model: String?, brand: String?): Boolean =
            forRegistryDevice(model, brand) == WHOOP5

        /** Whoop 5.0 CLIENT_HELLO bytes (16 bytes). Exposed as a named constant for test/debug use. */
        val WHOOP5_CLIENT_HELLO: ByteArray = byteArrayOf(
            0xAA.toByte(), 0x01, 0x08, 0x00, 0x00, 0x01, 0xE6.toByte(), 0x71,
            0x23, 0x01, 0x91.toByte(), 0x01, 0x36, 0x3E, 0x5C, 0x8D.toByte(),
        )
    }
}

/**
 * WHOOP custom GATT service families visible in advertisements.
 *
 * Only `WHOOP4` and `MAVERICK_GOOSE_FD4B` are connectable in NOOP today. The other services are
 * protocol facts from reverse engineering and are diagnostic-only until their connection framing is
 * mapped and hardware-tested. In particular, [PUFFIN_1150] is intentionally named with its UUID
 * prefix because NOOP already uses "puffin" for the fd4b/Maverick-Goose packet framing.
 */
private fun unsupportedWhoopCharacteristicUuidStrings(prefix: String, suffix: String): List<String> =
    listOf("0002", "0003", "0004", "0005", "0007").map { "$prefix$it-$suffix" }

enum class WhoopGattServiceFamily(
    val displayName: String,
    val serviceUuidString: String,
    val characteristicUuidStrings: List<String>,
    val connectableDeviceFamily: DeviceFamily?,
) {
    WHOOP4(
        displayName = "WHOOP 4.0",
        serviceUuidString = "61080001-8d6d-82b8-614a-1c8cb0f8dcc6",
        characteristicUuidStrings = DeviceFamily.WHOOP4.characteristicUuidStrings,
        connectableDeviceFamily = DeviceFamily.WHOOP4,
    ),
    MAVERICK_GOOSE_FD4B(
        displayName = "WHOOP 5.0 / MG fd4b (Maverick/Goose)",
        serviceUuidString = "fd4b0001-cce1-4033-93ce-002d5875f58a",
        characteristicUuidStrings = DeviceFamily.WHOOP5.characteristicUuidStrings,
        connectableDeviceFamily = DeviceFamily.WHOOP5,
    ),
    PUFFIN_1150(
        displayName = "WHOOP PUFFIN service 1150",
        serviceUuidString = "11500001-6215-11ee-8c99-0242ac120002",
        characteristicUuidStrings = unsupportedWhoopCharacteristicUuidStrings(
            "1150",
            "6215-11ee-8c99-0242ac120002",
        ),
        connectableDeviceFamily = null,
    ),
    MONUMENT(
        displayName = "WHOOP MONUMENT",
        serviceUuidString = "8a580001-2fe8-4796-9267-b87a2b0c8234",
        characteristicUuidStrings = unsupportedWhoopCharacteristicUuidStrings(
            "8a58",
            "2fe8-4796-9267-b87a2b0c8234",
        ),
        connectableDeviceFamily = null,
    ),
    SYMPHONY(
        displayName = "WHOOP SYMPHONY",
        serviceUuidString = "59830001-5955-419b-bb8d-c8262926af23",
        characteristicUuidStrings = unsupportedWhoopCharacteristicUuidStrings(
            "5983",
            "5955-419b-bb8d-c8262926af23",
        ),
        connectableDeviceFamily = null,
    );

    val isConnectable: Boolean get() = connectableDeviceFamily != null

    val diagnosticUnsupportedMessage: String
        get() = "$displayName detected but unsupported; NOOP will not connect or send commands."

    companion object {
        val unsupportedFamilies: List<WhoopGattServiceFamily> =
            entries.filter { !it.isConnectable }

        val unsupportedServiceUuidStrings: List<String> =
            unsupportedFamilies.map { it.serviceUuidString }

        fun forServiceUuidString(uuid: String?): WhoopGattServiceFamily? {
            val normalized = uuid?.lowercase() ?: return null
            return entries.firstOrNull { it.serviceUuidString == normalized }
        }

        fun firstUnsupportedIn(serviceUuidStrings: Iterable<String>): WhoopGattServiceFamily? =
            serviceUuidStrings.mapNotNull { forServiceUuidString(it) }
                .firstOrNull { !it.isConnectable }
    }
}

data class WhoopGattScanDecision(
    val shouldConnect: Boolean,
    val unsupportedFamily: WhoopGattServiceFamily? = null,
)

/**
 * Decide whether an advertisement found by the broadened diagnostic scan should enter GATT.
 *
 * Empty service lists preserve the pre-diagnostic behaviour because some platform callbacks omit the
 * advertised service UUIDs even though the service-filtered scan matched. When services are present,
 * only the selected connectable service may connect; unsupported families are reported for logging.
 */
fun whoopGattScanDecision(
    selectedServiceUuidString: String,
    advertisedServiceUuidStrings: Iterable<String>,
): WhoopGattScanDecision {
    val advertised = advertisedServiceUuidStrings.map { it.lowercase() }.toSet()
    if (advertised.isEmpty() || selectedServiceUuidString.lowercase() in advertised) {
        return WhoopGattScanDecision(shouldConnect = true)
    }
    val unsupported = WhoopGattServiceFamily.firstUnsupportedIn(advertised)
    return WhoopGattScanDecision(shouldConnect = false, unsupportedFamily = unsupported)
}

/**
 * Whoop 5.0 "puffin" packet types mirror existing 4.0 types on the new transport. These map onto
 * the canonical base type names so they decode like their 4.0 counterparts instead of falling
 * through to an "unknown" label.
 */
object PuffinPacketType {
    /** Puffin command response — behaves like COMMAND_RESPONSE (type 36). */
    const val PUFFIN_COMMAND_RESPONSE: Int = 38

    /** Puffin metadata — behaves like METADATA (type 49). */
    const val PUFFIN_METADATA: Int = 56
}
