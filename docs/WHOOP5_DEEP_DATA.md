# WHOOP 5.0 / MG deep-data experiment and historical observations


<a id="the-problem"></a>
<a id="why--the-feature-flag-gate"></a>

## Collection and output

Historical type-47 delivery without configuration writes was observed in
[goose #24](https://github.com/b-nnett/goose/issues/24). Collection, storage and
packet output are separate controls; use the [configuration reference](PROTOCOL_CONFIGURATION.md)
for the current contract and per-key polarity. R22 has an [inner record version](PROTOCOL_SENSORS.md#r22-inner-version),
not a hardware revision. Sensor identity and physiological interpretation remain
separate from structural decoding.

<a id="channel-layout-50--mg"></a>
<a id="the-frame-format"></a>

## Connection and framing

Use the [WHOOP 5 connection profile](PROTOCOL_WHOOP5.md) and
[format-1 framing](PROTOCOL_TRANSPORT.md#format-1-framing).

<a id="the-enable-sequence-whoop5config"></a>
<a id="how-noop-uses-it-opt-in-reversible"></a>

## Configuration interface

Use the complete [named configuration body](PROTOCOL_CONFIGURATION.md#named-configuration-interface)
and [feature inventory](PROTOCOL_CONFIGURATION.md#feature-flag-inventory).
The older NOOP encoder uses a 40-byte key/value block after its revision byte;
that client implementation is not the current 65-byte semantic request contract.
Acceptance of truncated bodies remains unresolved. This page supplies no bulk
“unlock” recipe.

## Console record sequencing and text reassembly

WHOOP 5 console records (type 50) carry a **wrapping u8 sequence at frame byte 9**. The Swift
decoder exposes `console_sequence` and the separate raw `console_header_byte_10`. The previous
`record_index` u16 interpretation is removed: on firmware **50.41.1.0**, 2,978 CRC-valid records
from a ten-hour night kept byte 10 at 2, including nine captured 255 → 0 wraps. Reading those
two bytes together produces 767 → 512, not a monotonic record counter.

Reconstruct text in received order within the same capture, link, characteristic and console
channel. Check sequence continuity modulo 256. Captured EVENT records can occupy intervening
positions; realtime, historical and metadata records have separate sequence meanings and can be
interleaved. Do not bridge an unexplained sequence gap or an invalid frame. Batch timestamps are
not exact computation times. This reconstruction recovered the complete firmware message
`generated a valid SPO2 during sleep`; it contains no numeric oxygen result and does not validate
the byte-82 candidate. Raw captures remain private; tests use synthetic wrap headers.

**Platform scope:** this investigation is explicitly limited to macOS and the shared Swift core.
The Android console decoder and its parity vectors are therefore deferred; Android still exposes
the incorrect u16 `record_index`. This is a deliberate scope limit, not a
cross-platform parity claim. Update the Kotlin twin and matching wrap/header vectors before
including this correction in a cross-platform release.

## Existing public sources

These sources contributed earlier protocol observations and client work:

- [judes.club — Cracking the WHOOP 5 Bluetooth Protocol](https://judes.club/writing/cracking-the-whoop-5-bluetooth-protocol/)
  and its [interactive specification](https://judes.club/experiments/whoop5/).
- [Asherlc/dofek protocol notes](https://github.com/Asherlc/dofek/blob/main/docs/whoop-ble-protocol.md).
- The community Bluetooth capture in [#103](https://github.com/ryanbr/noop/issues/103).

## High-rate IMU capture is a separate switch

NOOP’s raw IMU workflow uses command 81 followed by command 106 with `[1,1]`;
stop uses command 82 followed by command 106 with `[1,0]`. Requests, effective
collection state and packet delivery are separate; see the
[collection controls](PROTOCOL_CONFIGURATION.md#collection-and-live-stream-coordination)
and [R21 layout](PROTOCOL_SENSORS.md#r21-six-axis-imu).

## Honest limits

- **Measurements are not product scores.** NOOP computes its own metrics from
  the available records; decoded measurements do not reproduce WHOOP recovery,
  strain or sleep scores by themselves.
- **The large records are no longer an undifferentiated type-`0x2F` blob.** Layout v21 (1,244 bytes)
  contains six-axis IMU data; layout v20 (2,140 bytes) contains five repeated measurement blocks whose
  producer is optical; layout v26 contains a [compact optical window](PROTOCOL_SENSORS.md#r26-compact-optical-window).
  Optical producer identity does not establish wavelength labels or calibrated units.


## SpO₂ and respiration interpretation limits

The documented WHOOP 5 optical layouts do not establish calibrated SpO₂ or a raw
respiration waveform. Keep R18 byte 82 uninterpreted; see the
[sensor reference](PROTOCOL_SENSORS.md#r18-biometric-summary). NOOP’s candidate
validation tools are research instrumentation, not a source of validated health metrics.

### Comparison tool

`Tools/linux-capture/validate_spo2_candidate.py` compares raw-byte observations
with imported values. Its thresholds are research-tool policy, not proof of a
physiological field or calibration.

```bash
cd Tools/linux-capture
python3 validate_spo2_candidate.py capture.json my_whoop_data/ --device strap-a --postable
python3 validate_spo2_candidate.py --batch devices.json --postable
```

## Mapping the layout — ground-truth correlation

An HCI capture on its own is a pile of un-labelled bytes. The fast way to label them is *known
plaintext*: a tester's own **WHOOP data export** (app.whoop.com → Data Export) lists the official
per-night values — HRV, resting HR, skin temperature, SpO₂, respiratory rate — for exactly the nights
in the capture. Searching each record type for the byte offset + encoding that reproduces those known
values across every night pins the field without guesswork.

Three stdlib tools in [`Tools/linux-capture/`](../Tools/linux-capture/) do this:

- **`hci_extract.py`** converts a phone HCI log (iOS `.pklg` / Android `btsnoop_hci.log`) of the
  official app into the project's `capture.json` frame format — so an official-app full-sync capture
  feeds the same decoder as a Linux capture. It keeps only CRC-valid WHOOP frames.
- **`correlate_ground_truth.py`** cross-references those frames against the CSV export and reports
  candidate `(record type, offset, encoding, scale)` tuples, requiring both breadth and a
  distribution match so constants and coincidences don't score. English export headers (e.g.
  `Blood oxygen %`) map to the same canonical keys as DE/ES.
- **`validate_spo2_candidate.py`** is the SpO₂-specific multi-device harness for `@82` (nightly mean
  vs export, checklist, postable summary) — see above.

Crucially this is **privacy-preserving**: both tools run locally and the correlation output is only
offsets/encodings, never health values — so a 5/MG owner can contribute a confirmed field mapping to
[#103](https://github.com/ryanbr/noop/issues/103) without posting their capture or their data export.
A mapped offset still follows the project rule — *real captures, never invented offsets* — before it
lands in `parseFrameWhoop5` / `whoop_protocol.json`.

## How to help (5.0 / MG owners)

The [comparison tool](#comparison-tool) can compare an existing history capture
and data export locally. Inspect its output before sharing results; its checks
do not establish physiological field identity.

Credit to **judes.club**, **Asherlc/dofek**, and **b-nnett/goose** for the public protocol work this
builds on.
