# BLE Reverse Engineering

How NOOP talks to a WHOOP strap directly over Bluetooth Low Energy — no WHOOP cloud and no account.
This document explains how the strap's private GATT protocol was understood, how the
frame format and checksums work, how WHOOP 4.0 ("Harvard") and WHOOP 5.0 ("puffin") differ, capture observations, and how to extend the decoder for new packet types or sensors.
For current wire contracts, start with the [protocol reference](PROTOCOL.md); this page
retains implementation history and measured observations rather than a second schema.

> **Interoperability, not impersonation.** NOOP is a companion app for a strap *you own*. It reads the
> data *your* device already records and stores it locally on *your* machine. Nothing here replicates,
> circumvents, or interoperates with WHOOP's servers.
>
> **Not affiliated with WHOOP. Not a medical device.** "WHOOP" is used only to identify the hardware
> this app interoperates with. The decoded values are raw or locally-computed estimates and must not be
> used for any medical purpose.

---

## Credits

The protocol understanding in this codebase builds directly on two community reverse-engineering
projects, and the Swift code ports their findings:

| Project | Generation | What it contributed |
|---|---|---|
| **`johnmiddleton12/my-whoop`** | WHOOP 4.0 | The `61080001…` GATT service, the `0xAA` CRC8/CRC32 frame envelope, the command numbers, and the type-40/43/47 stream layouts. |
| **`b-nnett/goose`** | WHOOP 5.0 | The `fd4b0001…` GATT service, the CRC16-Modbus header check, the static `CLIENT_HELLO` frame, and the "puffin" packet types. |


---

## Where the code lives

The reverse-engineering logic is split between a platform-pure Swift package and the app's Apple-platform
(macOS + iOS) CoreBluetooth engine:

| File | Role |
|---|---|
| `Packages/WhoopProtocol/Sources/WhoopProtocol/Framing.swift` | CRC8 / CRC32 / CRC16-Modbus, `verifyFrame`, `Reassembler`. |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/DeviceFamily.swift` | WHOOP 4 vs 5 UUIDs, header-CRC kind, `CLIENT_HELLO`, puffin type aliases. |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/Interpreter.swift` | `parseFrame` — envelope → annotated fields + a flat `parsed` dict. |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/PostHooks.swift` | Per-type decoders for irregular layouts (raw IMU/optical, type-47 DSP record, events, metadata). |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/Streams.swift` / `HistoricalStreams.swift` | Parsed frames → durable rows (`HRSample`, `SpO2Sample`, …). |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/Resources/whoop_protocol.json` | The data-driven schema: packet types, enums, field offsets, sensor scales. |
| `Strand/BLE/BLEManager.swift` | CoreBluetooth engine: scan → connect → **bond** → subscribe → reassemble → route. |

| `Strand/BLE/FrameRouter.swift` | Pure decode → live UI state (HR, events, double-tap, wrist on/off). |

The `WhoopProtocol` package never imports CoreBluetooth — it exposes UUIDs as plain strings so the
protocol code runs unchanged in tests and CLI tools. Only `BLEManager` turns those strings into
`CBUUID`s. The `Strand/` tree (including `Strand/BLE/`) compiles into **both** Apple targets — the
macOS app and the `NOOPiOS` iOS target (`project.yml`) — so this CoreBluetooth layer is shared across
macOS and iOS, not macOS-only.

---

## 1. The discovery approach

WHOOP exposes live HR/R-R through the standard Heart Rate profile and uses
vendor-specific GATT services for additional custom records, history and control.
The earlier WHOOP 4 custom-channel flow below uses a bonding step; this does not
make standard HR availability depend on the same custom handshake.

### The GATT layout (WHOOP 4.0)

The custom service and its characteristics are the authoritative anchors of the whole protocol
(`BLEManager.swift`):

```text
Custom service  61080001-8d6d-82b8-614a-1c8cb0f8dcc6
  ├─ 61080002…  CMD write     ← app writes command frames here
  ├─ 61080003…  CMD notify    → command responses
  ├─ 61080004…  EVENT notify  → events (wrist on/off, double-tap, battery, alarms…)
  └─ 61080005…  DATA notify   → fragmented data frames (the big payloads)

