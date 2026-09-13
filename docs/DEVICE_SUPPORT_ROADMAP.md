# Device support — roadmap & protocol notes

NOOP's north star is **WHOOP**, fully supported. Everything else is an opportunistic, easy-first
expansion that must never regress the WHOOP experience. This file records where each additional
source stands and the protocol facts we've verified, so the next build can pick up cleanly.

| Source | Status | How |
|--------|--------|-----|
| **WHOOP 4 / 5 / MG** | ✅ Shipped, primary | Local BLE decode |
| **Generic BLE heart-rate straps** (Polar / Wahoo / Coospo / Garmin HRM / Amazfit Helio HR-broadcast) | ✅ Shipped (v3.8.0), live HR + RR | Standard HR service `0x180D` / `0x2A37` |
| **Fitness Age / Vitality / Body Age** | ✅ Shipped (v4.0.0) | On-device, from the data above |
| **Xiaomi Smart Band 8 / 9 / 10** (Mi Band) | ✅ Shipped, **import lane** | Read the Mi Fitness iOS app's own SQLite, on-device (below) |
| **Xiaomi Smart Band — live BLE sync** | 🔬 Protocol researched, decoder not built | Mi protobuf-v2 over BLE GATT + `encryptKey` handshake (below) — hardware-gated |
| **Polar deep streams** (ECG / PPG / ACC / PPI) | 🔬 Pure PPI decoder built (`Packages/PolarProtocol` + `com.noop.polar`, tests green both platforms); live `PolarPMDSource` + ECG/PPG decode still to build | PMD service (below) — alpha, hardware-gated |
| **Garmin** (sleep / HRV / Body Battery / SpO₂ / FIT) | 📋 Researched, not built | Local BLE re-derive (Gadgetbridge-informed, **never** GPLv3 copy) |
| **Amazfit / Zepp** (incl. Helio deep) | 📋 Researched, not built | Encrypted Huami BLE — needs a one-time **user-pasted** vendor key (NOOP never logs into the vendor cloud) |
| **Oura** (Gen 3/4/5) | 🔬 Cloud import shipped; local BLE ring **experimental** | Cloud API v2 (off-by-default OAuth backfill) **+** clean-room BLE ring — auth, live HR/IBI, history drain, sleep hypnogram, activity/HR research (below) |
| **Fitbit / Google** | 📋 Researched, not built | Build against **Google Health** API (Fitbit Web API sunsets Sept 2026) — off-by-default import |

## Polar Measurement Data (PMD) — verified protocol

Source: official `polarofficial/polar-ble-sdk` (cross-verified). Lets us read ECG/PPG/ACC/PPI from a
Polar H10 / Verity Sense / OH1 the user owns, account-free, on top of the standard HR service.

- **Service UUID:** `FB005C80-02E7-F387-1CAD-8ACD2D8DF0C8`
  - **Control Point char:** `FB005C81-02E7-F387-1CAD-8ACD2D8DF0C8` (write + indicate)
  - **Data (MTU) char:** `FB005C82-02E7-F387-1CAD-8ACD2D8DF0C8` (notify)
- **Measurement-type codes (u8):** ECG `0`, PPG `1`, ACC `2`, PPI `3`, GYRO `5`, MAGNETOMETER `6` (mask `0x3F`).
- **Control-Point opcodes:** GET_MEASUREMENT_SETTINGS `1`, REQUEST_MEASUREMENT_START `2`, STOP_MEASUREMENT `3`.
  Start request byte = `(recordingType << 7) | measurementType`; settings are `[SettingType, len, data…]`
  blocks where SampleRate `0x00`, Resolution `0x01`, Range `0x02`.
