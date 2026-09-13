# Linux capture tools

Headless WHOOP BLE **capture + decode** for reverse-engineering the strap protocol on Linux — no Mac,
no GUI. This is the workbench for mapping the WHOOP 5.0 ("puffin") biometric layout (and extending
4.0), using a strap **you own**.

```
  whoop_capture.py ──► capture.json ──► whoop-decode (Swift)  ──► mapped fields
   (bleak / BlueZ)     (shared format)   (WhoopProtocol decoder)
```

The capture file format is **identical** to the macOS app's frame-export hook, so frames captured
here and on a Mac are interchangeable, and both feed the one decoder of record (`WhoopProtocol`) —
no second decoder to drift.

## Status

| Path | State |
|---|---|
| WHOOP 4.0 — capture + decode | ✅ verified on real hardware (frames decode CRC-valid) |
| WHOOP 4.0 — **historical offload** + decode (HR/RR/resp/SpO₂/accel) | ✅ verified on real hardware (`whoop_sync.py` — durable ack-loop drain, thousands of type-47 records) |
| WHOOP 5.0 — bond + `CLIENT_HELLO` session + command set | ✅ verified on real hardware |
| WHOOP 5.0 — historical offload trigger (`SEND_HISTORICAL_DATA`) | ✅ verified (full burst, same trim-cursor mechanism as 4.0) |
| WHOOP 5.0 — historical **biometrics** (type-47 v18) | ✅ unix + HR + R-R + gravity decoded (`parseFrameWhoop5`); cross-validated vs a 4C on the same person/window (HR corr 0.96, ±1 bpm at rest) |
| WHOOP 5.0 — optical channels (PPG/SpO₂/skin-temp) + v26 layout | ◑ partial — v26 channel-0 PPG validated as **real** cardiac PPG (HR-locked, corr +0.907 over 14 bursts) → a **spot HRV** is derivable from it (`whoop_spot_hrv.py`); SpO₂/skin-temp still raw (AC-coupled PPG has no DC) |

See [`../../docs/BLE_REVERSE_ENGINEERING.md`](../../docs/BLE_REVERSE_ENGINEERING.md) §3 for the
protocol details these tools exercise.

## Why this split

| Job | Tool | Why |
|---|---|---|
| BLE transport (scan / bond / subscribe) | **Python + bleak** | Best cross-platform BLE story on Linux/BlueZ; the upstream RE projects are Python too. |
| Decode frames | **Swift `whoop-decode`** | Reuses the *exact* `WhoopProtocol` decoder the app ships — guaranteed parity, zero reimplementation. |

## Requirements

- **Linux with BlueZ** and a BLE adapter (the capture side talks to BlueZ over D-Bus via bleak).
- **Python 3.10+** and `bleak` (`pip install -r requirements.txt`). The framing module and its tests
  are stdlib-only — `bleak` is needed only to actually talk to a strap.
- **A Swift toolchain** (5.9+, any 6.x works) to build `whoop-decode`. `WhoopProtocol` is
  Foundation-only, so it builds on Linux unchanged — no Apple frameworks required.
- A **WHOOP strap you own**, and (for WHOOP 5) the phone's Bluetooth off during capture.

> Tested on **Pop!_OS 24.04** (Ubuntu 24.04 base). Any modern BlueZ-based distro should work; the
> `apt` commands below are for Debian/Ubuntu/Pop!_OS — use your distro's package manager otherwise.

## Setup (first time)

Step by step from a fresh machine. Run these from inside this directory (`Tools/linux-capture/`).

```bash
# 1. System packages: Python venv support + BlueZ (Debian/Ubuntu/Pop!_OS)
sudo apt update
sudo apt install -y python3 python3-venv python3-pip bluez

# 2. Create a virtual environment (keeps bleak out of your system Python)
python3 -m venv .venv

# 3. Activate it (do this in every new terminal you use the tool from)
source .venv/bin/activate
#    your prompt now shows (.venv); to leave later, run: deactivate

# 4. Install the Python dependency (bleak)
pip install -r requirements.txt

# 5. Check it imported OK
python3 -c "import bleak; print('bleak ready')"
```

That's it for capturing. To also **decode** captures you need a Swift toolchain (see *Decode* below);
the Python capture side does not require Swift.

> The framing unit tests (`python3 -m unittest`) are stdlib-only and need neither the venv nor `bleak`
> — only live capture from a strap needs the steps above.

## Files

