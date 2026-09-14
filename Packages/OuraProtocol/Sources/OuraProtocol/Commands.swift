import Foundation

// Commands: byte-exact opcode builders (OURA_PROTOCOL.md s4 / s5). Pure functions returning the
// wire bytes to write to ...0002. The live-HR enable path (s5.6) is the feature-0x02 (0x2F) path,
// NOT the 0x06 path. Dangerous opcodes (reboot, factory reset, key install, DFU) are quarantined in
// OuraDangerousCommands and never produced by the normal builders.
//
// Platform-pure value types. Facts cited per OURA_PROTOCOL.md s4 / s5.

/// A built command plus a short label for the strap log (statuses/UUIDs/counts only, never an
/// address). The OuraDriver returns these from nextStep(after:).
public struct OuraCommand: Equatable, Sendable {
    public let label: String
    public let bytes: [UInt8]
    public init(label: String, bytes: [UInt8]) { self.label = label; self.bytes = bytes }
}

public enum OuraCommands {
    // The live daytime-HR feature id. Per OURA_PROTOCOL.md s5.6 / s7.1.
    public static let featureDaytimeHR: UInt8 = 0x02
    // The SpO2 feature id. Per OURA_PROTOCOL.md s7.1.
    public static let featureSpO2: UInt8 = 0x04
    // The real-steps feature id (`activity/real_steps`). Nominally server-flag-gated per
    // OURA_PROTOCOL.md s7.1/s7.3 [open_oura-feat], but on-device 2026-08-25 real-steps status reads
    // came back enabled (status=1) from BOTH an authenticated Oura-app session and NOOP's own fully
    // offline, unauthenticated read of the same ring — the gate is ring-side state, not tied to which
    // client asks or whether that client is cloud-authenticated. Do not assume "off for NOOP" without
    // checking a live read.
    public static let featureRealSteps: UInt8 = 0x0B
    // The exercise-HR (AWHR) feature id — data arrives as `0x73`/`0x74`. Server-flag-gated per
    // OURA_PROTOCOL.md s7.1 [ring4-ble]. Per s7.5, open_oura reports this one respects a local
    // `setFeatureMode` write on a consumer ring.
    public static let featureExerciseHR: UInt8 = 0x03
    // The CVA PPG sampler feature id — feeds `0x81` raw PPG. Server-flag-gated per OURA_PROTOCOL.md
    // s7.1 [ring4-ble]. Per s7.5, open_oura reports this one respects a local `setFeatureMode` write
    // on a consumer ring.
    public static let featureCvaPpg: UInt8 = 0x0D

    // MARK: - Pre-auth / identity (unauthenticated OK)

    /// GetFirmwareVersion: `08 03 00 00 00`. Pre-auth readable. Per OURA_PROTOCOL.md s4.1 / s3.6.
    public static func getFirmwareVersion() -> OuraCommand {
        OuraCommand(label: "get_firmware", bytes: [0x08, 0x03, 0x00, 0x00, 0x00])
    }

    /// GetProductInfo serial page: `18 03 08 00 10`. Pre-auth readable; used for generation detection.
    /// Per OURA_PROTOCOL.md s4.1 / s7.3.
    public static func getProductSerial() -> OuraCommand {
        OuraCommand(label: "get_serial", bytes: [0x18, 0x03, 0x08, 0x00, 0x10])
    }

    /// GetProductInfo hardware page: `18 03 18 00 10`. Pre-auth readable; hardware id (e.g. BLB_03)
    /// maps to the generation. Per OURA_PROTOCOL.md s4.1 / s7.3.
    public static func getProductHardware() -> OuraCommand {
        OuraCommand(label: "get_hardware", bytes: [0x18, 0x03, 0x18, 0x00, 0x10])
    }

    // MARK: - Notifications / state

    /// SetNotification (enable all): `1c 01 3f`. `00`=none, `3f`/`bf`=all. Per OURA_PROTOCOL.md s4.1.
    public static func enableAllNotifications() -> OuraCommand {
        OuraCommand(label: "notify_all", bytes: [0x1C, 0x01, 0x3F])
    }