- **Data frame:** `data[0]` = measurement type; `data[1..8]` = 64-bit little-endian timestamp (ns since
  2000-01-01 UTC); `data[9]` = frame type (`& 0x7F` = type, `& 0x80` = delta-compressed); payload from `data[10]`.
  - **ECG** type-0: 24-bit signed µV samples.
  - **ACC** type-0/1/2: 8/16/24-bit signed X/Y/Z (milli-g).
  - **PPI** type-0: `byte0` HR, `bytes1-2` peak-to-peak interval (ms), `bytes3-4` error estimate (ms),
    `byte5` flags (bit0 invalid, bit1 poor/no skin contact, bit2 contact unsupported).
  - **PPG** type-0: three 24-bit channels + ambient.
- **Per-model streams:** **H10** = ECG (130 Hz) + ACC + HR + RR (no PPG); **Verity Sense / OH1** =
  PPG + PPI + ACC + GYRO + HR (no ECG).

- **Control-point response:** the control point INDICATES a reply prefixed `0xF0`:
  `[0xF0, requestOpcode, measType, status, more, params…]`, `status == 0` = success (a GET_SETTINGS reply
  then carries the supported setting blocks in `params`). SDK layout — **confirm on hardware** before any
  consumer trusts a parsed status.
- **Model catalog (public advertised names → PMD streams):** **H10** `Polar H10 …` = ECG + ACC (R-R on the
  standard HR service); **H9** `Polar H9 …` = HR + R-R only, no PMD; **OH1** `Polar OH1 …` = PPG + PPI + ACC
  (no gyroscope); **Verity Sense** `Polar Sense …` = PPG + PPI + ACC + GYRO. R-R for HRV also arrives on the
  standard HR service for every model, so a no-PMD model is still a first-class HR/R-R source.

**Decoder status.** Built and tested on both platforms (`Packages/PolarProtocol` / `com.noop.polar`):
- `PmdDecoder` — frame header (type `& 0x3F`, ns timestamp, frame-type/compressed bit) + PPI samples (HR +
  peak-to-peak interval + error estimate + flags). PPI is the one NOOP needs — HR + inter-beat interval for
  HRV, no ECG peak detection.
- `PmdControl` — the control-point command builder (GET_SETTINGS / REQUEST_START / STOP, u16-LE setting
  blocks, the `(recording<<7)|type` start byte) + `0xF0` response parse. Pure byte work, no BLE.
- `PolarModel` — advertised-name → model + per-model PMD stream capabilities (the catalog above).

**Still to build:** the live `PolarPMDSource: LiveHRSource` (CoreBluetooth / android.bluetooth — a thin
wrapper: discover the PMD service, write `PmdControl.start(model.hrvPmdStream)`, subscribe to the data
char, feed `PmdDecoder`; hardware-gated, validate on an H10/Verity), plus ECG/PPG/ACC decode if ever needed.
**Confirm on hardware:** (1) the PPI flags' bit1/bit2 skin-contact polarity — the decoder names them per the
Polar SDK, but this doc phrases them oppositely; (2) the `0xF0` control-point response layout. No consumer
should gate on either until a real device settles it.

**Open item — #421** ("Polar H10 paired, no live data", Android): the generic-HR plumbing is correct
(CCCD write + both notification callbacks); the leading theory is the WHOOP auto-reconnect reclaiming
the radio while the strap is active. Needs the reporter's detail + an H10 in hand to verify a fix.

## Xiaomi Smart Band (Mi Band) — shipped import lane

NOOP imports a Mi Band's full history **without Bluetooth, a Xiaomi account, or any
cloud** by reading the data the **Mi Fitness iOS app already stored on the phone**. This
is the same "import data you already own" model as the WHOOP-CSV and Apple-Health lanes,
and it's fully offline.

- **What the user does:** on the iPhone, *Files → On My iPhone → Mi Fitness*, long-press
  the folder → *Compress*, then bring that `.zip` to NOOP (*Data Sources → Xiaomi Smart
  Band*). The bare `<user_id>.db` or an unzipped folder (macOS) also work.
