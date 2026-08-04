# WHOOP 5/MG optical block experiment

**Status:** passive capture and offline comparison implemented. No labelled run has been analysed yet
— the harness exists so one can be. Related: #423 (the 5/MG high-rate offload thread this came out
of), #858 (the capture request), #845 (the field inventory that names the open questions).

## Purpose

The 2,140-byte layout-v20 record is structurally decoded as five repeated measurement blocks. Each
block has one 21-byte header, two 200-byte readout slots, and one reserved byte. The existing corpus
always has sample counts `[25, 0, 0, 25, 25]`, so blocks 1 and 2 are configured but inactive.

The experiment answers narrower questions before any SpO₂ work:

- Which blocks respond to wrist contact, darkness, room light, pressure, or paced breathing?
- Do blocks 1 or 2 ever acquire samples?
- Which of the 21 header bytes change with each physical condition?
- Do the two readout slots within one block behave as paired detectors of one measurement?

It intentionally does not call a block red, infrared, green, or ambient. It does not estimate SpO₂ or
blood pressure.

## Safety and timestamp model

Phase marking is a local file append. It does not call the BLE command path or write a setting to the
strap. The marker stores phone Unix time. The analyzer compares that time with the Unix timestamp
inside each v20 frame, rather than the frame's arrival time, because the strap may deliver a buffer
later during history offload.

The first 10 seconds after every marker are excluded by the CLI by default. This keeps removal,
replacement, covering, and pressure transitions out of the steady-state summaries.

## Capture procedure

Use a normal connected WHOOP 5/MG with its clock synchronized. Do not change R22/config flags during
this experiment. If deep-history capture is not already working, establish that separately first.

1. In **Settings → Advanced → Experimental · WHOOP 5 / MG**, enable **Record puffin frames to a
   file**.
2. Tap **Mark phase… → On wrist · still**. Sit still for 2 minutes.
3. Tap **On wrist · gentle pressure**. Apply only comfortable, steady pressure to the strap for 2
   minutes; stop if there is discomfort.
4. Tap **Off wrist · sensor covered**. Remove the strap and place the sensor face inside an opaque cup
   or under opaque cloth for 2 minutes. Do not press material into the sensor window.
5. Tap **Off wrist · room light**. Leave the sensor face exposed and stationary for 2 minutes.
6. Put the strap back in its normal position, tap **On wrist · again**, and remain still for 2 minutes.
7. Optional respiration check: tap **On wrist · slow paced breathing**, breathe comfortably at about
   6 breaths/min for 3 minutes, then tap **On wrist · normal breathing** and breathe normally for 2
   minutes. Do not hold your breath or attempt desaturation.
8. Tap **End experiment**. Leave frame recording enabled until the normal history sync has completed,
   because some v20 buffers may arrive after the physical phases.
9. Tap **Export experiment…** and save the file. The share sheet suggests
   `noop-whoop5-optical-experiment-<timestamp>.jsonl`; on the device the same content lives in
   `puffin-deepbuffers.jsonl`, because the markers are appended to the existing capture log rather
   than written separately. Either name holds the frames and the phase boundaries together — the
   analyzer only cares about the contents.

### What the labels look like in the file

The procedure above names the buttons; the JSONL and the report use the raw values. They are not
always the same words — tapping **Off wrist · sensor covered** writes `off_wrist_dark` — so this is
the mapping to grep by:

| Button | `label` in the JSONL |
|---|---|
| On wrist · still | `on_wrist_still` |
| On wrist · gentle pressure | `gentle_pressure` |
| Off wrist · sensor covered | `off_wrist_dark` |
| Off wrist · room light | `off_wrist_room_light` |
| On wrist · again | `on_wrist_again` |
| On wrist · slow paced breathing | `paced_breathing_slow` |
| On wrist · normal breathing | `paced_breathing_normal` |
| End experiment | `experiment_end` |

`experiment_end` is a boundary, not a phase: it closes the preceding one so later offload records
are not attributed past the run, and it never appears as a phase in the report.

## Analyze the export

From the repository:

```bash
cd Packages/WhoopProtocol
swift run whoop-optical-experiment /path/to/noop-whoop5-optical-experiment-<timestamp>.jsonl \
  > optical-report.json
```

Use `--settling-seconds 0` to retain transition frames or another non-negative value to change the
default 10-second exclusion. `--compact` emits single-line JSON.

The report contains:

- `phases[].frame_count` and decoded frame timestamp range;
- each block's sample-count histogram, number of distinct headers, independently modal value for each
  of the 21 header bytes, and per-slot sample count/mean/RMS/standard-deviation/min/max;
- each adjacent phase comparison's activation change, sample-count change, exact header-byte offsets
  that changed, and channel-mean deltas;
- decoded, assigned, ignored, and invalid line counts so a sparse or malformed capture is visible.

## Evidence rules for the next decision

- A non-zero sample count in block 1 or 2 proves that a separate measurement became active. It does
  not identify its wavelength.
- A large room-light response that disappears when covered supports an ambient-sensitive
  measurement. Repeatability is required before applying an ambient label.
- A response that appears only on-wrist supports tissue coupling. Brightness alone does not identify
  red versus infrared.
- Consistent shared-header changes affect the measurement block; changes confined to one seven-byte
  channel metadata group affect one readout slot. Register names still require a confirmed mapping or
  controlled one-variable intervention.
- Paced-breathing agreement supports a respiratory modulation candidate only if the peak follows two
  or more commanded rates and dark/off-wrist controls do not reproduce it.

Only after two separate illumination measurements are identified should the project begin reference
oximeter calibration. Blood pressure remains a separate modeling and clinical-validation problem; it
is not expected to be a hidden scalar in this record.