    /// SetNotification (disable): `1c 01 00`. Per OURA_PROTOCOL.md s4.1.
    public static func disableNotifications() -> OuraCommand {
        OuraCommand(label: "notify_none", bytes: [0x1C, 0x01, 0x00])
    }

    // MARK: - Time sync

    /// SyncTime (`0x12`): hand the ring the current wall-clock so it can emit a usable `0x42` UTC anchor
    /// (§5.5). Layout `12 09 <unix_secs: u64 LE (8 B)> <tz: i8 half-hours>` — unix **seconds**, 8-byte
    /// little-endian, one signed timezone byte in 30-minute units. Matches the authoritative open_oura
    /// `req_sync_time(secs, 0)` ([oura-proto]/[oura-link], OURA_PROTOCOL.md §5.4/§9.2). Supersedes an
    /// earlier reverse-engineered guess (`token` + `unix_s/256` in 3 bytes + `0xF6` trailer) that did NOT
    /// match the native client. `tzHalfHours` defaults to 0 (UTC), exactly as the reference client sends;
    /// NOOP does its own LOCAL-day bucketing downstream regardless of what the ring is told here.
    /// On-device proven (2026-07-08..10): sending this on connect makes the ring emit the 0x42 anchor.
    public static func syncTime(unixSeconds: Int, tzHalfHours: Int8 = 0) -> OuraCommand {
        let secs = UInt64(bitPattern: Int64(unixSeconds))
        var body: [UInt8] = (0..<8).map { UInt8((secs >> (UInt64($0) * 8)) & 0xFF) }   // u64 seconds, LE
        body.append(UInt8(bitPattern: tzHalfHours))                                    // i8 tz (30-min units)
        return OuraCommand(label: "sync_time", bytes: [0x12, UInt8(body.count)] + body)
    }

    // MARK: - Event fetch (cursor)

    /// GetEvents request: `10 09 <ringTimestamp:4 LE> <max:1> <flags:4 LE>`. cursor 0 = full dump;
    /// max 0 = ack-only (advance cursor without data); flags = 0xFFFFFFFF. Per OURA_PROTOCOL.md s5.1.
    public static func getEvents(cursor: UInt32, maxEvents: UInt8) -> OuraCommand {
        let c0 = UInt8(cursor & 0xFF)
        let c1 = UInt8((cursor >> 8) & 0xFF)
        let c2 = UInt8((cursor >> 16) & 0xFF)
        let c3 = UInt8((cursor >> 24) & 0xFF)
        return OuraCommand(label: "get_events",
                           bytes: [0x10, 0x09, c0, c1, c2, c3, maxEvents, 0xFF, 0xFF, 0xFF, 0xFF])
    }

    /// Flush flash-buffered events first: `28 01 00`. Per OURA_PROTOCOL.md s4.1 / s5.3.
    public static func flushBuffer() -> OuraCommand {
        OuraCommand(label: "flush_buffer", bytes: [0x28, 0x01, 0x00])
    }

    /// GetBattery: `0c 00`. Auth-gated after key set. Per OURA_PROTOCOL.md s4.1.
    public static func getBattery() -> OuraCommand {
        OuraCommand(label: "get_battery", bytes: [0x0C, 0x00])
    }

    // MARK: - Live-HR realtime (feature-0x02 path; s5.6)

    /// Step 1 of the live-HR enable triplet: read the daytime-HR feature status, `2f 02 20 02`.
    /// ACK: `2f 06 21 02 ...`. Per OURA_PROTOCOL.md s5.6.
    public static func liveHRReadStatus() -> OuraCommand {
        OuraCommand(label: "dhr_read", bytes: [0x2F, 0x02, 0x20, featureDaytimeHR])
    }