Standard Heart Rate  180D / 2A37   → HR + R-R, works UNBONDED (1 Hz)
Standard Battery     180F / 2A19   → battery percent
```

The two standard services (`180D` heart rate, `180F` battery) are a useful sanity check: the standard
`2A37` Heart Rate Measurement characteristic streams HR and R-R intervals at ~1 Hz **without bonding**,
which made it the reliable baseline while the custom channels were being mapped. NOOP still treats
`2A37` as the *reliable* HR/R-R source and lets the custom streams supply everything else (see
`parseStandardHR` in `BLEManager.swift`).

### The earlier confirmed-write workflow


In the earlier client flow, successful `didWriteValueFor` completion triggered
the next custom-channel handshake step. Write completion alone does not
independently prove a persistent bond or successful data delivery.
A subtlety learned the hard way: `didWriteValueFor` re-fires on **every** `.withResponse` write (the
bond write, every historical request, every chunk ack), so the connect handshake is gated behind a
`connectHandshakeDone` flag — re-running `HELLO`/`SET_CLOCK` mid-offload was found to make the strap
stop serving historical data.

### The connect handshake

The earlier WHOOP 4 client runs this connection sequence once
(`didWriteValueFor` → handshake block):


2. `SET_CLOCK` (10) — the earlier default body is 8-byte `[seconds u32 LE][subseconds u32 LE]`.
   A separate older WHOOP 4 observation requires a ninth zero byte. The reported
   wrong-length/clock incident does not establish a universal ACK or history-refusal
   rule; use the [generation-specific clock notes](PROTOCOL_WHOOP4.md#bond-handshake--connect-lifecycle-whoop-40).


---

## 2. The frame format (CRC framing)

Every custom-channel message is a length-prefixed, double-checksummed frame. The format was confirmed
against `my-whoop`'s `WhoopPacket.framed_packet` and is implemented in `Commands.swift`
(`frame(seq:payload:)`) and validated in `Framing.swift` (`verifyFrame`).

### WHOOP 4.0 envelope

```text
┌──────┬───────────┬──────┬───────┬──────┬──────┬───────────┬────────────┐
│ 0xAA │ len u16 LE │ crc8 │ type  │ seq  │ cmd  │ payload…  │ crc32 LE   │
│ [0]  │ [1..3]     │ [3]  │ [4]   │ [5]  │ [6]  │ [7..len]  │ [len..+4]  │
└──────┴───────────┴──────┴───────┴──────┴──────┴───────────┴────────────┘
        \_______ crc8 over these 2 length bytes _______/
                           \________ crc32 (zlib) over [type][seq][cmd][payload] _______/
