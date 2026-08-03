# WHOOP BLE Protocol

This document specifies the Bluetooth Low Energy (BLE) wire protocol that NOOP uses to talk
**directly to a WHOOP strap you own** (4.0 and 5.0/MG). It is a reverse-engineering reference:
frame envelope, checksums, packet/command/event enumerations, the bond handshake, and the
historical-data offload state machine.

NOOP is a standalone, fully offline companion. It pairs over BLE, decodes the strap's own
streams on-device, and stores everything locally in SQLite. There is no cloud or account
involved in any of the exchanges described here.

> **Interoperability & safety note.** This describes interoperation with the user's *own*
> device and the data it already holds. NOOP is **not affiliated with, authorized by, or
> endorsed by WHOOP**, and it is **not a medical device** — nothing here is intended for
> diagnosis or treatment. The command set NOOP sends is deliberately a *safe subset*;
> destructive opcodes are documented only so they can be explicitly avoided
> (see [Destructive commands — do not send](#destructive-commands--do-not-send)).

The protocol decoder is platform-pure Swift in the `WhoopProtocol` package
(`Packages/WhoopProtocol/`); it never imports CoreBluetooth, so it runs unchanged in tests and
CLI tools. The CoreBluetooth transport lives under `Strand/BLE/` and is shared by both the
macOS and iOS app targets (the platform-pure `WhoopProtocol` package above stays
CoreBluetooth-free for tests and CLI tools).

This work builds on two community reverse-engineering efforts:

- **`johnmiddleton12/my-whoop`** — WHOOP 4.0 protocol.
- **`b-nnett/goose`** — WHOOP 5.0 fd4b ("puffin" packet framing) protocol.

The canonical decode tables are bundled as a JSON resource:
`Packages/WhoopProtocol/Sources/WhoopProtocol/Resources/whoop_protocol.json`, loaded by
`loadSchema()` in `Schema.swift`.

---

## 1. GATT topology

Each WHOOP generation advertises a vendor-specific primary service plus the two standard SIG
services (Heart Rate and Battery). The custom service carries the framed command/response/
event/data channels; the standard services work even before bonding.

### WHOOP 4.0 — service `61080001-…`

Defined in `BLEManager.swift` (the on-device, authoritative UUIDs) and mirrored as plain
strings in `DeviceFamily.swift`. The same `Strand/BLE/` sources (`BLEManager`,
`StandardHeartRate`, `FrameRouter`) back both Apple-platform targets — macOS and iOS.

| Role | UUID | Direction |
|------|------|-----------|
| Custom service | `61080001-8d6d-82b8-614a-1c8cb0f8dcc6` | — |
| Command write (`cmdWriteChar`) | `61080002-8d6d-82b8-614a-1c8cb0f8dcc6` | app → strap |
| Command-response notify (`cmdNotifyChar`) | `61080003-8d6d-82b8-614a-1c8cb0f8dcc6` | strap → app |
| Event notify (`eventNotifyChar`) | `61080004-8d6d-82b8-614a-1c8cb0f8dcc6` | strap → app |
| Data notify (`dataNotifyChar`, fragmented) | `61080005-8d6d-82b8-614a-1c8cb0f8dcc6` | strap → app |

### WHOOP 5.0 / MG — service `fd4b0001-…`

The 5.0 transport ("puffin") adds a fifth characteristic (`…0007`). UUID strings are in
`DeviceFamily.characteristicUUIDStrings`.

| Role | UUID |
|------|------|
| Custom service | `fd4b0001-cce1-4033-93ce-002d5875f58a` |
| Command write | `fd4b0002-cce1-4033-93ce-002d5875f58a` |
| Notify channels | `fd4b0003`, `fd4b0004`, `fd4b0005`, `fd4b0007` (`…-cce1-4033-93ce-002d5875f58a`) |

NOOP's historical "puffin" label refers to this fd4b Maverick/Goose framing. Decompiled WHOOP app
taxonomy also names a separate `PUFFIN` service family at
`11500001-6215-11ee-8c99-0242ac120002`; NOOP names that metadata `puffin1150` to avoid confusing it
with the implemented fd4b path.

### Diagnostic-only WHOOP service families

The official app also models additional WHOOP service families with the same `0001` service plus
`0002`/`0003`/`0004`/`0005`/`0007` characteristic pattern. NOOP lists these as protocol metadata and
logs them when advertised, but does not connect, discover characteristics, or send commands for them
until the correct framing is mapped and hardware-tested.

| Family label in NOOP | Service UUID | Current status |
|----------------------|--------------|----------------|
| `puffin1150` | `11500001-6215-11ee-8c99-0242ac120002` | detected but unsupported |
| `monument` | `8a580001-2fe8-4796-9267-b87a2b0c8234` | detected but unsupported; likely Castle/Rev2 framing |
| `symphony` | `59830001-5955-419b-bb8d-c8262926af23` | detected but unsupported; likely Castle/Rev2 framing |

### Standard SIG services (both generations)

| Service | UUID | Characteristic | UUID | Notes |
|---------|------|----------------|------|-------|
| Heart Rate | `180D` | HR Measurement | `2A37` | HR + R-R; works **unbonded** |
| Battery | `180F` | Battery Level | `2A19` | single byte = battery percent |

The `0x2A37` channel is the BLE-standard Heart Rate Measurement and is parsed by the pure
`StandardHeartRate.parse(_:)` (`Strand/BLE/StandardHeartRate.swift`): flag byte, 8- or 16-bit
HR, optional Energy-Expended skip, then R-R intervals in 1/1024 s converted to milliseconds.
NOOP treats this as the *reliable* HR/R-R source (the custom `REALTIME_DATA` stream usually
reports `rr_count = 0`). `0x2A19` is read as a raw percent (`state.setBattery(Double(pct))`).

`DeviceFamily` keeps CoreBluetooth out of the protocol package: it exposes UUIDs as **strings**;
the app layer wraps them in `CBUUID(string:)`.

---

## 2. Frame envelope

A frame is a self-delimiting byte string beginning with a Start-Of-Frame marker and ending with
a CRC32 trailer. The two generations share the CRC32 payload check but differ in the header
checksum. The branch point is `DeviceFamily.headerCRCKind`:

| Family | Header check | Enum (`HeaderCRCKind`) |
|--------|--------------|------------------------|
| `whoop4` | CRC8 (poly `0x07`) | `.crc8` |
| `whoop5` | CRC16-Modbus (poly `0xA001`, init `0xFFFF`, reflected) | `.crc16Modbus` |

### 2.1 WHOOP 4.0 envelope

```
┌──────┬───────────────┬───────┬───────────── inner ─────────────┬─────────────┐
│ 0xAA │ length  u16 LE │ crc8  │ type │ seq │ cmd │  payload …    │ crc32 u32 LE│
│ [0]  │ [1..3]         │ [3]   │ [4]  │ [5] │ [6] │ [7 .. len)    │ [len .. +4) │
└──────┴───────────────┴───────┴───────────────────────────────────┴────────────┘
total frame size = length + 4
```

- **`0xAA`** — Start Of Frame.
- **`length`** — `u16` little-endian. Equals `inner.count + 4` (the inner `[type][seq][cmd]
  payload]` plus the 4 envelope bytes). It is the offset at which the CRC32 trailer begins.
- **`crc8`** — CRC8 (table-driven, poly `0x07`) computed over the **two length bytes only**
  (`crc8([frame[1], frame[2]])`).
- **inner record** — `type` (packet type, §3), `seq` (sequence / version byte), `cmd`
  (command number, §6), then the payload.
- **`crc32`** — standard zlib CRC-32 (reflected, poly `0xEDB88320`), `u32` little-endian,
  computed over the **inner bytes** `frame[4 .. length)`.

Reference: `verifyFrame(_:)` and `crc8(_:)` / `crc32(_:)` in `Framing.swift`, and the
outbound builder `WhoopCommand.frame(seq:payload:)` in `Strand/BLE/Commands.swift`.

```swift
// Framing.swift — WHOOP 4.0 validation (abridged)
let length = u16le(frame, 1)
let crc8OK = crc8([frame[1], frame[2]]) == frame[3]
if 7 <= length && length + 4 <= frame.count {
    let inner = Array(frame[4..<length])
    crc32OK = crc32(inner) == u32le(frame, length)
}
```

### 2.2 WHOOP 5.0 / MG envelope

The 5.0 envelope (reverse-engineered from `goose`) inserts a format byte and a CRC16-Modbus
header check, and shifts the inner record to offset 8:

```
┌──────┬────────┬──────────────────┬────────────┬───────────────┬──── inner ────┬─────────────┐
│ 0xAA │ format │ declLength u16 LE│ header [2] │ crc16 u16 LE  │ type seq cmd …│ crc32 u32 LE│
│ [0]  │ [1]    │ [2..4]           │ [4..6]     │ [6..8]        │ [8 ..]        │ tail (4)    │
└──────┴────────┴──────────────────┴────────────┴───────────────┴───────────────┴─────────────┘
total frame size = declLength + 8
```

- **`format`** — `0x01`.
- **`declLength`** — `u16` LE; counts the payload **plus** the 4-byte CRC32 trailer
  (so payload length = `declLength − 4`, and the trailer starts at `declLength + 8 − 4`).
- **`crc16`** — CRC16-Modbus over the first **6** header bytes (`frame[0..<6]`), stored LE at
  `frame[6..8]`.
- **inner record** — starts at **offset 8**: `type` `[8]`, `seq` `[9]`, `cmd` `[10]`, payload `[11..]`.
- **`crc32`** — same zlib CRC-32, LE, over the payload `frame[8 .. declLength+4)`.

Reference: `verifyFrameWhoop5(_:)` / `parseFrameWhoop5(_:)`. For a uniform "header CRC ok?"
signal across families, the `FrameCheck.crc8OK` field carries the **CRC16** outcome on 5.0.

The static WHOOP 5.0 `CLIENT_HELLO` (16 bytes, a fully-formed type-35 frame with CRC16 header
and CRC32 trailer) is `DeviceFamily.whoop5ClientHello`:

```
AA 01 08 00 00 01 E6 71 23 01 91 01 36 3E 5C 8D
```

WHOOP 4.0 has **no** fixed hello (`clientHello == nil`); it uses the bond-write handshake (§5).

### 2.3 Family-aware entry points

```swift
public func verifyFrame(_ frame: [UInt8], family: DeviceFamily) -> FrameCheck
public func parseFrame(_ frame: [UInt8], family: DeviceFamily) -> ParsedFrame
```

`whoop4` behaves exactly like the no-family overloads (back-compat). The "puffin" types
`38 PUFFIN_COMMAND_RESPONSE` and `56 PUFFIN_METADATA` are aliased onto `COMMAND_RESPONSE` /
`METADATA` by `canonicalTypeName(_:schema:)` so they never decode as "unknown".

### 2.4 COMMAND_RESPONSE body

Every reply to a command (`COMMAND_RESPONSE`, type 36 — and its 5/MG alias 38) opens with two bytes
before whatever the command itself returns:

```
WHOOP 4.0    [6] resp_cmd   [7] resp_seq   [8] result   [9..] per-command body
WHOOP 5/MG   [10] resp_cmd  [11] resp_seq  [12] result  [13..] per-command body
```

the 5/MG offsets being the 4.0 ones + 4, like the rest of the puffin inner record.

- **`resp_cmd`** — the command being answered (`CommandNumber`).
- **`resp_seq`** — the strap's own per-response counter. Not the envelope `seq` at `[5]`/`[9]`, which is
  host-assigned and echoed back: a single capture shows envelope `seq` 147 alongside `resp_seq` 2. A
  repeated `resp_seq` across replies is how a duplicated write was identified in #791.
- **`result`** — `CommandResult`: `0` FAILURE, `1` SUCCESS, `2` PENDING, `3` UNSUPPORTED. `GET_DATA_RANGE`
  answers PENDING then SUCCESS; `3` is what a real MG returned when it rejected `RUN_HAPTICS_PATTERN`
  (#48). Both fields are decoded from the bounded payload slice, so a reply too short to carry them
  yields neither rather than reading the CRC32 trailer (#894).

**The first body byte is per-command, and is not a status flag.** `GET_BATTERY_LEVEL` puts the charge
percentage there — `47` in the hardware-confirmed fixture — so the slot carries real data. On other
commands it has only ever been observed as `1`:

| capture | command | result | first body byte |
|---|---|---|---:|
| real 5/MG | `GET_BATTERY_LEVEL` | SUCCESS | **47** (= 47%) |
| real 5/MG | `GET_DATA_RANGE` | SUCCESS | 1 |
| real MG | `SELECT_WRIST`, accepted | SUCCESS | 1 |
| real MG | `SELECT_WRIST`, refused | FAILURE | 1 |
| real MG | `TOGGLE_LABRADOR_*` | SUCCESS | 1 |

For the wrist and ECG commands what that `1` means is **open**. A capture that sent `SELECT_WRIST` with
argument `0` got `1` back, which refutes an echo of the request — but every frame anyone has captured had
a stored value of `1`, so "reads back stored state" and "this handler writes a literal `1`" make identical
predictions on all of them. It is therefore left undecoded rather than named; settling it needs a reply
from a strap whose stored value is `0`. See #891.

### 2.5 Checksums

| Algorithm | Function | Parameters |
|-----------|----------|------------|
| CRC8 | `crc8(_:)` | table-driven, poly `0x07`, init `0x00` |
| CRC32 (zlib) | `crc32(_:)` | reflected, poly `0xEDB88320`, init `0xFFFFFFFF`, final XOR `0xFFFFFFFF` |
| CRC16-Modbus | `crc16Modbus(_:)` | poly `0xA001`, init `0xFFFF`, reflected |

CRC32 is the protocol's **only payload-integrity guarantee**. Decode and state-update paths
reject any frame whose CRC32 fails: `FrameRouter.handle(frame:)` bails on `parsed.crcOK == false`,
and `classifyHistoricalMeta(_:)` refuses to act on a frame where `p.crcOK == false` — without
that gate a garbled or hostile peer could forge a `HISTORY_END`/`HISTORY_COMPLETE` and advance
the strap's trim cursor, discarding data that was never durably stored.

### 2.6 Reassembly

BLE notifications arrive as MTU-sized fragments. `Reassembler` (`Framing.swift`) accumulates
bytes, finds the `0xAA` SOF, reads the `u16` LE length at `buf[1..3]`, and emits a complete
frame once `buf.count ≥ length + 4`. Leading garbage before an SOF is discarded; a buffer with
no SOF is dropped. The app feeds the data/cmd/event notify characteristics through one
`Reassembler` in `peripheral(_:didUpdateValueFor:error:)`.

```swift
// usage in BLEManager
for frame in reassembler.feed(bytes) {
    router.handle(frame: frame)   // UI/state
    // … live ingest or backfill routing …
}
```

`frameFromPayload(_:type:seq:cmd:)` reconstructs a complete frame from a bare payload (used when
a capture stored only the data portion): it rebuilds the envelope with a correct zlib CRC32 and
a placeholder `0x00` CRC8 byte.

---

## 3. PacketType (offset `[4]`, or `[8]` on 5.0)

Source: `enums.PacketType` in `whoop_protocol.json`; resolved by `Schema.typeName(_:)`.

| Value | Name | Notes |
|------:|------|-------|
| 35 | `COMMAND` | outbound command (app → strap) |
| 36 | `COMMAND_RESPONSE` | reply to a command |
| 37 | `PUFFIN_COMMAND` | WHOOP 5.0 command |
| 38 | `PUFFIN_COMMAND_RESPONSE` | WHOOP 5.0; aliased → `COMMAND_RESPONSE` |
| 40 | `REALTIME_DATA` | live HR / R-R |
| 43 | `REALTIME_RAW_DATA` | live IMU/optical flood (~2/s, ~1.9 KB) |
| 47 | `HISTORICAL_DATA` | offloaded biometric records |
| 48 | `EVENT` | strap event (§4) |
| 49 | `METADATA` | offload control metadata (§7) |
| 50 | `CONSOLE_LOGS` | firmware log text |
| 51 | `REALTIME_IMU_DATA_STREAM` | |
| 52 | `HISTORICAL_IMU_DATA_STREAM` | |
| 53 | `RELATIVE_PUFFIN_EVENTS` | WHOOP 5.0 |
| 54 | `PUFFIN_EVENTS_FROM_STRAP` | WHOOP 5.0 |
| 55 | `RELATIVE_BATTERY_PACK_CONSOLE_LOGS` | |
| 56 | `PUFFIN_METADATA` | WHOOP 5.0; aliased → `METADATA` |

`isOffloadFrame(_:)` (in `BLEManager`) treats **47/48/49/50** as offload traffic; the live
`REALTIME_DATA`(40)/`REALTIME_RAW_DATA`(43) flood is excluded so it cannot keep the backfill
idle-watchdog alive.

The parser also exposes irregular fields through per-type **post-hooks**
(`registerPostHooks()` in `PostHooks.swift`): `realtime_data`, `event`, `command_response`,
`raw_data`, `historical_data`, `metadata`, `console_logs`. The static field layout per packet
comes from the schema's `packets` table; `REALTIME_RAW_DATA` is keyed by payload length
(`"1917"` = IMU, `"1921"` = optical), and `HISTORICAL_DATA` by its version byte (`seq`).

---

## 4. EventNumber (`EVENT`, type 48, value at `[6]`)

`EVENT` frames carry an `EventNumber` at `[6]` and a `u32` `event_timestamp` at `[8]`. A
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
The `BATTERY_LEVEL` event has a fixed decoded layout (see the `event` post-hook):
`soc% = u16@17 / 10`, `mV = u16@21`, `charging = u8@26 & 1`.

---

## 5. Bond handshake & connect lifecycle (WHOOP 4.0)

The custom channels only flow once the link is bonded. CoreBluetooth performs *just-works*
bonding the moment a confirmed (`.withResponse`) write succeeds, so NOOP bonds by sending one
benign command and waiting for the write acknowledgement.

```
scan(service 61080001) ─▶ connect ─▶ discoverServices
                                       └▶ discoverCharacteristics
                                            ├ on cmdWriteChar (0002):
                                            │    confirmed write GET_BATTERY_LEVEL  ── THE BOND TRICK
                                            └ on 0003/0004/0005/2A37/2A19: setNotifyValue(true)
        confirmed-write ack (didWriteValueFor, no error) ─▶ BONDED  (state.bonded = true)
```

After bonding, the connect handshake runs **exactly once** per connection (guarded by
`connectHandshakeDone`, because `didWriteValueFor` re-fires on every later `.withResponse`
write). Re-blasting the handshake mid-offload was the historical root cause of the strap
refusing to stream type-47, so the guard is load-bearing. The one-shot handshake (in
`peripheral(_:didWriteValueFor:error:)`) issues, in order:

1. `GET_HELLO_HARVARD` (35) — version/identity hello (mirrors the official flow; not strictly
   required to serve).
2. `GET_ADVERTISING_NAME_HARVARD` (76).
3. `SET_CLOCK` (10) — set the strap RTC to UTC; payload is the **8-byte** form
   `[seconds u32 LE][subseconds u32 LE]` (`BLEManager.setClockPayload()`). A wrong-length
   `SET_CLOCK` is ack'd but not latched, leaving the RTC "lost" so the strap won't serve type-47.
4. `GET_CLOCK` (11) with an **empty** payload (the strap ignores a wrong-length payload). The
   response establishes the device↔wall `ClockRef` correlation used for realtime decode.
5. `SEND_R10_R11_REALTIME` (63) with `[0x00]` — stop the ~2/s type-43 raw flood (BLE airtime /
   battery / flash). This is the *real* control for that stream; `STOP_RAW_DATA` (82) does not
   affect it.
6. `GET_DATA_RANGE` (34) — refresh the strap's stored record range for the liveness watchdog.
7. After ~1.5 s (so the link settles), the first historical offload via `requestSync(.connect)`.

A periodic backfill timer (`backfillIntervalSeconds = 900`, i.e. 15 min, matching WHOOP) and a
keep-alive timer (`keepAliveIntervalSeconds = 30`: re-arm realtime, poll battery, watchdog the
link) are then started. The `GET_CLOCK` response is decoded by `ClockCorrelation` to produce a
`ClockRef(device:wall:)`; this unblocks both the live `Collector` and the `Backfiller`.

> WHOOP 5.0 instead writes the static `CLIENT_HELLO` frame (§2.2) to its `…0002` command
> characteristic immediately after discovery.

---

## 6. CommandNumber (sending) — the safe subset

NOOP exposes a curated, **safe** command set in `WhoopCommand` (`Strand/BLE/Commands.swift`).
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
| 1 | `LINK_VALID` | — | link keep-alive |
| 3 | `TOGGLE_REALTIME_HR` | `[0x01]`/`[0x00]` | start/stop live HR stream (type-40) |
| 7 | `REPORT_VERSION_INFO` | — | firmware versions (decoded by `command_response` hook) |
| 10 | `SET_CLOCK` | `[secs u32 LE][subsecs u32 LE]` | set strap RTC (UTC) |
| 11 | `GET_CLOCK` | *empty* | read RTC → `ClockRef` correlation |
| 22 | `SEND_HISTORICAL_DATA` | `[0x00]` | begin offload of the type-47 store |
| 23 | `HISTORICAL_DATA_RESULT` | `[0x01] + end_data(8)` | ack a `HISTORY_END` chunk / advance trim |
| 26 | `GET_BATTERY_LEVEL` | `[0x00]` | battery percent; also the **bond** write |
| 34 | `GET_DATA_RANGE` | `[0x00]` | strap's stored oldest/newest record range; #689 also logs a diagnostic ring-buffer page backlog — see below |
| 35 | `GET_HELLO_HARVARD` | `[0x00]` | identity/version hello |
| 39 / 40 | `SET_LED_DRIVE` / `GET_LED_DRIVE` | — | optical LED drive (research) |
| 41 / 42 | `SET_TIA_GAIN` / `GET_TIA_GAIN` | — | optical front-end gain (research) |
| 43 / 44 | `SET_BIAS_OFFSET` / `GET_BIAS_OFFSET` | — | optical bias (research) |
| 63 | `SEND_R10_R11_REALTIME` | `[0x00]` off / `[0x01]` on | the **real** type-43 raw-stream switch |
| 66 | `SET_ALARM_TIME` | `[0x01]+epoch u32 LE+[0,0]` | arm firmware alarm |
| 67 | `GET_ALARM_TIME` | `[0x01]` | read armed alarm |
| 68 | `RUN_ALARM` | `[0x01]` | app-driven alarm now |
| 69 | `DISABLE_ALARM` | `[0x01]` | disarm firmware alarm |
| 76 | `GET_ADVERTISING_NAME_HARVARD` | `[0x00]` | advertised name |
| 79 | `RUN_HAPTICS_PATTERN` | `[patternId, loops, 0,0,0]` | buzz a preset haptic pattern |
| 80 | `GET_ALL_HAPTICS_PATTERN` | — | enumerate preset patterns |
| 81 / 82 | `START_RAW_DATA` / `STOP_RAW_DATA` | `[0x01]` | raw-data collection toggle |
| 84 | `GET_BODY_LOCATION_AND_STATUS` | — | wrist/body-location status (read-only diagnostic probe, #690 — below) |
| 96 / 97 | `ENTER_HIGH_FREQ_SYNC` / `EXIT_HIGH_FREQ_SYNC` | `[0x00]` | high-freq offload mode |
| 98 | `GET_EXTENDED_BATTERY_INFO` | — | extended battery (mV etc.) |
| 100 | `CALIBRATE_CAPSENSE` | — | recalibrate cap-touch |
| 105 / 106 | `TOGGLE_IMU_MODE_HISTORICAL` / `TOGGLE_IMU_MODE` | `[0x01]` | IMU stream mode |
| 107 | `ENABLE_OPTICAL_DATA` | — | optical (PPG) data |
| 117 | `START_FF_KEY_EXCHANGE` | `[0x01]` | how many feature flags the firmware knows (read-only enumeration probe, #761 — below) |
| 118 | `SEND_NEXT_FF` | `[0x01]` | next feature-flag NAME (cursor, not index; read-only, #761 — below) |
| 122 | `STOP_HAPTICS` | `[0x00]` | stop an in-progress haptic |
| 123 | `SELECT_WRIST` | — | set strap wrist |

**Payload builders** in `WhoopCommand`:

- `setAlarmPayload(epochSec:)` → `[0x01] + epoch u32 LE + [0x00, 0x00]` (7 bytes).
- `BLEManager.setClockPayload(now:)` → `[secs u32 LE][0,0,0,0]` (8 bytes; subseconds in
  1/32768 s, zero is fine).

> **Note on `ENTER_HIGH_FREQ_SYNC` (96):** current builds do **not** enter high-freq sync; they
> send `EXIT_HIGH_FREQ_SYNC` (97) defensively on connect to release a strap a previous app may
> have parked there. Plain `SEND_HISTORICAL_DATA` returns the type-47 store without it.

### Additional 5-class command numbers

Command bytes present on a 5-class (MAVERICK) strap beyond the safe subset above. NOOP does not
send these; they are recorded for completeness.

| Code | Command | Purpose |
|-----:|---------|---------|
| 48 (0x30) | `SEND_EVENT_PACKETS` | flush stored event packets |
| 61 (0x3D) | `SET_AFE_PARAMETERS` | set optical AFE parameters |
| 62 (0x3E) | `GET_AFE_PARAMETERS` | read optical AFE parameters |

On MAVERICK the clock commands also answer in the high opcode space — `SET_CLOCK` at 146 (0x92)
and `GET_CLOCK` at 147 (0x93), alongside `GET_HELLO` at 145 (0x91) — distinct from the 4.0
numbers (10 / 11) above.

The strap further exposes an ECG/HeartKey command family. The `CommandNumber` table carries four codes
for it — 123 `SELECT_WRIST`, 124 `TOGGLE_LABRADOR_DATA_GENERATION`, 125 `TOGGLE_LABRADOR_RAW_SAVE`,
139 `TOGGLE_LABRADOR_FILTERED` — which are **not** contiguous, and an earlier revision of this section
described "five consecutive codes around 0x7B–0x8B" against five names (`ECG_MAIN_CONTROL`,
`ECG_SEND_RAW`, `ECG_SAVE_RAW`, `ECG_SAVE_FILTERED`, `ECG_SELECT_WRIST`). Both cannot be right:
`ECG_SEND_RAW` has no code, and 139 (0x8B) is separated from 123–125 (0x7B–0x7D). Treat the name↔code
mapping as unconfirmed — the 5/MG is known to remap opcodes into the high space (the clock family answers
at 145/146/147 there versus 10/11 on a 4.0), so a code that is accepted is not evidence that it means
what the name says.

What is confirmed: on a real WHOOP 5 MG (`WS50_r03`), 124, 125 and 139 are all **accepted** — each
answers `COMMAND_RESPONSE` with result `SUCCESS(1)` — and no ECG-shaped data followed in a 30-second
window. That is a null result with several live explanations (an open electrode circuit, flash rather
than a realtime channel, a wrong opcode mapping, no start verb, a flag block, an entitlement gate); see
#891. The three reply frames are pinned as decode fixtures in `Whoop5CommandResponseTests` /
`CommandCatalogueTest`.

NOOP sends these only from the gated, hand-run MG ECG probe described in
[§9.1](#91-ecg-labrador-on-the-mg) — never automatically, never on a plain 5.0 or a 4.0, and only
behind the Experimental opt-in plus a positively-identified MG. That is four codes for five names, so
the correspondence remains a working hypothesis rather than a confirmed mapping.

The strap also exposes an `IMU_SET_DATA_STREAM` (code 106, shared with `TOGGLE_IMU_MODE`) and a
`UART_DISABLE` (0x61–0x69). Exact codes for these are unconfirmed.

### Destructive commands — *do not send*

These exist on the wire but are **deliberately excluded** from `WhoopCommand`. They can wipe
data, brick, or power-cycle the strap. NOOP must never send them.

| Code | Command | Hazard |
|-----:|---------|--------|
| 25 | `FORCE_TRIM` | discards stored data |
| 32 | `POWER_CYCLE_STRAP` | power-cycles (gated probe exception — see below) |
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

**Two guarded exceptions — both restarts, both non-destructive** (a restart keeps the strap's stored
data and just re-advertises after boot). Neither is ever sent automatically or on any connect/offload path.

- **`REBOOT_STRAP` (29)** — the normal Restart. NOOP already triggers a reboot today via
  `SET_ADVERTISING_NAME_HARVARD` (rename applies on reboot). In `WhoopCommand` as `rebootStrap`, sent only
  from the user-initiated, confirmation-gated "Restart strap" action (`BLEManager.rebootStrap()` /
  `WhoopBleClient.rebootStrap()`) (#166).
- **`POWER_CYCLE_STRAP` (32)** — a harder restart, in the enum as `powerCycleStrap` **only** as a candidate
  for the WHOOP 4.0 reboot probe (below). Sent only from `rebootProbe(.powerCycle32Empty)`, itself gated
  behind Test Centre → Connection + a confirmation, and 4.0-only. Never on a default install.

Everything else in this table stays out of the enum entirely.

**WHOOP 4.0 reboot probe (#235).** A real 4.0 silently ignores the production `REBOOT_STRAP` frame (see
below) and the correct 4.0 reboot frame is unknown. The probe (Test Centre → Connection, 4.0 only) sends
one non-destructive candidate at a time — `REBOOT_STRAP(29)` empty, `POWER_CYCLE_STRAP(32)` empty, or
`REBOOT_STRAP(29)` with `[0x01]` — reusing the reboot watchdog so the strap log shows which one drops the
link (worked) vs is ignored. The definitive fix is still an HCI capture of the official app rebooting a
4.0 (the way the alarm frame was pinned, #535). Driven by `BLEManager.rebootProbe(_:)` /
`WhoopBleClient.rebootProbe(...)`; candidates enumerated in `RebootProbeVariant`.

**Body-location probe (#690).** A read-only, user-triggered diagnostic (Test Centre → Connection, both
families) that sends `GET_BODY_LOCATION_AND_STATUS` (84 / `0x54`) and dumps the strap's full raw
COMMAND_RESPONSE to the strap log + a copyable dialog. The 4-byte inner-payload record is
`revision · location · confidence · status`; `location` maps `0 UNKNOWN, 1 WRIST, 2 BICEP, 3 CALF,
4 SIDE_TORSO, 5 GLUTE, 7 ANKLE, 128 NOT_CONCLUSIVE, 160 UNKNOWN_GARMENT` (any other value — including the
gap at 6 — is kept raw; `confidence`/`status` stay raw until captures establish their semantics). Decoded
only on WHOOP 4.0, where the inner payload starts at the command byte + 1; on 5/MG the puffin envelope's
result code sits where `location` would land, so the raw grid is shown and the record is left undecoded
until a real 5/MG capture maps the offset. **Never** feeds wear detection, sleep gating, or scoring.
Driven by `BLEManager.probeBodyLocationAndStatus()` / `WhoopBleClient.probeBodyLocationAndStatus()`;
formatted by the pure `BodyLocationProbe` twin (Swift↔Kotlin byte-parity locked by a golden test). The
layout + enum facts are reverse-engineered from the WHOOP app and reimplemented in NOOP's own code
(facts, not copied expression — see [`ATTRIBUTION.md`](../ATTRIBUTION.md)).

**Feature-flag enumeration probe (#761, read-only).** NOOP has always been able to WRITE a feature flag
(`SET_FF_VALUE` / 120, the R22 unlock in `Whoop5Config`) but never to ASK a strap which flags it knows.
The `CommandNumber` table names a full symmetric read side that was never implemented — 117
`START_FF_KEY_EXCHANGE` / 118 `SEND_NEXT_FF` for feature flags, 115 / 116 for device config — and this
probe uses the enumerate pair only: **names, no values, nothing written.** `GET_FF_VALUE` (128) is
deliberately not sent: the only hands-on report of it (`johnmiddleton12/wearable`, run on the author's
own WHOOP 4.0 on fw 41.16.6.0) states its reply's value field is contaminated by a stale shared buffer,
so an on/off read is unreliable; the same session ran the 117→118 loop and got a complete key dump.

Request bodies are `[0x01]` (the inner b3 byte the SET_CONFIG family and `GET_HELLO` use); 118's body is
a **cursor, not an index**, so the same frame is repeated to walk the list. The reply is an ordinary
COMMAND_RESPONSE whose record sits behind the 2-byte response header (`pay[1]` is the 5/MG result code) —
the same `pay[2]` record start `GET_BATTERY_LEVEL` and `GET_CLOCK` already decode from:

| Command | Record (from `pay[2]`) |
|---|---|
| 117 `START_FF_KEY_EXCHANGE` | `revision u8` · `numberOfFeatureFlags u16 LE` · padding |
| 118 `SEND_NEXT_FF` | `revision u8` · `index u8` · `validKey u8` · `key` (ASCII, NUL-terminated) · padding |

The walk stops on the strap's own end marker (`validKey = 0`, or `index = 0xFF`), on the announced count,
or on a hard cap of 128 replies — and each 118 is only sent after the previous reply lands. Both CRCs are
verified before any field is read; a failed CRC, a non-COMMAND_RESPONSE type, or a short record ends the
walk with a named reason instead of a decode. Driven by `BLEManager.probeFeatureFlags()` /
`WhoopBleClient.probeFeatureFlags()` (user-triggered, Test Centre → Connection, both families) and
allowlisted for 5/MG framing **only while a probe is in flight**; parsed + rendered by the pure
`FeatureFlagProbe` / `FeatureFlagProbeReport` twins (Swift↔Kotlin byte-parity, unit-tested on synthetic
frames). Result goes to a copyable dialog + the strap log; no storage. The field order and opcode numbers
are facts read off a decompiled official client's response types and corroborated by that 4.0 dump,
reimplemented in NOOP's own code — facts, not copied expression (see [`ATTRIBUTION.md`](../ATTRIBUTION.md)).
**Unverified on 5/MG:** the published key dump is a 4.0's R19-era list; whether a 5/MG answers 117 at all
is what the probe exists to establish (§10).

**Device-config read probe (#103, read-only).** The #761 follow-up: that probe asked the strap for key
NAMES, this one asks for a named key's VALUE — and it reaches the namespace 117/118 never covered. NOOP
writes config through two different verbs into two different namespaces (`SET_FF_VALUE` / 120 for the
sixteen R22 feature flags in `Whoop5Config.enableR22Sequence`, `SET_DEVICE_CONFIG_VALUE` / 119 for the
Broadcast-HR key, #181) and has never read either. The `CommandNumber` table names the read side of both:
121 `GET_DEVICE_CONFIG_VALUE` and 128 `GET_FF_VALUE`.

**Both opcodes may simply not be implemented.** A number in the table is not a served verb — opcode 96
(`ENTER_HIGH_FREQ_HISTORICAL_MODE`) is the standing example of one nothing in the wild sends. So the
probe's primary deliverable is a per-verb verdict — **answered**, **rejected as UNSUPPORTED**, or
**silent** — and a clean "neither verb is served" is a useful result, not a failure. It spends exactly one
round-trip per verb establishing that (128 against a flag NOOP writes, 121 against the known-good
Broadcast-HR key) before doing anything else; a verb that is refused, silent or undecodable is **retired**,
so a dead verb costs one 8 s window rather than one per key.

Only a verb that answers goes on to read values: the sixteen known flag names (whose values NOOP has only
ever written, never read), then a short list of **guessed** oxygen-related key names against the
device-config namespace — `DeviceConfigReadProbe.oxygenCandidateKeys`, the one constant to extend, and
labelled as guesses everywhere they surface. That list is the #103 question in probe form: the byte at
deep-record offset 82 reads as real SpO2 on some straps and flat `0x00` on others, which is what a
subscription gate would look like, and a config key governing it would sit in the device-config namespace.

Request body is `[0x01]` (the inner b3 byte) + the key as ASCII NUL-padded to 32 bytes — the SET side's own
name field minus its value byte. That shape is **inferred from the SET side, not observed**; if it is wrong
the strap answers FAILURE or nothing, which the report says plainly. The reply is an ordinary
COMMAND_RESPONSE whose record sits behind the 2-byte response header, and **beyond that offset no field
layout is assumed**: the record is reported as raw hex. A value is only ever *claimed* when the reply
echoes the requested key inside a 32-byte NUL-padded field, in which case the byte immediately after that
field is the value — the SET layout, checked rather than assumed. (On 5/MG the puffin envelope pads the
inner payload to a 4-byte boundary, so trailing NULs in a record are envelope padding; reading "the byte
after the echoed field" rather than "the last byte" is what keeps that out of the answer.)

Read-only by construction. `DeviceConfigReadProbe.readOnlyOpcodes` is `{121, 128}` and
`isReadOnlyOpcode` is the *same predicate* the 5/MG `send()` allowlist consults — admitting them only
while a probe is in flight — so the "119/120 are never sent from this path" claim is a unit-tested property
of the allowlist rather than a comment. The plan is capped at 64 round-trips. Driven by
`BLEManager.probeDeviceConfigValues()` / `WhoopBleClient.probeDeviceConfigValues()` (user-triggered, Test
Centre → Connection, both families); parsed + planned + rendered by the pure `DeviceConfigReadProbe` /
`DeviceConfigReadProbeReport` twins (Swift↔Kotlin byte-parity, unit-tested on synthetic frames). Result
goes to a copyable dialog + the strap log; no storage. The opcode numbers come from this repo's own
protocol table (`Resources/whoop_protocol.json`). **Unverified on any strap:** nothing in this project has
ever had 121 or 128 answered.

**GET_DATA_RANGE ring backlog (#689, diagnostic only).** Beyond the oldest/newest timestamps NOOP already
scans from a `GET_DATA_RANGE` reply, the app computes a ring-buffer page backlog from three u32s in the
command-response inner payload (whose byte 0 is a subtype): write page `W = V(2)`, read pointer `U = V(3)`,
ring capacity `T = V(5)`, where `V(i)` is the u32 at inner offset `i·4 + 1` (frame offsets `cmdOff + 10/14/22`
here). Backlog with wraparound: `W < U ? W + (T − U) : W − U`. `DataRange.pagesBehind` (Swift + Kotlin twins,
byte-parity, unit-tested for normal / wraparound / too-short / implausible) logs `Strap backlog pages behind:
N` when it decodes plausibly — read u32 LE, guarded on frame length + a capacity sanity ceiling. **Never**
gates sync or backfill: the layout is RE'd from the WHOOP app (facts, reimplemented in NOOP's own code, see
[`ATTRIBUTION.md`](../ATTRIBUTION.md)) but **not yet confirmed against real 4.0 / 5-MG captures**, so it stays
a log-only diagnostic until a fixture pins the offsets + endianness.

**Payload forms** (decoded from the official app's command builders — recorded so the wire format is
*known*: for the destructive commands, known-and-avoidable; for the one guarded exception,
`REBOOT_STRAP`, known-and-used by `rebootStrap()`). The opcodes are shared across WHOOP 4 (harvard)
and WHOOP 5/MG (puffin): the app's unified command enum (`EnumC58479e`) uses the same `25`/`29`/`32`
on both transports — unlike haptics, which has a maverick-specific `0x13`.

- `FORCE_TRIM` (25) — body is **two little-endian int32 range args**. The app's "erase everything"
  form sets both to `-16843010` (`0xFEFEFEFE`), an 8-byte sentinel that trims the entire stored
  range (builder `rh0.C45484g`: `new C45484g(-16843010, -16843010)`). It is **not** an empty/`[0x00]`
  payload. This wipes the rolling ~14-day flash history — anything not already offloaded is gone.
- `REBOOT_STRAP` (29) — **empty body** (builder `rh0.C45476d0` passes a null payload). The strap drops
  the BLE link and re-advertises after boot; stored data is kept. Non-destructive, but interrupts any
  in-flight offload. **WHOOP 5.0 (puffin): hardware-confirmed** — the empty-body frame reboots a 5.0
  (fw 50.40.1.0, #227). **WHOOP 4.0 (harvard): NOT confirmed** — a real 4.0 silently ignores this
  empty-body frame (#235: no reboot, no disconnect, no COMMAND_RESPONSE), so the correct 4.0 form (a
  payload byte? a different opcode?) still needs an HCI capture of the official app rebooting a 4.0.

---

## 7. Historical-data offload (backfill)

The type-47 store is the strap's rolling ~14-day biometric history and is NOOP's **primary**
metric source (it is re-offloaded every 15 minutes while connected, mirroring WHOOP). An offload
is bracketed by `METADATA` (type 49) control frames and acknowledged chunk-by-chunk so the strap
can safely trim what it has handed over.

### 7.1 MetadataType (`METADATA[6]`)

`enums.MetadataType` in `whoop_protocol.json`; classified by `classifyHistoricalMeta(_:)`
(`HistoricalMeta.swift`).

| Value | Name | Meaning |
|------:|------|---------|
| 1 | `HISTORY_START` | offload beginning; start accumulating a chunk |
| 2 | `HISTORY_END` | chunk boundary; carries the trim cursor — **ack to advance** |
| 3 | `HISTORY_COMPLETE` | offload finished; close the session |

### 7.2 `HISTORY_END` payload layout

The `metadata` post-hook decodes the payload (which begins at `frame[7]`, after `[type][seq]
[cmd]`) as `struct '<LHLL'`:

| Frame offset | Payload offset | Field | Type | Meaning |
|-------------:|---------------:|-------|------|---------|
| 7 | 0 | `unix` | `u32` LE | record time (seconds) |
| 11 | 4 | `subsec` | `u16` LE | sub-seconds |
| 13 | 6 | `unk0` | `u32` LE | (unmapped) |
| 17 | 10 | `trim_cursor` | `u32` LE | ack with this to advance the strap's trim |

The 8-byte `end_data` the ack requires is `frame[17..25]` (= payload `[10..18]`), recovered by
`Backfiller.endData(from:)`. The trim cursor is the first `u32` of that slice.

### 7.3 Session state machine

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
   │       3. [if raw enabled] await enqueueRawBatch ── raw durable
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

### 7.4 Safe-trim invariant

A chunk is forgotten by the strap only after it is locally durable end-to-end. From
`Backfiller.finishChunk(...)`:

```
decode → await insert(decoded) → [await enqueueRawBatch] → await setCursor("strap_trim") → ackTrim
```

Any thrown error short-circuits before the ack, so an un-persisted chunk is never trimmed. The
ack itself is the link-layer half: `HISTORICAL_DATA_RESULT(23)` with payload `[0x01] + end_data`
written `.withResponse`, so the strap discards the chunk only once the write is confirmed. The
`strap_trim` cursor is persisted, so the next session resumes where the last left off — never
waiting on a network.

### 7.5 Watchdog & liveness

- **Idle watchdog** (`backfillIdleTimeoutSeconds = 60`): re-armed on every genuine offload frame
  (47/48/49/50) and only those; if the strap goes silent the session exits and resumes next time
  via the durable cursor. The live type-43 flood is dropped during offload so it cannot starve
  chunk acks.
- **Stuck detector** (`StuckStrapDetector`): after an offload, if the strap reports records newer
  than NOOP's frontier (from `GET_DATA_RANGE`, parsed by `dataRangeNewestUnix(from:)`) **and**
  that frontier has been frozen for the detector window, it flags `strapNeedsReboot` and attempts
  a defensive recovery (`EXIT_HIGH_FREQ_SYNC` + `SET_CLOCK`). Off-wrist / caught-up (strap not
  ahead) is **not** treated as stuck.

---

## 8. Decoded output (`ParsedFrame`)

`parseFrame(_:)` returns a `ParsedFrame` with the validated envelope, a typed field list
(`[DecodedField]`), and a flat `parsed: [String: ParsedValue]` dictionary that downstream code
reads. Key entries by packet type:

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

## 9. WHOOP 5.0 vs MG — telling the hardware apart

Both labels share the `fd4b…` GATT family and the same puffin envelope: framing, CRC, offload and
historical decode are **identical**, and `DeviceFamily.whoop5` covers both. What differs is hardware —
an MG carries the ECG-conductive clasp, a 5.0 does not.

`Whoop5Variant` resolves it from the standard BLE Device Information Service (`BLEManager` discovers
both characteristics as `disSerialChar` / `disHwRevChar`), deliberately orthogonal to `DeviceFamily` so
a capability gate can never change how a frame is parsed:

| Signal | DIS characteristic | Reads |
|---|---|---|
| Serial prefix `5AM` | Serial Number String (`0x2A25`) | MG |
| Serial prefix `5AG` | Serial Number String (`0x2A25`) | 5.0 |
| Hardware revision contains `WG50` | Hardware Revision String (`0x2A27`) | 5.0 |

Contradictory signals resolve to `.unknown` rather than a guess, and `.unknown` is not MG — an MG-only
feature stays gated off until the hardware attests to it. Only the 5.0 hardware string is attested on
real hardware so far; the MG's own revision string is not, so its absence proves nothing.

### 9.1 ECG ("Labrador") on the MG

The MG's ECG subsystem is called **Labrador** in the protocol tables. It is its own realtime data type,
**not** an R-numbered `StrapSensorData` layout: there is a FILTERED stream (live, display-ready) and a
RAW stream the strap persists for later offload.

> **Not a medical feature.** NOOP is not a medical device. The strap runs its own embedded rhythm
> classifier and ships the verdict in every packet; NOOP decodes that byte and nothing more. It is
> unvalidated instrumentation, never a measurement and never a diagnosis. See
> [`../DISCLAIMER.md`](../DISCLAIMER.md).

**Commands — a working hypothesis, not a confirmed mapping.** All four numbers are already in
`CommandNumber` (§6's table, from the upstream whoomp/goose work). Payload is `[revision, arg]` with
`revision = 0x01`, carried in the normal puffin envelope; `puffinCommandFrame`'s pad4 supplies the
command struct's trailing `padding` field.

Three reasons the numbers are **not** settled, all of which the on-hardware probe is meant to resolve:

1. **Four codes, five names.** §6 lists five ECG/HeartKey names; only four are mapped here.
   `ECG_SEND_RAW` is unaccounted for, so at least one of the four could be carrying the wrong name.
2. **139 (0x8B) is not contiguous** with 123–125, unlike the rest of the family.
3. **The table is 4.0-derived and 5/MG is known to remap opcodes.** §6's "Additional 5-class command
   numbers" already records MAVERICK answering `SET_CLOCK` at 146 and `GET_CLOCK` at 147 rather than
   10/11. So a 4.0-sourced number is not automatically the 5/MG number. This matters more than usual
   here: `CommandNumber`'s immediate neighbours in that range are
   **142 `START_FIRMWARE_LOAD_NEW` / 143 `LOAD_FIRMWARE_DATA_NEW` / 144 `PROCESS_FIRMWARE_IMAGE_NEW`** —
   the destructive family §6's "do not send" section excludes. NOOP never forms those bytes (they are
   absent from `WhoopCommand` entirely, so the command sender cannot express them), but anyone probing
   this space by hand should know what sits three codes above 139 before widening a sweep.

| Code | Command | Arg | Reversible? |
|-----:|---------|-----|---|
| 123 (0x7B) | `SELECT_WRIST` | `0` right / `1` left — **inferred from enum order, unconfirmed** | **Persistent device config** — survives disconnect; re-writable |
| 124 (0x7C) | `TOGGLE_LABRADOR_DATA_GENERATION` | `0` stop / `1` start / `2` restart | yes — `stop` is the OFF path |
| 125 (0x7D) | `TOGGLE_LABRADOR_RAW_SAVE` | `0`/`1` | yes |
| 139 (0x8B) | `TOGGLE_LABRADOR_FILTERED` | `0`/`1` | yes |

Documented turn-on order: `SELECT_WRIST` → filtered on → raw-save on → data generation `start`. NOOP
splits `SELECT_WRIST` into its own separately-confirmed action, because it is the only one that writes
strap state outliving the session **and** its value mapping is unattested.

**Packet layouts.** Both open with the same 17-byte status block (multi-byte fields little-endian):

| Off | Size | Field |
|----:|-----:|-------|
| 0 | 1 | `signalQuality` (0 unknown / 1 low / 2 medium / 3 high) |
| 1 | 1 | `statusFlags` |
| 2–5 | 1 each | `heartKeyStarted`, `heartKeyIsRunning`, `heartKeyIsStoppedAndComplete`, `heartKeyLeadsAreOn` (Bool) |
| 6 | 1 | `heartKeyArrhythmiaCheckResult` (0 notComplete, 1 normalSinusRhythm, 2 signalUnreadable, 3 bradycardia, 4 afibDetected, 5 tachycardia, 6 inconclusive) |
| 7 | 1 | `heartKeyArrhythmiaCheckStatus` (0 notRunning / 1 inProgress / 2 checkComplete) |
| 8 | 1 | `heartKeyProgress` (percentage; the source type also has a timed-out case whose sentinel value is unattested) |
| 9 | 1 | `heartKeyUnreadableReason` |
| 10 | 1 | `heartKeyAverageHR` |
| 11 | 1 | `heartKeyHR` |
| 12 | 2 | `heartKeyHRV` (u16) |
| 14 | 1 | `heartKeyStressScore` |
| 15 | 2 | `numberOfECGSamples` (u16) |

`FilteredLabradorPacket` then carries `numberOfECGSamples` × **i16** `filteredECGDataRaw`, then padding.
`RawLabradorPacket` carries an opaque `rawECGDataRaw` blob, then `numberOfLeadsOffSamples` (u8), then
`leadsOffIRaw` and `leadsOffQRaw` (u16 arrays of that length), then padding. The raw blob's
bytes-per-sample is `count ÷ numberOfECGSamples` — i.e. its **length is not on the wire**, so
`Whoop5Ecg.decodeRaw` takes the width explicitly and `rawBytesPerSampleCandidates` enumerates what a
buffer admits rather than guessing.

**What is not established.** The packet TYPE byte these records arrive under — no capture exists and
§3's table has no Labrador entry — so `Whoop5Ecg` decodes a payload and the app hunts for the type
empirically with a structural triage, logging candidates. The wrist enum's raw values, the timed-out
sentinel, and the ECG sample unit/scale are likewise unattested and are carried raw.

**Gating.** The hardware gate is MG-only and non-bypassable; entitlement and feature-flag gates are
client-side. Whether the strap ALSO refuses the feature is a separate question that only the strap's own
behaviour can answer. `Whoop5EcgProbe` separates the observable cases from the COMMAND_RESPONSE result
code at `frame[12]` (0 FAILURE / 1 SUCCESS / 2 PENDING / 3 UNSUPPORTED): `UNSUPPORTED` means the opcode
is not implemented, `FAILURE` means the firmware knows the opcode and refused to run it, and
all-`SUCCESS` with zero packets arriving means acknowledged and then not honoured. Silence alone is
never read as evidence of anything.

**The verdicts name observations, not mechanisms — and this was got wrong once.** Earlier wording
attributed both the refusal and the silence to a firmware `WhoopDeviceFlag` layer returning
`blockedByDeviceFlags`. **That is a client-side construct.** No command in `whoop_protocol.json`'s
`CommandNumber` table reads or writes such a flag, nothing in this repo implements one, and it is never
transmitted to a strap — so it is not a strap capability gate and a probe that sees only result codes
and packet counts cannot attribute silence to it. The reply carries *that* the firmware refused, never
*why*. #891 then tested the leading named firmware-side candidate — `enable_raw_data_w_ecg`, written to
`'1'` through `SET_DEVICE_CONFIG_VALUE(119)` and read back through `GET_DEVICE_CONFIG_VALUE(121)` — and
still saw zero packets in 30 s with the electrodes held, which falsified it. Five explanations remain
live for that silence: data banked to flash rather than streamed (one toggle is literally `RAW_SAVE`), a
wrong opcode mapping, no actual start verb among three `TOGGLE_*` commands, an entitlement gate, and an
electrode circuit that never closed.

**Both silence-interpreting verdicts are scoped to what the run actually asked for.** A verdict that
reads silence as informative is only reachable when the run exercised the ECG data path, which
`Whoop5Ecg.requestsRealtimeData` decides from the opcode AND the argument sent: `SELECT_WRIST` configures
and starts nothing on either argument, the OFF sequence asks for the silence it gets, and `RAW_SAVE`
names flash rather than a live channel. So a run built only from those reports "no data-generation
command was sent; this run cannot speak to whether ECG is blocked", and a `FAILURE` on one of them
reports as a refusal of that write. Without the scoping a `SELECT_WRIST`-only run rendered as a
device-flag block on real hardware — twice, once through each verdict — which is what #891 records.

## 10. SpO₂ on 5.0 / MG — what the wire does and does not carry

Recorded because "why is there no blood oxygen?" is a recurring question with a protocol answer.

- **No SpO₂ read opcode is known.** Our `CommandNumber` catalogue carries 80 commands and none is an
  oxygen/blood-oxygen read; independent RE reports none either. Note the catalogue is what we have
  mapped, not a proof of the strap's whole command space — §6 is explicitly a *safe subset*, and the
  98-vs-87 battery dispute shows the map is incomplete. Treat it as "nobody has found one", which is
  still enough to say hunting for a missing opcode is the wrong lead.
- **It is computed on-device, during sleep.** Our own decode corroborates the gating: `aux_byte_82` is
  observed nonzero *only* while the band sleep flag reads asleep. Expect values in overnight windows,
  never a continuous 24/7 series.
- **The export is a per-cycle aggregate.** `blood_oxygen_pct` arrives on the physiological-cycles row —
  our own importer reads it beside `recovery_score_pct` and `day_strain`, keyed on
  `cycleStart`/`cycleEnd` (`WhoopExportImporter.swift:272`) — so it is one value per recovery cycle and
  will not equal a plain mean of raw wire samples. Rounding, quality gates and incomplete nights all
  move it.
- **A night with no export value is a real gap**, not a NOOP bug — naps and incomplete nights are
  reported to carry none. (Contributor observation from #807, not something this repo can verify from
  the wire; recorded because "my SpO₂ is missing" reads as a decode failure otherwise.)

- **Whether a firmware FLAG gates it is now answerable from the strap itself.** The read-only
  feature-flag enumeration probe (§6, #761) asks the strap to list the flag names its own firmware
  knows. A 5/MG list with no oxygen-related key is evidence Blood Oxygen is not client-writable at all;
  a list containing one is the answer outright. That is a direct read, not an inference from a byte that
  happens to be zero — the same move the Oura `spo2_status` probe already makes for the ring.

So the research target is finding the banked on-device sample in the historical type-47 record — not
inventing a red/IR ratio or reversing a calibration curve. The v18 `@82` candidate and its split
cross-device evidence are covered in
[`WHOOP5_DEEP_DATA.md`](WHOOP5_DEEP_DATA.md); the full v18 field map lives in
[`BLE_REVERSE_ENGINEERING.md`](BLE_REVERSE_ENGINEERING.md#the-whoop-50-type-47-record-version-18) and
is deliberately **not** duplicated here — one table, one place to keep correct.

## 11. File map

| Path | Responsibility |
|------|----------------|
| `Packages/WhoopProtocol/Sources/WhoopProtocol/Framing.swift` | SOF/length/CRC8/CRC16/CRC32, `verifyFrame`, `Reassembler`, `frameFromPayload` |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/Interpreter.swift` | `parseFrame` (4.0 + 5.0), `ParsedFrame`, field builder |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/DeviceFamily.swift` | UUID strings, header-CRC kind, `CLIENT_HELLO`, puffin aliasing |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/Schema.swift` | JSON schema model + `loadSchema()` |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/PostHooks.swift` | per-type irregular-field decoders |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/HistoricalMeta.swift` | `classifyHistoricalMeta` (START/END/COMPLETE) |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/Resources/whoop_protocol.json` | canonical enums + packet layouts |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5Ecg.swift` | MG ECG ("Labrador") packet decode + command construction (§9.1) |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5EcgProbe.swift` | ECG turn-on report + the run-scoped result-code verdicts (§9.1) |
| `Strand/BLE/BLEManager.swift` | CoreBluetooth transport, bond, connect lifecycle, backfill orchestration |
| `Strand/BLE/Commands.swift` | safe `WhoopCommand` set + outbound frame builder |
| `Strand/BLE/FrameRouter.swift` | decode → `LiveState` (UI) |
| `Strand/BLE/StandardHeartRate.swift` | `0x2A37` HR/R-R parser |
| `Strand/Collect/Backfiller.swift` | historical-offload state machine + safe-trim invariant |

---

*Reverse-engineering credit: `johnmiddleton12/my-whoop` (WHOOP 4.0) and `b-nnett/goose`
(WHOOP 5.0). This is an independent interoperability project for the user's own device and data;
it is not affiliated with WHOOP and is not a medical device.*