    /// Step 2: enable (param write byte 0 = 3), `2f 03 22 02 03`. ACK: `2f 03 23 02 00`.
    /// Per OURA_PROTOCOL.md s5.6.
    public static func liveHREnable() -> OuraCommand {
        OuraCommand(label: "dhr_enable", bytes: [0x2F, 0x03, 0x22, featureDaytimeHR, 0x03])
    }

    /// Step 3: subscribe (param write byte 2 = 2), `2f 03 26 02 02`. ACK: `2f 03 27 02 00`. Live HR/IBI
    /// then streams ~1 Hz as 0x2F sub-op 0x28 pushes. Per OURA_PROTOCOL.md s5.6.
    public static func liveHRSubscribe() -> OuraCommand {
        OuraCommand(label: "dhr_subscribe", bytes: [0x2F, 0x03, 0x26, featureDaytimeHR, 0x02])
    }

    /// Disable live HR: `2f 03 22 02 00`. ACK: `2f 03 23 02 00`.
    /// Mode byte is **0x00** ("off" per OURA_PROTOCOL.md s7.2's APK-sourced table), not 0x01
    /// ("automatic") — an earlier build wrote 0x01 here on the mistaken belief it meant "off"; s7.4's
    /// own worked example shows mode=1 read back while daytime-HR is actively streaming, and two
    /// consecutive real-hardware nights (08-17/18, 08-18/19) falsified "stream stops on ACK" for that
    /// byte — green 0x80 kept arriving all night at reduced but non-zero volume, matching "automatic"
    /// mode's own adaptive/motion-triggered sampling rather than a true off. Per OURA_PROTOCOL.md s5.6.
    public static func liveHRDisable() -> OuraCommand {
        OuraCommand(label: "dhr_disable", bytes: [0x2F, 0x03, 0x22, featureDaytimeHR, 0x00])
    }

    /// Unsubscribe from live-HR pushes: `2f 03 26 02 00`. ACK: `2f 03 27 02 00`.
    /// The enable triplet's step 3 (`liveHRSubscribe`) leaves the ring subscribed at "latest" (byte2 =
    /// 2); nothing ever wrote it back to "off" before this — `liveHRDisable` alone only touches the
    /// feature MODE byte, not the subscription. Send both together when suspending live HR so no
    /// notification channel is left standing open for the ring's own adaptive sampling to push through.
    /// Safe to send any time the driver has reached `.streaming`: its ACK shares subop 0x27 with the
    /// subscribe step's ACK, which `OuraDriver.nextStep(after: .enableAckReceived)` no-ops outside
    /// `.enablingLiveHR` (same reasoning as `liveHRDisable`'s ACK routing). Per OURA_PROTOCOL.md s5.6/7.2.
    public static func liveHRUnsubscribe() -> OuraCommand {
        OuraCommand(label: "dhr_unsubscribe", bytes: [0x2F, 0x03, 0x26, featureDaytimeHR, 0x00])
    }

    // MARK: - Feature-status diagnostics (READ-ONLY; s5.6 / s7.1)

    /// Read the SpO2 feature status, `2f 02 20 04` — the SAME `0x20` READ verb as `dhr_read`, NOT the
    /// `0x22` set-mode enable. The `0x21` reply carries feature/mode/status/state/subscription; SpO2 is
    /// server-flag-gated (`health/spo2`), so the reply is the ring's own report of whether it will emit
    /// SpO2. Read-only diagnostic — never enables anything, never writes a mode. [open_oura-feat]
    public static func spo2ReadStatus() -> OuraCommand {
        OuraCommand(label: "spo2_status", bytes: [0x2F, 0x02, 0x20, featureSpO2])
    }

    /// Read the real-steps feature status, `2f 02 20 0b` (READ verb, not enable). The `0x21` reply reports
    /// the ring's own real_steps gate state — NOT reliably "off" for an offline ring: on-device
    /// 2026-08-25 this read back status=1 (enabled) from NOOP's own unauthenticated connection, matching
    /// the real Oura app's read of the same ring byte-for-byte. Read-only diagnostic either way — never
    /// enables anything, never writes a mode. [open_oura-feat]
    public static func realStepsReadStatus() -> OuraCommand {
        OuraCommand(label: "realsteps_status", bytes: [0x2F, 0x02, 0x20, featureRealSteps])
    }