- **Where the data is:** `DataBase/<user_id>/de/<user_id>.db` — one SQLite row per sample
  with a JSON `value` column. NOOP opens it **read-only** (GRDB) and never writes to it.
- **Tables read** (`deleted = 0` only):
  - Day rollups → `dailyMetric` + `metricSeries`: `steps_day` (steps, distance),
    `calories_day` (active kcal), `heart_rate_day` (`avg_rhr` resting, avg/min/max + HR
    zones), `sleep_day` (total/deep/light/rem minutes, `sleep_score`), `stress_day`
    (`avg_stress`, 0–100), `spo2_day` (`avg_spo2`), `intensity_day`, `valid_stand_day`,
    `vitality` (`latest_accumulated_vitality`).
  - `sleep` (interval) → `sleepSession`: each row's `items[]` is the **real per-epoch
    hypnogram** (`{start_time, end_time, state}`), giving NOOP a native
    `[{start,end,stage}]` timeline rather than just stage totals.
- **Sleep-stage codes** (verified against a real Mi Band 10 export):
  `1 = awake, 2 = light, 3 = deep, 4 = REM, 5 = awake-in-bed` → NOOP `wake/light/deep/rem`.
- **Not present in the export** (left `nil`, NOOP derives what it can): HRV, recovery,
  respiration rate, skin temperature.
- **Partition:** all rows land under `deviceId = "xiaomi-band"`, so it appears as its own
  Data Source for the per-source pages and cross-source consensus/compare views.

**Code:** parser `Packages/StrandImport/Sources/StrandImport/XiaomiBandImporter.swift`
(pure, re-derived from the public `artyomxx/xiaomi-band-ios-export` tool — **not** copied
from any GPL source); app glue `Strand/Data/XiaomiImporter.swift`; detection in
`ImportCoordinator`. Verified end-to-end against a real **450-day / 545-sleep** export.

## Xiaomi Smart Band — live BLE sync (researched, not built)

The chosen-but-deferred path. The band **is** reachable over BLE (Gadgetbridge supports
Smart Band 8/9/10 this way, no Classic-SPP/MFi needed), so a CoreBluetooth implementation
is feasible *in principle* on iOS — but it's a Gadgetbridge-scale reverse-engineer that
must be **re-derived, never GPL-copied**, and can only be built/verified with the physical
band in an iterative BLE test loop. Verified facts to pick up from:

- **Stack:** "Xiaomi protobuf v2" — length-prefixed, chunked **protobuf** command/response
  frames over a vendor GATT service (the Mi ecosystem service is `0xFE95`; the data
  channel is a custom 128-bit service with write + notify characteristics — confirm the
  exact UUIDs by a GATT dump of *this* band).
- **Auth:** the per-device **`encryptKey`** (32 hex chars) the vendor app holds — the user
  already extracts it as `auth.key` via the same Mi Fitness export. Pairing is a
  nonce-exchange handshake (send phone nonce → receive watch nonce → derive session keys),
  after which traffic is **AES-CCM** encrypted with **HMAC** integrity. NOOP would take the
  key as a one-time **user-pasted value** (same stance as the Amazfit/Zepp lane) and never
  log into the Xiaomi cloud.
- **Data fetch:** once authenticated, request **activity sync** — the watch streams the same
  per-minute samples and sleep/stage records that the import lane reads from the DB, so the
  decode target (and the `xiaomi-band` store shape) is **already built and verified**. Live
  sync is "only" the transport + crypto + protobuf layer in front of it.
- **iOS caveat:** background BLE sync under a free signing identity is limited; treat live
  sync as a foreground "Sync now" action first.

This earns its place only if it stays tractable and never threatens WHOOP stability — it
will not ship blind.

## Oura Ring — BLE (experimental)

A clean-room BLE lane for a ring the user owns, alongside the shipped cloud import. **Experimental**
(`ExperimentalBrand`-gated, not a shipped supported strap). NOOP computes its **own** Charge/Rest from the
ring's raw signals and **never** reads Oura's encrypted readiness/sleep scores. Full byte-level spec:
[`OURA_PROTOCOL.md`](OURA_PROTOCOL.md); this is the where-we-stand summary.

