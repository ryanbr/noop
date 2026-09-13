# NOOP — On-Device Data Model

NOOP is a standalone, fully offline companion app for WHOOP straps (4.0 and 5.0). It talks to
the user's own strap directly over Bluetooth Low Energy — no WHOOP cloud or account
is involved, and stores everything it decodes locally in a single SQLite database.
This document describes that on-device database: every table, its columns, natural keys, indexes,
and the migration history that produced the current schema.

> **Scope note.** Interacting with the strap here means interoperating with the user's *own*
> device and the data it has already recorded. NOOP is **not affiliated with, endorsed by, or
> connected to WHOOP**, and it is **not a medical device** — none of the stored values are
> intended for diagnosis or treatment.

---

## Where the database lives

The persistence layer is the `WhoopStore` Swift package
(`Packages/WhoopStore`), built on [GRDB](https://github.com/groue/GRDB.swift) over SQLite. Like
every package in the repo, it declares both platforms — `.iOS(.v16)` and `.macOS(.v13)`
(`Packages/WhoopStore/Package.swift`) — and is UI-framework agnostic, so the same schema and
storage code back both the macOS app and the iOS app (the latter build-from-source only — see
`docs/IOS.md`).

The macOS app target opens the database at a fixed, per-user location
(`Strand/Collect/StorePaths.swift`):

```
<Application Support>/OpenWhoop/whoop.sqlite
```

```swift
// Strand/Collect/StorePaths.swift
static func defaultDatabasePath() throws -> String {
    let fm = FileManager.default
    let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                          appropriateFor: nil, create: true)
        .appendingPathComponent("OpenWhoop", isDirectory: true)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    return base.appendingPathComponent("whoop.sqlite").path
}
```

On a typical macOS install that resolves to
`~/Library/Application Support/OpenWhoop/whoop.sqlite`. Tests use an in-memory database via
`WhoopStore.inMemory()`.

### Connection configuration

`WhoopStore.init(path:)` (`Packages/WhoopStore/Sources/WhoopStore/WhoopStore.swift`) opens a
single `DatabaseQueue` and applies these PRAGMAs before any query runs:

| PRAGMA | Value | Why |
| --- | --- | --- |
| `journal_mode` | `WAL` | Two handles to the same file (the BLE collector and the metrics repository) can read/write without deadlocking. |
| `synchronous` | `NORMAL` | Durable pairing with WAL — only an OS crash or power loss can lose the last transaction. |
| `cache_size` | `-16000` | ~16 MB page cache for multi-thousand-row import/backfill writes. |
| `mmap_size` | `268435456` | 256 MB memory-mapped I/O. |
| `temp_store` | `MEMORY` | In-memory temp tables. |
| `busyMode` | `.timeout(5)` | 5-second busy timeout under write contention. |

`WhoopStore` is an `actor`: all GRDB calls run on the actor's serial executor (off the main
thread) through the `syncRead` / `syncWrite` helpers. `WhoopStoreInfo.schemaVersion` is a
separate, manually-maintained constant (currently `18`) that has lagged the real migration
history for a while and should not be read as the schema's true version. The migrator itself
(`makeMigrator()`, below) is the source of truth for what tables/columns exist, and has run
through **v25** (`v25-oura-raw` — the Oura raw-payload archive, the newest addition; see
below).

---

## Schema at a glance

The schema falls into five groups (this section predates, and undercounts, everything added
after v9 — see the schema-version note above; the Oura raw archive below is the one
post-v9 addition currently documented here):