```

- **SOF** is `0xAA`.
- **`len`** = `(3 + payload.count) + 4` — the inner `[type][seq][cmd][payload]` length plus the 4-byte
  CRC32 trailer. Total frame length on the wire is `len + 4`.
- **`crc8`** (poly `0x07`, table in `Framing.swift`) guards **only the two length bytes** — a cheap
  header integrity check that lets the reassembler trust the declared length.
- **`crc32`** is standard zlib CRC-32 (reflected, poly `0xEDB88320`) over the inner bytes.
- **Size rules.** A 4.0 frame must be **at least 11 bytes** — `type`, `seq`, `cmd`, and the envelope
  including the CRC32 trailer; real zero-data metadata records sit exactly on this bound —
  and must be **exactly `len + 4`** bytes. Equality, not "at least": a frame cut short and a frame
  carrying trailing bytes past its own end are **both** rejected, even when the payload CRC32 over
  the bytes the length field claims happens to check out.

`type` is the packet type (see §5), `cmd` is the command/event number, `seq` is a rolling sequence
byte (and, for historical records, doubles as the **record version** — see §3).

### Reassembly

BLE delivers frames in MTU-sized fragments. The `Reassembler` (`Framing.swift`) accumulates bytes,
finds the `0xAA` SOF, reads the `len` field, and only emits a frame once `len + 4` bytes are present.
`BLEManager.didUpdateValueFor` feeds every custom-channel notification through it before routing.

The reassembler knows the same per-family minimum (11 bytes on 4.0, 13 on 5.0/MG): a `0xAA` whose
declared total is smaller is dropped and the scan resyncs on the next SOF, counted in
`belowMinimumLengthDrops` so the byte run leaves a trace instead of disappearing.

### WHOOP 5.0 envelope

WHOOP 5.0 changed the header and swapped the header checksum for CRC16-Modbus
(`verifyFrameWhoop5` / `parseFrameWhoop5`):

```text
[0]   0xAA SOF
[1]   format byte (0x01)
[2-3] declaredLength u16 LE   (= payload length + 4)
[4-5] header bytes
[6-7] CRC16-Modbus over frame[0..<6]  (poly 0xA001, init 0xFFFF, reflected), u16 LE
[8..] inner record: [type][seq][cmd][data…]
tail  CRC32 (zlib, LE) over the payload, 4 bytes
total = declaredLength + 8
```

The inner record (`[type][seq][cmd][data…]`) starts at **offset 8** instead of offset 4, and the
payload CRC32 is unchanged from 4.0. The header-check choice is selected through `DeviceFamily.headerCRCKind`; command
bodies and record layouts have further generation-specific differences.

NOOP accepts a 5.0/MG frame only at **13 bytes or more** (8 header bytes including the CRC16, at
least the inner type byte, and the 4-byte CRC32 trailer) and exactly `declaredLength + 8` bytes, so
truncation and trailing bytes are rejected. The 13-byte floor is empirical rather than structural:
Goose's `v5Payload` accepts the self-consistent 12-byte, zero-payload envelope. The committed real
fixtures include 20-byte command responses and 24-/32-byte frames, but no 12-byte boundary case;
they establish valid traffic above the floor, not that 12 is invalid. Keeping 13 is a deliberate
compatibility assumption that prevents a typeless frame's trailer from being treated as record data.

---

## 3. WHOOP 4 (Harvard) vs WHOOP 5 (puffin)

`DeviceFamily` (`DeviceFamily.swift`) selects the transport family. The family-aware `verifyFrame(_:family:)` and `parseFrame(_:family:)` overloads branch on
it; the `whoop4` path is byte-for-byte identical to the original no-family functions (back-compat).

| Aspect | WHOOP 4.0 (`whoop4`, "Harvard") | WHOOP 5.0 (`whoop5`, "puffin") |
|---|---|---|
| GATT service | `61080001-8d6d-82b8-614a-1c8cb0f8dcc6` | `fd4b0001-cce1-4033-93ce-002d5875f58a` |
| Characteristics | `…0002`–`…0005` | `fd4b…0002`–`0005` **plus** `…0007` |
| Header check | CRC8 (poly `0x07`) over the 2 length bytes | CRC16-Modbus over `frame[0..<6]` |
| Inner record offset | byte 4 | byte 8 |
| Session start | confirmed-write bond, then `GET_HELLO_HARVARD` | static `CLIENT_HELLO` frame |
| Extra packet types | — | "puffin" types 37/38/53/54/56 |

### The WHOOP 5.0 `CLIENT_HELLO`

WHOOP 5.0 starts a session by writing a fixed 16-byte command frame (transcribed from Goose):

```text
AA 01 08 00 00 01 E6 71 23 01 91 01 36 3E 5C 8D
```

This is a fully-formed type-35 COMMAND frame with a valid CRC16-Modbus header and CRC32 trailer,
exposed as `DeviceFamily.whoop5ClientHello`.

### Bonding and the puffin session


1. Subscribe `fd4b0003/0004/0005/0007`.
2. Write `CLIENT_HELLO` to `fd4b0002`. The strap replies with two `COMMAND_RESPONSE` (GET_HELLO, cmd
   145) frames carrying the device serial and a session token.


### "Puffin" packet types

The client schema includes aliases for several packet types. These are implementation
choices, not evidence that every alias has an equivalent producer on the strap:

| Puffin type | Aliased to |
|---|---|
| 38 `PUFFIN_COMMAND_RESPONSE` | `COMMAND_RESPONSE` (36) |
| 56 `PUFFIN_METADATA` | `METADATA` (49) |

> The capture above verified framing, bonding, hello and selected commands, including a
> CRC-valid historical offload. It did not verify every command or packet alias. The
> [transport reference](PROTOCOL_TRANSPORT.md) distinguishes observed producers from schema names. The 5.0 **biometric field offsets** are now mapped from real captures too — live
> `REALTIME_DATA` (§5) and the historical type-47 record (version 18, §5) both decode HR / R-R /
> gravity, validated against ground truth. Capture with `Tools/linux-capture/whoop_capture.py
> --history-only --history-ack` and decode with `whoop-decode`.

---

## 4. The realtime "R10/R11" raw stream (type 43)


| Payload len | Kind | Contents |
|---|---|---|


### Why NOOP disables it on connect

In the earlier WHOOP 4 sessions described here, the ~2 × 1.9 KB/s stream
consumed substantial BLE airtime during historical offload. Live delivery alone
does not establish how data is retained in flash or whether disconnected recording
continues. WHOOP 5/MG has separate [production, live-delivery and collection
controls](PROTOCOL_CONFIGURATION.md#collection-storage-and-live-transport).

The real control is **not** `STOP_RAW_DATA` (82), which doesn't affect this stream — it is
`SEND_R10_R11_REALTIME` (63). Sending it with `[0x00]` on connect stops the flood (verified on-device:
2.1/s → 0/s, and it **persists across reconnect**). This is part of the handshake:

```swift
send(.sendR10R11Realtime, payload: [0x00])   // stop the type-43 realtime flood (BLE airtime/battery)
```

Because the flood can resume, the backfill idle-watchdog deliberately ignores type-43/40 frames and
only re-arms on genuine offload frames (`BLEManager.isOffloadFrame` → types 47/48/49/50). With the raw
stream off, NOOP's primary metric source becomes the **historical offload** (next section).

### On-demand raw capture

For research, raw IMU can be captured for a bounded window with `captureRawAccel(seconds:)`, which
sends `START_RAW_DATA` (81) followed by `TOGGLE_IMU_MODE` (106), records for the window, then
re-issues `STOP_RAW_DATA` and disables the stream again. This ordering is hardware-verified on a
WHOOP 5/MG: opcode 106 alone returns an acknowledgement but does **not** start the producer. The 5/MG
selector is two bytes (`[0x01, 0x01]` on, `[0x01, 0x00]` off); retaining the older one-byte form here
was why an apparently successful capture contained no realtime IMU packets.

The manually stopped Raw Data Collector uses the same sequence and accepts delayed historical IMU
buffers into the session by strap timestamp, so a later offload can repair a Bluetooth gap. This is
opt-in and bounded; the global research toggle (`enableRawCapture`) defaults **off** and the app is
decoded-only otherwise. Storage/export details and consumer ordering rules are in
[5/MG raw data capture](RAW_DATA_CAPTURE.md).

---

## 5. Packet types and the historical store

Packet types come from the `PacketType` enum in `whoop_protocol.json`:

| Type | Name | Notes |
|---|---|---|
| 35 | `COMMAND` | App → strap. |
| 36 | `COMMAND_RESPONSE` | Strap → app (battery, clock, version, data range). |
| 37/38 | `PUFFIN_COMMAND` / `…_RESPONSE` | WHOOP 5.0. |
| 40 | `REALTIME_DATA` | Live HR + R-R (1 Hz). |
| 43 | `REALTIME_RAW_DATA` | The raw IMU/optical flood (§4). |
| 47 | `HISTORICAL_DATA` | The 14-day biometric store (below). |
| 48 | `EVENT` | Wrist on/off, double-tap, battery, alarms. |
| 49 | `METADATA` | Chunk boundary + trim cursor. |
| 50 | `CONSOLE_LOGS` | Firmware log text. |
| 51–56 | IMU streams / puffin events / puffin metadata | WHOOP 5.0 / extended. |

### The type-47 biometric record

`HISTORICAL_DATA` is the durable, DSP-processed 14-day store and the heart of offline operation. It is
re-offloaded periodically (~every 15 min while connected), mirroring how the official app syncs. Each
record's **version is the `seq` byte** (`frame[5]`); the schema resolves it via `versions`. Version 24
(the WHOOP 4.0 DSP record) is verified against 762 real device records and decodes a full sensor block
(`PostHooks.swift` `historical_data` hook + the v24 layout in `whoop_protocol.json`):

| Offset | Field | Sensor / meaning |
|---|---|---|
| 11 | `unix` (u32) | Real unix seconds — no clock offset needed. |
| 21 | `heart_rate` (u8) | bpm. |
| 22 | `rr_count` (u8) | Number of R-R intervals that follow. |
| 33 / 35 | `ppg_green` / `ppg_red_ir` (u16) | Optical LED ADCs. |
| 40/44/48 | `gravity_x/y/z` (f32) | Accel-derived gravity vector (g). |
| 55 | `skin_contact` (u8) | 0 = off-wrist (capacitive). |
| 56/60/64 | `gravity2_x/y/z` (f32) | Second accel/gravity triplet. |
| 68 / 70 | `spo2_red` / `spo2_ir` (u16) | Raw ADC; no calibrated SpO₂ % is established by these fields. |
| 72 | `skin_temp_raw` (u16) | Raw ADC; physical calibration is separate. |
| 74 / 76 / 78 | `ambient`, `led_drive_1/2` (u16) | Optical config. |
| 80 | `resp_rate_raw` (u16) | Legacy raw respiration-related field; not independently a rate in breaths/min. |
| 82 | `signal_quality` (u16) | DSP quality. |

Versions 5/7/9 are generic HR/R-R-only records with no DSP sensor block; version 12 shares the v24
layout; **version 25** is a different WHOOP 4.0 firmware layout (84-byte, timestamp + gravity/motion,
decoded in v1.95 — see "The WHOOP 4.0 type-47 record (version 25)" below).
`extractHistoricalStreams` (`HistoricalStreams.swift`) turns these into the typed rows
(`HRSample`, `SpO2Sample`, `SkinTempSample`, `RespSample`, `GravitySample`, …). The raw ADCs are kept
as-is (`unit: "raw_adc"`). These names do not independently establish physical
calibration. Current NOOP keeps SpO₂ import-only and treats respiration estimation
and temperature processing separately; see [current data boundaries](WHOOP5_DEEP_DATA.md#spo₂-and-respiration-interpretation-limits).

### Safe offload + trim

The strap streams `HISTORY_START → type-47 records → METADATA (HISTORY_END) → … → HISTORY_COMPLETE`.
Each `METADATA` chunk carries a **`trim_cursor`** (u32 at frame offset 17). NOOP persists the decoded +
raw rows first, then sends `HISTORICAL_DATA_RESULT` (23) as a confirmed write echoing the chunk's
`end_data`. The local `strap_trim` cursor records committed client progress. It does not guarantee
that the strap resumes at exactly that position: unacknowledged records can repeat, and preparation
can continue after a rewind failure. Retain duplicate handling and the full eight-byte ACK token;
see [interruption and recovery](PROTOCOL_TRANSPORT.md#interruption-and-recovery).

### WHOOP 5.0 historical offload

The ack is not just for resumability on WHOOP 5 — **it is what makes the offload progress at all.**
Confirmed in the cited worn WHOOP 5 capture via `Tools/linux-capture/`:

- **Without acking**, the strap re-serves the *same* early chunk forever. Across 16 deterministic
  re-requests the `trim_cursor` stayed frozen at `112193` and **zero** type-47 records arrived — only
  `CONSOLE_LOGS`, small `EVENT`s and `METADATA` (HISTORY_START/END).
- **With the chunk-ack handshake** — parse each `HISTORY_END`'s 8-byte `end_data` (trim u32 + next
  u32) and write it back in a `HISTORICAL_DATA_RESULT` (23) confirmed write — the cursor walks forward
  (`112193 → 112195 → … → 112474`) and the DSP records pour out. One 90 s capture pulled **3193**
  CRC-valid type-47 frames. (`whoop_capture.py --history-only --history-ack`.)

On WHOOP 5 the metadata fields sit at the 4.0 offsets **+4** (the envelope shift): `meta_type` at 10,
`trim_cursor` at 21, `end_data` = `frame[21:29]`.

### The WHOOP 5.0 type-47 record (version 18)

Use the [canonical R18 layout](PROTOCOL_SENSORS.md#r18-biometric-summary) for
field offsets, widths, counters, thermal values and state bits. The record
contains both interpreted fields and raw values without a physiological label.

#### Unresolved physiological interpretations

Frame byte 43 belongs to the R18 float at frame 41; it is not a separate
respiration-rate field. Byte 82 remains an uninterpreted raw value. Neither its
range nor correlation with an export establishes calibrated SpO₂. Use the
[canonical R18 layout](PROTOCOL_SENSORS.md#r18-biometric-summary).

### The WHOOP 5.0 type-47 record (version 26) — high-rate optical PPG

WHOOP 5/MG emits an **88-byte type-47 record with version byte 26**. Use the
[canonical R26 optical-window layout](PROTOCOL_SENSORS.md#r26-compact-optical-window)
for decoding: a u32 base at frame 23 followed by 24 signed adjacent deltas at
frame 27 reconstructs **25 samples**, subject to delta clipping. These are not
24 independent absolute samples, and the record alone does not establish 24 Hz.

The two-byte field at frame 21 is a **burst counter**, not an optical channel
selector. Frame 12 belongs to the record index. Neither field identifies a
wavelength; do not infer a channel sweep or SpO₂ recoverability from it.

Earlier capture analysis found a pulse-related pattern that remained present in
still periods, with amplitude/motion correlation +0.35 in the examined capture.
The published lag-to-bpm and trough-to-milliseconds results depended on the old
24-sample timing assumption and must not be reused as validation of the corrected
decoder. The existing `Tools/linux-capture/analyze_v26_waveform.py` is a historical
analysis tool; check its decoding and timing assumptions before using its output.
No recalculation or new capture validation is claimed here. Calibrated sample
units and physical wavelength remain unresolved.

### The WHOOP 5.0 / MG type-47 records (versions 20 & 21) — bulk multi-channel sensor stream

The examined captures include **2,140-byte R20 optical records** and **1,244-byte
R21 six-axis IMU records**, observed as a pair per second in that capture. A previous
decoder fell back to an unmapped layout and stored no rows (issue #344). Use the
[canonical R20 layout](PROTOCOL_SENSORS.md#r20-optical-blocks) and
[R21 layout](PROTOCOL_SENSORS.md#r21-six-axis-imu) for decoding rather than a second
copy of their offset tables.

Capture observations retained from that investigation:

- Both layouts had a valid trailing payload CRC32, a record index at 11 and time at
  15. The observed markers were 81/80 hex. R20 marker bit 0 can also reflect
  conditional fallback routing, so it is not constant by layout or a validity flag.
- R21 was validated as six-axis IMU over 1,423 real buffers. A stationary fixture
  gave median acceleration magnitude 1.006 g, with all 100 samples in the examined
  gravity shell; raw baselines approximately 1820/720/3630 give 1.007 g at 1/4096.
  The implementation tests include `Whoop5HistoricalV2021Tests.swift` and
  `Whoop5RawImuTests.swift`.
- R20 block counts were `[25,0,0,25,25]` in the examined corpus. **25 is the valid
  count per slot, not a presence flag**: each populated block contains two slots
  with 25 valid i32 samples and capacity for 50 each. Empty slots were zero-filled
  in that capture; they are not measured zero readings.
- The community offsets 47, 247, 1313, 1513, 1735 and 1935 match the six populated
  R20 slots. R20 is optical, but wavelengths, detector geometry and physical units
  remain unresolved. Matching offsets do not resolve those meanings.

These corrections document the wire contract; they do not claim that legacy
`decodeWhoop5HistoricalV2021` implementations or analysis scripts have been updated.
Check their count handling and signed widths before consuming their arrays.

> **Firmware-version caveat.** The 4.0 `v24` layout in `whoop_protocol.json` reflects one firmware
> revision (the `my-whoop` reference device); a given strap may run older or newer firmware with a
> different record version. Always key the decode on the version byte and anchor offsets to a real
> capture from the device in hand — do not assume one generation's documented layout transfers to
> another, even within the same generation.

### The WHOOP 4.0 type-47 record (version 25) — different firmware layout

WHOOP 4.0 firmware is **not** universally v24. A different firmware layout emits an **84-byte type-47
record with version byte 25** (`frame[5] == 25`, issue #30), and as of v1.95 it is decoded by the
`historical_data` post-hook in `PostHooks.swift` (the `v25` layout in `whoop_protocol.json`). Before
v1.95 only live HR worked on these straps; the v25 decode is the WHOOP 4.0 **sleep + recovery unlock**,
because the record carries the **motion vector** the sleep stager gates on. The fields were read off 45
real 84-byte records at their absolute offsets and cross-checked physiologically, never assumed:

| Offset | Field | Sensor / meaning |
|---|---|---|
| 11 | `unix` (u32 LE) | Real unix seconds — no clock offset needed. |
| 23–72 | optical PPG region | Raw AC-coupled optical ADCs. |
| 73 / 75 / 77 | `gravity_x/y/z` (3× i16 LE) | Accel-derived gravity, scaled `/16384` ≈ 1 g; \|g\| ≈ 1.0 on real records. |

No per-second HR field is mapped in this v25 record. WHOOP 4 v24 separately
contains an HR field; v25's mapped contribution here is **timestamp + motion**,  which is exactly what the sleep stager (and hence
recovery) needs. The decoded gravity/motion vector feeds `extractHistoricalStreams` unchanged, the same
path the v24 record uses.

### WHOOP 4 firmware-drift check — this device showed no drift

The v18 surprise prompted the obvious question: does a *different* device on *different* firmware still
emit the documented record? Tested on a real WHOOP 4 (firmware **41.17.6.0**) with the tool's WHOOP 4
offload mode (`whoop_capture.py --model whoop4 --history-only --history-ack`). The 4.0 handshake is the
image of the 5.0 one with the envelope shift removed: `meta_type` at `frame[6]`, `trim_cursor` at
`frame[17]`, `end_data` = `frame[17:25]` (vs 5.0's `[21:29]`), and acks are CRC8-framed COMMANDs
(`build_history_ack_whoop4` / `history_end_data_whoop4`). The cursor walked (`22303 → 22395 …`) exactly
as on 5.0.

**Result on this device: no drift.** All **1704** type-47 frames pulled were **version 24**
(`frame[5] == 24`), CRC-valid, and decoded cleanly through the *existing* documented v24 decoder — HR
equalled `60000 / mean(R-R)` to ~1 bpm and \|gravity\| ≈ 1 g. So the documented v24 layout is confirmed
on a second device and generation. But this is **not** a guarantee that all WHOOP 4.0 firmware is v24:
other WHOOP 4.0 firmware emits the 84-byte **version-25** layout documented just above (issue #30, the
gravity@73/75/77 i16/16384 record, decoded in v1.95). Always key the decode on the version byte — within
the WHOOP 4.0 generation you can meet v5/7/9/12, v24, **or** v25 depending on the strap's firmware.
Real-frame parity test: `Whoop4HistoricalV24HardwareTests.swift` (`HistoricalV24Tests` covers the same
layout synthetically). The offload streamed the same way as 4.0's realtime path, so its HR/HRV/gravity
feed `extractHistoricalStreams` unchanged.

### WHOOP 5.0 COMMAND_RESPONSE (type 36)

WHOOP 5 reuses the 4.0 command **numbers** on the puffin transport (`resp_cmd` at frame[10], the 4.0
frame[6] + 4), but the response **payloads** mostly differ from 4.0 — so each field is mapped from a
real capture (firmware **50.38.1.0**), never ported on faith (`decodeWhoop5CommandResponse`):

| Response | Field | Notes |
|---|---|---|
| `GET_BATTERY_LEVEL` (26) | `battery_pct` | **direct percent** at `pay[2]` — the 4.0 deci-percent ÷10 is gone (47 = 47%, confirmed vs the app) |
| `GET_DATA_RANGE` (34) | `history_oldest` / `history_newest` | the long response carries real-unix timestamps as 4-byte-aligned u32s from `pay[3]`; the window is their min/max |
| `GET_HELLO` (145) | `device_name`, `fw_version` | the user-facing strap name (ASCII at `pay[16]`) and firmware (4 bytes at `pay[93]`, e.g. `50.38.1.0`) |

What does **not** transfer: `REPORT_VERSION_INFO` (7) and `GET_EXTENDED_BATTERY_INFO` (98) return short
stub payloads on this firmware (so the firmware version lives in the `GET_HELLO` block instead), and
`GET_CLOCK` (11) isn't served at all — WHOOP 5 doesn't need it, since realtime (type-40) and historical
(type-47) both carry real unix rather than a device epoch.

> **Privacy.** The `GET_HELLO` response also contains a **session token**, which the decoder never
> reads or exposes — only the device name and firmware version are surfaced. The `device_name`/
> `fw_version` parity tests use a **synthetic** hello frame (fake name, version bytes at their real
> offsets), so no real device name or token ever enters a committed fixture. The version offset sits
> after the variable name+token region, so it is anchored to a 50.38.1.0 capture and guarded on the
> "5.0" generation byte (`pay[93] == 50`) — re-verify it across firmwares.

### WHOOP 5.0 EVENT (type 48)

The event frame is the 4.0 layout shifted +4: `event` (u8/`EventNumber`) at frame[10] and
`event_timestamp` (u32 real unix) at frame[12] are surfaced by the `parseFrameWhoop5` static walk, so
simple events (wrist on/off, double-tap, boot, pairing, BLE up/down, bonded) decode with no extra code.
A u16 **payload length** at frame[18] gives the size of the per-event body that starts at frame[20]
(verified: it predicts the frame size exactly across every event class in the capture).

`decodeWhoop5Event` adds the one per-event payload with on-device ground truth — **BATTERY_LEVEL** (3),
again following the +4 rule (4.0 soc@17 / mv@21 / charge@26 → soc@21 / mv@25 / charge@30). Unlike the
COMMAND_RESPONSE battery above, the EVENT battery keeps 4.0's **deci-percent** (`soc / 10`), confirmed
by a clean monotonic discharge across a real capture (49.9 → 47.7 %, mV ≈ 3.8 V). The same range guards
as the 4.0 `event` post-hook fail closed.

> **Enum-drift guard.** Event names come **only** from the shared `EventNumber` schema. This firmware
> also emits numbers the schema does not name (61, 62, 110, 112, 116, 120, 123); they stay raw
> (`0x7B(123)`) and are never given a name borrowed from another enum — note `CommandNumber` 123 is
> `SELECT_WRIST`, an unrelated meaning — nor invented. Other event payloads
> (`EXTENDED_BATTERY_INFORMATION`, `STRAP_CONDITION_REPORT`, and the serial-bearing 61/62) lack 5.0
> ground truth and are left raw rather than ported from 4.0 on faith. Parity tests use real frames
> verified to carry no device name / serial / token (battery and simple events do not).

---

## 6. Haptic preset discovery (GET_ALL_HAPTICS_PATTERN)

The legacy WHOOP 4 client uses command 79 with preset 2. WHOOP 5/MG uses
command 19 with a 12-byte pattern body; command 79 is unsupported in the current
WHOOP 5 command table. See [haptics and alarms](PROTOCOL_ALARMS.md) for the complete
pattern fields, result handling and busy-state behavior.

### SET_CLOCK — family-specific payloads

Use the [WHOOP 4 clock profile](PROTOCOL_WHOOP4.md) or
[WHOOP 5 clock contract](PROTOCOL_TRANSPORT.md#clock-and-identity-contracts).
A command response alone does not establish a correct RTC value.

## 7. Sensor inventory

Use the [sensor record reference](PROTOCOL_SENSORS.md) for optical, motion and
summary fields, and the [ECG reference](PROTOCOL_ECG.md) for electrical samples.
A record’s numeric layout does not by itself establish physical units or calibration.

## 8. Extending the decoder

The decoder is **data-driven**: most of the protocol lives in
`Resources/whoop_protocol.json`, not in code. To add or refine a packet/field:

1. **New static field on an existing type** — add an entry to that packet's `fields` array in the JSON
   (`off`, `len`, `dtype` of `u8`/`u16`/`u32`/`i16`, `name`, `cat`, optional `enum`, optional `note`).
   `parseFrame` picks it up automatically.
2. **New enum value** — add it under `enums` (`PacketType`, `EventNumber`, `CommandNumber`,
   `MetadataType`). `schema.enumName` and `canonicalTypeName` resolve names from here.
3. **Irregular / variable layout** (variable-count R-R, IMU/optical blocks, per-version records) — add
   a closure to `registerPostHooks()` in `PostHooks.swift` and reference it via the packet's `post`
   key. Hooks get `(FieldBuilder, frame, length, schema)` and write into `fb.parsed`.
4. **New historical record version** — add a key under `HISTORICAL_DATA.versions` (the version is
   `frame[5]`); use `"ref"` to reuse another version's layout, or give it its own `fields`.
5. **New durable row** — define the struct in `Streams.swift`, add it to the `Streams` aggregate, and
   emit it from `extractStreams` / `extractHistoricalStreams`. The GRDB persistence layer lives in
   the `WhoopStore` package.
6. **New command** — add a case to `WhoopCommand` in `Commands.swift` with its on-wire raw value.
   Keep the [safety rule](#safety) below.

Every change should be backed by a golden-frame fixture. The package ships captured frames and expected
output in `Tests/WhoopProtocolTests/Resources/` (`frames.json`, `golden.json`,
`historical_golden.json`, `biometric_streams_golden.json`, …); the parity tests assert the Swift
decoder reproduces them byte-for-byte. Prefer real captures over invented offsets — unmapped regions
are kept raw and labelled rather than guessed.

**Check where a fixture came from before citing it as evidence.** A generated vector and a real
capture are interchangeable for testing a decoder and are *not* interchangeable as evidence about
firmware — once committed they look identical, and a CRC-valid synthetic frame is as convincing as a
captured one.

Provenance is generally declared, but **at the top of the file, not at each fixture**: `StreamsTests`
and `FramingTests` both open by saying their frames are synthetic and that no real capture is
embedded, the Kotlin `FramingTest` says its vectors were generated independently in Python, and
`ExtendedBatteryProbeTests.realFrame` names the device it came off. Read that header before quoting a
frame in an issue.

This is not bookkeeping. #900 was filed against a decode that four in-tree fixtures appeared to
contradict; three of the four declare themselves generated in exactly those headers, and the fourth
shares a byte-identical envelope with one of them — a vector derived from another vector keeps its
header, so a synthetic frame can read as corroboration of the original it was copied from. The issue
went through two rounds of correction before anyone opened the files.

Two habits follow: state provenance for a new fixture, at the fixture when the frame is the kind
likely to be quoted outside its own file; and when a decode looks contradicted, check what the
contradicting bytes actually are before changing the decoder.

### A note on whoop5 offsets

Extend WHOOP 5 decoding through the family-specific path and use the
[canonical record layouts](PROTOCOL_SENSORS.md). Supported layouts already decode
fields; preserve unsupported layouts and unresolved fields raw. Back changes with
fixtures of stated provenance, without treating synthetic vectors as device evidence.

<a name="safety"></a>
### Safety rule

`WhoopCommand` in `Commands.swift` is a **deliberately curated subset**. Destructive or dangerous
commands — firmware load, force-trim, ship-mode, power-cycle, fuel-gauge reset, BLE DFU — are
**excluded by design** from the ordinary command sender. This allowlist is not a guarantee against data loss. The one guarded
exception is `rebootStrap` (a restart request; complete persistence across restart is
not established by this command contract), sent only from a
user-initiated, confirmation-gated action — never automatically (#166). When extending the command
set, keep it reversible and non-destructive.

---

## Appendix: observed but undecoded (#791)

A reporter running an instrumented build on a **WHOOP 4.0 with recent firmware** (Galaxy S24 Ultra) dumped
every non-streaming inbound frame across ~40 minutes of bonded sessions. These observations are recorded
because they exist nowhere else, and because guessing at them would be worse than leaving them raw. Nothing
here is decoded — the point is that the raw evidence survives for whoever next has a strap in this state.

### Two uncatalogued events

Neither number appears in the shared `EventNumber` catalogue (which tops out at 100), so both are named
nowhere on either platform and render as their hex label. Full frames, one occurrence each:

```
event 0x44 (68):  aa 14 00 03 30 fc 44 00 3c ee 63 6a 80 7e 04 00 01 01 ff 00 58 2e c2 81
event 0x66 (102): aa 14 00 03 30 0a 66 00 9e ee 63 6a 60 48 04 00 01 01 00 00 34 0e 63 88
                              │  │  │  └─ event_timestamp (u32 LE)      └─ payload
                              │  │  └─ event @6
                              │  └─ strap seq
                              └─ type 0x30 (48, EVENT)
