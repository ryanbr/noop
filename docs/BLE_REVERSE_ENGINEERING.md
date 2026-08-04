# BLE Reverse Engineering

How NOOP talks to a WHOOP strap directly over Bluetooth Low Energy — no WHOOP cloud and no account.
This document explains how the strap's private GATT protocol was understood, how the
frame format and checksums work, how WHOOP 4.0 ("Harvard") and WHOOP 5.0 ("puffin") differ, what each
data stream contains, and how to extend the decoder for new packet types or sensors.

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

Where a function or constant is a direct transcription, the source file says so (e.g.
`crc16Modbus` in `Framing.swift` is noted as *"Ported verbatim from the Goose reverse-engineering"*,
and `DeviceFamily.whoop5ClientHello` is transcribed from `GooseHello.clientHelloFrameHex`). Sensor
scale factors and field offsets were additionally re-verified on a real WHOOP 4.0 strap (see the
on-device verification notes embedded in `Resources/whoop_protocol.json`).

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
| `Strand/BLE/Commands.swift` | The curated, **safe** command set (`WhoopCommand`) and the frame builder. |
| `Strand/BLE/FrameRouter.swift` | Pure decode → live UI state (HR, events, double-tap, wrist on/off). |

The `WhoopProtocol` package never imports CoreBluetooth — it exposes UUIDs as plain strings so the
protocol code runs unchanged in tests and CLI tools. Only `BLEManager` turns those strings into
`CBUUID`s. The `Strand/` tree (including `Strand/BLE/`) compiles into **both** Apple targets — the
macOS app and the `NOOPiOS` iOS target (`project.yml`) — so this CoreBluetooth layer is shared across
macOS and iOS, not macOS-only.

---

## 1. The discovery approach

WHOOP straps do not expose their physiological data through any standard BLE profile. They advertise a
**hidden, vendor-specific GATT service** alongside the two standard ones, and the interesting data only
flows after a quiet bonding step.

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

### The single confirmed-write bond

The custom notify characteristics (`…0003/0004/0005`) stay silent until the link is bonded. The key
discovery is that **one "with-response" (confirmed) write is enough** to trigger iOS/macOS just-works
bonding — there is no PIN, no pairing UI. NOOP performs this with a benign `GET_BATTERY_LEVEL`
(`didDiscoverCharacteristicsFor` in `BLEManager.swift`):

```swift
// THE BONDING TRICK: one confirmed write triggers just-works bonding.
// GET_BATTERY_LEVEL is benign and what the Mac prototype uses.
let bondFrame = WhoopCommand.getBatteryLevel.frame(seq: seq, payload: [0x00])
peripheral.writeValue(Data(bondFrame), for: c, type: .withResponse)
```

When `didWriteValueFor` fires with no error, the link is bonded and the custom channels begin to flow.
A subtlety learned the hard way: `didWriteValueFor` re-fires on **every** `.withResponse` write (the
bond write, every historical request, every chunk ack), so the connect handshake is gated behind a
`connectHandshakeDone` flag — re-running `HELLO`/`SET_CLOCK` mid-offload was found to make the strap
stop serving historical data.

### The connect handshake

Once bonded, NOOP runs a WHOOP-faithful lifecycle exactly once
(`didWriteValueFor` → handshake block):

1. `GET_HELLO_HARVARD` (35) + `GET_ADVERTISING_NAME_HARVARD` (76) — greet the strap.
2. `SET_CLOCK` (10) — set the strap RTC to UTC (8-byte `[seconds u32 LE][subseconds u32 LE]`).
   A *wrong-length* SET_CLOCK is ack'd but not latched, which leaves the RTC lost and the strap
   refuses to serve history — a real bug found and fixed here.
3. `GET_CLOCK` (11) with an **empty** payload — establishes the device↔wall clock correlation.
4. `SEND_R10_R11_REALTIME` (63) with `[0x00]` — **disables** the raw realtime flood (see §4).
5. `GET_DATA_RANGE` (34) — read the strap's stored data window for the liveness watchdog.
6. After a short settle, request the historical offload (`SEND_HISTORICAL_DATA`).

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

`type` is the packet type (see §5), `cmd` is the command/event number, `seq` is a rolling sequence
byte (and, for historical records, doubles as the **record version** — see §3).

### Reassembly

BLE delivers frames in MTU-sized fragments. The `Reassembler` (`Framing.swift`) accumulates bytes,
finds the `0xAA` SOF, reads the `len` field, and only emits a frame once `len + 4` bytes are present.
`BLEManager.didUpdateValueFor` feeds every custom-channel notification through it before routing.

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
payload CRC32 is unchanged from 4.0. The whole 4-vs-5 difference is funnelled through one switch:
`DeviceFamily.headerCRCKind`.

---

## 3. WHOOP 4 (Harvard) vs WHOOP 5 (puffin)

`DeviceFamily` (`DeviceFamily.swift`) is the single enum that captures every hardware-generation
difference. The family-aware `verifyFrame(_:family:)` and `parseFrame(_:family:)` overloads branch on
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

### Bonding and the puffin session (hardware-verified)

Confirmed against a real WHOOP 5 strap using the Linux capture tooling in `Tools/linux-capture/` (a
`bleak`/BlueZ capture feeding the `whoop-decode` CLI). The notes below supersede the earlier
"unverified on MG hardware" caveats for the connect path.

**The `fd4b…` service requires an encrypted link.** Unlike WHOOP 4.0 — whose custom characteristics
are readable after a plain confirmed write — every `fd4b` operation (subscribing to a notify channel,
writing to `fd4b0002`) needs the link to be **bonded** first. Without a bond the operation simply
stalls while the stack waits for an encryption that never arrives. So the 5.0 session has a step the
4.0 does not: establish a BLE bond *before* anything else.

**The bond is "just works"** — no PIN, no passkey, no OOB. On Apple, CoreBluetooth performs it
transparently the first time an encrypted characteristic is touched (no strap screen, nothing to
confirm). On Linux it was reproduced with standard pairing: clear any stale bond, put the strap in
pairing mode, then pair — `Pair()` completes in ~0.2 s and the bond persists, after which connecting
needs no further pairing. WHOOP's own guidance is to pair only through the app and *not* via the OS
Bluetooth menu; for interoperability with a strap **you own**, an OS-level just-works bond is
nonetheless sufficient — no app-side step is required. (The strap holds one central at a time, so the
phone must be disconnected first; the firmware logs a `BLE Bond failure` for a contended attempt.)

**How NOOP's Apple app (macOS/iOS) triggers it (v1.5):** it writes `CLIENT_HELLO` to `fd4b0002` *with response*.
That single confirmed write makes CoreBluetooth bring up the just-works bond *before* the puffin notify
subscriptions are attempted — without it those subscriptions are rejected with *"Authentication is
insufficient"* and the handshake hangs at "Finishing the secure pairing handshake…" forever (issue #17).

