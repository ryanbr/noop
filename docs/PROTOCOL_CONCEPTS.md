# Shared protocol concepts

Read the [scope and compatibility](PROTOCOL.md#scope-and-compatibility) before applying this page.

## Standard SIG services (both generations)

| Service | UUID | Characteristic | UUID | Notes |
|---------|------|----------------|------|-------|
| Heart Rate | `180D` | HR Measurement | `2A37` | HR + R-R; works **unbonded** |
| Battery | `180F` | Battery Level | `2A19` | single byte = battery percent |

Heart Rate Measurement uses a flag byte, 8- or 16-bit HR, optional Energy Expended
and R-R intervals in units of 1/1024 second. Battery Level is a single-byte percent.
These standard characteristics are separate from the custom command replies.

---

<a id="2-frame-envelope"></a>

## Frame envelope

A frame is a self-delimiting byte string beginning with a Start-Of-Frame marker and ending with
a CRC32 trailer. The two generations share the CRC32 payload check but differ in the header
checksum. Select the family before parsing:

| Family | Header check | Enum (`HeaderCRCKind`) |
|--------|--------------|------------------------|
| `whoop4` | CRC8 (poly `0x07`) | `.crc8` |
| `whoop5` | CRC16-Modbus (poly `0xA001`, init `0xFFFF`, reflected) | `.crc16Modbus` |

<a id="25-checksums"></a>

## Checksums

| Algorithm | Function | Parameters |
|-----------|----------|------------|
| CRC8 | `crc8(_:)` | table-driven, poly `0x07`, init `0x00` |
| CRC32 (zlib) | `crc32(_:)` | reflected, poly `0xEDB88320`, init `0xFFFFFFFF`, final XOR `0xFFFFFFFF` |
| CRC16-Modbus | `crc16Modbus(_:)` | poly `0xA001`, init `0xFFFF`, reflected |

Validate the complete frame before decoding or updating state. CRC checks detect
corruption; they are not cryptographic authentication. Generation-specific length
and header rules are defined in the profiles.

## Requests, results and delivery

A BLE write acknowledgement, a command result, completion of asynchronous work and delivery of a measurement are separate events. Correlate replies within the connection and command context; do not interpret the first command-body byte as a universal success flag. Byte offsets belong to the selected [WHOOP 4](PROTOCOL_WHOOP4.md) or [WHOOP 5/MG](PROTOCOL_WHOOP5.md) profile.

## History and durable ownership

Historical transfer uses START, chunk END and COMPLETE concepts. Save the data needed by the application durably before acknowledging its corresponding chunk. Preserve the received acknowledgement token rather than reconstructing it from assumed timestamps. This client invariant does not promise exactly-once delivery, physical erasure or power-loss durability. The [WHOOP 5/MG transport](PROTOCOL_TRANSPORT.md#history-sequencing-and-storage-ownership) specifies its boundary conditions; the [WHOOP 4 profile](PROTOCOL_WHOOP4.md#72-history_end-payload-layout) retains the older token layout.
