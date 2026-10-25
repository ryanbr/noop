# NOOP implementation and historical observations

This page records client behavior and earlier observations; it does not override the topic references. Read the [scope and compatibility](PROTOCOL.md#scope-and-compatibility) before applying this page.

## Reading this page

These notes preserve application choices and previous observations. For wire
contracts use the [topic index](PROTOCOL.md#reading-guide); the legacy tables here
must not override it.

- [Client command inventory](#6-commandnumber-sending--the-safe-subset)
- [Probes and their limits](#whoop-4-reboot-probe-235)
- [Offload state machine](#73-session-state-machine)
- [Decoded output](#8-decoded-output-parsedframe)
- [SpO₂ observation and import boundaries](#10-spo₂-on-50--mg--what-the-wire-does-and-does-not-carry)
- [Implementation file map](#11-file-map)

## Protocol contract to implementation map

The protocol pages define the wire contracts; the tables below show where NOOP
implements each one. Every code reference names both a file and a symbol, and CI
checks that both continue to exist.

### Transport

| Contract | Swift | Android | Note |
|---|---|---|---|
| [WHOOP 4 envelope](PROTOCOL_WHOOP4.md#whoop-4-envelope) | [verifyFrame(_:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/Framing.swift), [crc8(_:_:_:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/Framing.swift), [crc32(_:_:_:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/Framing.swift) | [Framing.frameCrcOk](../android/app/src/main/java/com/noop/protocol/Framing.kt), [Crc.crc8](../android/app/src/main/java/com/noop/protocol/Crc.kt), [Crc.crc32](../android/app/src/main/java/com/noop/protocol/Crc.kt) | CRC8 protects the length; CRC32 protects the inner record |
| [WHOOP 5 format 1](PROTOCOL_TRANSPORT.md#format-1-framing) | [verifyFrame(_:family:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/Framing.swift), [crc16Modbus(_:_:_:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/Framing.swift), [crc32(_:_:_:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/Framing.swift) | [Framing.frameCrcOk](../android/app/src/main/java/com/noop/protocol/Framing.kt), [Crc.crc16Modbus](../android/app/src/main/java/com/noop/protocol/Crc.kt), [Crc.crc32](../android/app/src/main/java/com/noop/protocol/Crc.kt) | Format is selected before offsets or checksums |
| [Fragment reassembly](PROTOCOL_TRANSPORT.md#format-1-framing) | [Reassembler](../Packages/WhoopProtocol/Sources/WhoopProtocol/Framing.swift) | [Reassembler](../android/app/src/main/java/com/noop/protocol/Framing.kt) | One family-aware bounded buffer per connection |
| [Response correlation](PROTOCOL_TRANSPORT.md#responses-and-correlation) | [parseFrame(_:family:collectFields:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/Interpreter.swift), [Whoop4ResponseResultTests](../Packages/WhoopProtocol/Tests/WhoopProtocolTests/Whoop4ResponseResultTests.swift) | [Framing.parseFrame](../android/app/src/main/java/com/noop/protocol/Framing.kt), [Whoop4ResponseResultTest](../android/app/src/test/java/com/noop/protocol/Whoop4ResponseResultTest.kt) | Origin sequence and result code are decoded separately |
| [CLIENT_HELLO](PROTOCOL_WHOOP5.md#connection-and-frame-format) | [DeviceFamily.clientHello](../Packages/WhoopProtocol/Sources/WhoopProtocol/DeviceFamily.swift) | [DeviceFamily.clientHello](../android/app/src/main/java/com/noop/protocol/DeviceFamily.kt) | Fixed frame is family metadata |
| [WHOOP 4 bond and handshake](PROTOCOL_WHOOP4.md#bond-handshake--connect-lifecycle-whoop-40) | [peripheral(_:didWriteValueFor:error:)](../Strand/BLE/BLEManager.swift) | [onCharacteristicWrite](../android/app/src/main/java/com/noop/ble/WhoopBleClient.kt), [runConnectHandshake](../android/app/src/main/java/com/noop/ble/WhoopBleClient.kt) | Confirmed write establishes the client bond state |

### Identity

| Contract | Swift | Android | Note |
|---|---|---|---|
| [Hello 35 serial window](PROTOCOL_WHOOP4.md#get_hello_harvard-35-response--the-whoop-40-serial) | [Whoop4HelloSerial.decode(payload:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop4HelloSerial.swift) | [Whoop4HelloSerial.decode](../android/app/src/main/java/com/noop/protocol/Whoop4HelloSerial.kt) | Reads only the fixed nine-byte window |
| [Two-hello confirmation](PROTOCOL_WHOOP4.md#get_hello_harvard-35-response--the-whoop-40-serial) | [RepeatedSerialGate.offer(_:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop4HelloSerial.swift) | [RepeatedSerialGate.offer](../android/app/src/main/java/com/noop/protocol/Whoop4HelloSerial.kt) | Adoption waits for the same serial twice |
| [DIS 5.0/MG resolver](PROTOCOL_WHOOP5.md#whoop-50-vs-mg--telling-the-hardware-apart) | [Whoop5Variant.from(serial:hardwareRevision:modelNumber:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5Variant.swift) | [Whoop5Variant.from](../android/app/src/main/java/com/noop/protocol/Whoop5Variant.kt) | Contradictory inputs resolve to unknown |
| [Hello 145](PROTOCOL_TRANSPORT.md#hello--command-145) | [parseFrame(_:family:collectFields:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/Interpreter.swift) | [Framing.parseFrame](../android/app/src/main/java/com/noop/protocol/Framing.kt) | Decodes device name and firmware version |

### Commands

| Contract | Swift | Android | Note |
|---|---|---|---|
| [Curated sender enum](PROTOCOL_COMMANDS.md#canonical-command-matrix) | [WhoopCommand](../Strand/BLE/Commands.swift) | [CommandNumber](../android/app/src/main/java/com/noop/protocol/Enums.kt) | Sender surface is intentionally smaller than the decode catalogue |
| [WHOOP 4 command builder](PROTOCOL_TRANSPORT.md#whoop-4-frame-and-response-procedure) | [WhoopCommand.frame(seq:payload:)](../Strand/BLE/Commands.swift) | [Framing.buildCommand](../android/app/src/main/java/com/noop/protocol/Framing.kt) | Builds type 35 with the WHOOP 4 envelope |
| [WHOOP 5 command builder](PROTOCOL_TRANSPORT.md#format-1-framing) | [puffinCommandFrame(cmd:seq:payload:type:header:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/Framing.swift) | [Framing.puffinCommandFrame](../android/app/src/main/java/com/noop/protocol/Framing.kt) | Pads the inner record before checksums |
| [Clock 8/9-byte forms](PROTOCOL_COMMANDS.md#whoop-4) | [setClockPayload(now:)](../Strand/BLE/BLEManager.swift), [setClockPayloadLegacy(now:)](../Strand/BLE/BLEManager.swift) | [setClockPayload](../android/app/src/main/java/com/noop/ble/WhoopBleClient.kt), [setClockPayloadLegacy](../android/app/src/main/java/com/noop/ble/WhoopBleClient.kt) | WHOOP 4 sends both accepted lengths |
| [Alarm 9-byte body](PROTOCOL_ALARMS.md#scheduled-alarm-lifecycle-on-whoop-4) | [WhoopCommand.setAlarmPayload(epochSec:)](../Strand/BLE/Commands.swift) | [whoop4AlarmPayload](../android/app/src/main/java/com/noop/ble/WhoopBleClient.kt) | Two trailing bytes remain explicit |
| [Advertising name](PROTOCOL_COMMANDS.md#whoop-4) | [WhoopCommand.advertisingNamePayload(_:)](../Strand/BLE/Commands.swift) | [renameStrap](../android/app/src/main/java/com/noop/ble/WhoopBleClient.kt), [probeAdvertisingName](../android/app/src/main/java/com/noop/ble/WhoopBleClient.kt) | WHOOP 4 (77) on both platforms; client bytes are bounded. Android only, for 5/MG: an unconfirmed write (140, payload shape mirrored from WHOOP 4) and a read-only check (141), both only while Test Centre → Connection & Sync is on. Swift renames WHOOP 4 only. |
| [Haptic preset](PROTOCOL_ALARMS.md#immediate-whoop-4-haptics) | [MaverickHaptics.notificationBuzz(loops:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/HapticPayloads.swift) | [maverickHapticBody](../android/app/src/main/java/com/noop/ble/WhoopBleClient.kt) | Android remaps the common request to the family body |
| [Wrist and ECG controls](PROTOCOL_ECG.md#commands-and-independent-output-gates) | [Whoop5Ecg.selectWristPayload(_:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5Ecg.swift), [Whoop5Ecg.togglePayload(on:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5Ecg.swift) | [Whoop5Ecg.selectWristPayload](../android/app/src/main/java/com/noop/protocol/Whoop5Ecg.kt), [Whoop5Ecg.togglePayload](../android/app/src/main/java/com/noop/protocol/Whoop5Ecg.kt) | MG capability gate is separate from framing |
| [Feature-flag and device-config probes](PROTOCOL_CONFIGURATION.md#named-configuration-interface) | [FeatureFlagProbe](../Packages/WhoopProtocol/Sources/WhoopProtocol/FeatureFlagProbe.swift), [DeviceConfigReadProbe](../Packages/WhoopProtocol/Sources/WhoopProtocol/DeviceConfigReadProbe.swift) | [FeatureFlagProbe](../android/app/src/main/java/com/noop/protocol/FeatureFlagProbe.kt), [DeviceConfigReadProbe](../android/app/src/main/java/com/noop/protocol/DeviceConfigReadProbe.kt) | Read paths are bounded and namespace-aware |
| [Reboot probe](PROTOCOL_COMMANDS.md#unsupported-and-cross-version-commands) | [RebootProbeVariant](../Strand/BLE/Commands.swift) | [RebootProbeVariant](../android/app/src/main/java/com/noop/protocol/Enums.kt) | User-initiated candidate set only |
| [Send allowlist gate](PROTOCOL_COMMANDS.md#compatibility-status) | [send(_:payload:writeType:)](../Strand/BLE/BLEManager.swift), [DeviceConfigWriteGate.admitsSend(opcode:payload:ecgGateOptIn:isMG:broadcastHrOptIn:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/DeviceConfigWriteGate.swift) | [send](../android/app/src/main/java/com/noop/ble/WhoopBleClient.kt), [DeviceConfigWriteGate.admitsSend](../android/app/src/main/java/com/noop/protocol/DeviceConfigWriteGate.kt) | Raw WHOOP 5 sends are checked before framing |

### History

| Contract | Swift | Android | Note |
|---|---|---|---|
| [Offload start](PROTOCOL_TRANSPORT.md#history-sequencing-and-storage-ownership) | [beginBackfill](../Strand/BLE/BLEManager.swift) | [beginBackfill](../android/app/src/main/java/com/noop/ble/WhoopBleClient.kt) | Start is connection- and state-gated |
| [Offload abort](PROTOCOL_TRANSPORT.md#interruption-and-recovery) | [abortBackfill](../Strand/BLE/BLEManager.swift) | [abortBackfill](../android/app/src/main/java/com/noop/ble/WhoopBleClient.kt) | Abort does not advance trim |
| [HISTORY_END decoder](PROTOCOL_WHOOP4.md#history_end-payload-layout) | [classifyHistoricalMeta(_:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/HistoricalMeta.swift) | [classifyHistoricalMeta](../android/app/src/main/java/com/noop/protocol/HistoricalStreams.kt) | END and COMPLETE remain distinct states |
| [ACK with end block](PROTOCOL_TRANSPORT.md#whoop-4-history-lifecycle) | [finishChunk(unix:trim:endFrame:)](../Strand/Collect/Backfiller.swift) | [finishChunk](../android/app/src/main/java/com/noop/ble/Backfiller.kt) | The exact eight-byte end block is retained |
| [Safe-trim invariant](PROTOCOL_TRANSPORT.md#history-sequencing-and-storage-ownership) | [finishChunk(unix:trim:endFrame:)](../Strand/Collect/Backfiller.swift) | [finishChunk](../android/app/src/main/java/com/noop/ble/Backfiller.kt) | A failed durable write withholds the ACK |
| [Persist before ACK](PROTOCOL_TRANSPORT.md#history-sequencing-and-storage-ownership) | [Backfiller](../Strand/Collect/Backfiller.swift) | [Backfiller](../android/app/src/main/java/com/noop/ble/Backfiller.kt) | Each platform owns its transaction ordering |
| [Data range 34](PROTOCOL_TRANSPORT.md#data-range--command-34) | [DataRange.newestUnix(from:wallNowUnix:futureSkewSeconds:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/DataRange.swift), [DataRange.oldestUnix(from:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/DataRange.swift) | [DataRange.newestUnix](../android/app/src/main/java/com/noop/protocol/DataRange.kt), [DataRange.oldestUnix](../android/app/src/main/java/com/noop/protocol/DataRange.kt) | Bounds are decoded independently |
| [Ring backlog](#get_data_range-ring-backlog-689-diagnostic-only) | [DataRange.pagesBehind(from:cmdOff:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/DataRange.swift) | [DataRange.pagesBehind](../android/app/src/main/java/com/noop/protocol/DataRange.kt) | Both decode validated u32 ring pointers |

### Records

| Contract | Swift | Android | Note |
|---|---|---|---|
| [Type 40](PROTOCOL_SENSORS.md#whoop-4-realtime-heart-rate-record-type-40) | [registerPostHooks()](../Packages/WhoopProtocol/Sources/WhoopProtocol/PostHooks.swift) | [Framing.parseFrame](../android/app/src/main/java/com/noop/protocol/Framing.kt) | Live HR and R-R share the framed record path |
| [Type 43 variants 1917/1921](PROTOCOL_SENSORS.md#whoop-4-realtime-raw-layouts-type-43) | [registerPostHooks()](../Packages/WhoopProtocol/Sources/WhoopProtocol/PostHooks.swift) | — | Swift selects the WHOOP 4 layout by payload length; Android does not dispatch type 43 |
| [Type 47 v24/v25 and legacy layouts](PROTOCOL_SENSORS.md#whoop-4-historical-v25-and-unknown-versions) | [historicalLayoutSupport(version:observedLength:family:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/HistoricalLayoutSupport.swift), [extractHistoricalStreams(_:deviceClockRef:wallClockRef:family:wallNow:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/HistoricalStreams.swift) | [decodeHistorical](../android/app/src/main/java/com/noop/protocol/HistoricalStreams.kt), [extractHistoricalStreams](../android/app/src/main/java/com/noop/protocol/HistoricalStreams.kt) | Unknown layouts remain fail-closed |
| [R18](PROTOCOL_SENSORS.md#r18-biometric-summary) | [decodeWhoop5Historical(_:fb:payloadEnd:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/Interpreter.swift) | [decodeWhoop5Historical](../android/app/src/main/java/com/noop/protocol/HistoricalStreams.kt) | Biometric summary uses the versioned record decoder |
| [R20](PROTOCOL_SENSORS.md#r20-optical-blocks) | [decodeWhoop5Historical(_:fb:payloadEnd:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/Interpreter.swift) | [decodeWhoop5Historical](../android/app/src/main/java/com/noop/protocol/HistoricalStreams.kt) | Optical blocks are decoded by record version |
| [R21](PROTOCOL_SENSORS.md#r21-six-axis-imu) | [decodeWhoop5HistoricalV2021(_:fb:version:payloadEnd:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/Interpreter.swift) | [decodeWhoop5HistoricalV2021](../android/app/src/main/java/com/noop/protocol/HistoricalStreams.kt) | Six inertial channels use explicit offsets |
| [R22 versions](PROTOCOL_SENSORS.md#r22-inner-version) | — | — | No NOOP R22 record decoder is implemented |
| [R26](PROTOCOL_SENSORS.md#r26-compact-optical-window) | [decodeWhoop5HistoricalV26(_:fb:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/Interpreter.swift) | [decodeWhoop5HistoricalV26](../android/app/src/main/java/com/noop/protocol/HistoricalStreams.kt) | Compact optical window has a dedicated layout |
| [ECG R16/R17](PROTOCOL_ECG.md#routing-and-shared-header) | [Whoop5Ecg](../Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5Ecg.swift) | [Whoop5Ecg](../android/app/src/main/java/com/noop/protocol/Whoop5Ecg.kt) | Raw and filtered routes share the status header |
| [IMU streams 51/52](PROTOCOL_SENSORS.md#dedicated-imu-stream-types-51-and-52) | [Whoop5RawImu.decode(_:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5RawImu.swift) | [Whoop5RawImu.decode](../android/app/src/main/java/com/noop/protocol/Whoop5RawImu.kt) | Dedicated buffers decode to six-axis samples |
| [Battery 26](PROTOCOL_TRANSPORT.md#battery-level--command-26) | [parseFrame(_:family:collectFields:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/Interpreter.swift), [registerPostHooks()](../Packages/WhoopProtocol/Sources/WhoopProtocol/PostHooks.swift) | [Framing.parseFrame](../android/app/src/main/java/com/noop/protocol/Framing.kt) | WHOOP 4 uses u16/10; WHOOP 5 replies with four bytes, but both decoders currently use only the low byte |
| [Battery pack 151](PROTOCOL_TRANSPORT.md#battery-pack--command-151) | [BatteryPackInfo.decode(frame:cmdOff:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/BatteryPackInfo.swift) | [BatteryPackInfo.decode](../android/app/src/main/java/com/noop/protocol/BatteryPackInfo.kt) | Reply and event forms share the record decoder |
| [Extended battery event 63](PROTOCOL_TRANSPORT.md#whoop-4-battery-sources) | [registerPostHooks()](../Packages/WhoopProtocol/Sources/WhoopProtocol/PostHooks.swift) | [Framing.parseFrame](../android/app/src/main/java/com/noop/protocol/Framing.kt) | WHOOP 4 event fields are decoded separately from command 26 |

### Configuration

| Contract | Swift | Android | Note |
|---|---|---|---|
| [Named-key SET/GET 119–121/128](PROTOCOL_CONFIGURATION.md#named-configuration-interface) | [DeviceConfigReadProbe](../Packages/WhoopProtocol/Sources/WhoopProtocol/DeviceConfigReadProbe.swift), [DeviceConfigWriteGate](../Packages/WhoopProtocol/Sources/WhoopProtocol/DeviceConfigWriteGate.swift) | [DeviceConfigReadProbe](../android/app/src/main/java/com/noop/protocol/DeviceConfigReadProbe.kt), [DeviceConfigWriteGate](../android/app/src/main/java/com/noop/protocol/DeviceConfigWriteGate.kt) | Writes require key-aware admission and readback |
| [Feature-flag enumeration 117/118](PROTOCOL_CONFIGURATION.md#feature-flag-inventory) | [FeatureFlagProbe.parseStart(frame:family:namespace:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/FeatureFlagProbe.swift), [FeatureFlagProbe.parseNext(frame:family:namespace:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/FeatureFlagProbe.swift) | [FeatureFlagProbe.parseStart](../android/app/src/main/java/com/noop/protocol/FeatureFlagProbe.kt), [FeatureFlagProbe.parseNext](../android/app/src/main/java/com/noop/protocol/FeatureFlagProbe.kt) | Cursor walk is bounded |
| [R22 disable sequence](PROTOCOL_CONFIGURATION.md#r22-version-preferences) | [R22DisableReport](../Packages/WhoopProtocol/Sources/WhoopProtocol/R22Disable.swift), [FeatureFlagWriteGate](../Packages/WhoopProtocol/Sources/WhoopProtocol/R22Disable.swift) | [R22DisableReport](../android/app/src/main/java/com/noop/protocol/R22Disable.kt), [FeatureFlagWriteGate](../android/app/src/main/java/com/noop/protocol/R22Disable.kt) | Clear writes are followed by per-key verification |
| [AFE 61/62](PROTOCOL_CONFIGURATION.md#afe-parameters-6162) | [CommandNumber](../Packages/WhoopProtocol/Sources/WhoopProtocol/Resources/whoop_protocol.json) | [CommandNames](../android/app/src/main/java/com/noop/protocol/Enums.kt) | Decode catalogue only; no sender builder |
| [Gyro 150/152](PROTOCOL_CONFIGURATION.md#gyro-mode-150152) | — | — | No NOOP sender or decoder is implemented |
| [Collection policies 153/154](PROTOCOL_CONFIGURATION.md#collection-settings-and-overlapping-controls) | [CommandNumber](../Packages/WhoopProtocol/Sources/WhoopProtocol/Resources/whoop_protocol.json) | [CommandNames](../android/app/src/main/java/com/noop/protocol/Enums.kt) | Named in the decode catalogue; no sender builder |

### Alarms and haptics

| Contract | Swift | Android | Note |
|---|---|---|---|
| [SET/GET/RUN/DISABLE 66–69](PROTOCOL_ALARMS.md#scheduled-alarm-lifecycle-on-whoop-4) | [armStrapAlarm(at:)](../Strand/BLE/BLEManager.swift), [getStrapAlarm()](../Strand/BLE/BLEManager.swift), [buzzStrapOnce()](../Strand/BLE/BLEManager.swift), [disableStrapAlarm()](../Strand/BLE/BLEManager.swift) | [armStrapAlarm](../android/app/src/main/java/com/noop/ble/WhoopBleClient.kt), [getStrapAlarm](../android/app/src/main/java/com/noop/ble/WhoopBleClient.kt), [buzzStrapOnce](../android/app/src/main/java/com/noop/ble/WhoopBleClient.kt), [disableStrapAlarm](../android/app/src/main/java/com/noop/ble/WhoopBleClient.kt) | BLE-client entry points select the family-specific payload revision |
| [STOP 122](PROTOCOL_ALARMS.md#busy-execution-and-stop-completion) | [WhoopCommand.stopHaptics](../Strand/BLE/Commands.swift) | [stopHaptics](../android/app/src/main/java/com/noop/ble/WhoopBleClient.kt) | Stop is explicit on supported paths |
| [Pattern 19/79](PROTOCOL_ALARMS.md#immediate-whoop-4-haptics) | [MaverickHaptics.notificationBuzz(loops:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/HapticPayloads.swift), [WhoopCommand.runHapticsPattern](../Strand/BLE/Commands.swift) | [maverickHapticBody](../android/app/src/main/java/com/noop/ble/WhoopBleClient.kt), [CommandNumber.RUN_HAPTIC_PATTERN_MAVERICK](../android/app/src/main/java/com/noop/protocol/Enums.kt) | Common request is remapped for WHOOP 5/MG |

### Updates and authorization

| Contract | Swift | Android | Note |
|---|---|---|---|
| [Update and authorization boundaries](PROTOCOL_UPDATES.md) | — | — | NOOP has no installation path on either platform |

### Diagnostic probes

| Contract | Swift | Android | Note |
|---|---|---|---|
| [Reboot 29/32](#whoop-4-reboot-probe-235) | [RebootProbeVariant](../Strand/BLE/Commands.swift) | [RebootProbeVariant](../android/app/src/main/java/com/noop/protocol/Enums.kt) | Candidate frames are user-selected |
| [Body location 84](#body-location-probe-690) | [BodyLocationProbe.format(frame:cmdOff:isWhoop5:prevPayloadHex:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/BodyLocationProbe.swift) | [formatBodyLocationProbe](../android/app/src/main/java/com/noop/ble/WhoopBleClient.kt) | Read-only formatted response |
| [Feature flag 761](#feature-flag-enumeration-probe-761-read-only) | [FeatureFlagProbe](../Packages/WhoopProtocol/Sources/WhoopProtocol/FeatureFlagProbe.swift) | [FeatureFlagProbe](../android/app/src/main/java/com/noop/protocol/FeatureFlagProbe.kt) | Enumeration stops on bounds or terminal response |
| [Device config 103](#device-config-read-probe-103-read-only) | [DeviceConfigReadProbe](../Packages/WhoopProtocol/Sources/WhoopProtocol/DeviceConfigReadProbe.swift) | [DeviceConfigReadProbe](../android/app/src/main/java/com/noop/protocol/DeviceConfigReadProbe.kt) | Read-only namespace probe |
| [Ring backlog 689](#get_data_range-ring-backlog-689-diagnostic-only) | [DataRange.pagesBehind(from:cmdOff:)](../Packages/WhoopProtocol/Sources/WhoopProtocol/DataRange.swift) | [DataRange.pagesBehind](../android/app/src/main/java/com/noop/protocol/DataRange.kt) | Diagnostic estimate, not a stored-record count |

<a id="whoop-4-implementation-boundary"></a>

## WHOOP 4

WHOOP 4 behavior is version-scoped. NOOP implementation, observed wire bytes,
command acknowledgement, persisted state and physical device effects are separate
facts. For example, the seven-byte semantic alarm body is implemented with two
additional unevaluated zero bytes observed in working requests, while acknowledgement
alone still does not prove a scheduled physical buzz.

### Generation-specific implementation map

| Concern | WHOOP 4 implementation rule |
|---|---|
| Discovery | Use the `61080001-…` Harvard service and its family-specific characteristics; do not infer support from Puffin/Monument/Symphony advertisement alone |
| Framing | Select WHOOP 4 before reading length/CRC offsets; complete size is `u16le@1 + 4`, with CRC8 header and inner CRC32 |
| Reassembly | Keep fragment buffers connection-scoped, discard leading garbage, bound declared sizes and reset state on disconnect |
| Correlation | Match command, origin sequence and connection generation; preserve pending/final and duplicate CRC-valid responses |
| Records | Dispatch type first, then layout version or validated length; never apply WHOOP 5/MG offsets by a constant shift |
| History | Commit rows, rejected layouts and cursor before acknowledging the exact eight-byte END block |
| Battery | Prefer proprietary command/event observations over the standard Battery Service stub |
| Configuration | Keep request acceptance, readback, producer activity and persistence as separate facts |
| Alarms | Use the seven-byte revision-1 SET body; NOOP appends the two unevaluated zero bytes observed in working requests. Readback is diagnostic and recurrence remains application-owned |
| Updates | NOOP has no documented or authorized installation/flash path |

### Fail-closed and preserve-raw behavior

Malformed length, CRC failure and truncated fields are local
parse failures, not wire result codes. Unknown packet types, command results and
record versions should retain bounded raw data. An unknown historical layout
must not be acknowledged as successfully stored merely because its outer CRC is
valid; the local transaction must first preserve enough data for later
retro-decoding.

WHOOP 4 fallback decoding is deliberately asymmetric. Known v5/7/9, v12/v24 and
v25 layouts use explicit maps. Other historical versions may enter a v24-shaped
compatibility decoder only when physiological plausibility gates pass; otherwise
decoded fields are removed. This is client behavior and must be logged as fallback,
not relabelled as a proven version map.

### Remaining WHOOP 4 implementation gaps

Incomplete areas include request/response bodies for many supported commands,
record layouts for several revisions, the complete Nordic BLE/SPI contract,
configuration storage, alarm lifecycle and update authorization/recovery. NOOP
does not provide or authorize firmware installation.

### NOOP connection policy

These are NOOP client choices around the [WHOOP 4 connect sequence](PROTOCOL_WHOOP4.md#bond-handshake--connect-lifecycle-whoop-40),
not protocol requirements.

- NOOP marks the connection bonded once the confirmed `GET_BATTERY_LEVEL` write is
  acknowledged, then runs the connect handshake.
- The handshake runs exactly once per connection. Its one-shot guard
  (`connectHandshakeDone`) is load-bearing: the write-acknowledgement callback that
  starts it fires again for every later confirmed write, and re-blasting the
  handshake mid-offload was the historical root cause of the strap refusing to
  stream type-47.
- `GET_HELLO_HARVARD` (35) mirrors the official app's flow; it is not strictly
  required before the strap will serve data.
- The first historical offload starts about 1.5 s after `GET_DATA_RANGE`, so the
  link settles first.
- A 15-minute backfill timer (`backfillIntervalSeconds`, matching WHOOP) and a
  30-second keep-alive timer (`keepAliveIntervalSeconds`: re-arm realtime, poll
  battery, watchdog the link) are then started. With Low refresh enabled the
  backfill interval is 60 minutes (`lowRefreshBackfillIntervalSeconds`).
- The Swift path retains `GET_CLOCK`-based device/wall-clock correlation for WHOOP 4.
  Android derives its correlation from `GET_DATA_RANGE`. Commands 10/11 remain
  outside the documented 41.17.6.0 command set; on some devices one retained
  SET_CLOCK form was observed to latch, so both clients read back or correlate
  independently rather than trusting the write acknowledgement.

## Diagnostic-only WHOOP service families

Additional WHOOP service families use the same `0001` service plus
`0002`/`0003`/`0004`/`0005`/`0007` characteristic pattern. NOOP lists these as protocol metadata and
logs them when advertised, but does not connect, discover characteristics, or send commands for them
until the correct framing is mapped and hardware-tested.

| Family label in NOOP | Service UUID | Current status |
|----------------------|--------------|----------------|
| `puffin1150` | `11500001-6215-11ee-8c99-0242ac120002` | detected but unsupported |
| `monument` | `8a580001-2fe8-4796-9267-b87a2b0c8234` | detected but unsupported; likely Castle/Rev2 framing |
| `symphony` | `59830001-5955-419b-bb8d-c8262926af23` | detected but unsupported; likely Castle/Rev2 framing |

<a id="23-family-aware-entry-points"></a>

## Family-aware entry points

```swift
public func verifyFrame(_ frame: [UInt8], family: DeviceFamily) -> FrameCheck
public func parseFrame(_ frame: [UInt8], family: DeviceFamily) -> ParsedFrame
```

`whoop4` behaves exactly like the no-family overloads (back-compat). The "puffin" types
`38 PUFFIN_COMMAND_RESPONSE` and `56 PUFFIN_METADATA` are aliased onto `COMMAND_RESPONSE` /
`METADATA` by `canonicalTypeName(_:schema:)` so they never decode as "unknown".

## Frame integrity verdict

CRC32 is the protocol's **only payload-integrity guarantee**, and it is not the whole gate.
`verifyFrame` folds the header checksum, the payload CRC32 **and** the structural size rules of the
[WHOOP 4 envelope](PROTOCOL_WHOOP4.md#21-whoop-40-envelope) and
[format 1 framing](PROTOCOL_TRANSPORT.md#format-1-framing) into a single verdict, published as
`FrameCheck.ok` and carried onto `ParsedFrame.ok` ([decoded output](#8-decoded-output-parsedframe)).
Decode and state-update paths ask for that one verdict:

```swift
let parsed = parseFrame(frame, family: family)
guard parsed.ok else { return }   // header checksum + payload CRC32 + structural size, in one step
```

`FrameRouter.handle(parsed:frame:)` and `classifyHistoricalMeta(_:)` both gate on it. Without that
gate a garbled or hostile peer could forge a `HISTORY_END`/`HISTORY_COMPLETE` and advance the strap's
trim cursor, discarding data that was never durably stored — and a payload CRC32 check on its own
would not stop it, because the forged frame's own payload CRC32 can be correct while its header
checksum or declared length is not.

The verdict does not establish authenticity ([checksums](PROTOCOL_CONCEPTS.md#checksums)): a peer
that forms the envelope correctly is not excluded. The scope of the gate is likewise deliberate — six
state-driving consumers (the router, the historical-metadata classifier, live-stream extraction,
historical-row extraction, clock correlation, and the data-range reply) require the full verdict, not
"every frame consumer". Evidence-preserving readers are the documented exception: a raw history frame
with a negative verdict is archived *because* it failed, so the only durable copy of a frame the strap
is about to release is not the one that gets dropped.

<a id="26-reassembly"></a>

## Reassembly

BLE notifications arrive as MTU-sized fragments. For the **WHOOP 4 envelope**,
`Reassembler` (`Framing.swift`) accumulates bytes, finds the `0xAA` SOF, reads the `u16` LE
length at `buf[1..3]`, and emits a complete frame once `buf.count ≥ length + 4`.
WHOOP 5/MG format 1 instead reads length at offset 2 and uses complete size `length + 8`;
select the family/format before applying either rule. See [framing](PROTOCOL_TRANSPORT.md#format-1-framing). Leading garbage before an SOF is discarded; a buffer with
no SOF is dropped. The app feeds the data/cmd/event notify characteristics through one
`Reassembler` in `peripheral(_:didUpdateValueFor:error:)`.

The reassembler applies the **same family minimum** as `verifyFrame` (11 / 13 bytes): a `0xAA`
whose declared total falls below the configured acceptance floor is dropped before its checksum
trailer can be mistaken for inner fields, and the scan resyncs on the next one. Such a drop is
counted in `Reassembler.belowMinimumLengthDrops` rather than vanishing silently, because a byte run
discarded here never reaches a parser and never reaches the evidence-preserving reader either. The
existing ceiling (`maxFrameBytes`, 8192) resyncs the same way at the other end.

```swift
// usage in BLEManager
for frame in reassembler.feed(bytes) {
    router.handle(frame: frame)   // UI/state
    // … live ingest or backfill routing …
}
```

`frameFromPayload(_:type:seq:cmd:)` reconstructs a complete frame from a bare payload (used when
a capture stored only the data portion): it rebuilds the envelope with a correct zlib CRC32 **and**
a correctly computed CRC8 header byte. The CRC8 used to be a `0x00` placeholder, which was harmless
only while the gates asked whether the payload CRC32 was demonstrably wrong; under the full verdict
a placeholder header makes every rebuilt frame fail, so the rebuild now round-trips through
`verifyFrame` positively.

---

<a id="3-packettype-offset-4-or-8-on-50"></a>

<a id="packettype-offset-4-or-8-on-50"></a>

## PacketType (offset `[4]`, or `[8]` on WHOOP 5/MG)

This is NOOP’s schema vocabulary, not a guarantee that every named packet is produced by either generation. Current WHOOP 5/MG layouts are in [sensor records](PROTOCOL_SENSORS.md).

Source: `enums.PacketType` in `whoop_protocol.json`; resolved by `Schema.typeName(_:)`.

| Value | Name | Notes |
|------:|------|-------|
| 35 | `COMMAND` | format-1 outbound command (app → strap) |
| 36 | `COMMAND_RESPONSE` | format-1 reply to a command |
| 37 | `PUFFIN_COMMAND` | older label; role in 50.42.1.0 not confirmed |
| 38 | `PUFFIN_COMMAND_RESPONSE` | older label; role in 50.42.1.0 not confirmed; aliased → `COMMAND_RESPONSE` |
| 40 | `REALTIME_DATA` | live HR / R-R |
| 43 | `REALTIME_RAW_DATA` | live raw sensor data; the reference baseline also carries ECG R16/R17 ([ECG](PROTOCOL_ECG.md)); older ~1.9 KB IMU/optical examples are not a universal layout |
| 47 | `HISTORICAL_DATA` | offloaded biometric records |
| 48 | `EVENT` | strap event (event table below) |
| 49 | `METADATA` | offload control metadata (history topic) |
| 50 | `CONSOLE_LOGS` | firmware log text |
| 51 | `REALTIME_IMU_DATA_STREAM` | |
| 52 | `HISTORICAL_IMU_DATA_STREAM` | |
| 53 | `RELATIVE_PUFFIN_EVENTS` | WHOOP 5.0 |
| 54 | `PUFFIN_EVENTS_FROM_STRAP` | WHOOP 5.0 |
| 55 | `RELATIVE_BATTERY_PACK_CONSOLE_LOGS` | |
| 56 | `PUFFIN_METADATA` | WHOOP 5.0; aliased → `METADATA` |

Swift `isOffloadFrame(_:)` treats **47/48/49/50/56** as offload traffic. Android
uses the same list and additionally classifies type **52** as offload traffic for
WHOOP 5/MG. Both exclude live `REALTIME_DATA` (40) and `REALTIME_RAW_DATA` (43)
so those streams cannot keep the backfill idle watchdog active.

The parser also exposes irregular fields through per-type **post-hooks**
(`registerPostHooks()` in `PostHooks.swift`): `realtime_data`, `event`, `command_response`,
`raw_data`, `historical_data`, `metadata`, `console_logs`. The static field layout per packet
comes from the schema's `packets` table. The legacy WHOOP 4 raw-data model is keyed by
payload length (`"1917"` = IMU, `"1921"` = optical), and its historical data by version
byte (`seq`). WHOOP 5/MG needs its versioned record layout; those two length keys do not
identify every live sensor or ECG packet. See [sensor records](PROTOCOL_SENSORS.md).

---

<a id="4-eventnumber-event-type-48"></a>

## EventNumber (`EVENT`, type 48)

WHOOP 4 `EVENT` frames carry an `EventNumber` at `[6]` and a `u32` `event_timestamp` at `[8]`.
For WHOOP 5/MG format 1 the corresponding offsets are `[10]` and `[12]`; other event
types need their own layouts. See [sensor/event records](PROTOCOL_SENSORS.md). A
strap-pushed event is WHOOP's "strap-as-clock" signal: NOOP treats any event as "I may have new
data" and kicks a rate-limited sync (`FrameRouter.onSyncTrigger` → `requestSync(.strap)`).
Selected, frequently-used values (full table in `whoop_protocol.json`):

| Value | Name | | Value | Name |
|------:|------|-|------:|------|
| 3 | `BATTERY_LEVEL` | | 42 | `ACCELEROMETER_SATURATION_DETECTED` |
| 7 | `CHARGING_ON` | | 46 | `RAW_DATA_COLLECTION_ON` |
| 8 | `CHARGING_OFF` | | 47 | `RAW_DATA_COLLECTION_OFF` |
| 9 | `WRIST_ON` | | 56 | `STRAP_DRIVEN_ALARM_SET` |
| 10 | `WRIST_OFF` | | 57 | `STRAP_DRIVEN_ALARM_EXECUTED` |
| 13 | `RTC_LOST` | | 58 | `APP_DRIVEN_ALARM_EXECUTED` |
| 14 | `DOUBLE_TAP` | | 59 | `STRAP_DRIVEN_ALARM_DISABLED` |
| 17 | `TEMPERATURE_LEVEL` | | 60 | `HAPTICS_FIRED` |
| 23 | `BLE_BONDED` | | 63 | `EXTENDED_BATTERY_INFORMATION` |
| 32 | `CAPTOUCH_AUTOTHRESHOLD_ACTION` | | 96 | `HIGH_FREQ_SYNC_PROMPT` |
| 33 | `BLE_REALTIME_HR_ON` | | 97 | `HIGH_FREQ_SYNC_ENABLED` |
| 34 | `BLE_REALTIME_HR_OFF` | | 98 | `HIGH_FREQ_SYNC_DISABLED` |
| 40 | `CH1_SATURATION_DETECTED` | | 100 | `HAPTICS_TERMINATED` |
| 41 | `CH2_SATURATION_DETECTED` | | | |

`FrameRouter` maps several physical events to UI callbacks: `BLE_BONDED` confirms bonding,
`DOUBLE_TAP` fires `onDoubleTap`, `WRIST_ON`/`WRIST_OFF` toggle `worn` and fire `onWristChange`.
The legacy WHOOP 4 `BATTERY_LEVEL` event decoder uses this layout (see the `event` post-hook):
`soc% = u16@17 / 10`, `mV = u16@21`, `charging = u8@26 & 1`.

---

<a id="6-commandnumber-sending--the-safe-subset"></a>

## CommandNumber (sending) — client subset

**Non-exhaustive historical NOOP sender selection.** The table below records client
payload conventions, primarily WHOOP 4. It is not a complete inventory, the WHOOP
5/MG command contract or a recommendation to send every listed operation. Use the
[command reference](PROTOCOL_COMMANDS.md) for current meanings and the [alarm reference](PROTOCOL_ALARMS.md)
for revisioned alarms.

NOOP exposes a curated, **safe** command set in `WhoopCommand` (`../Strand/BLE/Commands.swift`).
The raw value is the on-wire command byte at `[6]` (inside a type-35 `COMMAND` frame). Commands
are built by `WhoopCommand.frame(seq:payload:)` and written to `…0002`.

```swift
public func frame(seq: UInt8, payload: [UInt8] = [0x00]) -> [UInt8] {
    let inner: [UInt8] = [35 /* COMMAND */, seq, rawValue] + payload
    let length = UInt16(inner.count + 4)
    let lenBytes: [UInt8] = [UInt8(length & 0xFF), UInt8(length >> 8)]
    return [0xAA] + lenBytes + [crc8(lenBytes)] + inner + crc32(inner) /* LE */
}
```

| Code | Command | Typical payload | Purpose |
|-----:|---------|-----------------|---------|
| 3 | `TOGGLE_REALTIME_HR` | `[0x01]`/`[0x00]` | sent by NOOP outside the documented 41.17.6.0 command set; standard BLE HR remains separate |
| 7 | `REPORT_VERSION_INFO` | `[0x00]` | firmware versions (decoded by `command_response` hook) |
| 10 | `SET_CLOCK` | `[secs u32 LE][subsecs u32 LE]` | request form observed in use outside the documented 41.17.6.0 command set; one of two forms can latch on some devices |
| 11 | `GET_CLOCK` | *empty* or `[0x00]` | request forms observed in use outside the documented 41.17.6.0 command set; readback selects the effective form |
| 22 | `SEND_HISTORICAL_DATA` | `[0x00]` | begin offload of the type-47 store |
| 23 | `HISTORICAL_DATA_RESULT` | `[0x01] + end_data(8)` | ack a `HISTORY_END` chunk / advance trim |
| 26 | `GET_BATTERY_LEVEL` | `[0x00]` | battery percent; also the **bond** write |
| 34 | `GET_DATA_RANGE` | `[0x00]` | strap's stored oldest/newest record range; #689 also logs a [diagnostic ring-buffer page backlog](#get_data_range-ring-backlog-689-diagnostic-only) |
| 35 | `GET_HELLO_HARVARD` | `[0x00]` | identity/version hello; the response carries the [WHOOP 4 serial](PROTOCOL_WHOOP4.md#get_hello_harvard-35-response--the-whoop-40-serial) |
| 63 | `SEND_R10_R11_REALTIME` | `[0x00]` off / `[0x01]` on | the **real** type-43 raw-stream switch |
| 66 | `SET_ALARM_TIME` | `[0x01]+epoch u32 LE+subseconds u16 LE+[0,0]` (9-byte NOOP request) | seven semantic bytes; final two zero bytes are not evaluated |
| 67 | `GET_ALARM_TIME` | `[0x01]` | read armed alarm |
| 68 | `RUN_ALARM` | `[0x01]` | app-driven alarm now |
| 69 | `DISABLE_ALARM` | `[0x01]` | disarm firmware alarm |
| 76 | `GET_ADVERTISING_NAME_HARVARD` | `[0x00]` | advertised name |
| 77 | `SET_ADVERTISING_NAME_HARVARD` | two reserved bytes + client name + NUL | NOOP allows up to 24 client bytes; the documented device field retains at most 15 and forces its last byte to NUL |
| 79 | `RUN_HAPTICS_PATTERN` | `[patternId, loops, 0,0,0]` | buzz a preset haptic pattern |
| 81 / 82 | `START_RAW_DATA` / `STOP_RAW_DATA` | `[0x01]` | raw-data collection toggle |
| 84 | `GET_BODY_LOCATION_AND_STATUS` | `[0x00]` | wrist/body-location status (read-only diagnostic probe, #690 — below) |
| 96 / 97 | `ENTER_HIGH_FREQ_SYNC` / `EXIT_HIGH_FREQ_SYNC` | retained client `[0x00]` forms | NOOP uses 97 during watchdog recovery; these client forms do not replace the documented WHOOP 4 contracts |
| 98 | `GET_EXTENDED_BATTERY_INFO` | `[0x00]` | extended battery (mV etc.) |
| 106 | `TOGGLE_IMU_MODE` | `[0x01]` | older one-byte NOOP form; the 41.17.6.0 SET contract is `[01, state]` |
| 107 | `GET_IMU_DATA_STREAM` | `[0x01]` | reads stored IMU stream state on 41.17.6.0; the WHOOP 5/MG identifier `ENABLE_OPTICAL_DATA` does not describe this WHOOP 4 operation |
| 117 | `START_FF_KEY_EXCHANGE` | `[0x01]` | the enumerated feature-name count (read-only enumeration probe, #761 — below) |
| 118 | `SEND_NEXT_FF` | `[0x01]` | next feature-flag NAME (cursor, not index; read-only, #761 — below) |
| 122 | `STOP_HAPTICS` | `[0x00]` | stop an in-progress haptic |
| 123 | `SELECT_WRIST` | `[0x01, arg]` | MG-only active in-memory wrist selection; persistence across reboot is not established; `arg` is the selected wrist value |

**Decode-only or historical inventory entries.** The following names are present
in protocol metadata or older notes but have no case in Swift `WhoopCommand`, so
they are not part of the sending subset above: `LINK_VALID` (1),
`SET_LED_DRIVE`/`GET_LED_DRIVE` (39/40), `SET_TIA_GAIN`/`GET_TIA_GAIN` (41/42),
`SET_BIAS_OFFSET`/`GET_BIAS_OFFSET` (43/44), `GET_ALL_HAPTICS_PATTERN` (80),
`CALIBRATE_CAPSENSE` (100), and `TOGGLE_IMU_MODE_HISTORICAL` (105). Command 105
is outside the documented WHOOP 4 41.17.6.0 command set and has no recorded
observation there.

Command 123 is formed only through the MG ECG path. `Whoop5Ecg.commandPayload(arg:)`
supplies `[0x01, arg]`, and `BLEManager.send(_:)` rejects every ECG-family command,
including `SELECT_WRIST`, unless the selected family is WHOOP 5/MG. It is never
sent to WHOOP 4.

**WHOOP 5/MG raw-IMU sequence (hardware-verified):** command 106 accepting a write does not mean that the
producer started. A bounded capture first sends `START_RAW_DATA` (81) `[0x01]`, then command 106 with
the two-byte selector `[0x01, 0x01]`. Stop uses `STOP_RAW_DATA` (82) `[0x01]`, then command 106
`[0x01, 0x00]`. The one-byte payload in the table is older NOOP behavior, not the
WHOOP 4 41.17.6.0 request contract. See
[WHOOP 5/MG raw data capture](RAW_DATA_CAPTURE.md) for storage, history repair, and export semantics.

**Payload construction** in `WhoopCommand`:

- `setAlarmPayload(epochSec:)` → `[0x01] + epoch u32 LE + subseconds u16 LE + [0x00, 0x00]`
  (9-byte request). The first seven bytes are the semantic body; the final two zero
  bytes are not evaluated. A seven-byte request was acknowledged in one run but did
  not produce the scheduled vibration; the subsecond field, not body length, is semantic.
- `BLEManager.setClockPayload(now:)` → `[secs u32 LE][0,0,0,0]` (8 bytes). This is
  a request form observed in use outside the documented 41.17.6.0 command set.
- `BLEManager.setClockPayloadLegacy(now:)` → `[secs u32 LE][0,0,0,0,0]` (9 bytes;
  another request form observed in use). On some devices one of these SET_CLOCK
  forms was observed to latch; read back to confirm.

**WHOOP 5/MG battery decoder boundaries:** command 26 returns a four-byte `u32le`
whole-percent value, including four zero bytes on the documented error path. NOOP
currently reads only the lowest byte. For command 151, NOOP divides the raw `u16le`
charge field by 10 for display; that scale is a client convention, not a confirmed
property of the wire value.

> **Note on `ENTER_HIGH_FREQ_SYNC` (96):** current builds do **not** enter high-freq sync. NOOP
> sends `EXIT_HIGH_FREQ_SYNC` (97) during watchdog recovery. Plain `SEND_HISTORICAL_DATA`
> returns the type-47 store without it.

## Additional 5-class command numbers

Command bytes present on a 5-class (MAVERICK) strap beyond the safe subset above. NOOP does not
send these; they are recorded for completeness.

| Code | Command | Purpose |
|-----:|---------|---------|
| 48 (0x30) | `SEND_EVENT_PACKETS` | event-delivery toggle; past/live selection unresolved |
| 61 (0x3D) | `SET_AFE_PARAMETERS` | set optical AFE parameters |
| 62 (0x3E) | `GET_AFE_PARAMETERS` | read optical AFE parameters |

On MAVERICK the clock commands also answer in the high opcode space — `SET_CLOCK` at 146 (0x92)
and `GET_CLOCK` at 147 (0x93), alongside `GET_HELLO` at 145 (0x91) — distinct from the WHOOP 4
numbers (10 / 11) above.

The ECG family is resolved as wrist selection (123), processing start/stop
(124), raw saving (125), raw live delivery (126), filtered saving (127), and filtered live
delivery (139). Noncontiguous IDs do not imply a mistaken mapping. Requests and
packet contracts are in [ECG](PROTOCOL_ECG.md); all remaining IDs are covered by the
[complete command reference](PROTOCOL_COMMANDS.md).

The turn-on ORDER and the 124 argument are attested on one device. On a WHOOP MG (`WS50_r00`, the earlier ECG observation), 139 gates the **stream**: with it off nothing arrives, so the working sequence is
**`139 = 1` then `124 = 2`**, after which type-43 carries a ~100 Hz single-channel i16 waveform,
present only while both clasp electrodes are held. 139 does not appear to gate the front end itself —
with 139 closed, `124 = 2` still made the strap's own `CONSOLE_LOGS` report `MAX86176: Set ECG ON`
while no packets arrived (eight sends, eight console lines, correlated on the strap's own uptime;
#891). Both directions are reversible (`124 = 1` or `139 = 0` stop the stream, both `SUCCESS`);
disconnecting also clears it. One device, one firmware — see the ⚠️ on `ControlSignal`.

What is confirmed on the other device: on a real WHOOP 5 MG (`WS50_r03`), 124, 125 and 139 are all
**accepted** — each answers `COMMAND_RESPONSE` with result `SUCCESS(1)` — and no ECG-shaped data
followed in a 30-second window. Those runs used `124 = 1` as their start verb, which under the mapping
above stops generation. That is a null result from a run that did not use the demonstrated start argument; it does not
establish a feature gate or contradict the later version-bound mapping. See
#891. The three reply frames are pinned as decode fixtures in `Whoop5CommandResponseTests` /
`CommandCatalogueTest`.

NOOP sends these only from the gated, hand-run MG ECG probe described in
[ECG controls](PROTOCOL_ECG.md#commands-and-independent-output-gates) — never automatically, never on a plain WHOOP 5 or WHOOP 4, and only
behind a default-off ECG opt-in plus a positively-identified MG. On Android that opt-in is the "WHOOP MG ECG turn-on probe" switch in Test Centre → 5/MG protocol diagnostics; the Apple apps currently have no control that turns it on, so their Devices-screen ECG entry stays hidden unless the stored key was already set. Existing probe implementation and
older observations must be distinguished from the expanded contract.

On the wire, live IMU control is 106 and BLE UART control is 103; they are distinct
operations. See [collection controls](PROTOCOL_CONFIGURATION.md#collection-storage-and-live-transport).

The configuration probing notes below describe earlier client behavior and unanswered
runs. They do not override the reference baseline [named configuration contract](PROTOCOL_CONFIGURATION.md):
read commands are defined, SET consumes a 65-byte body, lookup eligibility is versioned,
and tri-state polarity is per key. Historical enumeration and timeout reports are not
current absence-of-support claims.

## Destructive commands — *do not send*

These exist on the wire but are **deliberately excluded** from ordinary
`WhoopCommand` use. They can wipe data, brick, or power-cycle the strap. NOOP must
never send them, except command 32 through the narrowly scoped, user-confirmed
WHOOP 4 probe described below.

| Code | Command | Hazard |
|-----:|---------|--------|
| 25 | `FORCE_TRIM` | invasive history cursor/reclamation operation; unoffloaded data may become unavailable |
| 32 | `POWER_CYCLE_STRAP` | power-cycles ([gated probe exception](#whoop-4-reboot-probe-235)) |
| 36 | `START_FIRMWARE_LOAD` | firmware write |
| 37 | `LOAD_FIRMWARE_DATA` | firmware write |
| 38 | `PROCESS_FIRMWARE_IMAGE` | firmware write |
| 45 | `ENTER_BLE_DFU` | enters DFU bootloader |
| 99 | `RESET_FUEL_GAUGE` | resets battery fuel gauge |
| 142 | `START_FIRMWARE_LOAD_NEW` | firmware write |
| 143 | `LOAD_FIRMWARE_DATA_NEW` | firmware write |
| 144 | `PROCESS_FIRMWARE_IMAGE_NEW` | firmware write |

The 142–144 family is the high-opcode-space counterpart of 36/37/38, in the same style as the clock
family answering at 145–147 on MAVERICK. It is named by the schema and absent from the sender enum on
both platforms; it was missing from this table, so nothing recorded that it must stay that way. (83
`VERIFY_FIRMWARE_IMAGE` is part of the same flow but is not itself a write, and is likewise unsent.)

**Two guarded restart paths in NOOP.** These client paths are not proof of retained state or completed restart for every device. Neither is ever sent automatically or on any connect/offload path.

- **`REBOOT_STRAP` (29)** — the normal Restart. NOOP already triggers a reboot today via
  `SET_ADVERTISING_NAME_HARVARD` (rename applies on reboot). In `WhoopCommand` as `rebootStrap`, sent only
  from the user-initiated, confirmation-gated "Restart strap" action (`BLEManager.rebootStrap()` /
  `WhoopBleClient.rebootStrap()`) (#166).
- **`POWER_CYCLE_STRAP` (32)** — a harder restart, in the enum as `powerCycleStrap` **only** for the
  WHOOP 4 reboot probe variants `powerCycle32Empty` and `powerCycle32Payload1` (below). Each is gated
  behind Test Centre → Connection & Sync + a confirmation, and WHOOP-4-only. Never on a default install.

Everything else in this table stays out of the enum entirely.

<a id="whoop-40-reboot-probe-235"></a>

## WHOOP 4 reboot probe (#235)

The documented 41.17.6.0 contract does not evaluate the body for either restart
command: empty, `00` and `01` are equivalent, and an accepted request returns result 1.
The NOOP probe (Test Centre → Connection & Sync, WHOOP 4 only) sends one candidate at a time:
`REBOOT_STRAP(29)` empty, `POWER_CYCLE_STRAP(32)` empty,
`REBOOT_STRAP(29)` with `[0x01]`, `POWER_CYCLE_STRAP(32)` with `[0x01]`, or
`REBOOT_STRAP(29)` with `[0x00]`. It reuses the reboot watchdog so the strap log shows
which candidate drops the link versus being ignored. One device observation did not
show a response, disconnect or reboot for command 29, so that physical effect is not yet confirmed on hardware.
`BLEManager.rebootProbe(_:)` / `WhoopBleClient.rebootProbe(...)` enumerate all five through
`RebootProbeVariant`.

## Body-location probe (#690)

This paragraph records the older client decoder; the [current response body](PROTOCOL_COMMANDS.md#ordinary-service-commands) is documented separately.

A read-only, user-triggered diagnostic (Test Centre → Connection & Sync, both
families) that sends `GET_BODY_LOCATION_AND_STATUS` (84 / `0x54`) and dumps the strap's full raw
COMMAND_RESPONSE to the strap log + a copyable dialog. The 4-byte inner-payload record is
`revision · location · confidence · status`; `location` maps `0 UNKNOWN, 1 WRIST, 2 BICEP, 3 CALF,
4 SIDE_TORSO, 5 GLUTE, 7 ANKLE, 128 NOT_CONCLUSIVE, 160 UNKNOWN_GARMENT` (any other value — including the
gap at 6 — is kept raw; `confidence`/`status` stay raw until captures establish their semantics). Decoded
only on WHOOP 4. On 5/MG the command-response body starts at the command byte + 3,
after command, origin sequence and result; the raw grid is shown and the record is left undecoded
until a real 5/MG capture maps the offset. **Never** feeds wear detection, sleep gating, or scoring.
Driven by `BLEManager.probeBodyLocationAndStatus()` / `WhoopBleClient.probeBodyLocationAndStatus()`;
formatted by the pure `BodyLocationProbe` twin (Swift↔Kotlin byte-parity locked by a golden test).
The layout is implemented independently in NOOP; unknown enum values remain raw.

## Feature-flag enumeration probe (#761, read-only)

The probe’s older count model differs from the current u8 field; use the [named configuration interface](PROTOCOL_CONFIGURATION.md#named-configuration-interface).

NOOP has always been able to WRITE a feature flag
(`SET_FF_VALUE` / 120, the R22 unlock in `Whoop5Config`). The feature-name walk uses
117 `START_FF_KEY_EXCHANGE` followed by repeated 118 `SEND_NEXT_FF`: **names, no
values, nothing written.** `GET_FF_VALUE` (128) is
deliberately not sent by this enumeration path: the only hands-on report of it
(`johnmiddleton12/wearable`, run on the author's own WHOOP 4 on the earlier WHOOP 4 baseline)
states its reply's value field is contaminated by a stale shared buffer, so an on/off read is unreliable;
the same session ran the 117→118 loop and got a complete key dump.

That scope is not a global send prohibition. The separate device-config value probe uses
`GET_FF_VALUE` for named value reads, and the R22-disable sequence requires it as the read-back after
each `SET_FF_VALUE`. `BLEManager.send(_:)` admits that latter path only while an R22 disable run exists,
through `FeatureFlagWriteGate.isReadBackOpcode(_:)`.

Requests and reply fields are specified in the [named configuration interface](PROTOCOL_CONFIGURATION.md#named-configuration-interface).
The older probe’s count decoder is not the current byte contract.

**The two terminator conditions are not interchangeable, and are separated deliberately.** The walk stops
on `index = 0xFF` — the one end marker a strap has served here unambiguously. `validKey = 0` on its own
does NOT stop it: that could equally mark an EMPTY or RETIRED SLOT with the list continuing past it, and
the old probe interpretation was not established as a complete WHOOP 5/MG decoder. Neither reading is
established, because on the walks this project has, the two have never been separated on the wire: the
117/118 walk on a WS50_r03 served sixteen replies that were all `validKey = 1` with no `0xFF` at all,
and its 115/116 walk ended on a single reply carrying `index = 255` **and** `validKey = 0` together. So a
`validKey = 0` entry is recorded, stepped over, and the next record verb is sent again — what comes back
separates the two readings, and the report states which it observed. Past that the bounds are all
CLIENT-side and each names itself in the report's `Stop code:` line: 8 consecutive `validKey = 0` replies,
a repeated index during such a run (a parked cursor), the announced
count plus 4, or a hard cap of 128 replies. Each next-record request is only sent after the previous reply
lands. Both CRCs are verified before any field is read; a failed CRC, a non-COMMAND_RESPONSE type, or a
short record ends the walk with a named reason instead of a decode, and the RAW record bytes of every
reply are logged beside the fields decoded from them. Driven by `BLEManager.probeFeatureFlags()` /
`WhoopBleClient.probeFeatureFlags()` (user-triggered, Test Centre → Connection & Sync, both families) and
allowlisted for 5/MG framing **only while a probe is in flight**; parsed + rendered by the pure
`FeatureFlagProbe` / `FeatureFlagProbeReport` twins (Swift↔Kotlin byte-parity, unit-tested on synthetic
frames). Result goes to a copyable dialog + the strap log; no storage. The field
order and opcode numbers are implemented in NOOP and agree with that WHOOP 4
observation; unknown fields remain raw.
**Historical probe scope:** the published comparison dump is a WHOOP 4 R19-era list.
The reference-baseline enumeration commands and eligible-key inventory are now described in
[configuration](PROTOCOL_CONFIGURATION.md); this does not validate every older reply layout.

## Device-config read probe (#103, read-only)

The NOOP probe queries named values using commands 121 and 128, with a 64-round-trip
client cap. It is user-triggered and reports to a dialog and strap log without
persisting values. The allowlist restricts this path to reads; it does not send
119 or 120. Swift/Kotlin implementations have constructed-frame checks.

The current [request and complete response contract](PROTOCOL_CONFIGURATION.md#configuration-reads--commands-121-and-128)
is documented independently of the probe’s partial decoder. Earlier probe runs
did not establish successful hardware readback. Neither key names nor a missing
measurement establish an entitlement or subscription gate.

## GET_DATA_RANGE ring backlog (#689, diagnostic only)

 Beyond the oldest/newest timestamps NOOP already
scans from a `GET_DATA_RANGE` reply, the app computes a ring-buffer page backlog from three u32s in the
65-byte body (`01` followed by 16 `u32le` values): write page `W = V(2)`, acknowledged/trim boundary `D = V(3)`,
ring capacity `T = V(5)`, where `V(i)` is the u32 at inner offset `i·4 + 3` (frame offsets `cmdOff + 12/16/24`
here). In the current WHOOP 5/MG [range layout](PROTOCOL_TRANSPORT.md#data-range--command-34),
the read-page cursor is `V(1)`; `V(3)` measures the acknowledged boundary instead.
Backlog with wraparound: `W < D ? W + (T − D) : W − D`. `DataRange.pagesBehind` (Swift + Kotlin twins,
byte-parity, unit-tested for normal / wraparound / too-short / implausible) logs `Strap backlog pages behind:
N` when it decodes plausibly — read u32 LE, guarded on frame length + a capacity sanity ceiling. **Never**
gates sync or backfill: the layout is not yet confirmed against real WHOOP 4 or WHOOP 5/MG
device observations, so it stays a log-only diagnostic.

**Payload forms** are recorded so destructive commands can be avoided and the
guarded reboot operation can be encoded correctly. Commands 25, 29 and 32 use the
same numeric IDs on WHOOP 4 and WHOOP 5/MG; haptics differ by generation.

- `FORCE_TRIM` (25) — body is **two little-endian int32 range arguments**. The
  documented special form sets both to `-16843010` (`0xFEFEFEFE`). It is **not**
  an empty/`[0x00]` payload.
  In the WHOOP 5/MG profile, this pair enters the same history-storage event path
  as the chunk acknowledgement: it selects a special mode and the current write
  boundary. This is an invasive cursor/reclamation operation; it does not establish
  physical erasure of the entire flash history or guarantee that every stored
  record becomes unavailable. See [special history acknowledgement tokens](PROTOCOL_TRANSPORT.md#history-sequencing-and-storage-ownership).
- `REBOOT_STRAP` (29) — **empty body** on the WHOOP 5/MG path. The strap drops
  the BLE link and re-advertises after boot; stored data is kept. Non-destructive, but interrupts any
  in-flight offload. **WHOOP 5.0 (puffin): hardware-confirmed** — the empty-body frame reboots a 5.0
  (the earlier reboot observation, #227). On WHOOP 4 41.17.6.0, commands 29 and 32
  document distinct restart actions, ignore the request body and return result 1.
  A separate device observation showed no response, disconnect or reboot for 29,
  so the physical action is not yet confirmed on hardware.

---

<a id="73-session-state-machine"></a>

## Session state machine

```
SEND_HISTORICAL_DATA([0x00], .withResponse)
        │
        ▼
HISTORY_START ─▶ open chunk, accumulate type-47 records
   │
   ├─ HISTORICAL_DATA … HISTORICAL_DATA …            (records buffered)
   │
   ├─ HISTORY_END(unix, trim)  ──▶ finishChunk:
   │       1. decode chunk  (extractHistoricalStreams, using ClockRef)
   │       2. await store.insert(decoded)            ── decoded durable
   │       3. [Swift, if raw enabled] await enqueueRawBatch ── raw durable
   │       4. await setCursor("strap_trim", trim)    ── cursor durable
   │       5. ackTrim → HISTORICAL_DATA_RESULT([0x01]+end_data, .withResponse)
   │       (chunk cleared; chunkOpen stays TRUE — high-freq sends repeated ENDs)
   │
   └─ HISTORY_COMPLETE ─▶ isBackfilling = false, close session
```

High-frequency offload sends **one** `HISTORY_START` then **repeated** `HISTORY_END`s (a chunk
close roughly every ~50 records), so `Backfiller.begin()` starts with `chunkOpen = true`, and
`finishChunk(...)` snapshots-and-clears the accumulated frames but leaves the chunk open so the
following records form the next chunk. An `END` with no accumulated records is **still acked**
(that is how the offload progresses).

<a id="74-safe-trim-invariant"></a>

## Safe-trim invariant

NOOP sends the normal chunk acknowledgement only after local durability. This is a client persistence invariant; it does not prove all device read/erase behavior or exactly-once delivery. The Swift path in
`Backfiller.finishChunk(...)` is:

```
decode → await insert(decoded) → [Swift: await enqueueRawBatch] → await setCursor("strap_trim") → ackTrim
```

Android commits decoded rows and its cursor before acknowledgement, while an
enabled capture file is buffered separately rather than inserted into this
per-chunk sequence. Android's undecodable-record archive remains a separate
pre-ack durability condition. Any error in the applicable sequence short-circuits
before the client sends the ack. The
ack itself is the link-layer half: `HISTORICAL_DATA_RESULT(23)` with payload `[0x01] + end_data`
written `.withResponse`. A BLE write confirmation is not itself proof of physical erasure or power-loss durability. The
`strap_trim` cursor is persisted, so the client retains progress for another attempt; exact device replay after disconnect is not guaranteed. This local progress does not depend on a network.

<a id="75-watchdog--liveness"></a>

## Watchdog & liveness

- **Idle watchdog** (`backfillIdleTimeoutSeconds = 60`): Swift re-arms it for offload
  types 47/48/49/50/56. Android uses the same list and, for WHOOP 5/MG, also type
  52. Both exclude the live type-43 flood. If the strap goes silent, the session
  exits and resumes next time via the durable cursor.
- **Swift-specific stuck detector** (`StuckStrapDetector`): after an offload, if the strap reports records newer
  than NOOP's frontier (from `GET_DATA_RANGE`, parsed by `dataRangeNewestUnix(from:)`) **and**
  that frontier has been frozen for the detector window, it flags `strapNeedsReboot` and attempts
  a defensive recovery (`EXIT_HIGH_FREQ_SYNC` + `SET_CLOCK`). Off-wrist / caught-up (strap not
  ahead) is **not** treated as stuck.

---

<a id="8-decoded-output-parsedframe"></a>

## Decoded output (`ParsedFrame`)

`parseFrame(_:)` returns a `ParsedFrame` with the envelope verdict, a typed field list
(`[DecodedField]`), and a flat `parsed: [String: ParsedValue]` dictionary that downstream code
reads.

**`ok` means "intact", not "parsed".** It carries `verifyFrame`'s full verdict — header checksum,
payload CRC32 and structural size together — for the frame as a whole. It is *not* a parsability
signal: a frame with a broken header still gets decoded, so an inspector surface, a capture export
or a diagnostic summary keeps the frame's `typeName` and its `parsed` fields even when `ok` is
false. Code that wants to know whether the decode produced anything must ask for that (the parser
returns `typeName == "INVALID/FRAGMENT"` when it could not decode at all), not read `ok`.

**`rejectReason` says why.** It is a non-optional `FrameRejectReason` sitting on the parse result
itself, so a consumer can report the cause from the value it was handed — the frame is parsed
exactly once and the result threaded onwards, and a consumer that had to re-verify to learn the
reason would break that invariant. `.none` accompanies a positive verdict and only that:

| `rejectReason` | Meaning |
|---|---|
| `none` | Intact: header checksum, payload CRC32 and structural size all agree. |
| `noStartOfFrame` | No `0xAA` — this byte run is not a frame. |
| `belowMinimumLength` | Below the family minimum (11 / 13 bytes). |
| `lengthMismatch` | Byte count ≠ the total the length field declares: truncated, or trailing bytes. |
| `headerChecksumMismatch` | CRC8 (4.0) or CRC16-Modbus (5.0/MG) disagreed. |
| `payloadCRCMismatch` | The payload CRC32 was computed and disagreed. |

An unavailable CRC diagnostic is never promoted to a checksum reason: the preceding minimum or
exact-length rule rejects that byte run first. Thus every declared reason has a real input class and
is pinned by the shared parity oracle. Decoding a `ParsedFrame` from an older capture that predates
the field defaults `rejectReason` to `.none` rather than failing.

**Named inner-field reads are bounded by the CRC32 trailer.** Every read of a named field —
sequence byte, command byte, and the schema-driven fields including the per-type post-hooks — is
clamped to the **minimum of where the trailer starts and the frame's real size**. The minimum is
required in both directions: the trailer start follows from the *declared* length and points past
the buffer on a truncated frame, while the frame size alone is what let a frame sitting at the
family minimum have its own checksum trailer decoded as a sequence number or a metadata type. A
field counts as present when its start plus its length does **not exceed** that bound — the
smallest real WHOOP 4.0 history frame is 11 bytes with its trailer at 7, and its metadata type
occupies precisely the last payload byte, so a stricter comparison would swallow
`HISTORY_COMPLETE`. The one exception is the 8-byte `end_data` acknowledgement block that the
[safe-trim invariant](#74-safe-trim-invariant) echoes back to the strap verbatim: it reaches into the
CRC32 trailer by construction (on the real 25-byte `HISTORY_END` frame the trailer starts at 21 and
the block runs 17…25) and is an opaque echo, not a decoded field.

Key `parsed` entries by packet type:

| Packet | `parsed` keys (examples) |
|--------|--------------------------|
| `REALTIME_DATA` (40) | `heart_rate`, `rr_intervals` |
| `REALTIME_RAW_DATA` (43) | `heart_rate`, `rr_intervals`, IMU axis means, `ppg_mean` |
| `EVENT` (48) | `event`, `battery_pct`, `battery_mV`, `battery_charging` |
| `COMMAND_RESPONSE` (36) | `battery_pct`, `clock`, `fw_harvard`, `fw_boylston`, `history_oldest`, `history_newest` |
| `HISTORICAL_DATA` (47) | `hist_version`, schema-versioned biometric fields, `rr_intervals` |
| `METADATA` (49) | `meta_type`, `unix`, `subsec`, `trim_cursor` |
| `CONSOLE_LOGS` (50) | `log` (capped at 2048 chars) |

`HISTORICAL_DATA` (type-47) layout is selected by the version byte (`seq`) via
`Schema.resolveVersion(_:_:)`, which follows a `ref` chain (e.g. V12 → V24) so newer versions
inherit a base layout and override only what changed. The streamed decode that feeds SQLite is in
`Streams.swift` / `HistoricalStreams.swift` (`extractStreams`, `extractHistoricalStreams`).

---

<a id="10-spo₂-on-50--mg--what-the-wire-does-and-does-not-carry"></a>

<a id="spo₂-on-50--mg--what-the-wire-does-and-does-not-carry"></a>

## SpO₂ on WHOOP 5/MG — what the wire does and does not carry

No dedicated SpO₂ read operation is identified in the current command reference.
R18 byte 82 has no established physiological meaning. NOOP imports
`blood_oxygen_pct` as a per-cycle value; that importer does not establish the
vendor's aggregation or calibration algorithm. See the
[raw-record interpretation limits](PROTOCOL_SENSORS.md).

<a id="11-file-map"></a>

## File map

| Path | Responsibility |
|------|----------------|
| `../Packages/WhoopProtocol/Sources/WhoopProtocol/Framing.swift` | SOF/length/CRC8/CRC16/CRC32, `verifyFrame`, `Reassembler`, `frameFromPayload` |
| `../Packages/WhoopProtocol/Sources/WhoopProtocol/Interpreter.swift` | `parseFrame` (WHOOP 4 and WHOOP 5/MG), `ParsedFrame`, field construction |
| `../Packages/WhoopProtocol/Sources/WhoopProtocol/DeviceFamily.swift` | UUID strings, header-CRC kind, `CLIENT_HELLO`, puffin aliasing |
| `../Packages/WhoopProtocol/Sources/WhoopProtocol/Schema.swift` | JSON schema model + `loadSchema()` |
| `../Packages/WhoopProtocol/Sources/WhoopProtocol/PostHooks.swift` | per-type irregular-field decoders |
| `../Packages/WhoopProtocol/Sources/WhoopProtocol/HistoricalMeta.swift` | `classifyHistoricalMeta` (START/END/COMPLETE) |
| `../Packages/WhoopProtocol/Sources/WhoopProtocol/Resources/whoop_protocol.json` | canonical enums + packet layouts |
| `../Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5Ecg.swift` | MG ECG ("Labrador") packet decode + command construction |
| `../Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5EcgProbe.swift` | ECG turn-on report + the run-scoped result-code verdicts |
| `../Strand/BLE/BLEManager.swift` | CoreBluetooth transport, bond, connect lifecycle, backfill orchestration |
| `../Strand/BLE/Commands.swift` | safe `WhoopCommand` set + outbound frame construction |
| `../Strand/BLE/FrameRouter.swift` | decode → `LiveState` (UI) |
| `../Strand/BLE/StandardHeartRate.swift` | `0x2A37` HR/R-R parser |
| `../Strand/Collect/Backfiller.swift` | historical-offload state machine + safe-trim invariant |
| `../android/app/src/main/java/com/noop/protocol/Enums.kt` | Android command and event identifiers |
| `../android/app/src/main/java/com/noop/protocol/Framing.kt` | Android family-aware framing and response decoding |
| `../android/app/src/main/java/com/noop/ble/WhoopBleClient.kt` | Android BLE lifecycle, command sending and offload routing |

---

*This is an independent interoperability project for the user's own device and
data; it is not affiliated with WHOOP and is not a medical device.*

## Earlier command-response observations

**The first body byte is per-command, and is not a status flag.** Use the [complete battery response](PROTOCOL_TRANSPORT.md#battery-level--command-26); the older first-byte observation below does not establish a one-byte current body. `GET_BATTERY_LEVEL` puts the charge
percentage there — `47` in the hardware-confirmed fixture — so the slot carries real data. On other
commands it has only ever been observed as `1`:

| capture | command | result | first body byte |
|---|---|---|---:|
| real 5/MG | `GET_BATTERY_LEVEL` | SUCCESS | **47** (= 47%) |
| real 5/MG | `GET_DATA_RANGE` | SUCCESS | 1 |
| real MG | `SELECT_WRIST`, accepted | SUCCESS | 1 |
| real MG | `SELECT_WRIST`, refused | FAILURE | 1 |
| real MG | `TOGGLE_LABRADOR_*` | SUCCESS | 1 |

For the revision-1 wrist and ECG controls, the first response-body byte is a
literal revision marker, not wrist or enable-state readback. The historical accepted/refused
captures above remain observations of their respective runs; identical body bytes do not
prove that a requested state was applied. See [ECG](PROTOCOL_ECG.md).