**Once bonded, the session mirrors 4.0** on the new transport:

1. Subscribe `fd4b0003/0004/0005/0007`.
2. Write `CLIENT_HELLO` to `fd4b0002`. The strap replies with two `COMMAND_RESPONSE` (GET_HELLO, cmd
   145) frames carrying the device serial and a session token.
3. Drive the strap with **the 4.0 command numbers, re-framed for puffin** (`puffinCommandFrame` in
   `Framing.swift`). Verified on hardware: `SEND_HISTORICAL_DATA` (22) starts a full historical
   offload — trim-cursor acks, `History burst success`, `Historical Dump Complete`, exactly the §5
   4.0 mechanism; `GET_CLOCK` (11), `TOGGLE_REALTIME_HR` (3) and `SEND_R10_R11_REALTIME` (63) are all
   accepted. The puffin command set is therefore the 4.0 set on the 5.0 transport, not a new one.

**`CONSOLE_LOGS` (type 50) are plaintext firmware logs.** The 5.0 emits them freely, and they narrate
the command flow in clear text (`HELLO: Send hello packet`, `Command Send Historical Data`, `History
burst success. Trim: 0x00000010:0001b635 (16:112181)`, `Historical Dump Complete`, `PullStats:
Data: 5, Events: 279, Bytes: 21292`). They are a useful cross-check when mapping the rest of the
protocol.

### "Puffin" packet types

WHOOP 5.0 introduces parallel packet types that carry the same semantics on the new transport. Rather
than decode them separately, `canonicalTypeName` aliases them onto their 4.0 equivalents so they never
fall through to "unknown":

| Puffin type | Aliased to |
|---|---|
| 38 `PUFFIN_COMMAND_RESPONSE` | `COMMAND_RESPONSE` (36) |
| 56 `PUFFIN_METADATA` | `METADATA` (49) |

> WHOOP 5.0 framing, the hello, the puffin aliases, the bond/session handshake and the command set
> are implemented and now hardware-verified (see "Bonding and the puffin session" above): the strap
> bonds, accepts the 4.0 command numbers, and performs a full historical offload, all decoding
> CRC-valid. The 5.0 **biometric field offsets** are now mapped from real captures too — live
> `REALTIME_DATA` (§5) and the historical type-47 record (version 18, §5) both decode HR / R-R /
> gravity, validated against ground truth. Capture with `Tools/linux-capture/whoop_capture.py
> --history-only --history-ack` and decode with `whoop-decode`.

---

## 4. The realtime "R10/R11" raw stream (type 43)

`REALTIME_RAW_DATA` (packet type **43**, internally "R10/R11") is the strap's high-rate raw sensor
stream. On the WHOOP 4.0 firmware it streams **continuously and unprompted** at roughly 2 packets per
second once the link is up — and each packet is large (~1.9 KB). Two variants have been mapped,
distinguished by payload length (`PostHooks.swift` `raw_data` hook + the `variants` table in
`whoop_protocol.json`):

| Payload len | Kind | Contents |
|---|---|---|
| 1917 | `imu` | HR byte + R-R + **6 IMU axes** (accelX/Y/Z, gyroX/Y/Z), 100 signed-`i16` LE samples/axis @ ~100 Hz |
| 1921 | `optical` | A single AC-coupled PPG waveform: ~419 `s24` LE samples @ ~437 Hz, stride 4 |

The IMU variant is well-characterised and on-device-verified:

- **Accel** scale `1/4096` g/LSB (sphere-fit `|g| ≈ 0.99`, residual 0.0%).
- **Gyro** scale `2000/32768 = 0.06104` deg/s/LSB → full-scale ±2000 dps, verified with controlled
  720° rotations.
- Axes live at frame offsets `accelX@89, accelY@289, accelZ@489, gyroX@692, gyroY@892, gyroZ@1092`.
- Roughly 36% of the frame (a header gap and a tail from offset 1292) is **still unmapped** and kept
  raw — an honest gap, not an invented field.

### Why NOOP disables it on connect

The type-43 flood is expensive on two axes the strap can't spare:

- **BLE airtime** — at ~2 × 1.9 KB/s it dominates the connection and starves the historical offload.
- **Strap flash** — keeping the raw stream on blocks dense biometric retention and disconnected
  operation.

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
sends `START_RAW_DATA` (81) + `TOGGLE_IMU_MODE` (106), records for the window, then re-issues
`STOP_RAW_DATA` and disables the stream again. This is opt-in only; the global research toggle
(`enableRawCapture`) defaults **off** and the app is decoded-only otherwise.

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
| 68 / 70 | `spo2_red` / `spo2_ir` (u16) | Raw ADC; SpO₂ % computed locally. |
| 72 | `skin_temp_raw` (u16) | Raw ADC; °C computed locally. |
| 74 / 76 / 78 | `ambient`, `led_drive_1/2` (u16) | Optical config. |
| 80 | `resp_rate_raw` (u16) | Raw; respiratory rate computed locally. |
| 82 | `signal_quality` (u16) | DSP quality. |

Versions 5/7/9 are generic HR/R-R-only records with no DSP sensor block; version 12 shares the v24
layout; **version 25** is a different WHOOP 4.0 firmware layout (84-byte, timestamp + gravity/motion,
decoded in v1.95 — see "The WHOOP 4.0 type-47 record (version 25)" below).
`extractHistoricalStreams` (`HistoricalStreams.swift`) turns these into the typed rows
(`HRSample`, `SpO2Sample`, `SkinTempSample`, `RespSample`, `GravitySample`, …). The raw ADCs are kept
as-is (`unit: "raw_adc"`) — SpO₂ %, skin temperature in °C, and respiratory rate are derived later in
`StrandAnalytics`, on-device, never on a server.

### Safe offload + trim

The strap streams `HISTORY_START → type-47 records → METADATA (HISTORY_END) → … → HISTORY_COMPLETE`.
Each `METADATA` chunk carries a **`trim_cursor`** (u32 at frame offset 17). NOOP persists the decoded +
raw rows first, then sends `HISTORICAL_DATA_RESULT` (23) as a confirmed write echoing the chunk's
`end_data` — only then may the strap forget that chunk. This makes the offload resumable: the durable
`strap_trim` cursor means the next session resumes exactly where the last one stopped.

### Offload throughput is firmware-paced (~10 records/s), not link-bound

The offload runs at a steady **~10 type-47 records per second**, and since the records are 1 Hz that is
only **~10× real-time** (a full day ≈ 40 min, a night ≈ 30 min). This is a property of the strap
firmware, **not** the BLE link. Measured on a real worn WHOOP 4 (`Tools/linux-capture/`), the rate did
not move when either link parameter was forced upward:

- **ATT MTU 23 → 247** — a 104-byte type-47 frame goes from 6 notification packets to 1. No change.
  (BlueZ does not auto-negotiate the MTU; `whoop_sync.py` calls `_acquire_mtu()` to raise it — the
  offload still streams at ~10/s.)
- **Connection interval 50 ms → 7.5 ms** — via BlueZ `conn_min/max_interval` debugfs, the Linux
  equivalent of Android's `requestConnectionPriority(CONNECTION_PRIORITY_HIGH)`. No change.

The rate is rock-steady across the whole drain — the signature of firmware-side pacing of the per-record
`HISTORY` stream, not transmission throughput or the per-chunk ack round-trip. **Implication:** matching
the official app's far faster sync (24 h in 1–3 min) would require a different **bulk / flash-page
transfer command**, not link tuning, and that command is not yet reverse-engineered. For unattended
periodic sync ~10× real-time is fine (and resumable via the trim cursor if interrupted). It also means
adding `requestConnectionPriority`/`requestMtu` to a client to speed *this* offload is not worthwhile.

### WHOOP 5.0 historical offload (hardware-verified)

The ack is not just for resumability on WHOOP 5 — **it is what makes the offload progress at all.**
Confirmed on a real worn WHOOP 5 (latest firmware) via `Tools/linux-capture/`:

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

The historical record's version byte is `frame[9]` on WHOOP 5 (the +4 image of the 4.0 `frame[5]`).
Real WHOOP 5 hardware on the **latest firmware** emits **version 18 (124-byte)** — **not** the 4.0
**v24** layout documented above, and **not** v24 shifted by +4. The repo schema does not contain v18;
this device's firmware revision simply uses a different layout, and a naive "v24 + 4" decodes to
garbage (HR `0`, gravity overflow). The fields below were read off real frames at their **absolute
5.0 offsets** and cross-checked physiologically, never assumed (`decodeWhoop5Historical` in
`Interpreter.swift`, parity test `Whoop5HistoricalTests.swift`):