| File | Role |
|---|---|
| `whoop_capture.py` | Scan → connect → bond → subscribe → reassemble → write `capture.json`. `--probe` drives the post-hello command sequence. The RE workbench (whoop5-focused). |
| `whoop_sync.py` | **WHOOP 4.0 durable historical offload.** Connect → drain the on-device store (cmd 22 + `HISTORY_END` ack loop) into a device-scoped SQLite DB with **persist-before-ack** + auto-reconnect/resume. Subcommands: `sync` / `status` / `devices` / `export` / `label`. See [Historical sync](#historical-sync-whoop_syncpy). |
| `whoop_buzz.py` | **Find a misplaced strap.** Connect → vibrate the strap on repeat (and `--locate` to home in by signal strength). See [Find a lost strap](#find-a-lost-strap-whoop_buzzpy). |
| `whoop_setclock.py` | **Read/fix the strap clock.** Reads the RTC, and sets it to now if it has drifted past a threshold (`--if-drift`). See [Strap clock](#strap-clock-whoop_setclockpy). |
| `whoop_probe.py` | **Read-only status probe.** Reports the strap RTC + whether a historical store is present (`GET_CLOCK` / `GET_DATA_RANGE`) without writing anything. |
| `whoop_frame.py` | CRC8 / CRC16-Modbus / CRC32, frame builders (`build_command_frame`, `build_puffin_command`, `build_whoop5_buzz` / `build_whoop4_buzz`), the family-aware `Reassembler`, and the standard-HR parser. Stdlib only. |
| `hci_extract.py` | **Turn a phone HCI capture into `capture.json`.** Parses a btsnoop (`btsnoop_hci.log`) or Apple PacketLogger (`.pklg`) log, reassembles L2CAP/ATT, and extracts the CRC-valid WHOOP frames — so a capture of the **official app** (issue [#103](https://github.com/ryanbr/noop/issues/103)) feeds the same decode pipeline. Only WHOOP streams reach the output. Stdlib only. See [From a phone HCI capture](#from-a-phone-hci-capture-hci_extractpy). |
| `correlate_ground_truth.py` | **Locate un-decoded record fields using your WHOOP CSV export as known-plaintext.** Cross-references capture frames against the official per-night values (HRV, resting HR, skin temp, SpO₂, respiratory rate) to find each biometric's byte offset + encoding. Reuses the Swift importer's localized header aliases (English + DE/ES). Reports offsets only — your health values never leave the machine. Stdlib only. See [Ground-truth correlation](#ground-truth-correlation-correlate_ground_truthpy). |
| `validate_spo2_candidate.py` | **Multi-device validation of the v18 SpO₂ candidate at frame @82** (`spo2_candidate_82`). Nightly aggregate of in-band (70–100) samples during `sleep_state=asleep` vs CSV `blood_oxygen_pct`; reports r / MAE / bias / offset-specificity and a promote checklist. **@82 is duty-cycled**, so the tool detects its window schedule per capture, aggregates per window, and reports window coverage; a strap that never emits @82 is classified `feature_absent` rather than failed. Batch mode for several straps. Postable summary has **no raw SpO₂ values** (safe for [#103](https://github.com/ryanbr/noop/issues/103)). Stdlib only. See [SpO₂ candidate validation](#spo₂-candidate-validation-validate_spo2_candidatepy). |
| `pair_probe.py` | One-shot WHOOP 5 bonding probe: scan → connect → `pair()` → test `fd4b` access. `python3 pair_probe.py <MAC>`. |
| `analyze_v26_waveform.py` | Characterise the WHOOP 5 **v26** type-47 buffer as PPG @24 Hz using its own co-timestamped HR as ground truth. |
| `analyze_v25_waveform.py` | **WHOOP 4.0 v25 PPG → HR span-pinning harness ([#194](https://github.com/ryanbr/noop/issues/194)).** Sweeps the unpinned PPG span (start + sample-count) across a corpus of captures at *known* HRs and reports the span where recovered HR **tracks** ground truth instead of the `1440/N` autocorrelation artifact — or, on resting-only data, exactly what capture is still needed. `--selftest` proves it on synthetic pulses; no args runs the bundled-frames demo. Stdlib only. |
| `whoop_spot_hrv.py` | **Spot HRV (RMSSD) from the sparse PPG bursts.** Reads the v26 `feat_ppg` channel-0 24 Hz waveform (read-only), detects beats, computes RMSSD per PPG-covered window with a GOOD/COARSE/POOR quality label. See [Spot HRV](#spot-hrv-from-sparse-ppg-whoop_spot_hrvpy). Stdlib only. |
| `test_whoop_frame.py` | Unit tests for framing / reassembly / HR parsing / buzz frames (no `bleak` needed). |
| `test_hci_extract.py` | Unit tests for the btsnoop/pklg parsers, L2CAP/ATT reassembly, and WHOOP-frame extraction (synthetic fixtures; stdlib only). |
| `test_correlate_ground_truth.py` | Unit tests for the CSV/alias loading and the known-plaintext field search (planted-value recovery + false-positive rejection; stdlib only). |
| `test_validate_spo2_candidate.py` | Unit tests for multi-device SpO₂ @82 validation (planted perfect correlation, incomplete nights, awake gating, offset specificity, duty-cycle detection at planted period/phase, window coverage, the variance floor, flat-zero classification, privacy of postable output; stdlib only). |
| `test_whoop_spot_hrv.py` | Unit tests for the spot-HRV DSP (synthetic-signal HR/RMSSD recovery, ectopic rejection, grid reconstruction; stdlib only). |
| `requirements.txt` | `bleak` (runtime dep for capture only). |

## Capture (`whoop_capture.py`)

With the venv active (`source .venv/bin/activate` — see [Setup](#setup-first-time)):

```bash
# WHOOP 4.0: scan, connect, bond, record every frame, stop after 2 minutes
python3 whoop_capture.py --model whoop4 --address AA:BB:CC:DD:EE:FF --duration 120
```

It scans for the strap's custom GATT service, performs the bond, subscribes to the custom notify
channels **and** the standard Heart Rate profile (`0x2A37`, works unbonded), reassembles complete
frames, and appends each to `capture.json` as:

```json
{ "hex": "aa01…", "char": "fd4b0005-…", "ts_ms": 1700000000123, "hr": 61 }
```

The live `hr` (from the standard profile) is the **ground-truth cross-check**: find the byte in the
puffin payload that tracks it to locate the 5.0 HR field. `ts_ms` lets you line frames up against
known events.

### WHOOP 5: bonding (do this once)

The WHOOP 5 `fd4b…` characteristics require an **encrypted/bonded** link — without a bond, subscribing
or writing just stalls. The bond is plain just-works, but BlueZ needs a clean slate and the strap's
pairing window. With the **phone's Bluetooth off** (the strap accepts one central at a time):

```bash
export WHOOP_MAC=AA:BB:CC:DD:EE:FF
bluetoothctl remove $WHOOP_MAC     # clear any stale/half bond first — this is the usual fix
# put the strap into pairing mode, then:
bluetoothctl --timeout 8 scan on   # rediscover it
python3 pair_probe.py $WHOOP_MAC   # one just-works pair; the bond then persists
```

A stale bond left from a failed attempt shows up as `pair() → AuthenticationFailed`; `remove` + a
fresh pairing window clears it. Once bonded, the capture below needs no further pairing.

WHOOP's own guidance is to pair only through their app, not the OS Bluetooth menu. For interoperability
with a strap **you own**, the OS-level just-works bond above is sufficient — there is no app-side step.

### WHOOP 5: capture + start the stream

```bash
# bonded already → just capture; --probe sends post-hello commands to start streaming
python3 whoop_capture.py --model whoop5 --address $WHOOP_MAC --probe --duration 60 --out capture.json
```

`--probe` sends the (4.0) command numbers re-framed for puffin after `CLIENT_HELLO`;
`SEND_HISTORICAL_DATA` triggers a full historical offload. Without it you get only the hello response.

## Find a lost strap (`whoop_buzz.py`)

Misplaced your strap in the house? This connects and **vibrates it on repeat** so you can hear/feel it
and walk over. It sends the same haptic the official app uses for alarms — safe and reversible (only
the vibration motor runs; nothing is written to the data store, clock, alarm, or firmware).

```bash
# scan for any WHOOP 5, buzz 12× every 3 s
python3 whoop_buzz.py

# go straight to a known strap (find its MAC with `bluetoothctl devices`)
python3 whoop_buzz.py --address AA:BB:CC:DD:EE:FF

# buzz until you find it (Ctrl-C to stop), faster cadence
python3 whoop_buzz.py --address AA:BB:CC:DD:EE:FF --count 0 --interval 1.5

# WHOOP 4.0 strap
python3 whoop_buzz.py --model whoop4 --address AA:BB:CC:DD:EE:FF
```

**Not in the same room?** `--locate` doesn't buzz — it prints the strap's live signal strength so you
can play hot/cold (the bar grows as you get closer):

```bash
python3 whoop_buzz.py --locate --address AA:BB:CC:DD:EE:FF
#   -52 dBm [██████████████████████████····]     ← close
#   -88 dBm [██████·····························]  ← far / through a wall
```

Preconditions (same as capture): the strap must be **bonded to this machine** (run `pair_probe.py`
once — see [WHOOP 5: bonding](#whoop-5-bonding-do-this-once)), the **phone's Bluetooth must be OFF**
(the strap accepts one central at a time), and the strap must be **awake and in range** (~10 m line of
sight; a dead battery can't buzz).

By default each buzz is confirmed against the strap's `COMMAND_RESPONSE` ack, so the tool tells you
`acknowledged` vs `no ack yet` and exits non-zero if nothing was acknowledged — handy for scripting.
Exit codes: `0` accepted, `2` strap not found/reachable, `3` connected but no buzz acknowledged.

> Why a dedicated opcode: the WHOOP 5 / MG rejects the WHOOP 4.0 buzz command (79) and needs the
> "maverick" haptic (`0x13`) instead — details in
> [`docs/BLE_REVERSE_ENGINEERING.md` §6](../../docs/BLE_REVERSE_ENGINEERING.md).

## Strap clock (`whoop_setclock.py`)

A strap left offline (no app) for a long time loses its clock — its RTC drifts or resets, so realtime
and newly-recorded historical frames get **bogus timestamps** (e.g. dated 1971). The phone app fixes
this with `SET_CLOCK` on every connect; this does the same from Linux. It **reads the clock first and
only writes if it has drifted** past `--if-drift` seconds (mirrors the app's `ClockPolicy` — no
gratuitous resets), then re-reads to verify the new time latched.

```bash
# read-only: report the strap's current clock and how far it has drifted
python3 whoop_setclock.py --model whoop4 --address AA:BB:CC:DD:EE:FF --check

# set to now only if it's off by more than 30 s (otherwise leave it alone)
python3 whoop_setclock.py --model whoop4 --address AA:BB:CC:DD:EE:FF --if-drift 30

# force-set to now
python3 whoop_setclock.py --model whoop4 --address AA:BB:CC:DD:EE:FF
```

Exit codes: `0` clock OK or successfully set, `2` strap not found, `3` written but couldn't verify.

**The clock is checked automatically before every sync.** A sync from a strap with a bad clock yields
correctly-*valued* but wrongly-*dated* biometrics, so `whoop_sync.py sync` and `realtime` run this same
check first: they read the RTC and set it to now only if it has drifted past `--clock-threshold`
(default 30 s), then proceed. It's a self-contained preflight that doesn't perturb the capture session,
and it's best-effort (any error is logged and the sync continues). Disable with `--no-clock-check`.

```bash
# clock is checked + fixed (if >30s off) automatically, then the capture runs
python3 whoop_sync.py realtime --model whoop4 --address <MAC> --subject <name> --db captures/<name>.db
python3 whoop_sync.py realtime --model whoop4 --address <MAC> ... --clock-threshold 10   # stricter
python3 whoop_sync.py realtime --model whoop4 --address <MAC> ... --no-clock-check       # skip it
```

`whoop_setclock.py` remains the standalone tool for an explicit check/set outside a sync.

> **Firmware gotcha (hardware-verified).** Older WHOOP 4 firmware (e.g. `41.17.6.0`) latches the RTC
> **only** with the **9-byte** `SET_CLOCK` body (`u32 LE + 5 zero`); the 8-byte form newer firmware
> uses draws *no* response and silently fails. `build_whoop4_set_clock` sends the 9-byte form. The
> length is load-bearing — a wrong length is ack'd but not latched. Note also that the stored historical
> records keep the (correct) timestamp they were written with, so offloading old history does **not**
> need the clock fixed first — only future recordings do.

> Already-offloaded data isn't re-dated by a later `SET_CLOCK`; fix the clock so *new* data is correct.

## Historical sync (`whoop_sync.py`)

`whoop_capture.py` is the RE workbench (records raw frames; whoop5-focused). `whoop_sync.py` is the
**production offload path** (`--model whoop4|whoop5`): it drives the on-device **historical offload**
to completion and stores the frames durably, so you can pull a day — or a night — of **second-by-second**
biometrics off a strap you own: HR, RR intervals, respiration, SpO₂, skin temperature, and a 3-axis
accelerometer/gravity vector.

- **WHOOP 4.0** — fully working: offload + ack + decode (`whoop-decode` parses the type-47 fields).
- **WHOOP 5.0** — offload transport + ack + durable storage work (puffin framing, `CLIENT_HELLO`).
  The type-47 **v18** record decodes: `unix` @ 15, `heart_rate` @ 22 (stored by the sync), plus R-R
  and gravity via `whoop-decode`. Validated against a 4C worn by the same person in the same window
  (HR corr 0.96, ±1 bpm at rest). The optical channels (PPG/SpO₂/skin-temp) and a less-common **v26**
  record layout are kept raw (`unix`/`hr` = NULL) pending ground truth.

```
  whoop_sync.py sync ─► whoop.db (SQLite, device-scoped) ─► export ─► capture.json ─► whoop-decode
   (bleak / BlueZ)        persist-before-ack + trim cursor     (per device)               (HR/RR/resp/accel)
```

### The offload handshake (verified on real hardware)

1. Connect, subscribe the three `6108` notify channels, and silence the live type-43 raw flood
   (`TOGGLE_REALTIME_HR` / `SEND_R10_R11_REALTIME` off) so it doesn't starve the offload of airtime.
2. Write `SEND_HISTORICAL_DATA` (cmd 22, payload `[0x00]`, confirmed). The strap streams
   `METADATA HISTORY_START` → `HISTORICAL_DATA` (type-47) chunks → `METADATA HISTORY_END`.
3. On each `HISTORY_END`, **persist the chunk, then** ack with `HISTORICAL_DATA_RESULT` (cmd 23,
   payload `[0x01] + end_data`, confirmed), where `end_data` is the 8-byte trim cursor at
   `frame[17:25]`. The ack advances the strap's cursor to the next chunk — **without it the strap
   re-serves the same early chunk forever** and the type-47 records past it never arrive.
4. Loop until `METADATA HISTORY_COMPLETE`.

> WHOOP-4 frame offsets are the verified whoop5 offsets minus 4 (inner record starts at byte 4, not 8):
> inner type `@ frame[4]`, meta_type `@ frame[6]`, record unix `@ frame[11]`, trim cursor `@ frame[17:25]`.

### Durability — persist-before-ack

The ack tells the strap it may **trim (delete)** the acked chunk, so each chunk is committed to SQLite
(`journal_mode=WAL`, `synchronous=FULL` → fsync) **before** its ack is sent: a dropped BLE frame can
never be lost to a trim. The trim cursor is persisted too, so a reconnect **resumes where you left off**
(the strap also remembers; the stored cursor is for the client's own bookkeeping + gap reporting).

### Device scoping

Every frame, label, and cursor is tied to a `devices` row (MAC + advertised name + optional subject).
Multiple straps — or a partner as a test subject — never mix; dedup is **per device**
(`UNIQUE(device_id, hex)`).

### Usage

```bash
# bond once (see "WHOOP 5: bonding" above — the same bluetoothctl pair/trust works for 4.0), then:
python3 whoop_sync.py sync   --model whoop4 --address AA:BB:CC:DD:EE:FF --subject me  --db captures/whoop.db   # drain (resumable)
python3 whoop_sync.py sync   --model whoop5 --address 11:22:33:44:55:66 --subject partner --db captures/whoop.db
python3 whoop_sync.py status  --db captures/whoop.db [--address ..]     # cursor, coverage, counts, labels
python3 whoop_sync.py devices --db captures/whoop.db                    # every strap/subject in the store
python3 whoop_sync.py export  --db captures/whoop.db --address .. --out all.json [--only-type 47]
python3 whoop_sync.py label   --db .. --address .. --activity walking --start 19:58 --end 20:43
python3 whoop_sync.py decode  --db .. --address .. [--full]             # raw frames → the decoded values
```

`sync` auto-reconnects and resumes on a mid-session drop (up to `--max` seconds); it stops on
`HISTORY_COMPLETE`, on `--idle` seconds with no offload frame, or after two dry reconnects (store
drained / strap asleep). Re-run any time to continue — the cursor is durable. Times for `label`
accept epoch seconds, ISO-8601, or `HH:MM` (today).

> **The strap must be advertising to connect.** A bonded strap that BlueZ already auto-connected is
> *not* advertising, so `sync` force-disconnects and scans for the device object before connecting
> (and retries). If the strap has been idle a while it sleeps — nudge it (move it / pull it off the
> charger) so it advertises again; a central cannot wake a sleeping peripheral.

### SQLite schema

| Table | Columns | Purpose |
|---|---|---|
| `devices` | `id, address, name, subject, model` | one row per strap / subject |
| `frames` | `device_id, recv_ms, char, inner_type, unix, hr, hex` | every frame; deduped `UNIQUE(device_id, hex)` |
| `sync_state` | `(device_id, k) → v` | per-device `last_trim` cursor, coverage range, `history_complete` |
| `labels` | `device_id, start_unix, end_unix, activity, note` | activity labels for analysis |

Feed `export`'s `capture.json` to `whoop-decode` (below) to turn the synced frames into decoded
HR / R-R / respiration / accelerometer fields for downstream analysis.

### Decoded values (`decode_features.py`) — raw frames → the actual readings

`sync` stores raw frames (hex) durably, but hex isn't usable directly. The decode stage turns those
frames into **per-second value tables in the same DB**, so you have the actual readings — HR, R-R,
gravity, skin-temperature, PPG, events — pulled straight out of the raw WHOOP data. It runs
automatically as the **last stage of `sync`**, and standalone:

```bash
python3 whoop_sync.py decode --db captures/whoop.db --address AA:BB:..          # decode new frames since last run
python3 whoop_sync.py decode --db captures/whoop.db --address AA:BB:.. --full   # re-decode everything
```

**It reuses the Swift `whoop-decode` as the one decoder of record — it does _not_ re-implement
decoding in Python.** The bridge shells out to `whoop-decode --json`, maps the decoded fields into the
tables below, and stores nothing the decoder didn't produce. So the iOS/macOS/Android apps, the CLI,
and this decode step can never drift on frame offsets: there is exactly one decoder, verified against
real hardware. The decode cursor lives in `sync_state` (`last_decoded_frame_id`), so a run only decodes
**new** frames; re-runs are **idempotent**.

**Why this development matters for the synced data.** The raw offload is the *irreplaceable* part —
once the strap acks a chunk it may **trim (delete) it** — so capture must never be blocked or risked.
Decoding is the *rebuildable* part (features can always be re-derived from `frames`). The bridge
respects that split: decode runs **after** the offload fully drains, never inside the persist-before-ack
loop, and is **best-effort** — if `whoop-decode` isn't built or errors, the raw frames are already safe
and `sync` still succeeds; just re-run `decode`. The payoff: one `sync` leaves the DB with **both** the
durable raw frames **and** a complete, query-ready decoded view — the bridge between "we captured it"
and "we can learn from it". Without it, every consumer would have to re-export and re-decode the hex
themselves and risk diverging on the offsets.

#### Tables

| Table | Key | One row per |
|---|---|---|
| `feat_second` | `(device_id, unix)` | second — the wide design matrix |
| `feat_rr` | `(device_id, unix, idx)` | R-R interval within a second |
| `feat_ppg` | `(device_id, unix, sample_idx, channel)` | optical sample (WHOOP 5 v26, 24/sec) |
| `feat_event` | `(device_id, unix, kind)` | strap event |

#### Column reference (what each value means, as far as verified)

`feat_second` — one row per second; the decoded values for that second:

| Column | Unit / type | Meaning & caveats |
|---|---|---|
| `device_id` | int (FK `devices.id`) | which strap / subject this second belongs to |
| `unix` | UTC seconds | timestamp, from the **decoder's** `unix` field (authoritative across record versions; v26 frames carry NULL `frames.unix`, so we never rely on the row's column) |
| `hr` | bpm (u8) | heart rate. Sensor-startup/no-contact `hr==0` is stored as **NULL**, not 0, so it can't drag down averages |
| `gx`, `gy`, `gz` | g (float) | accelerometer / gravity vector; magnitude ≈ 1.0 at rest. The dominant **motion** signal for activity recognition |
| `rr_count` | int | number of beat-to-beat (R-R) intervals decoded in this second; NULL when none |
| `rr_mean_ms` | ms | mean R-R interval (≈ 60000/`hr`) |
| `rmssd` | ms | root-mean-square of successive R-R differences — standard short-window **HRV**; NULL when `rr_count` < 2 |
| `spo2_red`, `spo2_ir` | raw ADC counts | red & IR optical channel intensities. **Not a blood-oxygen %** — the red/IR ratio underlies SpO₂, but we store raw counts (no calibration invented). WHOOP 4 (v24) only |
| `skin_temp_raw` | raw ADC | skin-temperature sensor reading. **Not °C** — absolute raw count (the app derives a personal-baseline deviation; we keep the raw value). WHOOP 4 (v24) only |
| `resp_raw` | raw ADC | respiration-related raw reading. WHOOP 4 (v24) only |
| `record_version` | int | source record layout: **24** = WHOOP 4; **18 / 26** = WHOOP 5. Tells the consumer which columns are real vs NULL for this row |

> **Provenance via NULLs.** WHOOP 5 **v18** leaves the optical region unmapped (no verified offsets), so
> `spo2_*` / `skin_temp_raw` / `resp_raw` are **NULL** there; WHOOP 4 **v24** fills them. Per project rule
> we never invent offsets — an honest NULL beats a fabricated number.

`feat_rr` — individual beat-to-beat intervals (for HRV beyond the per-second summary):

| Column | Unit | Meaning |
|---|---|---|
| `idx` | int | position of the interval within its second (0 … `rr_count`-1) |
| `rr_ms` | ms | one R-R (inter-beat) interval |

`feat_ppg` — the WHOOP 5 **v26** optical photoplethysmography waveform (the raw pulse signal):

| Column | Unit | Meaning |
|---|---|---|
| `sample_idx` | int 0–23 | position within the 24-sample (≈ 24 Hz) burst for that second |
| `channel` | int | raw optical channel id as the decoder reports it. **No colour claim** — which physical LED (green/red/IR) each id maps to is unverified, so the raw id is surfaced as-is |
| `value` | relative ADC (signed) | one waveform sample. A **relative** optical intensity (AC+DC, uncalibrated) — useful for pulse shape / HR / perfusion features, **not** an absolute measurement |

`feat_event` — strap lifecycle events (useful for non-wear masking and context):

| Column | Type | Meaning |
|---|---|---|
| `kind` | text | event label as the decoder names it, e.g. `BLE_CONNECTION_UP(11)`, `BATTERY_LEVEL(3)`; events this firmware emits that the schema doesn't name stay raw, e.g. `0x7B(123)` (never cross-borrowed from another enum) |
| `event_num` | int / NULL | numeric event id when the decoder emits a number; NULL when `kind` is a named string |
| `payload_json` | text (JSON) | the event's remaining decoded fields (e.g. battery `soc`/`mv`), keys sorted |

> The decoded-value tables are **derived state** — delete them any time and rebuild with `decode --full`; the
> raw `frames` are the source of truth. Join `feat_second` to `labels` on `unix` for a labelled training set.

## Spot HRV from sparse PPG (`whoop_spot_hrv.py`)

> **Linux-first, read-only.** This derives an HRV figure on Linux from data the offload already gives —
> a capability the rest of the app does **not** yet implement (the apps surface the strap/cloud HRV; they
> don't derive RMSSD from the offloaded PPG). It opens `whoop.db` read-only and never writes. Documented
> here as the reference; port to the apps later.

The offload's per-second `rr_packed`/`rr` field **saturates and underestimates** HRV. But the strap also
banks a **real 24 Hz PPG waveform** in its sparse optical bursts (record version 26 → `feat_ppg` channel 0).
That waveform is genuine cardiac PPG — its fundamental **tracks heart rate** (validated: corr **+0.907** over
14 bursts). So beats can be detected and RMSSD computed:

```bash
python3 whoop_spot_hrv.py --db captures/whoop.db --device 1                  # every PPG-covered window
python3 whoop_spot_hrv.py --db captures/whoop.db --device 1 --start S --end E   # one window (e.g. a deep-sleep span)
```
```
window_start   span     HR   RMSSD  beats  quality
  0             40s    84   112ms     44  GOOD
  1120          40s   109      -       1  POOR
```

Where a burst lands inside a deep-sleep window, the PPG-derived RMSSD has lined up with WHOOP's own
deep-sleep number on the captures checked so far — and reaches values the offload's clamped `rr` field
can't. That's promising, not a controlled study: the tool labels each window's `quality` so you can tell a
trustworthy spot from a noisy one rather than relying on the headline.

**Honest limits** (the tool labels each window's `quality`):
- **Sparse** — bursts are ~40 s every ~18.7 min (~3.3 %), so a window gets HRV only if a burst lands in it.
  This is a **spot** HRV (best: a burst inside deep sleep), **not** continuous overnight HRV.
- **Coarse** — 24 Hz quantises beat timing (~42 ms/sample); sub-sample interpolation + ectopic rejection
  help, but trust `GOOD` (≥25 clean beats), treat `COARSE`/`POOR` with caution. HR (rate) is solid; RMSSD is
  approximate. Too little signal returns `None` rather than a fabricated number.
- **HRV only, not SpO₂** — the PPG is AC-coupled (no DC red/IR).

Best consumer: **sleep/recovery** — a deep-sleep spot RMSSD is a recovery proxy and an HRV input the sleep
stager otherwise lacks.

## Decode (`whoop-decode`)

Built from the `WhoopProtocol` Swift package (builds on Linux — Foundation only):

```bash
cd ../../Packages/WhoopProtocol
swift build --product whoop-decode
BIN=.build/debug/whoop-decode

$BIN capture.json                  # decode (family auto-detected per frame from `char`)
$BIN --raw-only capture.json       # only frames that did NOT fully decode — your RE worklist
$BIN --json capture.json           # machine-readable, for piping into your own analysis
$BIN --family whoop5 --hex aa0108000001e67123019101363e5c8d   # one frame ad hoc
```

## Import into the noop Android app

The noop Android app's **Data Sources → "Raw capture (.json)"** reads the same `capture.json` this
tool emits and decodes its frames on-device (HR / RR / gravity / …) through the *same* historical
decoder a live BLE offload uses — so history captured here on Linux lands in the app exactly as if the
phone had synced it. Produce one file per device:

```bash
.venv/bin/python whoop_sync.py export \
  --db captures/whoop.db --address <MAC> --out capture.json
```

**What `capture.json` is.** It is simply your strap's history saved as one file. `sync` already pulled
the data off your strap and stored it; `export` just writes a copy of it for one strap into a file the
phone app can open. Your data isn't changed or re-processed on the way out — the app does all the
decoding (heart rate, sleep, and so on) itself, so the file works the same whether you make it here or
the phone captured it directly.

If you want a smaller file, two optional flags narrow it down:

- `--only-type 47` — just the main once-per-second records.
- `--since <unix-time>` — only data newer than a given moment.

Then transfer `capture.json` to your phone (any file transfer works), open NOOP, and pick it from
**Data Sources → Raw capture**. Importing the same file twice is safe — NOOP skips anything it already
has — so you can re-run it without making duplicates. Export one file per strap; a file is normally a
single strap, but a mixed one still imports fine. The phone treats the file as untrusted input (size +
frame-count bounded, malformed rows skipped), so a stray or corrupt file is rejected cleanly rather
than crashing the import.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `pair() → AuthenticationFailed` | Stale/half bond in BlueZ, or strap not in its pairing window | `bluetoothctl remove <MAC>`, re-enter pairing mode, retry |
| Connect hangs (no `connected: True`) | Phone holds the strap (one central at a time) | Turn the **phone's Bluetooth off** / move it away |
| `start_notify` / write to `fd4b…` hangs | Not bonded — those chars need an encrypted link | Bond first (see *WHOOP 5: bonding*) |
| Bonded but only the hello response, no stream | No post-hello command sent | Add `--probe` |
| Not found in scan | Strap asleep / advertising window closed | Wake/charge-tap the strap; for WHOOP 5 re-enter pairing mode |
| `BleakClient(addr)` hangs right after `bluetoothctl remove` | BlueZ forgot the device | Scan first so it's rediscovered (the tools do this) |

## Safety & scope

- **Read-only with respect to your strap**, apart from the bonding handshake every BLE client must
  perform. These tools record data the strap already broadcasts.
- The only frames written are the **session/bond handshake** and, under `--probe`, a small set of
  **non-destructive** read/toggle commands (`GET_CLOCK`, `TOGGLE_REALTIME_HR`, `SEND_R10_R11_REALTIME`,
  `SEND_HISTORICAL_DATA`) — all part of the curated command set described in the project's BLE safety
  contract. No firmware/reboot/ship-mode/DFU commands are sent.
- **`whoop_sync.py` additionally sends `HISTORICAL_DATA_RESULT` (cmd 23), the offload ack.** This
  advances the strap's trim cursor, which causes the strap to **trim (delete) historical chunks it has
  already served** — exactly the same housekeeping WHOOP's own app performs on every sync, not a wipe
  of device function. Because the ack is destructive *to the on-strap copy*, the tool commits each
  chunk to disk **before** acking it (persist-before-ack), and the data lives on in the local DB.
- Use only on **hardware you own**. Capture files contain your strap's serial / a session token /
  its MAC — they are git-ignored and should not be shared.
- "WHOOP" is used **nominatively** to name the hardware. These tools contain no WHOOP code or assets.

## From a phone HCI capture (`hci_extract.py`)

You don't need a Linux BLE adapter to contribute frames. A **Bluetooth HCI capture of the official
WHOOP app** — the artifact issue [#103](https://github.com/ryanbr/noop/issues/103) asks for — records
the real app unlocking and draining the deep streams, which is exactly the traffic NOOP can't yet
elicit itself. `hci_extract.py` converts such a log into the same `capture.json` the rest of this
pipeline consumes.

Grab the capture on the phone that already pairs with your strap:

- **iOS** — install Apple's *Bluetooth* logging profile (the PacketLogger / Additional Logging
  profile), reproduce a **full history sync** in the WHOOP app, then export the `.pklg`.
- **Android** — *Developer options → Enable Bluetooth HCI snoop log*, sync, then pull
  `btsnoop_hci.log` (via a bug report or `adb`).

```bash
python3 hci_extract.py btsnoop_hci.log --family whoop5 --out capture.json
# → wrote 1843 frames → capture.json
#     fd4b0005-… [rx]: 1620 frames, …    ← strap → app data
#     fd4b0002-… [tx]: 41 frames, …      ← the app's commands (the enable sequence)
#     record types: 47 ×1601, 49 ×18, …
```

Only streams that reassemble into **CRC-valid WHOOP frames** are written — other devices' traffic and
non-WHOOP GATT chatter in the log are dropped. Frames the app *sent* are kept too (`"dir": "tx"`), so
the capture shows both the enable sequence and the strap's response. Privacy: the source HCI log still
holds your strap's BLE MAC and every device around you — share the extracted `capture.json` (or its
mapped offsets), not the raw log.

## Ground-truth correlation (`correlate_ground_truth.py`)

A capture gives raw records; your **WHOOP data export** gives the official readings for the same
nights. Put them together and the un-decoded layout (the type-`0x2F` deep records, the 5/MG history
types NOOP still skips — see [`WHOOP5_DEEP_DATA.md`](../../docs/WHOOP5_DEEP_DATA.md)) becomes a
*known-plaintext* problem: search each record for the byte offset + encoding whose value reproduces a
known biometric across every night.

Get the export from **app.whoop.com → Account → Data Export** (any language — the tool reads the
localized German/Spanish/… column headers via the same alias table the app's importer uses).

```bash
python3 correlate_ground_truth.py capture.json my_whoop_data.zip --tolerance 0.02
```

```
  type  field            offset    enc  scale       records      nights  score
  0x2f  resting_hr_bpm       10     u8      1    331/331      331/331    1.00
  0x2f  skin_temp_c          14  f32le      1    331/331      330/330    1.00
```

Offsets are into the **inner record** (the type byte is offset 0), ready to wire into
`parseFrameWhoop5` / `whoop_protocol.json`. The search demands both breadth (a decoded value for most
records) and distribution match (recall over known nights **and** precision — decoded values landing
in-range), so a near-constant byte or random noise won't score. `--type 0x2f` restricts to one record
type; widen `--tolerance` if a field is stored pre-rounded.

**Privacy:** everything runs locally. The tool prints only offsets/encodings — never your health
values — so its output is safe to post on #103 while the CSV export and the capture stay on your
machine. That's the intended way for other 5/MG owners to contribute field mappings without sharing
personal data.

## SpO₂ candidate validation (`validate_spo2_candidate.py`)

Once a capture has v18 historical records, this tool tests whether **byte @82** is a trustworthy
strap-computed SpO₂ scalar (the `spo2_candidate_82` decode already in Swift/Kotlin) by comparing
**nightly means** against your WHOOP CSV export — the multi-device bar described in
[`docs/WHOOP5_DEEP_DATA.md`](../../docs/WHOOP5_DEEP_DATA.md).

The frame source can be **either** an `hci_extract` / `whoop_capture` `capture.json` **or the SQLite
capture DB `whoop_sync.py` writes** (`captures/whoop.db`) — the same `frames` table
`whoop_activity.py` reads. Previously a Linux capture had to be round-tripped through
`whoop_sync.py export --only-type 47` before this tool, which sits in the same directory, could read
it. The file is identified by its SQLite header rather than its extension, since capture DBs get
renamed freely. Use `--device-id` if yours is not the default `2`.

Only v18 rows are read, filtered in SQL rather than after loading: newer 5/MG firmware serves a
v20 (2140 B) + v21 (1244 B) pair every second alongside the 124-byte v18, and only v18 carries
`@82`. On a mixed corpus that is the difference between 115 MB and 28 MB to reach the same 20k
usable records.

> **This is the capture tooling's database, not the app's.** Neither shipped app has a `frames`
> table — Android uses Room, iOS/macOS uses GRDB — so this cannot be pointed at a phone's store or a
> `.noopbak`. Validating a strap still requires a capture.

```bash
# One strap from a capture (summary stays aggregate-only unless you pass --show-nights):
python3 validate_spo2_candidate.py capture.json my_whoop_data/ --device strap-a --postable

# ...or straight from a whoop_sync.py capture DB, skipping the export step:
python3 validate_spo2_candidate.py captures/whoop.db my_whoop_data/ --device strap-a --postable

# Several straps at once (entries may mix .json and .db, and carry their own device_id):
python3 validate_spo2_candidate.py --batch devices.json --postable
```

`devices.json`:

```json
[
  {"device": "strap-a", "capture": "a.json", "export": "export_a/"},
  {"device": "strap-b", "capture": "b.json", "export": "export_b.zip"}
]
```

### @82 is duty-cycled — read this before trusting a run

`@82` is **not** sampled every second. On a corpus of 18,650 v18 records — 18,602 of them from
[@digitalerdude](https://github.com/digitalerdude)'s public PacketLogger capture of an official-app
overnight sync (see [#103](https://github.com/ryanbr/noop/issues/103)), plus 48 from a NOOP sync — it
is nonzero in only **450 records (2.4 %)**, in **15 runs, every one exactly 30 records long**, each
starting at the same `unix % 1200`, with **zero phase variance**. Outside that window the byte is
identically `0x00`.

So a capture (or a sampling scheme) that is not aligned to the phase reads all zeros and looks
exactly like a strap with the feature switched off. The tool therefore:

- **detects** the schedule per capture — period, phase, window length, jitter — and prints what it
  found. The window's *existence and stable length* is the robust fact; the phase offset is **not**
  assumed to generalise across straps or firmware, so it is never hard-coded;
- **aggregates per window**, not per second: a 30-second burst is one measurement the strap took, so
  a densely-sampled window cannot outvote a sparse one;
- **reports coverage** per night (windows sampled ÷ windows expected) and warns loudly below
  `--min-window-coverage` (default 0.5), because a night built on 2 of 21 windows is not comparable
  to one built on all of them.

If your run reports low coverage, re-capture aligned to the phase the tool printed rather than
reading the correlation.

What it checks (per device):

| Check | Default gate |
|-------|----------------|
| Paired nights with export SpO₂ **and** in-band @82 during sleep | ≥ 5 |
| Export SpO₂ has real night-to-night spread | range ≥ 1.0 % |
| Pearson **r** (nightly aggregate @82 vs export) | ≥ 0.7 |
| Mean absolute error | ≤ 1.0 % |
| Offset specificity scan @74–92 | best \|r\| is **@82** |
| Distinct in-band values at @82 (variance floor) | ≥ 5, stdev ≥ 0.5 |
| Median share of the night's duty windows sampled | ≥ 0.5 (n/a if not duty-cycled) |

The variance floor exists because "the value lands in 70–100" is **not** a specific screen. On a real
subscription-free 5.0 strap six offsets pass an in-band-only screen on a majority of records — `@17`,
`@33`, `@59`, `@69`, `@71`, `@107` — and every one is either an already-decoded non-SpO₂ field (`@33`
`cardiac_flags`, `@59` `step_cadence`, `@69`/`@71` the two aux thermal channels) or near-constant
(`@17` is byte 2 of the u32 unix timestamp at `@15`; `@107` has 4 distinct values). A nightly SpO₂
cannot have 2 distinct values, so an offset must show real variation before its correlation is ranked.

**Overall PASS** only if every gate clears. A strap whose `@82` is `0x00` on 100 % of a long enough
capture is reported as **`feature_absent`** — neither a PASS nor a FAIL, and excluded from the
multi-device gate, because a device with no data has not failed a correlation. To make that claim the
capture must also have **watched** the strap: at least an hour of *observed* sleep (samples × cadence,
not `max − min`, which counts gaps) and a cadence of **≤ 30 s**, since a coarser one can alias with the
duty period and read `0x00` off a working strap. Either bar missed and it stays a plain FAIL, with the
duty line saying why. NOOP still will not
promote `spo2_candidate_82` → `spo2Pct` from a single device: need **≥ 2 devices** that each PASS
(postable summary prints `multi_device_eligible` / `all_pass` / `feature_absent`).

**Privacy:** default output and `--postable` print only aggregates (r, MAE, bias, offsets, pass/fail).
`--show-nights` prints per-night values for **local** debugging — do not paste that on GitHub.

Capture sources: `hci_extract.py` on an official-app overnight sync, or `whoop_capture.py` after a
bonded 5/MG history offload. Synthetic/absolute v18 buffers (test fixtures) are also accepted.

## Contributing captures back

A `capture.json`'s `hex` values are a drop-in for the parity fixtures in
`Packages/WhoopProtocol/Tests/WhoopProtocolTests/Resources/frames.json`. When you map a new WHOOP 5.0
field, add the offset to `parseFrameWhoop5` / `whoop_protocol.json` and back it with a real capture —
the project rule is *real captures, never invented offsets*.

## Tests

```bash
python3 -m unittest -v          # framing / reassembly / HR parse (stdlib only, no bleak needed)
```

The framing is cross-checked against the Swift decoder: a `GET_BATTERY_LEVEL` frame built by
`build_command_frame()` and a puffin frame built by `build_puffin_command()` each decode with
`ok=true` and both CRCs valid via `whoop-decode`.

## Credits

The protocol understanding these tools exercise builds on prior community reverse-engineering —
`johnmiddleton12/my-whoop` (WHOOP 4.0) and `b-nnett/goose` (WHOOP 5.0). See
[`../../ATTRIBUTION.md`](../../ATTRIBUTION.md).
