# WHOOP 4 profile

Read the [scope and compatibility](PROTOCOL.md#scope-and-compatibility) before applying this page.

## WHOOP 4.0 — service `61080001-…`

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

<a id="21-whoop-40-envelope"></a>

## WHOOP 4.0 envelope

```
┌──────┬───────────────┬───────┬───────────── inner ─────────────┬─────────────┐
│ 0xAA │ length  u16 LE │ crc8  │ type │ seq │ cmd │  payload …    │ crc32 u32 LE│
│ [0]  │ [1..3)         │ [3]   │ [4]  │ [5] │ [6] │ [7 .. len)    │ [len .. +4) │
└──────┴───────────────┴───────┴───────────────────────────────────┴────────────┘
total frame size = length + 4
```

- **`0xAA`** — Start Of Frame.
- **`length`** — `u16` little-endian. Equals `inner.count + 4` (the inner `[type][seq][cmd]
  payload]` plus the 4 envelope bytes). It is the offset at which the CRC32 trailer begins.
- **`crc8`** — CRC8 (table-driven, poly `0x07`) computed over the **two length bytes only**
  (`crc8([frame[1], frame[2]])`).
- **inner record** — `type` (packet type), `seq` (sequence / version byte), `cmd`
  (command number), then the payload.
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

<a id="5-bond-handshake--connect-lifecycle-whoop-40"></a>

## Bond handshake & connect lifecycle (WHOOP 4.0)

This section records NOOP’s WHOOP 4 connection sequence and its observations. The delays and periodic timers are client policy, not required protocol timing. NOOP marks its WHOOP 4 connection as bonded after the confirmed command write is
acknowledged, then runs its connection handshake. This describes client connection
handling; a write acknowledgement is not independent proof of a persistent OS bond.

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
3. `SET_CLOCK` (10) — the client sends both retained variants with the same Unix
   seconds: four seconds bytes followed by four zeros, then four seconds bytes
   followed by five zeros. These are WHOOP 4 compatibility attempts.
4. `GET_CLOCK` (11) — the client tries both an empty body and `00`. Which form
   responds or updates the clock depends on the supported WHOOP 4 firmware.
   Earlier investigations reported unsuitable bodies leaving the clock unchanged,
   including cases with an acknowledgement. Read back the clock: ACK alone does
   not prove it latched, and silent history does not uniquely identify a clock problem.
5. `SEND_R10_R11_REALTIME` (63) with `[0x00]` — stop the ~2/s type-43 raw flood (BLE airtime /
   battery / flash). This is the *real* control for that stream; `STOP_RAW_DATA` (82) does not
   affect it.
6. `GET_DATA_RANGE` (34) — refresh the strap's stored record range for the liveness watchdog.
7. After ~1.5 s (so the link settles), the first historical offload via `requestSync(.connect)`.

A periodic backfill timer (`backfillIntervalSeconds = 900`, i.e. 15 min, matching WHOOP) and a
keep-alive timer (`keepAliveIntervalSeconds = 30`: re-arm realtime, poll battery, watchdog the
link) are then started. The `GET_CLOCK` response is decoded by `ClockCorrelation` to produce a
`ClockRef(device:wall:)` for realtime decoding. Backfill can also proceed with
the client's identity-clock fallback when correlation is unavailable.

> WHOOP 5.0 instead writes the static `CLIENT_HELLO` [frame](PROTOCOL_WHOOP5.md#connection-and-frame-format) to its `…0002` command
> characteristic immediately after discovery.

---

<a id="72-history_end-payload-layout"></a>

## `HISTORY_END` payload layout

The following offset table is the historical WHOOP 4 decoder convention. WHOOP 5/MG has a separate [history contract](PROTOCOL_TRANSPORT.md#historical-synchronization-boundaries-retries-and-range-interpretation); do not reuse these offsets for it.

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

## `GET_HELLO_HARVARD` (35) response — the WHOOP 4.0 serial

A 4.0 exposes no DIS Serial Number String (`0x2A25`), so this response is the only place its stable
serial appears. In the captures on record the response payload (sliced past `SOF+len+crc8` and
`[type,seq,cmd,origin_seq,result]`, i.e. from byte 9 of the frame) is **131 bytes** and carries two
alphanumeric runs:

| payload offset | length | what |
|---|---|---|
| 14 | 9 | **strap serial** — the stable per-device id (`Whoop4HelloSerial`) |
| 24 | 54 | **device key** — a secret; never read it, never log it, never let it become an id |

`Whoop4HelloSerial` reads a FIXED 9-byte window at offset 14 for exactly this reason: a scanning
"longest alnum run" could drift onto the key as payloads vary, and a fixed window cannot.

**Provenance, because it changes how much this should be trusted:** the offsets come from a single
capture, not from documentation. They are corroborated only in the sense that two independent places in
the codebase record the same layout — which is one observation written down twice, not two
observations. Treat a strap that stops adopting as evidence the field moved, rather than assuming the
table is wrong about the shape. This is why the 4.0 adoption path waits for the same value on two
separate hellos before acting on it (`RepeatedSerialGate`), where a 5/MG adopts its spec-defined DIS
serial on first read.

## Commands and records

The [historical sender inventory](PROTOCOL_IMPLEMENTATION.md#6-commandnumber-sending--the-safe-subset) records WHOOP 4 payload conventions. It is not equivalent to the WHOOP 5/MG catalog. WHOOP 4 battery replies use the legacy `u16le / 10` percent convention. Historical layouts are selected by their version in NOOP’s schema; the v24 optical/respiration fields must not be mapped onto WHOOP 5 records by adding four to offsets. See [decoder notes](PROTOCOL_IMPLEMENTATION.md#8-decoded-output-parsedframe) and the [historical measurement discussion](WHOOP5_DEEP_DATA.md#spo₂-and-respiration-interpretation-limits).

## Legacy IMU client-schema layout

NOOP's WHOOP 4 schema selects an IMU variant by declared length 1,917, with 100 signed `i16le`
values per axis. Absolute frame offsets are 89/289/489 for acceleration X/Y/Z
and 692/892/1092 for gyro X/Y/Z. The client applies acceleration scale `1/4096`
and gyro scale `2000/32768`; these are legacy decoder conventions and do not
establish WHOOP 5/MG scaling. See the
[bundled schema](../Packages/WhoopProtocol/Sources/WhoopProtocol/Resources/whoop_protocol.json).