| Offset | Field | Validation |
|---|---|---|
| 9 | `hist_version` (u8) = 18 | discriminates the layout |
| 11 | `record_index` (u32 LE) | a per-record counter: `+1` every record and **independent of `unix`** (it advances across gaps), so a lifetime record index, not a clock. Span ≈ record count on **two** straps. `@11` is only the low byte — read the full `u32` LE. |
| 15 | `unix` (u32) | monotonic, +1 s |
| 22 | `heart_rate` (u8) | **matched the 2A37-verified live HR exactly at all 96 overlapping timestamps** (mean \|Δ\| 0.00 bpm); note this is v24's `21`+1, **not** +4 |
| 23 | `rr_count` (u8) | matches #valid R-R intervals 100 % (1141/1143) |
| 24 + 2·i | `rr[i]` (u16, ms) | 60000/mean(R-R) ≈ HR for 88 % (rest are HR-averaging) |
| 36 | `hr_quality_flags` (u8) | a **flag byte**, *not* the low half of a fixed-point HR. Over **18,650** real v18 records bit 4 is **never** set (0/18,650 — a genuine 8.8 fraction sets it ~50 % of the time, and it is the only bit never set), **95.02 %** of values land in `0x80`–`0x8F` (uniform would be 6.25 %) across just **40 distinct values**, and sd = **26.5** vs 73.9 for a uniform byte. **Bit 7 = validity**: with it clear (n=748) `rr_count == 0` in **70.32 %** of records vs **19.82 %** with it set, and the `@108/@109` sentinel fires in **69.65 %** vs 1.32 %. Remaining bits unpinned; carried raw. |
| 37 | `heart_rate_alt` (u8, bpm) | a **duplicate** of `heart_rate@22` — equal in **99.575 %** of records (18,523/18,602), differing only by −6…+2, and it tracks HR only while `@36` bit 7 is set (99.74 % exact vs 94.12 % when clear). |
| ~~36–37~~ | ~~`hr_fixed_8_8` (u16 LE) — bpm = `value/256`~~ | **Retired.** The "corr 0.989 with `heart_rate@22`" that justified this name was **circular**: the u16 is literally `hr@22` (at `@37`) plus the `@36` flag byte over 256, so the residual is a flat **+0.504 ± 0.189** — i.e. `@36/256`, not a sub-bpm fraction. On records where `@36` bit 7 is clear it produced absurd readings (a fixture decodes to **227 bpm**). |
| 33 | `cardiac_flags` (u8) | a **beat-detection quality byte**, not cardiac. Over **18,650** v18 records (#845 census — @digitalerdude's public HCI capture plus a second strap): **bit 0 is byte-identical to `@81` bit 0** in 18,650/18,650, across two sessions 15 days apart on different hosts, so it is **not an independent signal**. Bits 1–3 are never set; bits 4–5 are **thermometer-coded** (bit 4 only ever set with bit 5; state `01` never occurs) — a 3-level field. High-nibble popcount is monotone against `P(rr_count == 0)`: **.180 / .207 / .301 / .427 / .612** for popcount 0→4, against a **.219** base rate. The name is POSITIONAL (it sits near the HR fields), not derived — the census says what the byte does, not what it is. |
| 38 | `rr_packed` (u16) | a u16 beside the R-R fields; meaning still **not pinned**. |
| 40 | `cardiac_status` (u8) | a **saturating 0–255 confidence score**, correlated **r = −0.80** with `@113` (#845 census). `whoop-local` names this `signal_quality` in its own code with no stated source or supporting analysis; the census independently supports something quality-shaped, but the name here stays positional until someone pins the scale. |
| 41 | `dynamic_acceleration` (f32, g) | the strap's own **gravity-removed motion magnitude**, one scalar per second sitting immediately before the gravity triplet. Gated to `[0, 8] g` so a wrong offset stores nothing rather than garbage; reads 0.006–0.033 g across the resting oracle frames. Decoded on both platforms but **not persisted and not scored** — `step_motion_counter@57` and `activity_class@63` are what the motion paths actually consume. See the byte-43 note below. |
| 45 / 49 / 53 | `gravity_x/y/z` (f32, g) | \|g\| ≈ 1.0 for 100 % of 500 records; v18 has **one** triplet (not v24's two) |
| 57–58 | `step_motion_counter` (u16 LE @[57:59]) | a **cumulative** counter: climbs while moving, flat when still, low byte wraps at 256. **Steps = Σ wrap-aware diffs** `(cur-prev)&0xFFFF` — *not* the value summed per record (that over-counts massively — the WHOOP 5/MG step over-report). No per-record step count is in the record. |
| 59 | `step_cadence` (u8) | a **cadence-like** byte between the counter and `@63`: never `0`, and lower when moving faster (still > walk > run in the data). Raw — no unit asserted. |
| 63 | `motion_wear_quality` (u8) {0,1,2} | a 3-valued byte; kept **raw** (semantics not pinned from observation). Also read as an **activity class** (0 still / 1 walk / 2 run, #316); `whoop-local` decodes the same offset with the same `<= 2` gate, reached independently (#715). |
| 69 | `temp_aux_1_raw` (i16 LE); °C = value/10 | a **secondary temperature channel**: tracks `skin_temp@73` (corr **0.92** on two straps) with the same on-wrist diurnal curve; deci-°C resolution. |
| 71 | `temp_aux_2_raw` (i16 LE); °C = value/10 | a second **temperature channel**: tracks `skin_temp@73` (corr **0.97**), same diurnal behaviour. |
| 73 | `skin_temp_raw` (u16); °C = raw / 100 | A **digital skin-temperature sensor**, identified **purely from the data**: the on-wrist warming/diurnal curve is a thermal signature nothing else in the record has. **Scale = `/100`** — the only divisor that yields a physiological worn skin temperature (median ≈ **34 °C** across two straps; `/128` reads a non-physiological ≈ 27 °C). Decoded in `decodeWhoop5Historical` (`Interpreter.swift`); flows to the decode-features store as `skin_temp_raw` + derived `skin_temp_c`. |
| 75 | `status_word` (u16 LE) | a packed status word; **NOT a deep-sleep marker** — its low nibble is `0` across ~258k records and it occurs as often awake as asleep (the community "`80`=deep" reading is a misread). Raw. |
| 77 | `status_word_1` (u16 LE) | raw; a near-static sibling of `status_word@75` (low nibble = channel index `1`). |
| 79 | `status_word_2` (u16 LE) | raw; sibling of `@75`/`@77` (low nibble = `2`). |
| 81 | `sleep_state` = `(byte >> 4) & 3` (+ low-nibble sub-flags) | bits 4-5 = the band sleep state: `0` wake / `1` still / `2` asleep / `3` up (deep/REM/light are off-band). Low-nibble sub-flags, observation-framed: **b0-1 `onwrist`** (on-wrist/validity flag) and **b2-3 `wake_quality`** (a 2-bit code observed nonzero **only in wake**); **b6-7 reserved** (`0` across all records). (Hypothesised from captures + a scored night on #132.) |
| 82 | `aux_byte_82` (u8) | the raw carry of the byte decoded as **`spo2_candidate_82`** — a strap-computed SpO₂ % scalar, tri-mode, sleep-only (#103). Instrumentation only, never a shipped metric; see the note below and [`WHOOP5_DEEP_DATA.md`](WHOOP5_DEEP_DATA.md). |
| 83–103 | reserved | observed **constant `0`** on two straps (zero-filled). |
| 104 | (const) | observed **constant `1`** on two straps; carried raw, no metric. |
| 106 / 107 | `optical_baseline_a` / `optical_baseline_b` (u8, u8) | two **independent u8** optical/ADC baseline channels — **not** one u16 LE. A u16 is structurally impossible here: across 18,599 consecutive-second pairs the **high byte changed while the low byte stayed frozen in 3,514 (18.89 %)**, and the corpus holds **zero** low-byte wrap events — a real u16 cannot step its high byte without a carry. The apparent u16 deltas are exactly `256·Δ@107 + Δ@106` (clustering at 0, ±1, ±255, ±256, ±257, ±513). Correlated but independent (corr **+0.73**; they move in **opposite** directions in 5.8 % of pairs where both move). **`0` — not `128` — marks off-wrist**: both bytes read 0 in exactly the 8 records that also carry `HR == 0`, while 128 occurs unremarkably while worn (`@106` in 10 records, `@107` in 103). Magnitudes are device-specific (102–255 / 119–247 on one strap vs 20–66 / 34–81 on another), so **no scale is asserted**. |
| 108 / 109 | `optical_amp_a` / `optical_amp_b` (u8, u8) | a tightly-coupled **pair** (equal in 23.5 % of records, within ±2 in ~80 %). **`128` is a RECORD-level sentinel**, not per-channel: `amp_a == 128` in 757 records and `amp_b == 128` in 757 — the **same** 757, never one without the other. They do **not** rise with heart rate; that reading (~34 at HR 40–49 → ~58 at 80–89) was an **averaging artifact** of counting the 128 sentinel as a number — with sentinels excluded the trend is flat-to-declining (**32.45 → 29.52**). The real monotone trend is with **motion**: ~32.7 while still (`dyn_acc` < 0.02 g) → **37.4** at 0.05–0.2 g. The sentinel is a usable per-second **signal-quality** flag: it fires on 4.02 % of worn seconds and predicts the band's own beat-detection failure (`rr_count == 0`) at **79.44 % vs 19.40 %** — a **4.09×** lift that **survives holding motion constant** (4.11× within `dyn_acc` < 0.009 g), where shuffled and circular-shift nulls all sit at ~1.0×. **Not** SpO₂, blood pressure or a perfusion substrate — signal-quality/AGC is the supported reading and the wavelength identity is unknown. |
| 113 | `unknown_f32_113` (f32 LE) | a **graded quality metric**, no longer unknown: it **floors at −5.2869** when signal quality is good, and across its range takes `P(rr_count == 0)` from **18.30 % to 78.00 %** — a 4.3× lift (#845 census). `0` = unset. Correlated **r = −0.80** with `@40`, so the two report the same condition on different scales. Carried raw; no physiological reading is asserted. |

**Corpus caveat for the `@33` / `@40` / `@108`–`@109` / `@113` quality group.** Those figures come from the #845 census over one contiguous capture: **a single subject, one night, 5 h 10 m, 99.48 % band-scored asleep**, median `dyn_acc` 0.0073 g, with **no ambulation, no workout and no verified off-wrist period**. The cardiac-quality fields are therefore well exercised and the activity-side behaviour is barely exercised at all. Read the monotone relationships as established *for still, asleep wear* — not across wake, exercise or off-wrist, which this corpus cannot speak to. A second corpus is what would promote any of this beyond instrumentation.

The strongest check on the HR offset: where a historical record and a live `REALTIME_DATA` (§5, 2A37
ground-truth-verified) frame share a timestamp, the historical HR equalled the live HR at **96/96**
samples — so HR@22 is anchored to hardware ground truth, not just internally consistent.

A second, independent corroboration comes from **two straps on the same wearer**: a WHOOP 4 and a
WHOOP 5 worn over the same window, both offloaded and decoded, agree at **corr 0.96** across ~28 000
overlapping 1 Hz samples, with a **rest-only mean absolute error of 0.7 bpm** (they diverge only during
exercise, as two independent PPG sensors do). That is a large-sample, cross-generation check on HR@22
on top of the live-vs-historical match above.

#### Byte 43 is not a respiration rate (#520)

A third-party decoder reads a `u8` at payload offset 35 — **frame offset 43** — and labels it a raw
respiration rate. It is not. Frame 43 is the third byte of the little-endian `dynamic_acceleration`
float32 at 41, and the claim is disproved by the fixture frames already in the repo:

| frame | byte 43 as "brpm" | f32@41 as g | \|g\| @45/49/53 |
|---|---|---|---|
| `whoop5_v18_real_worn` | 22 | 0.0092 | 1.0086 |
| `whoop5_v18_real_one_rr` | 47 | 0.0107 | 1.0106 |
| **`whoop5_v18_real_offwrist`** | **195** | 0.0060 | 0.9985 |
| `whoop5_v18_real_ack_capture` | 108 | 0.0144 | 1.0074 |
| `whoop5_v18_real_device2_hr57` | 6 | 0.0328 | 1.0029 |
| `whoop5_v18_real_device2_hr63` | 9 | 0.0084 | 1.0096 |

Two readings of bytes 41–44 are on offer, and they disagree about byte 43. The evidence, in order:

1. **The 4-byte grid is fixed.** The f32s at 45/49/53 give \|g\| = 0.9985…1.0106 on every frame; three
   values landing on unit magnitude together is not something a misaligned read produces.
2. **Read as an f32 on that grid, 41–44 is physically coherent** — 0.006–0.033 g on all six frames,
   the right size for a gravity-removed magnitude, and it stays coherent across worn, off-wrist and
   two different straps. (Being on the grid doesn't by itself make it a float; the coherence is what
   argues it is one.)
3. **Read as a rate, byte 43 is impossible** — 6…195 "brpm", worst on the **off-wrist** frame: 195
   breaths/min from a strap nobody is wearing, with `heart_rate@22` = 0.

A byte belongs to one field. (2) and (3) can't both be right, and (3) is refuted by its own values.

Note the tautology to avoid: byte 43 *is* byte 2 of that float by construction, so reproducing it from
the float's exponent/mantissa bits proves nothing. The evidence is the gravity anchor plus the
off-wrist value. `dynamic_acceleration` is now pinned in `decoder_oracle.json` on both platforms, so a
future offset change here fails a test rather than silently reintroducing a fabricated vital sign.

#### Byte 82: already decoded as `spo2_candidate_82`, blocked on a cross-device contradiction (#103)

**This byte is not unmapped, and the open question is not what it is.** `Interpreter.swift` and
`HistoricalStreams.kt` both decode `@82` as **`spo2_candidate_82`** — a strap-computed SpO₂ % scalar,
tri-mode (70–100 a real %, bit-7 a saturation sentinel, other sub-70 a diagnostic code), populated only
during sleep. It is instrumentation only: a guard test
(`testHistoricalV18OpticalFieldsAreNotNamedPhysiologically`) stops it ever writing `spo2Pct`,
`spo2_red` or `spo2_ir`, and nothing downstream reads it. The full analysis lives in
[`WHOOP5_DEEP_DATA.md`](WHOOP5_DEEP_DATA.md); the `aux_byte_82` row above is the same byte carried raw
alongside it.

**The evidence is split, and that is the whole blocker.** An 8-night independent validation with real
spread reaches **corr +0.99** (~0.4 %/night), tracks both a 92 % desaturation and a 98 % high, and is
offset-specific — only `@82` tracks in a 74–92 scan. But on the original #103 capture device, two
checked nights moved **opposite** to the app value (app 95.50→92.83 vs gated mean 93.62→93.80).
Unresolved: device/firmware variance, or an extraction error on one side. Until that contradiction
resolves, `@82` stays a candidate.

**What clears the bar is multi-device correlation, not one more capture** — the nightly candidate
tracking the app's own SpO₂ across many nights on several straps, *including* the device where the two
nights currently disagree. `Tools/linux-capture/validate_spo2_candidate.py` is the harness for exactly
that. A single asleep frame proves nothing here; the value range has been seen.

**Independent corroboration (#715).** `whoop-local` reads the same byte the same way — sleep-only, and
its decoder applies the identical `70…100` in-band gate, reached separately. That is a second source on
the *identification*. It does not touch the contradiction above, which is about whether the values
track a given wearer's app figures, not about what the field is. Note also that this project's decode is
already attributed as decompile-sourced (`gen5.rs spo2_pct`), reimplemented here as a protocol fact —
so whoop-local is corroboration, not the origin.

WHOOP 5 v18 carries no raw respiration channel, and the decoders already say so: `respRateRawOff = 80`
is set on the **4.0** `HIST_V24` layout only (§ the type-47 biometric record), and `AnalyticsEngine`
notes "WHOOP5 v18 carries no raw resp ADC, so this is an on-device estimate" where it derives the rate
from RSA instead.

Skin temperature @73 **is** decoded (above); PPG / SpO₂ still live further in the 124-byte record but
lack on-device ground truth, so that region is left raw rather than guessed (project rule: real
captures, never invented offsets). The decoded fields feed the existing `extractHistoricalStreams`
path unchanged, so WHOOP 5 historical HR / HRV / gravity / skin-temp land in the datastore like 4.0.

### The WHOOP 5.0 type-47 record (version 26) — high-rate optical PPG

The same WHOOP 5 also emits an **88-byte type-47 record with version byte 26**, distinct from the v18
per-second summary: a high-rate **optical PPG** waveform — **24 little-endian i16 samples at bytes
[27:75]**, one record per second (`unix` u32 LE @15, the same slot v18 uses), i.e. a **24 Hz** trace.
(It is little-endian — the high byte of each sample is `0xFA..0xFF` / `0x00..0x01` — not big-endian.)

It is identified as PPG, not IMU/motion, using the **heart rate as internal ground truth** — no external
reference or app export needed:

- Autocorrelating the concatenated trace peaks at the HR: **lag 14 = 102.9 bpm** vs a v18-measured
  101.7 bpm, with the half-period anti-correlation and 2-beat harmonic of a real pulse.
- Independent trough-detection gives a **563 ms inter-beat interval (≈106 bpm)**, again matching HR.
- The pulse stays HR-locked even in the **stillest** seconds, and its amplitude is not motion-driven
  (`corr(amplitude, |Δgravity|) = +0.35` — mild motion artifact, not the signal) — so it is optical,
  not a ballistocardiographic IMU reading.

**Time-multiplexed optical channels.** Byte `frame[21]` is the channel index: the strap sweeps **26
optical channels (values 1…26)**, one per ~40-frame (~39 s) block, revisiting a given channel only
~20 min later — so a full 1→26 sweep is spread over hours and **no two channels are ever sampled
simultaneously**. Each channel's waveform autocorrelates to the heart rate (lag 14 ≈ 103 bpm) with its
own DC baseline. Which physical LED each index maps to is **not** verifiable from the data, so the raw
index is surfaced (`ppg_channel`, gated to 1…26) with no colour claim. *(An earlier read at `frame[12]`
— the "two channels `0x41`/`0x46`" — was a high-entropy counter byte mistaken for the channel during a
short 2-burst capture; verified against a 22 h overnight corpus, `frame[12]` takes 67 distinct values
while `frame[21]` takes exactly 26. The PPG **sample** decode (LE i16 @[27:75]) is unaffected and
correct.) This 26-way time-multiplex is also why **SpO₂ is not recoverable offline** — it needs
*simultaneous* red+IR, and no two channels are ever co-sampled.

The full v26 byte map (88 bytes; CRC32 @84):

| Bytes | Field | Status |
|---|---|---|
| 8 / 9 | type 47 / version 26 | — |
| 10, 13, 14 | `0x80` / `0x84` / `0x01` | constant header |
| 11 | per-record counter (+1/s) | sequence |
| **12** | **`ppg_channel`** (`0x41` / `0x46`) | **mapped** — optical channel id |
| **15** | **`unix`** u32 LE | **mapped** — real seconds (v18's slot) |
| 19 | `0x000147AE` constant | config param |
| 23–26 | high-entropy (DC / checksum?) | raw — no ground truth |
| **27–74** | **`ppg_waveform`** 24× LE-i16 | **mapped** — 24 Hz PPG, HR-locked |
| 75–83 | footer (random + `0x50`,`0x08` const) | raw — no ground truth |

`decodeWhoop5HistoricalV26` exposes `ppg_waveform` (+ `ppg_sample_count`), `ppg_channel`, and `unix`. The
samples are raw AC-coupled ADC counts — PPG has no absolute unit — so no scale is invented; the
high-entropy `23–26` and the footer are left raw (no internal ground truth). Reproduce the proof with
`Tools/linux-capture/analyze_v26_waveform.py`; parity tests `Whoop5PpgWaveformTests.swift`.

### The WHOOP 5.0 / MG type-47 records (versions 20 & 21) — bulk multi-channel sensor stream

Newer 5/MG firmware also serves two **large** type-47 records alongside v18/v26: **version 20 (2140 B)**
and **version 21 (1244 B)**, emitted as a **pair per second**. Older builds had no map for them, fell back
to "unmapped layout", and stored nothing — so the offload completed but no data landed (issue #344). Both
reuse the v18 record header, confirmed across the captured frames:

| Offset | Field | Notes |
|---|---|---|
| 9 | layout version | 20 (len 2140) / 21 (len 1244) |
| 10 | `layout_marker` (u8) | `0x81` (v20) / `0x80` (v21), constant per version |
| 11 | `record_index` (u32 LE) | monotonic +1/record — the same lifetime counter as v18 |
| 15 | `unix` (u32 LE) | real seconds, +1 s/record (v18's slot) |

Integrity is the standard trailing **CRC32** over the payload (`frame[8 : len-4]`) — it validates on every
captured frame of both versions, which is what lets the body offsets be trusted.

The bodies are blocks of fixed-length **sample channels**:

- **v21 (1244 B):** a `(100, 100, 3)` descriptor near `@22`, then **six 100-sample i16 channels** in two
  blocks — **accelerometer at `@28` / `@228` / `@428`** and **gyroscope at `@640` / `@840` / `@1040`**
  (200 B apart; the second block's count sits at `@630` = 100). This is **6-axis IMU, not optical**: on a
  stationary strap the three accel channels sphere-fit to a **~1 g gravity shell** (median |a| = 1.006 g,
  100/100 samples in-shell on the real fixture) — a gravity vector, which a PPG channel cannot produce.
  (The DC "baselines" ≈1820 / 720 / 3630 a stationary capture shows are exactly that gravity vector:
  √(1820²+720²+3630²)/4096 = 1.007 g.) Validated as 6-axis IMU by `Whoop5RawImu` over 1423 real buffers.
- **v20 (2140 B):** **five channel blocks**, each preceded by a **presence byte** (`0x19` = active,
  `0x00` = empty/zero-filled). An active block holds **two 50-sample i32 channels**. Presence bytes at
  `@0x1a / 0x1c0 / 0x366 / 0x50c / 0x6b2`; the ten channel slots start at
  `@0x2f / 0xf7 / 0x1d5 / 0x29d / 0x37b / 0x443 / 0x521 / 0x5e9 / 0x6c7 / 0x78f`. i32 LE is the correct
  width (only that alignment yields smooth waveforms; an empty block's 200-byte slots are all-zero across
  every frame, matching its `0x00` presence byte). **v20 sensor identity is OPEN**: there is no labelled
  or moving v20 capture in the tree, and the earlier "same sensor set as v21" claim was the only basis for
  calling it optical — now that v21 is inertial, that inference no longer supports an optical reading. Do
  not treat v20 as an SpO₂/BP optical substrate pending a labelled **moving** capture.

  **Independently corroborated (#715).** `whoop-local` lists six 20-bit v20 channel offsets, derived
  separately from this tree: frame `47, 247, 1313, 1513, 1735, 1935`. Those are exactly the six slots of
  our **non-empty** blocks (0, 3 and 4 — the corpus shows block counts are always `[25, 0, 0, 25, 25]`),
  out of the ten listed above. Two unrelated methods agreeing on which six slots carry data, and where,
  is the strongest confirmation this layout has. Note what it does **not** settle: both projects agree on
  the *structure*, and neither has a labelled capture, so the sensor-identity question above is untouched
  — agreement about where the bytes are is not evidence about what produced them.

`decodeWhoop5HistoricalV2021` exposes `layout_marker`, `record_index`, `unix`, and the channels as **raw
i16 sample arrays with no scale applied at this layer**. For **v21** the channels are named `accel_x/y/z`
and `gyro_x/y/z` per the gravity-shell evidence above (`Whoop5RawImu.decode` applies the physical scales —
1/4096 g/LSB accel, 2000/32768 (°/s)/LSB gyro). For **v20** the channels stay neutrally named because its
sensor identity is still open (needs a labelled/moving capture). Tests: `Whoop5HistoricalV2021Tests.swift`
(incl. a real-frame gravity-shell assertion) and `Whoop5RawImuTests.swift`.

> The v18 per-second record's own optical region (bytes [57:120]) carries **no simple summary of this
> PPG** (no field tracks its DC or AC amplitude), and its SpO₂ / skin-temp channels have no internal
> proxy — HR, R-R, gravity and PPG morphology don't determine blood-oxygen or temperature. Those remain
> a raw region; positively mapping them needs an external reference (a worn pulse-oximeter / thermometer,
> or the official app's readout for matching timestamps), so they are intentionally left undecoded.

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

Note there is **no per-second HR field** in this record: WHOOP 4.0 HR is PPG-derived, not stored — so
the v25 win is the recovered **timestamp + motion**, which is exactly what the sleep stager (and hence
recovery) needs. The decoded gravity/motion vector feeds `extractHistoricalStreams` unchanged, the same
path the v24 record uses.

### WHOOP 4 firmware-drift check — this device showed no drift (hardware-verified)

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

The strap has a built-in table of haptic waveforms. `GET_ALL_HAPTICS_PATTERN` (command **80**) reports
the device's preset patterns — **7 presets on the WHOOP 4.0 (Harvard)**, indexed `0–6`. That count is
a claim about the STRAP's own table, not about NOOP: it would be read with `GET_ALL_HAPTICS_PATTERN`
(80), and neither platform has ever sent that command, so we have never enumerated it (#926). What the
app exposes is four `BuzzPattern` choices, all sharing patternId 2. They are fired
with `RUN_HAPTICS_PATTERN` (command **79**):

```text
RUN_HAPTICS_PATTERN payload = [patternId, numLoops, 0, 0, 0]   // 5 bytes
```

NOOP uses **`patternId = 2`** — the characteristic graduated "alarm" buzz, observed as the one the
official app fires, for interoperability (`buzzStrapOnce`, `AppModel.buzz`). `numLoops` sets the
length; `STOP_HAPTICS` (122) cancels an in-progress pattern. All notification patterns in NOOP map to
this confirmed preset and vary only the repeat count, so behaviour is predictable on real hardware.

Haptics tie into the firmware **alarm**: `SET_ALARM_TIME` (66) arms a UTC alarm that buzzes even if
NOOP is closed (event `STRAP_DRIVEN_ALARM_EXECUTED`=57); always `SET_CLOCK` first so the RTC is
UTC-correct.

### WHOOP 5 / MG haptic — the "maverick" opcode (hardware-verified)

The WHOOP 5 / MG does **not** honour `RUN_HAPTICS_PATTERN`=79 — a real-MG capture showed the strap
rejecting 79 with `COMMAND_RESPONSE result=0x03`. The 5.0 firmware instead drives haptics with the
**maverick** opcode **`0x13`** (`RUN_HAPTIC_PATTERN_MAVERICK`=19) — the exact command the official app
sends, matched byte-for-byte (#48), and shipped in `BLEManager.send()`:

```text
puffin cmd 0x13, body = [0x01, effects…, loopControl u16 LE, overallLoop]
NOOP's "notify" preset → effects 47, 152  →  body = [01 2F 98 00 00 00 00 00 00 00 00 00]  (12 bytes)
```

The 12-byte body makes the inner record 15 bytes, so the puffin framing **pads it to a 4-byte
boundary** (`pad4`, → 16) before the declared length and CRC32 — without the pad the strap rejects the
frame. The strap acknowledges acceptance with `COMMAND_RESPONSE` (type 36) echoing
`RUN_HAPTIC_PATTERN_MAVERICK(19)`.

**Verified on real hardware (2026-06-12):** a bonded WHOOP 5 buzzed on this exact frame and returned a
CRC-valid COMMAND_RESPONSE for every send. Frame builders live in `Tools/linux-capture/whoop_frame.py`
(`build_whoop5_buzz` / `build_whoop4_buzz`, unit-tested against the captured frame) and drive the
`whoop_buzz.py` find-my-strap tool — see the linux-capture README.

### SET_CLOCK — the payload length is firmware-specific (hardware-verified)

`SET_CLOCK` (command **10**) sets the strap RTC. A strap left offline (no app) for months loses its
clock: its RTC drifts/resets, and every frame it then emits — realtime *and* newly-written historical
records — carries a bogus timestamp (we saw a real WHOOP 4 dated **1971**, its RTC counting up from
~zero). The fix is to send the current unix time, exactly as the app does on each connect (it only
re-sends when drift exceeds a threshold — `ClockPolicy` — to avoid gratuitous resets).

The payload is `u32 unix-seconds LE` followed by zero subsecond bytes, but **the length is
firmware-specific and load-bearing** — a wrong length is `COMMAND_RESPONSE`-ack'd but **not latched**:

| Firmware | Body | Result |
|---|---|---|
| newer (app's default) | 8-byte `[u32 + 4 zero]` | latches on newer straps; on WHOOP 4 `41.17.6.0` → **no response at all** |
| older WHOOP 4 `41.17.6.0` | **9-byte** `[u32 + 5 zero]` | **latches** — COMMAND_RESPONSE(cmd 10) + the event clock jumps to the set time |

**Verified on real hardware (2026-06-12, WHOOP 4C fw 41.17.6.0):** the 8-byte form drew no response;
the 9-byte form latched and the strap's event RTC jumped from 1971 to the correct 2026 time, ticking
+1/sec. So `build_whoop4_set_clock` sends the 9-byte form; newer firmware may want 8.

Read-back to confirm a latch: the strap's RTC is the u32 LE timestamp in any EVENT or REALTIME frame —
**but the offset differs by type**: WHOOP 4.0 REALTIME(40) `@6`, EVENT(48) `@8`; WHOOP 5.0 (puffin, +4
rule) REALTIME(40) `@10`, EVENT(48) `@12` (`frame_rtc` in `whoop_frame.py`). Stored historical records
keep the timestamp they were written with, so offloading old history does **not** require fixing the
clock first — only future recordings do. Tooling: `whoop_setclock.py` (read + conditional set) and the
read-only `whoop_probe.py` — see the linux-capture README.

---

## 7. Sensor inventory

Combining the type-47 DSP record (§5), the type-43 raw streams (§4), and the `EventNumber` enum, the
WHOOP 4.0 strap exposes the following sensors and actuators. NOOP only consumes what the device already
measures:

| Sensor / actuator | How it surfaces in the protocol |
|---|---|
| **PPG optical** (green + red/IR LEDs, ambient) | type-47 `ppg_green` / `ppg_red_ir` / `ambient` / `led_drive_1/2`; type-43 optical variant (single AC-coupled green waveform @ ~437 Hz). Drives HR, SpO₂, respiratory rate. |
| **3-axis accelerometer** | type-47 `gravity_x/y/z` (f32, g); type-43 IMU `accelX/Y/Z` (i16 @ ~100 Hz, `1/4096` g/LSB). |
| **Gyroscope / IMU** | type-43 IMU `gyroX/Y/Z` (i16, `0.06104` deg/s/LSB, ±2000 dps). |
| **Skin temperature** | type-47 `skin_temp_raw` (u16 ADC); event `TEMPERATURE_LEVEL`. |
| **Capacitive double-tap** | event `DOUBLE_TAP` (14) → `FrameRouter` fires `onDoubleTap`. |
| **Wrist detection** | events `WRIST_ON` (9) / `WRIST_OFF` (10); type-47 `skin_contact` (0 = off-wrist). |
| **Haptic motor** | `RUN_HAPTICS_PATTERN` / `STOP_HAPTICS`; events `HAPTICS_FIRED` (60), `HAPTICS_TERMINATED` (100). |
| **Battery / charge** | standard `2A19`; type-48 `BATTERY_LEVEL` (SoC/mV/charging ~every 8 min); events `CHARGING_ON/OFF`. |

**Sensors the strap does NOT have** (and that NOOP therefore never fabricates): **no microphone, no
speaker, no GPS, no display.** All feedback to the wearer is via the single haptic motor; all
"location" or "audio" context, if any, comes from imported data, never the strap.

The live physical inputs are wired through `FrameRouter.handle(frame:)`: `DOUBLE_TAP` and
`WRIST_ON`/`WRIST_OFF` events update `LiveState` and can trigger user-configured Mac actions.

---

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

If you map the WHOOP 5.0 biometric fields, do it in `parseFrameWhoop5` (inner record at offset 8) and
back it with real 5.0 captures. Until then the 5.0 path intentionally leaves the inner record as an
unparsed region — describing the frame faithfully without inventing structure.

<a name="safety"></a>
### Safety rule

`WhoopCommand` in `Commands.swift` is a **deliberately curated subset**. Destructive or dangerous
commands — firmware load, force-trim, ship-mode, power-cycle, fuel-gauge reset, BLE DFU — are
**excluded by design** so the in-app command sender can never brick or wipe a device. The one guarded
exception is `rebootStrap` (a plain, non-destructive restart that keeps stored data), sent only from a
user-initiated, confirmation-gated action — never automatically (#166). When extending the command
set, keep it reversible and non-destructive.

---

## Appendix: evaluated and rejected — the LINK_VALID handshake (#715)

Recorded so it is not re-proposed. `whoop-local` ([a9eelsh](https://github.com/a9eelsh/whoop-local))
implements a handshake in which the strap sends a `LINK_VALID` (command 1) and the client must answer
with a `COMMAND_RESPONSE` (36) carrying `[originSeq, SUCCESS, "There it is."]`, stating that otherwise
"the strap treats the link as invalid and withholds data."

**As stated, that is contradicted by what NOOP does in the field.** Neither platform has ever had a
`LINK_VALID` handler — not one reference in `Strand/BLE/` or `com.noop.ble` — and NOOP nonetheless
completes historical offloads, live HR and sleep sync on WHOOP 5/MG for real users. If the strap
withheld data from a client that never answers, *every* 5/MG user would get nothing; instead the
5/MG reports we receive are about intermittent disconnects (#802) and state restoration (#613), not
about a strap that never sends anything.

The decode corpora point the same way — **~258k v18 records**, an **18,602-record** v18 span from a
third strap's overnight stream, a **29,203-record** v20 corpus — though note those are cited here as
corroboration, not proof: this project also has HCI-snoop tooling (`hci_extract.py`, #103), and a
corpus extracted from a snoop of the *official* app would have been produced by a client that DID
answer. The field-behaviour argument above does not depend on how any corpus was captured.

What may still be true is narrower: their handshake sits alongside `TOGGLE_IMU_MODE` (106) and
`TOGGLE_OPTICAL_MODE` (108), which arm the realtime R20/R21 raw streams — so if the exchange gates
anything, it plausibly gates *those streams* rather than the offload.

Our exposure to that is limited but not zero, and worth stating precisely. NOOP takes live HR from the
standard `0x2A37` profile and disables the R10/R11 flood on connect (§4), and it never sends
`TOGGLE_OPTICAL_MODE` (108) at all. But `captureRawAccel` **does** send `START_RAW_DATA` (81) +
`TOGGLE_IMU_MODE` (106) — on demand, for a bounded window, never continuously. So the one place this
could bite is an on-demand raw-accel capture on a 5/MG. Whether that path yields IMU frames today is
the observation that would settle the narrow claim, and it is not recorded anywhere here.

**Two questions are genuinely open**, and a capture answers both without implementing anything:

1. Does a WHOOP 5/MG ever send us a type-35 `COMMAND` with `cmd == 1`? The schema knows both
   (`PacketType 35 = COMMAND`, `CommandNumber 1 = LINK_VALID`) but nothing routes it, so today it would
   arrive and be dropped silently.
2. If it does, does ignoring it affect *link stability* — as distinct from data flow? That is a
   different claim from the one above and is not disproved by the corpus. It would be a candidate
   contributor to the intermittent-disconnect reports (#802, #613), though those look unlike a link the
   strap has declared invalid.

**Provenance caveat, and it is the deciding one.** The whole path is decompile-sourced
(`com/whoop/service/rearchitect/c.java`, `zi0/*`, `bj0/x.java`, `bj0/f.java`) and its payload is a
**literal string lifted from the app**. This project reimplements decompile-sourced *facts* with
attribution when they are treated as unvalidated candidates — `spo2_candidate_82` is the precedent —
but an offset is a fact and a magic string is expression. Even if question 1 turns out yes, the reply
should be derived from our own capture of what the strap accepts, not copied.

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

Consequences worth carrying forward:

- **Battery is unreachable on this firmware.** Command 26 silent, command 98 answering `FAILURE`, no
  `BATTERY_LEVEL(3)` events in 40 minutes, no `EXTENDED_BATTERY_INFORMATION(63)` events either, and the
  standard `0x2A19` characteristic a constant-100 stub. All four sources are dead, so there is no
  client-side path to the percent — not a decode bug to find.
- **`0x62` answers while `0x1a` does not**, which is odd enough to be a lead: the extended-battery opcode is
  reachable but fails, so it may want a sub-command or page selector in its request payload rather than the
  `[0x00]` the probe sends.
- The strap also had stretches — one 25-minute bonded session — where it answered *nothing* despite working
  realtime and backfill streams, then became chatty later. State-dependent, cause unknown.

---

## Summary

NOOP interoperates with a WHOOP strap you own by: scanning for its hidden custom GATT service,
triggering just-works bonding with a single confirmed `GET_BATTERY_LEVEL` write, reassembling the
`0xAA` CRC-framed messages, and decoding them with a data-driven schema. The expensive type-43 raw
flood is switched off on connect (`SEND_R10_R11_REALTIME [0x00]`), leaving the periodically-offloaded
type-47 14-day biometric store as the primary on-device data source. WHOOP 4.0 and 5.0 differ only in
their GATT UUIDs, header checksum (CRC8 vs CRC16-Modbus), inner-record offset, and session start — all
funnelled through `DeviceFamily`. The work stands on the shoulders of `johnmiddleton12/my-whoop`
(4.0) and `b-nnett/goose` (5.0), with sensor scales and offsets re-verified on real hardware.

> Reminder: not affiliated with WHOOP; not a medical device. All values are raw or locally-estimated
> and are for personal, informational use only.