| Group | Tables | Origin |
| --- | --- | --- |
| **Device registry** | `device` | BLE pairing |
| **Decoded streams** (durable) | `hrSample`, `rrInterval`, `event`, `battery`, `spo2Sample`, `skinTempSample`, `respSample`, `gravitySample` | Decoded from strap frames on-device |
| **Raw outbox** (transient) | `rawBatch` | Compressed raw BLE frames, prunable |
| **Bookkeeping** | `cursors` | Highwater / read cursors |
| **Metric caches** | `sleepSession`, `dailyMetric`, `journal`, `workout`, `appleDaily`, `metricSeries`, `scoreInputProvenance` | Derived metrics + their input-provider provenance + CSV / Apple-Health imports |
| **Oura raw archive** (durable, v25) | `ouraRaw` | Verbatim Oura API payloads behind the opt-in cloud import — see below |

All timestamp columns named `ts`, `startTs`, `endTs`, `capturedAt`, etc. are **unix seconds**
(integers). Day-keyed cache tables use a `day` text column in `YYYY-MM-DD` form and compare it
lexicographically.

---

## Migration history

Migrations are registered in `Packages/WhoopStore/Sources/WhoopStore/Database.swift`
(`makeMigrator()`) and run in order on every open.

| Version | What it adds |
| --- | --- |
| **v1** | Core tables: `device`, the four original decoded streams (`hrSample`, `rrInterval`, `event`, `battery`), and the raw outbox `rawBatch`. |
| **v2** | `cursors` key/value table for highwater bookkeeping. |
| **v3** | Type-47 biometric streams: `spo2Sample`, `skinTempSample`, `respSample`, `gravitySample`. |
| **v4** | Local metric caches: `sleepSession` (one row per session) and `dailyMetric` (one row per calendar day). |
| **v5** | Adds a `synced` integer column (default `0`) to all eight decoded-stream tables. **Vestigial** — see below. |
| **v6** | Adds nullable `charging` boolean to `battery` for the dense BATTERY_LEVEL series. |
| **v7** | Adds in-sleep signal aggregates to `dailyMetric`: `spo2Pct`, `skinTempDevC`, `respRateBpm` (all nullable). |
| **v8** | Adds `journal`, `workout`, and `appleDaily` (Apple-Health daily aggregates). |
| **v9** | Adds the generic long-format `metricSeries` table and its `(deviceId, key, day)` index. |
| **v24-rr-seq** | Rebuilds the `rrInterval` primary key as `(deviceId, ts, rrMs, seq)`, so an identical interval recurring within one second is no longer dropped. |
| **v29-score-input-provenance** | Adds metric-level `scoreInputProvenance` for NOOP-computed headline scores. It does not change `dayOwnership` or score precedence. |
| **v30-rr-ord** | Adds the nullable `rrInterval.ord` column — emission order within a `ts` — and makes it lead the read sort (#823/#830). Additive; pre-existing rows keep `ord` NULL. |

> This table is a selection, not the full list — it covers the migrations the tables above refer to.
> The registered set is the authority. Migrations are keyed by their **identifier string**, not by
> the number in it, so renaming one re-runs it against an already-migrated database. Cite the
> identifier in full — `v30-rr-ord`, not "v30".

### The vestigial `synced` column

Migration v5 added a per-row `synced` integer (`NOT NULL DEFAULT 0`) to each of the eight
decoded-stream tables. It dates from a since-removed server-upload feature. **NOOP is fully
offline: nothing writes or reads `synced`.** The insert path explicitly never sets it
(`StreamStore.swift`), and no read query references it. The column is left in place only to avoid
a `DROP COLUMN` migration over potentially millions of existing rows. Treat it as dead schema.

---

## Device registry

### `device` *(v1)*

One row per strap the app has seen. Natural key is the device `id`.

| Column | Type | Notes |
| --- | --- | --- |
| `id` | TEXT | **Primary key.** Stable device identifier. |
| `mac` | TEXT | BLE MAC address (nullable). |
| `name` | TEXT | Advertised/device name (nullable). |
| `firstSeen` | INTEGER | Unix seconds, set on first insert. |
| `lastSeen` | INTEGER | Unix seconds, bumped on every upsert. |

`upsertDevice(id:mac:name:)` (`StreamStore.swift`) inserts or, on `id` conflict, updates `mac`,
`name`, and `lastSeen` (it does not touch `firstSeen`). Every other table references the strap via
a `deviceId` text column, scoping all data per device.

---

## Decoded streams (durable record)

These eight tables are the **durable, compact local record** of what the strap measured. They are
decoded on-device from BLE frames by the `WhoopProtocol` package and written by
`WhoopStore.insert(_ streams:deviceId:)` (`StreamStore.swift`). The in-memory shapes are the
`WhoopProtocol` stream structs (`Packages/WhoopProtocol/Sources/WhoopProtocol/Streams.swift`):
`HRSample`, `RRInterval`, `WhoopEvent`, `BatterySample`, `SpO2Sample`, `SkinTempSample`,
`RespSample`, `GravitySample`, aggregated into `Streams`.

All inserts are **idempotent by natural key** — they use `ON CONFLICT(...) DO NOTHING`, so
re-decoding overlapping frames (the common case during BLE backfill) never duplicates rows.
`insert(...)` returns the count of rows *actually* inserted per stream. Range reads live in
`Reads.swift` and follow a uniform shape: `WHERE deviceId = ? AND ts >= ? AND ts <= ? ORDER BY ts
ASC LIMIT ?`.

> The biometric stream structs carry a constant `unit` field (`"raw_adc"` / `"g"`) for JSON
> parity with golden fixtures, but `unit` is **not** a database column — only the numeric fields
> below are persisted.

### `hrSample` *(v1)* — heart rate

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `ts` | INTEGER NOT NULL | Wall-clock unix seconds. Part of PK. |
| `bpm` | INTEGER NOT NULL | Beats per minute. |
| `synced` | INTEGER NOT NULL DEFAULT 0 | *(v5, vestigial)* |

**Primary key:** `(deviceId, ts)`. HR is taken only from `REALTIME_DATA` (type 40) frames.
`latestHRSampleTs(deviceId:)` returns `MAX(ts)` here — the biometric "data frontier" used by the
stuck-strap watchdog.

### `rrInterval` *(v1)* — R-R intervals (HRV source)

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `ts` | INTEGER NOT NULL | Wall-clock unix seconds. Part of PK. |
| `rrMs` | INTEGER NOT NULL | Beat-to-beat interval, milliseconds. Part of PK. |
| `seq` | INTEGER NOT NULL DEFAULT 0 | *(v24)* Repeat counter for an **identical** beat. Part of PK. |
| `ord` | INTEGER | *(v30)* Emission order within `ts`. Nullable; **not** in the PK. |
| `synced` | INTEGER NOT NULL DEFAULT 0 | *(v5, vestigial)* |

**Primary key:** `(deviceId, ts, rrMs, seq)` — `rrMs` is in the key because multiple R-R intervals can
share a single `REALTIME_DATA` timestamp, and `seq` because the same interval value can legitimately
recur within that second. `seq` keys on `(ts, rrMs)`, **not** `ts` alone: every *distinct* interval in
a second therefore carries `seq = 0` and keeps its own key, so a distinct beat is never dropped when a
second arrives across separate insert batches or via the live/historical merge. A `ts`-only counter
would restart per batch and collide distinct beats — a data-loss regression.

**Read order:** `ts ASC, ord ASC, rrMs ASC, seq ASC`
(`Reads.swift` `rrIntervals`, `WhoopDao.kt` `rrIntervals`).

`ord` leads the sort because ordering by `rrMs` returned a second's beats sorted by **value**, which
makes successive beats similar by construction and biases RMSSD — built entirely from successive
differences — downward (#823, fixed in #830). `ord` is the beat's position among all beats sharing its
`ts`, stamped at decode time. It is deliberately **not** in the key, for the reason above.

Two properties of `ord` a consumer has to know:

- **Pre-v30 rows have `ord` NULL.** The order was never recorded and cannot be backfilled. SQLite
  sorts NULL first in ASC, so an all-legacy second ties on `ord` and falls through to the old
  `(rrMs, seq)` order — i.e. existing data reads back exactly as before, with the #823 bias intact.
  No `COALESCE`, no sentinel. Room and GRDB agree here because both are SQLite.
- **`ord` is batch-local.** A second split across two live flushes restarts `ord` at 0, and
  `ON CONFLICT DO NOTHING` keeps whichever row landed first, so that second also falls back to
  magnitude order. The historical offload path delivers a second atomically and is unaffected.

`ord` is a sort key only. The two platforms differ in whether they carry it back: Swift selects
`ts, rrMs`, so `ord` is excluded, while `WhoopDao.rrIntervals` is `SELECT *` and Room materialises it
into every returned `RrInterval` (`Entities.kt`, `val ord: Int? = null`). No consumer reads its value
on either platform.

### `event` *(v1)* — strap events

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `ts` | INTEGER NOT NULL | Real RTC unix seconds (never offset). Part of PK. |
| `kind` | TEXT NOT NULL | Event name (e.g. `BATTERY_LEVEL(3)`). Part of PK. |
| `payloadJSON` | TEXT NOT NULL | Decoded payload as JSON. |
| `synced` | INTEGER NOT NULL DEFAULT 0 | *(v5, vestigial)* |

**Primary key:** `(deviceId, ts, kind)`. `payloadJSON` is serialized with `JSONEncoder`'s
`.sortedKeys` so the same payload is byte-identical every time — important for the natural-key
dedupe. Reads decode it back into `[String: ParsedValue]` with a shared, reused decoder.

### `battery` *(v1, +charging in v6)*

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `ts` | INTEGER NOT NULL | Event RTC for BATTERY_LEVEL events, else `wallClockRef`. Part of PK. |
| `soc` | DOUBLE | State of charge (%), nullable. |
| `mv` | INTEGER | Millivolts, nullable. |
| `charging` | BOOLEAN | *(v6)* Nullable — only the dense BATTERY_LEVEL event series reports it; the command-response path leaves it `NULL`. |
| `synced` | INTEGER NOT NULL DEFAULT 0 | *(v5, vestigial)* |

**Primary key:** `(deviceId, ts)`. (Note: `batterySamples(...)` reads back only `ts, soc, mv`.)

### Type-47 biometric streams *(v3)*

These four mirror the original streams (per-row natural key `(deviceId, ts)`, `DO NOTHING`
inserts, identical range-read shape).

#### `spo2Sample` — pulse oximetry raw ADC

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `ts` | INTEGER NOT NULL | Unix seconds. Part of PK. |
| `red` | INTEGER NOT NULL | Red LED raw ADC. |
| `ir` | INTEGER NOT NULL | IR LED raw ADC. |
| `synced` | INTEGER NOT NULL DEFAULT 0 | *(v5, vestigial)* |

**Primary key:** `(deviceId, ts)`.

#### `skinTempSample` — skin temperature raw ADC

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `ts` | INTEGER NOT NULL | Unix seconds. Part of PK. |
| `raw` | INTEGER NOT NULL | Raw ADC reading. |
| `synced` | INTEGER NOT NULL DEFAULT 0 | *(v5, vestigial)* |

**Primary key:** `(deviceId, ts)`.

#### `respSample` — respiration raw ADC

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `ts` | INTEGER NOT NULL | Unix seconds. Part of PK. |
| `raw` | INTEGER NOT NULL | Raw ADC reading. |
| `synced` | INTEGER NOT NULL DEFAULT 0 | *(v5, vestigial)* |

**Primary key:** `(deviceId, ts)`.

#### `gravitySample` — accelerometer / gravity vector

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `ts` | INTEGER NOT NULL | Unix seconds. Part of PK. |
| `x` | DOUBLE NOT NULL | Gravity vector X (g). |
| `y` | DOUBLE NOT NULL | Gravity vector Y (g). |
| `z` | DOUBLE NOT NULL | Gravity vector Z (g). |
| `synced` | INTEGER NOT NULL DEFAULT 0 | *(v5, vestigial)* |

**Primary key:** `(deviceId, ts)`.

This is the low-rate decoded vector used by normal analytics, not the 100 Hz six-axis capture.
High-rate IMU deliberately remains outside SQLite. Capture sessions own canonical, decoded `.imus`
files split into fixed 30-minute UTC segments with independently compressed 30-second blocks. See
[5/MG raw data capture](RAW_DATA_CAPTURE.md#storage-design).

---

## Raw outbox (transient, prunable)

### `rawBatch` *(v1)*

The raw outbox stores the strap's original BLE frames — compressed and batched — so the exact
bytes survive even for frames NOOP can't yet fully decode. Whereas the decoded streams are durable,
raw batches are **transient and prunable**. Implementation in `RawOutbox.swift`.

| Column | Type | Notes |
| --- | --- | --- |
| `batchId` | TEXT | **Primary key.** |
| `deviceId` | TEXT NOT NULL | Owning strap. |
| `capturedAt` | INTEGER NOT NULL | Unix seconds the batch was captured; pending reads order by this. |
| `deviceClockRef` | INTEGER NOT NULL | Strap-clock reference for the wall-clock offset. |
| `wallClockRef` | INTEGER NOT NULL | Wall-clock reference, unix seconds. |
| `startTs` | INTEGER NOT NULL | First frame timestamp in the batch. |
| `endTs` | INTEGER NOT NULL | Last frame timestamp in the batch. |
| `frameCount` | INTEGER NOT NULL | Number of frames packed. |
| `byteSize` | INTEGER NOT NULL | Size used for `storageStats()` totals. |
| `framesBlob` | BLOB NOT NULL | zlib-compressed packed frames (length-prefixed). |
| `syncedAt` | INTEGER | Unix seconds; `NULL` until marked. |

**Primary key:** `batchId`. Frames are packed as `[count u32 LE]{[len u32 LE][bytes]}×count`,
then zlib-compressed with a 4-byte uncompressed-length prefix.

**Pruning policy** (`pruneRaw(now:keepWindowSeconds:maxUnsyncedBytes:)`): only batches with a
non-null `syncedAt` older than `now - keepWindowSeconds` are deleted — safe because the decoded
streams persist separately. Unsynced raw is **never** dropped (it is the sole copy of the strap's
not-yet-decoded bytes after a chunk is trimmed). `maxUnsyncedBytes` is accepted for call-site
compatibility but intentionally unused.

---

## Bookkeeping

### `cursors` *(v2)*

A simple key/value table for incremental-processing highwater marks (`Cursors.swift`).

| Column | Type | Notes |
| --- | --- | --- |
| `name` | TEXT | **Primary key.** |
| `value` | INTEGER | Stored cursor value (typically a timestamp). |

Helpers namespace the `name`: `highwater:<stream>` (upload/forward-only highwater) and
`read:<stream>` (pull cursor). The distinct prefixes keep the two cursor families from colliding
for the same stream.

---

## Metric caches

These tables hold **derived metrics and imported aggregates** rather than raw measurements.
Recovery / strain / HRV / sleep math is computed locally by the `StrandAnalytics` package, and
CSV / Apple-Health data arrives through `StrandImport`. Every cache table follows the same
contract: a `Codable` struct, an idempotent `ON CONFLICT(...) DO UPDATE` upsert keyed by its
natural key (latest value wins), and range-read accessors that run off-main.

### `sleepSession` *(v4)*

One row per sleep session (`MetricsCache.swift`, `struct CachedSleepSession`).

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `startTs` | INTEGER NOT NULL | Session start, unix seconds. Part of PK. |
| `endTs` | INTEGER NOT NULL | Session end, unix seconds. |
| `efficiency` | DOUBLE | Sleep efficiency, nullable. |
| `restingHr` | INTEGER | Resting HR, nullable. |
| `avgHrv` | DOUBLE | Average HRV, nullable. |
| `stagesJSON` | TEXT | Verbatim JSON array of stage segments (`[{start,end,stage}]`), nullable — stored as a string so the cache stays schema-agnostic about staging shape. |

**Primary key:** `(deviceId, startTs)`. Read by `startTs` range, oldest first.

### `dailyMetric` *(v4, +v7 columns)*

One row per calendar day (`MetricsCache.swift`, `struct DailyMetric`). This is the central
per-day rollup behind the dashboard. **Natural key `(deviceId, day)`** where `day` is
`YYYY-MM-DD`. All metric columns are nullable.

| Column | Type | Migration | Notes |
| --- | --- | --- | --- |
| `deviceId` | TEXT NOT NULL | v4 | Part of PK. |
| `day` | TEXT NOT NULL | v4 | `YYYY-MM-DD`. Part of PK. |
| `totalSleepMin` | DOUBLE | v4 | Total sleep, minutes. |
| `efficiency` | DOUBLE | v4 | Sleep efficiency. |
| `deepMin` | DOUBLE | v4 | Deep sleep, minutes. |
| `remMin` | DOUBLE | v4 | REM sleep, minutes. |
| `lightMin` | DOUBLE | v4 | Light sleep, minutes. |
| `disturbances` | INTEGER | v4 | Disturbance count. |
| `restingHr` | INTEGER | v4 | Resting heart rate. |
| `avgHrv` | DOUBLE | v4 | Average HRV. |
| `recovery` | DOUBLE | v4 | Recovery score. |
| `strain` | DOUBLE | v4 | Day strain. |
| `exerciseCount` | INTEGER | v4 | Number of exercises. |
| `spo2Pct` | DOUBLE | v7 | Mean SpO2 (%) during sleep. |
| `skinTempDevC` | DOUBLE | v7 | Skin-temperature deviation (°C) from baseline. |
| `respRateBpm` | DOUBLE | v7 | Mean respiration rate (breaths/min) during sleep. |

**Primary key:** `(deviceId, day)`. Read by lexicographic `day` range, oldest first. The
`DailyMetric` struct's `init` defaults the three v7 fields to `nil` so older callers stay
source-compatible.

### `journal` *(v8)*

One user-answered daily prompt (`JournalWorkoutAppleCache.swift`, `struct JournalEntry`).

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `day` | TEXT NOT NULL | `YYYY-MM-DD`. Part of PK. |
| `question` | TEXT NOT NULL | Prompt text. Part of PK. |
| `answeredYes` | INTEGER NOT NULL | `0`/`1`, mapped to/from `Bool`. |
| `notes` | TEXT | Free-text note, nullable. |

**Primary key:** `(deviceId, day, question)`. Read by `day` range, ordered `day ASC, question
ASC`.

### `workout` *(v8)*

One workout (`JournalWorkoutAppleCache.swift`, `struct WorkoutRow`). All metric columns nullable.

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `startTs` | INTEGER NOT NULL | Start, unix seconds. Part of PK. |
| `endTs` | INTEGER NOT NULL | End, unix seconds. |
| `sport` | TEXT NOT NULL | Sport/activity name. Part of PK. |
| `source` | TEXT NOT NULL | Origin of the row (e.g. import source). |
| `durationS` | DOUBLE | Duration, seconds. |
| `energyKcal` | DOUBLE | Energy, kcal. |
| `avgHr` | INTEGER | Average HR. |
| `maxHr` | INTEGER | Max HR. |
| `strain` | DOUBLE | Workout strain. |
| `distanceM` | DOUBLE | Distance, meters. |
| `zonesJSON` | TEXT | Verbatim JSON of HR-zone percentages — stored as a string so the cache stays schema-agnostic about zone shape. |
| `notes` | TEXT | Free-text note. |

**Primary key:** `(deviceId, startTs, sport)`. Read by `startTs` range, oldest first.

### `appleDaily` *(v8)*

Apple-Health-specific daily aggregates (`JournalWorkoutAppleCache.swift`, `struct AppleDaily`),
imported from an Apple Health `export.xml`. All metric columns nullable.

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `day` | TEXT NOT NULL | `YYYY-MM-DD`. Part of PK. |
| `steps` | INTEGER | Step count. |
| `activeKcal` | DOUBLE | Active energy, kcal. |
| `basalKcal` | DOUBLE | Basal energy, kcal. |
| `vo2max` | DOUBLE | VO₂max estimate. |
| `avgHr` | INTEGER | Average HR. |
| `maxHr` | INTEGER | Max HR. |
| `walkingHr` | INTEGER | Walking HR average. |
| `weightKg` | DOUBLE | Body weight, kilograms. |

**Primary key:** `(deviceId, day)`. Read by lexicographic `day` range, oldest first.

### `metricSeries` *(v9)*

A generic **long-format / EAV** metric store (`MetricSeriesStore.swift`, `struct MetricPoint`).
Where the tables above use a wide column-per-metric layout, this is the tall counterpart: one row
per `(deviceId, day, key)` with a single REAL `value`. Any scalar metric — server-derived,
Apple-Health, journal-encoded, etc. — can be projected into this one table and read back uniformly
by key, which is the substrate for a metric explorer that lists and compares metrics without
knowing each source's schema.

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `day` | TEXT NOT NULL | `YYYY-MM-DD`. Part of PK. |
| `key` | TEXT NOT NULL | Metric identifier (e.g. `"restingHr"`, `"steps"`, `"recovery"`). Part of PK. |
| `value` | DOUBLE NOT NULL | The scalar value. |

**Primary key:** `(deviceId, day, key)`.

**Index** — `idx_metricSeries_device_key_day` on `(deviceId, key, day)`. The primary key orders by
`day` before `key`, so it can't efficiently serve per-metric range reads (`metricSeries(key:from:
to:)`) or `metricDays(key:)`, which scan `(deviceId, key)` and then walk days. This index makes
those reads index-only. Accessors: `upsertMetricSeries(...)`, `metricSeries(...)`,
`metricKeys(...)` (distinct keys for a device), and `metricDays(...)` (`MIN`/`MAX` day per key).

### `scoreInputProvenance` *(v29)*

Records which sensor/import source supplied the inputs for each persisted NOOP-computed score.
This is deliberately separate from `dayOwnership`, which remains a scoring resolver override.
Rows are replaced atomically with the corresponding `dailyMetric` / `metricSeries` score writes;
legacy scores without a row have unknown provenance and the UI omits their provider badge.

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Computed `-noop` namespace. Part of PK. |
| `day` | TEXT NOT NULL | `YYYY-MM-DD`. Part of PK. |
| `key` | TEXT NOT NULL | `recovery`, `strain`, or `sleep_performance`. Part of PK. |
| `sourceId` | TEXT NOT NULL | Physical device or import source that supplied the inputs. |

**Primary key:** `(deviceId, day, key)`. **Index:** `idx_scoreInputProvenance_source` on
`sourceId`, used when a provider's data is deleted.

---

## Oura raw-payload archive

This section documents the one table added after this document's v9 baseline (see the
schema-version note above): the lossless backstop behind the opt-in Oura history import
(off by default; user-initiated OAuth backfill — `docs/PRIVACY_SECURITY.md` §1.1b). It is
**not** a metric cache like the tables above — it stores verbatim API responses, not decoded
values, so any field Oura returns can be re-derived later without re-fetching.

### `ouraRaw` *(v25)*

One row per fetched PAGE of an Oura API endpoint response — not one row per Oura document; a
single page's `data` array can carry many documents (`OuraRawStore.swift`, `struct OuraRawRow`).
Written by `OuraSyncCoordinator.fetchRaw(_:dateParam:)` in the app target (`Strand/Oura/`).
Natural key `(deviceId, endpoint, documentId)`. Migration `v25-oura-raw`
(`Packages/WhoopStore/Sources/WhoopStore/Database.swift`) — additive only, a new table, no
existing row touched.

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. `"oura-api"` for the live cloud-import lane. |
| `endpoint` | TEXT NOT NULL | Part of PK. Oura endpoint name, e.g. `"sleep"`, `"daily_readiness"`, `"heartrate"`. |
| `documentId` | TEXT NOT NULL | Part of PK. A SYNTHESIZED page key, `"<endpoint>-<startDate>-<pageIndex>"` (`startDate` is the backfill window's start date, `pageIndex` the fetched page's 0-based position) — never Oura's own document `id`, for any endpoint. |
| `day` | TEXT | `YYYY-MM-DD`, nullable. Currently always NULL — the coordinator never sets it. Reserved for a future per-document (rather than per-page) keying scheme. |
| `payloadJSON` | TEXT NOT NULL | Verbatim JSON body of the fetched page (the raw HTTP response, including its `data` array of documents) — losslessness holds at the page level, not the individual-document level. |
| `fetchedAt` | INTEGER NOT NULL | Unix seconds. |

**Primary key:** `(deviceId, endpoint, documentId)`. `upsertOuraRaw(...)` is idempotent on this
key via `ON CONFLICT(...) DO UPDATE` — re-pulling the SAME window (same `startDate`, so the same
`pageIndex` synthesizes the same `documentId`) overwrites that page's `day`/`payloadJSON`/
`fetchedAt` in place rather than duplicating.

**Index** — `idx_ouraRaw_device_endpoint_day` on `(deviceId, endpoint, day)`, so per-endpoint
reads (`ouraRaw(deviceId:endpoint:)`) scan `(deviceId, endpoint)` and walk `day` in order
without a table scan.

**Not covered by `deleteAllData(deviceId:)`.** Unlike the metric-cache tables above, `ouraRaw`
is not in `DeviceRegistryStore.deviceScopedTables`, so the general per-device wipe skips it by
construction. Disconnecting Oura calls the dedicated `deleteOuraRaw(deviceId:)` alongside
`deleteAllData(deviceId:)` (`Strand/Oura/OuraConnectModel.swift`) so the raw archive is purged
too, not left behind.

---

## Index summary

| Index | Table | Columns | Purpose |
| --- | --- | --- | --- |
| *(implicit PK)* | every table above | (its natural key) | Dedupe + primary lookup. |
| `idx_metricSeries_device_key_day` | `metricSeries` | `deviceId, key, day` | Index-only per-metric range reads. |
| `idx_ouraRaw_device_endpoint_day` | `ouraRaw` | `deviceId, endpoint, day` | Index-only per-endpoint range reads. |

Every other table relies on its primary-key index; the decoded-stream and date-range reads are all
served by the `(deviceId, ts)` / `(deviceId, day)` / `(deviceId, startTs)` primary keys.

---

## Provenance

NOOP's strap interoperability is built on community reverse-engineering work, which it credits and
builds upon:

- **WHOOP 4.0 protocol** — [`johnmiddleton12/my-whoop`](https://github.com/johnmiddleton12/my-whoop)
- **WHOOP 5.0 protocol** — [`b-nnett/goose`](https://github.com/b-nnett/goose)

The frame parsing, CRC, and command/event/packet decode that feed the decoded-stream tables above
live in the `WhoopProtocol` package; persistence is `WhoopStore`; the local recovery / strain /
HRV / sleep math is `StrandAnalytics`; and the CSV / Apple-Health importers are `StrandImport`.

> **Reminder.** NOOP is not affiliated with WHOOP and is not a medical device. All stored data is
> the user's own, kept entirely on the user's device.