**Working (validated on a live Gen 3):** app-auth handshake (nonce → AES-128 proof), live HR + IBI stream,
SyncTime (`0x12`/`0x13`) handshake plus the ring-emitted `0x42` time-sync event as the UTC anchor (§6.11),
and a history drain aligned with open_oura `drain_events` (per-batch
cursor advance + quiet window → converges to `bytes_left 0`, no re-serve loop). Decoded signals: HR/IBI, HRV
(`0x5D` + reconstructed), skin temp (`0x46`), SpO₂, battery. Own central/GATT — never the WHOOP path.

**Sleep — hypnogram persist (DRAFT PR #446).** The ring writes the whole night's SleepNet phase codes in one
burst after wake; NOOP reconstructs the time axis (30 s/code, end anchored by the `0x49` sleep-summary) and
banks it as a `CachedSleepSession` with a `[{start,end,stage}]` timeline under the ring's own deviceId, so
`SleepMerge`'s imported-over-computed rule surfaces Oura's staging (reusing the #988/HC stage-timeline path).
Cross-checks: **light** matches WHOOP/the Oura app well (±2–3 min); **deep/REM undercounted, awake over** vs
the Oura app — the raw on-device SleepNet stream ≠ the app's post-processed hypnogram (surfaced honestly with
an "Oura / raw on-device stages" badge). **Display-only** — traced: it does NOT feed the recovery score (Charge
is computed from the engine's own HR staging). **Open:** a main-night gate so junk daytime fragments don't win
a day (same class as the import-side fix **#375**); on-device multi-night validation.

**Activity / MET — `0x50` (DRAFT PR #447, Tier-B, never scored).** A plausible third-party MET decode
(PR #960): `state` byte + per-sample MET. Captured to a diagnostic JSONL corpus (`oura-activity-<id>.jsonl`),
never a durable/scoring row. **Validated:** MET tracks land-activity intensity — three walks read mean ≈ 4 MET
vs a ≈ 0.9 sleep floor, and per-minute MET vs a Suunto `.fit` speed profile correlates **r = 0.89**. It
underreads water, and the stream is sparse with **ring-side** cadence gaps (~86 % coverage) so daily totals
undercount. **NOOP has no MET field** in its HR/strain model, so `0x50` stays research only — the ring's path
into NOOP activity is HR, never MET, and it is never a step count.

**Banked IBI → HR — `0x80` (research instrumentation).** open_oura derives per-minute HR (`hr_bpm = 60000/ibi`)
from the `0x80` green-IBI record, not from `0x50`. NOOP already decodes those IBIs for HRV; a tagged JSONL
sidecar (`oura-ibihr-<id>.jsonl`) also reconstructs an HR history from the banked stream for offline study.
**First daytime sample was sparse + noisy** (~7 usable beats/min, ~15 % impossible-HR artifacts) — looks like a
quality-sampled subset, not a full beat record. **Decisive test pending:** overnight density (ring still →
cleanest optics), per source tag. If a clean+dense stream emerges it becomes a real sleep-HR/RHR source (own
branch/PR); if not, it is a documented dead-end and MET stays the daytime proxy.

**Analysis tooling:** `diagnostics/oura_met_crosscheck.py` cross-checks the MET + IBI-HR corpora against the
app SQLite (workouts/sleep) and, with `--suunto`, a `.fit` export — per-minute MET/HR profiles + correlations.

## Notes on the deep-band lanes (Garmin / Amazfit / cloud)

These "earn their place" — pursue only while tractable, defer/drop if they threaten WHOOP stability or
become a time-sink. Garmin/Amazfit decode is genuinely L-effort and best done with a device to capture
against; the cloud lanes need registered OAuth apps + real accounts to verify. None will ship "blind."
