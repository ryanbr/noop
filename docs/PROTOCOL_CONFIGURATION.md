# WHOOP configuration and collection controls

Applicability: [central scope and compatibility](PROTOCOL.md#scope-and-compatibility).

This is the configuration companion to [the protocol reference](PROTOCOL.md). Unless explicitly labeled historical, the contracts below apply to the reference baseline. A stored value, its interpreted policy, accepted request, effective sensor activity and delivered packet stream are different states. Do not collapse them into one “enabled” boolean. Device-specific factory values, power-interruption survival and all hardware variants are not established by these contracts.

## Named configuration interface

| Operation | Command | Request / response boundary |
|---|---|---|
| Count device keys | 115 | Revision 1; resets the enumeration cursor and returns a one-byte count after revision 1 (two body bytes). |
| Next device key | 116 | Revision 1; advances a shared enumeration cursor, not a caller-supplied index. |
| Count feature keys | 117 | Revision 1; resets the feature enumeration cursor and returns a one-byte count after revision 1 (two body bytes). |
| Next feature key | 118 | Revision 1; advances the feature enumeration cursor. |
| Set device value | 119 | Revision 1, 32-byte key field, 32-byte value field. |
| Set feature value | 120 | Same layout, feature namespace. |
| Read device value | 121 | Revision 1 followed by a 32-byte key field; 65-byte reply. |
| Read feature value | 128 | Same request and reply sizes, feature namespace. |

The current named SET body is **65 bytes** before outer framing/padding. Fields are NUL-terminated; names have at most 31 meaningful bytes in the 32-byte field. Use ASCII values matching the descriptor type below and zero-fill unused field bytes. The shorter historical NOOP encoder, with one value character and a few padding bytes, does not establish the complete request contract. Handling of truncated SET bodies is unresolved; do not use them as capability probes.

Enumeration replies expose revision, index, validity and a bounded name; they do not return values. A false validity byte alone is not a universal terminator. Earlier NOOP handling recognizes index 255 as terminal and uses bounded count/slack and empty-response limits. The baseline count is one byte; older formats remain separately scoped. NOOP's safeguards—128 responses maximum, eight consecutive empty entries, and announced count plus four—are client limits, not promised firmware capacities. Serialize enumeration requests because the cursor is stateful.

GET reads configuration storage rather than merely echoing the preceding SET. The current reply is the 65-byte key/value record specified below, including its failure bodies. Validate response command, origin, result, bounds and returned key before using a value. Preserve the bounded value bytes instead of taking the final padded byte as a boolean. A response timeout is not evidence that a named key or command does not exist.

### Value types and storage

| Type | Accepted representation / conversion | Meaning boundary |
|---|---|---|
| Tri-state | Exact NUL-terminated ASCII `0`, `1` or `2` | Numeric policy values, not one universal on/off encoding. |
| Unsigned byte | Decimal integer bounded above by 255 | The parser limit is not a per-key safe operating range. |
| Tenths | Nonnegative decimal value, scaled by 10 with `+0.5` rounding into bounded integer storage; readback decodes a 16-bit quantity | `max_collection_backlog` uses tenths. It expresses capacity percentage in tenths of a percentage point; safe operating thresholds remain unknown. |

Device and feature namespaces are stored separately in checked nonvolatile records. A named SET rewrites the namespace's five records; atomicity of those writes is not established. A failed record read substitutes zero-filled data. Thus zero readback may be a fallback, not a successfully recovered saved value, and neither proves a factory default. Per-key callback effects and reboot behavior are not uniformly established. Read back a changed value when the relevant reply contract is supported, and separately observe the intended application effect.

## Device key inventory

All eight names below are eligible for named lookup. Eligibility does not establish a complete behavioral contract or support on every device.

| Key | Value type | Known behavior / remaining limits |
|---|---|---|
| `sigproc_wear_detect` | Tri-state | Wear-detection setting; per-value effect, applied default and safe change conditions unresolved. |
| `enable_rfid` | Tri-state | RFID setting; exact effect, polarity and default unresolved. |
| `max_collection_backlog` | Tenths | Capacity percentage in tenths; strict threshold exceed attempts to clear continuous mode. Safe operating thresholds remain unresolved. |
| `cont_collection_mode` | Unsigned byte | Contributes to optical/IMU collection policy alongside session and persistent requests. Mode 0 removes continuous collection; 1 requests optical and IMU collection. Other accepted bytes are not established supported modes. |
| `whoop_live_hr_in_adv_ind_pkt` | Tri-state | Stored 1 selects this advertising preference before the two-HRM preference; 0/2 do not. Exact advertised contents and timing remain unresolved. |
| `whoop_live_2_hrm_devices` | Tri-state | Stored 1 selects the named preference; 0/2 do not. Exact connection capacity and factory state remain unresolved. |
| `enable_raw_data_w_ecg` | Tri-state | Resolver: `0` and `1` true, `2` false; fallback is true. Requests companion raw optical/IMU handling after successful ECG startup. It is **not** the ECG master gate. |
| `dorset_detection_period_min` | Unsigned byte | Zero or a failed read selects fallback 5; a nonzero value uses the stored byte. The name does not independently establish time units or a safe range. |

In particular, writing zero is not a universal reset-to-off operation. The ECG companion resolver defaults on even with zero-filled storage. See [ECG behavior](PROTOCOL_ECG.md) for its startup and independent live/save controls.

## Feature flag inventory

All 25 descriptors use the tri-state representation. Twenty are eligible for named lookup; five are not. Ineligible names are included so an application does not mistake a readable name or historical write bundle for a supported named SET. They may still have an internal role. For entries without a decoded consumer below, polarity, applied default, packet effect and hardware variation remain **unknown**, regardless of how suggestive the name is.

| Feature key | Named lookup | Known meaning / limit |
|---|---|---|
| `general_ab_test` | Ineligible | No public operational value mapping established. |
| `enable_r22_packets` | Eligible | Historical packet 47/layout 22 master: `1` permits, `0` and `2` do not. Internal variants/readiness remain separate. |
| `enable_r22_v2_packets` | Eligible | Consumer maps 1 to true, 0/2 to false; see [version selection](#r22-version-preferences). |
| `enable_r22_v3_packets` | Eligible | Consumer maps 1 to true, 0/2 to false; see [version selection](#r22-version-preferences). |
| `enable_r22_v4_packets` | Eligible | Consumer maps 1 to true, 0/2 to false; see [version selection](#r22-version-preferences). |
| `enable_r22_v5_packets` | Eligible | Consumer maps 1 to true, 0/2 to false; see [version selection](#r22-version-preferences). |
| `enable_r22_v6_packets` | Eligible | Consumer maps 1 to true, 0/2 to false; see [version selection](#r22-version-preferences). |
| `enable_r22_v8_packets` | Eligible | Per-version selector semantics unresolved. |
| `enable_r22_v9_packets` | Eligible | Consumer maps 1 to true, 0/2 to false; see [version selection](#r22-version-preferences). |
| `make_hrfm_visible` | Eligible | Consumer semantics unresolved. |
| `disable_pip_r26_packets` | Eligible | Inverse historical packet 47/layout 26 permission: `1` removes it; `0` and `2` permit it. Producer readiness is additionally required; this is not a global optical stop. |
| `wear_detect_bias` | Eligible | Consumer semantics unresolved. |
| `enable_pdaf_walk_det` | Ineligible | No named SET support established. |
| `enable_maverick_model` | Ineligible | No named SET support established. |
| `hr_ch_switching` | Eligible | Enables one prerequisite of the alternate-source branch reflected in R18 bits 4/5; other input and state conditions also apply. See [source selection](PROTOCOL_SENSORS.md#r18-quality-adjacent-source-selection-bits). |
| `ir_hw_switching` | Eligible | Consumer semantics unresolved. |
| `enable_passive_strap_fit_gen5` | Eligible | Consumer semantics unresolved. |
| `enable_sig11_during_sleep` | Ineligible | Historical bundle inclusion does not establish named SET support here. |
| `dorset_inhibit_wpt` | Eligible | Consumer semantics unresolved. |
| `enable_sig12` | Ineligible | Historical bundle inclusion does not establish named SET support here. |
| `enable_frizzle_burst_mode` | Eligible | Consumer semantics unresolved. |
| `ir_1x_enable` | Eligible | Consumer semantics unresolved. |
| `enable_rocky_again` | Eligible | A change can trigger processing reset/reinitialization during configuration refresh; algorithm and physical effects remain unresolved. |
| `project_drawbridge` | Eligible | Stored 1 enables one side of a conditional gate that can skip normal buffered submission and recall deferred work. Another state condition is required; affected record types remain unresolved. Not a general stream-off or privacy control. |
| `wear_detect_fast_event` | Eligible | Consumer semantics unresolved. |

The historical write of ASCII `2` to the R22 master must not be described as universally enabling R22. In this version it removes that master contribution. Likewise the inverse-named PIP flag must not be presented with the same permission polarity. Consumer truth does not establish emitted variants, and v8 remains outside this mapping; do not guess an all-features bundle. Preserve unknown record variants instead of forcing them through a known decoder.

## Collection, storage and live transport

Requests below are command bodies, excluding the transport envelope. Revision-1 boolean controls take `[1, state]` with `state` 0 or 1; other boolean values are rejected. Live transport and persistent settings are separate from shared session requests; overlapping writers require the ordering rules below.

| Control | Commands | Contract and application effect |
|---|---|---|
| Raw producer start/stop | 81 / 82 | Revision 1 supported; start also has a revision-2 path whose body remains unresolved. Start/stop is separate from live transport and saving. |
| IMU session saving | 105 | Revision-1 boolean; changes a session collection contribution in RAM. It does not write the persistent policy below. |
| IMU live transport | 106 | Revision-1 boolean; controls live IMU delivery independently of saved records. |
| Optical session saving | 107 | Revision-1 boolean; separate RAM collection contribution. |
| Optical live transport | 108 | Revision-1 boolean; independently controls live optical delivery. |
| Persistent optical/R20 policy | 153 | Revision-1 boolean. Wire 0 stores explicit off, wire 1 stores on. Nonvolatile write requested, but ACK does not check programming success. |
| Persistent IMU/R21 policy | 154 | Same persistent policy contract, independent of IMU session saving. |

The two dedicated persistent policies share an option record with LED accessibility (149). If the setter cannot read that record, it writes from defaults before applying the requested option, so other stored options may be replaced. This is separate from the named configuration namespaces below.

The persistent policy resolver treats stored 1 as true and stored 0/2 as false. A missing or invalid record falls back to stored zero; a deployed device may already contain other values. There is no established BLE getter for these two dedicated policies. The durable-write path is distinct from RAM session flags, but observed reboot survival, power-loss atomicity and actual successful programming are not guaranteed by a command acknowledgement.

Raw, individual-sensor and ECG companion controls write shared session requests in event order; they are not independent leases. A later raw stop can clear requests set by another session control. Persistent and continuous sources remain separate contributions. Full downstream hardware application is unresolved; “off acknowledged” is not proof that the sensor is idle. Live transport, saving and producer start/stop each need their own application state. Startup/reset defaults and disconnect behavior are not universally known.

The earlier live-IMU sequence starts raw production before enabling live IMU transport; stopping production and disabling that transport are separate cleanup operations. Its 1,244-byte frame contains 100 six-axis samples. This is a versioned example, not a frame size to hard-code for every record. See [sensor layouts](PROTOCOL_SENSORS.md) and [raw capture operations](RAW_DATA_CAPTURE.md).

## Other sensor configuration

### AFE parameters (61/62)


The request and response structure is 12 bytes, with **no revision prefix**:

| Offset | Width | Field |
|---|---|---|
| 0 | 4 | Channel word, little-endian |
| 4 | 4 | Setting word, little-endian |
| 8 | 4 | Value bits, little-endian: SET input / GET output |

Preserve the complete 32-bit value. Signed display is not proof of a common
physical unit or range: individual settings may normalize nonzero to 1,
truncate to a byte, or run their own validation/conversion. Both commands are
gated by subsystem state. Check the response result before interpreting its
body as readback; failed responses can retain the input words. Successful
readback describes the cached configuration, not proof of analog register
application or reboot persistence. SET queues configuration processing after
dispatch even when dispatch reports an error; its response-refresh read is not
independently checked.

For generic per-channel settings, canonical channel values are 1–6; lookup
uses their low byte. Do not rely on ignored upper bits. The numeric selector
inventory is:

| Setting | Established contract |
|---|---|
| 1–5, 7–12 | Per-channel values with field-specific conversion/validation; physical labels, units and safe ranges unresolved |
| 6, 22 | Unsupported dispatch |
| 13 | Per-channel boolean; nonzero normalizes to 1 |
| 14–19 | The same channel boolean, selecting channels 1,2,4,5,6,3 respectively regardless of the channel word |
| 20 | Per-channel byte value; SET narrows to u8 |
| 21, 23 | Separate global booleans; user-facing functions unresolved |
| 24 | Low-byte selector 0 or 1; stored/readback value remains that selector; physical interpretation unresolved |

Setting zero and other unhandled full-word selectors fail dispatch. These
contracts support encoding and decoding; they do not supply a safe analog
tuning interface or authorize guessing wavelengths, current, gain or defaults.


### Signal-processing configuration (138)

Signal-processing configuration takes revision 1 and a value byte. All byte values receive success; 0–8 select defined presets with unresolved meanings, while 9–255 do not select a new preset. Storage and reconfiguration are still attempted, and success does not prove persistence. See [service contracts](PROTOCOL_COMMANDS.md#ordinary-service-commands).

### Gyro mode (150/152)

Commands 150/152 use revision 1; SET takes a following boolean byte.


Command 150 argument 0 requests gyro disabled and argument 1 requests enabled.
The operating-mode register is written and read back before the cached mode is
updated. FIFO reconfiguration then runs as a separate stage. Command 152
reports whether the cached mode equals the enabled mode; it does not perform a
fresh physical read or validate FIFO configuration.

**A failed SET can already have changed the mode.** If FIFO reconfiguration
fails after the mode write succeeded, the command reports failure while the
cache already contains the new mode. A failure during the earlier mode stage
can also follow a physical write whose readback could not be verified. Read
back after failure and show uncertain application state; neither success nor
failure is an atomic rollback guarantee, and a changed GET does not establish
that the FIFO stage succeeded. Enable/disable events 115/116 are emitted only
after both stages succeed.

A successful initialization path requests the enabled mode, but that is not a
guaranteed final boot state or a user's saved preference. The traced operation
changes sensor registers and cached state. Persistence across reboot, actual
power/sample behavior and later collection-state overrides remain separate.


## Configuration reads — commands 121 and 128

Command 121 reads device configuration; 128 reads feature flags. The request is
revision 1 followed by a 32-byte key. Use at most 31 key bytes plus NUL padding.
Both commands return a **65-byte body**, including failures.

| Offset | Width | Field |
|---:|---:|---|
| 0 | 1 | Revision 1 |
| 1 | 32 | First 31 requested key bytes followed by NUL |
| 33 | 32 | Formatted value, terminated within the field |

On SUCCESS, the value is text: depending on the key's type, it can be `0`, `1`,
`2`, an unsigned decimal integer, or an unsigned decimal with one fractional
digit. No binary value or type tag is present. Key-specific meaning and units
must come from the key's schema.

Unknown keys, reported value-read helper errors and formatting failures return
result 0, the normalized key echo and an all-zero value field. An underlying
checked-storage-slot read failure is different: the loader substitutes zero bytes
and continues successfully. A valid key can therefore return result 1 with a
formatted zero fallback despite such a storage failure. Unsupported request revisions
return result 0 with revision 1 and 64 zero bytes, without a key echo. Accept a
value only after checking result 1 and matching the canonical key. A non-NUL
32-byte key is normalized and therefore will not be echoed exactly.

Enumeration-start commands 115 and 117 use revision 1. Their successful body is
two bytes: revision 1 and a **one-byte entry count**. Invalid revision returns
FAILURE with `01 00`. They reset separate enumeration cursors.

## Collection settings and overlapping controls

`cont_collection_mode=0` removes the continuous collection
request; `1` requests both optical and IMU collection. Other nonzero byte values contribute an optical request without the mode-1 IMU
request and can enter an IMU diagnostic path. They
are not established clean operating modes and should not be exposed as supported
choices merely because storage accepts them.

`max_collection_backlog` expresses a percentage of collection capacity, in tenths
of a percentage point. When a continuous collection check observes a percentage
strictly above the configured threshold, it attempts to store continuous mode
zero. Equality does not trigger that action. A zero threshold can therefore end
continuous collection after backlog becomes nonzero. This does not establish
whether the storage attempt succeeded or when another collection source stops.
Entering or changing to continuous policy can be deferred when backlog is at or
above 0.2%, retaining the previous policy and emitting event 124 with transition
value 4 and reason 3. This is separate from the configurable maximum threshold.

Raw collection, individual optical/IMU session controls and ECG companion raw
collection overlap. They update shared session requests rather than independent
ownership counts. A later raw stop can clear session requests previously set by
ECG companion start or an individual sensor control. Persistent and continuous
requests can still contribute. Serialize overlapping operations, retain the
intended application state, and verify the resulting data flow separately from
command acknowledgments.

Advertising preferences also overlap: the standard heart-rate advertising
preference is considered before the two-HRM-device preference. In these preference
checks, stored 1 selects the named branch; 0 and 2 do not. This does not establish
a guaranteed number of simultaneous client connections.

For the R22 master and selectors v2/v3/v4/v5/v6/v9, the configuration consumer
maps stored 1 to true and 2 to false, with zero selecting false. These values do
not prove any particular packet was emitted. The v8 selector is outside this
verified consumer mapping. The inverse-named PIP flag must retain its separately
documented permission inversion. Do not substitute historical write recipes for
version-specific readback and data-flow checks.

For the described processing consumers, `wear_detect_bias`, `hr_ch_switching`,
`ir_hw_switching`, `enable_frizzle_burst_mode`, `ir_1x_enable`,
`enable_rocky_again` and `wear_detect_fast_event` resolve stored 1 as true and
0/2 or read failure as false. This identifies consumer fallback, not the installed
default or the physiological effect. Changes in `disable_pip_r26_packets` or
`enable_rocky_again` can trigger processing reset/reinitialization during
configuration refresh; an accepted settings write need not leave intermediate
processing state untouched.

A stored zero is a consumer fallback, not a factory reset. No factory value,
reconnect survival or reboot outcome is established by these additions.


## Analog configuration readback

Commands 61 and 62 carry three little-endian u32 words: channel, setting and value.
Successful readback describes cached configuration. It does not confirm that
all physical settings have already been applied.

Settings have distinct numeric behavior:

| Setting | Input and readback behavior |
|---|---|
| 1 | Preserves the full input word. |
| 2 | Stores an input contribution; readback returns that contribution plus setting 3, modulo 2^32. |
| 3 | Preserves its input and also changes setting 2 readback through the sum above. |
| 4, 5 and 7, 8 | Each paired selector's low byte must be 1..4. Validation uses both current selectors. Successful readback preserves the assigned full word. |
| 9, 10 | Inputs 0..5 become 0; 6..11 become 8; 12..23 become 16; all larger u32 values become 32, including values above 64. |
| 11, 12 | Inputs 0..3999 become 0; 4000..11999 become 8000; 12000..19999 become 16000; 20000..48000 become 24000. Larger unsigned inputs fail without replacing the previous field. |

For example, setting 2 input 100 with setting 3 equal to 20 reads back as 120.
Changing setting 3 to 30 changes setting 2 readback to 130. These are numeric
interface rules; physical units and safe tuning values are not established.

Configuration application is deferred and can stop after earlier driver
operations have run. Its pending indicator is cleared before application, so a
cleared indicator does not guarantee success or an automatic retry. Treat
command acceptance, cached readback and complete physical application as separate
states. Preserve uncertainty after an application failure.


## Collection and live-stream coordination

Requested policy selection prioritizes a true persistent preference, then the
shared raw request, then the individual sensor session request, and finally
continuous collection. Contributor counting, active-state transitions and backlog
guards are separate; selected policy does not prove completed physical acquisition.

Raw collection can hold a shared collection request in addition to the individual
optical and motion requests. Turning off an individual request, or stopping ECG
companion collection, therefore does not necessarily stop a running raw session.
Raw stop and raw-session expiry clear the shared raw request and the overlapping
session requests. Persistent collection preferences can still keep collection
requested afterward. Treat the operations as overlapping mutable controls and
reconcile their resulting state.

Live motion output has separate requested and active states. A requested change
is applied later through a driver operation. Failure can leave the previous
active output state in place. Rapidly sending an enable followed by a disable
before application can also leave output enabled despite the last requested
value being disabled. Serialize opposite changes and check actual output; an
acknowledgment or requested-state readback alone does not confirm application.

Cold sensor initialization clears the temporary collection and live-stream
requests in this version. That does not establish which reset
operations execute initialization, whether persistent preferences are reasserted,
or what remains active after a radio disconnect. Loss of notifications is not
evidence that sensing or historical recording stopped. Explicitly reconcile
collection and ECG state after reconnecting.

`enable_r22_packets` gates historical packet 47/layout 22. The inverse
`disable_pip_r26_packets` flag removes historical packet 47/layout 26 publication permission; it is not a global
optical acquisition stop. The latter path also requires producer readiness.
Unresolved experimental settings should remain opaque: names alone do not prove
physical effects, deployed defaults, safe values or support for additional wire
formats.

## R22 version preferences

R22 preparation chooses enabled version preferences in this order:
**9, 6, 5, 4, 3, 2, then 1 as fallback**. The master R22 flag gates preparation
and historical publication separately. Multiple preferences select one path;
they do not request separate output for each enabled version.

Selection does not guarantee the emitted version. Version 3 falls back to 2
when both selected 32-bit input words are zero. This is a value test, not proof
that sensor data is absent. Version 5 falls back to 4 unless its
readiness result is exactly 1. When version 9 selects its queued replay path,
empty queues cause a fallback to version 4; selecting it does not guarantee fresh version-9 output. See
[queued channels](PROTOCOL_SENSORS.md#r22-version-9-queued-channels-and-sample-encoding). Version 8 is not established in this
selection path. Decode the [actual inner version](PROTOCOL_SENSORS.md#r22-inner-version)
and preserve unfamiliar bodies rather than choosing a layout from settings.
