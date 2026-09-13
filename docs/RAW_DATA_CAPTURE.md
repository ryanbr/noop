# 5/MG raw data capture

**Status:** experimental, user-initiated, hardware-verified on WHOOP 5/MG. The capture path is a
research/export facility; it does not feed production health or activity scores.

## What it is for

The Raw Data Collector records a bounded interval of the strap's high-rate six-axis motion data and
exports it with enough provenance to analyse later. Typical uses are protocol validation, labelled
activity datasets, offline algorithm development, and checking whether a Bluetooth interruption was
repaired by a later history sync.

It lives in **Test Centre → 5/MG Raw Data Collector** on Android and Apple platforms. A session may be
started and stopped live, or created afterwards for an existing time range. Start/end times of a
completed session can be edited, individual sessions can be deleted, and all completed sessions can
be deleted after confirmation. Timestamped markers can identify a moment, start, end, or issue; each
marker may also carry a short note and remains editable after the session stops.

## What was verified on hardware

On WHOOP 5/MG, command 106 by itself can return `SUCCESS` without starting any IMU producer. The
working bounded sequence is:

1. `START_RAW_DATA` (81), payload `[0x01]`;
2. `TOGGLE_IMU_MODE` (106), payload `[0x01, 0x01]`;
3. receive and decode the 100 Hz six-axis buffers;
4. on stop, send `STOP_RAW_DATA` (82), payload `[0x01]`, then `TOGGLE_IMU_MODE` with
   `[0x01, 0x00]`.

The writes use the authenticated WHOOP command characteristic and require a connected/bonded strap.
An accepted command is not evidence that samples arrived, so the collector reports connection state,
request state, packet/byte counts, the last packet time, and history-sync progress separately.

The earlier NOOP decoder accepts 100 signed 16-bit samples for each of
`ax, ay, az, gx, gy, gz`, keyed by a strap Unix timestamp, and applies
`1/4096 g/LSB` and `0.06104 deg/s/LSB` as its historical scaling convention.
The [WHOOP 5/MG R21 layout](PROTOCOL_SENSORS.md#r21-six-axis-imu) also permits
partly populated buffers; its fixed layout does not independently prove physical
scaling or timing for every configuration.

## Live capture and history repair

A live BLE connection is not assumed to be lossless. Each session is a time window tied to one strap,
and incoming IMU buffers are routed by **strap timestamp**, not by arrival time. If Bluetooth is off or
the phone is disconnected during part of a recording, matching delayed buffers from a later historical
offload can still be appended to the session. Duplicate timestamps are discarded.

On Android, an active 100 Hz capture temporarily requests the high-throughput GATT connection
priority. A later historical offload does the same while it repairs an incomplete capture, then returns
the link to the balanced priority. This bounded lease is independent of the global experimental
history-speed preference. Apple's CoreBluetooth chooses connection parameters itself and exposes no
equivalent app-side priority request, so iOS keeps the same capture and repair lifecycle without a
non-functional transport toggle.

Consequences for consumers:

- file order is not chronological: repaired older history may be appended after newer live data;
- strap timestamp is authoritative and readers must sort by it;
- export metadata reports actual chunk coverage and `imu_100hz_complete`; it must not infer complete
  capture merely because the user started and stopped a session;
- history can repair only data the strap actually retained. The design does not promise that every
  firmware retains every high-rate buffer for later offload.

The historical-range action is therefore useful even when the collector was not running at the time:
it creates a session window over raw IMU buffers already available locally or delivered by the next
history sync. A range is currently bounded to seven days to keep an accidental export finite.

## Storage design

High-rate samples do **not** live as one SQLite row per sample. That would add avoidable write
amplification, database growth, migration burden, and backup cost to data whose main consumer is a
sequential signal-analysis job.

Instead, storage is split by responsibility:

| Data | Storage | Lifetime |
|---|---|---|
| Session window, comments, and markers | Small app-private JSON/JSONL metadata | Until the user deletes the session |
| Decoded 100 Hz IMU | App-private `.imus` segment files | Until the user explicitly deletes the session |

Each session owns fixed 30-minute UTC `.imus` segments. Late history data is routed by its strap
timestamp, so reconnecting after a workout does not put old samples into the current file. A segment
contains decoded, column-major, little-endian signed 16-bit accelerometer and gyroscope samples plus
the strap timestamp and phone receive time. Up to 30 one-second frames form an independently
zlib-compressed append block. A truncated final block after a crash does not make earlier blocks
unreadable.

There is no high-rate SQLite table or separate derived archive format. The time-addressable `.imus`
segments are both the retained source and the canonical analysis format. Readers must still sort and
deduplicate by strap timestamp because history frames can arrive late. Exports clip the first and last
segment to the selected interval without changing the retained source, so the same session can be
exported repeatedly after its window is edited.

## Session export

The shareable ZIP contains session provenance and all available sensor material for its selected
interval. Android currently includes `meta.json`, event JSONL and CSV files, decoded one-second
signals, raw sensor CSV, and `imu/*.imus`. Apple exports equivalent session metadata/events,
`history-sensors.csv`, `imu-coverage.json`, and IMU segments through its platform export path. Inspect
`meta.json` plus the platform's IMU coverage object first:

- `started_at_ms` / `ended_at_ms` are the selected analysis interval;
- `captured_started_at_ms` / `captured_ended_at_ms`, when present, preserve the physical recording
  interval even after the selected interval is edited;
- Android's `imu_100hz_coverage` identifies the segments actually present and `imu_100hz_complete` is
  the conservative coverage result; Apple carries the same facts in `imu-coverage.json`;

Exports stay local until the user invokes the operating system's share sheet. Raw captures are not
part of routine cloud sync or telemetry, consistent with NOOP's offline-first privacy model. The
suggested archive name is `noop-5mg-raw-<session-id>.zip`.

## Scope and operational limits


- The separately enabled protocol trace remains a general diagnostics tool. Starting a Raw Data
  Collector session does not enable it or duplicate its transport frames into the raw outbox.
- Session capture has one source of truth for high-rate motion: its file-backed `.imus` segments.
- Do not use arrival order as time, do not fill gaps silently, and do not claim 100 Hz coverage from
  packet count alone.

## Implementation map

| Concern | Apple | Android |
|---|---|---|
| Collector UI | `Strand/Screens/RawDataCollectorView.swift` | `com.noop.ui.GroundTruthCollectorScreen` |
| Session metadata | `RawDataSessionStore` | `GroundTruthCollector` |
| Live command path | `BLEManager.startGroundTruthRawCapture` | `WhoopBleClient.startGroundTruthImuCapture` |
| Append/recovery window | `ImuSessionFileStore` | `ImuSessionFileStore` |
| Canonical segmented storage/export | `ImuSessionFileStore` | `ImuSessionFileStore` |
| Raw decoder | `Whoop5RawImu` in `WhoopProtocol` | `Whoop5RawImu` in `com.noop.protocol` |