```

Both are well-formed: `declared_len + 4 == actual`, and the event byte sits at the documented `@6`. Their
8-byte payloads share a middle run and differ at each end:

```
0x44 (68):  80 7e | 04 00 01 01 | ff 00
0x66 (102): 60 48 | 04 00 01 01 | 00 00
```

Suggestive of a shared record shape, but one sample each proves nothing — do not build a decode on it.

### A strap-sourced ERROR event

The same session produced one `ERROR` (event 1) frame. On a strap in poor health — scrambled RTC, most
opcodes silent — this may be the firmware describing its own fault, which would make it the most valuable
payload in the capture:

```
aa 1c 00 ab 30 a2 01 00 69 f0 63 6a 98 54 0c 00 | 01 00 05 02 05 00 00 00 00 00 00 00
                        └─ ev 0x01              └─ 12-byte payload
```

### An opcode-silence census

The most reusable observation. On this firmware the strap answers **five** opcodes and ignores the rest,
consistently across the whole session:

| resp_cmd | | |
|---|---|---|
| `0x03` TOGGLE_REALTIME_HR | 19 | answered |
| `0x16` SEND_HISTORICAL_DATA | 5 | answered |
| `0x17` HISTORICAL_DATA_RESULT | 30 | answered |
| `0x22` GET_DATA_RANGE | 5 | answered |
| `0x62` GET_EXTENDED_BATTERY_INFO | 23 | answered, `result=FAILURE`, all-zero payload |
| `0x07` REPORT_VERSION_INFO | 0 | silent |
| `0x0a` / `0x0b` SET_CLOCK / GET_CLOCK | 0 | silent (both payload forms sent) |
| `0x1a` GET_BATTERY_LEVEL | 0 | silent |
| `0x23` GET_HELLO_HARVARD | 0 | silent |


---

## Summary


> Reminder: not affiliated with WHOOP; not a medical device. All values are raw or locally-estimated
> and are for personal, informational use only.
