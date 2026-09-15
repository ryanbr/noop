# NOOP implementation and historical observations

This page records client behavior and earlier observations; it does not override the topic references. Read the [scope and compatibility](PROTOCOL.md#scope-and-compatibility) before applying this page.

## Reading this page

These notes preserve application choices and previous observations. For wire
contracts use the [topic index](PROTOCOL.md#reading-guide); the legacy tables here
must not override it.

- [Client command inventory](#6-commandnumber-sending--the-safe-subset)
- [Probes and their limits](#whoop-40-reboot-probe-235)
- [Offload state machine](#73-session-state-machine)
- [Decoded output](#8-decoded-output-parsedframe)
- [SpO₂ observation and import boundaries](#10-spo₂-on-50--mg--what-the-wire-does-and-does-not-carry)
- [Implementation file map](#11-file-map)


## Diagnostic-only WHOOP service families

The official app also models additional WHOOP service families with the same `0001` service plus
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

## PacketType (offset `[4]`, or `[8]` on 5.0)

This is NOOP’s schema vocabulary, not a guarantee that every named packet is produced by either generation. Current WHOOP 5/MG layouts are in [sensor records](PROTOCOL_SENSORS.md).

Source: `enums.PacketType` in `whoop_protocol.json`; resolved by `Schema.typeName(_:)`.

| Value | Name | Notes |
|------:|------|-------|
| 35 | `COMMAND` | outbound command (app → strap) |
| 36 | `COMMAND_RESPONSE` | reply to a command |
| 37 | `PUFFIN_COMMAND` | WHOOP 5.0 command |
| 38 | `PUFFIN_COMMAND_RESPONSE` | WHOOP 5.0; aliased → `COMMAND_RESPONSE` |
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

`isOffloadFrame(_:)` (in `BLEManager`) treats **47/48/49/50** as offload traffic; the live
`REALTIME_DATA`(40)/`REALTIME_RAW_DATA`(43) flood is excluded so it cannot keep the backfill
idle-watchdog alive.

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

**Historical NOOP sender inventory.** The table below records client payload conventions, primarily WHOOP 4. It is not the WHOOP 5/MG command contract or a recommendation to send every listed operation. Use the [command reference](PROTOCOL_COMMANDS.md) for current meanings and the [alarm reference](PROTOCOL_ALARMS.md) for revisioned alarms.

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
| 35 | `GET_HELLO_HARVARD` | `[0x00]` | identity/version hello; the response carries the 4.0 strap serial — see below |
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

**5/MG raw-IMU sequence (hardware-verified):** command 106 accepting a write does not mean that the
producer started. A bounded capture first sends `START_RAW_DATA` (81) `[0x01]`, then command 106 with
the two-byte selector `[0x01, 0x01]`. Stop uses `STOP_RAW_DATA` (82) `[0x01]`, then command 106
`[0x01, 0x00]`. The one-byte payload in the table remains the WHOOP 4 form. See
[5/MG raw data capture](RAW_DATA_CAPTURE.md) for storage, history repair, and export semantics.

**Payload builders** in `WhoopCommand`:

- `setAlarmPayload(epochSec:)` → `[0x01] + epoch u32 LE + [0x00, 0x00]` (7 bytes).
- `BLEManager.setClockPayload(now:)` → `[secs u32 LE][0,0,0,0]` (8 bytes; subseconds in
  1/32768 s, zero is fine).

> **Note on `ENTER_HIGH_FREQ_SYNC` (96):** current builds do **not** enter high-freq sync; they
> send `EXIT_HIGH_FREQ_SYNC` (97) defensively on connect to release a strap a previous app may
> have parked there. Plain `SEND_HISTORICAL_DATA` returns the type-47 store without it.

## Additional 5-class command numbers

Command bytes present on a 5-class (MAVERICK) strap beyond the safe subset above. NOOP does not
send these; they are recorded for completeness.

| Code | Command | Purpose |
|-----:|---------|---------|
| 48 (0x30) | `SEND_EVENT_PACKETS` | event-delivery toggle; past/live selection unresolved |
| 61 (0x3D) | `SET_AFE_PARAMETERS` | set optical AFE parameters |
| 62 (0x3E) | `GET_AFE_PARAMETERS` | read optical AFE parameters |

On MAVERICK the clock commands also answer in the high opcode space — `SET_CLOCK` at 146 (0x92)
and `GET_CLOCK` at 147 (0x93), alongside `GET_HELLO` at 145 (0x91) — distinct from the 4.0
numbers (10 / 11) above.

The ECG family is resolved as wrist selection (123), processing start/stop
(124), raw saving (125), raw live delivery (126), filtered saving (127), and filtered live
delivery (139). Noncontiguous IDs are not evidence of a mistaken mapping. Requests and
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
[ECG controls](PROTOCOL.md#91-ecg-labrador-on-the-mg) — never automatically, never on a plain 5.0 or a 4.0, and only
behind the Experimental opt-in plus a positively-identified MG. Existing probe implementation and
older observations must be distinguished from the expanded contract.

live IMU control is 106 and BLE UART control is 103; they are distinct
operations. See [collection controls](PROTOCOL_CONFIGURATION.md#collection-storage-and-live-transport).

The configuration probing notes below describe earlier client behavior and unanswered
runs. They do not override the reference baseline [named configuration contract](PROTOCOL_CONFIGURATION.md):
read commands are defined, SET consumes a 65-byte body, lookup eligibility is versioned,
and tri-state polarity is per key. Historical enumeration and timeout reports are not
current absence-of-support claims.

## Destructive commands — *do not send*

These exist on the wire but are **deliberately excluded** from `WhoopCommand`. They can wipe
data, brick, or power-cycle the strap. NOOP must never send them.

| Code | Command | Hazard |
|-----:|---------|--------|
| 25 | `FORCE_TRIM` | invasive history cursor/reclamation operation; unoffloaded data may become unavailable |
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

**Two guarded restart paths in NOOP.** These client paths are not proof of retained state or completed restart for every device. Neither is ever sent automatically or on any connect/offload path.

- **`REBOOT_STRAP` (29)** — the normal Restart. NOOP already triggers a reboot today via
  `SET_ADVERTISING_NAME_HARVARD` (rename applies on reboot). In `WhoopCommand` as `rebootStrap`, sent only
  from the user-initiated, confirmation-gated "Restart strap" action (`BLEManager.rebootStrap()` /
  `WhoopBleClient.rebootStrap()`) (#166).
- **`POWER_CYCLE_STRAP` (32)** — a harder restart, in the enum as `powerCycleStrap` **only** as a candidate
  for the WHOOP 4.0 reboot probe (below). Sent only from `rebootProbe(.powerCycle32Empty)`, itself gated
  behind Test Centre → Connection + a confirmation, and 4.0-only. Never on a default install.

Everything else in this table stays out of the enum entirely.

## WHOOP 4.0 reboot probe (#235)

 A real 4.0 silently ignores the production `REBOOT_STRAP` frame (see
below) and the correct 4.0 reboot frame is unknown. The probe (Test Centre → Connection, 4.0 only) sends
one candidate at a time — `REBOOT_STRAP(29)` empty, `POWER_CYCLE_STRAP(32)` empty, or
`REBOOT_STRAP(29)` with `[0x01]` — reusing the reboot watchdog so the strap log shows which one drops the
link (worked) vs is ignored. The definitive fix is still an HCI capture of the official app rebooting a
4.0 (the way the alarm frame was pinned, #535). Driven by `BLEManager.rebootProbe(_:)` /
`WhoopBleClient.rebootProbe(...)`; candidates enumerated in `RebootProbeVariant`.

## Body-location probe (#690)

This paragraph records the older client decoder; the [current response body](PROTOCOL_COMMANDS.md#ordinary-service-commands) is documented separately.

 A read-only, user-triggered diagnostic (Test Centre → Connection, both
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

## Feature-flag enumeration probe (#761, read-only)

The probe’s older count model differs from the current u8 field; use the [named configuration interface](PROTOCOL_CONFIGURATION.md#named-configuration-interface).

 NOOP has always been able to WRITE a feature flag
(`SET_FF_VALUE` / 120, the R22 unlock in `Whoop5Config`) but never to ASK a strap which flags it knows.
The `CommandNumber` table names a full symmetric read side that was never implemented — 117
`START_FF_KEY_EXCHANGE` / 118 `SEND_NEXT_FF` for feature flags, 115 / 116 for device config — and this
probe uses the enumerate pair only: **names, no values, nothing written.** `GET_FF_VALUE` (128) is
deliberately not sent: the only hands-on report of it (`johnmiddleton12/wearable`, run on the author's
own WHOOP 4.0 on the earlier WHOOP 4 baseline) states its reply's value field is contaminated by a stale shared buffer,
so an on/off read is unreliable; the same session ran the 117→118 loop and got a complete key dump.

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
a repeated index during such a run (a parked cursor — evidence for the terminator reading), the announced
count plus 4, or a hard cap of 128 replies. Each next-record request is only sent after the previous reply
lands. Both CRCs are verified before any field is read; a failed CRC, a non-COMMAND_RESPONSE type, or a
short record ends the walk with a named reason instead of a decode, and the RAW record bytes of every
reply are logged beside the fields decoded from them. Driven by `BLEManager.probeFeatureFlags()` /
`WhoopBleClient.probeFeatureFlags()` (user-triggered, Test Centre → Connection, both families) and
allowlisted for 5/MG framing **only while a probe is in flight**; parsed + rendered by the pure
`FeatureFlagProbe` / `FeatureFlagProbeReport` twins (Swift↔Kotlin byte-parity, unit-tested on synthetic
frames). Result goes to a copyable dialog + the strap log; no storage. The field order and opcode numbers
are facts read off a decompiled official client's response types and corroborated by that 4.0 dump,
reimplemented in NOOP's own code — facts, not copied expression (see [`ATTRIBUTION.md`](../ATTRIBUTION.md)).
**Historical probe scope:** the published comparison dump is a 4.0's R19-era list. The
the reference baseline enumeration commands and eligible-key inventory are now described in
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
command-response inner payload (whose byte 0 is a subtype): write page `W = V(2)`, acknowledged/trim boundary `D = V(3)`,
ring capacity `T = V(5)`, where `V(i)` is the u32 at inner offset `i·4 + 1` (frame offsets `cmdOff + 10/14/22`
here). In the current WHOOP 5/MG [range layout](PROTOCOL_TRANSPORT.md#data-range--command-34),
the read-page cursor is `V(1)`; `V(3)` measures the acknowledged boundary instead.
Backlog with wraparound: `W < D ? W + (T − D) : W − D`. `DataRange.pagesBehind` (Swift + Kotlin twins,
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

- `FORCE_TRIM` (25) — body is **two little-endian int32 range args**. One app-built
  form sets both to `-16843010` (`0xFEFEFEFE`, builder `rh0.C45484g`:
  `new C45484g(-16843010, -16843010)`). It is **not** an empty/`[0x00]` payload.
  In the WHOOP 5/MG profile, this pair enters the same history-storage event path
  as the chunk acknowledgement: it selects a special mode and the current write
  boundary. This is an invasive cursor/reclamation operation; it does not establish
  physical erasure of the entire flash history or guarantee that every stored
  record becomes unavailable. See [special history acknowledgement tokens](PROTOCOL_TRANSPORT.md#history-sequencing-and-storage-ownership).
- `REBOOT_STRAP` (29) — **empty body** (builder `rh0.C45476d0` passes a null payload). The strap drops
  the BLE link and re-advertises after boot; stored data is kept. Non-destructive, but interrupts any
  in-flight offload. **WHOOP 5.0 (puffin): hardware-confirmed** — the empty-body frame reboots a 5.0
  (the earlier reboot observation, #227). **WHOOP 4.0 (harvard): NOT confirmed** — a real 4.0 silently ignores this
  empty-body frame (#235: no reboot, no disconnect, no COMMAND_RESPONSE), so the correct 4.0 form (a
  payload byte? a different opcode?) still needs an HCI capture of the official app rebooting a 4.0.

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

<a id="74-safe-trim-invariant"></a>

## Safe-trim invariant

NOOP sends the normal chunk acknowledgement only after local durability. This is a client persistence invariant; it does not prove all device read/erase behavior or exactly-once delivery. From
`Backfiller.finishChunk(...)`:

```
decode → await insert(decoded) → [await enqueueRawBatch] → await setCursor("strap_trim") → ackTrim
```

Any thrown error in that sequence short-circuits before the client sends the ack. The
ack itself is the link-layer half: `HISTORICAL_DATA_RESULT(23)` with payload `[0x01] + end_data`
written `.withResponse`. A BLE write confirmation is not itself proof of physical erasure or power-loss durability. The
`strap_trim` cursor is persisted, so the client retains progress for another attempt; exact device replay after disconnect is not guaranteed. This local progress does not depend on a network.

<a id="75-watchdog--liveness"></a>

## Watchdog & liveness

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

## SpO₂ on 5.0 / MG — what the wire does and does not carry

No dedicated SpO₂ read operation is identified in the current command reference.
R18 byte 82 has no established physiological meaning. NOOP imports
`blood_oxygen_pct` as a per-cycle value; that importer does not establish the
vendor's aggregation or calibration algorithm. See the
[raw-record interpretation limits](PROTOCOL_SENSORS.md).

<a id="11-file-map"></a>

## File map

| Path | Responsibility |
|------|----------------|
| `Packages/WhoopProtocol/Sources/WhoopProtocol/Framing.swift` | SOF/length/CRC8/CRC16/CRC32, `verifyFrame`, `Reassembler`, `frameFromPayload` |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/Interpreter.swift` | `parseFrame` (4.0 + 5.0), `ParsedFrame`, field builder |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/DeviceFamily.swift` | UUID strings, header-CRC kind, `CLIENT_HELLO`, puffin aliasing |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/Schema.swift` | JSON schema model + `loadSchema()` |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/PostHooks.swift` | per-type irregular-field decoders |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/HistoricalMeta.swift` | `classifyHistoricalMeta` (START/END/COMPLETE) |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/Resources/whoop_protocol.json` | canonical enums + packet layouts |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5Ecg.swift` | MG ECG ("Labrador") packet decode + command construction |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5EcgProbe.swift` | ECG turn-on report + the run-scoped result-code verdicts |
| `Strand/BLE/BLEManager.swift` | CoreBluetooth transport, bond, connect lifecycle, backfill orchestration |
| `Strand/BLE/Commands.swift` | safe `WhoopCommand` set + outbound frame builder |
| `Strand/BLE/FrameRouter.swift` | decode → `LiveState` (UI) |
| `Strand/BLE/StandardHeartRate.swift` | `0x2A37` HR/R-R parser |
| `Strand/Collect/Backfiller.swift` | historical-offload state machine + safe-trim invariant |

---

*Reverse-engineering credit: `johnmiddleton12/my-whoop` (WHOOP 4.0) and `b-nnett/goose`
(WHOOP 5.0). This is an independent interoperability project for the user's own device and data;
it is not affiliated with WHOOP and is not a medical device.*

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
