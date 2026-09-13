# WHOOP complete command reference

Applicability: [central scope and compatibility](PROTOCOL.md#scope-and-compatibility).

This reference extends [the existing protocol documentation](PROTOCOL.md); it is not a list of commands that NOOP automatically sends. The catalog covers **all IDs 1–159 in the documented command context**: 71 have a defined operation and 88 use the unsupported response. “Defined” does not mean fully decoded, available on every WHOOP 5/MG hardware variant, permitted in every state, or successfully exercised on a device. There are no device-validation claims for the reference baseline here; earlier observations are labeled with their own scope.

Names are identifiers, not sufficient evidence of behavior. Historical names are retained for recognition even where the current version does not support the operation. An unnamed unsupported ID has no assigned semantics. Do not extrapolate this catalog to other firmware versions, command contexts or IDs outside the range.

Requests below describe semantic command bodies, excluding outer padding. Unless stated otherwise, exact request/response bytes, initial state, prerequisite, persistence and reversal remain unknown. Common results and request-origin correlation are in [transport behavior](PROTOCOL_TRANSPORT.md#responses-and-correlation). An accepted request is not proof that its eventual effect occurred.

## All command IDs

Each numeric ID appears once in this catalog. **D** means defined, with the stated limits and linked contract; **U** means unsupported in the documented command context: result 3, empty semantic body. A known name on a U row is a historical identifier, not a current supported effect.

| ID | Name / identifier | Status | Meaning and contract |
|---:|---|:---:|---|
| 1 | `LINK_VALID` | D | Fixed acknowledgement; not identity. [Details](#core-command-contracts) |
| 2 | `GET_MAX_PROTOCOL_VERSION` | U | Historical identifier only; current arguments and effect not supported. [Details](#unsupported-and-cross-version-commands) |
| 3 | `TOGGLE_REALTIME_HR` | D | Live HR toggle; older NOOP body `0`/`1`, current acceptance unresolved. [Details](#core-command-contracts) |
| 4 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 5 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 6 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 7 | `REPORT_VERSION_INFO` | U | Historical identifier only; current arguments and effect not supported. [Details](#unsupported-and-cross-version-commands) |
| 8 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 9 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 10 | `SET_CLOCK_DEPRECATED` | D | Deprecated clock setter; do not use the high-opcode body. [Details](#core-command-contracts) |
| 11 | `GET_CLOCK_DEPRECATED` | D | Deprecated clock reader; current reply layout unresolved. [Details](#core-command-contracts) |
| 12 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 13 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 14 | `TOGGLE_GENERIC_HR_PROFILE` | D | Boolean generic-HR policy; nonvolatile setting, downstream GATT effect unresolved. [Details](#core-command-contracts) |
| 15 | `Forget bonds` | D | Remove pairing bonds; destructive lifecycle change. [Details](#service-and-sensitive-operations) |
| 16 | `TOGGLE_R7_DATA_COLLECTION` | U | Historical identifier only; current arguments and effect not supported. [Details](#unsupported-and-cross-version-commands) |
| 17 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 18 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 19 | `RUN_HAPTIC_PATTERN_MAVERICK` | D | Notification haptics; revision-1 pattern. [Details](#haptics-and-alarms) |
| 20 | `ABORT_HISTORICAL_TRANSMITS` | D | Stop historical transmission, not trim. [Details](#core-command-contracts) |
| 21 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 22 | `SEND_HISTORICAL_DATA` | D | Request historical transmission; delivery is asynchronous. [Details](#core-command-contracts) |
| 23 | `HISTORICAL_DATA_RESULT` | D | Acknowledge a committed history chunk; permits reclamation. [Details](#core-command-contracts) |
| 24 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 25 | `FORCE_TRIM` | D | Force history trimming; invasive cursor mutation. [Details](#service-and-sensitive-operations) |
| 26 | `GET_BATTERY_LEVEL` | D | Asynchronous battery query; four-byte u32 whole-percent final body. [Details](PROTOCOL_TRANSPORT.md#battery-level--command-26) |
| 27 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 28 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 29 | `REBOOT_STRAP` | D | Reboot and interrupt current work. [Details](#service-and-sensitive-operations) |
| 30 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 31 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 32 | `POWER_CYCLE_STRAP` | D | Power-cycle; current runtime and preservation guarantees unresolved. [Details](#service-and-sensitive-operations) |
| 33 | `SET_READ_POINTER` | D | Change history read position; invasive cursor mutation. [Details](#service-and-sensitive-operations) |
| 34 | `GET_DATA_RANGE` | D | Pending then 65-byte range reply; cursor roles and remaining clock limits specified. [Details](PROTOCOL_TRANSPORT.md#data-range--command-34) |
| 35 | `GET_HELLO_HARVARD` | D | Legacy Hello branch does not build a local command reply. [Details](PROTOCOL_TRANSPORT.md#hello--command-145) |
| 36 | `START_FIRMWARE_LOAD` | U | Historical identifier only; current arguments and effect not supported. [Details](#unsupported-and-cross-version-commands) |
| 37 | `LOAD_FIRMWARE_DATA` | U | Historical identifier only; current arguments and effect not supported. [Details](#unsupported-and-cross-version-commands) |
| 38 | `PROCESS_FIRMWARE_IMAGE` | U | Historical identifier only; current arguments and effect not supported. [Details](#unsupported-and-cross-version-commands) |
| 39 | `SET_LED_DRIVE` | U | Historical identifier only; current arguments and effect not supported. [Details](#unsupported-and-cross-version-commands) |
| 40 | `GET_LED_DRIVE` | U | Historical identifier only; current arguments and effect not supported. [Details](#unsupported-and-cross-version-commands) |
| 41 | `SET_TIA_GAIN` | U | Historical identifier only; current arguments and effect not supported. [Details](#unsupported-and-cross-version-commands) |
| 42 | `GET_TIA_GAIN` | U | Historical identifier only; current arguments and effect not supported. [Details](#unsupported-and-cross-version-commands) |
| 43 | `SET_BIAS_OFFSET` | U | Historical identifier only; current arguments and effect not supported. [Details](#unsupported-and-cross-version-commands) |
| 44 | `GET_BIAS_OFFSET` | U | Historical identifier only; current arguments and effect not supported. [Details](#unsupported-and-cross-version-commands) |
| 45 | `ENTER_BLE_DFU` | U | Historical identifier only; current arguments and effect not supported. [Details](#unsupported-and-cross-version-commands) |
| 46 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 47 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 48 | `SEND_EVENT_PACKETS` | D | Toggle event delivery, not a proven flush of stored events. [Details](#core-command-contracts) |
| 49 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 50 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 51 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 52 | `SET_DP_TYPE` | U | Historical identifier only; current arguments and effect not supported. [Details](#unsupported-and-cross-version-commands) |
| 53 | `FORCE_DP_TYPE` | U | Historical identifier only; current arguments and effect not supported. [Details](#unsupported-and-cross-version-commands) |
| 54 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 55 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 56 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 57 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 58 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 59 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 60 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 61 | `SET_AFE_PARAMETERS` | D | Set AFE channel/setting/value; operating AFE required. [Details](PROTOCOL_CONFIGURATION.md) |
| 62 | `GET_AFE_PARAMETERS` | D | Read cached AFE channel/setting/value; three-word body, no revision prefix. [Details](PROTOCOL_CONFIGURATION.md) |
| 63 | `SEND_R10_R11_REALTIME` | U | Historical identifier only; current arguments and effect not supported. [Details](#unsupported-and-cross-version-commands) |
| 64 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 65 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 66 | `SET_ALARM_TIME` | D | Set revision-4 time, pattern and crescendo for ID 1–6. [Details](#haptics-and-alarms) |
| 67 | `GET_ALARM_TIME` | D | Read revision-4 21-byte alarm record; storage fallback caveat. [Details](#haptics-and-alarms) |
| 68 | `RUN_ALARM` | D | Run a stored alarm; pending/final response, consumes saved schedule. [Details](#haptics-and-alarms) |
| 69 | `DISABLE_ALARM` | D | Clear one saved alarm or all six; distinct from stopping active haptics. [Details](#haptics-and-alarms) |
| 70 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 71 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 72 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 73 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 74 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 75 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 76 | `GET_ADVERTISING_NAME_HARVARD` | U | Historical identifier only; current arguments and effect not supported. [Details](#unsupported-and-cross-version-commands) |
| 77 | `SET_ADVERTISING_NAME_HARVARD` | U | Historical identifier only; current arguments and effect not supported. [Details](#unsupported-and-cross-version-commands) |
| 78 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 79 | `RUN_HAPTICS_PATTERN` | U | Historical identifier only; current arguments and effect not supported. [Details](#unsupported-and-cross-version-commands) |
| 80 | `GET_ALL_HAPTICS_PATTERN` | U | Historical identifier only; current arguments and effect not supported. [Details](#unsupported-and-cross-version-commands) |
| 81 | `START_RAW_DATA` | D | Start raw production; separate from saving and streaming. [Details](PROTOCOL_CONFIGURATION.md) |
| 82 | `STOP_RAW_DATA` | D | Stop raw production; not a substitute for every collection policy. [Details](PROTOCOL_CONFIGURATION.md) |
| 83 | `VERIFY_FIRMWARE_IMAGE` | D | Incremental integrity check with correlated asynchronous final result; boot acceptance separate. [Details](#service-and-sensitive-operations) |
| 84 | `GET_BODY_LOCATION_AND_STATUS` | D | Revision 1; fixed four-byte cached status, with location/confidence placeholders. [Details](#ordinary-service-commands) |
| 85 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 86 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 87 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 88 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 89 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 90 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 91 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 92 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 93 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 94 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 95 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 96 | `ENTER_HIGH_FREQ_SYNC` | D | Request high-frequency sync schedule; period/duration constraints below. [Details](#core-command-contracts) |
| 97 | `EXIT_HIGH_FREQ_SYNC` | D | Request leaving high-frequency sync; acceptance precedes asynchronous effect. [Details](#core-command-contracts) |
| 98 | `GET_EXTENDED_BATTERY_INFO` | U | Historical identifier only; current arguments and effect not supported. [Details](#unsupported-and-cross-version-commands) |
| 99 | `RESET_FUEL_GAUGE` | U | Historical identifier only; current arguments and effect not supported. [Details](#unsupported-and-cross-version-commands) |
| 100 | `CALIBRATE_CAPSENSE` | U | Historical identifier only; current arguments and effect not supported. [Details](#unsupported-and-cross-version-commands) |
| 101 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 102 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 103 | `Disable BLE UART` | D | Change BLE UART service state; safe readback unresolved. [Details](#service-and-sensitive-operations) |
| 104 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 105 | `TOGGLE_IMU_MODE_HISTORICAL` | D | IMU session saving contribution in RAM. [Details](PROTOCOL_CONFIGURATION.md) |
| 106 | `TOGGLE_IMU_MODE` | D | Live IMU transport toggle. [Details](PROTOCOL_CONFIGURATION.md) |
| 107 | `ENABLE_OPTICAL_DATA` | D | Optical session saving contribution in RAM. [Details](PROTOCOL_CONFIGURATION.md) |
| 108 | `TOGGLE_OPTICAL_MODE` | D | Live optical transport toggle. [Details](PROTOCOL_CONFIGURATION.md) |
| 109 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 110 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 111 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 112 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 113 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 114 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 115 | `START_DEVICE_CONFIG_KEY_EXCHANGE` | D | Reset device-key enumeration and return count. [Details](PROTOCOL_CONFIGURATION.md) |
| 116 | `SEND_NEXT_DEVICE_CONFIG` | D | Advance device-key cursor; names, not values. [Details](PROTOCOL_CONFIGURATION.md) |
| 117 | `START_FF_KEY_EXCHANGE` | D | Reset feature-key enumeration and return count. [Details](PROTOCOL_CONFIGURATION.md) |
| 118 | `SEND_NEXT_FF` | D | Advance feature-key cursor; names, not values. [Details](PROTOCOL_CONFIGURATION.md) |
| 119 | `SET_DEVICE_CONFIG_VALUE` | D | Typed named device-configuration SET. [Details](PROTOCOL_CONFIGURATION.md) |
| 120 | `SET_FF_VALUE` | D | Typed named feature-flag SET. [Details](PROTOCOL_CONFIGURATION.md) |
| 121 | `GET_DEVICE_CONFIG_VALUE` | D | Read named device configuration from storage. [Details](PROTOCOL_CONFIGURATION.md) |
| 122 | `STOP_HAPTICS` | D | Revision 1 only; asynchronous pending/final stop, one-byte body. [Details](PROTOCOL_ALARMS.md#busy-execution-and-stop-completion) |
| 123 | `SELECT_WRIST` | D | ECG wrist: revision 1, right 1 / left 2; persistence unproved. [Details](PROTOCOL_ECG.md) |
| 124 | `TOGGLE_LABRADOR_DATA_GENERATION` | D | ECG processing: revision 1, stop 1 / start 2 or 3; hardware guarded. [Details](PROTOCOL_ECG.md) |
| 125 | `TOGGLE_LABRADOR_RAW_SAVE` | D | Boolean raw-ECG saving, independent of live transport. [Details](PROTOCOL_ECG.md) |
| 126 | `Send raw ECG` | D | Boolean raw-ECG live transport. [Details](PROTOCOL_ECG.md) |
| 127 | `Save filtered ECG` | D | Boolean filtered-ECG saving. [Details](PROTOCOL_ECG.md) |
| 128 | `GET_FF_VALUE` | D | Read named feature configuration from storage. [Details](PROTOCOL_CONFIGURATION.md) |
| 129 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 130 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 131 | `SET_RESEARCH_PACKET` | U | Historical identifier only; current arguments and effect not supported. [Details](#unsupported-and-cross-version-commands) |
| 132 | `GET_RESEARCH_PACKET` | U | Historical identifier only; current arguments and effect not supported. [Details](#unsupported-and-cross-version-commands) |
| 133 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 134 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 135 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 136 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 137 | `Unknown` | U | No assigned meaning; no supported request body. [Details](#unsupported-and-cross-version-commands) |
| 138 | `Set signal-processing configuration` | D | Revision 1 plus selector; 0–8 presets, 9–255 acknowledge without selecting. [Details](#ordinary-service-commands) |
| 139 | `TOGGLE_LABRADOR_FILTERED` | D | Boolean filtered-ECG live transport. [Details](PROTOCOL_ECG.md) |
| 140 | `SET_ADVERTISING_NAME` | D | Revision 1; advertising name at most 15 bytes, update requested after storage. [Details](#ordinary-service-commands) |
| 141 | `GET_ADVERTISING_NAME` | D | Revision 1; fixed 19-byte name response. [Details](#ordinary-service-commands) |
| 142 | `START_FIRMWARE_LOAD_NEW` | D | Begin executable-image transfer; persistent mutation. [Details](#service-and-sensitive-operations) |
| 143 | `LOAD_FIRMWARE_DATA_NEW` | D | Write bounded executable-image chunk; persistent mutation. [Details](#service-and-sensitive-operations) |
| 144 | `PROCESS_FIRMWARE_IMAGE_NEW` | D | Process transferred image; later validation/activation incomplete. [Details](#service-and-sensitive-operations) |
| 145 | `GET_HELLO` | D | Revision 1/3 Hello; pending then asynchronous identity response. [Details](#core-command-contracts) |
| 146 | `SET_CLOCK` | D | Revision-1 seconds/ticks clock SET; hundredths precision. [Details](#core-command-contracts) |
| 147 | `GET_CLOCK` | D | Revision-1 seconds/ticks clock GET; zero-time caveat. [Details](#core-command-contracts) |
| 148 | `Wear-detection override` | D | Revision 1; 1 forces worn and disables detection, 0 restores detection. [Details](#ordinary-service-commands) |
| 149 | `Set LED accessibility` | D | Revision 1 boolean; persistent LED accessibility option. [Details](#ordinary-service-commands) |
| 150 | `Set gyro mode (Disable Gyro)` | D | Revision-1 gyro SET: 0 disabled, 1 enabled; partial failure possible. [Details](PROTOCOL_CONFIGURATION.md) |
| 151 | `GET_BATTERY_PACK_INFO` | D | Revision 1; cached 28-byte pack body, presence and freshness distinct. [Details](PROTOCOL_TRANSPORT.md#battery-pack--command-151) |
| 152 | `Get gyro mode status` | D | Revision-1 cached gyro-mode predicate; not fresh sensor read. [Details](PROTOCOL_CONFIGURATION.md) |
| 153 | `TOGGLE_PERSISTENT_R20` | D | Persistent optical/R20 collection contribution. [Details](PROTOCOL_CONFIGURATION.md) |
| 154 | `TOGGLE_PERSISTENT_R21` | D | Persistent IMU/R21 collection contribution. [Details](PROTOCOL_CONFIGURATION.md) |
| 155 | `START_CERTIFICATE_TRANSFER` | D | Begin certificate transfer; security-state mutation. [Details](#service-and-sensitive-operations) |
| 156 | `LOAD_CERTIFICATE` | D | Load certificate data; security-state mutation. [Details](#service-and-sensitive-operations) |
| 157 | `VERIFY_CERTIFICATE` | D | Verify transferred certificate, identity and freshness; detailed validation limits documented. [Details](#service-and-sensitive-operations) |
| 158 | `PROCESS_CERTIFICATE` | D | Process/store certificate material; security-state mutation. [Details](#service-and-sensitive-operations) |
| 159 | `LOCK_DEVICE` | D | Revision-1 queued authorization lock; conditional certificate clearing and reauthorization. [Details](#service-and-sensitive-operations) |

## Unsupported and cross-version commands

The U classification is version/context specific. For example, REPORT_VERSION_INFO, SEND_R10_R11_REALTIME and GET_EXTENDED_BATTERY_INFO have older family meanings or partial observations; that does not override their unsupported status here. The legacy image-transfer, analog-setting and advertising-name families likewise must not be used as aliases for supported high-number commands. An unsupported reply is distinct from a timeout, malformed-frame rejection or known command returning failure. Neither ID adjacency nor a familiar enum name is a basis for probing a replacement.

## Core command contracts

| Operation | Request and response | Effect / limits |
|---|---|---|
| Link check | No semantic payload fields; success, fixed 13-byte NUL-terminated acknowledgement. | Link-level acknowledgement, not device identity. |
| Live HR | Historical NOOP request byte `0` off / `1` on. | Live HR delivery is distinct from the command response; current acceptance and complete prerequisites unresolved. |
| Generic HR profile | One byte `0`/`1`; others fail. Success or failure with empty body, according to setting-write result. | Updates a nonvolatile policy; downstream standard-GATT behavior and observed restart survival unresolved. |
| Event delivery | One byte `0`/`1`; others fail; accepted request returns success with empty body. | Delivery toggle. Whether it selects historical events, future events or both remains unresolved; “flush stored events” is not established. |
| High-frequency sync entry | Revision 2, period `u16le`, duration `u16le`; period strictly greater than 60, duration strictly less than 28,800. | Accepted request returns success empty; invalid values fail empty. Duration is seconds; counter threshold is twice the period. [Scheduler contract](#high-frequency-sync-scheduler). |
| High-frequency sync exit | No semantic payload fields; success empty precedes queued disable. | Explicit exit clears active and emits event 98; automatic expiry differs. [Scheduler contract](#high-frequency-sync-scheduler). |
| History request / abort | Historical NOOP uses explicit `00` for each operation. | Start delivers metadata/records asynchronously; abort is not trim. Command 22 returns state plus two zero bytes; states 6/7/9/10 fail and others succeed, while asynchronous work is still requested. Delivery is separate. |
| History acknowledgement | `01` plus the eight original HISTORY_END bytes, only after local commit. | May release stored device history. See [storage ownership](PROTOCOL_TRANSPORT.md#history-sequencing-and-storage-ownership). |
| Range | No semantic request fields; initial pending empty. | Final body is 65 bytes with page cursors, estimates and clock pairs; see [range fields](PROTOCOL_TRANSPORT.md#data-range--command-34). An earlier MG returned pending then success; do not generalize all older offsets. |
| Battery | Historical NOOP uses empty or `00`; current query is asynchronous with no immediate reply established. | Older WHOOP 4 charge is `u16le / 10` percent; an older WHOOP 5 observation identified the first body byte as whole percent without establishing a universal one-byte body. The current final body is u32 whole percent; zero can be a fallback. Only a nonzero error on the ordinary completion callback carries four zero bytes; actual timeout/error handling does not guarantee that reply (see [battery responses](PROTOCOL_TRANSPORT.md#battery-level--command-26)). |
| Deprecated clock SET/GET | Historical SET: seconds `u32le` plus four zero subsecond bytes; WHOOP 4 also has a ninth zero variant. GET uses empty or `00`. | Current payload/reply unresolved. Separate from revision-1 high-number clocks. |
| Legacy Hello | WHOOP 4 client uses `00`. | The current local handler builds no command reply; do not expose identity fields unnecessarily. |
| New Hello and clock pair | [Exact revision, size and clock precision contracts](PROTOCOL_TRANSPORT.md#clock-and-identity-contracts). | Hello final bodies are 107/111 bytes; retain their preparation flags; clock success alone does not prove nonzero valid time. |

## High-frequency sync scheduler


Command 96 revision 2 carries revision `2`, period u16le at byte 1 and duration
u16le at byte 3. Accepted values are period >60 and duration <28800. Duration is
in seconds, compared against wall-clock seconds on a later scheduler callback.
The period controls a callback-count threshold: **2 × period callbacks**. Each
callback is nominally about half a second, making period units approximately
seconds. Period 61 represents 122 received callbacks, nominally about 61 seconds
from a zero counter. Timer restart, interrupt and scheduler latency remain
separate; this is not an exact elapsed-time guarantee.
Entering while already active does not replace the period, duration or start
time. Do not treat its successful response as confirmation that a session was
refreshed.

First entry emits event 97 (`0x61`). While active, a 16-bit counter advances
once per callback; reaching twice the period emits event 96 (`0x60`) and resets
the counter. For periods 32768–65535, twice the period exceeds the counter's
maximum, so that periodic event cannot be reached by this comparison. Entry
and explicit exit do not reset the counter in these paths, so its existing
value may affect the first interval.

Command 97 emits event 98 (`0x62`) and clears active. Automatic duration expiry
clears active without that exit event. Duration zero expires on the next
callback, after the periodic-event check. Wall-clock changes and 32-bit deadline
arithmetic matter; this is not a monotonic elapsed timer. These paths schedule
event notifications; they do not establish faster Bluetooth transfer or a
changed acquisition rate. Further event consumers or client reactions are
outside this contract. Keep command IDs and event IDs in separate namespaces.


## Haptics and alarms

Notification haptics uses a revision-1, 12-byte body: revision at 0, eight waveform-effect bytes at 1–8, effect loop-control `u16le` at 9–10, overall-repeat byte at 11. Existing NOOP patterns use effect-loop control zero. The overall field counts repetitions **after the first pulse**, so a request for N pulses uses N−1. Older MG validation found four buzzes when that byte was 3. NOOP bounds requests to one through eight pulses; this client bound is not a universal firmware maximum. The current WHOOP 5/MG shared pattern validator requires each of the eight effect bytes to be at most 251 and the overall-repeat byte to be below 8. It does not validate the loop-control field. Passing these checks alone does not establish a valid physical waveform. The existing effect sequence and its attribution remain in the NOOP implementation; these fields do not establish every possible waveform ID.

Alarm SET/GET, validation, readback, single/all-ID disable and manual RUN are described in
[alarm configuration and execution](PROTOCOL_ALARMS.md). The current record is 21 bytes,
including crescendo; the earlier NOOP 20-byte encoder obtains crescendo zero from framing
padding and is not thereby shown to send a short frame. SET validation detail, storage
result, execution event and physical wake are separate outcomes. RUN consumes its selected
saved schedule and is not a guaranteed nondestructive preview.

STOP_HAPTICS takes revision 1 alone and returns pending then a final result, each with body `[1]`. Stopping a buzz does not prove that a scheduled alarm was removed.
Older alarm arming acknowledgements remain scoped to their runs; no successful physical
wake is claimed. Haptic actions belong to deliberate app actions, not connection
discovery.

## Service and sensitive operations

Pairing reset and reboot interrupt connection and work; preservation is not established for every operation. Forced trim and read-pointer changes mutate history ownership and cannot substitute for committed-chunk acknowledgement. Their recovery behavior remains unresolved. Battery-pack fields are in [transport](PROTOCOL_TRANSPORT.md#battery-pack--command-151).

The following operation-specific schemas are for independent interface implementations. A known field does not establish every prerequisite, safe operating sequence or completed effect. These fields do not authorize or describe a tested device update.

All service-table offsets are command-body offsets; integers are little-endian. Revisioned operations use revision 1. Outer result is 1 success / 0 failure, separate from the listed body. Semantic lengths do not establish acceptance of unpadded short frames.

## Ordinary service commands

| Command | Request body | Response body | Behavior |
|---:|---|---|---|
| 148 | `revision:u8=1, override:u8` | `[1]` | `override=1` forces the worn state and disables normal wear detection. `0` restores normal detection. Other values fail. Restoring detection does not promise an immediate off-body report. |
| 149 | `revision:u8=1, enabled:u8` | `[1]` | Sets the persistent LED accessibility option; accepts only 0 and 1. Success reports the settings write result. Exact visual patterns depend on the indicator state. |
| 140 | `revision:u8=1, length:u8, name[length]` | `[1]` | Stores an advertising name of 0–15 bytes and requests an advertising update. Length counts bytes. No character-set validation is established. Radio visibility and client cache refresh may lag the reply. |
| 141 | `revision:u8=1` | Fixed 19 bytes, described below | Reads the advertising name. |
| 84 | `revision:u8=1` | `[1, 0, 255, on_body]` | Returns cached on-body status, 0 or 1. The two middle bytes are fixed placeholders, not measured location or confidence. |
| 138 | `revision:u8=1, selector:u8` | Empty | Selectors 0–8 select defined presets whose meanings remain undocumented. Every byte value receives success for revision 1; values 9–255 do not select a new preset. Success does not confirm persistence. |
| 103 | `revision:u8=1` | `[1]` | Acknowledges a BLE UART disable request before its asynchronous handling. No enable argument or completion/readback contract is established. |
| 32 | No command fields established | Empty | Acknowledges a power-cycle request before asynchronous lifecycle handling. Completion delay, power-rail behavior and retained state are not established. |

For the revisioned commands, an unsupported revision fails. Command 138 has an empty failure body. Commands 84 and 141 return their initialized fixed-size bodies on revision failure: `[1,0,0,0]` and `[1]` followed by 18 zeros. The remaining one-byte ordinary responses retain `[1]` on failure.

Command 149 updates one option within a shared stored settings record. If reading that record fails, it starts from defaults before writing the requested option. Success therefore does not prove that the other previously stored options were preserved.

Command 141 returns revision 1 at offset 0; source/status at offset 1; a NUL-inclusive length of 1–16 at offset 2; and 16 bytes of name storage at offsets 3–18. Status 1 identifies a custom name. Status 2 covers fallback or empty storage and storage-read failure; it does not diagnose a specific storage error. The last storage byte is zero. Limit decoding to this fixed storage and exclude the terminator from display.

## Image-transfer command boundaries

See [image transfer](PROTOCOL_UPDATES.md#image-transfer-command-boundaries).

## Certificate command boundaries

See [certificates and authorization](PROTOCOL_UPDATES.md#certificate-command-boundaries).
