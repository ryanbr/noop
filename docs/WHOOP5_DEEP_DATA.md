# WHOOP 5.0 / MG deep-data experiment and historical observations

**Scope:** [historical experiment](PROTOCOL.md#scope-and-compatibility), opt-in. Deep-history delivery and v20/v21/v26 structural layouts are
confirmed on hardware; wavelength identity and product-grade optical ingestion remain open.
**Tracking:** [#103](https://github.com/ryanbr/noop/issues/103) (raw HCI captures + new deep-record layouts).

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

The [WHOOP 5/MG profile](PROTOCOL_WHOOP5.md) defines the GATT channels;
[transport](PROTOCOL_TRANSPORT.md) defines the frame and response handling.
NOOP subscribes to the four custom notification channels and standard HR.
The earlier capture experiment used writes with response and observed
write-no-response being dropped.

<a id="the-enable-sequence-whoop5config"></a>
<a id="how-noop-uses-it-opt-in-reversible"></a>

## Configuration interface

Use the complete [named configuration body](PROTOCOL_CONFIGURATION.md#named-configuration-interface)
and [feature inventory](PROTOCOL_CONFIGURATION.md#feature-flag-inventory).
The older NOOP encoder uses a 40-byte key/value block after its revision byte;
that client implementation is not the current 65-byte semantic request contract.
Acceptance of truncated bodies remains unresolved. This page supplies no bulk
“unlock” recipe.

## Existing public sources

These sources contributed earlier protocol observations and client work:

- [judes.club — Cracking the WHOOP 5 Bluetooth Protocol](https://judes.club/writing/cracking-the-whoop-5-bluetooth-protocol/)
  and its [interactive specification](https://judes.club/experiments/whoop5/).
- [Asherlc/dofek protocol notes](https://github.com/Asherlc/dofek/blob/main/docs/whoop-ble-protocol.md).
- The community Bluetooth capture in [#103](https://github.com/ryanbr/noop/issues/103).

## High-rate IMU capture is a separate switch

The R22 feature flags above govern deep-history products; they are not the missing step for an explicit
100 Hz motion session. Hardware testing found a separate bounded raw-data sequence: `START_RAW_DATA`
(81) must precede the two-byte 5/MG `TOGGLE_IMU_MODE` (106) selector. Sending 106 alone can return
`SUCCESS` while producing no packets. With `[0x01, 0x01]` after command 81, NOOP receives and decodes
the six-axis 100 Hz buffers; stop uses command 82 followed by `[0x01, 0x00]`.

This establishes an on-demand research/workout capture path, not a safe continuous mode. Battery,
retention, and BLE-airtime cost over day-scale recording remain unmeasured. The session collector,
file-backed storage, Bluetooth-gap repair, and export contract are documented in
[5/MG raw data capture](RAW_DATA_CAPTURE.md).

## Honest limits

- **Measurements are not product scores.** NOOP computes its own metrics from
  the available records; decoded measurements do not reproduce WHOOP recovery,
  strain or sleep scores by themselves.
- **The large records are no longer an undifferentiated type-`0x2F` blob.** Layout v21 (1,244 bytes)
  contains six-axis IMU data; layout v20 (2,140 bytes) contains five repeated measurement blocks whose
  sensor identity remains open; layout v26 contains a [compact optical window](PROTOCOL_SENSORS.md#r26-compact-optical-window). The v20 blocks are
  preserved without optical/wavelength labels because the current capture does not prove what produced
  them, let alone red/IR identity.
- **SpO₂ is not “one calibration away.”** The current v20 corpus has three active measurement blocks,
  but it has not established two separate red and infrared illumination measurements. See
  [`WHOOP5_OPTICAL_EXPERIMENT.md`](WHOOP5_OPTICAL_EXPERIMENT.md) for the passive controlled experiment
  that must precede reference-oximeter calibration.
- **Blood pressure is not a decode target yet.** No hidden BP scalar has been identified. BP would
  require a validated model, reference-cuff data, population calibration, and an explicitly
  non-medical product boundary after the underlying optical/motion channels are established.

## Why SpO₂ (and the raw respiration track) aren't available on 5.0

This is the single most common "is it broken?" report (e.g. [#623](https://github.com/ryanbr/noop/issues/623)),
so the reasoning in one place:

**It is not an encryption problem.** The 5.0 (v18) record is available in plaintext, with mapped HR, R-R,
motion/rest and thermal fields alongside unresolved raw values. Nothing on the wire is hidden behind a cipher NOOP would need a key
for. Interpreting the available data as SpO₂ remains unresolved:

- **No *confirmed* SpO₂ field on the 5.0 wire — but there is now a candidate.** The raw optical tail
  (`@106` baseline, `@108/@109` amplitude pair, `@113` float) was checked against WHOOP-app SpO₂ across
  18,602 real records — it does not match; those channels track HR/motion, and there is no identifiable
  red/IR pair in that comparison. The documented optical metadata does not identify a
  usable red/IR pair or establish a calibrated SpO₂ derivation; see the
  [R26 reference](PROTOCOL_SENSORS.md#r26-compact-optical-window). However, a decompile-sourced decode
  ([#103](https://github.com/ryanbr/noop/issues/103)) interprets v18 byte `@82` as a **candidate SpO₂ scalar**
  (a sleep-only 70–100 gate with proposed sentinel/diagnostic modes outside that range).
  Those physiological and diagnostic meanings remain unvalidated; the
  [canonical R18 reference](PROTOCOL_SENSORS.md#r18-biometric-summary) preserves the byte raw. The evidence is currently **split**: an 8-night independent validation with real spread
  (corr +0.99, ~0.4 %/night) clears the cross-night bar, but the two nights checked on the original #103
  capture device moved *opposite* to the app value — unresolved device/firmware variance or an extraction
  error on one side. NOOP therefore decodes `@82` as `spo2_candidate_82` (deep-timeline instrumentation
  only, in-band values only) so more devices can correlate it against the app's nightly SpO₂; it does
  **not** populate `spo2Pct` or any card/score until the contradiction is resolved.
- **A calibrated % needs WHOOP's proprietary curve.** Even where raw optical exists, turning a red/IR
  ratio into a real SpO₂ % requires a device-specific calibration NOOP does not have — and NOOP will not
  fabricate one from unvalidated optical (the withdrawn #194 PPG→HR estimate is the cautionary
  precedent). `spo2Pct` is therefore nulled for *every* WHOOP; only an import writes it.

**WHOOP 4.0 differs.** The 4.0 **v24** historical layout *does* bank raw SpO₂ channels (`spo2_red@68` /
`spo2_ir@70`), so NOOP decodes the raw red/IR there (still not a calibrated %). The 5.0's v18 layout
dropped those channels — the location of a calibrated product value is not established by those missing channels. NOOP reverse-engineers what the strap actually sends; if a
decodable SpO₂ isn't sent, there is nothing to decode, plaintext or not.

**Respiration is a partial exception.** The 5.0 sends no raw respiration ADC stream either (also
4.0-v24-only), so the deep-timeline *track* is empty — but respiration is still estimated on-device from
the R-R interval stream (RSA) and shown on the Health screen when enough overnight R-R is captured.

**To see SpO₂ in NOOP on a 5.0:** import it. A WHOOP data export carries `blood_oxygen_pct`, and Health
Connect import works too — both populate the Blood Oxygen card with WHOOP's own computed values.

**Could it ever change?** Only via research, not decryption — and the `@82` candidate above is exactly
that research in progress. What would flip it to a real reading: the `spo2_candidate_82` nightly values
tracking the WHOOP app's own SpO₂ across many nights on **multiple devices** (a varying signal, not one
coincidental match), including on the device where the two checked nights currently move opposite.
Until that clears the bar, NOOP keeps SpO₂ import-only on the 5.0.

Wire-level facts (no SpO₂ opcode, export vs on-device aggregation, sleep-only product) are also summarised
in [`PROTOCOL.md` §10](PROTOCOL.md#10-spo₂-on-50--mg--what-the-wire-does-and-does-not-carry). This section
keeps the **promotion bar** and the harness that measures it.

### `@82` validation checklist (what would promote the candidate)

Only research — never a silent UI flip. A promote of `spo2_candidate_82` → `spo2Pct` needs all of:

1. **Multiple devices / firmwares** (not one lucky strap): the nightly aggregate of in-band (70–100)
   `@82` samples during `sleep_state = asleep` tracks the official app or CSV `blood_oxygen_pct` with
   real night-to-night spread (not a flat 98 %).
2. **Offset specificity:** nearby bytes (the 74–92 scan the harness already runs) must *not* track
   better than `@82`.
3. **Incomplete nights:** when the export omits SpO₂, the wire candidate should be empty or
   out-of-band — not invent a number. This is a falsification test: an "always 97 %" decoder fails it.
4. **Resolution of the #103 contradiction** on the original capture device (or a documented
   extraction / phase / duty-cycle error on one side).
5. **No recovery / illness gating** on the candidate until (1)–(4) clear — same rule as other
   derived biosignals.

The multi-device tool below implements the **measurable** half of this list: default gates include
≥5 paired nights, export range ≥1 %, r ≥ 0.7, MAE ≤ 1.0, best offset = 82, in-band value variance,
and duty-window coverage (with `feature_absent` when a long-enough asleep capture never emits `@82`).
Points 4–5 stay human judgment on [#103](https://github.com/ryanbr/noop/issues/103).

Until that bar is met, SpO₂ stays **import-only** on the 5.0, with `@82` available as instrumentation
for owners who opt into deep-timeline / experimental logging.

Related capability / UX roadmap: [#761](https://github.com/ryanbr/noop/issues/761) (honest labels when
SpO₂ / skin temp / stages are unavailable vs experimental).

### Band sleep flag vs hypnogram (quick reference)

Use the authoritative [R18 motion/rest-state contract](PROTOCOL_SENSORS.md#motionrest-state-and-override)
for the two-bit field, independent neighboring bits and override limits. Band state
is not a validated hypnogram or unconditional physiological sleep measurement.
The correlation tooling below uses NOOP’s `sleep_state` interpretation; its
historical results do not remove those decoding and validation limits.

### Multi-device validation tool (`validate_spo2_candidate.py`)

To make that bar concrete and privacy-preserving, `Tools/linux-capture/validate_spo2_candidate.py`
turns one or more `(capture.json, WHOOP export)` pairs into a promote checklist:

```bash
cd Tools/linux-capture
python3 validate_spo2_candidate.py capture.json my_whoop_data/ --device strap-a --postable
python3 validate_spo2_candidate.py --batch devices.json --postable
```

Per device it computes the **nightly aggregate** of in-band `@82` samples (70–100) while
`sleep_state = asleep`, pairs each night with CSV `blood_oxygen_pct`, then reports Pearson **r**,
MAE, bias, and an **offset-specificity** scan over bytes 74–92 (only `@82` should win). Default
gates: ≥5 paired nights, export range ≥1 %, r ≥ 0.7, MAE ≤ 1.0, best offset = 82, ≥5 distinct
in-band values at `@82`, and ≥50 % duty-window coverage.

**`@82` is duty-cycled**, which the harness has to account for or its numbers are meaningless.
Across 18,650 v18 records — 18,602 from [@digitalerdude](https://github.com/digitalerdude)'s public
PacketLogger capture of an official-app overnight sync, plus 48 from a NOOP sync — the byte is
nonzero in 450 records (2.4 %), in 15 runs of *exactly* 30 records each, every run starting at the
same `unix % 1200` with zero phase variance; outside the window it is identically `0x00`. A capture
not aligned to that phase reads all zeros and is indistinguishable from a strap with the feature off
— a plausible contributor to the split evidence above. The tool therefore **detects** the period,
phase and window length per capture (never assuming the phase generalises across firmware),
aggregates one value **per window** rather than per second, and reports per-night window coverage
with a loud warning below the floor. A strap whose `@82` is flat `0x00` across a long enough capture
is classified **`feature_absent`** — neither a PASS nor a FAIL in the multi-device gate.

That absence claim is gated on the capture having actually **watched** the strap — long enough, and
finely enough, that a duty-cycled feature would have fired somewhere the capture could see it. Both
halves fail the same way if you get them wrong, reporting a working strap as lacking the feature:

- **Long enough is observed time, not wall-clock span.** `max − min` counts the gaps, so a capture
  that ran densely for two minutes and then logged one record eight hours later scores an 8 h "span"
  off 121 s of observation. Sleep samples × cadence is what was watched, and that is what the bar uses.
- **Finely enough is a nominal 30 s window.** Missing the window is a phase problem, not a duration
  one — a cadence sharing a large factor with the period only ever occupies `period ÷ gcd` residues,
  so at 300 s against 1200 s it either always lands inside the window or never does. Six nights of
  scored sleep then read a flat `0x00` off a perfectly healthy strap.

A capture failing either test stays a plain FAIL and the duty line says why. The conservative
direction matters here: `feature_absent` *removes* a device from the gate, so over-claiming absence
would make promotion easier, not harder.

`--postable` prints a CSV-ish block with **no raw SpO₂ values** — safe to paste on
[#103](https://github.com/ryanbr/noop/issues/103). Promote `spo2_candidate_82` → `spo2Pct` only when
**≥2 devices** each PASS (the tool's multi-device footer tracks that). This does **not** change app
metrics by itself; it is the research harness for the split-evidence problem above.

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

For the SpO₂ candidate, the [validation checklist](#82-validation-checklist-what-would-promote-the-candidate)
requires multiple devices and resolution of the conflicting observations. The
local tools above can compare an existing history capture and data export without
publishing raw health data. Share only the postable aggregate result when
contributing to [#103](https://github.com/ryanbr/noop/issues/103).

Credit to **judes.club**, **Asherlc/dofek**, and **b-nnett/goose** for the public protocol work this
builds on.
