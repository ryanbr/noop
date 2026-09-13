# WHOOP 5/MG ECG protocol

Applicability: [central scope and compatibility](PROTOCOL.md#scope-and-compatibility).

This chapter specifies the ECG interface applicable to the reference baseline.
It complements [the main protocol reference](PROTOCOL.md) and separates the
versioned sensor records from earlier generic “Labrador” payload hypotheses.
A shared firmware version does not guarantee ECG hardware, successful
initialization, or availability on every strap. The complete workflow and physical
waveform calibration have not been validated on hardware for this version.

All offsets below refer to the **complete reassembled format-1 frame**, starting
at its framing byte. Check framing, declared length and both checksums before
reading a record. Multi-byte fields are little-endian unless explicitly stated.

## Commands and independent output gates

Payloads start at the command revision byte, after the command envelope. Every
command in this table requires revision `01`. Response result `1` means success;
`0` means failure. Success reports command handling, not completed measurement.

| Decimal / hex | Operation | Payload | Contract |
|---|---|---|---|
| 123 / 7B | Select wrist | `01 01` right; `01 02` left | Other wrist arguments fail. A valid argument can still fail when the ECG subsystem is not in the required state. |
| 124 / 7C | Generation control | `01 01` stop; `01 02` start | Queues generation control. Argument `03` also selects the start operation; a distinct restart behavior is not established. Zero and other arguments fail. |
| 125 / 7D | Save raw ECG | `01 00` off; `01 01` on | Independently gates raw historical output. |
| 126 / 7E | Send raw ECG live | `01 00` off; `01 01` on | Independently gates raw live output. |
| 127 / 7F | Save filtered ECG | `01 00` off; `01 01` on | Independently gates filtered historical output. |
| 139 / 8B | Send filtered ECG live | `01 00` off; `01 01` on | Independently gates filtered live output. |

The four output toggles accept only arguments zero and one. Generation control
and these toggles can be rejected by a hardware compatibility guard; passing that
guard does not satisfy every initialization prerequisite. Wrist selection has a
separate subsystem-state condition. It updates the active in-memory selection;
retention across reboot is **not established**. Do not encode right/left as zero/one
on this version or promise a persistent selection.

Generation and output are distinct. An enabled live gate does not start the ECG
front end. A start ACK precedes fallible initialization and conversion setup, so it
does not demonstrate that samples are being generated. Save controls and live
controls do not substitute for one another.

The device setting `enable_raw_data_w_ecg` controls **accompanying historical
optical and IMU requests**, after ECG startup succeeds. It is not a master ECG
permission. Its stored values resolve as `1 = true`, `2 = false`, and `0 = true`;
its unavailable/read-failure fallback is also true. Successful ECG generation can
continue when the setting is false. Stopping ECG requests companion shutdown only while its bookkeeping still records
those requests. Repeated starts can discard that bookkeeping; see the lifecycle
condition below. A raw session can still retain its separate shared request. This interaction matters if the app also manages
optical/IMU collection independently: these controls write shared session requests in event order, so a later raw stop can clear ECG companion requests. Persistent and continuous sources can still contribute. A stored setting, an ACK and effective
collection are different states.

A client should select and acknowledge the intended wrist before start, choose its live/save outputs explicitly,
request generation, and then require valid revision-specific records before
reporting waveform reception. There is no established universally successful
ordering that removes the wrist subsystem prerequisite. Report wrist refusal,
start refusal, acknowledged start without data, and received records separately.
During cleanup stop generation and disable the output gates enabled by the session.
Do not equate silence with absent electrode contact or a completed session.

## Repeated ECG start and companion collection

For command 124 revision 1, both arguments 2 and 3 request ECG startup. Neither is
an idempotent ensure-running operation. When accompanying optical/IMU collection
was enabled by an earlier successful ECG start, another start can discard the
bookkeeping used to turn those companion requests off. This can happen if the
new initialization fails, or if it succeeds with the companion option now off.
A subsequent ECG stop can then omit its usual companion-off requests.

Serialize ECG session transitions and resolve the previous session before
starting another. Reconcile shared raw/optical/IMU requests as part of the app's
session management; those controls do not provide independent ownership leases.
A stop response does not establish that all queued sensor changes have completed.
This ordering condition does not establish ongoing physical acquisition or a
particular power effect.

Connection establishment does not acknowledge restored ECG or sensor sessions.
In particular, do not implement reconnect by blindly resending ECG start.

## Routing and shared header

Both raw and filtered records can use either transport:

| Packet type at byte 8 | Layout at byte 9 | Meaning | Full length |
|---|---|---|---:|
| 43 | 16 | Live raw ECG | 1,584 |
| 43 | 17 | Live filtered ECG | 240 |
| 47 | 16 | Historical raw ECG | 1,584 |
| 47 | 17 | Historical filtered ECG | 240 |

Type 43 alone is insufficient to choose a decoder. These records use byte 9 as
a layout selector and byte 10 as sensor flags, **not** a command sequence and
command number. Keep other type-43 shapes separate.

| Offset | Width | Field |
|---:|---:|---|
| 8 | 1 | Packet type |
| 9 | 1 | Layout 16 or 17 |
| 10 | 1 | Common sensor flags; meaning unresolved |
| 11 | 4 | Shared record sequence |
| 15 | 4 | Timestamp main word |
| 19 | 2 | Additional timestamp word |
| 21 | 13 | Packed status and count, detailed below |

Timestamp units and a session-identifier interpretation are not established for
these ECG fields. Multiple outputs from the same acquisition pass can share
sequence and timestamp. Do not globally deduplicate raw/filtered or live/historical
records solely by that pair.

## Packed status: bytes 21–33

This is a **13-byte packed region**, not a 17-byte structure of unpacked booleans.
Preserve unknown codes and raw bytes alongside any derived presentation.

The described quality handler produces numeric codes 0–3. Reset clears presence
and quality; later transitions can set presence with quality 1, then quality 2 or
3. Another transition clears both. These are partial state-machine outcomes, not
an exhaustive enum or a bad/good/excellent scale. Keep presence separate from
clinical signal quality and preserve unknown codes.

In the described quality-input path, consecutive nonzero per-input flags increment
an unsigned counter capped at 65535; zero resets that run counter. Once the count
exceeds 100, it submits a transition input that, from the quality handler's state
0, sets presence and quality to 1. These counts are processed input entries, not
milliseconds. Later checks in the same iteration can submit further inputs, so
this does not guarantee the next transmitted status or readiness. The handler's
internal state 0 is distinct from the wire classifier fields below; nonzero flags
are not an established electrical-contact or clinical-quality classification.

| Offset | Width | Meaning and limitation |
|---:|---:|---|
| 21 | 1 | Quality code; thresholds and vocabulary unresolved |
| 22 | 1 | State-transition/presence bits described below |
| 23 | 1 | Classifier result code; no established diagnostic interpretation |
| 24 | 1 | Classifier state code |
| 25 | 1 | Progress value; percentage-like, complete range/termination contract unresolved |
| 26 | 1 | Four independent booleans packed into bits 0–3; individual names unresolved |
| 27 | 1 | HR-related classifier value; average/current distinction unresolved |
| 28 | 1 | Additional HR-related value for R17; **zero placeholder for R16** |
| 29 | 2 | Additional HRV-related value; units unresolved |
| 31 | 1 | Zero placeholder in this version; not a measured stress value |
| 32 | 2 | Declared waveform sample count |

Byte 22 encodes the following state relationship:

- Bit 1 is set when the current classifier state equals 1.
- Bit 0 is additionally set when that state is entered from a previous state other
  than 1.
- Bit 2 is set when state 2 follows state 1.
- Bit 3 carries the presence indication.

These are state codes, not established clinical states. Presence and quality
metadata can be transmitted; do not describe lead information as universally
absent from ECG records. Presence does not establish electrode acceptance,
clinical signal quality or a diagnosis. Contact thresholds, debounce behavior and
wall-clock settling time remain unknown. Counted-zero settling can be extended by subsequent inputs; no fixed wait establishes readiness.

## R17 filtered waveform

The frame length is exactly **240 bytes**:

| Region | Encoding |
|---|---|
| 0–33 | Envelope, shared header and status |
| 34–233 | **100 two-byte sample slots** |
| 234–235 | Two zero alignment bytes; never a waveform sample |
| 236–239 | CRC32 over bytes `[8,236)` |

The declared count at 32 is separate from the fixed storage capacity. Accept only
a count within the 100-slot capacity for ordinary decoding; reject or quarantine
larger counts as anomalies. Do not silently truncate them. Read only the declared
number of samples, even though every frame reserves all 100 slots. Zero-valued
samples can be meaningful; nonzero detection is not a substitute for the count.

these slots contain **signed i16 little-endian**
values. Physical scale remains unresolved; signed numerical representation does
not supply a voltage calibration. A gating condition can deliberately insert
zero-valued samples into the output queue. Counted zeros therefore remain entries
and must not be discarded as padding or used alone to conclude that generation
stopped. Do not assume that the final conversion guarantees a saturating amplitude
clamp.

Do not read `[34,236)` as 101 samples: its last word is alignment, not data.
Sample capacity and notification cadence do not establish the sample rate.

### Output ratio and conditional count bound

The standard startup configuration emits one filtered queue value per five
processed input samples. This is a count ratio, not an independently established
sample rate. With at most 500 accepted raw inputs per update, normal grouping
state and an empty output queue before that update, at most 100 filtered entries
are produced. This bound assumes no concurrent or intervening configuration change.

The retrieval queue nevertheless has 250 slots and no final 100-entry clamp.
Backlog, alternate configuration and other scheduling states are not covered by
that conditional bound. Continue rejecting or quarantining a declared R17 count
above 100. The normal-path explanation does not enlarge the frame's capacity or
justify silently truncating an anomalous count.

## R16 raw waveform and lead diagnostics

The frame length is exactly **1,584 bytes**:

| Offset / range | Encoding |
|---|---|
| 32–33 | u16 declared waveform count; capacity 500 |
| 34–1533 | **500 fixed slots of three bytes each** |
| 1534 | Lead-off diagnostic count, one byte |
| 1535–1556 | 11 fixed I-channel halfwords |
| 1557–1578 | 11 fixed Q-channel halfwords |
| 1579 | Zero alignment byte |
| 1580–1583 | CRC32 over bytes `[8,1580)` |

The status map matches R17 except byte 28 remains zero. Fixed regions do not move
when either count is smaller. In particular, a variable formula based on
`header + count × width` will locate the lead arrays incorrectly. Treat waveform
counts above 500 or diagnostic counts above the available 11 slots as anomalies;
never read outside those capacities. Exact diagnostic count/timing invariants are
not established.

For the three bytes `b0, b1, b2` of each waveform slot, the independently expressed
wire decoding rule is:

```text
raw18 = ((b0 & 0x03) << 16) | (b1 << 8) | b2
flag6 = (b0 >> 6) & 1
flag7 = (b0 >> 7) & 1
```

This is an 18-bit payload plus flags, not little-endian i16 and not a signed 24-bit
sample. Retain bits 2–5 as uninterpreted reserved bits. the waveform uses **signed two's-complement 18-bit coding**: after reconstructing
`raw18`, values below 131072 remain unchanged; values at or above 131072 subtract
262144. The numerical range is **−131072 through 131071**. Keep flag bits 6/7
separate; they are not sign bits. This establishes coding, not volts per count.

Flag 6 is supplied per sample. Flag 7 comes from a slower contact/lead-state stream,
so its timing must not be treated as an independently sampled 500-entry contact
channel. When the slower array's count is ten, the grouping divisor is derived
from raw sample count divided by ten. For the specific **500 raw / 10 slower**
case, the boundary sample uses the earlier flag before the index advances:

| Slower entry | Raw sample indices using its flag |
|---:|---|
| 0 | 0–50 |
| 1 | 51–100 |
| 2–8 | 101–150 through 401–450, respectively |
| 9 | 451–499 |

The group sizes are 51, eight groups of 50, and 49. Do not substitute ten equal
50-sample groups. This relates transmitted indices, not independently established
electrical measurement times. Other partial-buffer invariants remain unresolved.
A zero slower count omits flag-7 insertion; nonzero counts other than ten are not
established as ordinary supported input to this grouping rule.

The I/Q halfwords have a signed diagnostic interpretation but no established
physical units. Preserve raw words as well as an optional signed view. Do not use
their sign or magnitude as a clinical threshold.

## Decoder and session requirements

An implementation integrating this contract needs:

1. Version-aware wrist encoding and explicit support for all four live/save gates.
2. Packet type **and** layout selection, exact frame size, checksum checks and count
   bounds before sample extraction.
3. Separate R16/R17 status parsers, fixed capacities and padding handling; no
   fallback to the generic 17-byte Labrador header for these revisions.
4. Raw values retained for unknown enum codes, flag semantics, waveform units and
   timestamp fields. No medical label inferred from a classifier field name.
5. Distinct session outcomes for command failure, acknowledged initialization,
   waveform reception and stop/cleanup. Status changes alone are not samples.

NOOP's earlier right/left zero/one mapping, 101-halfword filtered slice, and generic
count-based raw payload interpretation are incompatible with these versioned
contracts. This document specifies the required behavior; it does not assert that
all application paths already implement it.

Still unresolved are physical voltage scale, raw/filtered rates, an unconditional
valid runtime filtered-count bound, complete hardware prerequisites, contact acceptance,
classifier-code semantics and clinical validity. Neither 500 raw slots nor 100
filtered slots establishes a rate, and no fixed session duration is established.

## Constructed parser checks

Run `python3 docs/protocol-examples/validate_examples.py` from the repository root.
The [standalone example](protocol-examples/validate_examples.py) checks R17 count
bounds and padding exclusion, signed i16/i18 edge cases, raw18/flag separation and
the specified 500/10 contact-index boundaries using constructed values. Its buffers
deliberately have no valid transport framing or checksums. These checks exercise
the documented arithmetic; they do not independently validate device behavior,
NOOP integration, the universal filtered-count bound or physical calibration.


## Startup, settling and interpretation

Select the intended wrist and check the command response before starting ECG
generation. A successful wrist response confirms acceptance of the selection;
it does not establish immediate hardware application or persistence across reboot.
A wrist change during an active session should not be presented as immediately
applied without separate confirmation.

Control live output, historical saving and generation independently. A start
acknowledgement confirms that the request was accepted for processing. Confirm
actual generation using validated revision-specific ECG records and their declared
sample counts. Command refusal, no incoming records, valid zero-valued samples and
status changes are distinct observations.

Valid counted samples can be zero during initial settling or later signal
rejection. The standard startup gate begins at 179 processed-input iterations. With the
normal initial selection phase and no extension, the first 36 selected outputs
are counted zeros and the next selected output is at input 181. These conditional
counts are not milliseconds or a guaranteed startup waveform. Settling can be
extended by subsequent input conditions. A zero per-input flag proposes 930
remaining processed-input iterations; an input at or below the configured signed
lower bound, or at or above the upper bound, proposes 680; an absolute step at or
above its configured threshold proposes 280. A candidate
replaces the remaining count only when larger. Other holdoffs control which checks
run, and these checks precede the block output-loop countdown. These are processing
counts, not milliseconds or electrode/clinical thresholds. Do not infer
readiness from a fixed delay, or classify a session solely from a flat waveform.
Preserve numeric quality, presence, state and classifier fields; their clinical
meaning is not established here. Preserve unknown values for later interpretation.

Use sample-index axes and uncalibrated amplitude unless rate and scale have been
independently established for the applicable configuration. Fixed record capacity
and the number of notifications do not establish absolute sampling rate. Retain
out-of-capacity counts as anomalies. During cleanup, stop generation and disable
the live/save gates enabled for the session.

A calibration also requires the effective clock, gain and reference configuration
and the complete conversion from input codes through processing to output values.
Register definitions alone would not establish that chain. Buffer capacity is not
a sample frequency, and numerical scaling constants alone do not identify volts.

## Front-end application and calibration boundary

ECG initialization attempts front-end register writes and compares readback bytes.
That comparison does not check every underlying transport return status. Software
initialization success or a cached configuration value therefore does not prove
that all requested hardware settings took effect. A frame-divider change writes
two ordered bytes and can fail partway through.

The numerical divider, FIFO count and one-in-five filtered selection do not
establish absolute sample frequency or voltage scale. FIFO items can have
different tags; an item count is not necessarily an ECG-only sample count. Use
sample index and native amplitude unless a matching calibration is available.