    // MARK: - Feature-mode write (s7.5; UNVALIDATED, opt-in only)

    /// Read any feature's status: `2f 02 20 <id>` — same read verb as `spo2ReadStatus`/
    /// `realStepsReadStatus`, generalized so the feature-mode write below can re-probe after writing.
    public static func featureReadStatus(_ feature: UInt8) -> OuraCommand {
        OuraCommand(label: "feature_status_\(String(feature, radix: 16))", bytes: [0x2F, 0x02, 0x20, feature])
    }

    /// Write a feature's MODE: `2f 03 22 <id> <mode>`. UNVALIDATED on NOOP's own hardware — see
    /// OURA_PROTOCOL.md s7.5: [open_oura-feat] reports this write bypassing the account gate for
    /// several features on a consumer ring, tested there only with mode=0x01 (automatic); mode=0x00
    /// ("off") always reverts. Gated to Test Centre / explicit user action only — nothing in
    /// `OuraDriver`'s own flow produces this call.
    public static func setFeatureMode(_ feature: UInt8, mode: UInt8) -> OuraCommand {
        OuraCommand(label: "EXPERIMENT_set_feature_\(String(feature, radix: 16))_mode\(mode)",
                    bytes: [0x2F, 0x03, 0x22, feature, mode])
    }

    /// The ordered live-HR enable triplet (read, enable, subscribe). The driver gates each on its ACK.
    /// Per OURA_PROTOCOL.md s5.6.
    public static func liveHREnableSequence() -> [OuraCommand] {
        [liveHRReadStatus(), liveHREnable(), liveHRSubscribe()]
    }
}

// MARK: - Dangerous commands (quarantined)

/// Opcodes that reboot, wipe, reflash, or re-key the ring. These are isolated here and NEVER produced
/// by the normal builders or the OuraDriver flow, so they can only be sent through an explicit, named
/// call. Per the brief's FOOTGUN WATCH and OURA_PROTOCOL.md s4.1 (DANGEROUS markers).
public enum OuraDangerousCommands {
    /// 0x0E StartFirmwareUpdate / soft_reset (reboots 22-35 s): `0e 01 ff`. Per OURA_PROTOCOL.md s4.1.
    public static func softReset() -> OuraCommand {
        OuraCommand(label: "DANGEROUS_soft_reset", bytes: [0x0E, 0x01, 0xFF])
    }

    /// 0x1A FactoryReset (wipes the ring, forces re-onboard + key reinstall). Per OURA_PROTOCOL.md s4.1.
    public static func factoryReset() -> OuraCommand {
        OuraCommand(label: "DANGEROUS_factory_reset", bytes: [0x1A, 0x00])
    }

    /// 0x24 SetAuthKey (installs a new 16-byte app key; only legitimate post-factory-reset). Builds
    /// via OuraAuth.installKeyCommand so the length guard is shared. Per OURA_PROTOCOL.md s3.2.
    public static func installKey(_ key: [UInt8]) throws -> OuraCommand {
        OuraCommand(label: "DANGEROUS_install_key", bytes: try OuraAuth.installKeyCommand(key))
    }

    /// 0x2B DFU start (OTA firmware). Payload is the OTA control body. Per OURA_PROTOCOL.md s4.1.
    public static func dfuStart(_ body: [UInt8]) -> OuraCommand {
        OuraCommand(label: "DANGEROUS_dfu_start", bytes: [0x2B, UInt8(body.count & 0xFF)] + body)
    }

    /// 0x2C DFU bulk payload chunk (OTA firmware data). Per OURA_PROTOCOL.md s4.1.
    public static func dfuBulk(_ body: [UInt8]) -> OuraCommand {
        OuraCommand(label: "DANGEROUS_dfu_bulk", bytes: [0x2C, UInt8(body.count & 0xFF)] + body)
    }
}
